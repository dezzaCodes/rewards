#!/usr/bin/env bash

set -euo pipefail

: "${ANDROID_KEYSTORE_BASE64:?ANDROID_KEYSTORE_BASE64 is required}"
: "${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD is required}"
: "${ANDROID_KEY_ALIAS:?ANDROID_KEY_ALIAS is required}"
: "${ANDROID_KEY_PASSWORD:?ANDROID_KEY_PASSWORD is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$PROJECT_ROOT/android"
ANDROID_APP_DIR="$ANDROID_DIR/app"
KEYSTORE_PATH="$ANDROID_APP_DIR/upload-keystore.jks"
KEY_PROPERTIES_PATH="$ANDROID_DIR/key.properties"

mkdir -p "$ANDROID_APP_DIR"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | openssl base64 -d -A -out "$KEYSTORE_PATH"

cat > "$KEY_PROPERTIES_PATH" <<EOF
storeFile=upload-keystore.jks
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
keyPassword=$ANDROID_KEY_PASSWORD
EOF

echo "Android signing assets installed at $KEYSTORE_PATH"
