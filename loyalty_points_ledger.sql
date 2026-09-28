-- =====================================================================
-- Loyalty Points Ledger (Smile.io -> LoyaltyLion platform switch)
-- ---------------------------------------------------------------------
-- Purpose : Rebuild the points history in the legacy Smile.io schema
--           from LoyaltyLion data, combining point activities and point
--           transactions into one ledger with customer names attached.
-- Source  : LoyaltyLion data synced to BigQuery
--           (project / dataset anonymized as `loyalty`)
-- Grain   : 1 row = 1 points movement (earn, redeem, adjustment...)
-- Dialect : BigQuery Standard SQL
-- Output  : Columns match the legacy Smile.io points-transaction
--           schema used by existing reports.
-- =====================================================================

DECLARE activity_start_date DATE DEFAULT DATE '2026-08-11';  -- LoyaltyLion go-live; earlier history comes from Smile.io

WITH

-- 1. Latest version of each customer's profile.
--    The customers table keeps history, so keep only the newest row.
--    Defined once and reused by both parts of the union.
latest_customers AS (
    SELECT
        id                                                     AS customer_id,
        JSON_VALUE(properties_json, '$.first_name')   AS first_name,
        JSON_VALUE(properties_json, '$.last_name')    AS last_name
    FROM loyalty.ll_customers
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) = 1
),

-- 2. Points earned through activities (purchases, sign-ups, reviews...)
activities AS (
    SELECT
        'activity'                                             AS source_table,
        CAST(a.id AS INT64)                                    AS id,
        CAST(a.customer_id AS INT64)                           AS customer_id,
        COALESCE(a.rule_title, a.rule_name, 'Unknown')         AS description,
        COALESCE(a.value, 0)                                   AS points_change,
        a.created_at                                           AS created_at,
        a.created_at                                           AS updated_at,
        a.customer_email                                       AS email,
        a.state,
        CASE
            WHEN a.rule_name LIKE '$%' THEN 'earn'             -- spend-based rules start with '$'
            ELSE COALESCE(a.rule_name, 'activity')
        END                                                    AS type
    FROM loyalty.ll_activities AS a
    WHERE DATE(a.created_at) >= activity_start_date
),

-- 3. Other point movements (claimed rewards, manual adjustments...).
--    Activity-type transactions are excluded because they are
--    already counted in step 2.
transactions AS (
    SELECT
        'transaction'                                          AS source_table,
        CAST(t.id AS INT64)                                    AS id,
        CAST(t.customer_id AS INT64)                           AS customer_id,
        COALESCE(t.description, t.transaction_type, 'Transaction') AS description,
        COALESCE(t.value, t.points, 0)                         AS points_change,
        t.created_at                                           AS created_at,
        COALESCE(t.updated_at, t.created_at)                   AS updated_at,
        t.customer_email                                       AS email,
        t.state,
        CASE
            WHEN COALESCE(t.description, t.transaction_type, '') LIKE '$%' THEN 'earn'
            ELSE t.transaction_type
        END                                                    AS type
    FROM loyalty.ll_transactions AS t
    WHERE t.transaction_type IS NULL
       OR t.transaction_type != 'activity'
),

ledger AS (
    SELECT * FROM activities
    UNION ALL
    SELECT * FROM transactions
)

-- 4. Final output in the target schema
SELECT
    l.id,
    l.source_table,                                -- ids can overlap across the two sources
    l.customer_id,
    l.description,
    l.points_change,
    CAST(NULL AS STRING)                           AS internal_note,
    CAST(l.created_at AS STRING)                   AS created_at,
    CAST(l.updated_at AS STRING)                   AS updated_at,
    l.email,
    c.first_name,
    c.last_name,
    l.state,
    l.type,
    FALSE                                          AS cancel
FROM ledger AS l
LEFT JOIN latest_customers AS c
    ON l.customer_id = c.customer_id;
