#!/usr/bin/env bash
# Build Space Invaders: vasm -> vlink -> uae/dh0/invaders
set -euo pipefail
cd "$(dirname "$0")/.."

EXE=""
[ -f tools/vasmm68k_mot.exe ] && EXE=".exe"   # windows_x64 toolchain

mkdir -p build
"tools/vasmm68k_mot$EXE" -m68000 -Fhunk -linedebug -o build/main.o main.asm
"tools/vlink$EXE" -bamigahunk -Bstatic -o uae/dh0/invaders build/main.o
echo "OK -> uae/dh0/invaders"
