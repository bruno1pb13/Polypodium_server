import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/admin/admin_handler.dart';
import '../features/auth/i_auth_repository.dart';
import '../middleware/admin_middleware.dart';
import '../middleware/auth_middleware.dart';

Handler buildAdminHandler(
    AdminHandler admin, ITokenService tokens, IAuthRepository authRepo) {
  final adminOnly = Router()
    ..get('/status', admin.status)
    ..get('/settings', admin.getSettings)
    ..patch('/settings', admin.updateSettings)
    ..get('/users', admin.listUsers)
    ..post('/users', admin.createUser)
    ..patch('/users/<id>/role', admin.setRole)
    ..patch('/users/<id>/status', admin.setDisabled);

  final router = Router()
    // Any authenticated user can check their own role — used by the client
    // to decide whether to show admin UI.
    ..get('/me', admin.me)
    ..mount(
      '/',
      Pipeline()
          .addMiddleware(adminOnlyMiddleware())
          .addHandler(adminOnly.call),
    );

  return Pipeline()
      .addMiddleware(authMiddleware(tokens, authRepo))
      .addHandler(router.call);
}
