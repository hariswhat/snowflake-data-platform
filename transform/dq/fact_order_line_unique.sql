-- severity: error
-- One row per order line, whatever the duplicates in the event feed.
SELECT order_id, line_number
FROM CORE.FACT_ORDER_LINE
GROUP BY order_id, line_number
HAVING COUNT(*) > 1
