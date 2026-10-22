#!/bin/bash
# Builds iPaint.app into the project root.
set -euo pipefail
cd "$(dirname "$0")/.."

# CI passes a version in; a local build is just 1.0.0-dev.
VERSION="${IPAINT_VERSION:-1.0.0-dev}"
echo "==> Building iPaint $VERSION"
swift build -c release

APP=iPaint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/iPaint "$APP/Contents/MacOS/iPaint"

echo "==> Generating icon"
ICONDIR=$(mktemp -d)
swift scripts/make-icon.swift "$ICONDIR/icon-1024.png" >/dev/null
ICONSET="$ICONDIR/iPaint.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONDIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICONDIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/iPaint.icns"
rm -rf "$ICONDIR"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>iPaint</string>
    <key>CFBundleIdentifier</key><string>com.gift.ipaint</string>
    <key>CFBundleName</key><string>iPaint</string>
    <key>CFBundleDisplayName</key><string>iPaint</string>
    <key>CFBundleIconFile</key><string>iPaint</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>com.microsoft.bmp</string>
                <string>public.tiff</string>
                <string>com.compuserve.gif</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# substitute the version into the plist we just wrote
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" 2>/dev/null || true
echo "==> Done: $(pwd)/$APP"
