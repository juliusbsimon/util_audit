#!/usr/bin/env python3
"""Regenerate the APEX app's Supporting Objects from setup.sql, help.sql and
uninstall.sql.

setup.sql stays the single source for the database objects and help.sql for
the in-app help articles. APEX limits each install script to 32767 bytes, so
setup.sql is split into one script per object group. Run this after every
change to setup.sql, help.sql or uninstall.sql:

    python3 tools/sync_supporting_objects.py
"""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "applications" / "util-audit" / "supporting-objects"
MAX_BYTES = 32767

# (script id, name, predicate on the statement's first code line)
GUARD_MARK = "-- util_audit v1 guard"

GROUPS = [
    ("tables", "Tables and indexes", lambda first: first.upper().startswith("DECLARE")),
    ("views", "Views", lambda first: " VIEW " in f" {first.upper()} "),
    ("util-audit-spec", "Package util_audit", lambda first: re.search(r"PACKAGE\s+util_audit\s", first, re.I)),
    ("util-audit-restore-spec", "Package util_audit_restore", lambda first: re.search(r"PACKAGE\s+util_audit_restore\s", first, re.I)),
    ("util-audit-restore-body", "Package body util_audit_restore", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit_restore\s", first, re.I)),
    ("util-audit-body", "Package body util_audit", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit\s", first, re.I)),
    ("util-audit-gen-spec", "Package util_audit_gen", lambda first: re.search(r"PACKAGE\s+util_audit_gen\s", first, re.I)),
    ("util-audit-gen-body", "Package body util_audit_gen", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit_gen\s", first, re.I)),
    ("util-audit-query-spec", "Package util_audit_query", lambda first: re.search(r"PACKAGE\s+util_audit_query\s", first, re.I)),
    ("util-audit-query-body", "Package body util_audit_query", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit_query\s", first, re.I)),
    ("util-audit-apx-spec", "Package util_audit_apx", lambda first: re.search(r"PACKAGE\s+util_audit_apx\s", first, re.I)),
    ("util-audit-apx-body", "Package body util_audit_apx", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit_apx\s", first, re.I)),
    ("util-audit-archive-spec", "Package util_audit_archive", lambda first: re.search(r"PACKAGE\s+util_audit_archive\s", first, re.I)),
    ("util-audit-archive-body", "Package body util_audit_archive", lambda first: re.search(r"PACKAGE\s+BODY\s+util_audit_archive\s", first, re.I)),
]
CHECK_MARK = "-- util_audit install check"


def statements(sql):
    """Split on SQL*Plus '/' terminator lines; keep the terminator."""
    for part in re.split(r"(?m)^/\s*$\n?", sql):
        if part.strip():
            yield part.rstrip("\n") + "\n/\n"


def first_code_line(stmt):
    for line in stmt.splitlines():
        if line.strip() and not line.strip().startswith("--"):
            return line.strip()
    return ""


def block(text, indent):
    pad = " " * indent
    return "\n".join(pad + line if line.strip() else "" for line in text.rstrip("\n").split("\n"))


def script_component(kind, sid, name, seq, content):
    # name is not accepted by the live validator for install/upgrade scripts;
    # the component id carries it instead
    return f"""
    {kind} {sid} (
        execution {{
            sequence: {seq}
        }}
        script {{
            content:
                ```
{block(content, 16)}
                ```
        }}
    )
"""


def main():
    grouped = {sid: [] for sid, _, _ in GROUPS}
    guard = ""
    check = ""
    for stmt in statements((ROOT / "setup.sql").read_text()):
        if GUARD_MARK in stmt:
            # Every script starts with the v1 guard: APEX may run later scripts
            # after an earlier one fails, and none may touch a v1 schema
            guard = stmt[stmt.index(GUARD_MARK):]
            continue
        if CHECK_MARK in stmt:
            # Runs after the last package, so it goes at the end of that script
            check = stmt
            continue
        first = first_code_line(stmt)
        for sid, _, match in GROUPS:
            if match(first):
                grouped[sid].append(stmt)
                break
        else:
            raise SystemExit(f"setup.sql statement not assigned to a group: {first[:60]}")

    if not guard:
        raise SystemExit("setup.sql has no '-- util_audit v1 guard' block.")
    grouped[GROUPS[-1][0]].append(check)

    parts = []
    for kind, prefix in (("installScript", "install"), ("upgradeScript", "upgrade")):
        for i, (sid, name, _) in enumerate(GROUPS, start=1):
            content = f"-- {name} (generated from setup.sql by tools/sync_supporting_objects.py)\n" + guard + "".join(grouped[sid])
            if "```" in content:
                raise SystemExit(f"{sid} contains three backticks, which would end the fenced script block early.")
            size = len(content.encode())
            if size > MAX_BYTES:
                raise SystemExit(f"{sid} is {size} bytes; APEX allows {MAX_BYTES} per script. Split it further.")
            parts.append(script_component(kind, f"{prefix}-{sid}", name, i * 10, content))
        # The help articles are app data, so they come from their own file
        help_sql = "-- Help articles (generated from help.sql by tools/sync_supporting_objects.py)\n" + \
            guard + (ROOT / "help.sql").read_text()
        if len(help_sql.encode()) > MAX_BYTES:
            raise SystemExit(f"help.sql is {len(help_sql.encode())} bytes; APEX allows {MAX_BYTES} per script.")
        parts.append(script_component(kind, f"{prefix}-help", "Help articles", (len(GROUPS) + 1) * 10, help_sql))

    apx = """supportingObject (
    installationMessages {
        welcome: Installs the util_audit framework (tables, views and packages) into the application's parsing schema.
        installSuccess: util_audit is installed. Open the app and go to Tables to start auditing.
    }
    upgrade {
        upgradeWhenSqlQuery:
            ```sql
            select 1 from user_objects where object_name = 'UTIL_AUDIT' and object_type = 'PACKAGE'
            ```
    }
    upgradeMessages {
        success: util_audit is upgraded. Go to Maintenance and re-create all triggers so existing tables use the new trigger code.
    }
    deinstall {
        scriptFile: deinstall-script.sql
    }
    deinstallationMessages {
        confirmation: This drops the audit triggers, packages, views and tables, including all audit history.
    }
    advanced {
        includeInAppExport: true
    }
""" + "".join(parts) + ")\n"

    (APP / "supporting-objects.apx").write_text(apx)
    shutil.copyfile(ROOT / "uninstall.sql", APP / "deinstall-script.sql")
    print(f"Wrote {APP / 'supporting-objects.apx'} ({len(GROUPS) + 1} install + {len(GROUPS) + 1} upgrade scripts)")


if __name__ == "__main__":
    main()
