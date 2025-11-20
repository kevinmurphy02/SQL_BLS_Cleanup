USE bls_cpi;

-- build cleaner dimension tables

-- area dim: only want areas that BLS labels as “selectable”
DROP TABLE IF EXISTS dim_area;
CREATE TABLE dim_area AS
SELECT
    area_code,
    area_name
FROM cu_raw_area
WHERE selectable = 'T';

ALTER TABLE dim_area
    ADD PRIMARY KEY (area_code);

-- item dim: same idea, keep the items that are real / selectable
DROP TABLE IF EXISTS dim_item;
CREATE TABLE dim_item AS
SELECT
    item_code,
    item_name
FROM cu_raw_item
WHERE selectable = 'T' OR selectable IS NULL;

ALTER TABLE dim_item
    ADD PRIMARY KEY (item_code);

-- period dim: month numbers and a label for what kind of period it is
DROP TABLE IF EXISTS dim_period;
CREATE TABLE dim_period AS
SELECT
    period,
    period_abbr,
    period_name,
    -- for M01..M12 I grab the numeric month
    CASE
        WHEN period LIKE 'M__' AND period <> 'M13'
            THEN CAST(SUBSTRING(period, 2, 2) AS UNSIGNED)
        ELSE NULL
    END AS month_num,
    -- M13 = annual avg, Sxx = semi-annual, everything else I’ll call monthly
    CASE
        WHEN period = 'M13' THEN 'Annual average'
        WHEN period LIKE 'S__' THEN 'Semi-annual'
        ELSE 'Monthly'
    END AS period_type
FROM cu_raw_period;

ALTER TABLE dim_period
    ADD PRIMARY KEY (period);

-- series dimension that has readable area + item names with each series_id
DROP TABLE IF EXISTS dim_cpi_series;
CREATE TABLE dim_cpi_series AS
SELECT
    s.series_id,
    s.series_title,
    s.area_code,
    a.area_name,
    s.item_code,
    i.item_name,
    s.seasonal,
    s.periodicity_code,
    s.base_period,
    s.base_code
FROM cu_raw_series s
LEFT JOIN dim_area a ON s.area_code = a.area_code
LEFT JOIN dim_item i ON s.item_code = i.item_code;

ALTER TABLE dim_cpi_series
    ADD PRIMARY KEY (series_id);

-- build the main fact table with one row per series/month
-- only want monthly data (not annual averages)
DROP TABLE IF EXISTS fact_cpi_monthly;

CREATE TABLE fact_cpi_monthly AS
SELECT
    r.series_id,
    r.year,
    r.period,
    dp.month_num,
    -- use the first day of the month as the actual date
    STR_TO_DATE(
        CONCAT(r.year, '-', LPAD(dp.month_num, 2, '0'), '-01'),
        '%Y-%m-%d'
    ) AS obs_date,
    -- value comes in as text so convert to numeric
    CAST(NULLIF(r.value_raw, '') AS DECIMAL(10,3)) AS cpi_value,
    NULLIF(r.footnote_codes, '') AS footnote_codes
FROM cu_raw_summaries r
JOIN dim_period dp
  ON r.period = dp.period
WHERE dp.month_num IS NOT NULL                -- filters to M01..M12
  AND NULLIF(r.value_raw, '') IS NOT NULL;    -- ignore blank values

ALTER TABLE fact_cpi_monthly
    ADD PRIMARY KEY (series_id, obs_date),
    ADD INDEX idx_obs_date (obs_date);

-- quick sanity checks
SELECT 'rows_in_fact_cpi_monthly' AS check_name,
       COUNT(*) AS row_count
FROM fact_cpi_monthly;

SELECT 'null_cpi_values' AS check_name,
       COUNT(*) AS row_count
FROM fact_cpi_monthly
WHERE cpi_value IS NULL;

SELECT 'duplicate_series_date_rows' AS check_name,
       COUNT(*) AS row_count
FROM (
    SELECT series_id, obs_date, COUNT(*) AS cnt
    FROM fact_cpi_monthly
    GROUP BY series_id, obs_date
    HAVING cnt > 1
) t;

-- onto views to make the data easier to work with

-- joins facts to readable area/item names
DROP VIEW IF EXISTS vw_cpi_by_area_item;
CREATE VIEW vw_cpi_by_area_item AS
SELECT
    f.obs_date,
    f.series_id,
    s.series_title,
    s.area_name,
    s.item_name,
    f.cpi_value
FROM fact_cpi_monthly f
JOIN dim_cpi_series s
  ON f.series_id = s.series_id;

-- focus on the “All items, U.S. city average” series
-- CUUR0000SA0 is the usual ID, but can confirm in dim_cpi_series
-- view to track YoY inflation for "All items, U.S. city average"
-- get rid of the old version of the view so I can recreate it
DROP VIEW IF EXISTS vw_us_all_items_inflation_yoy;

CREATE VIEW vw_us_all_items_inflation_yoy AS
SELECT
    f.obs_date,
    f.series_id,
    s.series_title,
    f.cpi_value AS cpi_index,
    -- look back 12 months for the index a year ago
    LAG(f.cpi_value, 12) OVER (
        PARTITION BY f.series_id
        ORDER BY f.obs_date
    ) AS cpi_index_12m_ago,
    -- convert into a year-over-year % change
    (
        (f.cpi_value /
         LAG(f.cpi_value, 12) OVER (
             PARTITION BY f.series_id
             ORDER BY f.obs_date
         )
        ) - 1
    ) * 100 AS inflation_yoy_pct
FROM fact_cpi_monthly f
JOIN dim_cpi_series s
  ON f.series_id = s.series_id
WHERE s.series_title LIKE 'All items in U.S. city average%'
ORDER BY f.obs_date;
