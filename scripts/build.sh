#!/bin/bash
set -euo pipefail
# This script may be invoked from a traced parent shell. It handles signing
# selectors and must never echo command lines that could contain credentials.
set +x
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
identity="${JORT_APPLE_DEVELOPMENT_IDENTITY:--}"
profile="${JORT_DEVELOPMENT_PROVISIONING_PROFILE:-}"
mkdir -p "$JORT_ROOT/dist"
stage="$(mktemp -d "$JORT_ROOT/dist/.local-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
derived_data="$stage/DerivedData"
app="$derived_data/Build/Products/Release/Jort.app"

app_entitlements="Configuration/JortLocal.entitlements"
if [[ "$identity" != "-" ]]; then
  if [[ -z "${JORT_DEVELOPMENT_TEAM_ID:-}" ]]; then
    echo "JORT_DEVELOPMENT_TEAM_ID is required with an Apple Development identity." >&2
    exit 2
  fi
  if [[ -z "$profile" ]]; then
    echo "JORT_DEVELOPMENT_PROVISIONING_PROFILE is required with an Apple Development identity." >&2
    exit 2
  fi
  identity="$(python3 "$JORT_ROOT/scripts/provisioning_profile.py" resolve-development-identity \
    --identity "$identity" --team-id "$JORT_DEVELOPMENT_TEAM_ID")"
  python3 "$JORT_ROOT/scripts/provisioning_profile.py" validate \
    --profile "$profile" --team-id "$JORT_DEVELOPMENT_TEAM_ID" --identity "$identity" --environment development >/dev/null
  app_entitlements="Configuration/JortDevelopment.entitlements"
elif [[ -n "$profile" ]]; then
  echo "JORT_DEVELOPMENT_PROVISIONING_PROFILE is forbidden for credential-free local builds." >&2
  exit 2
fi

overrides=(
  # Build ad-hoc first. The profile is inserted before the final contained
  # inside-out Apple Development pass below, so the outer app seal covers it.
  "CODE_SIGN_IDENTITY=-"
  "JORT_BUILD_AUDIENCE=local-only"
  "JORT_CREDENTIAL_ENVIRONMENT=development"
  "JORT_APP_ENTITLEMENTS=$app_entitlements"
)
if [[ -n "${JORT_DEVELOPMENT_TEAM_ID:-}" ]]; then
  overrides+=("DEVELOPMENT_TEAM=$JORT_DEVELOPMENT_TEAM_ID" "JORT_PRODUCTION_TEAM_ID=$JORT_DEVELOPMENT_TEAM_ID")
fi
if [[ "$identity" != "-" ]]; then
  # The profile is deliberately embedded after the build and the entire bundle
  # is then signed inside-out by sign_development.py.  Do not let Xcode infer
  # or require a profile before that controlled signing pass.
  overrides+=("CODE_SIGNING_ALLOWED=NO")
fi

# This is intentionally a local build entry point. A protected integration job
# may supply an Apple Development identity to exercise the real helper topology,
# but Developer ID and notarization selectors belong exclusively to release.sh.
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme Jort -configuration Release \
  -derivedDataPath "$derived_data" "${overrides[@]}" build
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -alltargets -configuration Release \
  "${overrides[@]}" -showBuildSettings -json \
  > "$stage/build-settings.json"
if [[ "$identity" != "-" ]]; then
  python3 "$JORT_ROOT/scripts/provisioning_profile.py" embed \
    --profile "$profile" --app "$app"
fi
manifest_profile_args=()
if [[ "$identity" != "-" ]]; then
  manifest_profile_args=(--team-id "$JORT_DEVELOPMENT_TEAM_ID" --provisioning-profile "$profile" --profile-environment development --signing-identity "$identity")
fi
python3 "$JORT_ROOT/scripts/release_manifest.py" generate \
  --settings "$stage/build-settings.json" \
  --app "$app" \
  "${manifest_profile_args[@]}" \
  --output "$stage/manifest.json"
if [[ "$identity" != "-" ]]; then
  python3 "$JORT_ROOT/scripts/sign_development.py" \
    --app "$app" \
    --manifest "$stage/manifest.json" --identity "$identity"
fi
python3 "$JORT_ROOT/scripts/package.py" \
  "$app" "$JORT_ROOT/dist/Jort.app" \
  --manifest "$stage/manifest.json"
echo "Local-only artifact: $JORT_ROOT/dist/Jort.app (not a Developer ID release or notarized distribution)."
