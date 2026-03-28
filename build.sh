#!/bin/bash
set -e

# Slappr Build Script
# Builds a standalone Slappr.app bundle ready for installation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/Slappr"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Slappr"

echo "🔨 Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build with xcodebuild
cd "$PROJECT_DIR"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO

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
