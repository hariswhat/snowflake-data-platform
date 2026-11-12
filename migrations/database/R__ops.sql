-- OPS: how the pipeline is doing and what it costs, and the two alerts
-- on-call relies on. Repeatable.
--
-- The alerts read INFORMATION_SCHEMA table functions, which have no delay;
-- the history and cost views read SNOWFLAKE.ACCOUNT_USAGE, which keeps a year
-- but can be up to a few hours behind.

CREATE OR REPLACE VIEW OPS.TASK_RUN
    COMMENT = 'Runs of this database''s task graph, last 30 days'
AS
SELECT
    name AS task_name
    , state
    , scheduled_time
    , completed_time
    , DATEDIFF(SECOND, query_start_time, completed_time) AS duration_s
    , error_code
    , error_message
    , graph_run_group_id
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE database_name = 'RIDGELINE_{{ env }}'
  AND scheduled_time >= DATEADD(DAY, -30, CURRENT_TIMESTAMP());

CREATE OR REPLACE VIEW OPS.TASK_FAILURE
    COMMENT = 'Failed task runs in the last day, without the account usage delay'
AS
SELECT name AS task_name, scheduled_time, completed_time, error_code, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -1, CURRENT_TIMESTAMP())
    , RESULT_LIMIT => 10000
    , ERROR_ONLY => TRUE
));

CREATE OR REPLACE VIEW OPS.PIPE_LOAD_ERROR
    COMMENT = 'Files a pipe did not load in full, last day, without the account usage delay'
AS
{% for table in ["ORDER_EVENT", "CUSTOMER", "PRODUCT"] %}
SELECT pipe_name, file_name, status, row_count, error_count, first_error_message, last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'RAW.{{ table }}'
    , START_TIME => DATEADD(DAY, -1, CURRENT_TIMESTAMP())
))
WHERE status <> 'Loaded'
{% if not loop.last %}UNION ALL{% endif %}
{% endfor %};

-- Credits per day by source: the environment's warehouses, and Snowpipe
-- (serverless, not covered by a resource monitor). The cost estimate is
-- checked against this view once the platform runs (docs/cost-estimate.md).
CREATE OR REPLACE VIEW OPS.CREDITS_BY_DAY
    COMMENT = 'Credits per day: warehouses of this environment and Snowpipe'
AS
SELECT
    DATE_TRUNC(DAY, start_time) AS usage_date
    , warehouse_name AS source
    , SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name LIKE 'WH\\_{{ env }}\\_%' ESCAPE '\\'
GROUP BY 1, 2
UNION ALL
SELECT
    DATE_TRUNC(DAY, u.start_time) AS usage_date
    , 'SNOWPIPE:' || p.pipe_name AS source
    , SUM(u.credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY AS u
INNER JOIN SNOWFLAKE.ACCOUNT_USAGE.PIPES AS p
    ON p.pipe_id = u.pipe_id
WHERE p.pipe_catalog = 'RIDGELINE_{{ env }}'
GROUP BY 1, 2;

-- Alerts. Each checks hourly and e-mails when its query returns rows. They
-- are serverless (no WAREHOUSE): on the transform warehouse each check would
-- resume it and pay the 60-second minimum, 48 times a day, which costs more
-- than the task graph (docs/cost-estimate.md).
CREATE OR REPLACE ALERT OPS.ALERT_TASK_FAILURE
    SCHEDULE = '60 MINUTE'
    IF (EXISTS (
        SELECT 1 FROM OPS.TASK_FAILURE
        WHERE scheduled_time > SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'NI_{{ env }}_EMAIL'
            , '{{ alert_email }}'
            , 'RIDGELINE_{{ env }}: task failed'
            , 'A task in RIDGELINE_{{ env }} failed. See OPS.TASK_FAILURE, and OPS.DQ_RESULT if it was T_DATA_QUALITY.'
        );

CREATE OR REPLACE ALERT OPS.ALERT_PIPE_LOAD_ERROR
    SCHEDULE = '60 MINUTE'
    IF (EXISTS (
        SELECT 1 FROM OPS.PIPE_LOAD_ERROR
        WHERE last_load_time > SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'NI_{{ env }}_EMAIL'
            , '{{ alert_email }}'
            , 'RIDGELINE_{{ env }}: file not loaded'
            , 'Snowpipe skipped or partly loaded a file. See OPS.PIPE_LOAD_ERROR.'
        );

ALTER ALERT OPS.ALERT_TASK_FAILURE RESUME;
ALTER ALERT OPS.ALERT_PIPE_LOAD_ERROR RESUME;
