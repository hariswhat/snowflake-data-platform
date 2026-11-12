-- severity: error
-- Every customer has exactly one current version.
SELECT customer_id
FROM CORE.DIM_CUSTOMER
GROUP BY customer_id
HAVING COUNT_IF(is_current) <> 1
