-- Warehouse sizes and monitor quotas from deploy/envs/<env>.json. V1.0.1
-- creates the warehouses and monitors once; this script is repeatable, and
-- schemachange compares checksums of the rendered text, so changing a size
-- or a quota in the environment's file reruns it on the next admin
-- deployment (docs/runbook section 3).
USE ROLE SYSADMIN;

ALTER WAREHOUSE WH_{{ env }}_TRANSFORM SET WAREHOUSE_SIZE = {{ transform_wh_size }};
ALTER WAREHOUSE WH_{{ env }}_BI SET WAREHOUSE_SIZE = {{ bi_wh_size }};

USE ROLE ACCOUNTADMIN;

ALTER RESOURCE MONITOR RM_{{ env }}_TRANSFORM SET CREDIT_QUOTA = {{ transform_monthly_credits }};
ALTER RESOURCE MONITOR RM_{{ env }}_BI SET CREDIT_QUOTA = {{ bi_monthly_credits }};
ALTER RESOURCE MONITOR RM_{{ env }}_ADHOC SET CREDIT_QUOTA = {{ adhoc_monthly_credits }};
