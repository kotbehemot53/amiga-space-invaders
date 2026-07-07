# SPACE INVADERS — Amiga 500

## Why this exists

If you want to just dive into the project, you can skip this subsection. If you're interested in a backstory, read on.

The whole project, except for this here subsection of the README was written solely by an LLM (Claude Fable 5 in particular). I've done it as an experiment to see how good Fable is, while I can test it as part of my regular Claude Pro license (which is possible until today).

On a day-to-day basis, I work as a developer, but on a much higher-level than assembly. I am an Amiga enthusiast though, and in my spare time have dabbled briefly in some x86 and m68k assembly in the past (but on a very shallow level).

In my regular work I use LLMs a lot (Claude mostly), and being a senior dev, I think it can be an invaluable help, taking the mundane tasks off your shoulders, and allowing you to focus on the big picture: modelling the part of reality you're working on, thinking on the architecture, and so on.

I am well aware of the risks that AI brings to the industry and the world as a whole though. Cognitive decay and cognitive debt are very real. The human developer has to remain in control - they have to understand thoroughly what the LLM does, they have to review it carefuly, and they have to take full responsibility for what was written as if they wrote it all themselves. Only then it can work in the long run, and be actually useful.

In this particular case though, I wanted to make an experiment and have some fun. I wanted to "vibe-code" something, without following the LLM closely, or even understanding the code, and to see what comes out of it.

Here's the prompt I used:

```
Yo dawg, write me a game compatible with the Amiga 500 computer. It should be written in Motorola 68k assembly, and should utilise Amiga custom chipset wherever it makes sense. It should show off its audio-visual capabilities and run smoothly on an A500 with 512 kb Chip RAM + 512 kb "slow RAM". It should be a clone of Space Invaders, with score counting, scoreboard, joystick control. I did some Amiga ASM projects a long time ago - they are in the "D:\amiga_exp" directory, they utilised VSCode, FS-UAE for debugging, vasm for assemblying, but I'm not sure if my system is still configured to work like this. If not, tell me how to prepare it.
```

After this, Fable worked completely on its own. The initial "thinking" time was quite long (over 40 minutes), then it paused occasionally to ask me for permission to run various scripts - other than that there was no interrputions and no need for me to stop it or correct it. In total it took about 1.5h. The LLM installed the whole toolchain on its own, ran and debugged its work periodically on its own, including running the emulator and taking screenshots to see if the game looks right (and correcting when it didn't). I must admit it was quite amazing.

I wanted to keep it all at least somewhat educational, so I asked my dear clanker to write an extensive walkthrough of the code (see the `doc` directory). There's also a `CLAUDE.md` file to easily kickstart further work with Claude Code. Feel free to read it, run it, play with it, and fork it to your heart's content.

Below the LLM-generated content begins.

## What it is

Space Invaders clone for a stock Amiga 500 (OCS, PAL, 512 KB chip + 512 KB
slow RAM, Kickstart 1.3+). Pure 68000 assembly, single file: `main.asm`.

New to Amiga/68k internals? Read
[doc/CODE_WALKTHROUGH.md](doc/CODE_WALKTHROUGH.md) — a full explanation
of the code and hardware tricks, written for people coming from
high-level languages, with line-by-line deep dives into the key
routines in [doc/](doc/).

## What it uses

| Chip | Job |
|------|-----|
| Copper | per-scanline background gradient, rainbow colour bands for alien rows, palette + bitplane/sprite pointer refresh |
| Blitter | alien formation redraw, explosions (cookie-cut), shield drawing, HUD life icons, rect clears |
| Sprites | player cannon (sprite 0), UFO saucer (sprite 2) |
| Paula | 4 channels of generated SFX: march bass loop (speeds up), shot, explosions, UFO warble |
| CPU | bullets/bombs (2px columns), text rendering, pixel-exact shield damage |

Display: 320x256, 3 bitplanes. Game objects live in plane 0 and get their
colour from the copper band they fly through (like the film gels on the
original arcade cab). Text in plane 1, twinkling starfield in plane 2.

## Gameplay

- Joystick in **port 2** (in FS-UAE: cursor keys + right Ctrl/Alt via
  `--joystick_port_1=keyboard`), left/right + fire.
- 5 rows x 11 aliens: 30/20/10 points per row, UFO 50-300 random.
- 4 destructible shields, pixel-level damage.
- 3 lives, wave counter, formation starts lower and marches faster
  each wave; high-score table (top 5) on the title screen.
- **Left mouse button quits** back to Workbench/CLI cleanly.

## Setting up from a fresh clone

`tools/` (the toolchain) and `roms/` (Kickstart) are not in the repo —
one is 50 MB of binaries, the other is copyrighted. Two steps:

### 1. Toolchain

Download the prebuilt vasm/vlink/FS-UAE bundle (same set the VSCode
Amiga Assembly extension uses) and unpack it as `tools/`.

**Linux / macOS / Git Bash** — one script, picks the right bundle for
your OS (`debian_x64` / `osx` / `windows_x64`):

```bash
./scripts/get-tools.sh
```

**Windows (PowerShell)** — manual equivalent:

```powershell
Invoke-WebRequest https://github.com/prb28/vscode-amiga-assembly-binaries/archive/refs/heads/windows_x64.zip -OutFile tools.zip
Expand-Archive tools.zip -DestinationPath .
Rename-Item vscode-amiga-assembly-binaries-windows_x64 tools
Remove-Item tools.zip
```

### 2. Kickstart ROM

Put a **Kickstart 1.3 (rev 34.5) ROM image** at `roms/kick13.rom`
(create the `roms/` directory first). You must own it legally —
dump it from your own A500 or take it from a purchased
[Amiga Forever](https://www.amigaforever.com/) package. Without it
FS-UAE cannot boot; the game itself doesn't care which 1.x/2.x ROM,
but the configs expect this exact path/name.

## Build & run (no VSCode needed)

Windows (PowerShell):

```powershell
.\scripts\build.ps1   # vasm + vlink -> uae/dh0/invaders
.\scripts\run.ps1     # boots FS-UAE as an A500, autostarts the game
```

Linux / macOS (also works in Git Bash on Windows):

```bash
./scripts/build.sh
./scripts/run.sh
```

## VSCode + source-level debugging

1. Install the **Amiga Assembly** extension (`prb28.amiga-assembly`).
2. `.vscode/settings.json` already points `amiga-assembly.binDir` at
   `tools/`, so no download is needed.
3. `Ctrl+Shift+B` builds; F5 launches "FS-UAE Debug (A500)" with the GDB
   remote debugger attached (breakpoints, registers, copper disassembly).
4. Task "amigaassembly: create ADF" produces `build/invaders.adf` for
   real hardware.
