------------------------------------------------------------------------------
-- V_UTIL_AUDIT_RECORDS_V1: all audit history in the util_audit v1 column
-- layout, for pages and code written against the v1 UTIL_AUDIT_RECORDS.
-- Called by migrate_v1.sql and migrate_v1_history.sql.
--
--   PK_VALUE     NUMBER when v1 stored numbers (text keys give NULL; use
--                PK_VALUE_VC for those), else text
--   USERENV      the v1 text for v1 events; the JSON context for new ones
--   AUDIT_DATE   AUDIT_TS as a DATE
--
-- While UTIL_AUDIT_RECORDS_V1 holds rows that migrate_v1_history.sql has
-- not copied yet, the view reads them from there.
------------------------------------------------------------------------------
DECLARE
    l_numeric BOOLEAN;
    l_archive NUMBER;
    l_left    NUMBER := 0;
    l_pk      VARCHAR2(200);
    l_sql     VARCHAR2(32767);
    l_type    VARCHAR2(128);
BEGIN
    SELECT COUNT(*) INTO l_archive FROM user_tables WHERE table_name = 'UTIL_AUDIT_RECORDS_V1';
    IF l_archive > 0 THEN
        SELECT data_type INTO l_type FROM user_tab_columns
         WHERE table_name = 'UTIL_AUDIT_RECORDS_V1' AND column_name = 'PK_VALUE';
        EXECUTE IMMEDIATE q'[
            select count(*) from util_audit_records_v1 v
             where rownum = 1
               and not exists (select 1 from util_audit_txn x
                                where x.transaction_id = coalesce(to_char(v.transaction_id), 'V1-' || v.util_audit_record_id))]'
            INTO l_left;
    ELSE
        -- Archive dropped: keep the key type the view had
        SELECT MAX(data_type) INTO l_type FROM user_tab_columns
         WHERE table_name = 'V_UTIL_AUDIT_RECORDS_V1' AND column_name = 'PK_VALUE';
    END IF;
    l_numeric := NVL(l_type, 'NUMBER') = 'NUMBER';

    IF l_numeric THEN
        -- The same expression as the index UTIL_AUDIT_RECORDS_V1PK_IX, so
        -- "pk_value = :P1_ID" is an index lookup
        l_pk := 'to_number(r.pk_value_vc default null on conversion error)';
        BEGIN
            EXECUTE IMMEDIATE 'create index util_audit_records_v1pk_ix on util_audit_records (table_name, ' ||
                              'to_number(pk_value_vc default null on conversion error))';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE NOT IN (-955, -1408) THEN
                    RAISE;
                END IF;
        END;
    ELSE
        l_pk := 'r.pk_value_vc';
    END IF;

    l_sql := q'[create or replace view v_util_audit_records_v1 as
select r.util_audit_record_id,
       r.transaction_id,
       r.table_name,
       ]' || l_pk || q'[ as pk_value,
       r.pk_value_vc,
       r.column_name,
       r.data_type,
       r.transaction_type,
       r.username,
       r.old_value,
       r.new_value,
       r.old_clob,
       r.new_clob,
       coalesce(json_value(t.audit_context, '$.v1_userenv' returning varchar2(4000)),
                dbms_lob.substr(t.audit_context, 4000, 1)) as userenv,
       cast(r.audit_ts as date) as audit_date
  from util_audit_records r
  left join util_audit_txn t
    on t.transaction_id = r.transaction_id]';

    IF l_left > 0 THEN
        l_sql := l_sql || q'[
union all
select v.util_audit_record_id,
       to_char(v.transaction_id),
       v.table_name,
       v.pk_value,
       to_char(v.pk_value),
       v.column_name,
       v.data_type,
       v.transaction_type,
       v.username,
       v.old_value,
       v.new_value,
       v.old_clob,
       v.new_clob,
       v.userenv,
       v.audit_date
  from util_audit_records_v1 v
 where not exists (select 1 from util_audit_txn x
                    where x.transaction_id = coalesce(to_char(v.transaction_id), 'V1-' || v.util_audit_record_id))]';
    END IF;

    EXECUTE IMMEDIATE l_sql;
    DBMS_OUTPUT.PUT_LINE('View V_UTIL_AUDIT_RECORDS_V1 ' ||
        CASE WHEN l_left > 0 THEN 'reads the new tables and the uncopied v1 archive.'
             ELSE 'reads the new tables only.' END);
END;
/
