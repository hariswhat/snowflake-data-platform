-- severity: error
-- A line's customer key points at the version valid when the order was
-- placed, or at the unknown member.
SELECT f.order_id, f.line_number
FROM CORE.FACT_ORDER_LINE AS f
LEFT JOIN CORE.DIM_CUSTOMER AS c
    ON c.customer_key = f.customer_key
WHERE c.customer_key IS NULL
   OR (f.customer_key <> -1 AND NOT (f.order_ts >= c.valid_from AND f.order_ts < c.valid_to))
   OR (f.customer_key <> -1 AND c.customer_id <> f.customer_id)
