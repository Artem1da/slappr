#!/bin/bash
set -e

# Slappr Build Script
# Builds a standalone Slappr.app bundle ready for installation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/Slappr"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Slappr"

echo "🔨 Building $APP_NAME..."

# Generate app icon from slappr.png
ICON_SOURCE="$SCRIPT_DIR/slappr.png"
ICON_DIR="$PROJECT_DIR/Slappr/Assets.xcassets/AppIcon.appiconset"
if [ -f "$ICON_SOURCE" ]; then
    echo "🎨 Generating app icons from slappr.png..."
    for size in 16 32 64 128 256 512 1024; do
        sips -z $size $size "$ICON_SOURCE" --out "$ICON_DIR/icon_${size}.png" >/dev/null 2>&1
    done
    # Write Contents.json with all icon sizes
    cat > "$ICON_DIR/Contents.json" << 'ICONJSON'
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
ICONJSON
    echo "✅ Icons generated"
else
    echo "⚠️  slappr.png not found, skipping icon generation"
fi

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Clean previous Xcode build cache to ensure fresh resources
cd "$PROJECT_DIR"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    clean 2>/dev/null || true

# Build with xcodebuild
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

# Extract the .app from the archive
APP_PATH="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Archive failed. Trying direct build..."

    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        build \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO

    APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed! No .app found."
    exit 1
fi

# Copy to build root for easy access
cp -R "$APP_PATH" "$BUILD_DIR/$APP_NAME.app"

# Ad-hoc sign the app (required for IOKit HID access on modern macOS)
echo "🔏 Signing app (ad-hoc)..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"

# Verify Sounds are in the bundle
SOUNDS_IN_BUNDLE="$BUILD_DIR/$APP_NAME.app/Contents/Resources/Sounds"
if [ -d "$SOUNDS_IN_BUNDLE" ]; then
    SOUND_COUNT=$(find "$SOUNDS_IN_BUNDLE" -type f \( -name "*.mp3" -o -name "*.wav" -o -name "*.aiff" -o -name "*.m4a" -o -name "*.ogg" \) | wc -l | tr -d ' ')
    echo "🔊 $SOUND_COUNT sound files bundled"
else
    echo "⚠️  No Sounds directory in bundle. Sounds may not be included."
fi

echo ""
echo "✅ Build successful!"
echo "📦 App location: $BUILD_DIR/$APP_NAME.app"
echo ""
echo "To install, run:"
echo "  cp -R \"$BUILD_DIR/$APP_NAME.app\" /Applications/"
echo ""
echo "Or just double-click the .app to run it."
