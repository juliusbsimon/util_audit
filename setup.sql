CREATE TABLE util_audit_records
(
    util_audit_record_id NUMBER
        DEFAULT ON NULL TO_NUMBER(SYS_GUID(), 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX')
        CONSTRAINT util_audit_records_pk PRIMARY KEY,

    transaction_id       VARCHAR2(64),   -- logical event id (GUID)

    table_name           VARCHAR2(255) NOT NULL,

    pk_value_vc          VARCHAR2(4000), -- supports any PK type

    column_name          VARCHAR2(255),
    data_type            VARCHAR2(128),
    transaction_type     VARCHAR2(6)
        CONSTRAINT util_audit_records_trx_chk
            CHECK (transaction_type IN ('INSERT', 'UPDATE', 'DELETE')),

    username             VARCHAR2(255),

    old_value            VARCHAR2(4000),
    new_value            VARCHAR2(4000),

    old_clob             CLOB,
    new_clob             CLOB,

    change_hash          VARCHAR2(64),

    audit_ts             TIMESTAMP WITH LOCAL TIME ZONE
        DEFAULT SYSTIMESTAMP           NOT NULL
)
    PARTITION BY RANGE (audit_ts)
    INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_start VALUES LESS THAN (TIMESTAMP'2025-01-01 00:00:00')
);

CREATE TABLE util_audit_config
(
    table_name   VARCHAR2(255) PRIMARY KEY,
    enabled_flag CHAR(1) CHECK (enabled_flag IN ('Y', 'N')),
    created_on   DATE DEFAULT SYSDATE,
    created_by   VARCHAR2(100)
);

CREATE TABLE util_audit_txn
(
    audit_txn_id      NUMBER
        DEFAULT ON NULL TO_NUMBER(SYS_GUID(), 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX')
        CONSTRAINT util_audit_txn_pk PRIMARY KEY,

    transaction_id    VARCHAR2(64)  NOT NULL, -- GUID from trigger
    db_transaction_id VARCHAR2(100),          -- dbms_transaction.local_transaction_id

    table_name        VARCHAR2(255) NOT NULL,
    pk_value_vc       VARCHAR2(4000),

    transaction_type  VARCHAR2(6)   NOT NULL
        CONSTRAINT util_audit_txn_trx_chk
            CHECK (transaction_type IN ('INSERT', 'UPDATE', 'DELETE')),

    username          VARCHAR2(255),

    audit_context     CLOB CHECK (audit_context IS JSON),

    old_row_json      CLOB CHECK (old_row_json IS JSON),
    new_row_json      CLOB CHECK (new_row_json IS JSON),

    audit_ts          TIMESTAMP WITH LOCAL TIME ZONE
        DEFAULT SYSTIMESTAMP        NOT NULL,

    CONSTRAINT util_audit_txn_uk UNIQUE (transaction_id)
)
    PARTITION BY RANGE (audit_ts)
    INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_start VALUES LESS THAN (TIMESTAMP'2025-01-01 00:00:00')
);

CREATE INDEX util_audit_txn_hist_ix
    ON util_audit_txn (table_name, pk_value_vc, audit_ts DESC);

CREATE INDEX util_audit_txn_tbl_ts_ix
    ON util_audit_txn (table_name, audit_ts DESC);

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

ALTER TABLE util_audit_records
    ADD CONSTRAINT util_audit_records_txn_fk
        FOREIGN KEY (transaction_id)
            REFERENCES util_audit_txn (transaction_id);
/
CREATE OR REPLACE VIEW v_util_audit_events AS
SELECT t.audit_ts,
       t.table_name,
       t.pk_value_vc,
       t.transaction_type,
       t.username,
       t.transaction_id,
       t.db_transaction_id,
       t.audit_context,
       t.old_row_json,
       t.new_row_json
FROM util_audit_txn t;
/
CREATE OR REPLACE VIEW v_util_audit_changes AS
SELECT r.audit_ts,
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
FROM util_audit_records r;
/
CREATE OR REPLACE VIEW v_util_audit_row_history AS
SELECT e.audit_ts,
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
FROM v_util_audit_events e
         LEFT JOIN v_util_audit_changes c
                   ON c.transaction_id = e.transaction_id;
