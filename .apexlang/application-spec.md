# Application Spec: Util Audit

## Summary

- Application purpose: A standalone GUI for the util_audit framework. Every action the scripts and the util_audit / util_audit_gen packages offer is available with clicks.
- Target users: Workspace developers/administrators (all actions) and other authenticated users (read-only).
- Primary workflows: see audit status per table; start, pause, resume, stop auditing; set ignored columns; preview trigger code; browse events and column changes; view a row's history; restore a row (with child rows) with preview; review audit errors; purge history and errors; re-create all triggers after an upgrade; install/upgrade/deinstall via Supporting Objects.
- Authoritative sources: `setup.sql` (schema_doc) plus live DB metadata of UA_TEST (live_db); user requirements in conversation (user_asserted).
- Target app path: `applications/util-audit`
- Runtime mode: live DB check (connection `ua_test_local`)
- Destination APEX workspace: `UTIL_AUDIT_DEV` (dev); the exported app imports into any workspace whose schema has, or installs, util_audit.
- Known exclusions: No editing of audit data (audit rows are read-only). No per-user access management UI (authorization uses APEX workspace developer/admin flags). `set_ignored_columns` (session-level) is superseded by per-table ignored columns.

## Requirement Coverage Matrix

| Requirement ID | Requirement Text / Cue | Planned Page / Region / Action | Frozen Plan Reference | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| FR-001 | Standalone app importable into any workspace | App export + Supporting Objects install/upgrade/deinstall | supporting-objects.apx | covered | user_asserted |
| FR-002 | Install / upgrade / uninstall with no scripts | Supporting Objects (install on import, upgrade when UTIL_AUDIT exists, deinstall script) | supporting-objects.apx | covered | user_asserted |
| FR-003 | Overview of audit activity | P1 Home: Overview metric cards, Events per Day chart, Recent Events | P1 | covered | derived (DW-001) |
| FR-004 | See which tables are audited | P2 Tables IR on V_UTIL_AUDIT_TABLES | P2 | covered | util_audit_gen / views |
| FR-005 | Start auditing a table (create_audit_trigger) | P3 button START_AUDITING | P3 | covered | util_audit_gen.create_audit_trigger |
| FR-006 | Re-create one trigger | P3 button RECREATE_TRIGGER | P3 | covered | util_audit_gen.create_audit_trigger |
| FR-007 | Pause / resume auditing (disable_table / enable_table) | P3 buttons PAUSE_AUDITING, RESUME_AUDITING | P3 | covered | util_audit.disable_table/enable_table |
| FR-008 | Stop auditing (drop_audit_trigger) | P3 button STOP_AUDITING | P3 | covered | util_audit_gen.drop_audit_trigger |
| FR-009 | Ignored columns per table | P3 Ignored Columns shuttle + SAVE_IGNORED | P3 | covered | util_audit_gen.set_table_ignored_columns |
| FR-010 | Preview trigger code (GENERATE mode) | P3 Trigger Code dynamic content | P3 | covered | util_audit_gen.get_trigger_ddl |
| FR-011 | Child tables report | P3 Child Tables classic report | P3 | covered | V_UTIL_AUDIT_CHILD_TABLES |
| FR-012 | Browse audit events | P4 Events faceted search | P4 | covered | V_UTIL_AUDIT_EVENT_SUMMARY |
| FR-013 | Event detail, context, column changes | P5 Event | P5 | covered | UTIL_AUDIT_TXN, UTIL_AUDIT_RECORDS |
| FR-014 | Restore a row incl. child rows, preview, force | P5 Restore region | P5 | covered | util_audit.restore_row |
| FR-015 | Row history | P6 Row History timeline + changes | P6 | covered | V_UTIL_AUDIT_EVENT_SUMMARY, V_UTIL_AUDIT_CHANGES |
| FR-016 | Review audit errors | P7 Errors IR | P7 | covered | UTIL_AUDIT_ERRORS |
| FR-017 | Purge history | P8 Purge Audit History | P8 | covered | util_audit.purge |
| FR-018 | Purge errors | P8 Purge Errors | P8 | covered | util_audit.purge_errors |
| FR-019 | Re-create all triggers (upgrade step) | P8 Re-create All Triggers | P8 | covered | util_audit_gen.recreate_all_triggers |
| FR-020 | Only admins may change things | Authorization `audit-administrator` on mutating buttons/processes and P8 | shared authorizations | covered | derived (DW-002) |

