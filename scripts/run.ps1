# Run the game in FS-UAE as a real A500: 512k chip + 512k slow, Kick 1.3
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root "tools\fs-uae.exe") `
    --amiga_model=A500 `
    --kickstart_file="$root\roms\kick13.rom" `
    --chip_memory=512 `
    --slow_memory=512 `
    --hard_drive_0="$root\uae\dh0" `
    --joystick_port_1=keyboard `
    --automatic_input_grab=0
