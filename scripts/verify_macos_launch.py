#!/usr/bin/env python3
"""Launch the extracted app through LaunchServices and require a visible window.

Does not remove quarantine, modify system protections, or execute Windows code.
The app uses a fresh library beside the report only when this test flag is set.
"""
import json
from pathlib import Path
import subprocess
import sys

app, report = (Path(argument).resolve() for argument in sys.argv[1:])
if report.exists() or (report.parent / "smoke-library.json").exists():
    raise SystemExit("Startup checks require a fresh report/library directory.")
try:
    subprocess.run(["/usr/bin/open", "-n", "-W", str(app), "--args",
                    "--bridge-ui-smoke-test", str(report)], check=True, timeout=35)
except subprocess.TimeoutExpired:
    raise SystemExit("Bridge did not complete normal GUI startup within 35 seconds.")
if not report.is_file():
    raise SystemExit("Bridge exited without a GUI readiness report; startup failed.")
result = json.loads(report.read_text())
print(json.dumps(result, indent=2), flush=True)
if result.get("success") is not True or result.get("windowVisible") is not True:
    raise SystemExit("Bridge failed its normal window/library startup check.")
if result.get("runtimeExecuted") is not False:
    raise SystemExit("Startup verification must not execute external software.")
