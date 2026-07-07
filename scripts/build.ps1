# Build Space Invaders: vasm -> vlink -> uae/dh0/invaders
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $root "tools"

New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null

& (Join-Path $tools "vasmm68k_mot.exe") -m68000 -Fhunk -linedebug `
    -o (Join-Path $root "build\main.o") (Join-Path $root "main.asm")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $tools "vlink.exe") -bamigahunk -Bstatic `
    -o (Join-Path $root "uae\dh0\invaders") (Join-Path $root "build\main.o")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "OK -> uae\dh0\invaders"