/
CREATE OR REPLACE VIEW v_util_audit_latest_by_row AS
SELECT *
FROM (SELECT e.*,
             ROW_NUMBER() OVER (
                 PARTITION BY e.table_name, e.pk_value_vc
                 ORDER BY e.audit_ts DESC
                 ) rn
      FROM v_util_audit_events e)
WHERE rn = 1;
/
CREATE OR REPLACE VIEW v_util_audit_event_summary AS
SELECT e.audit_ts,
       e.table_name,
       e.pk_value_vc,
       e.transaction_type,
       e.username,
       e.transaction_id,
       LISTAGG(c.column_name, ', ') WITHIN GROUP (ORDER BY c.column_name) AS changed_columns
FROM v_util_audit_events e
         LEFT JOIN v_util_audit_changes c
                   ON c.transaction_id = e.transaction_id
GROUP BY e.audit_ts, e.table_name, e.pk_value_vc, e.transaction_type, e.username, e.transaction_id;


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

    PROCEDURE enable_table(
        p_table_name IN VARCHAR2
    );

    PROCEDURE disable_table(
        p_table_name IN VARCHAR2
    );

    FUNCTION table_enabled(
        p_table_name IN VARCHAR2
    ) RETURN BOOLEAN;

     FUNCTION table_enabled_sql(
        p_table_name IN VARCHAR2
    ) RETURN char;
    ------------------------------------------------------------------------------
    -- CONTEXT
    ------------------------------------------------------------------------------

    FUNCTION get_audit_context
        RETURN CLOB;

    ------------------------------------------------------------------------------
    -- CAPTURE (called by triggers)
    ------------------------------------------------------------------------------

    PROCEDURE capture_audit(
        p_transaction_json IN json_object_t
    );

END util_audit;
/

CREATE OR REPLACE PACKAGE BODY util_audit AS
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
        MERGE INTO util_audit_txn t
        USING (SELECT jt.transaction_id,
                      jt.table_name,
                      jt.pk_value,
                      jt.transaction_type,
                      jt.username,
                      jt.old_row_json,
                      jt.new_row_json
               FROM json_table(
                            l_clob, '$'
                            COLUMNS (
                                transaction_id VARCHAR2(64) PATH '$.transaction_id',
                                table_name VARCHAR2(255) PATH '$.table_name',
                                pk_value VARCHAR2(4000) PATH '$.pk_value',
                                transaction_type VARCHAR2(6) PATH '$.trans_type',
                                username VARCHAR2(255) PATH '$.user_name',
                                old_row_json CLOB PATH '$.old_row',
                                new_row_json CLOB PATH '$.new_row'
                                )
                    ) jt) src
        ON (t.transaction_id = src.transaction_id)
        WHEN NOT MATCHED THEN
            INSERT (transaction_id,
                    db_transaction_id,
                    table_name,
                    pk_value_vc,
                    transaction_type,
                    username,
                    audit_context,
                    old_row_json,
                    new_row_json,
                    audit_ts)
            VALUES (src.transaction_id,
                    l_db_txn,
                    src.table_name,
                    src.pk_value,
                    src.transaction_type,
                    src.username,
                    l_context,
                    src.old_row_json,
                    src.new_row_json,
                    SYSTIMESTAMP);

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

               CASE WHEN j.data_type = 'CLOB' THEN NULL ELSE j.old_value END,
               CASE WHEN j.data_type = 'CLOB' THEN NULL ELSE j.new_value END,

               CASE WHEN j.data_type = 'CLOB' THEN j.old_value END,
               CASE WHEN j.data_type = 'CLOB' THEN j.new_value END,

               STANDARD_HASH(
                       j.table_name || j.column_name || j.old_value || j.new_value,
                       'SHA256'
               ),
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
        WHERE table_enabled_sql(j.table_name) = 'Y';

    EXCEPTION
        WHEN OTHERS THEN
            -- Auditing should never break business DML
            NULL;
    END capture_audit;

    FUNCTION table_enabled_sql(
        p_table_name IN VARCHAR2
    ) RETURN CHAR
        IS
    BEGIN
        IF table_enabled(p_table_name) THEN
            RETURN 'Y';
        ELSE
            RETURN 'N';
        END IF;
    END;

