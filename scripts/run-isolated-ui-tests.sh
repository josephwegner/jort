#!/bin/bash
# Build first, prepare an isolated GUI identity, then test without rebuilding it.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration=Debug
derived_data="$JORT_ROOT/.build-ui-tests"
kind=debug
source_app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) configuration="$2"; shift 2 ;;
    --derived-data) derived_data="$2"; shift 2 ;;
    --kind) kind="$2"; shift 2 ;;
    --source-app) source_app="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "Unknown isolated UI option: $1" >&2; exit 2 ;;
  esac
done
case "$configuration" in Debug|Release) ;; *) exit 2 ;; esac
case "$kind" in debug|packaged) ;; *) exit 2 ;; esac
filters=()
if [[ "$kind" == packaged ]]; then
  filters=(-only-testing:JortUITests/PackagedJortUITests)
else
  # Xcode combines --only selections; don't add a broad one to focused runs.
  if [[ $# -eq 0 ]]; then
    filters=(-only-testing:JortUITests)
  fi
  filters+=(-skip-testing:JortUITests/PackagedJortUITests)
fi
filters+=("$@")
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme Jort \
  -configuration "$configuration" -derivedDataPath "$derived_data" \
  -destination 'platform=macOS' "${filters[@]}" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  JORT_APP_ENTITLEMENTS=Configuration/JortLocal.entitlements \
  JORT_CREDENTIAL_ENVIRONMENT=development JORT_PRODUCTION_TEAM_ID= \
  JORT_JS_ALLOW_ADHOC=1 build-for-testing
if [[ -z "$source_app" ]]; then
  source_app="$derived_data/Build/Products/$configuration/Jort.app"
fi
# Preparation rejects credential-bearing artifacts and rewrites launch metadata.
test_run="$(python3 "$JORT_ROOT/scripts/prepare-ui-tests.py" \
  --products-dir "$derived_data/Build/Products" --source-app "$source_app" --kind "$kind")"
xcodebuild -xctestrun "$test_run" -destination 'platform=macOS' \
  "${filters[@]}" test-without-building
