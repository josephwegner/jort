#!/bin/bash
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JORT_PRESENTATION_LOG="$JORT_ROOT/.build-native-tests/presentation.log"
mkdir -p "$JORT_ROOT/.build-native-tests"
set +e
"$JORT_ROOT/scripts/test-native.sh" \
  -only-testing:JortCoreTests/PresentationCoordinatorTests \
  -only-testing:JortCoreTests/PresentationDrawingTests \
  -only-testing:JortCoreTests/NativeDrawingBaselineTests \
  -only-testing:JortCoreTests/PresentationReconciliationTests \
  -only-testing:JortCoreTests/PresentationPolicyTests \
  -only-testing:JortCoreTests/PreparedLineGeometryTests \
  -only-testing:JortCoreTests/RulerGeometryTests \
  -only-testing:JortCoreTests/InvocationGeometryTests \
  -only-testing:JortCoreTests/InvocationAccessibilityTests \
  -only-testing:JortCoreTests/ToolInvocationPresentationTests 2>&1 | tee "$JORT_PRESENTATION_LOG"
JORT_NATIVE_RESULT=${PIPESTATUS[0]}
set -e
if [ "$JORT_NATIVE_RESULT" -ne 0 ]; then exit "$JORT_NATIVE_RESULT"; fi
python3 "$JORT_ROOT/scripts/check-presentation-log.py" "$JORT_PRESENTATION_LOG"
