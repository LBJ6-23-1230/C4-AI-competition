# -*- coding: utf-8 -*-
"""Minimal pytest reporting plugin: dumps per-test outcomes to JSON.

Used because this sandbox blocks pytest's own tmp_path/basetemp cleanup,
which aborts the session before the standard summary is trustworthy.
"""
import json
import os

_RECORDS = {}
_OUT = os.environ.get("DSH_PYTEST_REPORT", "dsh_pytest_report.json")


def pytest_runtest_logreport(report):
    key = report.nodeid
    rec = _RECORDS.setdefault(key, {"nodeid": key, "outcome": "passed", "longrepr": ""})
    if report.failed:
        rec["outcome"] = "error" if report.when in ("setup", "teardown") else "failed"
        rec["longrepr"] = str(report.longrepr)[-2000:]
    elif report.skipped:
        rec["outcome"] = "skipped"
        rec["longrepr"] = str(report.longrepr)[-500:]


def pytest_sessionfinish(session, exitstatus):
    records = list(_RECORDS.values())
    summary = {
        "total": len(records),
        "passed": sum(1 for r in records if r["outcome"] == "passed"),
        "failed": sum(1 for r in records if r["outcome"] == "failed"),
        "error": sum(1 for r in records if r["outcome"] == "error"),
        "skipped": sum(1 for r in records if r["outcome"] == "skipped"),
    }
    with open(_OUT, "w", encoding="utf-8") as stream:
        json.dump({"summary": summary, "records": records}, stream, ensure_ascii=False, indent=2)
    print("\nDSH_SUMMARY " + json.dumps(summary, ensure_ascii=False))
