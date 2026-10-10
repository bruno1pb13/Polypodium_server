import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:polypodium_server/core/config.dart';
import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/admin/admin_handler.dart';
import 'package:polypodium_server/features/admin/release_checker.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/auth_repository.dart';
import 'package:polypodium_server/features/admin/settings_repository.dart';
import 'package:polypodium_server/features/gardens/garden_handler.dart';
import 'package:polypodium_server/features/gardens/garden_repository.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';
import 'package:polypodium_server/features/sync/sync_repository.dart';
import 'package:polypodium_server/features/weather/weather_handler.dart';
import 'package:polypodium_server/features/weather/weather_provider.dart';
import 'package:polypodium_server/features/weather/weather_repository.dart';
import 'package:polypodium_server/features/weather/weather_service.dart';
import 'package:polypodium_server/middleware/cors_middleware.dart';
import 'package:polypodium_server/middleware/error_middleware.dart';
import 'package:polypodium_server/routes/router.dart';
import 'package:polypodium_server/server/ssl.dart';

/// Set by the Docker build (`--build-arg SERVER_VERSION`): the release tag,
/// or `git describe` output for images built from main.
const _serverVersion =
    String.fromEnvironment('SERVER_VERSION', defaultValue: 'dev');

void main() async {
  final configError = Config.validate();
  if (configError != null) {
    stderr.writeln('FATAL: refusing to start — $configError');
    exit(78); // EX_CONFIG
  }

  final pool = await initDatabase();
  print('Database connected and migrations applied.');

  final photosDir = Directory(Config.photosDir);
  if (!photosDir.existsSync()) await photosDir.create(recursive: true);

  final tokens = JwtTokenService(Config.jwtSecret);
  final authRepo = AuthRepository(pool);
  final gardenRepo = GardenRepository(pool);
  final settingsRepo = SettingsRepository(pool);
  final weatherRepo = WeatherRepository(pool);
  final weather = WeatherService(
    weatherRepo,
    settingsRepo,
    OpenMeteoProvider(Config.weatherApiUrl),
    options: Config.weatherOptions,
  )..start();
  final releases = ReleaseChecker(_serverVersion);
  if (Config.updateCheckEnabled) releases.start();
  final serverStartedAt = DateTime.now();
  final router = buildRouter(
    auth: AuthHandler(authRepo, tokens),
    sync: SyncHandler(SyncRepository(pool)),
    photos: PhotoHandler(Config.photosDir),
    admin: AdminHandler(
        authRepo, settingsRepo, serverStartedAt, _serverVersion,
        weather: weather, releases: releases),
    gardens: GardenHandler(gardenRepo, authRepo),
    weather: WeatherHandler(weather, weatherRepo),
    gardenRepo: gardenRepo,
    authRepo: authRepo,
    tokens: tokens,
  );

  final handler = Pipeline()
      .addMiddleware(errorMiddleware())
      .addMiddleware(corsMiddleware())
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final context = buildSslContext();

  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    Config.port,
    securityContext: context,
  );

  final scheme = context != null ? 'https' : 'http';
  print('Polypodium server listening on $scheme://0.0.0.0:${server.port}');
  if (context == null && Config.behindProxy) {
    print('Serving plain HTTP; TLS is expected to terminate at the reverse proxy.');
  }
}
