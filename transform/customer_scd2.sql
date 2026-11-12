-- Customer dimension, SCD type 2, from the CRM change export (RAW.CUSTOMER_STREAM).
-- Runs inside one transaction in task T_DIM_CUSTOMER, so all three statements
-- read the same stream rows and the stream offset moves only if all succeed.
--
-- Tracked attributes: email, full_name, region, loyalty_tier, signup_date.
-- Every CRM row newer than the one the current version came from
-- (source_updated_at) is applied, in updated_at order, so a batch that spans
-- several exports (the graph was stopped) keeps every intermediate version.
-- valid_from cannot be used for the comparison, because a first version
-- starts in 1900. A row no newer than that (the CRM re-sent a stale row) is
-- logged to OPS.LATE_ARRIVAL and skipped; back-dating history is a manual
-- decision (docs/runbook section 6).

-- Stale rows. A row loaded before (same customer and updated_at, an earlier
-- load: a pipe refresh or a reloaded file) is not news and is not logged.
INSERT INTO OPS.LATE_ARRIVAL (source_table, business_key, source_ts, current_source_ts, file_name)
SELECT 'RAW.CUSTOMER' AS source_table, b.customer_id, b.updated_at, d.source_updated_at, b.file_name
FROM (
    SELECT customer_id, updated_at, file_name, loaded_at
    FROM RAW.CUSTOMER_STREAM
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_id, updated_at ORDER BY file_name DESC, file_row_number DESC
    ) = 1
) AS b
INNER JOIN CORE.DIM_CUSTOMER AS d
    ON d.customer_id = b.customer_id
   AND d.is_current
WHERE b.updated_at <= d.source_updated_at
  AND NOT EXISTS (
      SELECT 1
      FROM RAW.CUSTOMER AS r
      WHERE r.customer_id = b.customer_id
        AND r.updated_at = b.updated_at
        AND r.loaded_at < b.loaded_at
  );

-- One MERGE expires the current version and inserts the new ones. The
-- source has one row per new version with a NULL key (matches nothing, so
-- it is inserted), plus, for a customer that has a current version, one row
-- with its key (matches the current row, which is expired where the first
-- new version starts). A key seen for the first time has no row to expire;
-- its first version starts in 1900-01-01, so orders placed before the
-- customer reached the CRM export still find a version.
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
        -- one row per customer and CRM timestamp; on a tie, the later file
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY customer_id, updated_at ORDER BY file_name DESC, file_row_number DESC
        ) = 1
    )

    -- rows newer than the current version, each compared with the row
    -- before it (or with the current version, for the first)
    , newer AS (
        SELECT
            b.*
            , cur.customer_id IS NOT NULL AS has_current
            , COALESCE(
                LAG(b.hash_diff) OVER (PARTITION BY b.customer_id ORDER BY b.updated_at), cur.hash_diff
            ) AS prev_hash
        FROM batch AS b
        LEFT JOIN CORE.DIM_CUSTOMER AS cur
            ON cur.customer_id = b.customer_id
           AND cur.is_current
        WHERE cur.customer_id IS NULL
           OR b.updated_at > cur.source_updated_at
    )

    , versions AS (
        SELECT
            customer_id, email, full_name, region, loyalty_tier, signup_date, updated_at, hash_diff, has_current
            , LEAD(updated_at) OVER (PARTITION BY customer_id ORDER BY updated_at) AS next_updated_at
            , ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at) AS version_in_batch
        FROM newer
        WHERE prev_hash IS NULL
           OR hash_diff <> prev_hash
    )

    SELECT customer_id AS merge_key, * FROM versions WHERE has_current AND version_in_batch = 1
    UNION ALL
    SELECT NULL AS merge_key, * FROM versions
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
    , CASE
        WHEN NOT s.has_current AND s.version_in_batch = 1 THEN CAST('1900-01-01' AS TIMESTAMP_NTZ)
        ELSE s.updated_at
    END
    , COALESCE(s.next_updated_at, CAST('9999-12-31' AS TIMESTAMP_NTZ))
    , s.next_updated_at IS NULL
    , CURRENT_TIMESTAMP()
);

-- Newer CRM rows with no tracked change (after the last change in the batch,
-- or the whole batch) move the current version's source_updated_at forward,
-- so an older row that arrives later is still recognised as stale.
UPDATE CORE.DIM_CUSTOMER AS d
SET source_updated_at = b.updated_at
FROM (
    SELECT customer_id, MAX(updated_at) AS updated_at
    FROM RAW.CUSTOMER_STREAM
    GROUP BY customer_id
) AS b
WHERE d.customer_id = b.customer_id
  AND d.is_current
  AND b.updated_at > d.source_updated_at;
