-- Column masking by tag and row filtering by region (ADR-0004). Policies are
-- created once here; a change to a policy body is a new versioned script
-- with ALTER ... SET BODY, because a policy that is attached cannot be
-- replaced. Tag-based masking needs Enterprise edition or higher.
CREATE TAG IF NOT EXISTS GOVERNANCE.PII
    ALLOWED_VALUES 'email', 'name'
    COMMENT = 'Personal data; masked unless the session has RL_{{ env }}_PII_READER';

CREATE MASKING POLICY IF NOT EXISTS GOVERNANCE.MP_PII_STRING AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN val IS NULL THEN NULL
        WHEN IS_ROLE_IN_SESSION('RL_{{ env }}_PII_READER') THEN val
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE.PII') = 'email'
            THEN '***@' || SPLIT_PART(val, '@', 2)
        ELSE '***'
    END
    COMMENT = 'Masks PII-tagged strings; the email domain stays visible for analysis';

ALTER TAG GOVERNANCE.PII SET MASKING POLICY GOVERNANCE.MP_PII_STRING;

ALTER TABLE CORE.DIM_CUSTOMER MODIFY COLUMN email SET TAG GOVERNANCE.PII = 'email';
ALTER TABLE CORE.DIM_CUSTOMER MODIFY COLUMN full_name SET TAG GOVERNANCE.PII = 'name';
-- RAW holds the same values as loaded. Engineers read RAW, so it is masked
-- for them too; the deploy role reads it unmasked (admin V1.0.0).
ALTER TABLE RAW.CUSTOMER MODIFY COLUMN email SET TAG GOVERNANCE.PII = 'email';
ALTER TABLE RAW.CUSTOMER MODIFY COLUMN full_name SET TAG GOVERNANCE.PII = 'name';

-- A row is visible to a role that sees every region, or to a role mapped to
-- the row's region in GOVERNANCE.REGION_ACCESS. IS_ROLE_IN_SESSION follows
-- role inheritance, so a user's secondary roles count too. The argument is
-- named row_region, not region: inside the subquery an unqualified "region"
-- would be the mapping table's column, and the filter would always be true.
CREATE ROW ACCESS POLICY IF NOT EXISTS GOVERNANCE.RAP_REGION AS (row_region VARCHAR) RETURNS BOOLEAN ->
    IS_ROLE_IN_SESSION('RL_{{ env }}_ANALYST_ALL_REGIONS')
    OR EXISTS (
        SELECT 1
        FROM GOVERNANCE.REGION_ACCESS AS m
        WHERE m.region = row_region
          AND IS_ROLE_IN_SESSION(m.role_name)
    )
    COMMENT = 'Limits MART rows to the regions mapped to the session''s roles';
