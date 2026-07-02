#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC_PATH="$PROJECT_ROOT/pubspec.yaml"

VERSION_LINE="$(awk '/^version:/{print $2; exit}' "$PUBSPEC_PATH")"
PUBSPEC_BUILD_NAME="${VERSION_LINE%%+*}"

RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"

if [[ "$RUN_ATTEMPT" =~ ^[0-9]+$ ]]; then
  AUTO_BUILD_NUMBER="$(date -u +%s)"
else
  AUTO_BUILD_NUMBER="$(date -u +%s)"
fi

BUILD_NAME="${APP_BUILD_NAME_OVERRIDE:-$PUBSPEC_BUILD_NAME}"
BUILD_NUMBER="${APP_BUILD_NUMBER_OVERRIDE:-$AUTO_BUILD_NUMBER}"

echo "Resolved build metadata:"
echo "  BUILD_NAME=$BUILD_NAME"
echo "  BUILD_NUMBER=$BUILD_NUMBER"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "APP_BUILD_NAME=$BUILD_NAME"
    echo "APP_BUILD_NUMBER=$BUILD_NUMBER"
  } >> "$GITHUB_ENV"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "build_name=$BUILD_NAME"
    echo "build_number=$BUILD_NUMBER"
  } >> "$GITHUB_OUTPUT"
fi
