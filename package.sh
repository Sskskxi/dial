#!/bin/zsh
# Builds a release Dial.app and zips it to build/Dial.zip for GitHub Releases.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Dial.app
rm -rf "$APP" build/Dial.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dial "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" build/Dial.zip
echo "Packaged build/Dial.zip"
