import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import 'i_mcp_token_repository.dart';
import 'mcp_server.dart';

/// The MCP Streamable HTTP transport, reduced to what a stateless,
/// tools-only server needs: every JSON-RPC message is a POST answered with
/// plain JSON. There are no sessions and no server-initiated messages, so
/// the optional SSE stream (GET) isn't offered.
class McpHandler {
  const McpHandler(this._server);
  final McpServer _server;

  Future<Response> post(Request request) async {
    final version = request.headers['mcp-protocol-version'];
    if (version != null && !mcpProtocolVersions.contains(version)) {
      return _rpcError(400, -32600, 'unsupported MCP-Protocol-Version: $version');
    }
    final grant = request.context['mcpGrant'] as McpGrant;

    final bytes = await readBodyCapped(request, Config.maxJsonBodyBytes);
    final Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return _rpcError(400, -32700, 'parse error');
    }

    // Batches were part of the 2025-03-26 revision; still answered.
    if (message is List) {
      final responses = [
        for (final m in message) await _server.handle(m, grant),
      ].whereType<Map<String, Object?>>().toList();
      return responses.isEmpty ? Response(202) : _json(200, responses);
    }
    final response = await _server.handle(message, grant);
    return response == null ? Response(202) : _json(200, response);
  }

  /// GET would open a server-to-client SSE stream, DELETE end a session;
  /// this server has neither.
  Response notAllowed(Request request) => Response(
        405,
        headers: {'Allow': 'POST'},
      );
}

Response _rpcError(int status, int code, String message) => _json(status, {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': code, 'message': message},
    });

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );
