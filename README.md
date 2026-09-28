# Retail Analytics SQL Models (BigQuery)

SQL models I built as a Data Analyst for a multi-store fashion retailer,
turning raw e-commerce and loyalty-program data in BigQuery into clean
tables for reporting and analysis.

> Dataset names and internal codes are anonymized, and no company or
> customer data is included.

| Model | What it does | Source |
|---|---|---|
| [`sales_line_model.sql`](models/sales_line_model.sql) | Line-level gross, discount, return and net sales, plus first-time vs returning customer segmentation | Shopify via Fivetran |
| [`discount_detail.sql`](models/discount_detail.sql) | Every discount on every order line, with the code or campaign behind it | Shopify via Fivetran |
| [`loyalty_customers_export.sql`](models/loyalty_customers_export.sql) | Customer, balance and status export for a loyalty platform migration | LoyaltyLion → Smile.io |
| [`loyalty_points_ledger.sql`](models/loyalty_points_ledger.sql) | Full points history export for the same migration | LoyaltyLion → Smile.io |

---

## 1. Sales & Customer Retention Model

### Business problem

- Sales figures mixed gross and net values, so store and channel
  reports didn't reconcile
- Refunds and stacked discounts were double-counted when tables were
  joined directly
- The team couldn't separate **first-time** buyers from **returning**
  customers

### What the model does

| Area | Logic |
|---|---|
| Revenue | Gross sales, discounts, returns, net sales (before and after returns) |
| Quantity | Units sold, units refunded, net units |
| Dimensions | Store location, sales channel (web / mobile / POS), payment method |
| Customers | Purchase rank per customer → `First-time`, `Returning` or `Guest` |
| Data quality | Refunds and discounts pre-aggregated per order line to prevent row duplication |

**Grain:** one row per order line.

```mermaid
flowchart LR
    A[order_line] --> M[sales_line_model]
    B[orders] --> M
    C[order_line_refund] -->|aggregated per line| M
    D[discount_allocation] -->|aggregated per line| M
    E[location] --> M
    B -->|ROW_NUMBER per customer| F[customer_order_rank] --> M
    M --> R[Dashboards & ad-hoc analysis]
```

### Key design decisions

1. **Aggregate before joining.** An order line can have several refund
   rows and several discount allocations. Joining them raw multiplies
   rows and inflates sales, so both are summed per `order_line_id` first.
2. **Guests are handled separately.** Orders without a `customer_id`
   are labelled `Guest` instead of being ranked together as one customer.
3. **Deterministic ranking.** `ROW_NUMBER()` orders by `created_at` and
   then `id`, so orders placed at the same timestamp rank consistently.

---

## 2. Discount Detail

### Business problem

The sales model shows *how much* discount each order line received, but
not *which* discount. Marketing needed to see the cost and usage of each
voucher code and automatic promotion.

### What the model does

- Links each line-level discount amount to the order-level discount that
  created it (code, title, value, percentage or fixed)
- Names each discount by its voucher code, or by its title for
  automatic promotions
- Keeps one row per discount per line, so stacked discounts stay visible

```mermaid
flowchart LR
    DA[discount_application<br/>order level: code, value, type] -->|order_id + index| M[discount_detail]
    DL[discount_allocation<br/>line level: amount] --> M
    OL[order_line] --> M
    O[orders] --> M
```

### Key design decisions

1. **Understanding the source data model.** Shopify defines discounts at
   order level and allocates amounts at line level. The two are joined on
   `order_id` plus the application `index`.
2. **Row-count validation.** Output rows must equal allocation rows,
   which confirms the join doesn't duplicate or drop discounts.
3. **Reconciles with the sales model.** Total `discount_amount` here
   matches total `discount` in `sales_line_model`.

---

## 3. Loyalty Platform Migration (LoyaltyLion → Smile.io)

### Business problem

The business moved its loyalty program to a new platform. Every member's
profile, points balance, status and full points history had to be moved
across accurately. Customers must not lose points, and history must not
be duplicated.

### What I built

Two export models, each matching the new platform's import template:

| Model | Grain | Contents |
|---|---|---|
| `loyalty_customers_export.sql` | 1 row per customer | Name, email, birthday, points balance, member status, VIP tier, referral link |
| `loyalty_points_ledger.sql` | 1 row per points movement | Earned points (activities) plus claimed rewards and adjustments (transactions) |

```mermaid
flowchart LR
    C[ll_customers] -->|dedupe to latest version| CE[customers export]
    A[ll_activities] --> U[UNION ALL]
    T[ll_transactions] -->|excluding activity type| U
    C -->|latest name per customer| U
    U --> LE[points ledger export]
    CE --> S[(Smile.io import)]
    LE --> S
```

### Key design decisions

1. **Deduplicating incremental syncs.** Fivetran can land several versions
   of a customer. `QUALIFY ROW_NUMBER()` keeps the latest, with a sync
   timestamp as tie-breaker.
2. **Mapping status between platforms.** LoyaltyLion's `enrolled`,
   `guest` and `blocked` flags are mapped to Smile.io's `member`,
   `candidate` and `blocked` states.
3. **Carrying over pending points.** Balances include pending points so
   customers don't lose points earned on recent orders during the move.
4. **No double counting in history.** Activity-type transactions are
   excluded, since those points already appear in the activities table.
5. **Traceable rows.** A `source_table` column shows where each ledger
   row came from, since ids can overlap between the two source tables.

---

## Repository structure

```
models/
  sales_line_model.sql        -- sales & customer retention model
  discount_detail.sql         -- discount breakdown by code / campaign
  loyalty_customers_export.sql -- loyalty migration: customers & balances
  loyalty_points_ledger.sql   -- loyalty migration: points history
analysis/
  example_queries.sql         -- monthly sales, customer mix, repeat-rate cohorts
```

## Impact

- [e.g. Became the main source for sales reporting across N stores and online]
- [e.g. Reduced manual reconciliation from X hours to Y minutes per week]
- [e.g. Tracked cost and usage of N voucher codes for marketing]
- [e.g. Migrated N loyalty members and N points transactions to a new platform with balances reconciled]

## Tech

BigQuery Standard SQL · CTEs · window functions · QUALIFY · JSON parsing · UNION ALL · Fivetran · Shopify · LoyaltyLion · Smile.io · [Looker Studio / Power BI]
