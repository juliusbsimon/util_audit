------------------------------------------------------------------------------
-- util_audit uninstall
--
-- Drops the audit triggers, packages, views and tables.
-- WARNING: this deletes all audit history. Export it first if you need it.
------------------------------------------------------------------------------

-- The archive job, if util_audit_archive.schedule created one
BEGIN
    DBMS_SCHEDULER.DROP_JOB('UTIL_AUDIT_ARCHIVE_JOB', force => TRUE);
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/

-- Every trigger that calls util_audit, found by its dependency on the
-- package, so this works even when util_audit_gen is invalid or missing.
-- Includes triggers on tables no longer in util_audit_config.
BEGIN
    FOR t IN (
        SELECT d.name trigger_name
        FROM user_dependencies d
        WHERE d.type = 'TRIGGER'
          AND d.referenced_type = 'PACKAGE'
          AND d.referenced_name = 'UTIL_AUDIT'
          AND d.referenced_owner = USER
    ) LOOP
        EXECUTE IMMEDIATE 'drop trigger "' || t.trigger_name || '"';
    END LOOP;
END;
/

DECLARE
    PROCEDURE drop_if_exists(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    EXCEPTION
        WHEN OTHERS THEN
            -- ORA-00942: table or view does not exist, ORA-04043: object does not exist
            IF SQLCODE NOT IN (-942, -4043) THEN
                RAISE;
            END IF;
    END;
BEGIN
    drop_if_exists('drop package util_audit_archive');
    drop_if_exists('drop package util_audit_apx');
    drop_if_exists('drop package util_audit_query');
    drop_if_exists('drop package util_audit_gen');
    drop_if_exists('drop package util_audit');
    drop_if_exists('drop package util_audit_restore');
    drop_if_exists('drop view v_util_audit_records_v1');
    drop_if_exists('drop view v_util_audit_tables');
    drop_if_exists('drop view v_util_audit_child_tables');
    drop_if_exists('drop view v_util_audit_triggers');
    drop_if_exists('drop view v_util_audit_event_summary');
    drop_if_exists('drop view v_util_audit_latest_by_row');
    drop_if_exists('drop view v_util_audit_row_history');
    drop_if_exists('drop view v_util_audit_changes');
    drop_if_exists('drop view v_util_audit_events');
    drop_if_exists('drop table util_audit_records purge');
    drop_if_exists('drop table util_audit_txn purge');
    drop_if_exists('drop table util_audit_errors purge');
    drop_if_exists('drop table util_audit_config purge');
    drop_if_exists('drop table util_audit_doc_article purge');
    -- Archive catalog and settings. Archive files in S3 are not deleted.
    drop_if_exists('drop table util_audit_archive_files purge');
    drop_if_exists('drop table util_audit_settings purge');
    -- Left by migrate_v1.sql
    drop_if_exists('drop table util_audit_records_v1 purge');
    drop_if_exists('drop table util_audit_v1_triggers purge');
END;
/
