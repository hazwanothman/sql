-- =====================================================================
-- Loyalty Customers (Smile.io -> LoyaltyLion platform switch)
-- ---------------------------------------------------------------------
-- Purpose : The loyalty program moved from Smile.io (now closed) to
--           LoyaltyLion. Existing reports were built on the Smile.io
--           data structure, so this model rebuilds the customers table
--           in that same structure from LoyaltyLion data. Dashboards
--           keep working without being rebuilt.
-- Source  : LoyaltyLion data synced to BigQuery
--           (project / dataset anonymized as `loyalty`)
-- Grain   : 1 row = 1 customer
-- Dialect : BigQuery Standard SQL
-- Output  : Column names, types and values match the legacy Smile.io
--           schema, so timestamps are strings and fields LoyaltyLion
--           doesn't have are NULL.
-- =====================================================================

WITH

-- 1. Incremental syncs can land several versions of the same customer.
--    Keep only the most recent one.
latest_customers AS (
    SELECT *
    FROM loyalty.ll_customers
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY id
        ORDER BY updated_at DESC, _fivetran_synced DESC   -- tie-breaker for identical updated_at
    ) = 1
)

SELECT
    CAST(id AS INT64)                                           AS id,
    JSON_VALUE(properties_json, '$.first_name')                 AS first_name,
    JSON_VALUE(properties_json, '$.last_name')                  AS last_name,
    email,
    birthday                                                    AS date_of_birth,

    -- Balance = approved + pending points
    COALESCE(points_approved, 0) + COALESCE(points_pending, 0)  AS points_balance,

    referral_url,

    -- Translate LoyaltyLion flags into the legacy Smile.io states
    CASE
        WHEN blocked  THEN 'blocked'
        WHEN enrolled THEN 'member'      -- enrolled customers are members, guest or not
        ELSE               'candidate'   -- not enrolled: can still join
    END                                                         AS state,

    CAST(NULL AS FLOAT64)                                       AS vip_tier_id,   -- no LoyaltyLion equivalent; kept for schema compatibility
    loyalty_tier_name                                           AS vip_tiers,     -- LoyaltyLion tier name
    CAST(created_at AS STRING)                                  AS created_at,
    CAST(updated_at AS STRING)                                  AS updated_at

FROM latest_customers;
