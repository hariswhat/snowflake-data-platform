-- MART: what BI and analysts read. Secure views, so the definition and the
-- underlying objects stay hidden from consumers; the region filter is the
-- row access policy on each view, the PII masking comes from the tags on
-- CORE.DIM_CUSTOMER. Repeatable: rerun when this file changes.
--
-- The policy is part of each CREATE, not a separate ALTER, so a replaced
-- view is never readable without it, even briefly or after a failed deploy.

-- Daily sales: a dynamic table, refreshed by Snowflake within its target lag
-- (ADR-0002). Region is the customer's when the order was placed; category is
-- the product's current one, because products are type 1 (ADR-0003).
CREATE OR REPLACE DYNAMIC TABLE CORE.DAILY_SALES
    TARGET_LAG = '2 hours'
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    REFRESH_MODE = AUTO
    COMMENT = 'Net sales by day, region and category, excluding cancelled orders'
AS
{% include "modules/daily_sales.sql" %};

CREATE OR REPLACE SECURE VIEW MART.DAILY_SALES
    WITH ROW ACCESS POLICY GOVERNANCE.RAP_REGION ON (region)
    COMMENT = 'Net sales by day, region and category'
AS
SELECT order_date, region, category, orders, units, net_sales
FROM CORE.DAILY_SALES;

CREATE OR REPLACE SECURE VIEW MART.ORDER_LINE
    WITH ROW ACCESS POLICY GOVERNANCE.RAP_REGION ON (region)
    COMMENT = 'Order lines with the customer and product as they were at order time'
AS
SELECT
    f.order_id
    , f.line_number
    , f.order_date
    , f.order_ts
    , f.channel
    , f.status
    , f.customer_id
    , c.region
    , c.loyalty_tier
    , f.product_code
    , p.product_name
    , p.category
    , f.quantity
    , f.unit_price
    , f.discount_pct
    , f.net_amount
FROM CORE.FACT_ORDER_LINE AS f
INNER JOIN CORE.DIM_CUSTOMER AS c
    ON c.customer_key = f.customer_key
INNER JOIN CORE.DIM_PRODUCT AS p
    ON p.product_key = f.product_key;

CREATE OR REPLACE SECURE VIEW MART.CUSTOMER
    WITH ROW ACCESS POLICY GOVERNANCE.RAP_REGION ON (region)
    COMMENT = 'Current customer attributes; email and name masked by tag'
AS
SELECT customer_id, email, full_name, region, loyalty_tier, signup_date
FROM CORE.DIM_CUSTOMER
WHERE is_current
  AND customer_key <> -1;
