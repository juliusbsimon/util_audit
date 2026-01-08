# util_audit

**Oracle Column-Level Audit Utility**

`util_audit` is a lightweight, trigger-based **column-level auditing framework for Oracle databases**.  
It captures **per-column changes** (old value → new value) for INSERT, UPDATE, and DELETE operations, with minimal setup and no dependency on Oracle Unified Auditing.

This utility is intended for **compliance, traceability, and forensic analysis** in transactional systems where knowing *exactly what changed* is critical.

---

## Key Features

- Column-level auditing (not just row-level)
- Tracks INSERT, UPDATE, and DELETE
- Logs old value and new value per column
- Captures user, timestamp, table, and primary key
- Trigger-based, fully transparent
- Supports automatic trigger generation
- No APEX, ORDS, or database-version lock-in

---

## Repository Contents

### setup.sql

The installation script creates:

- An audit table: UTIL_AUDIT_RECORDS
- Supporting indexes for audit lookups
- An audit package: UTIL_AUDIT
- Datatype-safe comparison and logging utilities
- Helper procedures for generating audit triggers

There are no runtime dependencies beyond standard Oracle SQL and PL/SQL.

---

## Audit Table

All audited changes are stored in:

    UTIL_AUDIT_RECORDS

Each audit record contains:

- TABLE_NAME – table being audited  
- PK_VALUE – primary key value of the affected row  
- COLUMN_NAME – column that changed  
- DATA_TYPE – column datatype  
- TRANSACTION_TYPE – INSERT / UPDATE / DELETE  
- USERNAME – database user  
- OLD_VALUE – value before the change  
- NEW_VALUE – value after the change  
- AUDIT_DATE – timestamp of the change  
- TRANSACTION_ID – optional transaction grouping  

Each column change generates **one audit row**.

---

## Supported Datatypes

The audit package explicitly supports:

- NUMBER
- FLOAT
- BINARY_FLOAT
- BINARY_DOUBLE
- VARCHAR2
- CHAR
- DATE
- TIMESTAMP
- TIMESTAMP WITH TIME ZONE

Datatype handling is performed safely inside the UTIL_AUDIT package.

---

## Trigger Naming Convention (Required)

Audit triggers follow this naming pattern:

    BUID_<TABLE_NAME>_AUD

Example:

    BUID_DEMO_AUD

This convention allows the package to manage audit triggers consistently.

---

## Automatic Trigger Generation (Recommended)

Instead of writing audit triggers manually, you can **auto-generate** a column-level audit trigger for an entire table using the built-in helper procedure.

### Example: Generate an audit trigger for a table

    BEGIN
        util_audit.add_table_audit_trig(
            p_table_name => 'DEMO',
            p_action     => 'EXECUTE'
        );
    END;
    /

What this does:

- Inspects the table structure
- Identifies supported columns
- Generates a BEFORE INSERT / UPDATE / DELETE trigger
- Registers column-level audit logic automatically

This is the **preferred approach** for onboarding new tables.

---

## How Auditing Works

1. An audit trigger is created (manually or automatically)
2. The trigger calls UTIL_AUDIT logic per column
3. The package:
   - Compares old vs new values
   - Detects real changes
   - Inserts audit rows only when values differ

No audit row is written if a column value did not change.

---

## Querying Audit Data

View column change history:

    SELECT *
    FROM util_audit_records
    WHERE table_name = 'DEMO'
    ORDER BY audit_date DESC;

View changes by user:

    SELECT *
    FROM util_audit_records
    WHERE username = USER
    ORDER BY audit_date DESC;

---

## Installation

Run as a user with:

- CREATE TABLE
- CREATE INDEX
- CREATE PROCEDURE
- CREATE TRIGGER

    @setup.sql

No additional configuration required.

---

## Performance Considerations

- Column-level auditing introduces overhead
- Audit only business-critical tables and columns
- Avoid blanket auditing on high-volume tables
- Index UTIL_AUDIT_RECORDS appropriately
- Purge or archive old audit data periodically

This utility prioritizes **accuracy over volume**.

---

## When to Use This

Use util_audit when:

- Compliance or regulatory tracking is required
- You need who-changed-what visibility
- Oracle Unified Auditing is unavailable or too coarse
- You want fast, repeatable audit onboarding

---

## When Not to Use This

Avoid using this utility for:

- High-frequency ETL or bulk loads
- Auditing every column indiscriminately
- Systems where audit overhead is unacceptable

---

## License
Free for all uses
