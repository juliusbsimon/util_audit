# util_audit

**Oracle Transaction & Column-Level Audit Framework**

`util_audit` is a trigger-based auditing framework for Oracle that
captures:

-   Transaction events
-   Column-level changes
-   Row snapshots
-   Execution context

It provides **forensic-grade auditability** without requiring Oracle
Unified Auditing or Flashback Data Archive.

This framework is designed for systems where you need to answer:

👉 **Who changed what, when, and how did the row look before and
after?**

------------------------------------------------------------------------

# ✨ Key Features

-   Transaction-level audit events
-   Column-level change tracking
-   Old and new row snapshots (JSON)
-   Change detection (skips no-op updates)
-   Automatic trigger generation
-   Config-driven enable / disable per table
-   Context capture (user, module, IP, session)
-   Audit failures logged to `UTIL_AUDIT_ERRORS`, never breaking business DML
-   Prebuilt audit query views
-   Restore a deleted or changed row, with its child rows
-   An APEX app that does all of this with clicks, and an Audit History
    region plugin for your own apps
-   Archiving of old history to S3 (or the database), on a schedule,
    with restore
-   A migration path for schemas that already run util_audit v1

------------------------------------------------------------------------

# 🏗 Architecture Overview

The framework stores audit data in **two core tables**.

## UTIL_AUDIT_TXN --- Transaction Header

One row per audited DML event.

Contains:

-   Table name
-   Primary key value
-   Transaction type (INSERT / UPDATE / DELETE)
-   Username (the APEX user in APEX sessions, the database user otherwise)
-   Execution context (JSON, see below)
-   Old row snapshot (JSON)
-   New row snapshot (JSON)
-   Database transaction ID
-   Timestamp

The execution context holds only what the other columns don't:

-   APEX sessions: `app_id`, `page_id`, `session_id`, `action`, `ip` (the
    address that connected to the web server) and `forwarded_for` (the
    `X-Forwarded-For` header). Behind a proxy or load balancer `ip` is the
    proxy and `forwarded_for` holds the browser's address. The browser can
    set that header itself, so treat it as a hint, not proof.
-   Other sessions: `module`, `client_id`, `action`, `ip`, `host`, `os_user`

Empty values are left out. For example:
`{"app_id":"100","page_id":"5","session_id":"1234567","ip":"10.0.0.8"}`

## UTIL_AUDIT_RECORDS --- Column Changes

One row per column change.

Contains:

-   Column name
-   Old value
-   New value
-   Datatype
-   Change hash
-   Timestamp
-   Transaction reference

Values up to 4000 bytes go in `OLD_VALUE` / `NEW_VALUE`. CLOB columns
and longer values go in `OLD_CLOB` / `NEW_CLOB`.

An UPDATE gets a row for each column whose value changed. An INSERT or
DELETE gets a row for each column that is not NULL. The row snapshots in
`UTIL_AUDIT_TXN` always hold every column, including ignored ones, so a
deleted row can be restored whole.

This design supports both:

✔ High-level event auditing\
✔ Detailed column forensics

## UTIL_AUDIT_ERRORS --- Audit Failures

The trigger never lets an audit failure break your INSERT, UPDATE or
DELETE. If writing the audit fails, the error is logged here instead
(table, PK, error code, message, backtrace), in its own transaction.
A half-written event is removed first, so you never get a header
without its column changes.

``` sql
SELECT * FROM util_audit_errors ORDER BY error_ts DESC;
```

------------------------------------------------------------------------

# 📊 Audit Views

Prebuilt views simplify querying.

  View                             Purpose
  -------------------------------- ---------------------------------
  **v_util_audit_events**          Transaction-level history
  **v_util_audit_changes**         Column-level changes
  **v_util_audit_row_history**     Combined event + column details
  **v_util_audit_latest_by_row**   Latest change per row
  **v_util_audit_event_summary**   Changed column summary
  **v_util_audit_tables**          Every table with its audit status
  **v_util_audit_child_tables**    Foreign keys, and whether each child table is audited

------------------------------------------------------------------------

# 🖥 The Util Audit App

`export/f129.sql` is an Oracle APEX 26.1 app that does everything below
with clicks, no scripts. It installs the framework itself.

1.  In App Builder, import `export/f129.sql` into any workspace. Let
    APEX assign a new application ID.
2.  When asked, choose **Install Supporting Objects: Yes**. This creates
    the util_audit tables, views and packages in the workspace's schema.
    Importing over an existing install upgrades it instead.
