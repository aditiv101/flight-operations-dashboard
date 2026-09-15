-- ============================================================
-- RUN THIS FILE ONCE IN MYSQL WORKBENCH
-- It creates the enriched fact view and every Power BI analysis view.
-- It does not delete or change your raw airlines, airports, or flights tables.
-- ============================================================
CREATE OR REPLACE VIEW vw_flights_enriched AS
SELECT
    f.*,
    al.AIRLINE AS airline_name,

    -- Origin airport lookup fields
    ao.AIRPORT AS origin_airport_name,
    ao.CITY AS origin_city,
    ao.STATE AS origin_state,
    ao.COUNTRY AS origin_country,
    ao.LATITUDE AS origin_latitude,
    ao.LONGITUDE AS origin_longitude,

    -- Destination airport lookup fields
    ad.AIRPORT AS destination_airport_name,
    ad.CITY AS destination_city,
    ad.STATE AS destination_state,
    ad.COUNTRY AS destination_country,
    ad.LATITUDE AS destination_latitude,
    ad.LONGITUDE AS destination_longitude,

    -- Dashboard-ready derived fields
    STR_TO_DATE(CONCAT(f.YEAR, '-', LPAD(f.MONTH, 2, '0'), '-', LPAD(f.DAY, 2, '0')), '%Y-%m-%d') AS flight_date,
    ELT(f.DAY_OF_WEEK, 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') AS day_name,
    CASE
        WHEN f.SCHEDULED_DEPARTURE < 600 THEN 'Early Morning'
        WHEN f.SCHEDULED_DEPARTURE < 1200 THEN 'Morning'
        WHEN f.SCHEDULED_DEPARTURE < 1800 THEN 'Afternoon'
        ELSE 'Evening'
    END AS departure_time_bucket,
    CASE
        WHEN f.DISTANCE < 500 THEN 'Short (<500 miles)'
        WHEN f.DISTANCE < 1000 THEN 'Medium (500-999 miles)'
        WHEN f.DISTANCE < 1500 THEN 'Long (1000-1499 miles)'
        ELSE 'Very Long (1500+ miles)'
    END AS distance_bucket,
    CASE f.CANCELLATION_REASON
        WHEN 'A' THEN 'Airline/Carrier'
        WHEN 'B' THEN 'Weather'
        WHEN 'C' THEN 'National Air System'
        WHEN 'D' THEN 'Security'
        ELSE NULL
    END AS cancellation_reason_name,
    CASE
        WHEN f.CANCELLED = 1 THEN 'Cancelled'
        WHEN f.DIVERTED = 1 THEN 'Diverted'
        WHEN f.ARRIVAL_DELAY <= 15 THEN 'On Time (<=15 min)'
        ELSE 'Late (>15 min)'
    END AS arrival_status
FROM flights f
LEFT JOIN airlines al
    ON f.AIRLINE = al.IATA_CODE
LEFT JOIN airports ao
    ON f.ORIGIN_AIRPORT = ao.IATA_CODE
LEFT JOIN airports ad
    ON f.DESTINATION_AIRPORT = ad.IATA_CODE;

-- ============================================================
-- POWER BI READY VIEWS FOR THE FLIGHT DASHBOARD (MySQL 8)
-- Prerequisite: run the CREATE VIEW vw_flights_enriched statement
-- from "trial 1 - joined dashboard.sql" first.
--
-- Every object below is a VIEW: MySQL stores the SQL definition,
-- and Power BI can load each one exactly like a table.
-- ============================================================

-- One-row dashboard cards: volume, cancellations, diversions, delays, on-time rate.
CREATE OR REPLACE VIEW vw_kpi_overview AS
SELECT
    COUNT(*) AS total_scheduled_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(100.0 * SUM(DIVERTED = 1) / COUNT(*), 2) AS diversion_rate_pct,
    SUM(CANCELLED = 0 AND DIVERTED = 0) AS completed_flights,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(
        100.0 * SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY <= 15 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN 1 ELSE 0 END), 0), 2
    ) AS on_time_rate_pct
FROM vw_flights_enriched;

