INSERT INTO stations (station_name, lat, lon) VALUES
  ('Field A - West', 40.4237, -86.9212),
  ('Field A - East', 40.4238, -86.9190),
  ('Field B - North', 40.4290, -86.9200),
  ('Field B - South', 40.4180, -86.9205),
  ('Demo Plot', 40.4210, -86.9230)
ON CONFLICT (station_name) DO NOTHING;

WITH t AS (
  SELECT generate_series(
    date_trunc('minute', now()) - interval '14 days',
    date_trunc('minute', now()),
    interval '15 minutes'
  ) AS ts
),
s AS (
  SELECT station_id FROM stations
),
base AS (
  SELECT
    t.ts,
    s.station_id,
    0.22
      + (s.station_id * 0.01)
      + 0.03 * sin(extract(epoch from t.ts) / 86400.0 * 2 * pi())
      - 0.015 * (extract(hour from t.ts)::double precision / 24.0) AS soil_base,
    16
      + 8 * sin((extract(hour from t.ts)::double precision / 24.0) * 2 * pi())
      + (s.station_id * 0.3) AS air_temp_c,
    68
      - 12 * sin((extract(hour from t.ts)::double precision / 24.0) * 2 * pi())
      + (s.station_id * 0.4) AS humidity_percent,
    CASE
      WHEN (extract(day from t.ts)::int % 3 = 0) AND (extract(hour from t.ts)::int IN (2, 3)) THEN 1.5
      WHEN (extract(day from t.ts)::int % 5 = 0) AND (extract(hour from t.ts)::int = 18) THEN 2.0
      ELSE 0.0
    END AS rainfall_mm
  FROM t
  CROSS JOIN s
)
INSERT INTO measurements (ts, station_id, soil_moisture, air_temp_c, humidity_percent, rainfall_mm)
SELECT
  ts,
  station_id,
  GREATEST(0.05, LEAST(0.60, soil_base + (rainfall_mm / 20.0))) AS soil_moisture,
  air_temp_c,
  GREATEST(20.0, LEAST(100.0, humidity_percent)) AS humidity_percent,
  rainfall_mm
FROM base
ON CONFLICT (ts, station_id) DO NOTHING;
