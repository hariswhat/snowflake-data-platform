-- One warehouse per workload, each with its own resource monitor (ADR-0005).
-- Sizes and quotas come from the environment's config (vars); the cost
-- estimate in docs/cost-estimate.md is computed from the same numbers.
-- This script runs once; later changes to sizes and quotas are applied by
-- R__warehouse_sizes_and_quotas.sql.
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_{{ env }}_TRANSFORM
    WAREHOUSE_SIZE = {{ transform_wh_size }}
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 3600
    COMMENT = 'Task DAG and the dynamic table refresh';

CREATE WAREHOUSE IF NOT EXISTS WH_{{ env }}_BI
    WAREHOUSE_SIZE = {{ bi_wh_size }}
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 900
    COMMENT = 'Power BI and analyst queries over MART';

CREATE WAREHOUSE IF NOT EXISTS WH_{{ env }}_ADHOC
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 1800
    COMMENT = 'Engineers: investigation and backfills';

GRANT USAGE, OPERATE ON WAREHOUSE WH_{{ env }}_TRANSFORM TO ROLE RL_{{ env }}_DEPLOYER;
GRANT USAGE ON WAREHOUSE WH_{{ env }}_BI TO ROLE RL_{{ env }}_ANALYST;
GRANT USAGE ON WAREHOUSE WH_{{ env }}_ADHOC TO ROLE RL_{{ env }}_ENGINEER;

-- Resource monitors cover warehouses only. Snowpipe's serverless credits are
-- reported in OPS.CREDITS_BY_DAY (database migrations, R__ops.sql).
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_{{ env }}_TRANSFORM
    WITH CREDIT_QUOTA = {{ transform_monthly_credits }}
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 120 PERCENT DO SUSPEND_IMMEDIATE;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_{{ env }}_BI
    WITH CREDIT_QUOTA = {{ bi_monthly_credits }}
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO NOTIFY
        ON 150 PERCENT DO SUSPEND;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_{{ env }}_ADHOC
    WITH CREDIT_QUOTA = {{ adhoc_monthly_credits }}
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_{{ env }}_TRANSFORM SET RESOURCE_MONITOR = RM_{{ env }}_TRANSFORM;
ALTER WAREHOUSE WH_{{ env }}_BI SET RESOURCE_MONITOR = RM_{{ env }}_BI;
ALTER WAREHOUSE WH_{{ env }}_ADHOC SET RESOURCE_MONITOR = RM_{{ env }}_ADHOC;
