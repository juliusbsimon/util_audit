------------------------------------------------------------------------------
-- util_audit: undo migrate_v1.sql
--
-- Works while the v1 triggers are still in place (before they were replaced
-- by generated ones) and UTIL_AUDIT_RECORDS_V1 still exists.
--
--   @migrate_v1_rollback.sql
--
-- What it does:
--   1. Disables the v1 triggers.
--   2. Copies the changes recorded since the migration back into the v1
--      table, in the v1 layout. (Rows migrate_v1_history.sql copied are
--      already there and are skipped.)
--   3. Drops the util_audit packages, views and tables, and
--      V_UTIL_AUDIT_RECORDS_V1.
--   4. Renames UTIL_AUDIT_RECORDS_V1 back to UTIL_AUDIT_RECORDS.
--
-- Then reinstall your v1 util_audit package (spec and body) from your own
-- source and enable the triggers with the commands this script prints.
-- Until then the v1 triggers stay disabled, so changes are not audited but
-- nothing fails.
------------------------------------------------------------------------------

set define off verify off feedback off serveroutput on size unlimited
whenever sqlerror exit failure rollback

DECLARE
    l_cnt  NUMBER;
    l_type VARCHAR2(128);
    l_pk   VARCHAR2(200);

    PROCEDURE drop_if_exists(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-942, -4043, -1418) THEN
                RAISE;
            END IF;
    END;
