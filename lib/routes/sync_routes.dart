import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/token_service.dart';
import '../features/sync/sync_handler.dart';
import '../middleware/auth_middleware.dart';

Handler buildSyncHandler(SyncHandler sync, ITokenService tokens) {
  final router = Router()
    ..get('/changes', sync.changes)
    ..post('/receive', sync.receive)
    ..post('/ack', sync.ack)
    ..get('/status', sync.status);

  return Pipeline()
      .addMiddleware(authMiddleware(tokens))
      .addHandler(router.call);
}
