/// The water balance behind the weather-adjusted watering lives in
/// polypodium_core, so the app computes the local workspace's the same way.
library;

export 'package:polypodium_core/weather.dart'
    show
        WateringAdvice,
        WateringReason,
        WateringRules,
        WeatherDay,
        adviseWatering,
        dateKey;
