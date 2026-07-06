import 'package:shelf_router/shelf_router.dart';

import '../features/auth/auth_handler.dart';

Router buildAuthRouter(AuthHandler auth) => Router()
  ..get('/status', auth.status)
  ..post('/register', auth.register)
  ..post('/login', auth.login);