- DW-001: Home dashboard. Reason: a landing page summarizing activity; uses only existing tables/views.
- DW-002: Authorization. Reason: pages can drop triggers, restore and purge; read-only users must not.

## Source Evidence Matrix

| Fact Type | Object / Column | Evidence Source | Evidence Detail | Status |
| --- | --- | --- | --- | --- |
| view | V_UTIL_AUDIT_TABLES(TABLE_NAME, AUDIT_STATUS, TRIGGER_NAME, ENABLED_FLAG, IGNORED_COLUMNS, HAS_PK, CHILD_TABLES, UNAUDITED_CHILD_TABLES, EVENT_COUNT, LAST_EVENT_TS) | schema_doc + live_db | setup.sql; queried in UA_TEST | ok |
| view | V_UTIL_AUDIT_CHILD_TABLES(PARENT_TABLE, CHILD_TABLE, CONSTRAINT_NAME, DELETE_RULE, CHILD_AUDITED) | schema_doc + live_db | setup.sql | ok |
| view | V_UTIL_AUDIT_EVENT_SUMMARY(AUDIT_TS, TABLE_NAME, PK_VALUE_VC, TRANSACTION_TYPE, USERNAME, TRANSACTION_ID, CHANGED_COLUMNS) | schema_doc | setup.sql | ok |
| view | V_UTIL_AUDIT_CHANGES(AUDIT_TS, TABLE_NAME, PK_VALUE_VC, TRANSACTION_TYPE, USERNAME, TRANSACTION_ID, COLUMN_NAME, DATA_TYPE, OLD_VALUE, NEW_VALUE, OLD_CLOB, NEW_CLOB, CHANGE_HASH) | schema_doc | setup.sql | ok |
| table | UTIL_AUDIT_TXN(TRANSACTION_ID unique, DB_TRANSACTION_ID, TABLE_NAME, PK_VALUE_VC, TRANSACTION_TYPE check INSERT/UPDATE/DELETE, USERNAME, AUDIT_CONTEXT json, OLD_ROW_JSON, NEW_ROW_JSON, AUDIT_TS) | schema_doc | setup.sql | ok |
| table | UTIL_AUDIT_RECORDS(UTIL_AUDIT_RECORD_ID, TRANSACTION_ID fk, COLUMN_NAME, DATA_TYPE, OLD_VALUE, NEW_VALUE, OLD_CLOB, NEW_CLOB) | schema_doc | setup.sql | ok |
| table | UTIL_AUDIT_ERRORS(UTIL_AUDIT_ERROR_ID, ERROR_TS, TABLE_NAME, TRANSACTION_TYPE, PK_VALUE_VC, USERNAME, ERROR_CODE, ERROR_MESSAGE, ERROR_BACKTRACE) | schema_doc | setup.sql | ok |
| table | UTIL_AUDIT_CONFIG(TABLE_NAME pk, ENABLED_FLAG, IGNORED_COLUMNS) | schema_doc | setup.sql | ok |
| package | util_audit.enable_table / disable_table / purge / purge_errors / restore_row | schema_doc | setup.sql spec | ok |
| package | util_audit_gen.create_audit_trigger / drop_audit_trigger / set_table_ignored_columns / get_trigger_ddl / recreate_all_triggers | schema_doc | setup.sql spec | ok |
| dictionary | USER_TAB_COLUMNS(TABLE_NAME, COLUMN_NAME, COLUMN_ID) | live_db | Oracle dictionary | ok |
| APEX view | APEX_WORKSPACE_APEX_USERS(WORKSPACE_NAME, USER_NAME, IS_ADMIN, IS_APPLICATION_DEVELOPER) | live_db | APEX 26.1 | ok |

## Frozen Application Plan

