import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../features/mcp/i_mcp_token_repository.dart';
import '../features/mcp/mcp_handler.dart';
import '../middleware/mcp_auth_middleware.dart';

Handler buildMcpHandler(McpHandler mcp, IMcpTokenRepository tokens) {
  final router = Router()
    ..post('/', mcp.post)
    ..get('/', mcp.notAllowed)
    ..delete('/', mcp.notAllowed);

  return Pipeline()
      .addMiddleware(mcpAuthMiddleware(tokens))
      .addHandler(router.call);
}
