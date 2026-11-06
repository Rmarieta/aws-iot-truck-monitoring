-- ===========================================================================
-- Cold-chain stream detectors (Flink SQL, Managed Service for Apache Flink)
--
-- Reads raw telemetry from the input Kinesis stream and runs TWO stateful,
-- windowed detectors that a plain Lambda could not express cleanly, writing
-- both kinds of verdict to ONE shared output stream discriminated by a `type`
-- field (the industry "one event stream, polymorphic payload" pattern — the
-- per-type split happens downstream at EventBridge, not here):
--
--   type = 'excursion'           temperature stayed above the cargo threshold
--                                for the WHOLE window (sustained, not a spike).
--   type = 'battery_low_moving'  battery stayed under 20% for the whole window
--                                AND the truck kept moving (position changing)
--                                — an electric truck at risk of losing its
--                                reefer power while still on the road.
--
-- Both need state across time (a window) and, for the battery case, a derived
-- geospatial condition computed across the window's points — exactly what
-- stream windowing is for.
--
-- Placeholders ${...} are substituted at deploy time from Terraform.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Source: raw telemetry. event_time + WATERMARK make this EVENT-TIME
-- processing — windows are decided by the reading's own timestamp, tolerating
-- out-of-order / late arrivals up to 30s.
--
-- NULL-SAFE event_time: a record with a missing/malformed `ts` — notably the
-- MQTT Last-Will "offline_ungraceful" message, which has NO `ts` field and is
-- republished to the same telemetry topic the IoT rule forwards to Kinesis —
-- makes TO_TIMESTAMP(...) return NULL. A NULL rowtime throws
-- "RowTime field should not be null" in the WatermarkAssigner and crash-loops
-- the ENTIRE job. COALESCE pins such a record to epoch 0 (1970-01-01) so the
-- row is non-null (never crashes) and is harmless: it is a far-past timestamp
-- that falls outside every live window and is dropped as late data, while a
-- real reading always parses to its true time.
--
-- initpos = LATEST: start at the stream tip on restart. TRIM_HORIZON replays
-- the full 24h retention every restart, so one poison record already in the
-- backlog would crash-loop forever before COALESCE could even help a future
-- record. LATEST skips the existing backlog; COALESCE guards new records.
-- ---------------------------------------------------------------------------
CREATE TABLE readings (
    device_id      STRING,
    cargo_type     STRING,
    temperature_c  DOUBLE,
    lat            DOUBLE,
    lon            DOUBLE,
    battery_pct    DOUBLE,
    `ts`           STRING,
    -- Handle 'Z' and '+00:00' suffixes, truncate sub-second precision.
    -- COALESCE to epoch 0 so a malformed/absent `ts` can never be NULL.
    event_time     AS COALESCE(
                        TO_TIMESTAMP(SUBSTRING(REPLACE(REPLACE(REPLACE(`ts`, 'T', ' '), 'Z', ''), '+00:00', ''), 1, 19)),
                        TIMESTAMP '1970-01-01 00:00:00'
                     ),
    WATERMARK FOR event_time AS event_time - INTERVAL '30' SECOND
) WITH (
    'connector'                       = 'kinesis',
    'stream'                          = '${input_stream}',
    'aws.region'                      = '${region}',
    'scan.stream.initpos'             = 'LATEST',
    'format'                          = 'json',
    'json.timestamp-format.standard'  = 'ISO-8601'
);

-- ---------------------------------------------------------------------------
-- Sink: detected conditions, written to a second Kinesis stream that a small
-- Lambda forwards onto EventBridge. ONE stream carries both event types,
-- distinguished by `type`; subtype-specific columns are null for the other
-- type (an envelope with a discriminator — avoids "topic explosion" while the
-- events share producer, schema family, volume and consumer).
-- ---------------------------------------------------------------------------
CREATE TABLE excursions (
    `type`        STRING,
    device_id     STRING,
    cargo_type    STRING,
    window_start  TIMESTAMP(3),
    window_end    TIMESTAMP(3),
    -- excursion-specific
    min_temp_c    DOUBLE,
    max_temp_c    DOUBLE,
    -- battery_low_moving-specific
    max_battery_pct  DOUBLE,
    position_spread  DOUBLE,
    sample_count  BIGINT
) WITH (
    'connector'   = 'kinesis',
    'stream'      = '${output_stream}',
    'aws.region'  = '${region}',
    'format'      = 'json'
);

