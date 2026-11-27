#!/bin/sh
# Builds TokenBurn.app next to this script. Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP=TokenBurn.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/TokenBurn"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TokenBurn</string>
  <key>CFBundleIdentifier</key><string>local.tokenburn</string>
  <key>CFBundleName</key><string>TokenBurn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
