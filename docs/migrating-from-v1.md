# Migrating from util_audit v1

This guide is for a schema that already audits with **util_audit v1** and
should move to the current util_audit. It covers what changes, the steps,
and how to undo them. The last part walks through alda (schema `JFL_APPS`)
as a worked example.

To have a coding agent do the preparation work, give it
[agent-prompts/migrate-v1.md](agent-prompts/migrate-v1.md). It takes
stock, writes the migration files and page changes, and checks each step,
while a person runs anything that changes a shared database.

## How to tell you have v1

v1 has one audit table, `UTIL_AUDIT_RECORDS`, with the columns `PK_VALUE`,
`AUDIT_DATE` and `USERENV`, and one trigger per table named
`AIUD_<table>_AUD`. The current version has `UTIL_AUDIT_TXN` and a
`PK_VALUE_VC` column instead.

```sql
select column_name from user_tab_columns
 where table_name = 'UTIL_AUDIT_RECORDS' and column_name in ('PK_VALUE', 'PK_VALUE_VC');
```

`PK_VALUE` means v1. `setup.sql` checks this too. On a v1 schema it stops
with ORA-20100 and changes nothing, because installing on top would break
every v1 trigger.

## What the migration does

The migration keeps everything that works today working, and adds the
current version next to it:

1. The v1 table is renamed to `UTIL_AUDIT_RECORDS_V1`. Its rows, indexes
   and grants stay as they are.
2. The current tables, views and packages are installed.
3. The v1 triggers stay. The new `util_audit.capture_audit` still accepts
   their calls, so they keep auditing without any change. What they
   record now goes into the new tables.
4. Every table with a v1 trigger is registered in `UTIL_AUDIT_CONFIG`,
   enabled if its trigger was enabled.
5. A view, `V_UTIL_AUDIT_RECORDS_V1`, shows all history, old and new, with
   the v1 column names. Queries written for the v1 table work against it.

Then, at your own pace:

6. Point pages and code at `V_UTIL_AUDIT_RECORDS_V1` (or move them to the
   new views, the Audit History plugin or `util_audit_query.history`).
7. Copy the v1 history into the new tables, so the Util Audit app and the
   new views show it too.
8. Replace the v1 triggers with generated ones.

## What changes in the recorded data

| | v1 | current |
|---|---|---|
| Event per row change | `TRANSACTION_ID`, a number | `TRANSACTION_ID`, text. v1 triggers still send numbers, which are stored as text. |
| Row key | `PK_VALUE`, a number | `PK_VALUE_VC`, text. Composite keys are JSON. |
| Time | `AUDIT_DATE`, a DATE | `AUDIT_TS`, a TIMESTAMP |
| Who and where | `USERENV`, `key=value\|` text | `AUDIT_CONTEXT`, JSON, on `UTIL_AUDIT_TXN` |
| Record ids | from `SYS_GUID`, random order | an identity, in time order |
| Columns recorded | per trigger; alda's hand-written triggers leave out `ID` | every supported column except the ignored ones, including the key |
| Row snapshots | none | full old and new row, so `util_audit.restore_row` can undo a change |

Two things work the same in both versions. An UPDATE records only the
columns that changed. An INSERT or DELETE records only the columns that
are not NULL. The ignored columns are `CREATED*`, `UPDATED*` and
`MODIFIED*` (`*` = no suffix, `_ON` or `_BY`), plus any you add per table.

## The compatibility view

`V_UTIL_AUDIT_RECORDS_V1` has the v1 columns, in the v1 order, plus
`PK_VALUE_VC`:

| Column | Where it comes from |
|---|---|
| `UTIL_AUDIT_RECORD_ID` | the record id |
| `TRANSACTION_ID` | text; v1 numbers as their digits |
| `TABLE_NAME` | |
| `PK_VALUE` | a NUMBER if v1 stored numbers (a text or composite key gives NULL there, so use `PK_VALUE_VC`) |
| `PK_VALUE_VC` | the key as text |
| `COLUMN_NAME`, `DATA_TYPE`, `TRANSACTION_TYPE`, `USERNAME` | |
| `OLD_VALUE`, `NEW_VALUE`, `OLD_CLOB`, `NEW_CLOB` | |
| `USERENV` | the v1 text for v1 events, the JSON context for new ones |
| `AUDIT_DATE` | `AUDIT_TS` as a DATE |

`where table_name = 'X' and pk_value = :P1_ID` uses an index: the
migration creates `UTIL_AUDIT_RECORDS_V1PK_IX` on the numeric key for
exactly this.

Until the v1 history is copied, the view reads the not-yet-copied rows
from `UTIL_AUDIT_RECORDS_V1`. When the copy is complete, the view is
rebuilt to read the new tables only.

## Steps

