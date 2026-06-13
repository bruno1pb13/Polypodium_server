import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:polypodium_server/config.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';
import 'package:polypodium_server/middleware/auth_middleware.dart';
import 'package:polypodium_server/middleware/cors_middleware.dart';
import 'package:polypodium_server/middleware/error_middleware.dart';

void main() async {
  await initDatabase();
  print('Database connected and migrations applied.');

  final auth = AuthHandler();
  final sync = SyncHandler();

  final authRouter = Router()
    ..post('/register', auth.register)
    ..post('/login', auth.login);

  final syncRouter = Router()
    ..post('/push', sync.push)
    ..get('/pull', sync.pull)
    ..post('/ack', sync.ack)
    ..get('/status', sync.status);

  final protectedSync = Pipeline()
      .addMiddleware(authMiddleware())
      .addHandler(syncRouter.call);

  final router = Router()
    ..mount('/api/v1/auth/', authRouter.call)
    ..mount('/api/v1/sync/', protectedSync)
    ..get('/health', _health);

  final handler = Pipeline()
      .addMiddleware(errorMiddleware())
      .addMiddleware(corsMiddleware())
      .addMiddleware(logRequests())
      .addHandler(router.call);

  SecurityContext? context;
  if (!Config.isDevelopment) {
    if (Config.sslCertPath != null && Config.sslKeyPath != null) {
      context = SecurityContext()
        ..useCertificateChain(Config.sslCertPath!)
        ..usePrivateKey(Config.sslKeyPath!);
      print('SSL configured using certificate: ${Config.sslCertPath}');
    } else {
      print('Warning: Production mode but SSL certificates not provided. Running on HTTP.');
    }
  }

  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    Config.port,
    securityContext: context,
  );

  final scheme = context != null ? 'https' : 'http';
  print('Polypodium server listening on $scheme://0.0.0.0:${server.port}');
}

Response _health(Request _) => Response.ok(
      jsonEncode({'status': 'ok', 'version': '1.0.0'}),
      headers: {'Content-Type': 'application/json'},
    );
