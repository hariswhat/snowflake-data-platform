-- Product dimension, type 1, from the daily catalogue snapshot
-- (RAW.PRODUCT_STREAM). Prices and names are overwritten: reports price
-- orders at the order line's own unit price, so the catalogue's history is
-- not needed for revenue (ADR-0003). Products missing from a snapshot are
-- kept; deactivation comes from is_active in the snapshot.

MERGE INTO CORE.DIM_PRODUCT AS d
USING (
    SELECT
        product_code
        , product_name
        , category
        , list_price
        , is_active
        , SHA2(CONCAT_WS('|',
            COALESCE(product_name, '~'), COALESCE(category, '~'),
            COALESCE(CAST(list_price AS VARCHAR), '~'), COALESCE(CAST(is_active AS VARCHAR), '~')
        ), 256) AS hash_diff
    FROM RAW.PRODUCT_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY product_code ORDER BY file_name DESC, file_row_number DESC) = 1
) AS s
    ON d.product_code = s.product_code
WHEN MATCHED AND d.hash_diff <> s.hash_diff THEN UPDATE SET
    product_name = s.product_name
    , category = s.category
    , list_price = s.list_price
    , is_active = s.is_active
    , hash_diff = s.hash_diff
    , updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    product_key, product_code, product_name, category, list_price, is_active, hash_diff, updated_at
) VALUES (
    CORE.SEQ_PRODUCT_KEY.NEXTVAL, s.product_code, s.product_name, s.category, s.list_price, s.is_active
    , s.hash_diff, CURRENT_TIMESTAMP()
);
