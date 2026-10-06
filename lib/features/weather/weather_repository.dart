import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'weather_models.dart';

/// Today in the region's own timezone (dates and hours are stored as the
/// region's local wall-clock values), for a query that has `r` bound to
/// weather_regions.
const _regionToday =
    "(NOW() AT TIME ZONE COALESCE(r.timezone, 'UTC'))::date";

class WeatherRepository {
  const WeatherRepository(this._db);
  final Pool _db;

  Pool get db => _db;

  Future<List<WeatherRegion>> listRegions() async {
    final result = await _db.execute(Sql('''
      SELECT id, latitude, longitude, timezone, elevation, last_fetched_at,
             last_attempt_at, last_used_at, last_error
      FROM weather_regions
      ORDER BY created_at, id
    '''));
    return [
      for (final row in result)
        WeatherRegion(
          id: row[0] as String,
          latitude: row[1] as double,
          longitude: row[2] as double,
          timezone: row[3] as String?,
          elevation: row[4] as double?,
          lastFetchedAt: row[5] as DateTime?,
          lastAttemptAt: row[6] as DateTime?,
          lastUsedAt: row[7] as DateTime?,
          lastError: row[8] as String?,
        )
    ];
  }

  Future<void> createRegion(String id, double latitude, double longitude) =>
      _db.execute(
        Sql.named('''
          INSERT INTO weather_regions (id, latitude, longitude)
          VALUES (@id, @lat, @lon)
        '''),
        parameters: {'id': id, 'lat': latitude, 'lon': longitude},
      );

  /// Marks regions as still near some location, which keeps them (and their
  /// history) from being pruned as idle.
  Future<void> touchRegions(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await _db.execute(
      Sql.named('''
        UPDATE weather_regions SET last_used_at = NOW()
        WHERE id = ANY(@ids::text[])
      '''),
      parameters: {'ids': ids.toList()},
    );
  }

  /// Every distinct coordinate of a live location, across all gardens.
  Future<List<({double latitude, double longitude})>>
      locationCoordinates() async {
    final result = await _db.execute(Sql('''
      SELECT DISTINCT (payload->>'latitude')::float8,
                      (payload->>'longitude')::float8
      FROM mat_locations
      WHERE deleted_at IS NULL
        AND jsonb_typeof(payload->'latitude') = 'number'
        AND jsonb_typeof(payload->'longitude') = 'number'
    '''));
    return [
      for (final row in result)
        (latitude: row[0] as double, longitude: row[1] as double)
    ];
  }

