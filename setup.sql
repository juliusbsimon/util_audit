CREATE TABLE util_audit_records
(
    util_audit_record_id NUMBER
        DEFAULT ON NULL TO_NUMBER(SYS_GUID(),'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX')
        CONSTRAINT util_audit_records_pk PRIMARY KEY,

    transaction_id        VARCHAR2(64),   -- logical event id (GUID)
    db_transaction_id     VARCHAR2(100),  -- DB transaction scope

    table_name            VARCHAR2(255) NOT NULL,

    pk_value_vc           VARCHAR2(4000), -- supports any PK type

    column_name           VARCHAR2(255),
    data_type             VARCHAR2(128),

    transaction_type      VARCHAR2(6)
        CONSTRAINT util_audit_records_trx_chk
        CHECK (transaction_type IN ('INSERT','UPDATE','DELETE')),

    username              VARCHAR2(255),

    old_value             VARCHAR2(4000),
    new_value             VARCHAR2(4000),

    old_clob              CLOB,
    new_clob              CLOB,

    change_hash           VARCHAR2(64),

    audit_context         CLOB CHECK (audit_context IS JSON),

    audit_ts              TIMESTAMP WITH LOCAL TIME ZONE
        DEFAULT SYSTIMESTAMP NOT NULL
)
PARTITION BY RANGE (audit_ts)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
(
    PARTITION p_start VALUES LESS THAN (TIMESTAMP'2025-01-01 00:00:00')
);

CREATE TABLE util_audit_config
(
    table_name   VARCHAR2(255) PRIMARY KEY,
    enabled_flag CHAR(1) CHECK (enabled_flag IN ('Y','N')),
    created_on   DATE DEFAULT SYSDATE,
    created_by   VARCHAR2(100)
);

/
-- Row history lookups
CREATE INDEX util_audit_records_hist_ix
ON util_audit_records (table_name, pk_value_vc, audit_ts DESC);

-- Table timeline scans
CREATE INDEX util_audit_records_tbl_ts_ix
ON util_audit_records (table_name, audit_ts DESC);

-- Hash lookups (optional forensic)
CREATE INDEX util_audit_records_hash_ix
ON util_audit_records (change_hash);

-- JSON context (if queried often)
CREATE SEARCH INDEX util_audit_ctx_jsx
ON util_audit_records (audit_context)
FOR JSON;
/

CREATE OR REPLACE PACKAGE util_audit AS
    ------------------------------------------------------------------------------
    --  PURPOSE
    --      Centralized auditing framework (v2)
    --
    --  FEATURES
    --      • Generic PK support
    --      • JSON context capture
    --      • DB transaction grouping
    --      • Change hashing
    --      • Config-driven enablement
    ------------------------------------------------------------------------------

    ------------------------------------------------------------------------------
    -- CONFIG MANAGEMENT
    ------------------------------------------------------------------------------

    PROCEDURE enable_table (
        p_table_name IN VARCHAR2
    );

    PROCEDURE disable_table (
        p_table_name IN VARCHAR2
    );

    FUNCTION table_enabled (
        p_table_name IN VARCHAR2
    ) RETURN BOOLEAN;

    ------------------------------------------------------------------------------
    -- CONTEXT
    ------------------------------------------------------------------------------

    FUNCTION get_audit_context
        RETURN CLOB;

    ------------------------------------------------------------------------------
    -- CAPTURE (called by triggers)
    ------------------------------------------------------------------------------

    PROCEDURE capture_audit (
        p_transaction_json IN json_object_t
    );

END util_audit;
/

CREATE OR REPLACE PACKAGE BODY util_audit AS

-------------------------------------------------------------------------------
-- ENABLE TABLE
-------------------------------------------------------------------------------
PROCEDURE enable_table (
    p_table_name IN VARCHAR2
) IS
BEGIN
    MERGE INTO util_audit_config c
    USING (SELECT UPPER(p_table_name) table_name FROM dual) src
    ON (c.table_name = src.table_name)
    WHEN MATCHED THEN
        UPDATE SET enabled_flag = 'Y'
    WHEN NOT MATCHED THEN
        INSERT (table_name, enabled_flag, created_on, created_by)
        VALUES (src.table_name, 'Y', SYSDATE, USER);
END;

