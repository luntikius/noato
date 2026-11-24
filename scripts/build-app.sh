#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo 'noato requires native Apple Silicon (M1 or newer).' >&2; exit 2; }
version=$(sw_vers -productVersion)
[[ "${version%%.*}" -ge 15 ]] || { echo 'noato requires macOS 15 or newer.' >&2; exit 2; }
xcrun --find swift >/dev/null 2>&1 || { echo 'Install Apple Command Line Tools: xcode-select --install' >&2; exit 2; }
swift_version=$(xcrun swift --version | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -n 1)
awk -v v="$swift_version" 'BEGIN {split(v,a,"."); exit !(a[1]>6 || (a[1]==6 && (a[2]>2 || (a[2]==2 && a[3]>=3))))}' || { echo 'Swift 6.2.3+ is required. Update Command Line Tools or Xcode.' >&2; exit 2; }
xcrun swift build -c release --product noato --arch arm64 --disable-automatic-resolution >&2
binary_dir=$(xcrun swift build -c release --arch arm64 --show-bin-path)
output="${NOATO_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output"
staging=$(mktemp -d "${TMPDIR:-/tmp/}noato-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/noato.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/noato" "$app/Contents/MacOS/noato"
cp Sources/quill/Info.plist "$app/Contents/Info.plist"
for resource in "$binary_dir/"*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
xcrun swift scripts/generate-icon.swift "$staging/AppIcon.iconset" >&2
iconutil -c icns "$staging/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/Licenses"
for checkout in .build/checkouts/*; do
    [[ -d "$checkout" ]] || continue
    component=$(basename "$checkout")
    for license in "$checkout"/LICENSE* "$checkout"/NOTICE*; do
        [[ -f "$license" ]] || continue
        cp "$license" "$app/Contents/Resources/Licenses/$component-$(basename "$license")"
    done
done
# Reject accidental links against a developer's checkout or external packages.
otool -L "$app/Contents/MacOS/noato" | tail -n +2 | awk '{print $1}' | while read -r dependency; do
    case "$dependency" in /System/*|/usr/lib/*) ;; *) echo "Unbundled dependency: $dependency" >&2; exit 2 ;; esac
done
codesign --force --sign - --identifier io.github.luntikius.noato "$app" >&2
codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" | grep -qx 'io.github.luntikius.noato'
[[ -f "$app/Contents/Resources/noato_quill.bundle/en.lproj/Localizable.strings" ]]
# Stage before replacing output. No installed application is touched here.
if [[ -e "$output/noato.app" ]]; then
    [[ ! -L "$output/noato.app" && -d "$output/noato.app" ]] || { echo 'Unsafe output path.' >&2; exit 2; }
    rm -rf "$output/noato.app"
fi
ditto "$app" "$output/noato.app"
printf '%s\n' "$output/noato.app"