| Page | Name | Group | Type / Native Pattern | Page Mode | Menu | Breadcrumb Entry | Req | Primary Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Home | - | dashboard | normal | Home (fa-home) | home (root) | FR-003 | util_audit_txn, v_util_audit_tables, util_audit_errors |
| 2 | Tables | - | interactive report | normal | Tables (fa-table) | tables (parent home) | FR-004 | V_UTIL_AUDIT_TABLES |
| 3 | Table | - | form-like drawer (end) | modal drawer | - | - (modal) | FR-005..011 | V_UTIL_AUDIT_TABLES |
| 4 | Events | - | faceted search + classic report | normal | Events (fa-history) | events (parent home) | FR-012 | V_UTIL_AUDIT_EVENT_SUMMARY |
| 5 | Event | - | detail + action drawer (end) | modal drawer | - | - (modal) | FR-013, FR-014 | UTIL_AUDIT_TXN |
| 6 | Row History | - | selector + timeline + classic report | normal | Row History (fa-clock-o) | row-history (parent home) | FR-015 | V_UTIL_AUDIT_EVENT_SUMMARY |
| 7 | Errors | - | interactive report | normal | Errors (fa-exclamation-triangle) | errors (parent home) | FR-016 | UTIL_AUDIT_ERRORS |
| 8 | Maintenance | Administration | action page | normal, auth audit-administrator | Maintenance (fa-wrench, auth) | maintenance (parent home) | FR-017..019 | packages |
| 12 | Archive | Administration | action page + report | normal, auth audit-administrator | Archive (fa-archive, auth) | archive (parent home) | archiving | util_audit_archive, UTIL_AUDIT_ARCHIVE_FILES |
| 9999 | Login | - | login | global | - | - | scaffold | - |

## Frozen Region Plan

| Page | Order | Region Name | Family | Source Shape | Source / Query | Links / Actions | Refresh |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 10 | Home | breadcrumb (breadcrumbBar) | none | @breadcrumb | - | - |
| 1 | 20 | Overview | metric card template component | sql | 4 rows: Audited Tables, Events (24h), Events (7 days), Errors (7 days) | - | - |
| 1 | 30 | Events per Day | chart (bar, stacked by transaction_type) | sql | util_audit_txn last 14 days | - | - |
| 1 | 40 | Recent Events | classic report | sql | top 10 V_UTIL_AUDIT_EVENT_SUMMARY | AUDIT_TS link -> P5 | - |
| 2 | 10 | Tables | breadcrumb | none | @breadcrumb | - | - |
| 2 | 20 | Audited Tables | interactive report | view | V_UTIL_AUDIT_TABLES | TABLE_NAME link -> P3 | close-dialog refresh |
| 3 | 10 | Status | static content with display items | none | items loaded by before-header process from V_UTIL_AUDIT_TABLES | START_AUDITING, RECREATE_TRIGGER, PAUSE_AUDITING, RESUME_AUDITING, STOP_AUDITING | - |
| 3 | 20 | Ignored Columns | static content with shuttle | none | P3_IGNORED_COLUMNS | SAVE_IGNORED | - |
| 3 | 30 | Child Tables | classic report | sql | V_UTIL_AUDIT_CHILD_TABLES where parent_table = :P3_TABLE_NAME | - | - |
| 3 | 40 | Trigger Code | dynamic content (PL/SQL CLOB) | none | util_audit_gen.get_trigger_ddl | - | - |
| 3 | 50 | Buttons | buttons container (dialog footer) | none | - | CANCEL | - |
| 4 | 10 | Events | breadcrumb | none | @breadcrumb | - | - |
| 4 | 20 | Search | faceted search | - | facets on results | - | - |
| 4 | 30 | Event Results | classic report | sql | V_UTIL_AUDIT_EVENT_SUMMARY | AUDIT_TS -> P5; HISTORY -> P6 | close-dialog refresh |
| 5 | 10 | Event | static content with display items | none | before-header fetch from UTIL_AUDIT_TXN | - | - |
| 5 | 20 | Context | classic report | sql | AUDIT_CONTEXT unpivoted to Key/Value | - | - |
| 5 | 30 | Column Changes | classic report | sql | UTIL_AUDIT_RECORDS for the event | - | - |
| 5 | 40 | Restore | static content with items | none | P5_INCLUDE_CHILDREN, P5_FORCE, P5_RESTORE_OUTPUT | PREVIEW_RESTORE, RESTORE | - |
| 5 | 50 | Buttons | buttons container | none | - | CLOSE | - |
| 6 | 10 | Row History | breadcrumb | none | @breadcrumb | - | - |
| 6 | 20 | Row | static content with items | none | P6_TABLE_NAME, P6_PK_VALUE | - | change -> refresh 30, 40 |
| 6 | 30 | Timeline | timeline template component | sql | V_UTIL_AUDIT_EVENT_SUMMARY for the row | link -> P5 | close-dialog refresh |
| 6 | 40 | All Column Changes | classic report | sql | V_UTIL_AUDIT_CHANGES for the row | - | - |
| 7 | 10 | Errors | breadcrumb | none | @breadcrumb | - | - |
| 7 | 20 | Audit Errors | interactive report | table | UTIL_AUDIT_ERRORS | - | - |
| 8 | 10 | Maintenance | breadcrumb | none | @breadcrumb | - | - |
| 8 | 20 | Purge Audit History | static content with items | none | P8_PURGE_BEFORE, P8_PURGE_TABLE | PURGE_HISTORY | - |
| 8 | 30 | Purge Errors | static content with items | none | P8_ERRORS_BEFORE | PURGE_ERRORS | - |
| 8 | 40 | Re-create All Triggers | static content with items | none | P8_RECREATE_OUTPUT | RECREATE_ALL | - |