  /// The live location's coordinates; `found: false` when the garden has no
  /// such location, null coordinates when it has none set.
  Future<({bool found, double? latitude, double? longitude})> locationInGarden(
      String gardenId, String locationId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT
          CASE WHEN jsonb_typeof(payload->'latitude') = 'number'
               THEN (payload->>'latitude')::float8 END,
          CASE WHEN jsonb_typeof(payload->'longitude') = 'number'
               THEN (payload->>'longitude')::float8 END
        FROM mat_locations
        WHERE garden_id = @gardenId AND entity_id = @locationId
          AND deleted_at IS NULL
      '''),
      parameters: {'gardenId': gardenId, 'locationId': locationId},
    );
    if (result.isEmpty) {
      return (found: false, latitude: null, longitude: null);
    }
    return (
      found: true,
      latitude: result.first[0] as double?,
      longitude: result.first[1] as double?,
    );
  }

  /// Stores a fresh forecast. Rows already present (overlapping past days
  /// and earlier forecasts for the same hours/dates) are overwritten, so the
  /// latest fetch -- closest to what actually happened -- always wins.
  Future<void> saveForecast(String regionId, WeatherForecast forecast) =>
      _db.runTx((tx) async {
        if (forecast.hourly.isNotEmpty) {
          await tx.execute(
            Sql.named('''
              INSERT INTO weather_hourly (region_id, time, temperature,
                humidity, precipitation, precipitation_probability,
                weather_code, wind_speed)
              SELECT @regionId, r.time::timestamp, r.temperature, r.humidity,
                     r.precipitation, r."precipitationProbability",
                     r."weatherCode", r."windSpeed"
              FROM jsonb_to_recordset(@rows::jsonb) AS r(
                time text, temperature float8, humidity float8,
                precipitation float8, "precipitationProbability" float8,
                "weatherCode" int, "windSpeed" float8)
              ON CONFLICT (region_id, time) DO UPDATE SET
                temperature = EXCLUDED.temperature,
                humidity = EXCLUDED.humidity,
                precipitation = EXCLUDED.precipitation,
                precipitation_probability = EXCLUDED.precipitation_probability,
                weather_code = EXCLUDED.weather_code,
                wind_speed = EXCLUDED.wind_speed
            '''),
            parameters: {
              'regionId': regionId,
              'rows': jsonEncode([for (final h in forecast.hourly) h.toJson()]),
            },
          );
        }
        if (forecast.daily.isNotEmpty) {
          await tx.execute(
            Sql.named('''
              INSERT INTO weather_daily (region_id, date, weather_code,
                temperature_max, temperature_min, precipitation_sum,
                precipitation_probability_max, wind_speed_max, et0)
              SELECT @regionId, r.date::date, r."weatherCode",
                     r."temperatureMax", r."temperatureMin",
                     r."precipitationSum", r."precipitationProbabilityMax",
                     r."windSpeedMax", r.et0
              FROM jsonb_to_recordset(@rows::jsonb) AS r(
                date text, "weatherCode" int, "temperatureMax" float8,
                "temperatureMin" float8, "precipitationSum" float8,
                "precipitationProbabilityMax" float8, "windSpeedMax" float8,
                et0 float8)
              ON CONFLICT (region_id, date) DO UPDATE SET
                weather_code = EXCLUDED.weather_code,
                temperature_max = EXCLUDED.temperature_max,
                temperature_min = EXCLUDED.temperature_min,
                precipitation_sum = EXCLUDED.precipitation_sum,
                precipitation_probability_max =
                  EXCLUDED.precipitation_probability_max,
                wind_speed_max = EXCLUDED.wind_speed_max,
                et0 = EXCLUDED.et0
            '''),
            parameters: {
              'regionId': regionId,
              'rows': jsonEncode([for (final d in forecast.daily) d.toJson()]),
            },
          );
        }
        await tx.execute(
          Sql.named('''
            UPDATE weather_regions SET
              -- Only a name Postgres knows: anything else would make
              -- every AT TIME ZONE query on this region fail.
              timezone = COALESCE(
                (SELECT name FROM pg_timezone_names WHERE name = @timezone),
                timezone),
              elevation = COALESCE(@elevation, elevation),
              last_fetched_at = NOW(),
              last_attempt_at = NOW(),
              last_error = NULL
            WHERE id = @regionId
          '''),
          parameters: {
            'regionId': regionId,
            'timezone': forecast.timezone,
            'elevation': forecast.elevation,
          },
        );
      });

  Future<void> recordFailure(String regionId, String error) => _db.execute(
        Sql.named('''
          UPDATE weather_regions
          SET last_attempt_at = NOW(), last_error = @error
          WHERE id = @regionId
        '''),
        parameters: {
          'regionId': regionId,
          'error': error.length > 500 ? error.substring(0, 500) : error,
        },
      );

  /// Thins stored data as it ages: hourly detail only for the last few days,
  /// daily detail for [WeatherOptions.dailyRetentionDays], monthly summaries
  /// after that. Regions nobody has been near for a while go entirely.
  Future<void> housekeeping(WeatherOptions options) => _db.runTx((tx) async {
        await tx.execute(
          Sql.named('''
            DELETE FROM weather_regions
            WHERE last_used_at < NOW() - make_interval(days => @idleDays)
          '''),
          parameters: {'idleDays': options.regionIdleDays},
        );

        await tx.execute(
          Sql.named('''
            DELETE FROM weather_hourly h USING weather_regions r
            WHERE r.id = h.region_id
              AND h.time < $_regionToday - make_interval(days => @days)
          '''),
          parameters: {'days': options.hourlyPastDays},
        );

        // Recomputed every run for each complete month still held in daily
        // detail, so the summary always reflects the latest corrections.
        // Daily rows are only ever dropped a whole month at a time (below),
        // so a month is never re-summarized from a partial set of days.
        await tx.execute(Sql('''
          INSERT INTO weather_monthly (region_id, month, days,
            temperature_max_avg, temperature_min_avg, temperature_max,
            temperature_min, precipitation_sum, rainy_days, et0_sum)
          SELECT d.region_id, date_trunc('month', d.date)::date, COUNT(*),
                 AVG(d.temperature_max), AVG(d.temperature_min),
                 MAX(d.temperature_max), MIN(d.temperature_min),
                 SUM(d.precipitation_sum),
                 COUNT(*) FILTER (WHERE d.precipitation_sum >= 1),
                 SUM(d.et0)
          FROM weather_daily d
          JOIN weather_regions r ON r.id = d.region_id
          WHERE d.date < date_trunc('month', $_regionToday)
          GROUP BY 1, 2
          ON CONFLICT (region_id, month) DO UPDATE SET
            days = EXCLUDED.days,
            temperature_max_avg = EXCLUDED.temperature_max_avg,
            temperature_min_avg = EXCLUDED.temperature_min_avg,
            temperature_max = EXCLUDED.temperature_max,
            temperature_min = EXCLUDED.temperature_min,
            precipitation_sum = EXCLUDED.precipitation_sum,
            rainy_days = EXCLUDED.rainy_days,
            et0_sum = EXCLUDED.et0_sum
        '''));

        // Keeps the month the cutoff falls in whole.
        await tx.execute(
          Sql.named('''
            DELETE FROM weather_daily d USING weather_regions r
            WHERE r.id = d.region_id
              AND d.date < date_trunc('month',
                    $_regionToday - make_interval(days => @days))
          '''),
          parameters: {'days': options.dailyRetentionDays},
        );
      });

  Future<List<Map<String, Object?>>> hourly(String regionId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT to_char(time, 'YYYY-MM-DD"T"HH24:MI'), temperature, humidity,
               precipitation, precipitation_probability, weather_code,
               wind_speed
        FROM weather_hourly WHERE region_id = @regionId
        ORDER BY time
      '''),
      parameters: {'regionId': regionId},
    );
    return [
      for (final row in result)
        HourlyWeather(
          time: row[0] as String,
          temperature: row[1] as double?,
          humidity: row[2] as double?,
          precipitation: row[3] as double?,
          precipitationProbability: row[4] as double?,
          weatherCode: row[5] as int?,
          windSpeed: row[6] as double?,
        ).toJson()
    ];
  }

  /// Daily rows from [pastDays] before the region's today through the end of
  /// the forecast.
  Future<List<Map<String, Object?>>> daily(
      String regionId, int pastDays) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT to_char(d.date, 'YYYY-MM-DD'), d.weather_code,
               d.temperature_max, d.temperature_min, d.precipitation_sum,
               d.precipitation_probability_max, d.wind_speed_max, d.et0
        FROM weather_daily d
        JOIN weather_regions r ON r.id = d.region_id
        WHERE d.region_id = @regionId
          AND d.date >= $_regionToday - make_interval(days => @pastDays)
        ORDER BY d.date
      '''),
      parameters: {'regionId': regionId, 'pastDays': pastDays},
    );
    return [
      for (final row in result)
        DailyWeather(
          date: row[0] as String,
          weatherCode: row[1] as int?,
          temperatureMax: row[2] as double?,
          temperatureMin: row[3] as double?,
          precipitationSum: row[4] as double?,
          precipitationProbabilityMax: row[5] as double?,
          windSpeedMax: row[6] as double?,
          et0: row[7] as double?,
        ).toJson()
    ];
  }

  /// The last [months] complete months, oldest first.
  Future<List<Map<String, Object?>>> monthly(
      String regionId, int months) async {
    if (months <= 0) return const [];
    final result = await _db.execute(
      Sql.named('''
        SELECT * FROM (
          SELECT to_char(month, 'YYYY-MM'), days, temperature_max_avg,
                 temperature_min_avg, temperature_max, temperature_min,
                 precipitation_sum, rainy_days, et0_sum, month
          FROM weather_monthly WHERE region_id = @regionId
          ORDER BY month DESC LIMIT @months
        ) m ORDER BY m.month
      '''),
      parameters: {'regionId': regionId, 'months': months},
    );
    return [
      for (final row in result)
        {
          'month': row[0] as String,
          'days': row[1] as int,
          'temperatureMaxAvg': row[2] as double?,
          'temperatureMinAvg': row[3] as double?,
          'temperatureMax': row[4] as double?,
          'temperatureMin': row[5] as double?,
          'precipitationSum': row[6] as double?,
          'rainyDays': row[7] as int,
          'et0Sum': row[8] as double?,
        }
    ];
  }
}
