import 'dart:io';

import '../core/config.dart';

SecurityContext? buildSslContext() {
  if (Config.isDevelopment) return null;

  if (Config.sslCertPath == null || Config.sslKeyPath == null) {
    // Reaching here in production is only allowed when BEHIND_PROXY=true
    // (enforced by Config.validate() at startup): TLS terminates at the
    // reverse proxy, so the app intentionally serves HTTP on the private link.
    return null;
  }

  print('SSL configured using certificate: ${Config.sslCertPath}');
  return SecurityContext()
    ..useCertificateChain(Config.sslCertPath!)
    ..usePrivateKey(Config.sslKeyPath!);
}
