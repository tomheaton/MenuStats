#!/bin/sh
# Builds build/MenuStats.app. Pass "install" to also copy it to /Applications.
set -eu
cd "$(dirname "$0")"

APP=build/MenuStats.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos14" Sources/*.swift -o "$APP/Contents/MacOS/MenuStats"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
	pkill -x MenuStats || true
	rm -rf /Applications/MenuStats.app
	cp -R "$APP" /Applications/
	open /Applications/MenuStats.app
	echo "Installed /Applications/MenuStats.app"
fi
