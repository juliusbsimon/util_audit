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
- No APEX, ORDS, or database-version lock-in

---

## Repository Contents

### setup.sql

The installation script creates:

- An audit table: UTIL_AUDIT_RECORDS
- Supporting indexes for audit lookups
- An audit package: UTIL_AUDIT
- Datatype-safe comparison and logging utilities

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

Audit triggers must follow this naming pattern:

    BUID_<TABLE_NAME>_AUD

Example:

    BUID_EMPLOYEES_AUD

This convention allows the package to recognize and manage audit triggers consistently.

---

## How Auditing Works

1. A BEFORE INSERT OR UPDATE OR DELETE trigger is created
2. The trigger calls UTIL_AUDIT.CHECK_VAL(...) per column
3. The package:
   - Compares old vs new values
   - Detects real changes
   - Inserts audit rows only when values differ

No audit row is written if a column value did not change.

---

## Example Trigger

    CREATE OR REPLACE TRIGGER buid_employees_aud
    BEFORE INSERT OR UPDATE OR DELETE ON employees
    FOR EACH ROW
    BEGIN
        util_audit.check_val(
            p_table_name  => 'EMPLOYEES',
            p_pk_value    => :NEW.employee_id,
            p_column_name => 'SALARY',
            p_old_value   => :OLD.salary,
            p_new_value   => :NEW.salary,
            p_data_type   => 'NUMBER'
        );
    END;
    /

Repeat CHECK_VAL calls only for columns you want audited.

---

## Querying Audit Data

View column change history:

    SELECT *
    FROM util_audit_records
    WHERE table_name = 'EMPLOYEES'
      AND column_name = 'SALARY'
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
- Audit only business-critical columns
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
- Full control over audit logic is required

---

## When Not to Use This

Avoid using this utility for:

- High-frequency ETL or bulk loads
- Auditing every column indiscriminately
- Systems where audit overhead is unacceptable

---

## License

No license specified.  
Add one if public or commercial reuse is intended.
