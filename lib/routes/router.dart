import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/auth/auth_handler.dart';
import '../features/sync/sync_handler.dart';
import 'auth_routes.dart';
import 'sync_routes.dart';

Router buildRouter({
  required AuthHandler auth,
  required SyncHandler sync,
  required ITokenService tokens,
}) =>
    Router()
      ..mount('/api/v1/auth/', buildAuthRouter(auth).call)
      ..mount('/api/v1/sync/', buildSyncHandler(sync, tokens))
      ..get('/health', _health);

Response _health(Request _) => Response.ok(
      jsonEncode({'status': 'ok', 'version': '1.0.0'}),
      headers: {'Content-Type': 'application/json'},
    );
