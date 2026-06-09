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

# Code-sign with a STABLE identity so the macOS Keychain trusts the same app
# across rebuilds. Without this, the binary's identity changes on every build and
# you'd be re-prompted for your login-keychain password to read the Claude Code
# credentials item. Set SIGN_IDENTITY to a code-signing cert in your keychain;
# defaults to a self-signed cert named "ClaudeUsage Code Signing".
#
# To create the self-signed cert once (no password, persists across rebuilds):
#   Keychain Access > Certificate Assistant > Create a Certificate…
#     Name: ClaudeUsage Code Signing
#     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#
# If the named identity isn't found we fall back to ad-hoc signing and warn that
# the password prompt will keep returning.
SIGN_IDENTITY="${SIGN_IDENTITY:-ClaudeUsage Code Signing}"

echo ""
# Note: a self-signed cert is usable for signing but NOT "valid" under the
# codesigning policy, so `find-identity -v` won't list it. Detect by attempting
# the signature and fall back to ad-hoc only if that genuinely fails.
if codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>/dev/null; then
    echo "Signed with stable identity: ${SIGN_IDENTITY}"
    codesign --verify --verbose=2 "${APP_DIR}"
else
    echo "WARNING: code-signing identity '${SIGN_IDENTITY}' not found."
    echo "         Falling back to ad-hoc signing — macOS will keep asking for your"
    echo "         keychain password on each rebuild and token rotation."
    echo "         See the comment in build.sh to create a stable self-signed cert."
    codesign --force --sign - "${APP_DIR}"
fi

echo ""
echo "Done. Built: ${APP_DIR}"
echo "Run:  open ${APP_DIR}"