-- ---------------------------------------------------------------------------
-- Detector 1 — temperature excursion. TUMBLE = fixed, non-overlapping windows
-- of ${window} minutes per device. The HAVING clause fires only when the
-- window's MINIMUM temp is still above threshold — meaning it was over the
-- limit for the entire window, not just a momentary spike. Per-cargo thresholds.
-- ---------------------------------------------------------------------------
INSERT INTO excursions
SELECT
    'excursion'        AS `type`,
    device_id,
    cargo_type,
    TUMBLE_START(event_time, INTERVAL '${window}' MINUTE) AS window_start,
    TUMBLE_END(event_time,   INTERVAL '${window}' MINUTE) AS window_end,
    MIN(temperature_c) AS min_temp_c,
    MAX(temperature_c) AS max_temp_c,
    CAST(NULL AS DOUBLE) AS max_battery_pct,
    CAST(NULL AS DOUBLE) AS position_spread,
    COUNT(*)           AS sample_count
FROM readings
GROUP BY
    device_id,
    cargo_type,
    TUMBLE(event_time, INTERVAL '${window}' MINUTE)
HAVING MIN(temperature_c) > CASE cargo_type
    WHEN 'frozen'  THEN -15.0
    WHEN 'produce' THEN  12.0
    WHEN 'pharma'  THEN   6.0
    ELSE                  8.0   -- vaccine / default
END;

-- ---------------------------------------------------------------------------
-- Detector 2 — sustained low battery WHILE MOVING. A fixed ${battery_window}-minute
-- tumbling window per device fires only when BOTH hold across the whole window:
--   (a) battery stayed under 20% the entire window  -> MAX(battery_pct) < 20
--   (b) the truck kept moving                        -> position "spread"
--       (lat range + lon range) exceeds an epsilon.
--
-- "Moving" is a DERIVED condition — it cannot be known from a single reading;
-- it is computed from the spread of GPS points collected across the window.
-- This is a demo-grade proxy for movement: in production you would use true
-- geodesic distance (haversine) between successive fixes rather than a
-- bounding-box spread, and filter GPS jitter. The spread proxy keeps the SQL
-- readable while still demonstrating a windowed, cross-event geospatial test.
-- EPSILON ~ 0.005 degrees (~500 m) is above the simulated ±0.02° parked jitter
-- only when the truck genuinely traverses ground over the window.
-- ---------------------------------------------------------------------------
INSERT INTO excursions
SELECT
    'battery_low_moving' AS `type`,
    device_id,
    cargo_type,
    TUMBLE_START(event_time, INTERVAL '${battery_window}' MINUTE) AS window_start,
    TUMBLE_END(event_time,   INTERVAL '${battery_window}' MINUTE) AS window_end,
    CAST(NULL AS DOUBLE) AS min_temp_c,
    CAST(NULL AS DOUBLE) AS max_temp_c,
    MAX(battery_pct)     AS max_battery_pct,
    (MAX(lat) - MIN(lat)) + (MAX(lon) - MIN(lon)) AS position_spread,
    COUNT(*)             AS sample_count
FROM readings
GROUP BY
    device_id,
    cargo_type,
    TUMBLE(event_time, INTERVAL '${battery_window}' MINUTE)
HAVING MAX(battery_pct) < 20.0
   -- MOVEMENT EPSILON: 0.002 deg (~200 m N-S, ~150 m E-W at 47 deg N). Above
   -- GPS parked-jitter but trips on a genuine short traverse within the window.
   -- Still the demo bounding-box proxy; prod value ~0.005 (~500 m) for driving.
   AND (MAX(lat) - MIN(lat)) + (MAX(lon) - MIN(lon)) > 0.002;
