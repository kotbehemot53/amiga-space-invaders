#!/usr/bin/env bash
# Run the game in FS-UAE as a real A500: 512k chip + 512k slow, Kick 1.3
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EXE=""
[ -f "$ROOT/tools/fs-uae.exe" ] && EXE=".exe"

cd "$ROOT/tools"   # fs-uae loads fs-uae.dat relative to cwd
"./fs-uae$EXE" \
    --amiga_model=A500 \
    --kickstart_file="$ROOT/roms/kick13.rom" \
    --chip_memory=512 \
    --slow_memory=512 \
    --hard_drive_0="$ROOT/uae/dh0" \
    --joystick_port_1=keyboard \
    --automatic_input_grab=0
