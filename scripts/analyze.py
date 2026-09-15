#!/usr/bin/env python3
"""Blocking first-party compiler/analyzer checks or isolated QuickJS audit."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("lane", choices=["first-party", "quickjs"])
parser.add_argument(
    "--self-test",
    action="store_true",
    help="Verify the first-party failure gate with a null dereference",
)
parser.add_argument(
    "--force",
    action="store_true",
    help="Run the QuickJS analyzer even if inputs are unchanged",
)
parser.add_argument(
    "--reuse", action="store_true", help="Reuse a previously successful QuickJS audit"
)
args = parser.parse_args()
if args.self_test and args.lane != "first-party":
    parser.error("--self-test belongs to the first-party lane")
env = dict(os.environ)
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
out = ROOT / (".build-analysis-" + args.lane + ("-self-test" if args.self_test else ""))
out.mkdir(exist_ok=True)


def run(command, name):
    print("Running: " + " ".join(map(str, command)), flush=True)
    with (out / name).open("w") as log:
        result = subprocess.run(
            command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT
        )
    if result.returncode:
        print((out / name).read_text(), file=sys.stderr)
        sys.exit(result.returncode)
    return (out / name).read_text()


versions = {
    cmd: subprocess.check_output(command, env=env, text=True).strip()
    for cmd, command in [
        ("xcode", ["xcodebuild", "-version"]),
        ("swift", ["xcrun", "swift", "--version"]),
        ("clang", ["xcrun", "clang", "--version"]),
    ]
}
(out / "toolchain.json").write_text(json.dumps(versions, indent=2) + "\n")
tracked = (
    subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
    )
    .decode()
    .split("\0")
)
if args.lane == "first-party":
    run(
        ["python3", "scripts/audit-tool-dependencies.py", "--self-test"],
        "dependency-self-test.log",
    )
    run(["python3", "scripts/audit-tool-dependencies.py"], "dependencies.log")
    project = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(ROOT / "Jort.xcodeproj/project.pbxproj"),
            ]
        )
    )
    production = {
        key: value["name"]
        for key, value in project["objects"].items()
        if value.get("isa") == "PBXNativeTarget"
        and value.get("productType")
        not in (
            "com.apple.product-type.bundle.unit-test",
            "com.apple.product-type.bundle.ui-testing",
        )
    }
    scheme = ET.parse(
        ROOT / "Jort.xcodeproj/xcshareddata/xcschemes/JortEngineering.xcscheme"
    )
    covered = set()
    for entry in scheme.findall(".//BuildActionEntry"):
        reference = entry.find("BuildableReference")
        if entry.attrib.get("buildForRunning") == "YES" and reference is not None:
            covered.add(reference.attrib["BlueprintIdentifier"])
    if set(production) != covered:
        sys.exit(
            "Engineering scheme must explicitly cover every production target: "
            + str(production)
        )
    (out / "targets.json").write_text(
        json.dumps(sorted(production.values()), indent=2) + "\n"
    )
    # Swift has compiler diagnostics, not a Clang path-sensitive analyzer. Build all
    # production targets; analyze the first-party C bridge separately, never Vendor.
    run(
        [
            "xcodebuild",
            "-project",
            "Jort.xcodeproj",
            "-scheme",
            "JortEngineering",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(out / "DerivedData"),
            "build",
        ],
        "build.log",
    )
    sources = sorted(
        p
        for p in tracked
        if p.endswith((".c", ".m", ".mm", ".cpp"))
        and p.startswith(("Sources/", "Jort/", "Tools/"))
    )
else:
    sources = sorted(
        p for p in tracked if p.endswith(".c") and p.startswith("Vendor/QuickJS/")
    )
if not sources:
    sys.exit("No C sources found; refusing an empty analysis lane.")
if args.self_test:
    fixture = out / "intentional-finding.c"
    fixture.write_text("int intentional_finding(void) { int *p = 0; return *p; }\n")
    sources.append(str(fixture.relative_to(ROOT)))
compiler_flags = [
    "-std=gnu11",
    "-DDEBUG=1",
    "-fno-common",
    "-mmacosx-version-min=14.0",
    "-I",
    "Vendor/QuickJS",
    "-I",
    "Sources/JortJavaScript",
    '-DCONFIG_VERSION="2026-06-04"',
]
context = ROOT / "docs/quickjs-analyzer-provenance.json"
provenance = None
if args.lane == "quickjs":
    provenance = dict(
        toolchain=versions,
        compiler_flags=compiler_flags,
        sources={
            p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
            for p in sorted(tracked)
            if p.startswith("Vendor/QuickJS/")
        },
    )
    if context.exists():
        expected_context = json.loads(context.read_text())
        receipt = out / "validated.json"
        if (
            args.reuse
            and not args.force
            and receipt.exists()
            and expected_context == provenance
        ):
            validated = json.loads(receipt.read_text())
            fingerprint = hashlib.sha256(
                json.dumps(provenance, sort_keys=True).encode()
            ).hexdigest()
            if validated.get("provenance") != fingerprint:
                sys.exit("Cached QuickJS audit receipt does not match current inputs.")
            baseline = ROOT / "docs/quickjs-analyzer-baseline.json"
            if not baseline.exists():
                sys.exit("QuickJS baseline missing; refusing to skip the analyzer.")
            findings = json.loads(baseline.read_text())
            (out / "diagnostics.json").write_text(
                json.dumps(findings, indent=2, sort_keys=True) + "\n"
            )
            (out / "provenance.json").write_text(
                json.dumps(provenance, indent=2, sort_keys=True) + "\n"
            )
            (out / "baseline-diff.json").write_text(
                json.dumps(dict(added=[], removed=[]), indent=2) + "\n"
            )
            summary = "QuickJS audit: reusing a previously successful audit.\n"
            print(summary)
            if "GITHUB_STEP_SUMMARY" in os.environ:
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                    stream.write(summary)
            sys.exit(0)
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], env=env, text=True).strip()


def analyze_source(item):
    index, source = item
    report = out / f"{index}-{Path(source).stem}.plist"
    log = out / f"{index}-{Path(source).stem}.log"
    command = [
        "xcrun",
        "clang",
        "--analyze",
        "-isysroot",
        sdk,
        *compiler_flags,
        "-Xanalyzer",
        "-analyzer-output=plist",
        source,
        "-o",
        str(report),
    ]
    print("Running: " + " ".join(command), flush=True)
    with log.open("w") as stream:
        result = subprocess.run(
            command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT
        )
    if result.returncode:
        raise RuntimeError(log.read_text())
    return report


items = list(enumerate(sources))
if args.lane == "quickjs":
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(len(items), os.cpu_count() or 1)
    ) as pool:
        try:
            reports = list(pool.map(analyze_source, items))
        except RuntimeError as error:
            sys.exit(str(error))
else:
    reports = [analyze_source(item) for item in items]

findings = []
for report in reports:
    data = plistlib.loads(report.read_bytes())
    for diagnostic in data["diagnostics"]:
        location = diagnostic["location"]
        path = Path(data["files"][location["file"]])
        if path.is_absolute():
            path = path.relative_to(ROOT)
        findings.append(
            dict(
                file=str(path),
                line=location["line"],
                column=location["col"],
                checker=diagnostic["check_name"],
                message=diagnostic["description"],
            )
        )
findings.sort(key=lambda f: json.dumps(f, sort_keys=True))
(out / "diagnostics.json").write_text(
    json.dumps(findings, indent=2, sort_keys=True) + "\n"
)
(out / "sources.json").write_text(
    json.dumps(
        {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources},
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
print(
    f"{args.lane}: {len(sources)} C translation units, {len(findings)} diagnostics; reports: {out}"
)
if args.lane == "first-party":
    for finding in findings:
        print(
            f"{finding['file']}:{finding['line']}:{finding['column']}: {finding['message']} [{finding['checker']}]"
        )
    sys.exit(1 if findings else 0)
assert provenance is not None
(out / "provenance.json").write_text(
    json.dumps(provenance, indent=2, sort_keys=True) + "\n"
)
context_changed = not context.exists() or json.loads(context.read_text()) != provenance
baseline = ROOT / "docs/quickjs-analyzer-baseline.json"
if not baseline.exists():
    sys.exit(
        "QuickJS baseline missing; review diagnostics.json before establishing it."
    )
expected = json.loads(baseline.read_text())
added = [f for f in findings if f not in expected]
removed = [f for f in expected if f not in findings]
summary = f"QuickJS audit: {len(added)} added, {len(removed)} removed diagnostics; source/toolchain changed: {context_changed}.\n"
(out / "baseline-diff.json").write_text(
    json.dumps(dict(added=added, removed=removed), indent=2) + "\n"
)
print(summary)
if "GITHUB_STEP_SUMMARY" in os.environ:
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write(summary)
if added or removed or context_changed:
    sys.exit(
        "QuickJS diagnostic set changed; review the complete retained report and baseline diff."
    )
(out / "validated.json").write_text(
    json.dumps(
        {
            "provenance": hashlib.sha256(
                json.dumps(provenance, sort_keys=True).encode()
            ).hexdigest()
        },
        indent=2,
    )
    + "\n"
)
