import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/photos/photo_handler.dart';
import '../middleware/auth_middleware.dart';

Handler buildPhotoHandler(PhotoHandler photo, ITokenService tokens) {
  final router = Router()
    ..put('/<photoKey>', photo.upload)
    ..get('/<photoKey>', photo.download);

  return Pipeline()
      .addMiddleware(authMiddleware(tokens))
      .addHandler(router.call);
}