3.  Open the app, go to **Tables**, pick a table and click
    **Start Auditing**.

  Page            What you can do
  --------------- ----------------------------------------------------------
  Home            Counts, events per day, recent events
  Tables          Start, pause, resume, stop auditing; ignored columns; trigger code; child tables
  Events          Search events; open one to see context and column changes
  Event           Preview and run a restore, including child rows
  Row History     Timeline and column changes for one row
  Errors          Audit failures logged by the triggers
  Maintenance     Purge history, purge errors, re-create all triggers
  Archive         Archive settings and schedule; store, purge, restore or download each archive file
  Query Generator Build an Audit History region for a page in your own app
  Documentation   Help articles; **Help** in the top bar opens the one for the current screen

Workspace administrators and developers can change things. Other
users can look but not change anything, and cannot open Maintenance.

The app follows the computer's light or dark setting. The **Theme** menu
in the top bar switches between **Match system**, **Light** and **Dark**,
and remembers the choice per user.

Help articles live in `UTIL_AUDIT_DOC_ARTICLE`, written in Markdown.
`help.sql` creates the table and the starting articles, and the app
installs it with its Supporting Objects. Administrators can edit, add
and hide articles in the app. An upgrade adds new articles and updates
the ones nobody edited; edited articles are kept as they are.

The app's source is APEXlang in `applications/util-audit`. After
changing `setup.sql`, `help.sql` or `uninstall.sql`, run
`python3 tools/sync_supporting_objects.py` so the app installs the same
code.

------------------------------------------------------------------------

# 🧩 Audit History in Your Own Apps

Show a row's history on the page that edits it. There are three ways,
from least to most work:

1.  **The Audit History region plugin** (below). Add a region, set the
    table and the key item, done.
2.  **The table function**, in any region type you like:

    ``` sql
    select * from table(util_audit_query.history('EMP', :P10_EMP_ID))
    ```

    Pass one value per key column (`p_key1` .. `p_key4`). Options:
    `p_style => 'EVENTS'`, `p_columns`, `p_child_tables`, `p_max_rows`.
3.  **Generated SQL or APEXlang**: the app's **Query Generator** page
    writes the region for you and previews it. From SQL:
    `util_audit_query.get_history_query` (SQL for App Builder) and
    `util_audit_apx.get_plugin_region_apx` / `get_history_region_apx`
    (a region to paste into an APEXlang page file).

With child tables, changes to child rows show too, for example a
department's employees. They are matched through the foreign key values
recorded in each audited row.

## The Audit History region plugin

A region plugin (internal name `UTIL_AUDIT_HISTORY`) that lists the
changes util_audit recorded for the row the page is showing. It reads
`util_audit_query.history`, so it follows util_audit upgrades without
being regenerated.

What it shows, newest first:

  Changed         By     Action   Field       Old Value   New Value
  --------------- ------ -------- ----------- ----------- -----------
  5 minutes ago   ANN    Update   Salary      1000        1200
                                  Job Title   Clerk       Analyst
  2 days ago      BOB    Insert   Salary                  1000

-   One group per change. Later lines of the same change leave the
    first columns empty, so each change reads as one block.
-   Old values are shown in a muted colour. Values longer than 200
    characters are cut, and the full value shows on hover.
-   With child tables it adds **Table** and **Record** columns.
-   With **Display = One row per change**, it shows one line per change
    with a **Fields Changed** list instead of old and new values.
-   It works in light and dark mode, using the theme's colours.

### Install it in your app

The plugin needs util_audit (`setup.sql`) in the app's parsing schema,
or in another schema (see below). Then pick one of three ways:

-   **App Builder:** Shared Components > Plug-ins > Import, and choose
    `export/region_type_plugin_util_audit_history.sql`.
-   **SQL:** set the target app, then run the export:

    ``` sql
    begin
      apex_application_install.set_workspace('MY_WORKSPACE');
      apex_application_install.set_application_id(100);   -- your app
      apex_application_install.generate_offset;
      apex_application_install.set_schema('MY_SCHEMA');
    end;
    /
    @export/region_type_plugin_util_audit_history.sql
    ```

-   **APEXlang apps:** copy the folder
    `applications/util-audit/shared-components/plugins/region/utilAuditHistory`
    into your app's `shared-components/plugins/region/`.

### Add the region

