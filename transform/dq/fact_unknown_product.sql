-- severity: warn
-- Lines whose product code is not in the catalogue.
SELECT f.order_id, f.line_number
FROM CORE.FACT_ORDER_LINE AS f
WHERE f.product_key = -1
