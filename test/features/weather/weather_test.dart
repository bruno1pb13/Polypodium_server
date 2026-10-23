import 'package:test/test.dart';

import 'package:polypodium_server/features/weather/weather_models.dart';

// distanceKm, isValidCoordinate, parseOpenMeteo and adviseWatering are
// tested in polypodium_core.
void main() {
  group('nearestRegion', () {
    const a = WeatherRegion(id: 'a', latitude: -23.50, longitude: -46.60);
    const b = WeatherRegion(id: 'b', latitude: -23.52, longitude: -46.60);

    test('picks the closest region within the radius', () {
      expect(nearestRegion([a, b], -23.515, -46.60, 5)?.id, 'b');
    });

    test('returns null when every region is farther than the radius', () {
      expect(nearestRegion([a, b], -22.0, -46.60, 5), isNull);
    });
  });
}
