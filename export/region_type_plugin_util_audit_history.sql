prompt --application/set_environment
set define off verify off feedback off
whenever sqlerror exit sql.sqlcode rollback
--------------------------------------------------------------------------------
--
-- Oracle APEX export file
--
-- You should run this script using a SQL client connected to the database as
-- the owner (parsing schema) of the application or as a database user with the
-- APEX_ADMINISTRATOR_ROLE role.
--
-- This export file has been automatically generated. Modifying this file is not
-- supported by Oracle and can lead to unexpected application and/or instance
-- behavior now or in the future.
--
-- NOTE: Calls to apex_application_install override the defaults below.
--
--------------------------------------------------------------------------------
begin
wwv_flow_imp.import_begin (
 p_version_yyyy_mm_dd=>'2026.03.30'
,p_release=>'26.1.0'
,p_default_workspace_id=>5500743544394398
,p_default_application_id=>129
,p_default_id_offset=>0
,p_default_owner=>'UA_TEST'
);
end;
/
 
prompt APPLICATION 129 - Util Audit
--
-- Application Export:
--   Application:     129
--   Name:            Util Audit
--   Date and Time:   02:44 Wednesday September 30, 2026
--   Exported By:     UA_TEST
--   Flashback:       0
--   Export Type:     Component Export
--   Manifest
--     PLUGIN: 5629411888562794
--   Manifest End
--   Version:         26.1.0
--   Instance ID:     746091147707827
--

begin
  -- replace components
  wwv_flow_imp.g_mode := 'REPLACE';
