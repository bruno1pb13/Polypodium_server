import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../features/gardens/i_garden_repository.dart';

/// Selects the garden a sync or photo request acts on.
const gardenHeader = 'X-Polypodium-Garden';

/// Runs after authMiddleware. Resolves the garden from [gardenHeader] --
/// absent or blank means the caller's personal garden, which is what every
/// client predating gardens gets -- checks that the caller belongs to it,
/// and injects `gardenId` into `request.context`. Handlers scope every query
/// by that id and never by anything read from the request themselves.
Middleware gardenMiddleware(IGardenRepository gardens) {
  return (Handler inner) {
    return (Request request) async {
      final userId = request.context['userId'] as String;
      final requested = request.headers[gardenHeader]?.trim() ?? '';

      final String gardenId;
      if (requested.isEmpty) {
        gardenId = userId;
        if (await gardens.memberRole(gardenId, userId) == null) {
          await gardens.ensurePersonalGarden(userId);
        }
      } else {
        gardenId = requested;
        if (await gardens.memberRole(gardenId, userId) == null) {
          return Response(
            403,
            body: jsonEncode({'error': 'not a member of this garden'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
      }

      return inner(request.change(context: {'gardenId': gardenId}));
    };
  };
}