END util_audit;
/
CREATE OR REPLACE PACKAGE util_audit_gen AS

    PROCEDURE create_audit_trigger(
        p_table_name IN VARCHAR2,
        p_columns IN VARCHAR2 DEFAULT NULL,
        p_action IN VARCHAR2 DEFAULT 'EXECUTE'
    );

    PROCEDURE drop_audit_trigger(
        p_table_name IN VARCHAR2
    );

END util_audit_gen;
/
CREATE OR REPLACE PACKAGE BODY util_audit_gen AS
    ------------------------------------------------------------------
-- SQL EXEC / PRINT
------------------------------------------------------------------
    PROCEDURE run_sql(p_sql CLOB, p_action VARCHAR2) IS
    BEGIN
        IF p_action = 'EXECUTE' THEN
            EXECUTE IMMEDIATE p_sql;
        ELSE
            DBMS_OUTPUT.PUT_LINE(p_sql);
        END IF;
    END;

------------------------------------------------------------------
-- PK DETECTION
------------------------------------------------------------------
    FUNCTION get_pk(p_table VARCHAR2) RETURN VARCHAR2 IS
        v_pk VARCHAR2(128);
    BEGIN
        SELECT cols.column_name
        INTO v_pk
        FROM user_constraints cons
                 JOIN user_cons_columns cols
                      ON cons.constraint_name = cols.constraint_name
        WHERE cons.table_name = UPPER(p_table)
          AND cons.constraint_type = 'P'
          AND cols.position = 1;

        RETURN v_pk;
    END;

------------------------------------------------------------------
-- COLUMN LIST WITH AUTO EXCLUSIONS
------------------------------------------------------------------
    FUNCTION get_columns(p_table VARCHAR2, p_cols VARCHAR2)
        RETURN SYS.ODCIVARCHAR2LIST IS
        v_list SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
    BEGIN
        IF p_cols IS NOT NULL THEN
            FOR r IN (
                SELECT REGEXP_SUBSTR(p_cols, '[^,]+', 1, LEVEL) col
                FROM dual
                CONNECT BY LEVEL <= REGEXP_COUNT(p_cols, ',') + 1
                )
                LOOP
                    v_list.EXTEND;
                    v_list(v_list.COUNT) := UPPER(TRIM(r.col));
                END LOOP;

        ELSE
            FOR r IN (
                SELECT column_name
                FROM user_tab_columns
                WHERE table_name = UPPER(p_table)
                  AND data_type NOT IN ('BLOB', 'RAW', 'LONG', 'LONG RAW')
                  AND column_name NOT IN (
                                          'CREATED', 'CREATED_BY', 'CREATED_ON',
                                          'UPDATED', 'UPDATED_BY', 'UPDATED_ON',
                                          'MODIFIED', 'MODIFIED_BY', 'MODIFIED_ON',
                                          'ROW_VERSION'
                    )
                )
                LOOP
                    v_list.EXTEND;
                    v_list(v_list.COUNT) := r.column_name;
                END LOOP;
        END IF;

        RETURN v_list;
    END;

