-- The task DAG (ADR-0002). Repeatable: schemachange reruns it whenever this
-- file or an included transform changes.
--
--   T_ROOT (hourly, only when a stream has rows)
--     +-- T_DIM_PRODUCT    product_upsert.sql
--     +-- T_DIM_CUSTOMER   customer_scd2.sql
--           \__ both __ T_FACT_ORDER_LINE   order_line.sql
--                          \__ T_DATA_QUALITY  transform/dq checks
--
-- Each transform runs in one transaction, so the statements in it read the
-- same stream rows and the stream advances only if all of them succeed. A
-- failed task is retried by the next scheduled run, which sees the same rows.
--
-- Tasks cannot be changed while the root is running a graph: suspend the
-- root, replace, then resume the whole graph from the root.
ALTER TASK IF EXISTS CORE.T_ROOT SUSPEND;

CREATE OR REPLACE TASK CORE.T_ROOT
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    SCHEDULE = 'USING CRON 15 * * * * UTC'
    USER_TASK_TIMEOUT_MS = 3600000
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    COMMENT = 'Starts the graph when any RAW stream has new rows'
    WHEN SYSTEM$STREAM_HAS_DATA('RAW.ORDER_EVENT_STREAM')
      OR SYSTEM$STREAM_HAS_DATA('RAW.CUSTOMER_STREAM')
      OR SYSTEM$STREAM_HAS_DATA('RAW.PRODUCT_STREAM')
AS
    SELECT 1;

CREATE OR REPLACE TASK CORE.T_DIM_PRODUCT
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    COMMENT = 'Product dimension, type 1 (transform/product_upsert.sql)'
    AFTER CORE.T_ROOT
AS
EXECUTE IMMEDIATE $$
BEGIN
    BEGIN TRANSACTION;
    {% include "modules/product_upsert.sql" %}
    COMMIT;
END;
$$;

CREATE OR REPLACE TASK CORE.T_DIM_CUSTOMER
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    COMMENT = 'Customer dimension, SCD type 2 (transform/customer_scd2.sql)'
    AFTER CORE.T_ROOT
AS
EXECUTE IMMEDIATE $$
BEGIN
    BEGIN TRANSACTION;
    {% include "modules/customer_scd2.sql" %}
    COMMIT;
END;
$$;

CREATE OR REPLACE TASK CORE.T_FACT_ORDER_LINE
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    COMMENT = 'Order status and order lines (transform/order_line.sql)'
    AFTER CORE.T_DIM_PRODUCT, CORE.T_DIM_CUSTOMER
AS
EXECUTE IMMEDIATE $$
BEGIN
    BEGIN TRANSACTION;
    {% include "modules/order_line.sql" %}
    COMMIT;
END;
$$;

-- Records every check, then fails the task if an error-severity check found
-- rows. A failed task shows in task history and in OPS.TASK_FAILURE, which the
-- alert reads (R__ops.sql).
CREATE OR REPLACE TASK CORE.T_DATA_QUALITY
    WAREHOUSE = WH_{{ env }}_TRANSFORM
    COMMENT = 'Data quality checks from transform/dq'
    AFTER CORE.T_FACT_ORDER_LINE
AS
EXECUTE IMMEDIATE $$
DECLARE
    run_id VARCHAR DEFAULT UUID_STRING();
    errors INTEGER DEFAULT 0;
    dq_failed EXCEPTION (-20001, 'Data quality checks failed; see OPS.DQ_RESULT');
BEGIN
{% for check in dq_checks %}
    INSERT INTO OPS.DQ_RESULT (run_id, check_name, severity, failing_rows, checked_at)
    SELECT :run_id, '{{ check.name }}', '{{ check.severity }}', COUNT(*), CURRENT_TIMESTAMP()
    FROM (
        {% include "modules/dq/" ~ check.name ~ ".sql" %}
    );
{% endfor %}
    SELECT COUNT(*) INTO :errors
    FROM OPS.DQ_RESULT
    WHERE run_id = :run_id AND severity = 'error' AND failing_rows > 0;
    IF (errors > 0) THEN
        RAISE dq_failed;
    END IF;
END;
$$;

SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CORE.T_ROOT');
