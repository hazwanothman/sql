-- =====================================================================
-- Discount Detail
-- ---------------------------------------------------------------------
-- Purpose : Show every discount applied to every order line, with the
--           code / campaign behind it (e.g. voucher code vs automatic
--           promo, percentage vs fixed amount).
-- Source  : Shopify data synced to BigQuery via Fivetran
--           (dataset name anonymized as `shop`)
-- Grain   : 1 row = 1 discount allocation on 1 order line
--           (a line with a voucher + an automatic promo has 2 rows)
-- Dialect : BigQuery Standard SQL
--
-- How Shopify stores discounts:
--   discount_application : the discount defined at ORDER level
--                          (code, title, value, type), numbered by `index`
--   discount_allocation  : how much of that discount landed on each
--                          ORDER LINE, linked by discount_application_index
--
-- Validation: row count of the output must equal the row count of
-- discount_allocation (the join to discount_application is 1:1).
-- =====================================================================

WITH

allocations AS (
    SELECT
        DATE(o.created_at)              AS order_date,
        o.order_number,
        ol.order_id,
        dl.order_line_id,
        ol.sku,
        dl.amount                       AS allocated_amount,
        dl.discount_application_index
    FROM shop.discount_allocation   AS dl
    JOIN shop.order_line            AS ol ON ol.id = dl.order_line_id
    JOIN shop.orders                AS o  ON o.id  = ol.order_id
    -- INNER joins drop orphan allocations whose line or order is missing
)

SELECT
    a.order_date,
    a.order_number,
    a.order_id,
    a.order_line_id,
    a.sku,
    COALESCE(a.allocated_amount, 0)     AS discount_amount,   -- RM taken off this line
    COALESCE(da.value, 0)               AS discount_value,    -- configured value, e.g. 20 (%) or 10 (RM)
    da.value_type,                                            -- 'percentage' or 'fixed_amount'
    COALESCE(da.code, da.title)         AS discount_name,     -- code for vouchers, title for automatic promos
    da.description,
    da.type                             AS discount_type      -- e.g. discount_code, automatic, manual
FROM allocations                     AS a
LEFT JOIN shop.discount_application  AS da
    ON  da.order_id = a.order_id
    AND da.`index`  = a.discount_application_index;
