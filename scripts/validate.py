#!/usr/bin/env python3
"""Run canonical Jort validation lanes with concise output and complete logs."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
LOG_ROOT = ROOT / ".build-validation"
TSAN_SKIP = (
    "JortToolRuntimeTests/ToolPackageTests/"
    "testBundledCalculatorRejectsDeepUnaryExpression"
)

CHECKS = {
    "toolchain": [["xcodebuild", "-version"], ["xcrun", "swift", "--version"]],
    "format": [["python3", "scripts/format.py", "--check"]],
    "project": [["python3", "scripts/check-project.py"]],
    "foundation": [["./scripts/test-foundation.sh"]],
    "native": [["./scripts/test-native.sh"]],
    "localization": [["python3", "scripts/check-localization.py"]],
    "presentation": [["bash", "scripts/test-presentation.sh"]],
    "packaging-tests": [["python3", "scripts/test-packaging.py"]],
    "ui": [["./scripts/test-ui.sh"]],
    "first-party-analysis": [["python3", "scripts/analyze.py", "first-party"]],
    "quickjs-audit": [["python3", "scripts/analyze.py", "quickjs", "--reuse"]],
    "tsan-foundation": [
        [
            "xcodebuild",
            "-project",
            "Jort.xcodeproj",
            "-scheme",
            "JortFoundation",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            ".build-tsan",
            "-destination",
            "platform=macOS",
            "-enableThreadSanitizer",
            "YES",
            f"-skip-testing:{TSAN_SKIP}",
            "test",
        ]
    ],
    "tsan-native": [
        [
            "xcodebuild",
            "-project",
            "Jort.xcodeproj",
            "-scheme",
            "JortNativeTests",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            ".build-native-tsan",
            "-destination",
            "platform=macOS",
            "-enableThreadSanitizer",
            "YES",
            "test",
        ]
    ],
    "release": [["./scripts/build.sh"]],
}

LANES = {
    "fast": ["format", "project"],
    "test": ["foundation", "native", "packaging-tests"],
    "presentation": ["localization", "presentation"],
    "analysis": ["first-party-analysis"],
    "quickjs": ["quickjs-audit"],
    "tsan": ["tsan-foundation", "tsan-native"],
    "ui": ["ui"],
    "package": ["release", "packaging-tests"],
    "ci-test": [
        "format",
        "project",
        "foundation",
        "native",
        "packaging-tests",
        "ui",
        "tsan-foundation",
        "tsan-native",
        "release",
        "packaging-tests",
    ],
    "all": [
        "format",
        "project",
        "foundation",
        "native",
        "packaging-tests",
        "first-party-analysis",
        "quickjs-audit",
        "ui",
        "tsan-foundation",
        "tsan-native",
        "release",
        "packaging-tests",
    ],
}

DIAGNOSTIC = re.compile(
    r"(?:^|\s)(?:error:|fatal error:|warning: ThreadSanitizer:|SUMMARY: ThreadSanitizer:|"
    r"Test Case .* failed|\*\* (?:BUILD|TEST) FAILED \*\*|Formatting differs:|"
    r"Generated configuration drift:|QuickJS diagnostic set changed)"
)


def diagnostic_excerpt(log: Path, limit: int = 20) -> list[str]:
    lines = log.read_text(errors="replace").splitlines()
    matches = [line.strip() for line in lines if DIAGNOSTIC.search(line)]
    if matches:
        return matches[-limit:]
    return [line for line in lines[-limit:] if line.strip()]


def display_path(path: Path) -> str:
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def run_check(name: str, run_dir: Path, env: dict[str, str]) -> dict:
    log = run_dir / f"{name}.log"
    started = time.monotonic()
    commands = CHECKS[name]
    returncode = 0
    with log.open("w") as stream:
        for command in commands:
            stream.write("$ " + shlex.join(command) + "\n")
            stream.flush()
            result = subprocess.run(
                command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT
            )
            if result.returncode:
                returncode = result.returncode
                break
    elapsed = time.monotonic() - started
    status = "PASS" if returncode == 0 else "FAIL"
    print(f"{status:<4} {name:<22} {elapsed:7.1f}s  {display_path(log)}", flush=True)
    if returncode:
        for line in diagnostic_excerpt(log):
            print(f"     {line}", file=sys.stderr)
    return {
        "name": name,
        "status": status.lower(),
        "returncode": returncode,
        "duration_seconds": round(elapsed, 3),
        "log": display_path(log),
        "commands": [shlex.join(command) for command in commands],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=sorted(LANES), nargs="?", default="fast")
    parser.add_argument("--keep-going", action="store_true")
    parser.add_argument("--log-root", type=Path, default=LOG_ROOT)
    args = parser.parse_args()

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    log_root = args.log_root if args.log_root.is_absolute() else ROOT / args.log_root
    run_dir = log_root / run_id
    run_dir.mkdir(parents=True)
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

    summary = {
        "lane": args.lane,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "developer_dir": env["DEVELOPER_DIR"],
        "run_directory": display_path(run_dir),
        "checks": [],
    }
    print(f"Validation lane: {args.lane}  logs: {summary['run_directory']}", flush=True)
    for name in LANES[args.lane]:
        result = run_check(name, run_dir, env)
        summary["checks"].append(result)
        if result["returncode"] and not args.keep_going:
            break
    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    summary["status"] = (
        "failed"
        if any(check["returncode"] for check in summary["checks"])
        else "passed"
    )
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{summary['status'].upper()}: {run_dir / 'summary.json'}", flush=True)
    return 1 if summary["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
