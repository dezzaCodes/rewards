#!/usr/bin/env bash

set -euo pipefail

: "${IOS_TEAM_ID:?IOS_TEAM_ID is required}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"
: "${IOS_PROFILE_NAME:?IOS_PROFILE_NAME is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="${1:-$PROJECT_ROOT/ios/ExportOptions.plist}"

cat > "$OUTPUT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>app-store</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key>
    <string>$IOS_PROFILE_NAME</string>
  </dict>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$IOS_TEAM_ID</string>
</dict>
</plist>
EOF

echo "Wrote $OUTPUT_PATH"
