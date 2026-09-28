------------------------------------------------------------------------------
-- util_audit: migrate a schema from util_audit v1 to the current version
--
-- v1 is the older util_audit: one table UTIL_AUDIT_RECORDS with PK_VALUE
-- (NUMBER), AUDIT_DATE and USERENV columns, and hand-written or generated
-- AIUD_<table>_AUD triggers. setup.sql refuses to run over it.
--
-- Run from the repository folder, connected as the schema that owns v1:
--
--   @migrate_v1.sql            preview: reports what it would do, changes nothing
--   @migrate_v1.sql EXECUTE    does the migration
--
-- What EXECUTE does, in order:
--   1. Records the v1 triggers and their status in UTIL_AUDIT_V1_TRIGGERS,
--      then disables them, so no business DML fails while util_audit is
--      swapped (changes in these seconds are not audited).
--   2. Renames UTIL_AUDIT_RECORDS to UTIL_AUDIT_RECORDS_V1. The v1 history
--      stays there, untouched. Its indexes and grants go with it.
--   3. Runs setup.sql: new tables, views and packages. The new util_audit
--      package still accepts the calls the v1 triggers make.
--   4. Registers every table that has a v1 trigger in UTIL_AUDIT_CONFIG
--      (enabled when its trigger was enabled) and re-enables the v1
--      triggers that were enabled. From here on they write the new format.
--   5. Creates V_UTIL_AUDIT_RECORDS_V1: all history (the v1 archive and
--      everything recorded from now on) in the v1 column layout, so pages
--      and code that read UTIL_AUDIT_RECORDS keep working after changing
--      that one name. Grants on the old table are repeated on the view.
--
-- After it, see docs/migrating-from-v1.md: copy the v1 history
-- into the new tables (migrate_v1_history.sql), point old queries at the
-- view, and replace the v1 triggers with generated ones.
--
-- Run it when nobody is using the apps: sessions that already called the
-- v1 package can get one ORA-04068 on their next change.
-- migrate_v1_rollback.sql undoes it until the v1 triggers are replaced.
------------------------------------------------------------------------------

set define on verify off feedback off serveroutput on size unlimited

-- &1 is optional: default to preview
set termout off
column mode_arg new_value 1
select null mode_arg from dual where 1 = 0;
set termout on
define ua_mode = "&1"

whenever sqlerror exit failure rollback

-------------------------------------------------------------------------------
-- Preview (always runs): what is here and what depends on it
-------------------------------------------------------------------------------
DECLARE
    l_v1      NUMBER;
    l_v2      NUMBER;
    l_log     NUMBER;
    l_rows    NUMBER;
    l_txns    NUMBER;
    l_nulls   NUMBER;
    l_first   DATE;
    l_last    DATE;
    l_cnt     PLS_INTEGER := 0;
    l_execute BOOLEAN := NVL(UPPER('&ua_mode'), '-') = 'EXECUTE';

    PROCEDURE say(p_text IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_text);
    END;

    -- APEX regions and processes whose source mentions UTIL_AUDIT_RECORDS.
    -- Dynamic, so this runs where APEX is not installed.
    PROCEDURE apex_users IS
        l_cur SYS_REFCURSOR;
        l_app NUMBER;
        l_pg  NUMBER;
        l_kind VARCHAR2(20);
        l_name VARCHAR2(4000);
        l_any  BOOLEAN := FALSE;
    BEGIN
        OPEN l_cur FOR q'[
            select application_id, page_id, 'region', region_name
              from apex_application_page_regions
             where upper(table_name) = 'UTIL_AUDIT_RECORDS'
                or dbms_lob.instr(upper(region_source), 'UTIL_AUDIT_RECORDS') > 0
            union all
            select application_id, page_id, 'process', process_name
              from apex_application_page_proc
             where dbms_lob.instr(upper(process_source), 'UTIL_AUDIT_RECORDS') > 0
             order by 1, 2]';
        LOOP
            FETCH l_cur INTO l_app, l_pg, l_kind, l_name;
            EXIT WHEN l_cur%NOTFOUND;
            say('  app ' || l_app || ' page ' || l_pg || ' ' || l_kind || ': ' || l_name);
            l_any := TRUE;
        END LOOP;
        CLOSE l_cur;
        IF NOT l_any THEN
            say('  none found (the APEX views only show apps in workspaces that use this schema)');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            say('  (APEX dictionary not readable here: ' || SQLERRM || ')');
    END;
