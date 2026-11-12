-- Account-level roles for one environment. Run by the admin deployment
-- (docs/runbook section 1) with a user that holds SECURITYADMIN.
--
-- Functional roles are what people and services are granted. Apart from
-- warehouse usage (V1.0.1), they hold no object privileges themselves: those
-- sit on database roles (access roles) created inside the environment's
-- database (V1.1.0, database migrations).
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
-- The transforms copy email and name from RAW to CORE, and both are masked;
-- the deploy role, which owns and runs the tasks, has to read them unmasked.
-- Engineers do not inherit this: the deploy role sits above them.
GRANT ROLE RL_{{ env }}_PII_READER TO ROLE RL_{{ env }}_DEPLOYER;

-- Tasks run as their owner, which needs EXECUTE TASK.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE RL_{{ env }}_DEPLOYER;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE RL_{{ env }}_DEPLOYER;
-- Serverless alerts (R__ops.sql) also need this.
GRANT EXECUTE MANAGED ALERT ON ACCOUNT TO ROLE RL_{{ env }}_DEPLOYER;
-- Setting a masking policy on a tag (V1.1.3) needs the account-level
-- privilege, even for the owner of both. It also lets this role set or unset
-- masking policies elsewhere in the account; dev and prd share the account
-- (docs/open-issues.md, issue 9).
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE RL_{{ env }}_DEPLOYER;
-- OPS views read SNOWFLAKE.ACCOUNT_USAGE for cost attribution. This shows
-- usage for the whole account, other environments included (issue 9).
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE RL_{{ env }}_DEPLOYER;
