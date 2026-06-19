import 'dart:io';

class Config {
  static final String environment = Platform.environment['APP_ENV'] ?? 'development';
  static bool get isDevelopment => environment == 'development';

  static final String? sslCertPath = Platform.environment['SSL_CERT_PATH'];
  static final String? sslKeyPath = Platform.environment['SSL_KEY_PATH'];

  static final String databaseUrl = Platform.environment['DATABASE_URL'] ??
      'postgresql://postgres:postgres@localhost/polypodium';

  static final String jwtSecret = Platform.environment['JWT_SECRET'] ??
      'dev-secret-change-in-production-min-32-chars!!';

  static final bool dbSsl = (Platform.environment['DB_SSL'] ?? (isDevelopment ? 'false' : 'true')) == 'true';

  static final int port =
      int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  static final String allowedOrigins =
      Platform.environment['ALLOWED_ORIGINS'] ?? '*';

  static final String photosDir =
      Platform.environment['PHOTOS_DIR'] ?? './photos';
}
