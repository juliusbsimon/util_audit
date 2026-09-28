------------------------------------------------------------------------------
-- util_audit: copy the util_audit v1 history into the new tables
--
-- Run after migrate_v1.sql, from the repository folder, as the schema owner:
--
--   @migrate_v1_history.sql
--
-- Copies UTIL_AUDIT_RECORDS_V1 into UTIL_AUDIT_TXN (one event per v1
-- TRANSACTION_ID) and UTIL_AUDIT_RECORDS, one month of one table at a time,
-- committing after each. The apps can stay in use. If it stops, run it
-- again: it skips what it already copied.
--
-- The copied events have no row snapshots, so they show in the history
-- views, the app and util_audit_query, but util_audit.restore_row cannot
-- restore them. The v1 USERENV text is kept in AUDIT_CONTEXT as v1_userenv.
--
-- When everything is copied, V_UTIL_AUDIT_RECORDS_V1 is rebuilt to read the
-- new tables only. UTIL_AUDIT_RECORDS_V1 is then no longer needed; drop it
-- yourself once you have checked the copy:
--   drop table util_audit_records_v1 purge;
------------------------------------------------------------------------------

set define off verify off feedback off serveroutput on size unlimited
whenever sqlerror exit failure rollback

DECLARE
    l_events  NUMBER;
    l_rows    NUMBER;
    l_total_e NUMBER := 0;
    l_total_r NUMBER := 0;
    l_skipped NUMBER;
    l_cur     SYS_REFCURSOR;
    l_table   VARCHAR2(255);
    l_month   DATE;

    -- The event key: the v1 transaction id, or one per row when v1 had none
    c_key CONSTANT VARCHAR2(200) := q'[coalesce(to_char(v.transaction_id), 'V1-' || v.util_audit_record_id)]';
BEGIN
    -- Month by month, so the new ids come out in time order
    OPEN l_cur FOR q'[
        select table_name, trunc(audit_date, 'MM')
          from util_audit_records_v1
         where table_name is not null
         group by trunc(audit_date, 'MM'), table_name
         order by 2 nulls first, 1]';
    LOOP
        FETCH l_cur INTO l_table, l_month;
        EXIT WHEN l_cur%NOTFOUND;

        -- One event (header) per v1 transaction id
        EXECUTE IMMEDIATE q'[
            insert into util_audit_txn
                (transaction_id, table_name, pk_value_vc, transaction_type, username, audit_context, audit_ts)
            select k, :t, min(to_char(pk_value)), min(transaction_type), substr(min(username), 1, 255),
                   json_object('source' value 'util_audit v1', 'v1_userenv' value min(userenv) absent on null),
                   cast(min(audit_date) as timestamp)
              from (select v.*, ]' || c_key || q'[ k
                      from util_audit_records_v1 v
                     where v.table_name = :t
                       and (trunc(v.audit_date, 'MM') = :m or (:m is null and v.audit_date is null))
                       and v.transaction_type in ('INSERT', 'UPDATE', 'DELETE')) v
             where not exists (select 1 from util_audit_txn x where x.transaction_id = v.k)
             group by k]'
            USING l_table, l_table, l_month, l_month;
        l_events := SQL%ROWCOUNT;

        -- Its changed columns, unless an earlier run copied them already
        EXECUTE IMMEDIATE q'[
            insert into util_audit_records
                (transaction_id, table_name, pk_value_vc, column_name, data_type, transaction_type,
                 username, old_value, new_value, old_clob, new_clob, audit_ts)
            select v.k, v.table_name, to_char(v.pk_value), v.column_name, substr(v.data_type, 1, 128),
                   v.transaction_type, substr(v.username, 1, 255), v.old_value, v.new_value,
                   v.old_clob, v.new_clob, cast(v.audit_date as timestamp)
              from (select v.*, ]' || c_key || q'[ k
                      from util_audit_records_v1 v
                     where v.table_name = :t
                       and (trunc(v.audit_date, 'MM') = :m or (:m is null and v.audit_date is null))
                       and v.transaction_type in ('INSERT', 'UPDATE', 'DELETE')) v
             where exists (select 1 from util_audit_txn x where x.transaction_id = v.k)
               and not exists (select 1 from util_audit_records r where r.transaction_id = v.k)
             order by v.audit_date, v.util_audit_record_id]'
            USING l_table, l_month, l_month;
        l_rows := SQL%ROWCOUNT;
        COMMIT;

        l_total_e := l_total_e + l_events;
        l_total_r := l_total_r + l_rows;
        IF l_events > 0 OR l_rows > 0 THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(l_table, 32) || NVL(TO_CHAR(l_month, 'YYYY-MM'), 'no date') ||
                                 ': ' || l_events || ' events, ' || l_rows || ' rows');
        END IF;
    END LOOP;
    CLOSE l_cur;

    DBMS_OUTPUT.PUT_LINE('Copied ' || l_total_e || ' events, ' || l_total_r || ' rows.');

    EXECUTE IMMEDIATE q'[
        select count(*) from util_audit_records_v1
         where table_name is null or transaction_type is null
            or transaction_type not in ('INSERT', 'UPDATE', 'DELETE')]'
        INTO l_skipped;
    IF l_skipped > 0 THEN
        DBMS_OUTPUT.PUT_LINE(l_skipped || ' v1 rows have no table name or transaction type and were not copied.');
    END IF;
END;
/

-- Rebuild the compatibility view: without the archive once all is copied
@@migration/v1_compat_view.sql

set feedback on
whenever sqlerror continue
