#!/usr/bin/env bash

set -euo pipefail

FILE_PATH="${1:?Usage: ./scripts/encode_base64.sh path/to/file}"

base64 < "$FILE_PATH" | tr -d '\n'
echo