1.  On the form page, create a region of type **Audit History [Plug-in]**.
2.  Set **Table** to the audited table, for example `EMP`.
3.  Set **Key Items** to the page item or items that hold the primary
    key, for example `P10_EMP_ID`. For a composite key, list one item per
    key column, in key column order, up to four.
4.  Optionally, give it a server-side condition "Item is NOT NULL" on the
    key item, so it stays hidden while creating a new row.

In APEXlang:

```
region audit-history (
    name: Audit History
    type: plugin/utilAuditHistory
    settings {
        table: EMP
        keyItems: P10_EMP_ID
        display: columns
        childTables: EMP_TASK,PROJECT
        readableNames: true
        maxRows: 100
        dateFormat: SINCE
    }
    layout {
        sequence: 100
        slot: body
    }
    appearance {
        template: @/standard
        templateOptions: #DEFAULT#
    }
    serverSideCondition {
        type: itemIsNotNull
        item: P10_EMP_ID
    }
)
```

`util_audit_apx.get_plugin_region_apx('EMP', p_page_id => 10)` writes
this for you, and so does the **Query Generator** page.

### Settings

  Setting                 APEXlang name       Default   What it does
  ----------------------- ------------------- --------- ------------------------------------------------------------
  Table                   `table`             (needed)  The audited table the page shows
  Key Items               `keyItems`          (needed)  Page items holding the primary key, comma-separated, in key column order
  Display                 `display`           Columns   `COLUMNS`: one line per changed column, with old and new value. `EVENTS`: one line per change, listing the columns
  Child Tables            `childTables`                 Audited tables that point at this one, comma-separated, whose changes also show
  Columns                 `columns`                     Only show these columns, comma-separated. Empty: all
  Readable Column Names   `readableNames`     Yes       "Hire Date" instead of `HIRE_DATE`
  Maximum Lines           `maxRows`           100       The most lines to show. A note says when the list is cut
  Date Format             `dateFormat`        SINCE     `SINCE` shows "5 minutes ago", with the exact time on hover; any Oracle format works, e.g. `DD-MON-YYYY HH24:MI`
  util_audit Schema       `utilAuditSchema`             Only when util_audit lives in another schema (see below)

The region's **No Data Found** message is shown when the row has no
recorded changes, and while the key item is empty. The default is "No
changes recorded yet."

### util_audit in a different schema

If the app parses as `APP_SCHEMA` and util_audit is installed in
`AUDIT_SCHEMA`, set **util_audit Schema** to `AUDIT_SCHEMA` and grant:

``` sql
grant execute on audit_schema.util_audit_query to app_schema;
```

`util_audit_query` runs with its owner's rights, so the app schema needs
no access to the audit tables themselves.

### Good to know

-   The region reads the key items' session state when the page is
    rendered. So the key items must have their value by then, as a form
    page's items do after its "Initialize form" process. After a save,
    the history is current once the page shows again.
-   The region does not support a Refresh dynamic action. To show new
    changes without a page submit, reload the page.
-   If something is wrong, such as a mistyped table name or a missing
    grant, the region shows the error message in place of the list, and
    the rest of the page still works.
-   The region shows what `util_audit_query.history` returns: the table's
    audit rows for that key. It does not apply any other access rules of
    your app. Give it the same authorization as the data it describes.

------------------------------------------------------------------------

# 🚀 Quickstart

## 1️⃣ Install

Requires Oracle 12.2 or later. Tested on 21c.

Run the setup script as a user with:

-   CREATE TABLE
-   CREATE VIEW
-   CREATE PROCEDURE
-   CREATE TRIGGER

``` sql
@setup.sql
```

The script is safe to re-run. Existing tables and audit data are kept.

## 2️⃣ Enable auditing for a table

``` sql
BEGIN
  util_audit_gen.create_audit_trigger('YOUR_TABLE');
END;
/
```

This will:

-   Register the table in `UTIL_AUDIT_CONFIG` (if not registered yet)
-   Create the audit trigger, named `AUD_<table>` (`UA_AUD_<table>` if
    another trigger already has that name)
-   Enable the trigger only if it compiled. A trigger that does not
    compile is left disabled and the call fails, so an audit problem never
    blocks changes to the table.
-   Drop any other trigger on the table that calls util_audit, such as a
    util_audit v1 `AIUD_<table>_AUD` trigger, so rows are not audited twice
-   Print the table's child tables and whether each is audited

