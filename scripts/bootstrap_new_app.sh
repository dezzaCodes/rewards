#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bootstrap_new_app.sh \
    --dart-package my_app \
    --display-name "My App" \
    --application-id com.company.myapp

This updates the generated Flutter template identifiers for Android and iOS.
EOF
}

DART_PACKAGE_NAME=""
DISPLAY_NAME=""
APPLICATION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dart-package)
      DART_PACKAGE_NAME="$2"
      shift 2
      ;;
    --display-name)
      DISPLAY_NAME="$2"
      shift 2
      ;;
    --application-id)
      APPLICATION_ID="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DART_PACKAGE_NAME" || -z "$DISPLAY_NAME" || -z "$APPLICATION_ID" ]]; then
  usage
  exit 1
fi

if [[ ! "$DART_PACKAGE_NAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "Dart package names must match ^[a-z][a-z0-9_]*$" >&2
  exit 1
fi

if [[ ! "$APPLICATION_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; then
  echo "Application IDs must look like com.company.appname" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

replace_in_file() {
  local old="$1"
  local new="$2"
  local file="$3"

  OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

replace_in_file "name: app_blueprint" "name: $DART_PACKAGE_NAME" \
  "$PROJECT_ROOT/pubspec.yaml"
replace_in_file "App Blueprint" "$DISPLAY_NAME" \
  "$PROJECT_ROOT/lib/src/app.dart"
replace_in_file "App Blueprint" "$DISPLAY_NAME" \
  "$PROJECT_ROOT/lib/src/features/dashboard/dashboard_screen.dart"
replace_in_file "App Blueprint" "$DISPLAY_NAME" \
  "$PROJECT_ROOT/ios/Runner/Info.plist"
replace_in_file "App Blueprint" "$DISPLAY_NAME" \
  "$PROJECT_ROOT/android/app/src/main/AndroidManifest.xml"
replace_in_file "app_blueprint" "$DART_PACKAGE_NAME" \
  "$PROJECT_ROOT/test/widget_test.dart"
replace_in_file "com.example.app_blueprint" "$APPLICATION_ID" \
  "$PROJECT_ROOT/android/app/build.gradle.kts"
replace_in_file "com.example.appBlueprint" "$APPLICATION_ID" \
  "$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"

OLD_KOTLIN_DIR="$PROJECT_ROOT/android/app/src/main/kotlin/com/example/app_blueprint"
NEW_KOTLIN_DIR="$PROJECT_ROOT/android/app/src/main/kotlin/${APPLICATION_ID//./\/}"
mkdir -p "$NEW_KOTLIN_DIR"

if [[ -f "$OLD_KOTLIN_DIR/MainActivity.kt" ]]; then
  mv "$OLD_KOTLIN_DIR/MainActivity.kt" "$NEW_KOTLIN_DIR/MainActivity.kt"
fi

replace_in_file "package com.example.app_blueprint" "package $APPLICATION_ID" \
  "$NEW_KOTLIN_DIR/MainActivity.kt"

echo "Updated identifiers."
echo "Run flutter pub get after renaming to refresh generated metadata."
