#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?Usage: bash Scripts/VerifyBundle.sh path/to/TangoDisplay.app}"
contents="$bundle/Contents"
executable="$contents/MacOS/TangoDisplay"
sparkle="$contents/Frameworks/Sparkle.framework/Sparkle"

test -x "$executable"
test -s "$contents/Resources/icon.icns"
test -s "$contents/Resources/SetlistLogo.png"
test -s "$contents/Resources/RemoteUI/index.html"
plutil -lint "$contents/Info.plist"
test "$(plutil -extract CFBundleExecutable raw "$contents/Info.plist")" = TangoDisplay
test "$(plutil -extract LSMinimumSystemVersion raw "$contents/Info.plist")" = 13.0
app_archs=" $(lipo -archs "$executable") "
sparkle_archs=" $(lipo -archs "$sparkle") "
for arch in arm64 x86_64; do
  [[ "$app_archs" == *" $arch "* && "$sparkle_archs" == *" $arch "* ]]
  xcrun vtool -arch "$arch" -show-build "$executable" | grep -E '^[[:space:]]*minos 13\.0(\.0)?$'
done
codesign --verify --deep --strict --verbose=2 "$bundle"