Run it again after you add or drop columns, so the trigger picks up the
change. Re-running keeps the table's enabled / disabled setting. The
util_audit tables themselves cannot be audited.

Columns named `CREATED`, `CREATED_ON`, `CREATED_BY`, `UPDATED`,
`UPDATED_ON`, `UPDATED_BY`, `MODIFIED`, `MODIFIED_ON` and `MODIFIED_BY`
are ignored: a change to only these records nothing. To ignore more
columns for one table, store them in `UTIL_AUDIT_CONFIG`. The trigger is
re-created right away and keeps the list on every re-create:

``` sql
BEGIN
  util_audit_gen.set_table_ignored_columns('YOUR_TABLE', 'LAST_LOGIN, VERSION');
END;
/
```

To see the trigger code without creating it:

``` sql
SELECT util_audit_gen.get_trigger_ddl('YOUR_TABLE') FROM dual;
```

Ignored columns are left out of the column changes but kept in the row
snapshots, so restore can still re-insert a row whose `CREATED` column is
NOT NULL.

**Secrets need excluding, not ignoring.** An excluded column is never
recorded: not as a change, and not in the row snapshots. Use it for
password hashes, tokens and the like:

``` sql
BEGIN
  util_audit_gen.set_table_excluded_columns('APP_USER', 'PASSWORD_HASH, RESET_TOKEN');
END;
/
```

-   The names are checked against the table, so a typo is an error
    instead of a secret that stays audited. Primary key columns cannot be
    excluded.
-   The trigger is re-created straight away and never reads the columns.
-   If the table was audited before, pass `p_scrub_history => TRUE` (or
    call `util_audit_gen.scrub_columns`) to remove the columns from the
    history already recorded, then COMMIT. Archive files made earlier are
    not changed.
-   A restored row gets NULL or the column default for an excluded
    column. If the column is NOT NULL without a default, a deleted row
    cannot be restored, and `restore_row` says so.

A single-column primary key is stored as its value, e.g. `42`.
A composite key is stored as JSON, e.g.
`{"ORDER_ID":"100","LINE_NO":"1"}`.

## 3️⃣ Verify auditing

``` sql
SELECT *
FROM v_util_audit_events
WHERE table_name = 'YOUR_TABLE'
ORDER BY audit_ts DESC;
```

## 4️⃣ View column changes

``` sql
SELECT *
FROM v_util_audit_changes
WHERE table_name = 'YOUR_TABLE'
ORDER BY audit_ts DESC;
```

## 5️⃣ View full row timeline

``` sql
SELECT *
FROM v_util_audit_row_history
WHERE table_name = 'YOUR_TABLE'
  AND pk_value_vc = 'PRIMARY_KEY_VALUE'
ORDER BY audit_ts;
```

------------------------------------------------------------------------

# 🔧 Audit Enablement Control

Auditing is controlled via:

    UTIL_AUDIT_CONFIG

### Enable manually

``` sql
BEGIN
  util_audit.enable_table('YOUR_TABLE');
END;
/
```

### Disable

``` sql
BEGIN
  util_audit.disable_table('YOUR_TABLE');
END;
/
```

Triggers remain in place but auditing stops at runtime.

------------------------------------------------------------------------

# ⚙️ How Auditing Works

1️⃣ A DML operation fires an audit trigger\
2️⃣ Trigger checks `UTIL_AUDIT_CONFIG` and stops if the table is disabled\
3️⃣ Trigger builds a JSON payload: the changed columns and both row snapshots\
4️⃣ `util_audit.capture_audit` inserts the transaction header and the
column changes\
5️⃣ No audit rows are written if an UPDATE does not change data

Text is compared byte for byte, so a change from `smith` to `Smith` is
recorded even when the session uses `NLS_COMP=LINGUISTIC` with a
case-insensitive sort.

------------------------------------------------------------------------

# 🧬 Supported Datatypes

Triggers safely support:

-   NUMBER
-   FLOAT / BINARY_FLOAT / BINARY_DOUBLE
-   VARCHAR2 / CHAR / NVARCHAR2 / NCHAR
-   DATE
-   TIMESTAMP, TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH LOCAL TIME ZONE
    (the offset is kept)
-   INTERVAL
-   CLOB
-   RAW (stored as hex)

Numbers and dates are stored the same way whatever the session's NLS
settings (including `NLS_CALENDAR`): `1234.5`, `2026-02-03T00:00:00`.

Unsupported datatypes (BLOB, LONG, XMLTYPE, object types) are skipped.

