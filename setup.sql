create table UTIL_AUDIT_CONFIG
(
    TABLE_NAME   VARCHAR2(255) not null
        primary key,
    ENABLED_FLAG CHAR
        check (enabled_flag IN ('Y', 'N')),
    CREATED_ON   DATE default SYSDATE,
    CREATED_BY   VARCHAR2(100)
)
/

create table UTIL_AUDIT_TXN
(
    AUDIT_TXN_ID      NUMBER                            default TO_NUMBER(SYS_GUID(), 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX') not null
        constraint UTIL_AUDIT_TXN_PK
            primary key,
    TRANSACTION_ID    VARCHAR2(64)                                                                                        not null
        constraint UTIL_AUDIT_TXN_UK
            unique,
    DB_TRANSACTION_ID VARCHAR2(100),
    TABLE_NAME        VARCHAR2(255)                                                                                       not null,
    PK_VALUE_VC       VARCHAR2(4000),
    TRANSACTION_TYPE  VARCHAR2(6)                                                                                         not null
        constraint UTIL_AUDIT_TXN_TRX_CHK
            check (transaction_type IN ('INSERT', 'UPDATE', 'DELETE')),
    USERNAME          VARCHAR2(255),
    AUDIT_CONTEXT     CLOB
        check (audit_context IS JSON),
    OLD_ROW_JSON      CLOB
        check (old_row_json IS JSON),
    NEW_ROW_JSON      CLOB
        check (new_row_json IS JSON),
    AUDIT_TS          TIMESTAMP(6) default SYSTIMESTAMP                                              not null
)
/

create table UTIL_AUDIT_RECORDS
(
    UTIL_AUDIT_RECORD_ID NUMBER                            default TO_NUMBER(SYS_GUID(), 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX') not null
        constraint UTIL_AUDIT_RECORDS_PK
            primary key,
    TRANSACTION_ID       VARCHAR2(64)
        constraint UTIL_AUDIT_RECORDS_TXN_FK
            references UTIL_AUDIT_TXN (TRANSACTION_ID),
    TABLE_NAME           VARCHAR2(255)                                                                                       not null,
    PK_VALUE_VC          VARCHAR2(4000),
    COLUMN_NAME          VARCHAR2(255),
    DATA_TYPE            VARCHAR2(128),
    TRANSACTION_TYPE     VARCHAR2(6)
        constraint UTIL_AUDIT_RECORDS_TRX_CHK
            check (transaction_type IN ('INSERT', 'UPDATE', 'DELETE')),
    USERNAME             VARCHAR2(255),
    OLD_VALUE            VARCHAR2(4000),
    NEW_VALUE            VARCHAR2(4000),
    OLD_CLOB             CLOB,
    NEW_CLOB             CLOB,
    CHANGE_HASH          VARCHAR2(64),
    AUDIT_TS             TIMESTAMP(6) default SYSTIMESTAMP                                              not null
)
/

create index UTIL_AUDIT_RECORDS_HIST_IX
    on UTIL_AUDIT_RECORDS (TABLE_NAME asc, PK_VALUE_VC asc, AUDIT_TS desc)
/

create index UTIL_AUDIT_RECORDS_TBL_TS_IX
    on UTIL_AUDIT_RECORDS (TABLE_NAME asc, AUDIT_TS desc)
/

create index UTIL_AUDIT_RECORDS_HASH_IX
    on UTIL_AUDIT_RECORDS (CHANGE_HASH)
/

create index UTIL_AUDIT_TXN_HIST_IX
    on UTIL_AUDIT_TXN (TABLE_NAME asc, PK_VALUE_VC asc, AUDIT_TS desc)
/

create index UTIL_AUDIT_TXN_TBL_TS_IX
    on UTIL_AUDIT_TXN (TABLE_NAME asc, AUDIT_TS desc)
/

create view V_UTIL_AUDIT_EVENTS as
SELECT
    t.audit_ts,
    t.table_name,
    t.pk_value_vc,
    t.transaction_type,
    t.username,
    t.transaction_id,
    t.db_transaction_id,
    t.audit_context,
    t.old_row_json,
    t.new_row_json
FROM util_audit_txn t
/

create view V_UTIL_AUDIT_CHANGES as
SELECT
    r.audit_ts,
    r.table_name,
    r.pk_value_vc,
    r.transaction_type,
    r.username,
    r.transaction_id,
    r.column_name,
    r.data_type,
    r.old_value,
    r.new_value,
    r.old_clob,
    r.new_clob,
    r.change_hash
FROM util_audit_records r
/

create view V_UTIL_AUDIT_ROW_HISTORY as
SELECT
    e.audit_ts,
    e.table_name,
    e.pk_value_vc,
    e.transaction_type,
    e.username,
    e.transaction_id,
    e.db_transaction_id,
    c.column_name,
    c.data_type,
    c.old_value,
    c.new_value,
    c.old_clob,
    c.new_clob,
    e.audit_context,
    e.old_row_json,
    e.new_row_json
FROM v_util_audit_events  e
LEFT JOIN v_util_audit_changes c
  ON c.transaction_id = e.transaction_id
/

create view V_UTIL_AUDIT_LATEST_BY_ROW as
SELECT "AUDIT_TS","TABLE_NAME","PK_VALUE_VC","TRANSACTION_TYPE","USERNAME","TRANSACTION_ID","DB_TRANSACTION_ID","AUDIT_CONTEXT","OLD_ROW_JSON","NEW_ROW_JSON","RN"
FROM (
    SELECT
        e.*,
        ROW_NUMBER() OVER (
            PARTITION BY e.table_name, e.pk_value_vc
            ORDER BY e.audit_ts DESC
        ) rn
    FROM v_util_audit_events e
)
WHERE rn = 1
/

create view V_UTIL_AUDIT_EVENT_SUMMARY as
SELECT
    e.audit_ts,
    e.table_name,
    e.pk_value_vc,
    e.transaction_type,
    e.username,
    e.transaction_id,
    LISTAGG(c.column_name, ', ') WITHIN GROUP (ORDER BY c.column_name) AS changed_columns
FROM v_util_audit_events e
LEFT JOIN v_util_audit_changes c
  ON c.transaction_id = e.transaction_id
GROUP BY
    e.audit_ts, e.table_name, e.pk_value_vc, e.transaction_type, e.username, e.transaction_id
/

create PACKAGE util_audit AS
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

    FUNCTION table_enabled_sql (
        p_table_name IN VARCHAR2
    ) RETURN VARCHAR2;

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
create or replace PACKAGE BODY util_audit AS
    -------------------------------------------------------------------------------
-- ENABLE TABLE
-------------------------------------------------------------------------------
    PROCEDURE enable_table(
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
    PROCEDURE disable_table(
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
    FUNCTION table_enabled(
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

    FUNCTION table_enabled_sql(
        p_table_name IN VARCHAR2
    ) RETURN Varchar2
        IS
    BEGIN
        IF table_enabled(p_table_name) THEN
            RETURN 'Y';
        ELSE
            RETURN 'N';
        END IF;
    END;

-------------------------------------------------------------------------------
-- BUILD AUDIT CONTEXT (JSON)
-------------------------------------------------------------------------------
    FUNCTION get_audit_context
        RETURN CLOB IS
        l_ctx json_object_t := json_object_t();
    BEGIN
        l_ctx.put('module', sys_context('USERENV', 'MODULE'));
        l_ctx.put('action', sys_context('USERENV', 'ACTION'));
        l_ctx.put('client_id', sys_context('USERENV', 'CLIENT_IDENTIFIER'));
        l_ctx.put('ip', sys_context('USERENV', 'IP_ADDRESS'));
        l_ctx.put('host', sys_context('USERENV', 'HOST'));
        l_ctx.put('os_user', sys_context('USERENV', 'OS_USER'));
        l_ctx.put('schema', sys_context('USERENV', 'CURRENT_SCHEMA'));

        IF sys_context('APEX$SESSION', 'APP_ID') IS NOT NULL THEN
            l_ctx.put('app_id', sys_context('APEX$SESSION', 'APP_ID'));
            l_ctx.put('page_id', sys_context('APEX$SESSION', 'APP_PAGE_ID'));
            l_ctx.put('app_user', sys_context('APEX$SESSION', 'APP_USER'));
            l_ctx.put('session_id', sys_context('APEX$SESSION', 'APP_SESSION'));
        END IF;

        RETURN l_ctx.to_clob;
    END;
-------------------------------------------------------------------------------
-- CAPTURE AUDIT
-------------------------------------------------------------------------------
    PROCEDURE capture_audit(
        p_transaction_json IN json_object_t
    ) IS
        l_context CLOB          := get_audit_context;
        l_clob    CLOB          := p_transaction_json.to_clob;
        l_db_txn  VARCHAR2(100) := dbms_transaction.local_transaction_id;
    BEGIN
        ----------------------------------------------------------------------------
        -- 1) Insert header row ONCE per transaction_id
        ----------------------------------------------------------------------------
        --DBMS_OUTPUT.PUT_LINE(p_transaction_json.to_clob);
        --begin

            INSERT INTO util_audit_txn
            (transaction_id,
             db_transaction_id,
             table_name,
             pk_value_vc,
             transaction_type,
             username,
             audit_context,
             old_row_json,
             new_row_json,
             audit_ts)
            SELECT jt.transaction_id,
                   l_db_txn,
                   jt.table_name,
                   jt.pk_value,
                   jt.transaction_type,
                   jt.username,
                   l_context,
                   jt.old_row_json,
                   jt.new_row_json,
                   SYSTIMESTAMP
            FROM json_table(
                         l_clob,
                         '$'
                         COLUMNS (
                             transaction_id VARCHAR2(64) PATH '$.transaction_id',
                             table_name VARCHAR2(255) PATH '$.table_name',
                             pk_value VARCHAR2(4000) PATH '$.pk_value',
                             transaction_type VARCHAR2(6) PATH '$.transaction_type',
                             username VARCHAR2(255) PATH '$.user_name',
                             old_row_json CLOB PATH '$.old_row',
                             new_row_json CLOB PATH '$.new_row'
                             )
                 ) jt;

--         EXCEPTION
--             WHEN DUP_VAL_ON_INDEX THEN
--                 -- header already inserted for this transaction_id
--                 NULL;
--         END;

        ----------------------------------------------------------------------------
        -- 2) Insert detail rows for changed columns (your existing approach)
        ----------------------------------------------------------------------------
        INSERT INTO util_audit_records
        (transaction_id,
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
         audit_ts)
        SELECT j.transaction_id,
               j.table_name,
               j.pk_value,
               j.transaction_type,
               j.username,
               j.column_name,
               j.data_type,

               CASE
                   WHEN j.data_type = 'CLOB'
                       THEN NULL
                   ELSE DBMS_LOB.SUBSTR(j.old_value, 4000, 1)
                   END,

               CASE
                   WHEN j.data_type = 'CLOB'
                       THEN NULL
                   ELSE DBMS_LOB.SUBSTR(j.new_value, 4000, 1)
                   END,

               CASE WHEN j.data_type = 'CLOB' THEN j.old_value END,
               CASE WHEN j.data_type = 'CLOB' THEN j.new_value END,

               STANDARD_HASH(
                       DBMS_LOB.SUBSTR(j.table_name, 255) ||
                       DBMS_LOB.SUBSTR(j.column_name, 255) ||
                       DBMS_LOB.SUBSTR(j.old_value, 2000, 1) ||
                       DBMS_LOB.SUBSTR(j.new_value, 2000, 1),
                       'SHA256'
               ),

               SYSTIMESTAMP
        FROM json_table(
                     l_clob, '$'
                     COLUMNS (
                         transaction_id VARCHAR2(64) PATH '$.transaction_id',
                         table_name VARCHAR2(255) PATH '$.table_name',
                         pk_value VARCHAR2(4000) PATH '$.pk_value',
                         transaction_type VARCHAR2(6) PATH '$.transaction_type',
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
        --WHERE util_audit.table_enabled_sql(j.table_name) = 'Y'
        ;

        --
--     EXCEPTION
--         WHEN OTHERS THEN
--             -- Auditing should never break business DML
--             RAISE;
    END capture_audit;


END util_audit;
/
create PACKAGE util_audit_gen AS
    ------------------------------------------------------------------------------
    -- util_audit_gen
    --
    -- Trigger generator for util_audit (v2).
    --
    -- Generates a row-level AFTER INSERT/UPDATE/DELETE trigger that:
    --   - Normalizes transaction_type via INSERTING/UPDATING/DELETING
    --   - Auto-enables auditing in util_audit_config (enable_table)
    --   - Skips audit columns (standard set + configurable list)
    --   - Audits only supported datatypes
    --   - Audits only changed columns (for UPDATE)
    --   - Skips calling util_audit.capture_audit if no columns changed
    --   - Captures row snapshots (old_row/new_row) as JSON
    --
    -- Notes:
    --   * Designed for "single-row" triggers (FOR EACH ROW).
    --   * PK can be any datatype; pk_value is serialized to VARCHAR2 via TO_CHAR
    --     for numbers/dates/timestamps and via direct bind for strings.
    ------------------------------------------------------------------------------

    -- Generate or execute the trigger DDL
    -- p_action: 'EXECUTE' or 'GENERATE'
    PROCEDURE create_audit_trigger(
        p_table_name IN VARCHAR2,
        p_action     IN VARCHAR2 DEFAULT 'EXECUTE'
    );

    -- Drop the trigger if it exists
    PROCEDURE drop_audit_trigger(
        p_table_name IN VARCHAR2,
        p_action     IN VARCHAR2 DEFAULT 'EXECUTE'
    );

    -- Set additional ignored columns (comma-separated, case-insensitive)
    PROCEDURE set_ignored_columns(
        p_columns IN VARCHAR2
    );

END util_audit_gen;
/
create PACKAGE BODY util_audit_gen AS

    g_ignored_columns VARCHAR2(32767);

    --------------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------------
    FUNCTION norm_name(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN UPPER(TRIM(p_name));
    END;

    FUNCTION trig_name(p_table_name IN VARCHAR2) RETURN VARCHAR2 IS
        v_name VARCHAR2(128);
    BEGIN
        -- Keep it <= 30 for older conventions. If you don't care, remove SUBSTR.
        v_name := 'AUD_' || SUBSTR(norm_name(p_table_name), 1, 24);
        RETURN v_name;
    END;

    PROCEDURE exec_sql(p_sql IN CLOB, p_action IN VARCHAR2) IS
        l_cur  INTEGER;
        l_rows NUMBER;
    BEGIN
        IF norm_name(p_action) = 'GENERATE' THEN
            DBMS_OUTPUT.PUT_LINE(p_sql);
            DBMS_OUTPUT.PUT_LINE(CHR(10));
            RETURN;
        END IF;

        l_cur := DBMS_SQL.OPEN_CURSOR;
        BEGIN
            DBMS_SQL.PARSE(l_cur, p_sql, DBMS_SQL.NATIVE);
            l_rows := DBMS_SQL.EXECUTE(l_cur);
            DBMS_SQL.CLOSE_CURSOR(l_cur);
        EXCEPTION
            WHEN OTHERS THEN
                IF DBMS_SQL.IS_OPEN(l_cur) THEN
                    DBMS_SQL.CLOSE_CURSOR(l_cur);
                END IF;
                RAISE;
        END;
    END;

    FUNCTION in_list(p_list IN VARCHAR2, p_item IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN INSTR(',' || UPPER(REPLACE(NVL(p_list,''),' ','')) || ',',
                     ',' || UPPER(TRIM(p_item)) || ',') > 0;
    END;

    FUNCTION is_ignored_column(p_col IN VARCHAR2) RETURN BOOLEAN IS
        v_col VARCHAR2(128) := UPPER(TRIM(p_col));
    BEGIN
        -- Standard audit/meta columns
        IF v_col IN (
            'CREATED','CREATED_ON','CREATED_BY',
            'UPDATED','UPDATED_ON','UPDATED_BY',
            'MODIFIED','MODIFIED_ON','MODIFIED_BY',
            'AUDIT_TS','AUDIT_DATE','AUDIT_CONTEXT',
            'TRANSACTION_ID','DB_TRANSACTION_ID',
            'OLD_ROW_JSON','NEW_ROW_JSON',
            'CHANGE_HASH'
        ) THEN
            RETURN TRUE;
        END IF;

        -- Additional configured ignores
        IF g_ignored_columns IS NOT NULL AND in_list(g_ignored_columns, v_col) THEN
            RETURN TRUE;
        END IF;

        RETURN FALSE;
    END;

    FUNCTION supported_datatype(p_data_type IN VARCHAR2) RETURN BOOLEAN IS
        v_dt VARCHAR2(128) := UPPER(TRIM(p_data_type));
    BEGIN
        IF v_dt IN ('NUMBER','FLOAT','BINARY_FLOAT','BINARY_DOUBLE',
                    'VARCHAR2','CHAR','NCHAR','NVARCHAR2',
                    'DATE','CLOB') THEN
            RETURN TRUE;
        END IF;

        IF v_dt LIKE 'TIMESTAMP%' THEN
            RETURN TRUE;
        END IF;

        IF v_dt LIKE 'INTERVAL %' THEN
            RETURN TRUE;
        END IF;

        -- Exclusions: RAW/BLOB/etc
        RETURN FALSE;
    END;

    -- Build a safe expression that returns a VARCHAR2 representation of a bind.
    -- For CLOB we return the bind itself and let JSON put handle it; for hashing we substr.
    FUNCTION to_char_expr(p_bind_prefix IN VARCHAR2, p_col IN VARCHAR2, p_data_type IN VARCHAR2)
        RETURN VARCHAR2
    IS
        v_dt VARCHAR2(128) := UPPER(TRIM(p_data_type));
    BEGIN
        IF v_dt IN ('VARCHAR2','CHAR','NCHAR','NVARCHAR2') THEN
            RETURN p_bind_prefix || p_col;
        ELSIF v_dt = 'NUMBER' OR v_dt IN ('FLOAT','BINARY_FLOAT','BINARY_DOUBLE') THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col || ')';
        ELSIF v_dt = 'DATE' THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col ||
                   q'[,'YYYY-MM-DD"T"HH24:MI:SS']' || ')';
        ELSIF v_dt LIKE 'TIMESTAMP WITH TIME ZONE' THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col ||
                   q'[,'YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM']' || ')';
        ELSIF v_dt LIKE 'TIMESTAMP WITH LOCAL TIME ZONE' THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col ||
                   q'[,'YYYY-MM-DD"T"HH24:MI:SS.FF']' || ')';
        ELSIF v_dt LIKE 'TIMESTAMP%' THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col ||
                   q'[,'YYYY-MM-DD"T"HH24:MI:SS.FF']' || ')';
        ELSIF v_dt LIKE 'INTERVAL %' THEN
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col || ')';
        ELSIF v_dt = 'CLOB' THEN
            -- JSON object put can accept CLOB via to_clob in your util_audit.capture_audit;
            -- In the trigger we'll put it into JSON directly.
            RETURN p_bind_prefix || p_col;
        ELSE
            -- Fallback
            RETURN 'TO_CHAR(' || p_bind_prefix || p_col || ')';
        END IF;
    END;

    -- Comparison predicate that handles NULL properly.
    FUNCTION changed_predicate(p_col IN VARCHAR2, p_data_type IN VARCHAR2) RETURN VARCHAR2 IS
        v_dt VARCHAR2(128) := UPPER(TRIM(p_data_type));
        v_new VARCHAR2(4000) := ':NEW.' || p_col;
        v_old VARCHAR2(4000) := ':OLD.' || p_col;
    BEGIN
        -- For LOBs, direct != is not allowed; use DBMS_LOB.COMPARE and NULL checks.
        IF v_dt = 'CLOB' THEN
            RETURN '(' ||
                   '(' || v_new || ' IS NULL AND ' || v_old || ' IS NOT NULL)' ||
                   ' OR (' || v_new || ' IS NOT NULL AND ' || v_old || ' IS NULL)' ||
                   ' OR (' || v_new || ' IS NOT NULL AND ' || v_old || ' IS NOT NULL AND ' ||
                         'DBMS_LOB.COMPARE(' || v_new || ',' || v_old || ') != 0)' ||
                   ')';
        END IF;

        RETURN '(' ||
               '(' || v_new || ' != ' || v_old || ')' ||
               ' OR (' || v_new || ' IS NULL AND ' || v_old || ' IS NOT NULL)' ||
               ' OR (' || v_new || ' IS NOT NULL AND ' || v_old || ' IS NULL)' ||
               ')';
    END;

    PROCEDURE set_ignored_columns(p_columns IN VARCHAR2) IS
    BEGIN
        g_ignored_columns := p_columns;
    END;

    --------------------------------------------------------------------------
    -- Public: Drop trigger
    --------------------------------------------------------------------------
    PROCEDURE drop_audit_trigger(
        p_table_name IN VARCHAR2,
        p_action     IN VARCHAR2 DEFAULT 'EXECUTE'
    ) IS
        v_sql CLOB;
        v_trg VARCHAR2(128) := trig_name(p_table_name);
    BEGIN
        v_sql := 'DROP TRIGGER ' || v_trg;
        BEGIN
            exec_sql(v_sql, p_action);
        EXCEPTION
            WHEN OTHERS THEN
                -- ignore "trigger does not exist"
                IF SQLCODE = -4080 THEN
                    NULL;
                ELSE
                    RAISE;
                END IF;
        END;
    END;

    --------------------------------------------------------------------------
    -- Public: Create trigger
    --------------------------------------------------------------------------
    PROCEDURE create_audit_trigger(
        p_table_name IN VARCHAR2,
        p_action     IN VARCHAR2 DEFAULT 'EXECUTE'
    ) IS
        v_table_name VARCHAR2(255) := norm_name(p_table_name);
        v_trg_name   VARCHAR2(128) := trig_name(p_table_name);

        v_pk_col     VARCHAR2(128);
        v_pk_dt      VARCHAR2(128);

        v_sql        CLOB;
        v_has_cols   BOOLEAN := FALSE;

        -- local utility to append
        PROCEDURE ap(p IN VARCHAR2) IS
        BEGIN
            v_sql := v_sql || p || CHR(10);
        END;

    BEGIN
        -- Validate table exists
        DECLARE
            v_cnt NUMBER;
        BEGIN
            SELECT COUNT(*)
            INTO v_cnt
            FROM user_tables
            WHERE table_name = v_table_name;

            IF v_cnt = 0 THEN
                RAISE_APPLICATION_ERROR(-20001, 'Table not found in schema: ' || v_table_name);
            END IF;
        END;

        -- Determine PK column (single-column PK required for the generator)
        BEGIN
            SELECT cols.column_name
            INTO v_pk_col
            FROM user_constraints cons
            JOIN user_cons_columns cols
              ON cons.constraint_name = cols.constraint_name
             AND cons.owner          = cols.owner
            WHERE cons.table_name = v_table_name
              AND cons.constraint_type = 'P'
            ORDER BY cols.position
            FETCH FIRST 1 ROWS ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'No primary key found for table: ' || v_table_name);
        END;

        -- PK datatype
        SELECT data_type
        INTO v_pk_dt
        FROM user_tab_columns
        WHERE table_name = v_table_name
          AND column_name = v_pk_col;

        v_sql := EMPTY_CLOB();

        ap('CREATE OR REPLACE TRIGGER ' || v_trg_name);
        ap('AFTER INSERT OR UPDATE OR DELETE ON ' || v_table_name);
        ap('FOR EACH ROW');
        ap('DECLARE');
        ap('    l_txn_id    VARCHAR2(64) := RAWTOHEX(SYS_GUID());');
        ap('    l_db_txn    VARCHAR2(100) := DBMS_TRANSACTION.LOCAL_TRANSACTION_ID;');
        ap('    l_action    VARCHAR2(6);');
        ap('    l_has_changes BOOLEAN := FALSE;');
        ap('    v_audit_json JSON_OBJECT_T := JSON_OBJECT_T();');
        ap('    v_cols_arr   JSON_ARRAY_T  := JSON_ARRAY_T();');
        ap('    v_col_obj    JSON_OBJECT_T := JSON_OBJECT_T();');
        ap('    v_old_row    JSON_OBJECT_T := JSON_OBJECT_T();');
        ap('    v_new_row    JSON_OBJECT_T := JSON_OBJECT_T();');
        ap('BEGIN');
        ap('    -- Normalize transaction type (do NOT rely on ORA_SYSEVENT)');
        ap('    l_action := CASE');
        ap('        WHEN INSERTING THEN ''INSERT''');
        ap('        WHEN UPDATING  THEN ''UPDATE''');
        ap('        WHEN DELETING  THEN ''DELETE''');
        ap('    END;');
        ap('');
        ap('    -- Ensure table enabled (auto-register)');
        ap('    util_audit.enable_table(''' || v_table_name || ''');');
        ap('');

        -- pk_value serialization
        ap('    -- Primary key value');
        ap('    v_audit_json.put(''pk_value'', ' ||
           CASE
               WHEN UPPER(v_pk_dt) IN ('VARCHAR2','CHAR','NCHAR','NVARCHAR2') THEN
                   'CASE WHEN INSERTING THEN :NEW.' || v_pk_col || ' ELSE :OLD.' || v_pk_col || ' END'
               WHEN UPPER(v_pk_dt) = 'DATE' THEN
                   'CASE WHEN INSERTING THEN TO_CHAR(:NEW.' || v_pk_col || q'[,'YYYY-MM-DD"T"HH24:MI:SS']' || ') ' ||
                   'ELSE TO_CHAR(:OLD.' || v_pk_col || q'[,'YYYY-MM-DD"T"HH24:MI:SS']' || ') END'
               WHEN UPPER(v_pk_dt) LIKE 'TIMESTAMP%' THEN
                   'CASE WHEN INSERTING THEN TO_CHAR(:NEW.' || v_pk_col || q'[,'YYYY-MM-DD"T"HH24:MI:SS.FF']' || ') ' ||
                   'ELSE TO_CHAR(:OLD.' || v_pk_col || q'[,'YYYY-MM-DD"T"HH24:MI:SS.FF']' || ') END'
               ELSE
                   'CASE WHEN INSERTING THEN TO_CHAR(:NEW.' || v_pk_col || ') ELSE TO_CHAR(:OLD.' || v_pk_col || ') END'
           END
           || ');');

        ap('    v_audit_json.put(''transaction_id'', to_char(l_txn_id));');
        ap('    v_audit_json.put(''db_transaction_id'', to_char(l_db_txn));');
        ap('    v_audit_json.put(''table_name'', ''' || v_table_name || ''');');
        ap('    v_audit_json.put(''transaction_type'', l_action);');
        ap('    v_audit_json.put(''user_name'', NVL(sys_context(''APEX$SESSION'',''APP_USER''), USER));');
        ap('    v_audit_json.put(''audit_ts'',TO_CHAR(SYSTIMESTAMP,''YYYY-MM-DD"T"HH24:MI:SS.FF TZH:TZM''));');
        ap('');

        -- Build row snapshots (supported columns only, excluding ignored)
        ap('    -- Row snapshots (supported columns only)');
        FOR c IN (
            SELECT column_name, data_type
            FROM user_tab_columns
            WHERE table_name = v_table_name
            ORDER BY column_id
        ) LOOP
            IF is_ignored_column(c.column_name) THEN
                CONTINUE;
            END IF;
            IF NOT supported_datatype(c.data_type) THEN
                CONTINUE;
            END IF;

            -- Old row put
            ap('    IF NOT INSERTING THEN');
            ap('        v_old_row.put(''' || c.column_name || ''', ' ||
               to_char_expr(':OLD.', c.column_name, c.data_type) || ');');
            ap('    END IF;');

            -- New row put
            ap('    IF NOT DELETING THEN');
            ap('        v_new_row.put(''' || c.column_name || ''', ' ||
               to_char_expr(':NEW.', c.column_name, c.data_type) || ');');
            ap('    END IF;');
        END LOOP;

        ap('    v_audit_json.put(''old_row'', v_old_row);');
        ap('    v_audit_json.put(''new_row'', v_new_row);');
        ap('');

        -- Column changes array
        ap('    -- Column-level changes');
        FOR c IN (
            SELECT column_name, data_type
            FROM user_tab_columns
            WHERE table_name = v_table_name
            ORDER BY column_id
        ) LOOP
            IF is_ignored_column(c.column_name) THEN
                CONTINUE;
            END IF;
            IF NOT supported_datatype(c.data_type) THEN
                CONTINUE;
            END IF;

            v_has_cols := TRUE;

            ap('    IF INSERTING OR DELETING OR (UPDATING AND ' || changed_predicate(c.column_name, c.data_type) || ') THEN');
            ap('        l_has_changes := TRUE;');
            ap('        v_col_obj := JSON_OBJECT_T();');
            ap('        v_col_obj.put(''column_name'', ''' || c.column_name || ''');');
            ap('        v_col_obj.put(''data_type'', ''' || UPPER(c.data_type) || ''');');

            -- old_value/new_value in JSON - keep CLOBs as-is in JSON
            IF UPPER(c.data_type) = 'CLOB' THEN
                ap('        v_col_obj.put(''old_value'', CASE WHEN INSERTING THEN NULL ELSE :OLD.' || c.column_name || ' END);');
                ap('        v_col_obj.put(''new_value'', CASE WHEN DELETING THEN NULL ELSE :NEW.' || c.column_name || ' END);');
            ELSE
                ap('        v_col_obj.put(''old_value'', CASE WHEN INSERTING THEN NULL ELSE ' ||
                   to_char_expr(':OLD.', c.column_name, c.data_type) || ' END);');
                ap('        v_col_obj.put(''new_value'', CASE WHEN DELETING THEN NULL ELSE ' ||
                   to_char_expr(':NEW.', c.column_name, c.data_type) || ' END);');
            END IF;

            ap('        v_cols_arr.append(v_col_obj);');
            ap('    END IF;');
        END LOOP;

        ap('');
        ap('    IF NOT l_has_changes THEN');
        ap('        RETURN;');
        ap('    END IF;');
        ap('');
        ap('    v_audit_json.put(''columns'', v_cols_arr);');
        ap('');
        ap('    -- Write audit');
        ap('    util_audit.capture_audit(v_audit_json);');
        ap('');
        ap('EXCEPTION');
        ap('    WHEN OTHERS THEN');
        ap('        -- Do not break business DML');
        ap('        NULL;');
        ap('END;');

        IF NOT v_has_cols THEN
            RAISE_APPLICATION_ERROR(-20003, 'No auditable columns found for table: ' || v_table_name);
        END IF;

        exec_sql(v_sql, p_action);

    END create_audit_trigger;

END util_audit_gen;
/




