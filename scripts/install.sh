#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(./scripts/build-app.sh)
# Never terminate or replace a running recorder or transcription process.
for process in noato quill; do
    result=0
    pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 || result=$?
    if [[ "$result" -eq 0 ]]; then
        echo "$process is running. Finish recording/transcription, then Quit it and run this installer again." >&2
        exit 3
    elif [[ "$result" -ne 1 ]]; then
        echo 'Cannot determine whether the application is running. Installation stopped without changing it.' >&2
        exit 3
    fi
done
install_dir="${NOATO_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_dir"
[[ ! -L "$install_dir" && ! -L "$install_dir/noato.app" ]] || { echo 'Installation folder must not be a symbolic link.' >&2; exit 2; }
if [[ -e "$install_dir/noato.app" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_dir/noato.app/Contents/Info.plist")
    [[ "$identifier" == io.github.luntikius.noato ]] || { echo 'A different application occupies the destination.' >&2; exit 2; }
fi
staging=$(mktemp -d "$install_dir/.noato-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/noato.app"
codesign --verify --deep --strict "$staging/noato.app"
# Retain one prior app until replacement is complete. User data is outside it.
if [[ -d "$install_dir/noato.app" ]]; then mv "$install_dir/noato.app" "$staging/previous.app"; fi
if ! mv "$staging/noato.app" "$install_dir/noato.app"; then
    [[ ! -d "$staging/previous.app" ]] || mv "$staging/previous.app" "$install_dir/noato.app"
    exit 2
fi
# Remove only our known legacy login agent, after its process has exited.
legacy="$HOME/Library/LaunchAgents/com.digimata.quill.plist"
if [[ -f "$legacy" && ! -L "$legacy" && -z "${NOATO_INSTALL_DIR:-}" ]]; then
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$legacy")
    executable=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$legacy")
    if [[ "$label" == com.digimata.quill && "$(basename "$executable")" == quill ]]; then
        launchctl bootout "gui/$(id -u)" "$legacy" >/dev/null 2>&1 || true
        rm "$legacy"
    fi
fi
printf 'Installed: %s/noato.app\nCLI: %s/noato.app/Contents/MacOS/noato\n' "$install_dir" "$install_dir"
if [[ "${NOATO_NO_OPEN:-0}" != 1 ]]; then open "$install_dir/noato.app"; fi