------------------------------------------------------------------------

# 📈 Performance Considerations

-   Auditing adds overhead per DML
-   Only audit business-critical tables
-   Avoid auditing staging or bulk-load tables
-   Partition the audit tables by `AUDIT_TS` if they grow large
-   Purge historical data periodically:

``` sql
DECLARE
  n NUMBER;
BEGIN
  util_audit.purge(p_before => SYSTIMESTAMP - INTERVAL '365' DAY, p_events_deleted => n);
  util_audit.purge_errors(p_before => SYSTIMESTAMP - INTERVAL '30' DAY, p_errors_deleted => n);
  COMMIT;
END;
/
```

`purge` takes an optional `p_table_name` to purge one table only.

This framework is optimized for **traceability, not raw throughput**

------------------------------------------------------------------------

# 🧭 Use Cases

Ideal for:

-   Regulatory and compliance environments
-   Financial transaction systems
-   Workflow / approval tracking
-   Data governance programs
-   Investigative forensics

------------------------------------------------------------------------

# 🚫 When Not to Use

Avoid util_audit for:

-   ETL pipelines
-   High-frequency logging tables
-   Data warehouse fact tables
-   Systems where write latency is critical

------------------------------------------------------------------------

# 🧠 Design Principles

-   Deterministic triggers
-   No dynamic SQL at runtime
-   JSON-based context for extensibility
-   Separation of transaction and column data
-   Minimal dependencies

------------------------------------------------------------------------

# 🗄 Archiving Old History

`util_audit_archive` moves old audit history out of the database, one
table and one month per file (gzipped JSON lines), preferably to S3. It
reads every file back and checks it before anything is deleted, and it
can load any month back.

``` sql
exec util_audit_archive.set_setting('ARCHIVE_STORAGE', 'AWS4_S3_PKG')  -- or DATABASE, DBMS_CLOUD, CUSTOM
exec util_audit_archive.set_setting('ARCHIVE_BUCKET', 'my-audit-archive')
exec util_audit_archive.set_setting('ARCHIVE_KEEP_MONTHS', '12')
exec util_audit_archive.run                     -- archive and store months older than 12
exec util_audit_archive.schedule                -- every night at 02:00 (needs CREATE JOB)
exec util_audit_archive.restore(17)             -- load archive 17 back
```

Deleting archived months from the audit tables is off until you set
`ARCHIVE_PURGE` to `Y`. The app's **Archive** page does all of this with
clicks. The guide, including S3 setup through the `aws4_s3_pkg` that
MARAD, MCC_PROD and JFL_APPS already use, is in
[docs/archiving.md](docs/archiving.md).

------------------------------------------------------------------------

# ♻️ Restoring a Row

`util_audit.restore_row` puts a row back the way it was just before one
audit event. Pass the event's `TRANSACTION_ID`.

-   DELETE event: the row is re-inserted
-   UPDATE event: the row's columns are set back to their old values
-   INSERT events cannot be restored

``` sql
SET SERVEROUTPUT ON
BEGIN
  util_audit.restore_row('5C843A4FDFBD5AEDE063030012AC74F5', p_preview => TRUE);
END;
/
```

`p_preview => TRUE` does the whole restore, prints it, and rolls it
back. Drop it to restore for real, then COMMIT. `restore_row` never
commits. If any step fails, everything that call changed is rolled back.

### Child rows

When you restore a DELETE, child rows come back too. A child row belongs
to the deleted row when:

-   its table references the deleted row's table through a foreign key,
-   it was deleted (or its FK was set to NULL) in the same database
    transaction, and
-   its old FK values match the deleted row's key.

This covers ON DELETE CASCADE, ON DELETE SET NULL, and apps that delete
children before the parent. Grandchildren are included. A child row that
was moved to a different parent in the same transaction is not part of
the delete and stays where it is. A child row that also references a
second deleted parent waits until that parent is back, then is restored.
Example output:

    Restored DEPT 10 (undid DELETE at 2026-09-28 04:10:08)
      Restored EMP 1 (undid DELETE at 2026-09-28 04:10:08)
        Not in the audit snapshot, left NULL/default: PHOTO
        WARNING: BADGE references EMP (FK_BADGE_EMP, ON DELETE CASCADE) but is not audited. Child rows removed with this row cannot be restored.
        Restored EMP_TASK 100 (undid DELETE at 2026-09-28 04:10:08)
        Restored PROJECT 500 (undid UPDATE at 2026-09-28 04:10:08)

