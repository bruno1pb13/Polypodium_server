import 'dart:convert';
import 'dart:io';

import 'i_mcp_token_repository.dart';

/// MCP revisions this server speaks, newest first. `initialize` echoes the
/// client's when listed, else offers the newest.
const mcpProtocolVersions = ['2025-06-18', '2025-03-26'];

/// A tool failure the model should see and can recover from (bad
/// arguments, unknown plant...). Reported as a tool result with
/// `isError: true`, not as a JSON-RPC error.
class McpToolError implements Exception {
  const McpToolError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// An image sent back to the model as MCP `image` content.
class McpImage {
  const McpImage(this.bytes, this.mimeType);
  final List<int> bytes;
  final String mimeType;
}

/// What a tool returns: JSON (sent as `structuredContent` and as text) and
/// any images, which follow the text in `content`.
class McpToolResult {
  const McpToolResult(this.data, {this.images = const []});
  final Map<String, Object?> data;
  final List<McpImage> images;
}

class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.writes = false,
    this.destructive = false,
  });

  final String name;
  final String title;
  final String description;

  /// JSON Schema of the `arguments` object.
  final Map<String, Object?> inputSchema;

  /// Whether the tool changes garden data; such tools are only offered to
  /// tokens created with `canWrite`.
  final bool writes;
  final bool destructive;

  final Future<McpToolResult> Function(
      McpGrant grant, Map<String, Object?> args) run;

  bool availableTo(McpGrant grant) => !writes || grant.canWrite;

  Map<String, Object?> describe() => {
        'name': name,
        'title': title,
        'description': description,
        'inputSchema': inputSchema,
        'annotations': {
          'title': title,
          'readOnlyHint': !writes,
          if (writes) 'destructiveHint': destructive,
          'openWorldHint': false,
        },
      };
}

/// The JSON-RPC side of MCP, independent of the HTTP transport: takes one
/// decoded message and returns the response to send, or null for
/// notifications and client responses. Stateless -- every request carries
/// its token, so there is no session to keep.
class McpServer {
  McpServer(List<McpTool> tools, {required this.version, this.instructions})
      : _tools = {for (final t in tools) t.name: t};

  final Map<String, McpTool> _tools;
  final String version;
  final String? instructions;

  Future<Map<String, Object?>?> handle(Object? message, McpGrant grant) async {
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _error(null, -32600, 'invalid JSON-RPC message');
    }
    final id = message['id'];
    final method = message['method'];
    // A response to a server request (we send none) or a notification.
    if (method is! String) {
      return id == null ? _error(null, -32600, 'missing method') : null;
    }
    if (id == null) return null;
    final rawParams = message['params'];
    if (rawParams != null && rawParams is! Map<String, Object?>) {
      return _error(id, -32602, 'params must be an object');
    }
    final params = (rawParams as Map<String, Object?>?) ?? const {};

    switch (method) {
      case 'initialize':
        return _result(id, _initialize(params));
      case 'ping':
        return _result(id, const {});
      case 'tools/list':
        return _result(id, {
          'tools': [
            for (final tool in _tools.values)
              if (tool.availableTo(grant)) tool.describe(),
          ],
        });
      case 'tools/call':
        return _callTool(id, params, grant);
      default:
        return _error(id, -32601, 'method not found: $method');
    }
  }

  Map<String, Object?> _initialize(Map<String, Object?> params) {
    final requested = params['protocolVersion'];
    return {
      'protocolVersion': mcpProtocolVersions.contains(requested)
          ? requested
          : mcpProtocolVersions.first,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {
        'name': 'polypodium',
        'title': 'Polypodium',
        'version': version,
      },
      if (instructions != null) 'instructions': instructions,
    };
  }

  Future<Map<String, Object?>> _callTool(
      Object id, Map<String, Object?> params, McpGrant grant) async {
    final name = params['name'];
    final tool = _tools[name];
    if (tool == null || !tool.availableTo(grant)) {
      return _error(id, -32602, 'unknown tool: $name');
    }
    final args = params['arguments'] ?? const <String, Object?>{};
    if (args is! Map<String, Object?>) {
      return _error(id, -32602, 'arguments must be an object');
    }
    try {
      final result = await tool.run(grant, args);
      return _result(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(result.data)},
          for (final image in result.images)
            {
              'type': 'image',
              'data': base64Encode(image.bytes),
              'mimeType': image.mimeType,
            },
        ],
        'structuredContent': result.data,
        'isError': false,
      });
    } on McpToolError catch (e) {
      return _result(id, {
        'content': [
          {'type': 'text', 'text': e.message},
        ],
        'isError': true,
      });
    } catch (e, stack) {
      stderr.writeln('[MCP] tool $name failed: $e');
      stderr.writeln(stack);
      return _error(id, -32603, 'internal error');
    }
  }

  static Map<String, Object?> _result(Object id, Object result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}
