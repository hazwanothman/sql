-- =====================================================================
-- Sales Line Model
-- ---------------------------------------------------------------------
-- Purpose : Build one clean row per order line with gross, discount,
--           return and net sales, plus first-time vs returning
--           customer classification.
-- Source  : Shopify data synced to BigQuery via Fivetran
--           (dataset name anonymized as `shop`)
-- Grain   : 1 row = 1 order line
-- Dialect : BigQuery Standard SQL
-- =====================================================================

WITH

-- 1. Refunds: one line can be refunded more than once, so aggregate
--    first. Joining the raw table would duplicate order lines.
refunds AS (
    SELECT
        order_line_id,
        SUM(quantity) AS refund_qty,
        SUM(subtotal) AS refund_amount
    FROM shop.order_line_refund
    GROUP BY order_line_id
),

-- 2. Discounts: a line can receive several discount allocations
--    (e.g. a voucher plus an automatic promo), so aggregate them too.
discounts AS (
    SELECT
        order_line_id,
        SUM(amount) AS discount_amount
    FROM shop.discount_allocation
    GROUP BY order_line_id
),

-- 3. Purchase rank per customer. Guest orders (no customer_id) are
--    excluded so they are not ranked together as one "customer".
customer_order_rank AS (
    SELECT
        id AS order_id,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY created_at, id          -- id breaks timestamp ties
        ) AS purchase_rank
    FROM shop.orders
    WHERE customer_id IS NOT NULL
)

-- 4. Final line-level model
SELECT
    -- Keys
    ol.id                                   AS order_line_id,
    o.id                                    AS order_id,
    o.order_number,
    o.customer_id,
    ol.variant_id,
    ol.sku,

    -- Time
    DATE(o.created_at)                      AS order_date,
    DATETIME(o.created_at)                  AS order_datetime,

    -- Dimensions
    COALESCE(l.name, 'Online')              AS location,
    CASE
        WHEN o.source_name = '<mobile_app_source_id>' THEN 'Mobile'
        ELSE o.source_name
    END                                     AS sales_channel,
    REGEXP_EXTRACT(o.payment_gateway_names, r'([^\[]+)\]') AS payment_method,
    o.note,

    -- Quantities
    COALESCE(ol.quantity, 0)                AS quantity,
    COALESCE(r.refund_qty, 0)               AS refund_qty,
    COALESCE(ol.quantity, 0)
      - COALESCE(r.refund_qty, 0)           AS net_quantity,

    -- Revenue
    COALESCE(ol.price, 0)                   AS unit_price,
    COALESCE(ol.price, 0) * COALESCE(ol.quantity, 0)
                                            AS gross_sales,
    COALESCE(d.discount_amount, 0)          AS discount,
    COALESCE(r.refund_amount, 0)            AS returns,
    COALESCE(ol.price, 0) * COALESCE(ol.quantity, 0)
      - COALESCE(d.discount_amount, 0)      AS net_sales_before_returns,
    COALESCE(ol.price, 0) * COALESCE(ol.quantity, 0)
      - COALESCE(d.discount_amount, 0)
      - COALESCE(r.refund_amount, 0)        AS net_sales,

    -- Flags
    COALESCE(d.discount_amount, 0) > 0      AS has_discount,
    COALESCE(r.refund_amount, 0) > 0        AS has_return,

    -- Customer segmentation
    c.purchase_rank,
    CASE
        WHEN o.customer_id IS NULL THEN 'Guest'
        WHEN c.purchase_rank = 1   THEN 'First-time'
        ELSE 'Returning'
    END                                     AS customer_status

FROM shop.order_line            AS ol
LEFT JOIN shop.orders           AS o ON ol.order_id = o.id
LEFT JOIN refunds               AS r ON r.order_line_id = ol.id
LEFT JOIN discounts             AS d ON d.order_line_id = ol.id
LEFT JOIN shop.location         AS l ON o.location_id = l.id
LEFT JOIN customer_order_rank   AS c ON c.order_id = o.id;
