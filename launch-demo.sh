#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Find first booted simulator or default to iPhone 17
BOOTED_ID=$(xcrun simctl list devices | grep "Booted" | grep -v "Apple Watch" | head -n 1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' || true)

if [ -z "$BOOTED_ID" ]; then
  echo "==> No simulator booted. Booting iPhone 17..."
  xcrun simctl boot "iPhone 17" || true
  BOOTED_ID=$(xcrun simctl list devices | grep "Booted" | grep -v "Apple Watch" | head -n 1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
fi

echo "==> Using Simulator Device ID: $BOOTED_ID"

echo "==> Building Demo app for iOS Simulator..."
xcodebuild -project Demo/Demo.xcodeproj -scheme Demo \
  -destination "platform=iOS Simulator,id=$BOOTED_ID" \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH=$(find .build/DerivedData/Build/Products -name "Demo.app" -type d | head -n 1)

if [ -z "$APP_PATH" ]; then
  echo "Error: Demo.app not found in build products."
  exit 1
fi

echo "==> Found App at: $APP_PATH"
echo "==> Installing app to device: $BOOTED_ID"
xcrun simctl install "$BOOTED_ID" "$APP_PATH"

echo "==> Launching com.nilkanth.PhotoManagerDemo..."
xcrun simctl launch "$BOOTED_ID" com.nilkanth.PhotoManagerDemo

echo "==> Done! App successfully launched on simulator."
