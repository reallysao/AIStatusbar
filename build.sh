#!/bin/bash
# 构建 AIStatusbar.app (Touch Bar 状态条: 监控豆包/ChatGPT/DeepSeek/通义千问等)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/src"
APP="$(cd "$(dirname "$0")" && pwd)/AIStatusbar.app"
BIN="$APP/Contents/MacOS/AIStatusbar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AIStatusbar</string>
    <key>CFBundleIdentifier</key><string>com.aistatusbar</string>
    <key>CFBundleName</key><string>AIStatusbar</string>
    <key>CFBundleDisplayName</key><string>AI Statusbar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "PKGINFO" > "$APP/Contents/PkgInfo"

echo "compiling..."
swiftc -O \
    -o "$BIN" \
    "$SRC/Config.swift" \
    "$SRC/ProcessTable.swift" \
    "$SRC/AppMonitor.swift" \
    "$SRC/TouchBarController.swift" \
    "$SRC/main.swift" \
    -framework AppKit -framework IOKit -framework CoreGraphics

codesign --force --sign - "$APP" 2>/dev/null || true
echo "done: $APP"
