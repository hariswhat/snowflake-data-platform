-- severity: warn
-- ORDER_CREATED events kept out of the fact in the last day because a
-- required field was missing (transform/order_line.sql).
SELECT r.event_id, r.order_id, r.line_number, r.reason
FROM OPS.REJECTED_EVENT AS r
WHERE r.logged_at >= DATEADD(DAY, -1, CURRENT_TIMESTAMP())