-- Monthly trend: line/column visual. Sort month_name by month_number in Power BI.
CREATE OR REPLACE VIEW vw_monthly_performance AS
SELECT
    MONTH AS month_number,
    DATE_FORMAT(flight_date, '%b') AS month_name,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(100.0 * SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY <= 15 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN 1 ELSE 0 END), 0), 2) AS on_time_rate_pct
FROM vw_flights_enriched
GROUP BY MONTH, DATE_FORMAT(flight_date, '%b');

-- Airline scorecard: airline name, volume, cancellation, arrival delay and punctuality.
CREATE OR REPLACE VIEW vw_airline_performance AS
SELECT
    airline_name,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(100.0 * SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY <= 15 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN 1 ELSE 0 END), 0), 2) AS on_time_rate_pct
FROM vw_flights_enriched
GROUP BY airline_name;

-- Origin-airport map and ranking table.
-- Power BI map fields: origin_latitude and origin_longitude.
CREATE OR REPLACE VIEW vw_origin_airport_performance AS
SELECT
    ORIGIN_AIRPORT AS origin_iata_code,
    origin_airport_name,
    origin_city,
    origin_state,
    origin_country,
    origin_latitude,
    origin_longitude,
    COUNT(*) AS total_departures,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes
FROM vw_flights_enriched
GROUP BY ORIGIN_AIRPORT, origin_airport_name, origin_city, origin_state, origin_country, origin_latitude, origin_longitude;

-- Destination-airport map and ranking table.
-- Power BI map fields: destination_latitude and destination_longitude.
CREATE OR REPLACE VIEW vw_destination_airport_performance AS
SELECT
    DESTINATION_AIRPORT AS destination_iata_code,
    destination_airport_name,
    destination_city,
    destination_state,
    destination_country,
    destination_latitude,
    destination_longitude,
    COUNT(*) AS total_arrivals,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
GROUP BY DESTINATION_AIRPORT, destination_airport_name, destination_city, destination_state, destination_country, destination_latitude, destination_longitude;

-- Route table: use in a matrix, ranked bar chart, or route drill-through page.
CREATE OR REPLACE VIEW vw_route_performance AS
SELECT
    ORIGIN_AIRPORT AS origin_iata_code,
    origin_airport_name,
    origin_city,
    origin_state,
    DESTINATION_AIRPORT AS destination_iata_code,
    destination_airport_name,
    destination_city,
    destination_state,
    origin_latitude,
    origin_longitude,
    destination_latitude,
    destination_longitude,
    CONCAT(ORIGIN_AIRPORT, ' - ', DESTINATION_AIRPORT) AS route_code,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(AVG(DISTANCE), 2) AS avg_distance_miles
FROM vw_flights_enriched
GROUP BY
    ORIGIN_AIRPORT, origin_airport_name, origin_city, origin_state,
    DESTINATION_AIRPORT, destination_airport_name, destination_city, destination_state,
    origin_latitude, origin_longitude, destination_latitude, destination_longitude;

-- Cancellation-reason breakdown: pie/donut or stacked bar.
CREATE OR REPLACE VIEW vw_cancellation_reason_performance AS
SELECT
    cancellation_reason_name,
    COUNT(*) AS cancelled_flights,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_of_cancellations_pct
FROM vw_flights_enriched
WHERE CANCELLED = 1
GROUP BY cancellation_reason_name;

-- Delay-cause totals by airline: stacked bar visual.
CREATE OR REPLACE VIEW vw_delay_cause_by_airline AS
SELECT
    airline_name,
    SUM(AIR_SYSTEM_DELAY) AS air_system_delay_minutes,
    SUM(SECURITY_DELAY) AS security_delay_minutes,
    SUM(AIRLINE_DELAY) AS airline_delay_minutes,
    SUM(LATE_AIRCRAFT_DELAY) AS late_aircraft_delay_minutes,
    SUM(WEATHER_DELAY) AS weather_delay_minutes
FROM vw_flights_enriched
GROUP BY airline_name;