BEGIN
    SELECT COUNT(*) INTO l_cnt FROM user_tables
     WHERE table_name IN ('UTIL_AUDIT_V1_TRIGGERS', 'UTIL_AUDIT_RECORDS_V1', 'UTIL_AUDIT_TXN');
    IF l_cnt < 3 THEN
        RAISE_APPLICATION_ERROR(-20120, 'Nothing to roll back: this schema was not migrated by migrate_v1.sql, ' ||
            'or UTIL_AUDIT_RECORDS_V1 was dropped.');
    END IF;

    -- A generated trigger means the v1 trigger it replaced is gone
    SELECT COUNT(*) INTO l_cnt
    FROM user_dependencies d
    WHERE d.type = 'TRIGGER' AND d.referenced_type = 'PACKAGE'
      AND d.referenced_name = 'UTIL_AUDIT' AND d.referenced_owner = USER
      AND d.name NOT IN (SELECT trigger_name FROM util_audit_v1_triggers);
    IF l_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20121, l_cnt || ' table(s) already have generated audit triggers, which replaced ' ||
            'their v1 triggers. Recreate those v1 triggers from your source first.');
    END IF;

    -- 1. Stop auditing while util_audit is swapped back
    FOR t IN (SELECT tr.trigger_name FROM user_triggers tr
               JOIN util_audit_v1_triggers v ON v.trigger_name = tr.trigger_name
              WHERE tr.status = 'ENABLED') LOOP
        EXECUTE IMMEDIATE 'alter trigger "' || t.trigger_name || '" disable';
    END LOOP;

    -- 2. Changes recorded since the migration, back in the v1 layout
    SELECT data_type INTO l_type FROM user_tab_columns
     WHERE table_name = 'UTIL_AUDIT_RECORDS_V1' AND column_name = 'PK_VALUE';
    l_pk := CASE WHEN l_type = 'NUMBER'
                 THEN 'to_number(r.pk_value_vc default null on conversion error)'
                 ELSE 'r.pk_value_vc' END;
    SELECT data_type INTO l_type FROM user_tab_columns
     WHERE table_name = 'UTIL_AUDIT_RECORDS_V1' AND column_name = 'TRANSACTION_ID';

    EXECUTE IMMEDIATE q'[
        insert into util_audit_records_v1
            (transaction_id, table_name, pk_value, column_name, data_type, transaction_type,
             username, old_value, new_value, old_clob, new_clob, userenv, audit_date)
        select ]' || CASE WHEN l_type = 'NUMBER'
                          THEN 'to_number(r.transaction_id default null on conversion error)'
                          ELSE 'r.transaction_id' END || q'[,
               r.table_name, ]' || l_pk || q'[, r.column_name, r.data_type, r.transaction_type,
               r.username, r.old_value, r.new_value, r.old_clob, r.new_clob,
               dbms_lob.substr(t.audit_context, 4000, 1), cast(r.audit_ts as date)
          from util_audit_records r
          join util_audit_txn t on t.transaction_id = r.transaction_id
         where t.audit_ts >= (select min(migrated_on) from util_audit_v1_triggers)
           and nvl(json_value(t.audit_context, '$.source'), '-') <> 'util_audit v1'
         order by r.audit_ts, r.util_audit_record_id]';
    DBMS_OUTPUT.PUT_LINE('Copied ' || SQL%ROWCOUNT || ' rows recorded since the migration back to the v1 table.');
    COMMIT;

    -- 3. The current util_audit
    drop_if_exists('drop view v_util_audit_records_v1');
    drop_if_exists('drop package util_audit_archive');
    drop_if_exists('drop package util_audit_apx');
    drop_if_exists('drop package util_audit_query');
    drop_if_exists('drop package util_audit_gen');
    drop_if_exists('drop package util_audit');
    drop_if_exists('drop package util_audit_restore');
    FOR v IN (SELECT view_name FROM user_views
               WHERE view_name IN ('V_UTIL_AUDIT_TABLES', 'V_UTIL_AUDIT_CHILD_TABLES', 'V_UTIL_AUDIT_TRIGGERS',
                                   'V_UTIL_AUDIT_EVENT_SUMMARY', 'V_UTIL_AUDIT_LATEST_BY_ROW',
                                   'V_UTIL_AUDIT_ROW_HISTORY', 'V_UTIL_AUDIT_CHANGES', 'V_UTIL_AUDIT_EVENTS')) LOOP
        EXECUTE IMMEDIATE 'drop view ' || v.view_name;
    END LOOP;
    drop_if_exists('drop table util_audit_records purge');
    drop_if_exists('drop table util_audit_txn purge');
    drop_if_exists('drop table util_audit_errors purge');
    drop_if_exists('drop table util_audit_config purge');
    drop_if_exists('drop table util_audit_doc_article purge');
    drop_if_exists('drop table util_audit_archive_files purge');
    drop_if_exists('drop table util_audit_settings purge');

    -- 4. The v1 table under its own name again, with the names step 2 of
    --    the migration changed
    EXECUTE IMMEDIATE 'alter table util_audit_records_v1 rename to util_audit_records';
    FOR c IN (SELECT constraint_name FROM user_constraints
               WHERE table_name = 'UTIL_AUDIT_RECORDS'
                 AND constraint_name LIKE 'UTIL\_AUDIT\_RECORDS\_%\_V1' ESCAPE '\') LOOP
        EXECUTE IMMEDIATE 'alter table util_audit_records rename constraint "' || c.constraint_name ||
                          '" to "' || SUBSTR(c.constraint_name, 1, LENGTH(c.constraint_name) - 3) || '"';
    END LOOP;
    FOR i IN (SELECT index_name FROM user_indexes
               WHERE table_name = 'UTIL_AUDIT_RECORDS'
                 AND index_name LIKE 'UTIL\_AUDIT\_RECORDS\_%\_V1' ESCAPE '\') LOOP
        EXECUTE IMMEDIATE 'alter index "' || i.index_name || '" rename to "' ||
                          SUBSTR(i.index_name, 1, LENGTH(i.index_name) - 3) || '"';
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(CHR(10) || 'Rolled back. Now reinstall your v1 util_audit package (spec and body),');
    DBMS_OUTPUT.PUT_LINE('then enable the v1 triggers that were enabled before the migration:');
    FOR t IN (SELECT trigger_name FROM util_audit_v1_triggers WHERE status_before = 'ENABLED' ORDER BY 1) LOOP
        DBMS_OUTPUT.PUT_LINE('  alter trigger ' || LOWER(t.trigger_name) || ' enable;');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('and finally: drop table util_audit_v1_triggers purge;');
END;
/

set feedback on
whenever sqlerror continue