------------------------------------------------------------------
-- CREATE TRIGGER
------------------------------------------------------------------
    PROCEDURE create_audit_trigger(
        p_table_name IN VARCHAR2,
        p_columns IN VARCHAR2 DEFAULT NULL,
        p_action IN VARCHAR2 DEFAULT 'EXECUTE'
    ) IS
        v_sql  CLOB;
        v_pk   VARCHAR2(128);
        v_cols SYS.ODCIVARCHAR2LIST;
    BEGIN
        v_pk := get_pk(p_table_name);
        v_cols := get_columns(p_table_name, p_columns);

        v_sql :=
                'CREATE OR REPLACE TRIGGER aud_' || LOWER(p_table_name) || CHR(10) ||
                'AFTER INSERT OR UPDATE OR DELETE ON ' || p_table_name || CHR(10) ||
                'FOR EACH ROW' || CHR(10) ||
                'DECLARE' || CHR(10) ||
                '  l_txn_id VARCHAR2(64) := RAWTOHEX(SYS_GUID());' || CHR(10) ||
                '  l_action VARCHAR2(6) := ORA_SYSEVENT;' || CHR(10) ||
                '  l_has_changes BOOLEAN := FALSE;' || CHR(10) ||
                '  v_audit_json json_object_t := json_object_t();' || CHR(10) ||
                '  v_columns json_array_t := json_array_t();' || CHR(10) ||
                '  v_col json_object_t := json_object_t();' || CHR(10) ||
                '  v_old_row json_object_t := json_object_t();' || CHR(10) ||
                '  v_new_row json_object_t := json_object_t();' || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '  v_audit_json.put(''transaction_id'', l_txn_id);' || CHR(10) ||
                '  v_audit_json.put(''table_name'', ''' || p_table_name || ''');' || CHR(10) ||
                '  v_audit_json.put(''trans_type'', l_action);' || CHR(10) ||
                '  v_audit_json.put(''user_name'', NVL(sys_context(''APEX$SESSION'',''APP_USER''),USER));' || CHR(10) ||
                '  IF INSERTING THEN v_audit_json.put(''pk_value'', TO_CHAR(:NEW.' || v_pk || '));' || CHR(10) ||
                '  ELSE v_audit_json.put(''pk_value'', TO_CHAR(:OLD.' || v_pk || ')); END IF;' || CHR(10);

        FOR i IN 1 .. v_cols.COUNT
            LOOP
                v_sql := v_sql ||
                         '  IF NOT INSERTING THEN v_old_row.put(''' || v_cols(i) || ''', :OLD.' || v_cols(i) ||
                         '); END IF;' || CHR(10) ||
                         '  IF NOT DELETING THEN v_new_row.put(''' || v_cols(i) || ''', :NEW.' || v_cols(i) ||
                         '); END IF;' || CHR(10) ||
                         '  IF NVL(:OLD.' || v_cols(i) || ',''§'') <> NVL(:NEW.' || v_cols(i) || ',''§'') THEN' ||
                         CHR(10) ||
                         '     l_has_changes := TRUE;' || CHR(10) ||
                         '     v_col := json_object_t();' || CHR(10) ||
                         '     v_col.put(''column_name'',''' || v_cols(i) || ''');' || CHR(10) ||
                         '     v_col.put(''data_type'',''VARCHAR2'');' || CHR(10) ||
                         '     v_col.put(''old_value'', :OLD.' || v_cols(i) || ');' || CHR(10) ||
                         '     v_col.put(''new_value'', :NEW.' || v_cols(i) || ');' || CHR(10) ||
                         '     v_columns.append(v_col);' || CHR(10) ||
                         '  END IF;' || CHR(10);

            END LOOP;

        v_sql := v_sql ||
                 '  IF l_has_changes OR INSERTING OR DELETING THEN' || CHR(10) ||
                 '     v_audit_json.put(''columns'', v_columns);' || CHR(10) ||
                 '     v_audit_json.put(''old_row'', v_old_row);' || CHR(10) ||
                 '     v_audit_json.put(''new_row'', v_new_row);' || CHR(10) ||
                 '     util_audit.capture_audit(v_audit_json);' || CHR(10) ||
                 '  END IF;' || CHR(10) ||
                 'END;';

        run_sql(v_sql, p_action);

        ------------------------------------------------------------------
        -- AUTO ENABLE CONFIG
        ------------------------------------------------------------------
        IF p_action = 'EXECUTE' THEN
            util_audit.enable_table(p_table_name);
        END IF;

    END;

------------------------------------------------------------------
-- DROP TRIGGER
------------------------------------------------------------------
    PROCEDURE drop_audit_trigger(p_table_name VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP TRIGGER aud_' || LOWER(p_table_name);
    END;

END util_audit_gen;
/
