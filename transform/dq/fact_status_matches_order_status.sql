-- severity: error
-- Every line carries its order's newest status.
SELECT f.order_id, f.line_number
FROM CORE.FACT_ORDER_LINE AS f
INNER JOIN CORE.ORDER_STATUS AS s
    ON s.order_id = f.order_id
WHERE f.status IS DISTINCT FROM s.status
