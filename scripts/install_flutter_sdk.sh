#!/usr/bin/env bash

set -euo pipefail

FLUTTER_DIR="${1:-$HOME/flutter}"

if [[ -d "$FLUTTER_DIR/.git" ]]; then
  git -C "$FLUTTER_DIR" fetch origin stable --depth 1
  git -C "$FLUTTER_DIR" checkout stable
  git -C "$FLUTTER_DIR" reset --hard origin/stable
else
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$FLUTTER_DIR/bin" >> "$GITHUB_PATH"
else
  export PATH="$FLUTTER_DIR/bin:$PATH"
fi

"$FLUTTER_DIR/bin/flutter" --version
