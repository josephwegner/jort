#!/usr/bin/env python3
"""Run canonical Jort validation with concise output and complete local logs."""
from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from typing import Iterator, Sequence

ROOT = Path(__file__).resolve().parent.parent
LOG_ROOT = ROOT / ".build-validation"
LOCK_PATH = LOG_ROOT / "xcode.lock"
TSAN_SKIP = "JortToolRuntimeTests/ToolPackageTests/testBundledCalculatorRejectsDeepUnaryExpression"


@dataclass(frozen=True)
class Check:
    name: str
    commands: tuple[tuple[str, ...], ...]
    xcode: bool = False


def make_check(name: str, *commands: Sequence[str], xcode: bool = False) -> Check:
    return Check(name, tuple(tuple(command) for command in commands), xcode)


CHECKS = {item.name: item for item in (
    make_check("toolchain", ["xcodebuild", "-version"], ["xcrun", "swift", "--version"]),
    make_check("format", ["python3", "scripts/format.py", "--check"]),
    make_check("project", ["python3", "scripts/check-project.py"]),
    make_check("foundation", ["./scripts/test-foundation.sh"], xcode=True),
    make_check("native", ["./scripts/test-native.sh"], xcode=True),
    make_check("localization", ["python3", "scripts/check-localization.py"]),
    make_check("presentation", ["bash", "scripts/test-presentation.sh"], xcode=True),
    make_check("packaging-tests", ["python3", "scripts/test-packaging.py"]),
    make_check("ui", ["./scripts/test-ui.sh"], xcode=True),
    make_check("containment-binary-ui", ["python3", "scripts/verify-javascript-containment.py", ".build-ui-tests/Build/Products/Debug/Jort.app"]),
    make_check("containment-binary-release", ["python3", "scripts/verify-javascript-containment.py", "dist/Jort.app"]),
    make_check("first-party-analysis", ["python3", "scripts/analyze.py", "first-party"], xcode=True),
    make_check("quickjs-audit", ["python3", "scripts/analyze.py", "quickjs", "--reuse"]),
    make_check("tsan-foundation", ["xcodebuild", "-project", "Jort.xcodeproj", "-scheme", "JortFoundation", "-configuration", "Debug", "-derivedDataPath", ".build-tsan", "-destination", "platform=macOS", "-enableThreadSanitizer", "YES", f"-skip-testing:{TSAN_SKIP}", "test"], xcode=True),
    make_check("tsan-native", ["xcodebuild", "-project", "Jort.xcodeproj", "-scheme", "JortNativeTests", "-configuration", "Debug", "-derivedDataPath", ".build-native-tsan", "-destination", "platform=macOS", "-enableThreadSanitizer", "YES", "test"], xcode=True),
    make_check("release", ["./scripts/build.sh"], xcode=True),
)}

LANES = {
    "fast": ["format", "project"],
    "test": ["foundation", "native", "packaging-tests"],
    "presentation": ["localization", "presentation"],
    "analysis": ["first-party-analysis"],
    "quickjs": ["quickjs-audit"],
    "tsan": ["tsan-foundation", "tsan-native"],
    "ui": ["ui", "containment-binary-ui"],
    "package": ["release", "packaging-tests", "containment-binary-release"],
    "ci-test": ["format", "project", "foundation", "native", "packaging-tests", "ui", "containment-binary-ui", "tsan-foundation", "tsan-native", "release", "packaging-tests", "containment-binary-release"],
    "all": ["format", "project", "foundation", "native", "packaging-tests", "first-party-analysis", "quickjs-audit", "ui", "containment-binary-ui", "tsan-foundation", "tsan-native", "release", "packaging-tests", "containment-binary-release"],
    "gate": ["format", "project", "foundation", "native", "packaging-tests", "first-party-analysis", "quickjs-audit", "ui", "containment-binary-ui"],
}

DIAGNOSTIC = re.compile(r"(?:^|\s)(?:error:|fatal error:|warning: ThreadSanitizer:|SUMMARY: ThreadSanitizer:|Test Case .* failed|\*\* (?:BUILD|TEST) FAILED \*\*|Formatting differs:|Generated configuration drift:|QuickJS diagnostic set changed|Assertion failed)")
FOUNDATION_FILTERS = {
    "document": ("JortFoundationTests/DocumentTests", "JortFoundationTests/IncrementalLineEditingTests", "JortFoundationTests/PersistentLineIndexTests"),
    "persistence": ("JortFoundationTests/StorageTests", "JortFoundationTests/RecoveryControlsTests", "JortFoundationTests/StartupPersistenceTests", "JortFoundationTests/MigrationTests", "JortFoundationTests/ToolPersistenceTests"),
}


