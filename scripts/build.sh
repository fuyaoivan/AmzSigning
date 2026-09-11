#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/Temp
export TMPDIR="$PWD/.build/Temp/"
swift build -c release --cache-path "$PWD/.build/Cache" --manifest-cache local
amz_bin="$(swift build -c release --cache-path "$PWD/.build/Cache" --manifest-cache local --show-bin-path)"
amz_stage="$(mktemp -d "$PWD/.build/AmzSigning-package.XXXXXX")"
trap 'rm -rf -- "$amz_stage"' EXIT
amz_app="$amz_stage/AmzSigning.app"
mkdir -p "$amz_app/Contents/MacOS" "$amz_app/Contents/Helpers" "$amz_app/Contents/Resources"
cp "$amz_bin/AmzSigning" "$amz_app/Contents/MacOS/AmzSigning"
cp "$amz_bin/AmzSigningAgent" "$amz_app/Contents/Helpers/AmzSigningAgent"
cp Resources/Info.plist "$amz_app/Contents/Info.plist"
xcrun swiftc -module-cache-path "$amz_stage/ModuleCache" Sources/AmzSigning/BrandArtwork.swift scripts/make-icon.swift -o "$amz_stage/make-icon"
"$amz_stage/make-icon" "$amz_stage/AppIcon.iconset"
iconutil -c icns "$amz_stage/AppIcon.iconset" -o "$amz_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$amz_app/Contents/Helpers/AmzSigningAgent"
codesign --force --sign - "$amz_app"
codesign --verify --deep --strict "$amz_app"
mkdir -p "$PWD/dist"
rm -rf -- "$PWD/dist/AmzSigning.app"
mv "$amz_app" "$PWD/dist/AmzSigning.app"
print "$PWD/dist/AmzSigning.app"
