CREATE TABLE IF NOT EXISTS stations (
  station_id SERIAL PRIMARY KEY,
  station_name TEXT NOT NULL UNIQUE,
  lat DOUBLE PRECISION NOT NULL,
  lon DOUBLE PRECISION NOT NULL
);

CREATE TABLE IF NOT EXISTS measurements (
  ts TIMESTAMPTZ NOT NULL,
  station_id INT NOT NULL REFERENCES stations(station_id),
  soil_moisture DOUBLE PRECISION NOT NULL,
  air_temp_c DOUBLE PRECISION NOT NULL,
  humidity_percent DOUBLE PRECISION NOT NULL,
  rainfall_mm DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ts, station_id)
);

SELECT create_hypertable('measurements', 'ts', if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_measurements_station_ts
  ON measurements (station_id, ts DESC);