end;
/
prompt --application/shared_components/plugins/region_type/util_audit_history
begin
wwv_flow_imp_shared.create_plugin(
 p_id=>wwv_flow_imp.id(5629411888562794)
,p_plugin_type=>'REGION TYPE'
,p_name=>'UTIL_AUDIT_HISTORY'
,p_display_name=>'Audit History'
,p_apexlang_name=>'utilAuditHistory'
,p_plsql_code=>wwv_flow_string.join(wwv_flow_t_varchar2(
'-- Audit History region: the changes util_audit recorded for the row a',
'-- page shows, read from util_audit_query.history.',
'function render (',
'    p_region              in apex_plugin.t_region,',
'    p_plugin              in apex_plugin.t_plugin,',
'    p_is_printer_friendly in boolean )',
'    return apex_plugin.t_region_render_result',
'is',
'    l_result   apex_plugin.t_region_render_result;',
'    type t_row is record (',
'        changed_at     timestamp(6),',
'        changed_by     varchar2(255),',
'        action         varchar2(6),',
'        table_name     varchar2(255),',
'        record_key     varchar2(4000),',
'        field          varchar2(255),',
'        old_value      varchar2(4000),',
'        new_value      varchar2(4000),',
'        fields_changed varchar2(4000),',
'        transaction_id varchar2(64));',
'    type t_rows is table of t_row;',
'',
'    l_table    varchar2(128)   := upper(trim(p_region.attribute_01));',
'    l_items    apex_t_varchar2 := apex_string.split(replace(p_region.attribute_02, '' ''), '','');',
'    l_style    varchar2(10)    := nvl(p_region.attribute_03, ''COLUMNS'');',
'    l_children varchar2(4000)  := p_region.attribute_04;',
'    l_columns  varchar2(4000)  := p_region.attribute_05;',
'    l_friendly varchar2(1)     := nvl(p_region.attribute_06, ''Y'');',
'    l_max_rows number          := nvl(to_number(p_region.attribute_07), 100);',
'    l_datefmt  varchar2(100)   := nvl(p_region.attribute_08, ''SINCE'');',
'    l_schema   varchar2(128)   := upper(trim(p_region.attribute_09));',
'    l_keys     apex_t_varchar2 := apex_t_varchar2(null, null, null, null);',
'    l_sql      varchar2(4000);',
'    l_rc       sys_refcursor;',
'    l_rows     t_rows;',
'    l_kids     boolean := l_children is not null;',
'    l_prev_txn varchar2(64);',
'    l_first    boolean;',
'',
'    function cell(p_value in varchar2, p_class in varchar2 default null) return varchar2 is',
'        l_short varchar2(4000) := p_value;',
'    begin',
'        if length(p_value) > 200 then',
'            l_short := substr(p_value, 1, 200) || ''...'';',
'        end if;',
'        return ''<td class="t-Report-cell'' || case when p_class is not null then '' '' || p_class end || ''"'' ||',
'               case when l_short <> p_value then '' title="'' || apex_escape.html_attribute(p_value) || ''"'' end ||',
'               ''>'' || apex_escape.html(l_short) || ''</td>'';',
'    end;',
'',
'    function head(p_label in varchar2) return varchar2 is',
'    begin',
'        return ''<th class="t-Report-colHead" scope="col">'' || apex_escape.html(p_label) || ''</th>'';',
'    end;',
'',
'    function when_text(p_ts in timestamp) return varchar2 is',
'    begin',
'        return case when l_datefmt = ''SINCE'' then apex_util.get_since(cast(p_ts as date))',
'                    else to_char(p_ts, l_datefmt) end;',
'    end;',
'    -- The Changed cell. "5 minutes ago" shows the exact time on hover.',
'    function when_cell(p_ts in timestamp) return varchar2 is',
'    begin',
'        if l_datefmt <> ''SINCE'' then',
'            return cell(when_text(p_ts), ''ua-hist-event'');',
'        end if;',
'        return ''<td class="t-Report-cell ua-hist-event"><time datetime="'' ||',
'               to_char(p_ts, ''YYYY-MM-DD"T"HH24:MI:SS'', ''NLS_CALENDAR=GREGORIAN'') || ''" title="'' ||',
'               apex_escape.html_attribute(to_char(p_ts, ''YYYY-MM-DD HH24:MI:SS'', ''NLS_CALENDAR=GREGORIAN'')) ||',
'               ''">'' || apex_escape.html(when_text(p_ts)) || ''</time></td>'';',
'    end;',
'begin',
'    apex_css.add(',
'        p_css => ''.ua-hist .ua-hist-cont td.ua-hist-event{color:transparent;user-select:none}'' ||',
'                 ''.ua-hist td.ua-hist-old{color:var(--ua-text-muted,var(--ut-component-text-muted-color,#6b6e80))}'',',
'        p_key => ''util_audit_history'');',
'',
'    for i in 1 .. least(l_items.count, 4) loop',
'        l_keys(i) := apex_util.get_session_state(l_items(i));',
'    end loop;',
'',
'    if l_keys(1) is null then',
'        sys.htp.p(''<p class="ua-hist-empty">'' || apex_escape.html(',
'            nvl(p_region.no_data_found_message, ''No changes recorded yet.'')) || ''</p>'');',
'        return l_result;',
'    end if;',
'',
'    if l_schema is not null and not regexp_like(l_schema, ''^[A-Z][A-Z0-9_$#]*$'') then',
'        raise_application_error(-20031, ''Not a valid schema name: '' || l_schema);',
'    end if;',
'',
'    l_sql := ''select * from table('' ||',
'             case when l_schema is not null then l_schema || ''.'' end ||',
'             ''util_audit_query.history(:t, :k1, :k2, :k3, :k4, :s, :c, :ch, :f, :m))'';',
'    open l_rc for l_sql',
'        using l_table, l_keys(1), l_keys(2), l_keys(3), l_keys(4),',
'              l_style, l_columns, l_children, l_friendly, l_max_rows;',
'    fetch l_rc bulk collect into l_rows;',
'    close l_rc;',
'',
'    if l_rows.count = 0 then',
'        sys.htp.p(''<p class="ua-hist-empty">'' || apex_escape.html(',
'            nvl(p_region.no_data_found_message, ''No changes recorded yet.'')) || ''</p>'');',
'        return l_result;',
'    end if;',
'',
'    sys.htp.p(''<div class="t-Report t-Report--stretch ua-hist"><div class="t-Report-wrap">'' ||',
'              ''<table class="t-Report-report" aria-label="'' ||',
'              apex_escape.html_attribute(p_region.name) || ''"><thead><tr>'' ||',
'              head(''Changed'') || head(''By'') || head(''Action'') ||',
'              case when l_kids then head(''Table'') || head(''Record'') end ||',
'              case when l_style = ''COLUMNS''',
'                   then head(''Field'') || head(''Old Value'') || head(''New Value'')',
'                   else head(''Fields Changed'') end ||',
'              ''</tr></thead><tbody>'');',
'',
'    for i in 1 .. l_rows.count loop',
'        -- Later lines of the same change leave the event columns empty,',
'        -- so each change reads as one group',
'        l_first := l_style <> ''COLUMNS'' or l_rows(i).transaction_id is null',
'                   or l_rows(i).transaction_id <> nvl(l_prev_txn, ''-'');',
'        l_prev_txn := l_rows(i).transaction_id;',
'        sys.htp.p(''<tr'' || case when not l_first then '' class="ua-hist-cont"'' end || ''>'' ||',
'                  when_cell(l_rows(i).changed_at) ||',
'                  cell(l_rows(i).changed_by, ''ua-hist-event'') ||',
'                  cell(initcap(l_rows(i).action), ''ua-hist-event'') ||',
'                  case when l_kids then',
'                      cell(l_rows(i).table_name, ''ua-hist-event'') ||',
'                      cell(l_rows(i).record_key, ''ua-hist-event'') end ||',
'                  case when l_style = ''COLUMNS'' then',
'                      cell(l_rows(i).field) ||',
'                      cell(l_rows(i).old_value, ''ua-hist-old'') ||',
'                      cell(l_rows(i).new_value)',
'                  else',
'                      cell(l_rows(i).fields_changed) end ||',
'                  ''</tr>'');',
'    end loop;',
'',
'    sys.htp.p(''</tbody></table></div></div>'');',
'    if l_rows.count >= l_max_rows then',
'        sys.htp.p(''<p class="ua-hist-more">Showing the latest '' || l_max_rows || '' lines.</p>'');',
'    end if;',
'    return l_result;',
'exception',
'    when others then',
'        if l_rc%isopen then',
'            close l_rc;',
'        end if;',
'        -- Show the problem in the region instead of failing the page',
'        sys.htp.p(''<p class="ua-hist-error">Audit History: '' || apex_escape.html(sqlerrm) || ''</p>'');',
'        return l_result;',
'end render;'))
,p_api_version=>1
,p_render_function=>'render'
,p_standard_attributes=>'NO_DATA_FOUND_MESSAGE'
,p_substitute_attributes=>false
,p_help_text=>wwv_flow_string.join(wwv_flow_t_varchar2(
'<p>Shows the changes util_audit recorded for the row a page is showing: who changed it, when, and each column''s old and new value. Set <strong>Table</strong> and <strong>Key Items</strong>; everything else is optional.</p>',
'<p>Needs the util_audit framework installed (the Util Audit app installs it). The region renders when the page loads.</p>'))
,p_version_identifier=>'1.0'
,p_files_version=>2461314024428
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5629537890562798)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>1
,p_display_sequence=>10
,p_static_id=>'attribute_01'
,p_prompt=>'Table'
,p_apexlang_name=>'table'
,p_attribute_type=>'TEXT'
,p_is_required=>true
,p_is_translatable=>false
,p_help_text=>'The audited table the page shows, for example EMP.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5629662898562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>2
,p_display_sequence=>20
,p_static_id=>'attribute_02'
,p_prompt=>'Key Items'
,p_apexlang_name=>'keyItems'
,p_attribute_type=>'PAGE ITEMS'
,p_is_required=>true
,p_is_translatable=>false
,p_help_text=>'The page items holding the row''s primary key, one per key column, in key column order.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5629706885562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>3
,p_display_sequence=>30
,p_static_id=>'attribute_03'
,p_prompt=>'Display'
,p_apexlang_name=>'display'
,p_attribute_type=>'SELECT LIST'
,p_is_required=>true
,p_default_value=>'COLUMNS'
,p_is_translatable=>false
,p_lov_type=>'STATIC'
,p_help_text=>'One row per changed column with old and new values, or one row per change listing the columns that changed.'
);
wwv_flow_imp_shared.create_plugin_attr_value(
 p_id=>wwv_flow_imp.id(5629849053562799)
,p_plugin_attribute_id=>wwv_flow_imp.id(5629706885562799)
,p_display_sequence=>10
,p_display_value=>'One row per changed column'
,p_return_value=>'COLUMNS'
,p_apexlang_name=>'columns'
);
wwv_flow_imp_shared.create_plugin_attr_value(
 p_id=>wwv_flow_imp.id(5629904444562799)
,p_plugin_attribute_id=>wwv_flow_imp.id(5629706885562799)
,p_display_sequence=>20
,p_display_value=>'One row per change'
,p_return_value=>'EVENTS'
,p_apexlang_name=>'events'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630071966562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>4
,p_display_sequence=>40
,p_static_id=>'attribute_04'
,p_prompt=>'Child Tables'
,p_apexlang_name=>'childTables'
,p_attribute_type=>'TEXT'
,p_is_required=>false
,p_is_translatable=>false
,p_help_text=>'Audited tables that point at this one, comma-separated, whose changes should also show. For example EMP_TASK,PROJECT.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630147022562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>5
,p_display_sequence=>50
,p_static_id=>'attribute_05'
,p_prompt=>'Columns'
,p_apexlang_name=>'columns'
,p_attribute_type=>'TEXT'
,p_is_required=>false
,p_is_translatable=>false
,p_help_text=>'Only show changes to these columns, comma-separated. Leave empty for all.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630268042562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>6
,p_display_sequence=>60
,p_static_id=>'attribute_06'
,p_prompt=>'Readable Column Names'
,p_apexlang_name=>'readableNames'
,p_attribute_type=>'CHECKBOX'
,p_is_required=>false
,p_default_value=>'Y'
,p_is_translatable=>false
,p_help_text=>'Show "Hire Date" instead of HIRE_DATE.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630342088562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>7
,p_display_sequence=>70
,p_static_id=>'attribute_07'
,p_prompt=>'Maximum Lines'
,p_apexlang_name=>'maxRows'
,p_attribute_type=>'INTEGER'
,p_is_required=>true
,p_default_value=>'100'
,p_is_translatable=>false
,p_help_text=>'The most lines to show, newest first.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630471942562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>8
,p_display_sequence=>80
,p_static_id=>'attribute_08'
,p_prompt=>'Date Format'
,p_apexlang_name=>'dateFormat'
,p_attribute_type=>'TEXT'
,p_is_required=>false
,p_default_value=>'SINCE'
,p_is_translatable=>false
,p_help_text=>'SINCE shows "5 minutes ago", with the exact time on hover. Any Oracle date format also works, for example DD-MON-YYYY HH24:MI.'
);
wwv_flow_imp_shared.create_plugin_attribute(
 p_id=>wwv_flow_imp.id(5630561309562799)
,p_plugin_id=>wwv_flow_imp.id(5629411888562794)
,p_attribute_scope=>'COMPONENT'
,p_attribute_sequence=>9
,p_display_sequence=>90
,p_static_id=>'attribute_09'
,p_prompt=>'util_audit Schema'
,p_apexlang_name=>'utilAuditSchema'
,p_attribute_type=>'TEXT'
,p_is_required=>false
,p_is_translatable=>false
,p_help_text=>'Only when util_audit is installed in a different schema than the app''s. That schema must grant EXECUTE on UTIL_AUDIT_QUERY to the app''s schema.'
);
end;
/
prompt --application/end_environment
begin
wwv_flow_imp.import_end(p_auto_install_sup_obj => nvl(wwv_flow_application_install.get_auto_install_sup_obj, false)
);
commit;
end;
/
set verify on feedback on define on
prompt  ...done
