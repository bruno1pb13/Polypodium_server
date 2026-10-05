import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/auth/i_auth_repository.dart';
import '../features/gardens/i_garden_repository.dart';
import '../features/photos/photo_handler.dart';
import '../middleware/auth_middleware.dart';
import '../middleware/garden_middleware.dart';

Handler buildPhotoHandler(
    PhotoHandler photo, ITokenService tokens, IAuthRepository authRepo,
    IGardenRepository gardens) {
  final router = Router()
    ..put('/<photoKey>', photo.upload)
    ..get('/<photoKey>', photo.download);

  return Pipeline()
      .addMiddleware(authMiddleware(tokens, authRepo))
      .addMiddleware(gardenMiddleware(gardens))
      .addHandler(router.call);
}