-------------------------------------------------------------------------------
-- DISABLE TABLE
-------------------------------------------------------------------------------
PROCEDURE disable_table (
    p_table_name IN VARCHAR2
) IS
BEGIN
    UPDATE util_audit_config
    SET enabled_flag = 'N'
    WHERE table_name = UPPER(p_table_name);
END;

-------------------------------------------------------------------------------
-- CHECK IF TABLE ENABLED
-------------------------------------------------------------------------------
FUNCTION table_enabled (
    p_table_name IN VARCHAR2
) RETURN BOOLEAN IS
    v_flag CHAR(1);
BEGIN
    SELECT enabled_flag
    INTO v_flag
    FROM util_audit_config
    WHERE table_name = UPPER(p_table_name);

    RETURN v_flag = 'Y';
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN FALSE;
END;

-------------------------------------------------------------------------------
-- BUILD AUDIT CONTEXT (JSON)
-------------------------------------------------------------------------------
FUNCTION get_audit_context
RETURN CLOB IS
    l_ctx json_object_t := json_object_t();
BEGIN
    l_ctx.put('module', sys_context('USERENV','MODULE'));
    l_ctx.put('action', sys_context('USERENV','ACTION'));
    l_ctx.put('client_id', sys_context('USERENV','CLIENT_IDENTIFIER'));
    l_ctx.put('ip', sys_context('USERENV','IP_ADDRESS'));
    l_ctx.put('host', sys_context('USERENV','HOST'));
    l_ctx.put('os_user', sys_context('USERENV','OS_USER'));
    l_ctx.put('schema', sys_context('USERENV','CURRENT_SCHEMA'));

    IF sys_context('APEX$SESSION','APP_ID') IS NOT NULL THEN
        l_ctx.put('app_id', sys_context('APEX$SESSION','APP_ID'));
        l_ctx.put('page_id', sys_context('APEX$SESSION','APP_PAGE_ID'));
        l_ctx.put('app_user', sys_context('APEX$SESSION','APP_USER'));
        l_ctx.put('session_id', sys_context('APEX$SESSION','APP_SESSION'));
    END IF;

    RETURN l_ctx.to_clob;
END;

-------------------------------------------------------------------------------
-- CAPTURE AUDIT
-------------------------------------------------------------------------------
PROCEDURE capture_audit (
    p_transaction_json IN json_object_t
) IS
    l_context   CLOB := get_audit_context;
    l_clob      CLOB := p_transaction_json.to_clob;
    l_db_txn    VARCHAR2(100) := dbms_transaction.local_transaction_id;
BEGIN
    INSERT INTO util_audit_records
    (
        transaction_id,
        db_transaction_id,
        table_name,
        pk_value_vc,
        transaction_type,
        username,
        column_name,
        data_type,
        old_value,
        new_value,
        old_clob,
        new_clob,
        change_hash,
        audit_context,
        audit_ts
    )
    SELECT
        j.transaction_id,
        l_db_txn,
        j.table_name,
        j.pk_value,
        j.transaction_type,
        j.username,
        j.column_name,
        j.data_type,

        CASE WHEN j.data_type = 'CLOB' THEN NULL ELSE j.old_value END,
        CASE WHEN j.data_type = 'CLOB' THEN NULL ELSE j.new_value END,

        CASE WHEN j.data_type = 'CLOB' THEN j.old_value END,
        CASE WHEN j.data_type = 'CLOB' THEN j.new_value END,

        STANDARD_HASH(
            j.table_name || j.column_name || j.old_value || j.new_value,
            'SHA256'
        ),

        l_context,
        SYSTIMESTAMP
    FROM json_table(
        l_clob, '$'
        COLUMNS (
            transaction_id VARCHAR2(64) PATH '$.transaction_id',
            table_name VARCHAR2(255) PATH '$.table_name',
            pk_value VARCHAR2(4000) PATH '$.pk_value',
            transaction_type VARCHAR2(6) PATH '$.trans_type',
            username VARCHAR2(255) PATH '$.user_name',
            NESTED PATH '$.columns[*]'
            COLUMNS (
                column_name VARCHAR2(255) PATH '$.column_name',
                data_type VARCHAR2(128) PATH '$.data_type',
                old_value CLOB PATH '$.old_value',
                new_value CLOB PATH '$.new_value'
            )
        )
    ) j
    WHERE table_enabled(j.table_name);

EXCEPTION
    WHEN OTHERS THEN
        -- Fail-safe: auditing should not block business logic
        NULL;
END;

END util_audit;
/
