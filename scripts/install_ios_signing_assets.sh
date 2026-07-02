#!/usr/bin/env bash

set -euo pipefail

: "${IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64:?IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64 is required}"
: "${IOS_DISTRIBUTION_CERTIFICATE_PASSWORD:?IOS_DISTRIBUTION_CERTIFICATE_PASSWORD is required}"
: "${IOS_PROVISIONING_PROFILE_BASE64:?IOS_PROVISIONING_PROFILE_BASE64 is required}"

RUNNER_TEMP_DIR="${RUNNER_TEMP:-/tmp}"
KEYCHAIN_NAME="${IOS_KEYCHAIN_NAME:-build.keychain-db}"
KEYCHAIN_PASSWORD="${IOS_KEYCHAIN_PASSWORD:-temporary-password}"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
LOGIN_KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP_DIR/ios-distribution.p12"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
PROFILE_TEMP_PATH="$RUNNER_TEMP_DIR/app.mobileprovision"
PROFILE_PLIST_PATH="$RUNNER_TEMP_DIR/app.mobileprovision.plist"

printf '%s' "$IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64" \
  | openssl base64 -d -A -out "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "$LOGIN_KEYCHAIN_PATH"

security import "$CERTIFICATE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$IOS_DISTRIBUTION_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

mkdir -p "$PROFILE_DIR"
printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" \
  | openssl base64 -d -A -out "$PROFILE_TEMP_PATH"

security cms -D -i "$PROFILE_TEMP_PATH" > "$PROFILE_PLIST_PATH"

PROFILE_NAME="$(
  /usr/libexec/PlistBuddy -c "Print :Name" "$PROFILE_PLIST_PATH"
)"
PROFILE_UUID="$(
  /usr/libexec/PlistBuddy -c "Print :UUID" "$PROFILE_PLIST_PATH"
)"
PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"

mv "$PROFILE_TEMP_PATH" "$PROFILE_PATH"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "IOS_KEYCHAIN_NAME=$KEYCHAIN_NAME"
    echo "IOS_KEYCHAIN_PATH=$KEYCHAIN_PATH"
    echo "IOS_PROFILE_NAME=$PROFILE_NAME"
    echo "IOS_PROFILE_UUID=$PROFILE_UUID"
    echo "IOS_PROFILE_PATH=$PROFILE_PATH"
  } >> "$GITHUB_ENV"
fi

echo "Installed provisioning profile: $PROFILE_NAME ($PROFILE_UUID)"
