import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/config.dart';
import '../core/token_service.dart';
import '../features/admin/admin_handler.dart';
import '../features/auth/auth_handler.dart';
import '../features/auth/i_auth_repository.dart';
import '../features/gardens/garden_handler.dart';
import '../features/gardens/i_garden_repository.dart';
import '../features/photos/photo_handler.dart';
import '../features/sync/sync_handler.dart';
import '../middleware/rate_limit_middleware.dart';
import 'admin_routes.dart';
import 'auth_routes.dart';
import 'garden_routes.dart';
import 'photo_routes.dart';
import 'sync_routes.dart';

Router buildRouter({
  required AuthHandler auth,
  required SyncHandler sync,
  required PhotoHandler photos,
  required AdminHandler admin,
  required GardenHandler gardens,
  required IGardenRepository gardenRepo,
  required IAuthRepository authRepo,
  required ITokenService tokens,
}) {
  // Rate-limit the unauthenticated auth surface (login/register/status) to
  // blunt credential brute-force and registration abuse.
  final authPipeline = Pipeline()
      .addMiddleware(rateLimitMiddleware(
        maxRequests: Config.authRateLimitMax,
        window: Duration(seconds: Config.authRateLimitWindowSeconds),
        behindProxy: Config.behindProxy,
      ))
      .addHandler(buildAuthRouter(auth).call);

  return Router()
    ..mount('/api/v1/auth/', authPipeline)
    ..mount('/api/v1/sync/', buildSyncHandler(sync, tokens, authRepo, gardenRepo))
    ..mount('/api/v1/photos/', buildPhotoHandler(photos, tokens, authRepo, gardenRepo))
    ..mount('/api/v1/gardens', buildGardenHandler(gardens, tokens, authRepo))
    ..mount('/api/v1/admin/', buildAdminHandler(admin, tokens, authRepo))
    ..get('/api/v1/health', _health);
}

Response _health(Request _) => Response.ok(
      jsonEncode({'status': 'ok', 'version': '1.0.0'}),
      headers: {'Content-Type': 'application/json'},
    );
