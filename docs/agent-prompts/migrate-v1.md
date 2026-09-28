# Agent prompt: migrate a project from util_audit v1

Copy everything below the line into a coding agent (for example Claude
Code) that is running in the project to migrate. Fill in the three values
in the first section first. The agent prepares and checks the migration;
a person runs anything that changes a shared database.

---

You are migrating this project's database schema from **util_audit v1**
to the current util_audit. Work carefully: the audit history is a legal
record and must not be lost or changed.

## Inputs

- util_audit repository (read it, do not change it): `<path, e.g. /home/me/util_audit>`
- This project's schema that owns util_audit v1: `<schema, e.g. JFL_APPS>`
- Database access you have: `<e.g. "read-only connection named ro", or "none">`

## Read first

1. `<util_audit repo>/docs/migrating-from-v1.md`: the whole guide. The
   steps below follow it. If they disagree, the guide wins; tell me.
2. `<util_audit repo>/README.md`, the section "Where util_audit v1
   already exists".
3. This project's own rules for database changes (for example CLAUDE.md,
   RUNBOOK.md, `db/migrations/README.md`): how migrations are named, who
   runs them, and in what order pages and migrations ship. Follow those
   rules over anything here.

## Rules

- Never run anything that changes a shared or production database. You
  may run read-only queries if you have a read-only connection. A person
  runs the migration files. Stop and ask when a step needs a change there.
- Never edit files in the util_audit repository. Copy what you need.
- Never print or store passwords, keys or connection strings.
- Do not change code that has nothing to do with util_audit.
- Commit only when I ask.
- When something doesn't match what the guide expects, stop and tell me
  what you found instead of working around it.

## Step 1: take stock (no changes)

Find and list, with file paths and line numbers:

1. **The v1 objects.** Confirm `UTIL_AUDIT_RECORDS` has a `PK_VALUE`
   column (v1). Note its row count if you can query it. Note the column
   types of `TRANSACTION_ID` and `PK_VALUE`, its indexes, and its grants.
2. **The triggers that call util_audit.** Both those in the source tree
   and those created by migration files. Note which are disabled. If you
   can query the database, compare with:

   ```sql
   select d.name, t.table_name, t.status
     from user_dependencies d join user_triggers t on t.trigger_name = d.name
    where d.type = 'TRIGGER' and d.referenced_name = 'UTIL_AUDIT'
      and d.referenced_type = 'PACKAGE';
   ```

3. **Readers of the v1 table.** Every APEX page region, process, LOV and
   item that reads `UTIL_AUDIT_RECORDS`, and every procedure, package,
   view and script. For each, note which v1-only columns it uses
   (`PK_VALUE`, `AUDIT_DATE`, `USERENV`) and anything that assumes
   `TRANSACTION_ID` or `PK_VALUE` is a number.
4. **Calls to v1-only procedures**, such as `util_audit.add_table_audit_trig`
   or `create_audit_table`. They no longer exist after the migration.
5. **Scripts that name a v1 trigger**, for example
   `alter trigger aiud_x_aud disable`. After step 5 below the triggers
   are named `AUD_<table>`.
6. **Other audit mechanisms**: other history tables, triggers named
   `*_AUD`, other packages. The migration must leave them alone. Confirm
   they do not call util_audit.
7. **Audit gaps**: columns added to audited tables after their v1 trigger
   was written, which the trigger therefore misses.

Report this as a short inventory, then wait for me to confirm before
changing any file.

## Step 2: prepare the files

1. In the util_audit repository, run `python3 tools/bundle_v1_migration.py`.
   It only writes into `migration/bundle/`. If you may not run it, ask me
   to.
2. Copy the three bundle files into this project's migrations folder,
   named by the project's rules. Keep this order:
   1. `util_audit_v1_view_first.sql` creates `V_UTIL_AUDIT_RECORDS_V1` on
      the v1 table.
   2. `util_audit_v1_migrate.sql` is the migration.
   3. `util_audit_v1_history.sql` copies the v1 history.

   Put each in its own migration file, so they can run on different days.
3. Change every reader from step 1.3 to read `V_UTIL_AUDIT_RECORDS_V1`
   instead of `UTIL_AUDIT_RECORDS`. Change nothing else in those queries,
   except:
   - `TRANSACTION_ID` becomes text. Comparisons with a page item work as
     they are. Fix code that does arithmetic on it or stores it in a
     NUMBER variable.
   - `PK_VALUE` stays a number when v1 stored numbers.
   - An interactive report built on the table itself needs its table name
     changed to the view.
4. For code that restores rows from the v1 table, note that
   `util_audit.restore_row` does the job for events recorded after step 5
   below. Don't rewrite that code now; list it for me.
5. Write a short release note for me: which files ship in which release,
   in which order, and what a person has to run.

These page and code changes only work once the view exists. So they ship
in the same release as the first migration file, or later, never before
it.

## Step 3: check before anyone runs it

1. If you have a read-only connection, check that every reader from step
   1.3 would still parse. Compare the columns each one uses with the
   view's columns, listed in the guide under "The compatibility view".
2. Validate the changed APEX pages with the project's usual tools.
3. Ask me to run the preview on the target database. It changes nothing:

   ```sql
   @migrate_v1.sql
   ```

   Run it from the util_audit repository folder, as the schema owner.
   Compare its trigger list, dependency list and APEX list with your
   inventory, and explain any difference.
4. Ask whether the whole sequence was rehearsed on a copy of the
   database, and how long the history copy took there. If it was not
   rehearsed, say that this is the main risk.

## Step 4: after each file has run

After the person tells you a file ran, verify with read-only queries
where you can:

- **After the first file:** `V_UTIL_AUDIT_RECORDS_V1` exists and returns
  the same row count as `UTIL_AUDIT_RECORDS`.
- **After the second file:**
  - `UTIL_AUDIT_RECORDS_V1`, `UTIL_AUDIT_TXN` and `UTIL_AUDIT_V1_TRIGGERS`
    exist.
  - The triggers that were enabled before are enabled again.
  - `select count(*) from util_audit_errors` is 0.
  - A test change on an audited table (in a development database only)
    shows up in `V_UTIL_AUDIT_RECORDS_V1`.
  - Nothing util_audit-related is INVALID, apart from the readers you
    have not switched yet.
- **After the third file:**
  - The script's output says the view reads the new tables only.
  - The view's row count is the old v1 count plus what was recorded
    since.
  - Spot-check three events from the v1 archive against the view.
- Check the pages you changed, by opening them or with the project's
  usual tests.

## Step 5: replace the v1 triggers (a separate, later change)

Only after the steps above are verified, and only when I say so:

1. A person runs `exec util_audit_gen.recreate_all_triggers`, or recreates
   one table at a time from the Util Audit app.
2. Update the project's source snapshot: remove the `AIUD_*_AUD` trigger
   files and add the generated `AUD_*` triggers.
3. Update the scripts from step 1.5 to the new trigger names.
4. From now on, rolling back with `migrate_v1_rollback.sql` is no longer
   possible. Say so in the release note.

## Rollback

Until step 5, `migrate_v1_rollback.sql` from the util_audit repository
undoes the migration. It keeps the changes recorded since, by copying
them back into the v1 table. After running it, the person must reinstall
the v1 `util_audit` package from this project's source and enable the
triggers it lists. Keep your page changes on a branch, so they can be
reverted along with it.

## What to report back

- The inventory (step 1).
- Every file you added or changed, and why.
- The release plan (step 2.5).
- The results of each check, including anything that did not match the
  guide.
- Open risks. The main one is always a history copy that was never timed
  on a copy of production data.
