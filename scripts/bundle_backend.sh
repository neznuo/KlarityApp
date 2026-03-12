#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bundle_backend.sh
#
# Xcode "Run Script" Build Phase — copies the Python backend + virtualenv
# into the .app bundle so the app is fully self-contained.
#
# HOW TO ADD THIS AS AN XCODE BUILD PHASE:
#   1. In Xcode: Target → Build Phases → "+" → New Run Script Phase
#   2. Paste the full path to this script:
#        "${SRCROOT}/scripts/bundle_backend.sh"
#   3. Drag this phase to run AFTER "Compile Sources" but BEFORE "Copy Bundle Resources"
#   4. Uncheck "Based on dependency analysis" so it always runs
#
# PREREQUISITES (run once before first build):
#   cd backend && python3 -m venv venv && pip install -r requirements.txt
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Resolve the repo root from this script's location (scripts/ → repo root)
# This works regardless of where the .xcodeproj is.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_SRC="${REPO_ROOT}/backend"
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/backend"

echo "▶ Bundling backend into: ${DEST}"
echo "  REPO_ROOT: ${REPO_ROOT}"
echo "  BACKEND_SRC: ${BACKEND_SRC}"

# Validate that the backend source and venv exist
if [ ! -d "${BACKEND_SRC}" ]; then
    echo "error: Backend directory not found at ${BACKEND_SRC}"
    exit 1
fi

if [ ! -f "${BACKEND_SRC}/venv/bin/python" ]; then
    echo "error: Python venv not found at ${BACKEND_SRC}/venv"
    echo "       Run: cd backend && python3 -m venv venv && pip install -r requirements.txt"
    exit 1
fi

# Create destination
mkdir -p "${DEST}"

# Copy the backend app code (fast — only Python source files)
rsync -a --delete \
    --exclude=".env" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    --exclude=".pytest_cache" \
    --exclude=".ruff_cache" \
    --exclude="tests/" \
    "${BACKEND_SRC}/app" "${DEST}/"

# Copy requirements + config files
cp "${BACKEND_SRC}/requirements.txt" "${DEST}/"

# Copy the virtualenv (this includes all installed packages)
# rsync -a is used to make subsequent builds fast (only copies changed files)
rsync -a --delete \
    "${BACKEND_SRC}/venv" "${DEST}/"

# Copy .env if it exists (not required — app uses defaults / Keychain without it)
if [ -f "${BACKEND_SRC}/.env" ]; then
    cp "${BACKEND_SRC}/.env" "${DEST}/.env"
    echo "  ✓ Copied .env"
fi

echo "✅ Backend bundled successfully → ${DEST}"
