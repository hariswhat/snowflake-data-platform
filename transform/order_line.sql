-- Order status and order lines from the web shop events (RAW.ORDER_EVENT_STREAM).
-- Runs inside one transaction in task T_FACT_ORDER_LINE, after the customer
-- and product tasks, so every statement reads the same stream rows.
--
-- Events arrive late, out of order and twice. The rules:
--   * an order's status is its newest event by event_ts; an older event never
--     overwrites a newer one, so a SHIPPED that arrives before PAID stays
--     SHIPPED
--   * a line is inserted once, from its ORDER_CREATED event; a re-sent event
--     matches the existing line and changes nothing
--   * a line whose customer or product is not in the dimension yet gets key
--     -1, and is re-keyed when it arrives
--   * a customer change can reach the CRM export after orders placed after
--     it were loaded; those lines point at the old version and are re-keyed
--     to the version valid when the order was placed

MERGE INTO CORE.ORDER_STATUS AS t
USING (
    SELECT
        order_id
        , CASE event_type
            WHEN 'ORDER_CREATED' THEN 'PLACED'
            WHEN 'PAID' THEN 'PAID'
            WHEN 'SHIPPED' THEN 'SHIPPED'
            WHEN 'CANCELLED' THEN 'CANCELLED'
        END AS status
        , event_ts
        , event_id
    FROM RAW.ORDER_EVENT_STREAM
    WHERE event_type IN ('ORDER_CREATED', 'PAID', 'SHIPPED', 'CANCELLED')
    -- Newest event wins; on a tie, the later step of the order's life.
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY order_id
        ORDER BY event_ts DESC
            , CASE event_type WHEN 'CANCELLED' THEN 4 WHEN 'SHIPPED' THEN 3 WHEN 'PAID' THEN 2 ELSE 1 END DESC
            , event_id DESC
    ) = 1
) AS s
    ON t.order_id = s.order_id
WHEN MATCHED AND s.event_ts > t.status_ts THEN UPDATE SET
    status = s.status
    , status_ts = s.event_ts
    , event_id = s.event_id
WHEN NOT MATCHED THEN INSERT (order_id, status, status_ts, event_id)
VALUES (s.order_id, s.status, s.event_ts, s.event_id);

MERGE INTO CORE.FACT_ORDER_LINE AS f
USING (
    SELECT
        e.order_id
        , e.line_number
        , e.customer_id
        , COALESCE(c.customer_key, -1) AS customer_key
        , e.product_code
        , COALESCE(p.product_key, -1) AS product_key
        , e.event_ts AS order_ts
        , CAST(e.event_ts AS DATE) AS order_date
        , e.channel
        , st.status
        , e.quantity
        , e.unit_price
        , e.discount_pct
        , CAST(ROUND(e.quantity * e.unit_price * (1 - e.discount_pct), 2) AS NUMBER(14, 2)) AS net_amount
        , e.event_id
    FROM RAW.ORDER_EVENT_STREAM AS e
    LEFT JOIN CORE.DIM_CUSTOMER AS c
        ON c.customer_id = e.customer_id
       AND e.event_ts >= c.valid_from
       AND e.event_ts < c.valid_to
    LEFT JOIN CORE.DIM_PRODUCT AS p
        ON p.product_code = e.product_code
    LEFT JOIN CORE.ORDER_STATUS AS st
        ON st.order_id = e.order_id
    WHERE e.event_type = 'ORDER_CREATED'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY e.order_id, e.line_number ORDER BY e.event_id) = 1
) AS s
    ON f.order_id = s.order_id
   AND f.line_number = s.line_number
WHEN NOT MATCHED THEN INSERT (
    order_id, line_number, customer_id, customer_key, product_code, product_key, order_ts, order_date
    , channel, status, quantity, unit_price, discount_pct, net_amount, created_event_id, updated_at
) VALUES (
    s.order_id, s.line_number, s.customer_id, s.customer_key, s.product_code, s.product_key, s.order_ts
    , s.order_date, s.channel, s.status, s.quantity, s.unit_price, s.discount_pct, s.net_amount
    , s.event_id, CURRENT_TIMESTAMP()
);

-- Status changes for lines already loaded. Only orders with an event in this
-- batch can have changed.
UPDATE CORE.FACT_ORDER_LINE AS f
SET
    status = st.status
    , updated_at = CURRENT_TIMESTAMP()
FROM CORE.ORDER_STATUS AS st
WHERE st.order_id = f.order_id
  AND f.status IS DISTINCT FROM st.status
  AND f.order_id IN (SELECT order_id FROM RAW.ORDER_EVENT_STREAM);

-- Late-arriving dimension data: lines loaded before their customer, or before
-- a change that was in effect when the order was placed. Only customer
-- versions written in the last seven days can have moved, which keeps this
-- from scanning the whole fact; a pipeline stopped for longer needs the
-- re-key run by hand (docs/runbook section 5).
UPDATE CORE.FACT_ORDER_LINE AS f
SET
    customer_key = c.customer_key
    , updated_at = CURRENT_TIMESTAMP()
FROM CORE.DIM_CUSTOMER AS c
WHERE c.changed_at >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
  AND c.customer_id = f.customer_id
  AND f.order_ts >= c.valid_from
  AND f.order_ts < c.valid_to
  AND f.customer_key <> c.customer_key;

-- Lines loaded before their product reached the catalogue snapshot.

UPDATE CORE.FACT_ORDER_LINE AS f
SET
    product_key = p.product_key
    , updated_at = CURRENT_TIMESTAMP()
FROM CORE.DIM_PRODUCT AS p
WHERE f.product_key = -1
  AND p.product_code = f.product_code;
