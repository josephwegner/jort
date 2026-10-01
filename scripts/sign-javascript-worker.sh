#!/usr/bin/env bash
set -euo pipefail

if [[ "$CODE_SIGNING_ALLOWED" != "YES" ]]; then
  # The protected Apple Development path builds unsigned, embeds its selected
  # profile, then signs the complete contained bundle in sign_development.py.
  echo "Skipping worker signing because Xcode signing is disabled."
  exit 0
fi

worker="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/JortJavaScriptWorker"
entitlements="$SRCROOT/Configuration/JortJavaScriptWorker.entitlements"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ ! -f "$worker" ]]; then
  echo "Missing embedded JavaScript worker: $worker" >&2
  exit 1
fi
if [[ -z "$identity" ]]; then
  identity="-"
fi

arguments=(
  --force
  --sign "$identity"
  --identifier dev.jort.editor.javascript-worker
  --entitlements "$entitlements"
  --options runtime
  --timestamp=none
  --generate-entitlement-der
)

/usr/bin/codesign "${arguments[@]}" "$worker"
/usr/bin/touch "$DERIVED_FILE_DIR/JortJavaScriptWorker-signature.stamp"