BEGIN
    SELECT COUNT(*) INTO l_v1 FROM user_tables t
     WHERE t.table_name = 'UTIL_AUDIT_RECORDS'
       AND NOT EXISTS (SELECT 1 FROM user_tab_columns c
                        WHERE c.table_name = t.table_name AND c.column_name = 'PK_VALUE_VC');
    SELECT COUNT(*) INTO l_v2 FROM user_tables WHERE table_name = 'UTIL_AUDIT_TXN';
    SELECT COUNT(*) INTO l_log FROM user_tables WHERE table_name = 'UTIL_AUDIT_V1_TRIGGERS';

    IF l_log > 0 THEN
        -- Every step checks whether it is done, so EXECUTE picks up where
        -- an earlier run stopped
        say('An earlier "migrate_v1.sql EXECUTE" ran here (UTIL_AUDIT_V1_TRIGGERS exists).');
        say('Running EXECUTE again finishes it; steps already done are skipped.');
        say();
    ELSIF l_v2 > 0 THEN
        RAISE_APPLICATION_ERROR(-20110, 'This schema already has the current util_audit (UTIL_AUDIT_TXN exists). Nothing to migrate.');
    ELSIF l_v1 = 0 THEN
        RAISE_APPLICATION_ERROR(-20111, 'No util_audit v1 here (no UTIL_AUDIT_RECORDS with PK_VALUE). Run setup.sql instead.');
    END IF;

    say('util_audit v1 found. ' || CASE WHEN l_execute THEN 'Migrating.' ELSE 'PREVIEW: nothing is changed.' END);
    say();

    EXECUTE IMMEDIATE 'select count(*), count(distinct transaction_id), count(case when transaction_id is null then 1 end),
                              min(audit_date), max(audit_date) from ' ||
                      CASE WHEN l_v1 > 0 THEN 'util_audit_records' ELSE 'util_audit_records_v1' END
        INTO l_rows, l_txns, l_nulls, l_first, l_last;
    say('History: ' || l_rows || ' rows, ' || l_txns || ' events, ' ||
        TO_CHAR(l_first, 'YYYY-MM-DD') || ' to ' || TO_CHAR(l_last, 'YYYY-MM-DD') ||
        CASE WHEN l_nulls > 0 THEN ' (' || l_nulls || ' rows without a transaction id)' END);
    say('  It is kept as UTIL_AUDIT_RECORDS_V1.');
    say();

    say('Triggers that call util_audit (kept, and re-enabled if they were enabled):');
    FOR t IN (
        SELECT tr.trigger_name, tr.table_name, tr.status
        FROM user_triggers tr
        JOIN user_dependencies d
          ON d.name = tr.trigger_name AND d.type = 'TRIGGER'
         AND d.referenced_type = 'PACKAGE' AND d.referenced_name = 'UTIL_AUDIT'
         AND d.referenced_owner = USER
        ORDER BY tr.table_name
    ) LOOP
        l_cnt := l_cnt + 1;
        say('  ' || RPAD(t.table_name, 32) || RPAD(t.trigger_name, 34) || t.status);
    END LOOP;
    say('  ' || l_cnt || ' trigger(s).');
    say();

    say('Other code that uses the v1 package or table (review it; the v1-only');
    say('procedures such as add_table_audit_trig no longer exist afterwards):');
    l_cnt := 0;
    FOR d IN (
        SELECT DISTINCT name, type, referenced_name
        FROM user_dependencies
        WHERE referenced_owner = USER
          AND referenced_name IN ('UTIL_AUDIT', 'UTIL_AUDIT_RECORDS')
          AND type <> 'TRIGGER'
          AND name NOT IN ('UTIL_AUDIT')
        ORDER BY name
    ) LOOP
        l_cnt := l_cnt + 1;
        say('  ' || d.type || ' ' || d.name || ' uses ' || d.referenced_name);
    END LOOP;
    IF l_cnt = 0 THEN
        say('  none');
    END IF;
    say();

    say('APEX regions and processes that read UTIL_AUDIT_RECORDS (change them to');
    say('V_UTIL_AUDIT_RECORDS_V1, see docs/migrating-from-v1.md):');
    apex_users;
    say();

    say('Grants on UTIL_AUDIT_RECORDS (repeated on the new view and tables):');
    l_cnt := 0;
    FOR g IN (SELECT DISTINCT grantee, privilege FROM user_tab_privs_made
               WHERE table_name IN ('UTIL_AUDIT_RECORDS', 'UTIL_AUDIT_RECORDS_V1')
                 AND privilege IN ('SELECT', 'READ') ORDER BY 1, 2) LOOP
        l_cnt := l_cnt + 1;
        say('  ' || g.privilege || ' to ' || g.grantee);
    END LOOP;
    IF l_cnt = 0 THEN
        say('  none');
    END IF;

    IF NOT l_execute THEN
        say();
        say('To migrate, run: @migrate_v1.sql EXECUTE');
    END IF;
END;
/

-- Stop here unless EXECUTE was given
set termout off
column next_script new_value next_script
select case when upper('&ua_mode') = 'EXECUTE' then 'migrate_v1_execute.sql' else 'migrate_v1_done.sql' end next_script from dual;
set termout on
@@migration/&next_script
