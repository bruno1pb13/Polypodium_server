import 'dart:async';
import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import '../auth/i_auth_repository.dart';
import '../weather/weather_service.dart';
import 'i_settings_repository.dart';
import 'release_checker.dart';

final _uuid = const Uuid();

const _minPasswordLength = 8;

class AdminHandler {
  const AdminHandler(
      this._repo, this._settings, this._serverStartedAt, this._version,
      {WeatherService? weather, ReleaseChecker? releases})
      : _weather = weather,
        _releases = releases;
  final IAuthRepository _repo;
  final ISettingsRepository _settings;
  final DateTime _serverStartedAt;
  final String _version;
  final WeatherService? _weather;
  final ReleaseChecker? _releases;

  /// Any authenticated user can call this — used by the client to decide
  /// whether to show admin UI and whether data export/import is allowed for
  /// this account, not gated behind adminOnlyMiddleware.
  Future<Response> me(Request request) async {
    final userId = request.context['userId'] as String;
    final info = await _repo.getAuthInfo(userId);
    if (info == null) return _error(404, 'user not found');
    final isAdmin = info['role'] == 'admin';
    return _json(200, {
      ...info,
      // Effective permissions for this account: admins are never restricted,
      // members follow the server-wide toggles.
      'canExportData': isAdmin ||
          await _settings.getBool(settingAllowMemberExport,
              defaultValue: true),
      'canImportData': isAdmin ||
          await _settings.getBool(settingAllowMemberImport,
              defaultValue: true),
      // Whether GET /weather/locations/<id> serves forecasts.
      'weatherEnabled': await _weatherEnabled(),
    });
  }

  Future<Response> getSettings(Request request) async {
    return _json(200, {
      'allowMemberExport':
          await _settings.getBool(settingAllowMemberExport, defaultValue: true),
      'allowMemberImport':
          await _settings.getBool(settingAllowMemberImport, defaultValue: true),
      'weatherEnabled': await _weatherEnabled(),
    });
  }

  Future<bool> _weatherEnabled() async =>
      await _weather?.isEnabled() ?? false;

  Future<Response> updateSettings(Request request) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final allowExport = body['allowMemberExport'];
    final allowImport = body['allowMemberImport'];
    final weatherEnabled = body['weatherEnabled'];
    if (allowExport == null && allowImport == null && weatherEnabled == null) {
      return _error(400,
          'allowMemberExport, allowMemberImport or weatherEnabled must be provided');
    }
    if ((allowExport != null && allowExport is! bool) ||
        (allowImport != null && allowImport is! bool) ||
        (weatherEnabled != null && weatherEnabled is! bool)) {
      return _error(400,
          'allowMemberExport, allowMemberImport and weatherEnabled must be booleans');
    }
    if (allowExport is bool) {
      await _settings.setBool(settingAllowMemberExport, allowExport);
    }
    if (allowImport is bool) {
      await _settings.setBool(settingAllowMemberImport, allowImport);
    }
    if (weatherEnabled is bool) {
      await _settings.setBool(settingWeatherEnabled, weatherEnabled);
      // Fetches right away instead of waiting for the next hourly check.
      final weather = _weather;
      if (weatherEnabled && weather != null) {
        unawaited(weather.runOnce().then((_) {}, onError: (Object e) {
          print('Weather job failed: $e');
        }));
      }
    }
    return getSettings(request);
  }

  /// Regions the weather job maintains and how their last fetch went.
  Future<Response> weatherStatus(Request request) async {
    final weather = _weather;
    if (weather == null) return _error(404, 'weather not available');
    final regions = await weather.regions();
    return _json(200, {
      'enabled': await weather.isEnabled(),
      'regions': [
        for (final r in regions)
          {
            'id': r.id,
            'latitude': r.latitude,
            'longitude': r.longitude,
            'timezone': r.timezone,
            'elevation': r.elevation,
            'lastFetchedAt': r.lastFetchedAt?.toUtc().toIso8601String(),
            'lastAttemptAt': r.lastAttemptAt?.toUtc().toIso8601String(),
            'lastUsedAt': r.lastUsedAt?.toUtc().toIso8601String(),
            'lastError': r.lastError,
          }
      ],
    });
  }

  /// Refetches every region in use now, regardless of the daily schedule.
  Future<Response> weatherRefresh(Request request) async {
    final weather = _weather;
    if (weather == null) return _error(404, 'weather not available');
    if (!await weather.isEnabled()) {
      return _error(409, 'weather is disabled');
    }
    final result = await weather.runOnce(force: true);
    return _json(200, result.toJson());
  }

  Future<Response> status(Request request) async {
    final userCount = await _repo.countUsers();
    final uptimeSeconds =
        DateTime.now().difference(_serverStartedAt).inSeconds;
    return _json(200, {
      'uptimeSeconds': uptimeSeconds,
      'version': _version,
      'userCount': userCount,
      // Informational only: the newest published release (null until a
      // check succeeds or when checks are off) and whether this server is
      // behind it. Updating the deployment is up to the operator.
      'latestVersion': _releases?.latestVersion,
      'updateAvailable': _releases?.updateAvailable ?? false,
    });
  }

  Future<Response> listUsers(Request request) async {
    final users = await _repo.listUsers();
    return _json(200, {'users': users});
  }

  Future<Response> createUser(Request request) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;

    if (email == null ||
        email.isEmpty ||
        password == null ||
        password.isEmpty) {
      return _error(400, 'email and password required');
    }
    if (password.length < _minPasswordLength) {
      return _error(400, 'password must be at least $_minPasswordLength characters');
    }

    final existing = await _repo.findUserByEmail(email);
    if (existing != null) {
      return _error(409, 'email already registered');
    }

    final userId = _uuid.v4();
    final hash = BCrypt.hashpw(password, BCrypt.gensalt());
    final user = await _repo.createUser(userId, email, hash, 'member');
    return _json(201, user);
  }

  Future<Response> setRole(Request request, String id) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final role = body['role'] as String?;
    if (role == null || (role != 'admin' && role != 'member')) {
      return _error(400, "role must be 'admin' or 'member'");
    }

    if (role == 'member') {
      final guardError = await _guardLastAdmin(id);
      if (guardError != null) return guardError;
    }

    await _repo.setRole(id, role);
    return _json(200, {'id': id, 'role': role});
  }

  Future<Response> setDisabled(Request request, String id) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final disabled = body['disabled'] as bool?;
    if (disabled == null) {
      return _error(400, 'disabled must be a boolean');
    }

    if (disabled) {
      final guardError = await _guardLastAdmin(id);
      if (guardError != null) return guardError;
    }

    await _repo.setDisabled(id, disabled);
    return _json(200, {'id': id, 'disabled': disabled});
  }

  /// Blocks demoting/disabling [targetUserId] if doing so would leave the
  /// server with zero active admins.
  Future<Response?> _guardLastAdmin(String targetUserId) async {
    final target = await _repo.getAuthInfo(targetUserId);
    if (target == null) return _error(404, 'user not found');
    if (target['role'] == 'admin' && target['disabled'] == false) {
      final activeAdmins = await _repo.countActiveAdmins();
      if (activeAdmins <= 1) {
        return _error(400, 'cannot remove the last remaining admin');
      }
    }
    return null;
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