## Application Composition Plan

- Application scope: new app, alias UTIL-AUDIT, name "Util Audit".
- Page groups: Administration (P8).
- Shared LOVs: `audited-tables` (tables with audit events).
- Navigation menu: Home, Tables, Events, Row History, Errors, Maintenance, Archive (Maintenance and Archive authorized by audit-administrator).
- Static files/icons: scaffold icons.

### Breadcrumb Hierarchy

| Page | Entry | Root | Parent Entry |
| --- | --- | --- | --- |
| 1 | home | yes | - |
| 2 | tables | - | home |
| 4 | events | - | home |
| 6 | row-history | - | home |
| 7 | errors | - | home |
| 8 | maintenance | - | home |
| 12 | archive | - | home |

## Behavior Coverage

### Modal Targets And Cross-Page Links

| Source Page | Source | Target Page | Target Items | Key Column | Presentation | Close Refresh Region |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Recent Events.AUDIT_TS | 5 | P5_TRANSACTION_ID | TRANSACTION_ID | drawer end | Recent Events |
| 2 | Audited Tables.TABLE_NAME | 3 | P3_TABLE_NAME | TABLE_NAME | drawer end | Audited Tables |
| 4 | Event Results.AUDIT_TS | 5 | P5_TRANSACTION_ID | TRANSACTION_ID | drawer end | Event Results |
| 4 | Event Results.HISTORY | 6 | P6_TABLE_NAME, P6_PK_VALUE | TABLE_NAME, PK_VALUE_VC | normal page | - |
| 6 | Timeline row link | 5 | P5_TRANSACTION_ID | TRANSACTION_ID | drawer end | Timeline |

### Page Actions (buttons and processes)

| Page | Button | Process (PL/SQL) | Condition | Authorization | After |
| --- | --- | --- | --- | --- | --- |
| 3 | START_AUDITING "Start Auditing" | util_audit_gen.create_audit_trigger(:P3_TABLE_NAME) | P3_AUDIT_STATUS = 'Not audited' and P3_HAS_PK = 'Y' | audit-administrator | close dialog, message "Auditing started." |
| 3 | RECREATE_TRIGGER "Re-create Trigger" | util_audit_gen.create_audit_trigger(:P3_TABLE_NAME) | P3_TRIGGER_NAME is not null | audit-administrator | close dialog |
| 3 | PAUSE_AUDITING "Pause" | util_audit.disable_table(:P3_TABLE_NAME) | P3_AUDIT_STATUS = 'Auditing' | audit-administrator | close dialog |
| 3 | RESUME_AUDITING "Resume" | util_audit.enable_table(:P3_TABLE_NAME) | P3_AUDIT_STATUS = 'Paused' | audit-administrator | close dialog |
| 3 | STOP_AUDITING "Stop Auditing" (confirm, danger) | util_audit_gen.drop_audit_trigger(:P3_TABLE_NAME) | P3_TRIGGER_NAME is not null | audit-administrator | close dialog |
| 3 | SAVE_IGNORED "Save Ignored Columns" | util_audit_gen.set_table_ignored_columns(:P3_TABLE_NAME, replace(:P3_IGNORED_COLUMNS, ':', ',')) | always | audit-administrator | close dialog |
| 5 | PREVIEW_RESTORE "Preview Restore" | restore wrapper (p_preview true), output to P5_RESTORE_OUTPUT | P5_CAN_RESTORE = 'Y' | audit-administrator | stay on page |
| 5 | RESTORE "Restore" (confirm, hot) | restore wrapper (p_preview false) | P5_CAN_RESTORE = 'Y' | audit-administrator | stay on page |
| 8 | PURGE_HISTORY (confirm, danger) | util_audit.purge(:P8_PURGE_BEFORE, :P8_PURGE_TABLE, n) | always | page-level | message with count |
| 8 | PURGE_ERRORS (confirm, danger) | util_audit.purge_errors(:P8_ERRORS_BEFORE, n) | always | page-level | message with count |
| 8 | RECREATE_ALL (confirm) | util_audit_gen.recreate_all_triggers, output to P8_RECREATE_OUTPUT | always | page-level | stay |