-- Day/time performance: heatmap or clustered-column visual.
CREATE OR REPLACE VIEW vw_day_time_performance AS
SELECT
    DAY_OF_WEEK AS day_of_week_number,
    day_name,
    departure_time_bucket,
    COUNT(*) AS total_flights,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct
FROM vw_flights_enriched
GROUP BY DAY_OF_WEEK, day_name, departure_time_bucket;

-- Check that every view is available after running this file.
SHOW FULL TABLES WHERE Table_type = 'VIEW';


-- ============================================================
-- EXTENDED POWER BI ANALYSIS CATALOGUE
-- Run powerbi_dashboard_views.sql first. Then run this whole file.
-- These are the remaining analyses from trial 1, each exposed as
-- a separate, loadable Power BI table/view.
-- ============================================================

-- Data-audit table: baseline counts for a dashboard information card.
CREATE OR REPLACE VIEW vw_data_audit AS
SELECT
    COUNT(*) AS total_flights,
    COUNT(DISTINCT airline_name) AS unique_airlines,
    COUNT(DISTINCT ORIGIN_AIRPORT) AS unique_origin_airports,
    COUNT(DISTINCT DESTINATION_AIRPORT) AS unique_destination_airports,
    MIN(flight_date) AS first_flight_date,
    MAX(flight_date) AS last_flight_date
FROM vw_flights_enriched;

-- Airline x month performance: small multiples, matrix, or drill-through.
CREATE OR REPLACE VIEW vw_airline_monthly_performance AS
SELECT
    airline_name,
    MONTH AS month_number,
    DATE_FORMAT(flight_date, '%b') AS month_name,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct
FROM vw_flights_enriched
GROUP BY airline_name, MONTH, DATE_FORMAT(flight_date, '%b');

-- Day-of-week performance: sort day_name by day_of_week_number in Power BI.
CREATE OR REPLACE VIEW vw_day_of_week_performance AS
SELECT
    DAY_OF_WEEK AS day_of_week_number,
    day_name,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
GROUP BY DAY_OF_WEEK, day_name;

-- Origin cancellation hotspots: filter in Power BI to airports with meaningful volume.
CREATE OR REPLACE VIEW vw_origin_cancellation_hotspots AS
SELECT
    ORIGIN_AIRPORT AS origin_iata_code,
    origin_airport_name,
    origin_city,
    origin_state,
    origin_latitude,
    origin_longitude,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes
FROM vw_flights_enriched
GROUP BY ORIGIN_AIRPORT, origin_airport_name, origin_city, origin_state, origin_latitude, origin_longitude
HAVING COUNT(*) >= 1000;

-- Destination cancellation hotspots: destination counterpart to origin hotspots.
CREATE OR REPLACE VIEW vw_destination_cancellation_hotspots AS
SELECT
    DESTINATION_AIRPORT AS destination_iata_code,
    destination_airport_name,
    destination_city,
    destination_state,
    destination_latitude,
    destination_longitude,
    COUNT(*) AS total_flights,
    SUM(CANCELLED = 1) AS cancelled_flights,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN ARRIVAL_DELAY END), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
GROUP BY DESTINATION_AIRPORT, destination_airport_name, destination_city, destination_state, destination_latitude, destination_longitude
HAVING COUNT(*) >= 1000;

-- Cancellation reasons by airline: stacked bar or matrix.
CREATE OR REPLACE VIEW vw_cancellation_reason_by_airline AS
SELECT
    airline_name,
    cancellation_reason_name,
    COUNT(*) AS cancelled_flights,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY airline_name), 2) AS share_of_airline_cancellations_pct
FROM vw_flights_enriched
WHERE CANCELLED = 1
GROUP BY airline_name, cancellation_reason_name;

-- Cancellation reasons by month: seasonal cancellation story.
CREATE OR REPLACE VIEW vw_cancellation_reason_by_month AS
SELECT
    MONTH AS month_number,
    DATE_FORMAT(flight_date, '%b') AS month_name,
    cancellation_reason_name,
    COUNT(*) AS cancelled_flights,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY MONTH), 2) AS share_of_monthly_cancellations_pct
