#!/usr/bin/env python3
"""Verify the shipped JavaScript-containment code inside a built Jort.app.

This intentionally inspects the produced bundle rather than project settings: an
embedding or signing regression can satisfy the source-level checks while
shipping a different process graph.
"""
from __future__ import annotations

import argparse
import os
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_APP = ROOT / "dist/Jort.app"
APP_EXECUTABLE = "Contents/MacOS/Jort"
BROKER_BUNDLE = "Contents/XPCServices/JortJavaScriptBroker.xpc"
BROKER_EXECUTABLE = BROKER_BUNDLE + "/Contents/MacOS/JortJavaScriptBroker"
WORKER_EXECUTABLE = BROKER_BUNDLE + "/Contents/Helpers/JortJavaScriptWorker"
CLIENT_FRAMEWORK = "Contents/Frameworks/JortJavaScriptClient.framework/JortJavaScriptClient"
EXPECTED_IDENTIFIERS = {
    APP_EXECUTABLE: "dev.jort.editor",
    BROKER_EXECUTABLE: "dev.jort.editor.javascript-broker",
    WORKER_EXECUTABLE: "dev.jort.editor.javascript-worker",
    CLIENT_FRAMEWORK: "dev.jort.javascript.client",
}
EXPECTED_ENTITLEMENTS = {
    BROKER_EXECUTABLE: {"com.apple.security.app-sandbox": True},
    WORKER_EXECUTABLE: {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.inherit": True,
    },
}
QUICKJS_SYMBOL = re.compile(r"\b_JS_(?:NewRuntime|Eval)\b")


def command(*args: str, input: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def details(path: Path) -> tuple[dict[str, str], str]:
    result = command("/usr/bin/codesign", "-dvvv", str(path))
    text = result.stderr.decode("utf-8", "replace")
    values = dict(re.findall(r"^(Identifier|TeamIdentifier|Authority)=(.*)$", text, re.M))
    # codesign prints flags on the CodeDirectory line, not at column zero.
    flags = re.search(r"\bflags=0x[0-9a-fA-F]+\(([^)]*)\)", text)
    if flags:
        values["flags"] = flags.group(1)
    return values, text


def entitlements(path: Path) -> dict:
    result = command("/usr/bin/codesign", "-d", "--entitlements", ":-", str(path))
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip())
    try:
        return plistlib.loads(result.stdout)
    except plistlib.InvalidFileException as error:
        raise ValueError("codesign emitted an invalid entitlements plist") from error


def is_macho(path: Path) -> bool:
    result = command("/usr/bin/file", "-b", str(path))
    return result.returncode == 0 and b"Mach-O" in result.stdout


def macho_files(app: Path) -> list[Path]:
    # Framework executable symlinks and their Versions/A target describe the
    # same image. Inspect the target once and canonicalize its path below.
    return [path for path in app.rglob("*") if path.is_file() and not path.is_symlink() and is_macho(path)]


def canonical_relative(app: Path, path: Path) -> str:
    relative = path.relative_to(app)
    parts = relative.parts
    for index, part in enumerate(parts):
        if part.endswith(".framework") and parts[index + 1:index + 2] == ("Versions",):
            return str(Path(*parts[:index + 1]) / parts[-1])
    return str(relative)


def quickjs_owners(app: Path, files: list[Path]) -> set[str]:
    owners: set[str] = set()
    for path in files:
        # Exercise both the linked-image and symbol views. The latter catches
        # QuickJS statically linked into an otherwise ordinary executable.
        linked = command("/usr/bin/otool", "-L", str(path))
        symbols = command("/usr/bin/nm", "-gU", str(path))
        # Release/LTO may remove public symbols, so use a vendored QuickJS
        # diagnostic marker as positive evidence of the statically linked engine.
        literal = command("/usr/bin/strings", "-a", str(path))
        evidence = linked.stdout + linked.stderr + symbols.stdout + symbols.stderr + literal.stdout
        if b"quickjs" in evidence.lower() or QUICKJS_SYMBOL.search(evidence.decode("utf-8", "replace")):
            owners.add(canonical_relative(app, path))
    return owners


def mapped(path: Path, report: str) -> bool:
    # vmmap lists image paths on region rows. Check the normal and symlink
    # target forms because framework and app bundle paths can be canonicalized.
    candidates = {str(path), str(path.resolve())}
    return any(candidate in report for candidate in candidates)


def vmmap(pid: int) -> str:
    result = subprocess.run(
        ["/usr/bin/vmmap", "-wide", str(pid)], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, timeout=5,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"vmmap exited {result.returncode}")
    if not re.search(rf"^Process:.*\[{pid}\]$", result.stdout, re.M):
        raise ValueError(f"vmmap did not identify target PID {pid}")
    return result.stdout


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass


