#!/bin/zsh
# Builds Dial.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Dial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dial "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Dial.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Dial.app"
