#!/usr/bin/env bash
set -euo pipefail

if [[ "$CODE_SIGNING_ALLOWED" != "YES" ]]; then
  # The protected Apple Development path builds unsigned, embeds its selected
  # profile, then signs the complete contained bundle in sign_development.py.
  echo "Skipping broker signing because Xcode signing is disabled."
  exit 0
fi

broker="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/JortJavaScriptBroker.xpc"
entitlements="$SRCROOT/Configuration/JortJavaScriptBroker.entitlements"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ ! -d "$broker" ]]; then
  echo "Missing embedded JavaScript broker: $broker" >&2
  exit 1
fi
if [[ -z "$identity" ]]; then
  identity="-"
fi

/usr/bin/codesign --force --sign "$identity" \
  --identifier dev.jort.editor.javascript-broker \
  --entitlements "$entitlements" \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  "$broker"
/usr/bin/touch "$DERIVED_FILE_DIR/JortJavaScriptBroker-signature.stamp"
