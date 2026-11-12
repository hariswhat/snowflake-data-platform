-- Customer dimension, SCD type 2, from the CRM change export (RAW.CUSTOMER_STREAM).
-- Runs inside one transaction in task T_DIM_CUSTOMER, so both statements read
-- the same stream rows and the stream offset moves only if both succeed.
--
-- Tracked attributes: email, full_name, region, loyalty_tier, signup_date.
-- A change is applied only if it is newer than the CRM row the current
-- version came from (source_updated_at; valid_from cannot be used, because a
-- first version starts in 1900). An older
-- change (the CRM re-sends a stale row) is logged to OPS.LATE_ARRIVAL and
-- skipped; back-dating history is a manual decision (docs/runbook).

INSERT INTO OPS.LATE_ARRIVAL (source_table, business_key, source_ts, current_source_ts, file_name)
SELECT 'RAW.CUSTOMER' AS source_table, b.customer_id, b.updated_at, d.source_updated_at, b.file_name
FROM (
    SELECT customer_id, updated_at, file_name
    FROM RAW.CUSTOMER_STREAM
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_id ORDER BY updated_at DESC, file_name DESC, file_row_number DESC
    ) = 1
) AS b
INNER JOIN CORE.DIM_CUSTOMER AS d
    ON d.customer_id = b.customer_id
   AND d.is_current
WHERE b.updated_at <= d.source_updated_at;

-- One MERGE expires the current version and inserts the new one: each changed
-- key appears twice in the source, once with its key (matches the current
-- row, which is expired) and once with a NULL key (matches nothing, so it is
-- inserted). A key seen for the first time appears once and is inserted with
-- valid_from 1900-01-01, so orders placed before the customer reached the CRM
-- export still find a version.
MERGE INTO CORE.DIM_CUSTOMER AS d
USING (
    WITH batch AS (
        SELECT
            customer_id
            , NULLIF(TRIM(email), '') AS email
            , full_name
            , UPPER(region) AS region
            , UPPER(loyalty_tier) AS loyalty_tier
            , signup_date
            , updated_at
            , SHA2(CONCAT_WS('|',
                COALESCE(NULLIF(TRIM(email), ''), '~'), COALESCE(full_name, '~'), COALESCE(UPPER(region), '~'),
                COALESCE(UPPER(loyalty_tier), '~'), COALESCE(CAST(signup_date AS VARCHAR), '~')
            ), 256) AS hash_diff
        FROM RAW.CUSTOMER_STREAM
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY customer_id ORDER BY updated_at DESC, file_name DESC, file_row_number DESC
        ) = 1
    )

    , changes AS (
        SELECT b.*, cur.customer_id IS NOT NULL AS has_current
        FROM batch AS b
        LEFT JOIN CORE.DIM_CUSTOMER AS cur
            ON cur.customer_id = b.customer_id
           AND cur.is_current
        WHERE cur.customer_id IS NULL
           OR (cur.hash_diff <> b.hash_diff AND b.updated_at > cur.source_updated_at)
    )

    SELECT customer_id AS merge_key, * FROM changes
    UNION ALL
    SELECT NULL AS merge_key, * FROM changes WHERE has_current
) AS s
    ON d.customer_id = s.merge_key
   AND d.is_current
WHEN MATCHED THEN UPDATE SET
    valid_to = s.updated_at
    , is_current = FALSE
    , changed_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    customer_key, customer_id, email, full_name, region, loyalty_tier, signup_date
    , hash_diff, source_updated_at, valid_from, valid_to, is_current, changed_at
) VALUES (
    CORE.SEQ_CUSTOMER_KEY.NEXTVAL, s.customer_id, s.email, s.full_name, s.region, s.loyalty_tier, s.signup_date
    , s.hash_diff, s.updated_at
    , CASE WHEN s.has_current THEN s.updated_at ELSE CAST('1900-01-01' AS TIMESTAMP_NTZ) END
    , CAST('9999-12-31' AS TIMESTAMP_NTZ), TRUE, CURRENT_TIMESTAMP()
);

-- A newer CRM row with no tracked change moves the current version's
-- source_updated_at forward, so an older row that arrives after it is still
-- recognised as stale.
UPDATE CORE.DIM_CUSTOMER AS d
SET source_updated_at = b.updated_at
FROM (
    SELECT
        customer_id
        , updated_at
        , SHA2(CONCAT_WS('|',
            COALESCE(NULLIF(TRIM(email), ''), '~'), COALESCE(full_name, '~'), COALESCE(UPPER(region), '~'),
            COALESCE(UPPER(loyalty_tier), '~'), COALESCE(CAST(signup_date AS VARCHAR), '~')
        ), 256) AS hash_diff
    FROM RAW.CUSTOMER_STREAM
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_id ORDER BY updated_at DESC, file_name DESC, file_row_number DESC
    ) = 1
) AS b
WHERE d.customer_id = b.customer_id
  AND d.is_current
  AND d.hash_diff = b.hash_diff
  AND b.updated_at > d.source_updated_at;
