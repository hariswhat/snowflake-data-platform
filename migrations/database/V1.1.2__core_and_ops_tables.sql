-- CORE: conformed dimensions and the order line fact; OPS: what the pipeline
-- records about itself.
CREATE SEQUENCE IF NOT EXISTS CORE.SEQ_CUSTOMER_KEY START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS CORE.SEQ_PRODUCT_KEY START = 1 INCREMENT = 1;

CREATE TABLE IF NOT EXISTS CORE.DIM_CUSTOMER (
    customer_key NUMBER(38, 0) NOT NULL
    , customer_id VARCHAR NOT NULL
    , email VARCHAR
    , full_name VARCHAR
    , region VARCHAR
    , loyalty_tier VARCHAR
    , signup_date DATE
    , hash_diff VARCHAR(64) NOT NULL
    , source_updated_at TIMESTAMP_NTZ NOT NULL
    , valid_from TIMESTAMP_NTZ NOT NULL
    , valid_to TIMESTAMP_NTZ NOT NULL
    , is_current BOOLEAN NOT NULL
    , changed_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS CORE.DIM_PRODUCT (
    product_key NUMBER(38, 0) NOT NULL
    , product_code VARCHAR NOT NULL
    , product_name VARCHAR
    , category VARCHAR
    , list_price NUMBER(12, 2)
    , is_active BOOLEAN
    , hash_diff VARCHAR(64) NOT NULL
    , updated_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS CORE.ORDER_STATUS (
    order_id VARCHAR NOT NULL
    , status VARCHAR NOT NULL
    , status_ts TIMESTAMP_NTZ NOT NULL
    , event_id VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS CORE.FACT_ORDER_LINE (
    order_id VARCHAR NOT NULL
    , line_number NUMBER(4, 0) NOT NULL
    , customer_id VARCHAR NOT NULL
    , customer_key NUMBER(38, 0) NOT NULL
    , product_code VARCHAR NOT NULL
    , product_key NUMBER(38, 0) NOT NULL
    , order_ts TIMESTAMP_NTZ NOT NULL
    , order_date DATE NOT NULL
    , channel VARCHAR
    , status VARCHAR
    , quantity NUMBER(6, 0) NOT NULL
    , unit_price NUMBER(12, 2) NOT NULL
    , discount_pct NUMBER(5, 4) NOT NULL
    , net_amount NUMBER(14, 2) NOT NULL
    , created_event_id VARCHAR NOT NULL
    , updated_at TIMESTAMP_LTZ NOT NULL
);

-- Unknown members, so a fact row can always point at a dimension row.
INSERT INTO CORE.DIM_CUSTOMER (
    customer_key, customer_id, email, full_name, region, loyalty_tier, signup_date
    , hash_diff, source_updated_at, valid_from, valid_to, is_current, changed_at
)
SELECT -1, 'UNKNOWN', NULL, 'Unknown customer', 'UNKNOWN', 'NONE', NULL
    , 'unknown', CAST('1900-01-01' AS TIMESTAMP_NTZ), CAST('1900-01-01' AS TIMESTAMP_NTZ), CAST('9999-12-31' AS TIMESTAMP_NTZ), TRUE, CURRENT_TIMESTAMP()
WHERE NOT EXISTS (SELECT 1 FROM CORE.DIM_CUSTOMER WHERE customer_key = -1);

INSERT INTO CORE.DIM_PRODUCT (
    product_key, product_code, product_name, category, list_price, is_active, hash_diff, updated_at
)
SELECT -1, 'UNKNOWN', 'Unknown product', 'UNKNOWN', NULL, FALSE, 'unknown', CURRENT_TIMESTAMP()
WHERE NOT EXISTS (SELECT 1 FROM CORE.DIM_PRODUCT WHERE product_key = -1);

CREATE TABLE IF NOT EXISTS OPS.LATE_ARRIVAL (
    source_table VARCHAR NOT NULL
    , business_key VARCHAR NOT NULL
    , source_ts TIMESTAMP_NTZ NOT NULL
    , current_source_ts TIMESTAMP_NTZ NOT NULL
    , file_name VARCHAR NOT NULL
    , logged_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ORDER_CREATED events missing a field the fact requires. They are kept out
-- of the fact so one bad record does not fail every run of the fact task; a
-- corrected event re-sent by the shop is loaded normally.
CREATE TABLE IF NOT EXISTS OPS.REJECTED_EVENT (
    event_id VARCHAR NOT NULL
    , order_id VARCHAR NOT NULL
    , line_number NUMBER(4, 0)
    , reason VARCHAR NOT NULL
    , file_name VARCHAR NOT NULL
    , file_row_number NUMBER(10, 0) NOT NULL
    , logged_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS OPS.DQ_RESULT (
    run_id VARCHAR NOT NULL
    , check_name VARCHAR NOT NULL
    , severity VARCHAR NOT NULL
    , failing_rows NUMBER(38, 0) NOT NULL
    , checked_at TIMESTAMP_LTZ NOT NULL
);

-- Region access for the row access policy: one row per role and region.
CREATE TABLE IF NOT EXISTS GOVERNANCE.REGION_ACCESS (
    role_name VARCHAR NOT NULL
    , region VARCHAR NOT NULL
);
