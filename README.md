util_audit

Oracle Transaction & Column-Level Audit Framework

util_audit is a trigger-based auditing framework for Oracle that
captures: - Transaction events - Column-level changes - Row snapshots -
Execution context

It provides forensic-grade auditability without requiring Oracle Unified
Auditing or Flashback Data Archive.

This framework is designed for systems where you need to answer: Who
changed what, when, and how did the row look before and after?

------------------------------------------------------------------------

KEY FEATURES

-   Transaction-level audit events
-   Column-level change tracking
-   Old and new row snapshots (JSON)
-   Change detection (skips no-op updates)
-   Automatic trigger generation
-   Config-driven enable / disable per table
-   Context capture (user, module, IP, session)
-   Partitioned audit storage for scalability
-   Prebuilt audit query views

------------------------------------------------------------------------

QUICKSTART

1)  Install

@setup.sql

2)  Enable auditing for a table

BEGIN util_audit_gen.create_audit_trigger(‘YOUR_TABLE’); END; /

3)  Verify auditing

SELECT * FROM v_util_audit_events WHERE table_name = ‘YOUR_TABLE’ ORDER
BY audit_ts DESC;

------------------------------------------------------------------------

LICENSE

Free for all use, including commercial.
