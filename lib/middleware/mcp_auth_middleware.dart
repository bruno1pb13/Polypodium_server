import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../features/mcp/i_mcp_token_repository.dart';

/// Authenticates the MCP endpoint with a garden-bound MCP token (not the
/// app's JWT) and injects its [McpGrant] as `mcpGrant`. The token alone
/// selects the garden: there is no garden header to get wrong.
Middleware mcpAuthMiddleware(IMcpTokenRepository tokens) {
  return (Handler inner) {
    return (Request request) async {
      final header =
          request.headers['Authorization'] ?? request.headers['authorization'];
      if (header == null || !header.startsWith('Bearer ')) {
        return _unauthorized('missing or invalid Authorization header');
      }
      final grant = await tokens.resolve(header.substring(7).trim());
      if (grant == null) return _unauthorized('invalid or revoked MCP token');
      return inner(request.change(context: {'mcpGrant': grant}));
    };
  };
}

Response _unauthorized(String message) => Response(
      401,
      body: jsonEncode({'error': message}),
      headers: {
        'Content-Type': 'application/json',
        'WWW-Authenticate': 'Bearer realm="polypodium-mcp"',
      },
    );