def diagnostic_excerpt(log: Path, limit: int = 20) -> list[str]:
    lines = log.read_text(errors="replace").splitlines()
    matches = [line.strip() for line in lines if DIAGNOSTIC.search(line)]
    return (matches if matches else [line for line in lines if line.strip()])[-limit:]


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def safe_log_root(path: Path) -> Path:
    resolved = (path if path.is_absolute() else ROOT / path).resolve()
    root = LOG_ROOT.resolve()
    if resolved != root and root not in resolved.parents:
        raise ValueError(f"log root must remain inside {display_path(LOG_ROOT)}")
    return resolved


@contextmanager
def xcode_lock(timeout: float = 180.0) -> Iterator[None]:
    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+") as stream:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out waiting for {display_path(LOCK_PATH)}")
                time.sleep(0.2)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def focused_check(suite: str, configuration: str, filters: Sequence[str], performance: bool) -> Check:
    scheme = {"foundation": "JortFoundation", "native": "JortNativeTests", "containment": "JortJavaScriptContainment", "ui": "Jort"}[suite]
    derived = f".build-focused-{suite}-{configuration.lower()}"
    command = ["env", f"JORT_PERFORMANCE_ENFORCE={int(performance)}", "xcodebuild", "-project", "Jort.xcodeproj", "-scheme", scheme, "-configuration", configuration, "-derivedDataPath", derived, "-destination", "platform=macOS", "ENABLE_TESTABILITY=YES"]
    command.extend(f"-only-testing:{value}" for value in filters)
    command.append("test")
    return make_check(f"focused-{suite}-{configuration.lower()}", command, xcode=True)


def changed_plan(paths: Sequence[str]) -> list[Check]:
    paths = sorted({path.removeprefix("./") for path in paths if path})
    names: list[str] = []
    focused: list[Check] = []
    def add(name: str) -> None:
        if name not in names:
            names.append(name)
    for path in paths:
        if path.endswith(".swift") or path == "project.yml" or path.startswith("scripts/"):
            add("format")
        if path == "project.yml" or path.endswith(".xcodeproj/project.pbxproj"):
            add("project"); add("foundation"); add("native")
        elif path.startswith(("Sources/JortDocument/", "Tests/Foundation/Document", "Tests/Foundation/IncrementalLineEditing", "Tests/Foundation/PersistentLineIndex")):
            item = focused_check("foundation", "Debug", FOUNDATION_FILTERS["document"], False)
            if item not in focused: focused.append(item)
        elif path.startswith(("Sources/JortPersistence/", "Tests/Foundation/Recovery", "Tests/Foundation/Storage", "Tests/Foundation/Migration", "Tests/Foundation/StartupPersistence", "Tests/Foundation/ToolPersistence")):
            item = focused_check("foundation", "Debug", FOUNDATION_FILTERS["persistence"], False)
            if item not in focused: focused.append(item)
        elif path.startswith("Tests/UI/"):
            add("ui")
        elif path.startswith(("Sources/JortAppKit/", "Tests/AppKit/", "Jort/")):
            add("native")
        elif path.startswith(("Sources/", "Tests/", "Tools/")):
            add("foundation"); add("native")
        elif path.startswith("Vendor/QuickJS/"):
            add("quickjs-audit")
        elif path.startswith("scripts/"):
            add("packaging-tests")
    return [CHECKS[name] for name in CHECKS if name in names] + focused


def git_changed_paths(base: str | None) -> list[str]:
    commands = [["git", "diff", "--name-only", f"{base}...HEAD"]] if base else [["git", "diff", "--name-only"], ["git", "diff", "--cached", "--name-only"], ["git", "ls-files", "--others", "--exclude-standard"]]
    paths: set[str] = set()
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
        paths.update(result.stdout.splitlines())
    return sorted(path for path in paths if path)


def run_check(item: Check, run_dir: Path, env: dict[str, str]) -> dict:
    log = run_dir / f"{item.name}.log"
    started = time.monotonic()
    returncode = 0
    try:
        with (xcode_lock() if item.xcode else nullcontext()), log.open("w") as stream:
            for command in item.commands:
                stream.write("$ " + shlex.join(command) + "\n"); stream.flush()
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
                if result.returncode:
                    returncode = result.returncode; break
    except TimeoutError as error:
        log.write_text(str(error) + "\n"); returncode = 75
    elapsed = time.monotonic() - started
    status = "PASS" if returncode == 0 else "FAIL"
    print(f"{status:<4} {item.name:<31} {elapsed:7.1f}s  {display_path(log)}", flush=True)
    if returncode:
        for line in diagnostic_excerpt(log): print(f"     {line}", file=sys.stderr)
    return {"name": item.name, "status": status.lower(), "returncode": returncode, "duration_seconds": round(elapsed, 3), "log": display_path(log), "commands": [shlex.join(command) for command in item.commands]}


