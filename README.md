# util_audit

**Oracle Transaction & Column-Level Audit Framework**

`util_audit` is a trigger-based auditing framework for Oracle that
captures:

-   Transaction events\
-   Column-level changes\
-   Row snapshots\
-   Execution context

It provides **forensic-grade auditability** without requiring Oracle
Unified Auditing or Flashback Data Archive.

This framework is designed for systems where you need to answer:

👉 **Who changed what, when, and how did the row look before and
after?**

------------------------------------------------------------------------

# ✨ Key Features

-   Transaction-level audit events\
-   Column-level change tracking\
-   Old and new row snapshots (JSON)\
-   Change detection (skips no-op updates)\
-   Automatic trigger generation\
-   Config-driven enable / disable per table\
-   Context capture (user, module, IP, session)\
-   Partitioned audit storage for scalability\
-   Prebuilt audit query views

------------------------------------------------------------------------

# 🏗 Architecture Overview

The framework stores audit data in **two core tables**.

## UTIL_AUDIT_TXN --- Transaction Header

One row per audited DML event.

Contains:

-   Table name\
-   Primary key value\
-   Transaction type (INSERT / UPDATE / DELETE)\
-   Username\
-   Execution context (JSON)\
-   Old row snapshot (JSON)\
-   New row snapshot (JSON)\
-   Database transaction ID\
-   Timestamp

## UTIL_AUDIT_RECORDS --- Column Changes

One row per column change.

Contains:

-   Column name\
-   Old value\
-   New value\
-   Datatype\
-   Change hash\
-   Timestamp\
-   Transaction reference

This design supports both:

✔ High-level event auditing\
✔ Detailed column forensics

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

------------------------------------------------------------------------

# 🚀 Quickstart

## 1️⃣ Install

Run the setup script as a user with:

-   CREATE TABLE\
-   CREATE INDEX\
-   CREATE VIEW\
-   CREATE PROCEDURE\
-   CREATE TRIGGER

``` sql
@setup.sql
```

------------------------------------------------------------------------

## 2️⃣ Enable auditing for a table

``` sql
BEGIN
  util_audit_gen.create_audit_trigger('YOUR_TABLE');
END;
/
```

This will:

-   Create the audit trigger\
-   Detect primary key\
-   Identify supported columns\
-   Register the table in `UTIL_AUDIT_CONFIG`\
-   Start auditing immediately

------------------------------------------------------------------------

## 3️⃣ Verify auditing

``` sql
SELECT *
FROM v_util_audit_events
WHERE table_name = 'YOUR_TABLE'
ORDER BY audit_ts DESC;
```

------------------------------------------------------------------------

## 4️⃣ View column changes

``` sql
SELECT *
FROM v_util_audit_changes
WHERE table_name = 'YOUR_TABLE'
ORDER BY audit_ts DESC;
```

------------------------------------------------------------------------

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
2️⃣ Trigger builds a JSON payload\
3️⃣ `util_audit` package:\
- Inserts transaction header\
- Inserts column changes\
4️⃣ No audit rows are written if an UPDATE does not change data

------------------------------------------------------------------------

# 🧬 Supported Datatypes

Triggers safely support:

-   NUMBER\
-   FLOAT / BINARY_FLOAT / BINARY_DOUBLE\
-   VARCHAR2 / CHAR\
-   DATE\
-   TIMESTAMP\
-   CLOB

Unsupported datatypes are automatically skipped.

------------------------------------------------------------------------

# 📈 Performance Considerations

-   Auditing adds overhead per DML\
-   Only audit business-critical tables\
-   Avoid auditing staging or bulk-load tables\
-   Partitioned storage reduces long-term cost\
-   Purge historical data periodically

This framework is optimized for **traceability, not raw throughput**

------------------------------------------------------------------------

# 🧭 Use Cases

Ideal for:

-   Regulatory and compliance environments\
-   Financial transaction systems\
-   Workflow / approval tracking\
-   Data governance programs\
-   Investigative forensics

------------------------------------------------------------------------

# 🚫 When Not to Use

Avoid util_audit for:

-   ETL pipelines\
-   High-frequency logging tables\
-   Data warehouse fact tables\
-   Systems where write latency is critical

------------------------------------------------------------------------

# 🧠 Design Principles

-   Deterministic triggers\
-   No dynamic SQL at runtime\
-   JSON-based context for extensibility\
-   Separation of transaction and column data\
-   Minimal dependencies\
-   Version-agnostic PL/SQL

------------------------------------------------------------------------

# 📜 License

Free for all use, including commercial.
