-- Daily sales by region and category: the query behind the dynamic table
-- CORE.DAILY_SALES (R__mart.sql). Region is the customer's region when the
-- order was placed (the point-in-time key on the fact), not today's.
-- Cancelled orders are excluded.
SELECT
    f.order_date
    , c.region
    , p.category
    , COUNT(DISTINCT f.order_id) AS orders
    , SUM(f.quantity) AS units
    , SUM(f.net_amount) AS net_sales
FROM CORE.FACT_ORDER_LINE AS f
INNER JOIN CORE.DIM_CUSTOMER AS c
    ON c.customer_key = f.customer_key
INNER JOIN CORE.DIM_PRODUCT AS p
    ON p.product_key = f.product_key
WHERE f.status <> 'CANCELLED'
GROUP BY f.order_date, c.region, p.category
