#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
BUILD_DIR="$TASK_ROOT/build"
LOCATION_KEY="$(print -rn "$TASK_ROOT" | /usr/bin/shasum -a 256 | cut -c1-12)"
MODULE_CACHE="$BUILD_DIR/module-cache-$LOCATION_KEY"
APP_DIR="$BUILD_DIR/release/镜生 H3.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
# Xcode 27's SwiftUI @State macros use a compiler subprocess. The outer Codex
# sandbox rejects nested sandbox-exec, so disable only the compiler's nested
# subprocess sandbox. This does not change any macOS security setting.
xcrun swiftc -disable-sandbox -swift-version 5 -O -module-cache-path "$MODULE_CACHE" -target arm64-apple-macos14.0 \
  "$TASK_ROOT"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/WanshenjiH3Studio"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>镜生 H3</string>
  <key>CFBundleDisplayName</key><string>镜生 H3</string>
  <key>CFBundleIdentifier</key><string>com.wengong.WanshenjiH3Studio</string>
  <key>CFBundleExecutable</key><string>WanshenjiH3Studio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.15</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
cp "$TASK_ROOT/Resources/H3S41ABPipelineTemplate.json" "$APP_DIR/Contents/Resources/H3S41ABPipelineTemplate.json"
python3 - "$TASK_ROOT/Data" "$APP_DIR/Contents/Resources/LegacyWorkspace.json" <<'PY'
import json,sys
from pathlib import Path
legacy=Path(sys.argv[1]).resolve()
try:
    relative=str(legacy.relative_to(Path.home()))
except ValueError:
    raise SystemExit('Legacy workspace must be inside the current user home; do not invent a replacement path.')
Path(sys.argv[2]).write_text(json.dumps({'relativeToHome':relative},indent=2),encoding='utf-8')
PY
xcrun swift -module-cache-path "$MODULE_CACHE" "$TASK_ROOT/scripts/icon.swift" "$BUILD_DIR/AppIcon.iconset" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --identifier com.wengong.WanshenjiH3Studio "$APP_DIR"
print "Staged candidate (not installed or launched): $APP_DIR"