### Form Validations, Context, And Defaults

| Page | Item | Type | Rule |
| --- | --- | --- | --- |
| 3 | P3_TABLE_NAME | context | hidden, value protected, set by P2 link |
| 5 | P5_TRANSACTION_ID | context | hidden, value protected, set by links |
| 5 | P5_INCLUDE_CHILDREN | default | Y |
| 5 | P5_FORCE | default | N |
| 8 | P8_PURGE_BEFORE | validation/default | required when PURGE_HISTORY; default today minus 365 days |
| 8 | P8_ERRORS_BEFORE | validation/default | required when PURGE_ERRORS; default today minus 30 days |

### Refresh Dependencies

| Event Source | Event | Affected Region |
| --- | --- | --- |
| P1 Recent Events | apexafterclosedialog | Recent Events |
| P2 Audited Tables | apexafterclosedialog | Audited Tables |
| P4 Event Results | apexafterclosedialog | Event Results |
| P6 Timeline | apexafterclosedialog | Timeline |
| P6 P6_TABLE_NAME, P6_PK_VALUE | change | Timeline, All Column Changes |

### Security, Guidance, And Empty States

- Authentication: Oracle APEX Accounts (scaffold). Any workspace user can sign in and read.
- Authorization `audit-administrator`: user is a workspace admin or application developer in APEX_WORKSPACE_APEX_USERS for the current workspace. Applied to every mutating button/process and to page 8 plus its menu entry.
- No-data messages: each report states what is missing ("No audit events yet." etc.).
- P3 shows a note when the table has no primary key (auditing requires one).
- P5 shows a note when the event is an INSERT or has no snapshot (cannot be restored).

## Rich UI Pattern Plan

| Pattern | Page / Region | Native Component |
| --- | --- | --- |
| metricCard | P1 Overview | Metric Card template component |
| bar chart | P1 Events per Day | JET bar chart, stacked |
| faceted search | P4 Search | Faceted Search: TABLE_NAME, TRANSACTION_TYPE, USERNAME (checkbox), AUDIT_TS (date range) |
| timeline | P6 Timeline | Timeline template component |
| drawer | P3, P5 | modal drawer end |

## LOVs

- `audited-tables` (dynamic): `select table_name d, table_name r from v_util_audit_tables where event_count > 0 order by 1`. Used by P6_TABLE_NAME, P8_PURGE_TABLE.
- Page-local: P3_IGNORED_COLUMNS columns of the table (`user_tab_columns` where table_name = :P3_TABLE_NAME order by column_id); P6_PK_VALUE distinct PK values (cascading on P6_TABLE_NAME).

## Test Plan

| Scenario | Expected |
| --- | --- |
| Import app with supporting objects into empty schema | util_audit objects created, app runs |
| Start/pause/resume/stop auditing from P3 | V_UTIL_AUDIT_TABLES status changes accordingly |
| Save ignored columns | UTIL_AUDIT_CONFIG.IGNORED_COLUMNS set, trigger re-created without those columns |
| Restore preview and restore from P5 | output lists restored rows; preview changes nothing |
| Read-only user | mutating buttons hidden, P8 not accessible |
| Live APEX validation | pass |

## Missing Inputs / Blockers

- none
