#!/usr/bin/env bash
# Download the Amiga toolchain (vasm, vlink, FS-UAE, ADF tools) into tools/.
# Uses the prebuilt bundles from prb28/vscode-amiga-assembly-binaries —
# the same binaries the VSCode "Amiga Assembly" extension ships.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d tools ]; then
    echo "tools/ already exists — remove it first if you want a fresh copy." >&2
    exit 1
fi

case "$(uname -s)" in
    Linux*)                BRANCH=debian_x64 ;;
    Darwin*)               BRANCH=osx ;;
    MINGW*|MSYS*|CYGWIN*)  BRANCH=windows_x64 ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

URL="https://github.com/prb28/vscode-amiga-assembly-binaries/archive/refs/heads/$BRANCH.zip"
echo "Downloading $BRANCH toolchain..."

if command -v curl >/dev/null 2>&1; then
    curl -fL -o tools.zip "$URL"
else
    wget -O tools.zip "$URL"
fi

unzip -q tools.zip
mv "vscode-amiga-assembly-binaries-$BRANCH" tools
rm -f tools.zip

# non-Windows bundles need the executable bit restored after unzip
if [ "$BRANCH" != "windows_x64" ]; then
    chmod +x tools/vasmm68k_mot tools/vlink tools/fs-uae \
             tools/vbccm68k tools/vc tools/adf* 2>/dev/null || true
fi

echo "OK -> tools/ ($BRANCH)"
echo "Next: put a Kickstart 1.3 image at roms/kick13.rom, then ./scripts/build.sh && ./scripts/run.sh"
