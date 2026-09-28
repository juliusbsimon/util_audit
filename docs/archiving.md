# Archiving audit history

Audit tables only grow. `util_audit_archive` moves old history out of
the database into files, preferably in S3. It can do this on a schedule,
and it can load a month back whenever someone needs it.

## How it works

The unit is **one table, one calendar month**. For each unit:

1. **Archive.** All of that month's events for the table, with their
   column changes and row snapshots, are written to one file. The file is
   gzipped JSON lines (`.jsonl.gz`), one event per line.
2. **Store.** The file goes to its storage, for example S3. It is then
   read back, and its SHA-256 is compared with the original. Only a file
   that comes back identical counts as stored.
3. **Purge** (optional). The month's events are deleted from the audit
   tables, but first the tables are checked to still hold exactly what
   the file holds.
4. **Restore** (when needed). The file is fetched, checked against its
   SHA-256, and its events are loaded back. Events that are already
   there are skipped, so a restore can be repeated safely.

`UTIL_AUDIT_ARCHIVE_FILES` has one row per file: the table, the month,
counts, size, checksum, where it is, and its status:

| Status | Meaning |
|---|---|
| CREATED | File built, kept in the row until it is stored |
| STORED | File in storage, read back and checked |
| PURGED | The month's events were deleted from the audit tables |
| RESTORED | The events were loaded back |
| FAILED | A step failed; `MESSAGE` says why. The next run tries again |

For example, a DELETE on `EMP` in January 2025 ends up in S3 at:

    s3://my-bucket/util_audit/HR/table=EMP/month=2025-01/EMP_2025-01_17.jsonl.gz

## Where the files go

Set `ARCHIVE_STORAGE` to one of four values.

| `ARCHIVE_STORAGE` | Where | Settings it needs |
|---|---|---|
| `DATABASE` (default) | the `CONTENT` column of `UTIL_AUDIT_ARCHIVE_FILES` | none |
| `AWS4_S3_PKG` | S3, through the schema's `aws4_s3_pkg` | `ARCHIVE_BUCKET`, optionally `ARCHIVE_PREFIX` |
| `DBMS_CLOUD` | S3 or other object storage, through `DBMS_CLOUD` (Autonomous Database and some on-premises installs; not RDS) | `ARCHIVE_CREDENTIAL`, `ARCHIVE_BASE_URI` |
| `CUSTOM` | anywhere your own code can reach | `ARCHIVE_PUT_PROCEDURE`, `ARCHIVE_GET_FUNCTION` |

### S3 through AWS4_S3_PKG

MARAD, MCC_PROD and JFL_APPS (alda) already have `aws4_s3_pkg`. It
signs S3 requests in PL/SQL and sends them with `APEX_WEB_SERVICE`, and
their document uploads use it. util_audit calls it the same way:

- to upload: `aws4_s3_pkg.put_object(p_bucket, p_blob, p_object_key, p_mimetype)`
- to read back: `aws4_s3_pkg.get_object_blob(p_bucket, p_canonical_uri)`

`put_object` does not raise an error when S3 refuses the upload. It
commits, and on an APEX page it shows an alert. So util_audit checks
`apex_web_service.g_status_code` after each upload, and reads every file
back before it counts as stored. A refused upload leaves the archive
FAILED, with the HTTP status in `MESSAGE`.

```sql
exec util_audit_archive.set_setting('ARCHIVE_STORAGE', 'AWS4_S3_PKG')
exec util_audit_archive.set_setting('ARCHIVE_BUCKET', 'my-audit-archive')
exec util_audit_archive.set_setting('ARCHIVE_PREFIX', 'util_audit/jfl_apps')
commit;
```

What the bucket needs:

- The AWS key that `aws4_s3_pkg` uses needs `s3:PutObject` and
  `s3:GetObject` on the prefix.
- Use a bucket (or prefix) of its own, with versioning on. Deny
  `s3:DeleteObject` to everyone except whoever manages retention: the
  archive is part of the audit trail.
- If audit history must be kept for a set number of years, S3 Object
  Lock or a lifecycle rule can enforce it. A rule can also move old
  files to a cheaper storage class; restore then has to wait until S3
  brings the file back.
- `aws4_s3_pkg` sends to `us-east-1` (`g_aws_region`), so create the
  bucket there or change the package.

A warning about the existing packages: their AWS access key and secret
are written into the package body. In the mcc-trading repository, that
source file contains the key and secret. Rotate those keys and move them out of
source control before building more on top of them.

### DBMS_CLOUD

```sql
exec util_audit_archive.set_setting('ARCHIVE_STORAGE', 'DBMS_CLOUD')
exec util_audit_archive.set_setting('ARCHIVE_CREDENTIAL', 'AUDIT_S3_CRED')
exec util_audit_archive.set_setting('ARCHIVE_BASE_URI', 'https://my-bucket.s3.eu-central-1.amazonaws.com')
commit;
```

The credential is created with `DBMS_CLOUD.CREATE_CREDENTIAL`.

### Your own code

If a system has its own way to reach S3 (or anything else), point
util_audit at two routines with these signatures:

```sql
procedure my_put(p_object_key in varchar2, p_content in blob);   -- raise on failure
function  my_get(p_object_key in varchar2) return blob;
```

```sql
exec util_audit_archive.set_setting('ARCHIVE_STORAGE', 'CUSTOM')
exec util_audit_archive.set_setting('ARCHIVE_PUT_PROCEDURE', 'my_put')
exec util_audit_archive.set_setting('ARCHIVE_GET_FUNCTION', 'my_get')
commit;
```

`p_object_key` is the path shown above, without the bucket, for example
`util_audit/HR/table=EMP/month=2025-01/EMP_2025-01_17.jsonl.gz`. The
routine must raise an error when it fails. util_audit reads the file back
and checks it either way.

## Retention and scheduling

| Setting | Default | Meaning |
|---|---|---|
| `ARCHIVE_KEEP_MONTHS` | 12 | Months kept in the audit tables. Older complete months are archived. |
| `ARCHIVE_PURGE` | N | Y: delete archived months from the audit tables. |

`ARCHIVE_PURGE` starts at N, so the first runs only make copies. Restore
one archive on a test copy, check it, and only then set it to Y.

`util_audit_archive.run` does one pass:

1. Stores files that were built but not stored yet, for example after a
   failed upload.
2. Archives and stores every table-month older than `ARCHIVE_KEEP_MONTHS`
   that has no archive yet (at most `p_max_files` new files per run,
   default 100).
3. Purges stored months, if `ARCHIVE_PURGE` is Y.

It prints what it did. If anything failed, it raises an error at the end,
so a scheduled run shows up as failed.

To run it every night at 02:00:

```sql
exec util_audit_archive.schedule('FREQ=DAILY;BYHOUR=2;BYMINUTE=0')
```

This creates the DBMS_SCHEDULER job `UTIL_AUDIT_ARCHIVE_JOB`, which needs
`CREATE JOB` (mcc's `AWS_FOLDER_MOVE` job works the same way).
`util_audit_archive.unschedule` removes it. Check the runs with:

```sql
select log_date, status, error#, additional_info
  from user_scheduler_job_run_details
 where job_name = 'UTIL_AUDIT_ARCHIVE_JOB'
 order by log_date desc;
```

The Util Audit app does all of this on its **Archive** page: settings,
schedule, run now, and store, purge, restore or download for each file.

## Restoring

```sql
set serveroutput on
exec util_audit_archive.restore(17)
```

The month's events are back in the audit tables, with their original
transaction ids, times, users, context, row snapshots and column
changes. Row
History, the views, `util_audit_query.history` and `util_audit.restore_row`
all work on them again.

A restored month is older than `ARCHIVE_KEEP_MONTHS`, so the next
scheduled run archives it again, and purges it again if `ARCHIVE_PURGE`
is Y. To keep it for a while, turn the schedule off or raise
`ARCHIVE_KEEP_MONTHS` until you are done.

To get the file itself, without loading it:

```sql
select util_audit_archive.get_file(17) from dual;   -- the .jsonl.gz BLOB
```

## Reading archives without restoring

The files are plain gzipped JSON lines in Hive-style folders
(`table=…/month=…`), so they can be read where they are:

- **Amazon Athena:** a table over the prefix, with a JSON SerDe and
  `table` and `month` as partition columns. One line is one event with a
  `changes` array.
- **Any machine:** `aws s3 cp s3://…/EMP_2025-01_17.jsonl.gz - | gunzip | jq .`

One line looks like this (shortened):

```json
{"transaction_id":"5C8E...","table_name":"EMP","pk_value":"7","transaction_type":"UPDATE",
 "username":"ANN","audit_ts":"2025-01-14T09:31:02.123456",
 "audit_context":{"app_id":"100","page_id":"5"},
 "old_row":{"EMP_ID":"7","SAL":"1000"},"new_row":{"EMP_ID":"7","SAL":"1200"},
 "changes":[{"column_name":"SAL","data_type":"NUMBER","old_value":"1000","new_value":"1200"}]}
```

## Things to know

- Each step commits. One file is one unit of work, so a failure stops at
  that file, and the next run picks up from there.
- **Size.** A file is built in temporary LOBs, one month of one table at
  a time. A very busy table can make a large file. `aws4_s3_pkg` sends it
  in one request, which S3 allows up to 5 GB.
- **Checksum.** It is a SHA-256 through `DBMS_CRYPTO`. A schema without
  `EXECUTE` on `DBMS_CRYPTO` gets a SHA-256 chain over blocks instead,
  marked `blocks:`. Each archive is always checked with the kind it was
  made with.
- **What purge leaves.** It deletes events and their changes, but not
  `UTIL_AUDIT_ERRORS`. `util_audit.purge_errors` handles that table.
- **util_audit v1 history** copied by `migrate_v1_history.sql` is
  archived like any other history. It has no row snapshots.
- **Uninstall** drops `UTIL_AUDIT_ARCHIVE_FILES`, the settings and the
  job. Files in S3 are left where they are.
- **Tested on:** Oracle 21c with a stand-in `aws4_s3_pkg`. It was not
  run against real S3 or on 19c. Try one month on a test system first:
  archive, store, purge, restore, then compare.
