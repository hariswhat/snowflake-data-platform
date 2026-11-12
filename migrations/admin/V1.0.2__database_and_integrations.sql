-- The environment's database and the two integrations Snowpipe needs: a
-- storage integration to read the landing container and a notification
-- integration on the storage queue that Event Grid writes to (ADR-0001).
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS RIDGELINE_{{ env }}
    DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
    COMMENT = 'Ridgeline data platform, {{ env }}';
GRANT OWNERSHIP ON DATABASE RIDGELINE_{{ env }} TO ROLE RL_{{ env }}_DEPLOYER COPY CURRENT GRANTS;

USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS SI_{{ env }}_LANDING
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'AZURE'
    ENABLED = TRUE
    AZURE_TENANT_ID = '{{ azure_tenant_id }}'
    STORAGE_ALLOWED_LOCATIONS = ('azure://{{ storage_account }}.blob.core.windows.net/landing/');

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_{{ env }}_LANDING
    ENABLED = TRUE
    TYPE = QUEUE
    NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
    AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://{{ storage_account }}.queue.core.windows.net/{{ landing_queue }}'
    AZURE_TENANT_ID = '{{ azure_tenant_id }}';

GRANT USAGE ON INTEGRATION SI_{{ env }}_LANDING TO ROLE RL_{{ env }}_DEPLOYER;
GRANT USAGE ON INTEGRATION NI_{{ env }}_LANDING TO ROLE RL_{{ env }}_DEPLOYER;

-- E-mail for the failure alerts (R__ops.sql). Recipients must be verified
-- users of the account.
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_{{ env }}_EMAIL
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('{{ alert_email }}');

GRANT USAGE ON INTEGRATION NI_{{ env }}_EMAIL TO ROLE RL_{{ env }}_DEPLOYER;