def runtime_mapping_errors(app: Path, owners: set[str]) -> list[str]:
    """Launch the app and prove its live address space maps no engine owner."""
    executable = app / APP_EXECUTABLE
    app_process: subprocess.Popen[bytes] | None = None
    data_root: tempfile.TemporaryDirectory[str] | None = None
    errors: list[str] = []
    try:
        data_root = tempfile.TemporaryDirectory(prefix="jort-containment-map-")
        environment = dict(os.environ)
        environment["JORT_DATA_DIRECTORY"] = data_root.name
        app_process = subprocess.Popen(
            [str(executable)], cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            env=environment,
        )
        # Give the normal GUI entry point a bounded opportunity to initialize.
        time.sleep(0.5)
        if app_process.poll() is not None:
            return [f"runtime mapping probe: app exited during launch ({app_process.returncode})"]

        if app_process.poll() is not None:
            raise ValueError("app exited before vmmap inspection")
        app_maps = vmmap(app_process.pid)
        if not mapped(executable, app_maps):
            errors.append("runtime mapping probe: vmmap did not show the launched app executable")
        for owner in sorted(owners):
            image = app / owner
            if mapped(image, app_maps):
                errors.append(f"runtime mapping probe: app PID maps QuickJS-bearing image {owner}")
        if WORKER_EXECUTABLE not in owners:
            errors.append("runtime mapping probe: worker is not the statically verified QuickJS owner")
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        errors.append(f"runtime mapping probe could not establish containment: {error}")
    finally:
        if app_process is not None:
            stop_process(app_process)
        if data_root is not None:
            data_root.cleanup()
    return errors


def verify(app: Path, check_runtime_mapping: bool = True) -> list[str]:
    errors: list[str] = []
    if not app.is_dir():
        return [f"missing app bundle: {app}"]

    required = [*EXPECTED_IDENTIFIERS, BROKER_BUNDLE + "/Contents/Info.plist"]
    for relative in required:
        path = app / relative
        if not path.is_file():
            errors.append(f"missing required containment path: {relative}")
        elif relative in EXPECTED_IDENTIFIERS and not path.stat().st_mode & 0o111:
            errors.append(f"containment executable is not executable: {relative}")
    if errors:
        return errors

    verify_result = command("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    if verify_result.returncode:
        errors.append("codesign --verify --deep --strict failed: " + verify_result.stderr.decode("utf-8", "replace").strip())
    broker_verify = command(
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2",
        str(app / BROKER_BUNDLE))
    if broker_verify.returncode:
        errors.append("broker codesign --verify --deep --strict failed: "
                      + broker_verify.stderr.decode("utf-8", "replace").strip())
    if (app / "Contents/Helpers/JortJavaScriptWorker").exists():
        errors.append("worker must be nested only inside the broker bundle")

    bundle_infos = {
        "Contents/Info.plist": "dev.jort.editor",
        BROKER_BUNDLE + "/Contents/Info.plist": "dev.jort.editor.javascript-broker",
    }
    for relative, expected in bundle_infos.items():
        try:
            identifier = plistlib.loads((app / relative).read_bytes()).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException) as error:
            errors.append(f"cannot read {relative}: {error}")
            continue
        if identifier != expected:
            errors.append(f"{relative} identifier is {identifier!r}, expected {expected!r}")

    signing: dict[str, dict[str, str]] = {}
    for relative, expected in EXPECTED_IDENTIFIERS.items():
        values, raw = details(app / relative)
        signing[relative] = values
        if values.get("Identifier") != expected:
            errors.append(f"{relative} signed identifier is {values.get('Identifier')!r}, expected {expected!r}")
        if relative in EXPECTED_ENTITLEMENTS:
            try:
                actual = entitlements(app / relative)
            except ValueError as error:
                errors.append(f"{relative} entitlements unavailable: {error}")
            else:
                if actual != EXPECTED_ENTITLEMENTS[relative]:
                    errors.append(f"{relative} entitlements are {actual!r}, expected {EXPECTED_ENTITLEMENTS[relative]!r}")
        if relative in (BROKER_EXECUTABLE, WORKER_EXECUTABLE) and "runtime" not in values.get("flags", ""):
            errors.append(f"{relative} is missing the Hardened Runtime flag")
        if not raw:
            errors.append(f"codesign did not return details for {relative}")

    teams = {values.get("TeamIdentifier") for values in signing.values()}
    if None in teams or len(teams) != 1:
        errors.append("app, broker, worker, and client must share one signing team")

    files = macho_files(app)
    if not files:
        errors.append("no Mach-O files found in app bundle")
    expected_by_identifier = {identifier: relative for relative, identifier in EXPECTED_IDENTIFIERS.items()}
    for path in files:
        relative = canonical_relative(app, path)
        identifier = details(path)[0].get("Identifier")
        expected_path = expected_by_identifier.get(identifier)
        if expected_path and relative != expected_path:
            errors.append(f"{identifier} is duplicated at {relative}; expected only {expected_path}")
    owners = quickjs_owners(app, files)
    if owners != {WORKER_EXECUTABLE}:
        errors.append("QuickJS symbols/links must exist only in " + WORKER_EXECUTABLE + "; found " + repr(sorted(owners)))
    if check_runtime_mapping and not errors:
        errors.extend(runtime_mapping_errors(app, owners))
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=DEFAULT_APP, help="built Jort.app to inspect (default: dist/Jort.app)")
    args = parser.parse_args()
    app = args.app.resolve()
    errors = verify(app)
    if errors:
        raise SystemExit("JavaScript containment verification failed:\n- " + "\n- ".join(errors))
    print(f"JavaScript containment verification passed: {app}")


if __name__ == "__main__":
    main()
