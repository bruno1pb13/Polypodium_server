import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../features/admin/i_settings_repository.dart';

/// Answers 404 for the whole MCP endpoint while admins keep MCP off (the
/// default), before any token is looked at.
Middleware mcpEnabledMiddleware(ISettingsRepository settings) {
  return (Handler inner) {
    return (Request request) async {
      if (!await settings.getBool(settingMcpEnabled, defaultValue: false)) {
        return Response(
          404,
          body: jsonEncode(
              {'error': 'MCP is disabled on this server', 'code': 'mcp_disabled'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      return inner(request);
    };
  };
}