def execute(label: str, checks: Sequence[Check], keep_going: bool, log_root: Path) -> int:
    run_dir = log_root / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}")
    run_dir.mkdir(parents=True)
    env = dict(os.environ); env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    summary = {"lane": label, "started_at": datetime.now(timezone.utc).isoformat(), "developer_dir": env["DEVELOPER_DIR"], "run_directory": display_path(run_dir), "checks": []}
    print(f"Validation: {label}  logs: {summary['run_directory']}", flush=True)
    for item in checks:
        result = run_check(item, run_dir, env); summary["checks"].append(result)
        if result["returncode"] and not keep_going: break
    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    summary["status"] = "failed" if any(item["returncode"] for item in summary["checks"]) else "passed"
    summary_path = run_dir / "summary.json"; summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{summary['status'].upper()}: {display_path(summary_path)}", flush=True)
    return int(summary["status"] == "failed")


def show_result(path: Path | None, check_name: str | None, lines: int, log_root: Path) -> int:
    if path is None:
        summaries = sorted(log_root.glob("*/summary.json"), key=lambda item: item.stat().st_mtime)
        if not summaries: raise FileNotFoundError(f"no validation results under {display_path(log_root)}")
        path = summaries[-1]
    if path.is_dir(): path /= "summary.json"
    data = json.loads(path.read_text())
    print(f"{data['status'].upper()} {data['lane']}  {display_path(path.parent)}")
    for item in data["checks"]: print(f"{item['status'].upper():<4} {item['name']:<31} {item['duration_seconds']:7.1f}s  {item['log']}")
    if check_name:
        selected = next((item for item in data["checks"] if item["name"] == check_name), None)
        if selected is None: raise ValueError(f"check not found: {check_name}")
        print(f"\nLast {lines} lines from {selected['log']}:")
        print("\n".join((ROOT / selected["log"]).read_text(errors="replace").splitlines()[-lines:]))
    return 0


def build_parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__); sub = root.add_subparsers(dest="command")
    for lane in LANES:
        item = sub.add_parser(lane); item.add_argument("--keep-going", action="store_true"); item.add_argument("--log-root", type=Path, default=LOG_ROOT)
    focused = sub.add_parser("focused"); focused.add_argument("suite", choices=("foundation", "native", "containment", "ui")); focused.add_argument("--configuration", choices=("Debug", "Release"), default="Debug"); focused.add_argument("--only", action="append", default=[]); focused.add_argument("--performance", action="store_true"); focused.add_argument("--keep-going", action="store_true"); focused.add_argument("--log-root", type=Path, default=LOG_ROOT)
    changed = sub.add_parser("changed"); changed.add_argument("--base"); changed.add_argument("--path", action="append", default=[]); changed.add_argument("--plan-only", action="store_true"); changed.add_argument("--keep-going", action="store_true"); changed.add_argument("--log-root", type=Path, default=LOG_ROOT)
    result = sub.add_parser("result"); result.add_argument("--run", type=Path); result.add_argument("--check"); result.add_argument("--lines", type=int, default=40); result.add_argument("--log-root", type=Path, default=LOG_ROOT)
    sub.add_parser("self-test")
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv); command = args.command or "fast"
    if args.command is None:
        return execute("fast", [CHECKS[name] for name in LANES["fast"]], False, LOG_ROOT)
    if command == "self-test": return subprocess.run(["python3", "-m", "unittest", "scripts.test_validate"], cwd=ROOT).returncode
    try:
        log_root = safe_log_root(args.log_root)
        if command in LANES: return execute(command, [CHECKS[name] for name in LANES[command]], args.keep_going, log_root)
        if command == "focused":
            item = focused_check(args.suite, args.configuration, args.only, args.performance); return execute(item.name, [item], args.keep_going, log_root)
        if command == "changed":
            paths = args.path or git_changed_paths(args.base); checks = changed_plan(paths)
            print("Changed paths:"); [print(f"  {path}") for path in sorted(paths)]
            print("Planned checks: " + (", ".join(item.name for item in checks) or "none"))
            return 0 if args.plan_only or not checks else execute("changed", checks, args.keep_going, log_root)
        if command == "result":
            if not 1 <= args.lines <= 80: raise ValueError("--lines must be between 1 and 80")
            run = args.run if not args.run or args.run.is_absolute() else ROOT / args.run
            return show_result(run, args.check, args.lines, log_root)
    except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"validate: {error}", file=sys.stderr); return 2
    raise AssertionError(command)


if __name__ == "__main__": sys.exit(main())
