-- Account-level roles for one environment. Run by the admin deployment
-- (docs/runbook section 1) with a user that holds SECURITYADMIN.
--
-- Functional roles are what people and services are granted. They hold no
-- object privileges themselves: those sit on database roles (access roles)
-- created inside the environment's database (V1.1.0, database migrations).
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS RL_{{ env }}_DEPLOYER
    COMMENT = 'Owns every object in RIDGELINE_{{ env }}; used by schemachange and owns the tasks and pipes';
CREATE ROLE IF NOT EXISTS RL_{{ env }}_ENGINEER
    COMMENT = 'Data engineers: read and write RAW, CORE and OPS';
CREATE ROLE IF NOT EXISTS RL_{{ env }}_ANALYST
    COMMENT = 'Analysts and BI: read MART; PII masked; rows limited by region';
CREATE ROLE IF NOT EXISTS RL_{{ env }}_ANALYST_ALL_REGIONS
    COMMENT = 'Analysts who see every region';
CREATE ROLE IF NOT EXISTS RL_{{ env }}_PII_READER
    COMMENT = 'Adds unmasked PII to an analyst role';

GRANT ROLE RL_{{ env }}_ANALYST TO ROLE RL_{{ env }}_ANALYST_ALL_REGIONS;
GRANT ROLE RL_{{ env }}_ANALYST_ALL_REGIONS TO ROLE RL_{{ env }}_ENGINEER;
GRANT ROLE RL_{{ env }}_ENGINEER TO ROLE RL_{{ env }}_DEPLOYER;
GRANT ROLE RL_{{ env }}_DEPLOYER TO ROLE SYSADMIN;
GRANT ROLE RL_{{ env }}_PII_READER TO ROLE SYSADMIN;

-- Tasks run as their owner, which needs EXECUTE TASK.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE RL_{{ env }}_DEPLOYER;
-- OPS views read SNOWFLAKE.ACCOUNT_USAGE for cost attribution.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE RL_{{ env }}_DEPLOYER;