Child rows can only come back from **audited** child tables.
`create_audit_trigger` prints every child table and whether it is
audited, so you can see the gaps when you set up auditing.

### Limits

-   Only events recorded by this version have row snapshots. Older
    events, and history copied from util_audit v1, cannot be restored.
-   Excluded columns and unsupported types (e.g. BLOB) are not in the
    snapshot. A re-inserted row gets NULL or the column default for them.
-   An UPDATE's snapshot leaves out CLOB columns the UPDATE did not
    change. Restoring that UPDATE leaves those CLOBs as they are.
-   If the row changed again after the event, `restore_row` stops.
    Pass `p_force => TRUE` to overwrite the later changes.
-   A table with a `GENERATED ALWAYS AS IDENTITY` column cannot have a
    deleted row re-inserted with its original value.
-   The restore is audited like any other change. Its events have
    `action` = `util_audit.restore_row <id>` in `AUDIT_CONTEXT`.

------------------------------------------------------------------------

# 🔒 Protecting the Audit Trail

Anyone who can INSERT, UPDATE or DELETE on the `UTIL_AUDIT_*` tables can
change the history. Grant DML on them to no one, and give read access
through the views.

------------------------------------------------------------------------

# ⬆️ Upgrading

This is for schemas that already run this version of util_audit (they
have `UTIL_AUDIT_TXN`). For util_audit v1, see the next section.

Run `setup.sql` over the existing install, then re-create the triggers
so they use the new code:

``` sql
SET SERVEROUTPUT ON
BEGIN
  util_audit_gen.recreate_all_triggers;
END;
/
```

It lists each table. A table that fails is reported and skipped, and the
call ends with an error saying how many failed.

Until you re-create them, the old triggers keep running with the old
behavior, including taking a lock on `UTIL_AUDIT_CONFIG` for every row.

In the app: import the new `export/f129.sql` over the old app with
**Install Supporting Objects: Yes** (this runs the upgrade), then
**Maintenance > Re-create All Triggers**.

------------------------------------------------------------------------

# 🔁 Where util_audit v1 already exists

util_audit v1 is the older version: one table `UTIL_AUDIT_RECORDS` with
`PK_VALUE`, `AUDIT_DATE` and `USERENV` columns, and `AIUD_<table>_AUD`
triggers. The current version reuses the names `UTIL_AUDIT` and
`UTIL_AUDIT_RECORDS` with a different layout, so it cannot simply be
installed on top. `setup.sql` checks for v1 and stops without changing
anything.

`migrate_v1.sql` moves a v1 schema over without losing history and
without breaking the v1 triggers or the pages that read v1 data:

-   The v1 table is renamed to `UTIL_AUDIT_RECORDS_V1` and kept as it is.
-   The current version is installed next to it. Its `util_audit` package
    still accepts the v1 triggers' calls, so they keep working unchanged
    and start writing the new format.
-   `V_UTIL_AUDIT_RECORDS_V1` shows all history, old and new, in the v1
    column layout. Pages and code that read `UTIL_AUDIT_RECORDS` keep
    working once they read this view instead.

``` sql
@migrate_v1.sql            -- preview: what it would do, and what depends on v1
@migrate_v1.sql EXECUTE    -- do it
@migrate_v1_history.sql    -- later, with the apps in use: copy the v1 history
```

Then point old queries at the view and, table by table or all at once,
replace the v1 triggers with generated ones (`create_audit_trigger` or
`recreate_all_triggers`). Until you do that, `migrate_v1_rollback.sql`
undoes the migration.

The full guide, with the steps for a project that runs its migrations
through a script (and alda as a worked example), is in
[docs/migrating-from-v1.md](docs/migrating-from-v1.md).
[docs/agent-prompts/migrate-v1.md](docs/agent-prompts/migrate-v1.md) is a
prompt that has a coding agent prepare and check the migration for a
project.

------------------------------------------------------------------------

# 🗑 Uninstall

``` sql
@uninstall.sql
```

This removes the archive job, and drops every trigger that calls util_audit (found through its
dependency on the package, so v1 triggers too), and the packages, views
and tables, **including all audit history** (and `UTIL_AUDIT_RECORDS_V1`
if a v1 migration left it). Archive files already in S3 stay there.

------------------------------------------------------------------------

# 📜 License

Free for all use, including commercial.
