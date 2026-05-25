#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
APP_DIR="${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "Building..."
swift build -c release

echo "Packaging ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

echo ""
echo "Done. Built: ${APP_DIR}"
echo "Run:  open ${APP_DIR}"
