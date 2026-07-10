import 'dart:io';

class Config {
  static final String environment = Platform.environment['APP_ENV'] ?? 'development';
  static bool get isDevelopment => environment == 'development';

  static final String? sslCertPath = Platform.environment['SSL_CERT_PATH'];
  static final String? sslKeyPath = Platform.environment['SSL_KEY_PATH'];

  /// TLS is terminated by a reverse proxy (e.g. Nginx Proxy Manager). When
  /// true, the app knowingly serves plain HTTP on the loopback/private network
  /// and the proxy is responsible for HTTPS. This is an explicit opt-in so a
  /// misconfigured production deploy never *silently* serves plaintext.
  static final bool behindProxy =
      (Platform.environment['BEHIND_PROXY'] ?? 'false') == 'true';

  static final String databaseUrl = Platform.environment['DATABASE_URL'] ??
      'postgresql://postgres:postgres@localhost/polypodium';

  /// Built-in secret used only for local development. Production is required to
  /// override this (see [validate]) — a token signed with this key must never
  /// be accepted by a public server, since the value is in the source tree.
  static const String defaultJwtSecret =
      'dev-secret-change-in-production-min-32-chars!!';

  static final String jwtSecret =
      Platform.environment['JWT_SECRET'] ?? defaultJwtSecret;

  static final bool dbSsl = (Platform.environment['DB_SSL'] ?? (isDevelopment ? 'false' : 'true')) == 'true';

  static final int port =
      int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  static final String allowedOrigins =
      Platform.environment['ALLOWED_ORIGINS'] ?? '*';

  static final String photosDir =
      Platform.environment['PHOTOS_DIR'] ?? './photos';

  /// Optional shared secret that gates public self-registration of the very
  /// first (admin) account. When set, callers must present it; this closes the
  /// "first request to a fresh server wins admin" exposure. Unset = no gate.
  static final String? registrationToken =
      Platform.environment['REGISTRATION_TOKEN'];

  static final int authRateLimitMax =
      int.tryParse(Platform.environment['AUTH_RATE_LIMIT_MAX'] ?? '') ?? 20;

  static final int authRateLimitWindowSeconds =
      int.tryParse(Platform.environment['AUTH_RATE_LIMIT_WINDOW'] ?? '') ?? 300;

  /// Cap on JSON request bodies (auth/sync/admin) to bound memory use.
  static final int maxJsonBodyBytes =
      int.tryParse(Platform.environment['MAX_JSON_BODY_BYTES'] ?? '') ??
          1024 * 1024;

  /// Cap on a single photo upload.
  static final int maxPhotoBytes =
      int.tryParse(Platform.environment['MAX_PHOTO_BYTES'] ?? '') ??
          15 * 1024 * 1024;

  /// Returns a human-readable error if the configuration is unsafe to serve in
  /// a non-development environment, or null if it is safe. Called once at
  /// startup so the process refuses to boot rather than run insecurely.
  static String? validate() {
    if (isDevelopment) return null;

    if (jwtSecret == defaultJwtSecret) {
      return 'JWT_SECRET is still the built-in development default. '
          'Set JWT_SECRET to a unique random value (min 32 chars) in production.';
    }
    if (jwtSecret.length < 32) {
      return 'JWT_SECRET must be at least 32 characters in production.';
    }

    final hasCerts = sslCertPath != null && sslKeyPath != null;
    if (!hasCerts && !behindProxy) {
      return 'No TLS configured. Either set SSL_CERT_PATH and SSL_KEY_PATH to '
          'serve HTTPS directly, or set BEHIND_PROXY=true when TLS is '
          'terminated by a reverse proxy (e.g. Nginx Proxy Manager).';
    }

    return null;
  }
}
