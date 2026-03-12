#!/usr/bin/env bash
# ─────────────────────────────────────────────────────
# build.sh — Debug build wrapper for KlarityApp
# Usage: ./scripts/build.sh
# ─────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/apps/macos/KlarityApp.xcodeproj"
DERIVED_DATA="/tmp/KlarityApp-build"
CONFIG="Debug"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/KlarityApp.app"

echo "═══════════════════════════════════════════"
echo "  KlarityApp — ${CONFIG} Build"
echo "  Project: ${PROJECT}"
echo "  Output:  ${APP_PATH}"
echo "═══════════════════════════════════════════"

xcodebuild \
  -project "${PROJECT}" \
  -scheme KlarityApp \
  -configuration "${CONFIG}" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep --line-buffered -E \
    "error:|warning:.*\.swift|BUILD (SUCCEEDED|FAILED)|▶|✅|PhaseScript|SwiftCompile normal arm64 Compiling"

EXIT=${PIPESTATUS[0]}

if [ $EXIT -eq 0 ]; then
  echo ""
  echo "✅  BUILD SUCCEEDED"
  echo ""
  echo "  📦 App bundle:"
  echo "     ${APP_PATH}"
  echo ""
  echo "  Open in Finder:"
  echo "     open -R \"${APP_PATH}\""
  echo ""
  echo "  Run directly:"
  echo "     open \"${APP_PATH}\""
else
  echo ""
  echo "❌  BUILD FAILED (exit ${EXIT})"
  echo ""
  echo "  Full logs are in:"
  echo "     ${DERIVED_DATA}/Logs/Build/"
fi

exit $EXIT