All scripts are in this repository. Run them with SQLcl or SQL\*Plus,
connected as the schema that owns util_audit v1, from the repository
folder.

### 0. Test on a copy

Run the whole thing on a development copy first. On a large history,
this tells you how long the history copy (step 4) takes. Nothing here
has been timed on a production-sized table.

### 1. Preview

```sql
@migrate_v1.sql
```

It changes nothing, and lists:

- how much v1 history there is,
- every trigger that calls util_audit, and whether it is enabled,
- procedures, views and other code that use the v1 table or package
  (they may need a change),
- APEX regions and processes that read `UTIL_AUDIT_RECORDS` (only for
  apps whose workspace uses this schema),
- grants on the v1 table (they are repeated on the new objects).

### 2. Optional: switch pages first

```sql
@migration/v1_view_before_migrating.sql
```

This creates `V_UTIL_AUDIT_RECORDS_V1` over the **v1** table, with the
same columns the migration's view will have. Change your pages and code
to read the view now, and deploy them while v1 is still running. The
migration then swaps the view underneath them, so no page breaks at any
point.

If you skip this step, pages that read `UTIL_AUDIT_RECORDS` fail from
the migration until you deploy their change. That table then has the new
layout, without `PK_VALUE`, `AUDIT_DATE` or `USERENV`.

### 3. Migrate

Pick a quiet moment: it takes seconds, but sessions that already used
the v1 package can get one ORA-04068 on their next change.

```sql
@migrate_v1.sql EXECUTE
```

While the package is swapped, the v1 triggers are disabled for a few
seconds. Changes in those seconds are not audited, but nothing fails. If
the script stops, fix the cause and run it again: every step checks
whether it is already done.

At the end it recompiles what the swap invalidated and lists anything
still invalid. Typically that is code that reads v1-only columns of
`UTIL_AUDIT_RECORDS`.

### 4. Copy the v1 history

```sql
@migrate_v1_history.sql
```

It copies one month of one table at a time and commits after each, so it
can run while the apps are in use. If it stops, run it again and it
skips what it already copied.

Copied v1 events have no row snapshot, so `util_audit.restore_row`
cannot restore them. Everything else sees them: the Util Audit app, the
views, `util_audit_query.history` and the Audit History plugin.

When it is done, check a few rows and drop the archive:

```sql
drop table util_audit_records_v1 purge;
```

### 5. Replace the v1 triggers

```sql
set serveroutput on
exec util_audit_gen.recreate_all_triggers
```

Or do it one table at a time: in the Util Audit app, open **Tables**,
then the table, then **Re-create Trigger**. Or run
`util_audit_gen.create_audit_trigger('TABLE')`.

Each table gets a trigger named `AUD_<table>`. Its `AIUD_<table>_AUD`
trigger is dropped only after the new one compiled and was enabled, so
auditing has no gap. A table whose v1 trigger was disabled keeps
auditing off: its `UTIL_AUDIT_CONFIG` flag is `N` until you start it in
the app or run `util_audit.enable_table`.

From then on each change also records the full row, so it can be
restored.

### Undo

Until step 5, `migrate_v1_rollback.sql` undoes the migration:

```sql
@migrate_v1_rollback.sql
```

It disables the v1 triggers, and copies the changes recorded since the
migration back into the v1 table, in the v1 layout. It then drops the
new objects and renames `UTIL_AUDIT_RECORDS_V1` back. After that,
reinstall your v1 `util_audit` package from your own source, and enable
the triggers with the commands it prints. It refuses to run once a table
has a generated trigger, because the v1 trigger that it replaced is gone.

### Projects that run migrations through a script

Some projects run each migration file on its own, with `set define off`
and no arguments. `migrate_v1.sql` needs an argument and includes other
files, so it cannot be dropped in as it is. Build single-file versions:

```
python3 tools/bundle_v1_migration.py
```

This writes three files to `migration/bundle/`:

| File | Same as |
|---|---|
| `util_audit_v1_view_first.sql` | step 2 |
| `util_audit_v1_migrate.sql` | step 3 (`migrate_v1.sql EXECUTE`, including `setup.sql`) |
| `util_audit_v1_history.sql` | step 4 |

Copy them into the project's migrations folder under its own names.
Re-run the tool whenever `setup.sql` changes, and copy the result as a
new migration.

## Worked example: alda (JFL_APPS)

What is below comes from alda's repository (`db/src/database/jfl_apps`,
`db/migrations`, `apex/alda144`) as of September 2026. Check the preview
output against it, because the database can differ from the source
snapshot.

### What alda has today

- **History:** `UTIL_AUDIT_RECORDS`, about 25 million rows
  (`docs/apexlang-notes.md`). There are six extra indexes and a `READ`
  grant to `CLAUDE_RO`.
