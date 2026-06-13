import 'dart:io';

import '../core/config.dart';

SecurityContext? buildSslContext() {
  if (Config.isDevelopment) return null;

  if (Config.sslCertPath == null || Config.sslKeyPath == null) {
    print('Warning: production mode but SSL certificates not provided. Running on HTTP.');
    return null;
  }

  print('SSL configured using certificate: ${Config.sslCertPath}');
  return SecurityContext()
    ..useCertificateChain(Config.sslCertPath!)
    ..usePrivateKey(Config.sslKeyPath!);
}
