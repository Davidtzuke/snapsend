#!/bin/zsh
# Builds a universal SnapSend.app into build/.
# Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/SnapSend.app"
BIN="$APP/Contents/MacOS/SnapSend"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp App/Info.plist "$APP/Contents/Info.plist"

for arch in arm64 x86_64; do
  echo "Compiling for $arch…"
  swiftc -O -swift-version 6 -parse-as-library \
    -module-name SnapSend \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift \
    -o "build/obj/SnapSend-$arch"
done
lipo -create build/obj/SnapSend-arm64 build/obj/SnapSend-x86_64 -output "$BIN"

# A stable signing identity keeps camera and Accessibility permissions across rebuilds.
# Without one the app is signed ad hoc, and macOS asks for permissions again after each build.
# Select by SHA-1 hash, since a renewed certificate shares its name with the old one.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --options runtime \
  --entitlements App/SnapSend.entitlements \
  --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-an ad-hoc identity})"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x SnapSend 2>/dev/null || true
  rm -rf ~/Applications/SnapSend.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/SnapSend.app
  echo "Installed to ~/Applications/SnapSend.app"
fi
