import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:polypodium_server/core/config.dart';
import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/auth_repository.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';
import 'package:polypodium_server/features/sync/sync_repository.dart';
import 'package:polypodium_server/middleware/cors_middleware.dart';
import 'package:polypodium_server/middleware/error_middleware.dart';
import 'package:polypodium_server/routes/router.dart';
import 'package:polypodium_server/server/ssl.dart';

void main() async {
  final pool = await initDatabase();
  print('Database connected and migrations applied.');

  final photosDir = Directory(Config.photosDir);
  if (!photosDir.existsSync()) await photosDir.create(recursive: true);

  final tokens = JwtTokenService(Config.jwtSecret);
  final router = buildRouter(
    auth: AuthHandler(AuthRepository(pool), tokens),
    sync: SyncHandler(SyncRepository(pool)),
    photos: PhotoHandler(Config.photosDir),
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
}
