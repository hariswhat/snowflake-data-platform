-- severity: error
-- A customer's versions follow each other: each one ends where the next
-- begins, and none overlaps another.
SELECT customer_id, valid_from
FROM (
    SELECT
        customer_id
        , valid_from
        , valid_to
        , LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS next_from
    FROM CORE.DIM_CUSTOMER
)
WHERE valid_to < valid_from
   OR (next_from IS NOT NULL AND valid_to <> next_from)
