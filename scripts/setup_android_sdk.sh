#!/usr/bin/env bash

set -euo pipefail

: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_HOME:?ANDROID_HOME or ANDROID_SDK_ROOT is required}"

export ANDROID_HOME
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

PACKAGES=(
  "platform-tools"
  "platforms;android-34"
  "build-tools;35.0.0"
  "ndk;28.2.13676358"
  "cmake;3.22.1"
)

# sdkmanager exits after reading enough "y" responses, which causes `yes`
# to receive SIGPIPE. Avoid failing the script under `set -o pipefail`.
set +o pipefail
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null
set -o pipefail
sdkmanager --sdk_root="$ANDROID_HOME" "${PACKAGES[@]}"
