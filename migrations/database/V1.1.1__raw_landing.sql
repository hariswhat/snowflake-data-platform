-- RAW: one table per source, loaded by an auto-ingest pipe. Each pipe types
-- the columns the transforms need as it loads (COPY with a SELECT), and keeps
-- the original record, the file name and the row number, so any row can be
-- traced to its file and reloaded (ADR-0001).
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_JSON_LINES
    TYPE = JSON
    STRIP_OUTER_ARRAY = FALSE;

CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV_HEADER
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE;

CREATE STAGE IF NOT EXISTS RAW.LANDING
    URL = 'azure://{{ storage_account }}.blob.core.windows.net/landing/'
    STORAGE_INTEGRATION = SI_{{ env }}_LANDING;

CREATE TABLE IF NOT EXISTS RAW.ORDER_EVENT (
    event_id VARCHAR NOT NULL
    , event_type VARCHAR NOT NULL
    , event_ts TIMESTAMP_NTZ NOT NULL
    , order_id VARCHAR NOT NULL
    , customer_id VARCHAR
    , channel VARCHAR
    , line_number NUMBER(4, 0)
    , product_code VARCHAR
    , quantity NUMBER(6, 0)
    , unit_price NUMBER(12, 2)
    , discount_pct NUMBER(5, 4)
    , payload VARIANT
    , file_name VARCHAR NOT NULL
    , file_row_number NUMBER(10, 0) NOT NULL
    , loaded_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS RAW.CUSTOMER (
    customer_id VARCHAR NOT NULL
    , email VARCHAR
    , full_name VARCHAR
    , region VARCHAR
    , loyalty_tier VARCHAR
    , signup_date DATE
    , updated_at TIMESTAMP_NTZ NOT NULL
    , file_name VARCHAR NOT NULL
    , file_row_number NUMBER(10, 0) NOT NULL
    , loaded_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS RAW.PRODUCT (
    product_code VARCHAR NOT NULL
    , product_name VARCHAR
    , category VARCHAR
    , list_price NUMBER(12, 2)
    , is_active BOOLEAN
    , file_name VARCHAR NOT NULL
    , file_row_number NUMBER(10, 0) NOT NULL
    , loaded_at TIMESTAMP_LTZ NOT NULL
);

CREATE PIPE IF NOT EXISTS RAW.PIPE_ORDER_EVENT
    AUTO_INGEST = TRUE
    INTEGRATION = 'NI_{{ env }}_LANDING'
    AS
    COPY INTO RAW.ORDER_EVENT (
        event_id, event_type, event_ts, order_id, customer_id, channel, line_number
        , product_code, quantity, unit_price, discount_pct, payload, file_name, file_row_number, loaded_at
    )
    FROM (
        SELECT
            $1:event_id::VARCHAR
            , $1:event_type::VARCHAR
            , $1:event_ts::TIMESTAMP_NTZ
            , $1:order_id::VARCHAR
            , $1:customer_id::VARCHAR
            , $1:channel::VARCHAR
            , $1:line_number::NUMBER(4, 0)
            , $1:product_code::VARCHAR
            , $1:quantity::NUMBER(6, 0)
            , $1:unit_price::NUMBER(12, 2)
            , $1:discount_pct::NUMBER(5, 4)
            , $1
            , METADATA$FILENAME
            , METADATA$FILE_ROW_NUMBER
            , CURRENT_TIMESTAMP()
        FROM @RAW.LANDING/orders/
    )
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_JSON_LINES');

CREATE PIPE IF NOT EXISTS RAW.PIPE_CUSTOMER
    AUTO_INGEST = TRUE
    INTEGRATION = 'NI_{{ env }}_LANDING'
    AS
    COPY INTO RAW.CUSTOMER (
        customer_id, email, full_name, region, loyalty_tier, signup_date, updated_at
        , file_name, file_row_number, loaded_at
    )
    FROM (
        SELECT
            $1, $2, $3, $4, $5, $6::DATE, $7::TIMESTAMP_NTZ
            , METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
        FROM @RAW.LANDING/customers/
    )
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_HEADER');

CREATE PIPE IF NOT EXISTS RAW.PIPE_PRODUCT
    AUTO_INGEST = TRUE
    INTEGRATION = 'NI_{{ env }}_LANDING'
    AS
    COPY INTO RAW.PRODUCT (
        product_code, product_name, category, list_price, is_active
        , file_name, file_row_number, loaded_at
    )
    FROM (
        SELECT
            $1, $2, $3, $4::NUMBER(12, 2), $5::BOOLEAN
            , METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
        FROM @RAW.LANDING/products/
    )
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_HEADER');

-- Append-only streams: the transforms only ever see new rows (ADR-0002).
CREATE STREAM IF NOT EXISTS RAW.ORDER_EVENT_STREAM ON TABLE RAW.ORDER_EVENT APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS RAW.CUSTOMER_STREAM ON TABLE RAW.CUSTOMER APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS RAW.PRODUCT_STREAM ON TABLE RAW.PRODUCT APPEND_ONLY = TRUE;
