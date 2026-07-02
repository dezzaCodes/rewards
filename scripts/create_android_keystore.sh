#!/usr/bin/env bash

set -euo pipefail

OUTPUT_PATH="android/app/upload-keystore.jks"
KEY_ALIAS="upload"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --alias)
      KEY_ALIAS="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: ./scripts/create_android_keystore.sh [--output path] [--alias alias]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

keytool -genkeypair \
  -v \
  -keystore "$OUTPUT_PATH" \
  -alias "$KEY_ALIAS" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000

echo
echo "Created keystore at $OUTPUT_PATH"
echo "Base64 for GitHub Secrets:"
echo "  ./scripts/encode_base64.sh $OUTPUT_PATH"
