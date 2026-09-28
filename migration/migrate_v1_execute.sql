------------------------------------------------------------------------------
-- Called by migrate_v1.sql EXECUTE. Stops at the first error.
------------------------------------------------------------------------------
whenever sqlerror exit failure rollback

prompt
prompt Step 1: record and disable the v1 triggers
DECLARE
    l_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO l_cnt FROM user_tables WHERE table_name = 'UTIL_AUDIT_V1_TRIGGERS';
    IF l_cnt = 0 THEN
        EXECUTE IMMEDIATE q'[
create table util_audit_v1_triggers
(
    trigger_name  VARCHAR2(128) not null
        constraint util_audit_v1_triggers_pk primary key,
    table_name    VARCHAR2(128) not null,
    status_before VARCHAR2(8)   not null,
    migrated_on   DATE default SYSDATE not null
)]';
        -- Dynamic: the table did not exist when this block was compiled
        EXECUTE IMMEDIATE q'[
            insert into util_audit_v1_triggers (trigger_name, table_name, status_before)
            select tr.trigger_name, tr.table_name, tr.status
              from user_triggers tr
             where exists (select 1 from user_dependencies d
                            where d.name = tr.trigger_name and d.type = 'TRIGGER'
                              and d.referenced_type = 'PACKAGE' and d.referenced_name = 'UTIL_AUDIT'
                              and d.referenced_owner = user)]';
        COMMIT;
    END IF;
END;
/

BEGIN
    FOR t IN (SELECT tr.trigger_name FROM user_triggers tr
               JOIN util_audit_v1_triggers v ON v.trigger_name = tr.trigger_name
              WHERE tr.status = 'ENABLED') LOOP
        EXECUTE IMMEDIATE 'alter trigger "' || t.trigger_name || '" disable';
    END LOOP;
END;
/

prompt Step 2: keep the v1 history as UTIL_AUDIT_RECORDS_V1
DECLARE
    -- Names setup.sql gives to its own constraints and indexes
    l_taken SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST(
                'UTIL_AUDIT_RECORDS_PK', 'UTIL_AUDIT_RECORDS_TXN_FK',
                'UTIL_AUDIT_RECORDS_TRX_CHK', 'UTIL_AUDIT_RECORDS_HIST_IX',
                'UTIL_AUDIT_RECORDS_TBL_TS_IX', 'UTIL_AUDIT_RECORDS_HASH_IX',
                'UTIL_AUDIT_RECORDS_TXN_IX', 'UTIL_AUDIT_RECORDS_V1PK_IX');
    l_v1 NUMBER;
BEGIN
    -- Skipped when an earlier run already renamed it
    SELECT COUNT(*) INTO l_v1 FROM user_tables t
     WHERE t.table_name = 'UTIL_AUDIT_RECORDS'
       AND NOT EXISTS (SELECT 1 FROM user_tab_columns c
                        WHERE c.table_name = t.table_name AND c.column_name = 'PK_VALUE_VC');
    IF l_v1 = 0 THEN
        RETURN;
    END IF;

    EXECUTE IMMEDIATE 'alter table util_audit_records rename to util_audit_records_v1';

    FOR c IN (SELECT constraint_name FROM user_constraints
               WHERE table_name = 'UTIL_AUDIT_RECORDS_V1'
                 AND constraint_name IN (SELECT column_value FROM TABLE(l_taken))) LOOP
        EXECUTE IMMEDIATE 'alter table util_audit_records_v1 rename constraint "' ||
                          c.constraint_name || '" to "' || SUBSTR(c.constraint_name, 1, 125) || '_V1"';
    END LOOP;
    FOR i IN (SELECT index_name FROM user_indexes
               WHERE table_name = 'UTIL_AUDIT_RECORDS_V1'
                 AND index_name IN (SELECT column_value FROM TABLE(l_taken))) LOOP
        EXECUTE IMMEDIATE 'alter index "' || i.index_name || '" rename to "' ||
                          SUBSTR(i.index_name, 1, 125) || '_V1"';
    END LOOP;
END;
/

prompt Step 3: install util_audit (setup.sql)
@@../setup.sql
whenever sqlerror exit failure rollback

prompt Step 4: register the audited tables and re-enable their triggers
BEGIN
    MERGE INTO util_audit_config c
    USING (SELECT table_name,
                  MAX(CASE WHEN status_before = 'ENABLED' THEN 'Y' ELSE 'N' END) enabled_flag
             FROM util_audit_v1_triggers
            GROUP BY table_name) s
    ON (c.table_name = s.table_name)
    WHEN NOT MATCHED THEN
        INSERT (table_name, enabled_flag, created_on, created_by)
        VALUES (s.table_name, s.enabled_flag, SYSDATE, USER);
    COMMIT;

    FOR t IN (SELECT v.trigger_name FROM util_audit_v1_triggers v
               JOIN user_triggers tr ON tr.trigger_name = v.trigger_name
              WHERE v.status_before = 'ENABLED') LOOP
        EXECUTE IMMEDIATE 'alter trigger "' || t.trigger_name || '" enable';
    END LOOP;
END;
/

prompt Step 5: V_UTIL_AUDIT_RECORDS_V1 and grants
@@v1_compat_view.sql

DECLARE
    l_objects SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST('V_UTIL_AUDIT_RECORDS_V1', 'UTIL_AUDIT_RECORDS', 'UTIL_AUDIT_TXN');
BEGIN
    FOR g IN (SELECT DISTINCT grantee, privilege, grantable
                FROM user_tab_privs_made
               WHERE table_name = 'UTIL_AUDIT_RECORDS_V1'
                 AND privilege IN ('SELECT', 'READ')) LOOP
        FOR i IN 1 .. l_objects.COUNT LOOP
            EXECUTE IMMEDIATE 'grant ' || g.privilege || ' on ' || l_objects(i) || ' to "' || g.grantee || '"' ||
                              CASE WHEN g.grantable = 'YES' THEN ' with grant option' END;
            DBMS_OUTPUT.PUT_LINE('Granted ' || g.privilege || ' on ' || l_objects(i) || ' to ' || g.grantee);
        END LOOP;
    END LOOP;
END;
/

prompt
prompt Done. Check:
-- Recompile what the swap invalidated (the v1 triggers compile against the
-- new util_audit), so only code that really needs changing is listed
exec DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE)

DECLARE
    l_cnt PLS_INTEGER := 0;
BEGIN
    FOR o IN (SELECT object_type, object_name FROM user_objects
               WHERE status = 'INVALID' ORDER BY object_name) LOOP
        IF l_cnt = 0 THEN
            DBMS_OUTPUT.PUT_LINE('These objects are INVALID now. Code written for the v1 table or package');
            DBMS_OUTPUT.PUT_LINE('needs to read V_UTIL_AUDIT_RECORDS_V1 or use the new packages:');
        END IF;
        l_cnt := l_cnt + 1;
        DBMS_OUTPUT.PUT_LINE('  ' || o.object_type || ' ' || o.object_name);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(CHR(10) || 'Next (docs/migrating-from-v1.md):');
    DBMS_OUTPUT.PUT_LINE('  1. Point pages and code that read UTIL_AUDIT_RECORDS at V_UTIL_AUDIT_RECORDS_V1.');
    DBMS_OUTPUT.PUT_LINE('  2. Copy the v1 history into the new tables: @migrate_v1_history.sql');
    DBMS_OUTPUT.PUT_LINE('  3. Replace the v1 triggers: exec util_audit_gen.recreate_all_triggers');
    DBMS_OUTPUT.PUT_LINE('     (or per table, from the Util Audit app).');
END;
/
set feedback on
whenever sqlerror continue
