#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MTP_PREFIX="${MTP_PREFIX:-$PWD/.build/dependencies}"
[[ -f "$MTP_PREFIX/lib/libmtp.9.dylib" ]] || { echo "Run scripts/build-dependencies.sh first."; exit 1; }
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --build-system native ${SDKROOT:+--sdk "$SDKROOT"} --disable-sandbox --cache-path "$PWD/.build/cache" -c release --arch arm64
app="$PWD/dist/Kindle USB.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
xcrun actool --compile "$app/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 13.0 --output-partial-info-plist "$PWD/.build/AppIcon-Info.plist" \
    Assets.xcassets
cp .build/arm64-apple-macosx/release/KindleUSB "$app/Contents/MacOS/KindleUSB"
cp "$MTP_PREFIX/lib/libmtp.9.dylib" "$app/Contents/Frameworks/"
cp "$MTP_PREFIX/lib/libusb-1.0.0.dylib" "$app/Contents/Frameworks/"
chmod u+w "$app/Contents/Frameworks/"*.dylib
install_name_tool -change "$MTP_PREFIX/lib/libmtp.9.dylib" @executable_path/../Frameworks/libmtp.9.dylib "$app/Contents/MacOS/KindleUSB"
install_name_tool -id @rpath/libmtp.9.dylib -change "$MTP_PREFIX/lib/libusb-1.0.0.dylib" @loader_path/libusb-1.0.0.dylib "$app/Contents/Frameworks/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$app/Contents/Frameworks/libusb-1.0.0.dylib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KindleUSB</string>
<key>CFBundleIdentifier</key><string>local.kindleusb.browser</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleName</key><string>Kindle USB</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources/Licenses"
cp "$MTP_PREFIX/licenses/"* "$app/Contents/Resources/Licenses/"
identity="${SIGN_IDENTITY:--}"
args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then args+=(--options runtime --timestamp); fi
for library in "$app/Contents/Frameworks/"*.dylib; do codesign "${args[@]}" "$library"; done
codesign "${args[@]}" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
