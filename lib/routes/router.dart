import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/admin/admin_handler.dart';
import '../features/auth/auth_handler.dart';
import '../features/auth/i_auth_repository.dart';
import '../features/photos/photo_handler.dart';
import '../features/sync/sync_handler.dart';
import 'admin_routes.dart';
import 'auth_routes.dart';
import 'photo_routes.dart';
import 'sync_routes.dart';

Router buildRouter({
  required AuthHandler auth,
  required SyncHandler sync,
  required PhotoHandler photos,
  required AdminHandler admin,
  required IAuthRepository authRepo,
  required ITokenService tokens,
}) =>
    Router()
      ..mount('/api/v1/auth/', buildAuthRouter(auth).call)
      ..mount('/api/v1/sync/', buildSyncHandler(sync, tokens))
      ..mount('/api/v1/photos/', buildPhotoHandler(photos, tokens))
      ..mount('/api/v1/admin/', buildAdminHandler(admin, tokens, authRepo))
      ..get('/api/v1/health', _health);

Response _health(Request _) => Response.ok(
      jsonEncode({'status': 'ok', 'version': '1.0.0'}),
      headers: {'Content-Type': 'application/json'},
    );
