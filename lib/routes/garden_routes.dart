import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/auth/i_auth_repository.dart';
import '../features/gardens/garden_handler.dart';
import '../middleware/auth_middleware.dart';

Handler buildGardenHandler(
    GardenHandler gardens, ITokenService tokens, IAuthRepository authRepo) {
  final router = Router()
    ..get('/', gardens.list)
    ..post('/', gardens.create)
    ..patch('/<id>', gardens.rename)
    ..get('/<id>/members', gardens.members)
    ..post('/<id>/members', gardens.addMember)
    ..delete('/<id>/members/<userId>', gardens.removeMember);

  return Pipeline()
      .addMiddleware(authMiddleware(tokens, authRepo))
      .addHandler(router.call);
}