- **Triggers:** 23 hand-written `AIUD_<table>_AUD` triggers. 17 are in
  `db/src/.../triggers`. The other 6 (the LCL tables) are only in
  `db/migrations/20260822-03-lcl-audit.sql`.
  `AIUD_CC_SHIPMENT_CONTAINER_AUD` is disabled.
- **Drift:** columns that later migrations added to the LCL tables are not
  in their triggers, so they are not audited. For example
  `LCL_MANIFEST.OPERATION_ID` and `LCL_MANIFEST_ITEM.PARENT_ITEM_ID`.
  Generated triggers (step 5) pick them up.
- **Pages that read the v1 table:**
  - `alda144`: p36 (an interactive report on the table itself), p51,
    p53, p56, p57 and p59, and the LCL pages p70, p71, p73, p75, p77,
    p78 and p79.
  - The older copies under `db/src/.../apex_apps` have some of them too:
    `f121` p36, p51, p53, p56, p57 and p59, and `f144` p36, p56 and p57.
- **Code:** `RESTORE_CONTAINER` reads the v1 table directly.
- **Trigger names in scripts:** `20260924-08-staging-transfer-single-space.sql`
  disables and re-enables `aiud_cc_container_movement_aud` by name.
- **Other audit:** the `HISTORY` table and its `*_AUD` triggers, and the
  `*_BIU` triggers, do not call util_audit. The migration leaves them
  alone.

These alda objects were copied into a local test schema, and the steps
above were run with the bundled files, the same way `scripts/migrate.sh`
runs them: the v1 package, table, indexes, `get_audit_context`,
`RESTORE_CONTAINER`, two of the real triggers and a disabled third. The
queries from p51 and p56, and the query inside `RESTORE_CONTAINER`,
returned the same results before the migration, after it, and after the
history copy. The
read-only user could read the view at every stage.

### The steps for alda

1. **Build the files.** In this repository, run
   `python3 tools/bundle_v1_migration.py`.
2. **Switch pages to the view first (release 1).**
   - Add `util_audit_v1_view_first.sql` as a migration, e.g.
     `db/migrations/YYYYMMDD-01-util-audit-v1-view.sql`, and run it with
     `scripts/migrate.sh`.
   - In each page listed above, replace `UTIL_AUDIT_RECORDS` with
     `V_UTIL_AUDIT_RECORDS_V1`. For p36, change the interactive report's
     table name to the view.
   - Deploy the pages. Nothing else changes yet.
3. **Migrate (release 2, in a quiet moment).**
   - Add `util_audit_v1_migrate.sql` as the next migration and run it.
   - `migrate.sh` then refreshes `CLAUDE_RO`'s grants. The migration also
     repeats the old `READ` grant on the view and the new tables.
4. **Copy the history.** Add `util_audit_v1_history.sql` as a migration
   and run it when convenient. With 25 million rows, time it on a copy
   first (step 0).
5. **Replace the triggers.** Run `exec util_audit_gen.recreate_all_triggers`,
   or one table at a time from the Util Audit app. Then remove the
   `AIUD_*_AUD` files from `db/src/.../triggers`, and export the new
   `AUD_*` triggers into the project snapshot.
   - The `CC_SHIPMENT_CONTAINER` trigger was disabled, so that table stays
     off (flag `N`) until someone turns it on.
   - Scripts that disable a trigger by name around a bulk change need the
     new name, e.g. `alter trigger aud_cc_container_movement disable`.
     `util_audit.disable_table` is not a substitute: it stops auditing for
     every session, not just the script's.
6. **`RESTORE_CONTAINER`.**
   - For deletes recorded after step 5, `util_audit.restore_row` does the
     same job for any table and brings back child rows. Use
     `p_preview => TRUE` to try it first.
   - To keep the procedure for older deletes, change it to read
     `V_UTIL_AUDIT_RECORDS_V1`.
   - It has a date bug either way. It parses `LATEST_MOVEMENT_TIME` with
     `'YYYY-MM-DD HH24:MI:SS'`, but the triggers store dates as
     `2026-09-01T10:15:00`. So it fails with ORA-01861 whenever that
     column has a value. The format needs `'YYYY-MM-DD"T"HH24:MI:SS'`.
7. **Later.** Drop `UTIL_AUDIT_RECORDS_V1` once the copy is checked. Move
   audit tabs to the Audit History plugin or `util_audit_query.history`
   when you touch those pages anyway. The LCL pages sort by
   `UTIL_AUDIT_RECORD_ID`, which was random in v1. New and copied rows
   have ids in time order, so their sort order becomes meaningful.

Until step 5, `migrate_v1_rollback.sql` takes alda back to v1. The v1
package source to reinstall is in `db/src/database/jfl_apps/package_specs`
and `package_bodies`.
