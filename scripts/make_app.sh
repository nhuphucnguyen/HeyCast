#!/bin/zsh
# Build SwiftCast and assemble a proper macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
APP_NAME="SwiftCast"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="1.0.0"

echo "==> swift build (release)"
DEVELOPER_DIR="$DEVELOPER_DIR" swift build -c release

echo "==> generating icon"
rm -rf "$BUILD_DIR/AppIcon.iconset"
swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.iconset" >/dev/null
rm -rf "$BUILD_DIR/$APP_NAME.icns"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/$APP_NAME.icns"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"

# SPM resource bundle (emoji dataset etc.)
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R ".build/release/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.swiftcast.app</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCalendarsUsageDescription</key>
    <string>SwiftCast can show your upcoming calendar events on the empty launcher page.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.swiftcast.app.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>swiftcast</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ad-hoc codesign so LaunchServices treats it as a normal app
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> done: $APP"