FROM vw_flights_enriched
WHERE CANCELLED = 1
GROUP BY MONTH, DATE_FORMAT(flight_date, '%b'), cancellation_reason_name;

-- Total delay-cause contribution. This tall format is ideal for a donut/bar visual.
CREATE OR REPLACE VIEW vw_delay_cause_overall AS
SELECT 'Air System' AS delay_cause, SUM(AIR_SYSTEM_DELAY) AS delay_minutes FROM vw_flights_enriched
UNION ALL SELECT 'Security', SUM(SECURITY_DELAY) FROM vw_flights_enriched
UNION ALL SELECT 'Airline', SUM(AIRLINE_DELAY) FROM vw_flights_enriched
UNION ALL SELECT 'Late Aircraft', SUM(LATE_AIRCRAFT_DELAY) FROM vw_flights_enriched
UNION ALL SELECT 'Weather', SUM(WEATHER_DELAY) FROM vw_flights_enriched;

-- Monthly delay causes: stacked column chart across months.
CREATE OR REPLACE VIEW vw_delay_cause_by_month AS
SELECT
    MONTH AS month_number,
    DATE_FORMAT(flight_date, '%b') AS month_name,
    SUM(AIR_SYSTEM_DELAY) AS air_system_delay_minutes,
    SUM(SECURITY_DELAY) AS security_delay_minutes,
    SUM(AIRLINE_DELAY) AS airline_delay_minutes,
    SUM(LATE_AIRCRAFT_DELAY) AS late_aircraft_delay_minutes,
    SUM(WEATHER_DELAY) AS weather_delay_minutes
FROM vw_flights_enriched
GROUP BY MONTH, DATE_FORMAT(flight_date, '%b');

-- Delay-cause composition by airline: percentages make airlines comparable despite volume.
CREATE OR REPLACE VIEW vw_delay_cause_composition_by_airline AS
SELECT
    airline_name,
    ROUND(100.0 * SUM(AIR_SYSTEM_DELAY) / NULLIF(SUM(AIR_SYSTEM_DELAY) + SUM(SECURITY_DELAY) + SUM(AIRLINE_DELAY) + SUM(LATE_AIRCRAFT_DELAY) + SUM(WEATHER_DELAY), 0), 2) AS air_system_delay_pct,
    ROUND(100.0 * SUM(SECURITY_DELAY) / NULLIF(SUM(AIR_SYSTEM_DELAY) + SUM(SECURITY_DELAY) + SUM(AIRLINE_DELAY) + SUM(LATE_AIRCRAFT_DELAY) + SUM(WEATHER_DELAY), 0), 2) AS security_delay_pct,
    ROUND(100.0 * SUM(AIRLINE_DELAY) / NULLIF(SUM(AIR_SYSTEM_DELAY) + SUM(SECURITY_DELAY) + SUM(AIRLINE_DELAY) + SUM(LATE_AIRCRAFT_DELAY) + SUM(WEATHER_DELAY), 0), 2) AS airline_delay_pct,
    ROUND(100.0 * SUM(LATE_AIRCRAFT_DELAY) / NULLIF(SUM(AIR_SYSTEM_DELAY) + SUM(SECURITY_DELAY) + SUM(AIRLINE_DELAY) + SUM(LATE_AIRCRAFT_DELAY) + SUM(WEATHER_DELAY), 0), 2) AS late_aircraft_delay_pct,
    ROUND(100.0 * SUM(WEATHER_DELAY) / NULLIF(SUM(AIR_SYSTEM_DELAY) + SUM(SECURITY_DELAY) + SUM(AIRLINE_DELAY) + SUM(LATE_AIRCRAFT_DELAY) + SUM(WEATHER_DELAY), 0), 2) AS weather_delay_pct
FROM vw_flights_enriched
GROUP BY airline_name;

