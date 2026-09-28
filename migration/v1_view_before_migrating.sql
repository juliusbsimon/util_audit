------------------------------------------------------------------------------
-- Optional first step of a util_audit v1 migration: create
-- V_UTIL_AUDIT_RECORDS_V1 on the v1 table, before migrating.
--
-- Pages and code can then switch from UTIL_AUDIT_RECORDS to the view
-- ahead of time, while v1 is still running. migrate_v1.sql replaces the
-- view with one over the new tables, with the same columns, so those pages
-- keep working through the migration without another change.
--
-- Run as the schema that owns util_audit v1. Safe to run again.
------------------------------------------------------------------------------
DECLARE
    l_v1   NUMBER;
    l_type VARCHAR2(128);
BEGIN
    SELECT COUNT(*) INTO l_v1 FROM user_tables t
     WHERE t.table_name = 'UTIL_AUDIT_RECORDS'
       AND NOT EXISTS (SELECT 1 FROM user_tab_columns c
                        WHERE c.table_name = t.table_name AND c.column_name = 'PK_VALUE_VC');
    IF l_v1 = 0 THEN
        RAISE_APPLICATION_ERROR(-20111, 'No util_audit v1 here (no UTIL_AUDIT_RECORDS with PK_VALUE).');
    END IF;

    -- Same columns and types as the view migrate_v1.sql creates
    EXECUTE IMMEDIATE q'[create or replace view v_util_audit_records_v1 as
select util_audit_record_id,
       to_char(transaction_id) as transaction_id,
       table_name,
       pk_value,
       to_char(pk_value) as pk_value_vc,
       column_name,
       data_type,
       transaction_type,
       username,
       old_value,
       new_value,
       old_clob,
       new_clob,
       userenv,
       audit_date
  from util_audit_records]';

    -- Whoever can read the v1 table can read the view
    FOR g IN (SELECT DISTINCT grantee, privilege FROM user_tab_privs_made
               WHERE table_name = 'UTIL_AUDIT_RECORDS' AND privilege IN ('SELECT', 'READ')) LOOP
        EXECUTE IMMEDIATE 'grant ' || g.privilege || ' on v_util_audit_records_v1 to "' || g.grantee || '"';
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Created V_UTIL_AUDIT_RECORDS_V1 over the v1 table.');
END;
/
