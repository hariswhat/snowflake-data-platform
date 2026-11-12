-- severity: warn
-- Lines still on the unknown customer two days after the order: the CRM
-- export is late or the customer does not exist there.
SELECT f.order_id, f.line_number
FROM CORE.FACT_ORDER_LINE AS f
WHERE f.customer_key = -1
  AND f.order_date < DATEADD(DAY, -2, (SELECT MAX(order_date) FROM CORE.FACT_ORDER_LINE))