-- Arrival punctuality by airline: retains the original late-vs-early analysis.
CREATE OR REPLACE VIEW vw_arrival_punctuality_by_airline AS
SELECT
    airline_name,
    COUNT(*) AS completed_flights,
    SUM(ARRIVAL_DELAY > 0) AS late_arrivals,
    SUM(ARRIVAL_DELAY <= 0) AS on_time_or_early_arrivals,
    ROUND(100.0 * SUM(ARRIVAL_DELAY > 0) / COUNT(*), 2) AS late_arrival_rate_pct,
    ROUND(AVG(ARRIVAL_DELAY), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY IS NOT NULL
GROUP BY airline_name;

-- Departure time bucket analysis: shows whether delays worsen during the day.
CREATE OR REPLACE VIEW vw_departure_time_bucket_performance AS
SELECT
    departure_time_bucket,
    COUNT(*) AS completed_flights,
    SUM(ARRIVAL_DELAY > 0) AS late_arrivals,
    SUM(ARRIVAL_DELAY <= 0) AS on_time_or_early_arrivals,
    ROUND(100.0 * SUM(ARRIVAL_DELAY > 0) / COUNT(*), 2) AS late_arrival_rate_pct,
    ROUND(AVG(ARRIVAL_DELAY), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY IS NOT NULL
GROUP BY departure_time_bucket;

-- Distance bucket analysis: compares short, medium, long and very-long flights.
CREATE OR REPLACE VIEW vw_distance_bucket_performance AS
SELECT
    distance_bucket,
    COUNT(*) AS completed_flights,
    SUM(ARRIVAL_DELAY > 0) AS late_arrivals,
    SUM(ARRIVAL_DELAY <= 0) AS on_time_or_early_arrivals,
    ROUND(100.0 * SUM(ARRIVAL_DELAY > 0) / COUNT(*), 2) AS late_arrival_rate_pct,
    ROUND(AVG(ARRIVAL_DELAY), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY IS NOT NULL
GROUP BY distance_bucket;

-- Departure punctuality by airline: separate from arrival punctuality.
CREATE OR REPLACE VIEW vw_departure_punctuality_by_airline AS
SELECT
    airline_name,
    COUNT(*) AS completed_flights,
    SUM(DEPARTURE_DELAY > 0) AS delayed_departures,
    SUM(DEPARTURE_DELAY <= 0) AS on_time_or_early_departures,
    ROUND(100.0 * SUM(DEPARTURE_DELAY > 0) / COUNT(*), 2) AS departure_delay_rate_pct,
    ROUND(AVG(DEPARTURE_DELAY), 2) AS avg_departure_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0 AND DEPARTURE_DELAY IS NOT NULL
GROUP BY airline_name;

-- Taxi-time analysis: identifies operational congestion by airline.
CREATE OR REPLACE VIEW vw_taxi_performance_by_airline AS
SELECT
    airline_name,
    ROUND(AVG(TAXI_OUT), 2) AS avg_taxi_out_minutes,
    ROUND(AVG(TAXI_IN), 2) AS avg_taxi_in_minutes,
    ROUND(AVG(DEPARTURE_DELAY), 2) AS avg_departure_delay_minutes,
    ROUND(AVG(ARRIVAL_DELAY), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0
GROUP BY airline_name;

-- Scheduled versus actual duration: tells whether flights are taking longer than planned.
CREATE OR REPLACE VIEW vw_schedule_vs_actual_by_airline AS
SELECT
    airline_name,
    COUNT(*) AS completed_flights,
    ROUND(AVG(SCHEDULED_TIME), 2) AS avg_scheduled_time_minutes,
    ROUND(AVG(ELAPSED_TIME), 2) AS avg_actual_time_minutes,
    ROUND(AVG(ELAPSED_TIME - SCHEDULED_TIME), 2) AS avg_time_difference_minutes,
    ROUND(AVG(ARRIVAL_DELAY), 2) AS avg_arrival_delay_minutes
FROM vw_flights_enriched
WHERE CANCELLED = 0 AND DIVERTED = 0 AND ELAPSED_TIME IS NOT NULL AND SCHEDULED_TIME IS NOT NULL
GROUP BY airline_name;

-- Diversion analysis: separate operational-risk table.
CREATE OR REPLACE VIEW vw_diversion_by_airline AS
SELECT
    airline_name,
    COUNT(*) AS total_flights,
    SUM(DIVERTED = 1) AS diverted_flights,
    ROUND(100.0 * SUM(DIVERTED = 1) / COUNT(*), 2) AS diversion_rate_pct
FROM vw_flights_enriched
GROUP BY airline_name;

-- Airline volume versus performance: shows scale and reliability together.
CREATE OR REPLACE VIEW vw_airline_volume_vs_performance AS
SELECT
    airline_name,
    COUNT(*) AS total_flights,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS flight_volume_share_pct,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 AND ARRIVAL_DELAY > 0 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN 1 ELSE 0 END), 0), 2) AS arrival_late_rate_pct
FROM vw_flights_enriched
GROUP BY airline_name;

-- State-level origin performance: filled map or state ranking.
CREATE OR REPLACE VIEW vw_origin_state_performance AS
SELECT
    origin_state,
    COUNT(*) AS total_departures,
    SUM(CANCELLED = 1) AS cancelled_flights,
    ROUND(100.0 * SUM(CANCELLED = 1) / COUNT(*), 2) AS cancellation_rate_pct,
    ROUND(AVG(CASE WHEN CANCELLED = 0 AND DIVERTED = 0 THEN DEPARTURE_DELAY END), 2) AS avg_departure_delay_minutes
FROM vw_flights_enriched
GROUP BY origin_state;

SHOW FULL TABLES WHERE Table_type = 'VIEW';

CREATE OR REPLACE VIEW vw_top10_origin_airports AS
SELECT
    origin_iata_code,
    origin_airport_name,
    origin_city,
    origin_state,
    total_departures,
    cancelled_flights,
    cancellation_rate_pct,
    avg_departure_delay_minutes
FROM vw_origin_airport_performance
WHERE origin_airport_name IS NOT NULL
ORDER BY total_departures DESC
LIMIT 10;


CREATE OR REPLACE VIEW vw_top10_cancellation_airports AS
SELECT
    origin_iata_code,
    origin_airport_name,
    origin_city,
    origin_state,
    total_departures,
    cancelled_flights,
    cancellation_rate_pct,
    avg_departure_delay_minutes
FROM vw_origin_airport_performance
WHERE origin_airport_name IS NOT NULL
  AND total_departures >= 10000
ORDER BY cancellation_rate_pct DESC
LIMIT 10;

CREATE OR REPLACE VIEW vw_origin_destination_volume AS
SELECT
    'Origin' AS airport_type,
    SUM(total_departures) AS flight_volume
FROM vw_origin_airport_performance

UNION ALL

SELECT
    'Destination' AS airport_type,
    SUM(total_arrivals) AS flight_volume
FROM vw_destination_airport_performance;

CREATE OR REPLACE VIEW vw_top10_route_cancellation AS
SELECT
    route_code,
    origin_airport_name,
    destination_airport_name,
    total_flights,
    cancelled_flights,
    cancellation_rate_pct,
    avg_arrival_delay_minutes,
    avg_distance_miles
FROM vw_route_performance
WHERE total_flights >= 5000
ORDER BY cancellation_rate_pct DESC
LIMIT 10;

CREATE OR REPLACE VIEW vw_delay_cause_frequency AS

SELECT
    'Air System' AS delay_cause,
    COUNT(*) AS affected_flights
FROM flights
WHERE AIR_SYSTEM_DELAY > 0

UNION ALL

SELECT
    'Security' AS delay_cause,
    COUNT(*) AS affected_flights
FROM flights
WHERE SECURITY_DELAY > 0

UNION ALL

SELECT
    'Airline' AS delay_cause,
    COUNT(*) AS affected_flights
FROM flights
WHERE AIRLINE_DELAY > 0

UNION ALL

SELECT
    'Late Aircraft' AS delay_cause,
    COUNT(*) AS affected_flights
FROM flights
WHERE LATE_AIRCRAFT_DELAY > 0

UNION ALL

SELECT
    'Weather' AS delay_cause,
    COUNT(*) AS affected_flights
FROM flights
WHERE WEATHER_DELAY > 0;

SELECT *
FROM vw_delay_cause_frequency
ORDER BY affected_flights DESC;