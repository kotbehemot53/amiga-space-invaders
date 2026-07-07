# Code Walkthrough — Space Invaders in 68000 Assembly

A guided tour of `main.asm` for someone who lives in high-level languages
and last saw assembly at university. It explains not just *what* the code
does but *why the Amiga makes you do it that way*.

This document covers concepts and architecture. For **line-by-line
readings of the crucial routines**, see the deep dives:

| Deep dive | Covers | Teaches |
|---|---|---|
| [dive-mainloop.md](dive-mainloop.md) | `MainLoop`, `WaitVBL`, `StateTab` | beam-synced timing, jump tables, CIA polling |
| [dive-copper.md](dive-copper.md) | `BuildCopper` | copper lists, WAIT/MOVE encoding, the line-256 crossing, self-modified display programs |
| [dive-blitter.md](dive-blitter.md) | `CalcP0Word`, `BlitObj16`, `BlitCell` | minterms, shifts, modulos, padded gfx, cookie-cut bobs |
| [dive-aliens.md](dive-aliens.md) | `DrawAliens` | wipe-and-redraw strategy, extent tracking, table-driven gfx selection |
| [dive-bullet.md](dive-bullet.md) | `MoveBullet`, `AddScore`, `BCDToStr` | three collision styles, BCD scoring with `abcd`, the register-clobber bug |
| [dive-audio.md](dive-audio.md) | `PlaySound`, `UpdateAudio`, `PlayMarch` | Paula programming, one-shot scheduling, live pitch bends, tail calls |

---

## 1. The mental model shift

Forget everything a modern platform gives you. After the first twenty
instructions this program has:

- **No operating system.** We switch it off and talk to the hardware.
- **No memory allocator.** Every buffer is a statically declared block.
- **No graphics API.** "Drawing" means writing bytes into RAM that the
  video chip is simultaneously reading 50 times per second.
- **No sound API.** "Playing audio" means pointing a DMA channel at raw
  signed bytes and setting a sample rate.
- **No threads, no interrupts (here), no scheduler.** One CPU, one loop,
  synchronised to the TV beam.

What replaces all of it is a set of **memory-mapped hardware registers**
starting at address `$dff000`. Writing a 16-bit value to `$dff096` isn't
"calling a function" — it flips real control lines in the chipset. The
file starts with a long list of `equ` lines (assembler constants, zero
runtime cost) naming those registers: `DMACON`, `BPLCON0`, `COLOR00`…
That list is our entire "SDK".

The Amiga 500's chipset is three chips working off shared RAM:

| Chip | Role in this game |
|------|------------------|
| **Agnus** | Traffic cop. Owns DMA: fetches bitplanes, runs the **Copper** and the **Blitter** |
| **Denise** | Video output: turns bitplane bits into pixels, overlays **sprites** |
| **Paula** | Audio: 4 DMA channels of 8-bit samples; also floppy/serial/joystick bits |

**Chip RAM vs slow RAM:** only the first 512 KB ("chip RAM") is visible
to the custom chips. Anything the hardware touches — bitplanes, copper
list, sprite data, blitter graphics, audio samples — *must* live there.
The other 512 KB ("slow" expansion RAM) is CPU-only; our code and plain
variables can live in it. This is why the source is split into sections
(`data_c`, `bss_c` = chip; plain `code`/`data`/`bss` = wherever the OS
loader puts them). Get this wrong and the screen shows garbage from the
wrong address — the hardware doesn't error, it just reads whatever is at
the chip-RAM address you gave it.

---

## 2. Ten minutes of 68000

Registers: **d0–d7** (data) and **a0–a7** (address). a7 is the stack
pointer. Any register can hold anything; conventions are yours to invent.
This program's convention: **a5 permanently holds `$dff000`**, so
`DMACON(a5)` means "the DMACON register" everywhere. Subroutine arguments
go in registers ad hoc (documented in comments above each routine).

Every instruction has an operation size: `.b` (8-bit), `.w` (16-bit),
`.l` (32-bit). `move.w d0,d1` copies only the low 16 bits of d0 and
leaves d1's upper half untouched — a classic source of bugs, which is
why you'll see `moveq #0,d2` (clear whole register) before byte loads.

The instructions that carry this whole program:

| Instruction | Meaning |
|---|---|
| `move src,dst` | copy (note: operands read left→right, like `dst = src`) |
| `lea addr,aN` | load *address* into an address register (a pointer, no memory read) |
| `add/sub/and/or/eor` | arithmetic/logic; `eor` = XOR |
| `lsl/lsr/asr/ror` | shifts and rotates — multiplication/division by 2ⁿ |
| `cmp a,b` + `beq/bne/blt/bge/bhi…` | compare then conditionally branch (the if/else) |
| `bsr` / `rts` | call / return (return address on the stack) |
| `dbf dN,label` | "decrement and branch": the canonical loop — repeats until dN hits −1 |
| `movem.l d2-d4/a2,-(sp)` | push a set of registers (callee-saved conventions, by hand) |
| `btst #n,addr` | test a single bit, sets the Z flag |
| `mulu` / `abcd` | unsigned multiply / add binary-coded-decimal with carry |

Addressing modes you'll meet: `#123` immediate, `d0` register, `(a0)`
pointer dereference, `(a0)+` dereference then advance (pointer++),
`-(a0)` decrement then dereference, `8(a0)` offset, `(a0,d0.w)` base +
index. That's it — arrays, structs and loops are all built from these.

Labels starting with a dot (`.loop`, `.done`) are **local**: they exist
only between two normal labels, so every routine can have its own
`.done` without collisions.

---

## 3. Program skeleton

```
Start            system takeover
MainLoop         once per video frame: audio, stars, current game state
Quit             restore the OS, exit
```

### 3.1 Taking the machine (label `Start`)

You can't just trash the hardware — the user launched us from AmigaDOS
and expects to get their desktop back. The polite demo-scene protocol:

1. `move.l 4.w,a6` — address 4 is the one absolute constant in AmigaOS:
   a pointer to Exec, the kernel. Library calls are `jsr offset(a6)`,
   negative offsets into a jump table. We call `Forbid()` (stop
   multitasking) and `OpenLibrary("graphics.library")`.
2. Save the current DMA and interrupt enable masks (`DMACONR`,
   `INTENAR`). Quirk: the readable and writable versions of these are
   *different registers*, and the write format is "bit 15 = set/clear
   switch, bits 0-14 = which bits". That's why the code ORs `$8000` into
   the saved value — so writing it back later *sets* what was on.
3. `move.w #$7fff,INTENA/DMACON` — everything off. Silence.
4. Configure our display, build the copper list, enable exactly the DMA
   we need: `#$83e0` = master + bitplanes + copper + blitter + sprites.

On exit (`Quit`) the process runs backwards, plus one crucial line:
`move.l 38(a1),COP1LCH(a5)` — offset 38 in GfxBase is the OS's own
copper list; restoring it brings Workbench's display back.

### 3.2 The heartbeat (`MainLoop` and `WaitVBL`)

There is no timer API. The clock of the whole game is the **television
beam**: PAL draws 312 lines, 50 times a second. `WaitVBL` polls the beam
position register until it reaches line 303 (safely inside the vertical
blank, below the last visible line):

```asm
.wait   move.l  VPOSR(a5),d0
        and.l   #$1ff00,d0        ; isolate the 9-bit line number
        cmp.l   #303<<8,d0
        bne.s   .wait
```

Reading `VPOSR` as a 32-bit long grabs two adjacent registers at once —
the 9th bit of the line number lives in a different register than the
other 8, and the `$1ff00` mask stitches them together. The loop above it
(waiting for the line to *not* be 303 first) prevents running the game
twice in one frame if logic finished within a single scanline.

Everything after `WaitVBL` — game logic, blits, sound updates — happens
once per frame, giving a rock-solid 50 fps. There's no "delta time":
one frame is the unit of time. "Bullet speed 4" means 4 pixels per
frame, 200 pixels per second, always, on every A500 in the world.
That's why the code is full of frame-counter arithmetic like
`move.w #40,StateTimer` (0.8 seconds).

The game states (title / play / death / game-over / wave-intro) are a
jump table: `GameState` is an index into `StateTab`, a list of routine
addresses — assembly's switch statement:

```asm
        move.w  GameState,d0
        add.w   d0,d0
        add.w   d0,d0             ; index * 4 (pointers are 4 bytes)
        lea     StateTab(pc),a0
        move.l  (a0,d0.w),a0
        jsr     (a0)
```

---

## 4. How the picture works

### 4.1 Bitplanes: colour as a stack of 1-bit images

The Amiga doesn't store "a pixel = a colour byte". It stores N separate
1-bit-per-pixel images (**bitplanes**). For each pixel, the hardware
collects one bit from each plane, stacks them into a number, and uses
that number as an index into the palette registers (`COLOR00`…).

We run 3 bitplanes → 3 bits → colours 0–7. The clever part is *what we
put in each plane*:

- **Plane 0** — every game object: aliens, bullets, bombs, shields,
  ground, life icons. Alone it produces colour index 1 (binary 001).
- **Plane 1** — all text. Index 2 (010).
- **Plane 2** — the starfield. Index 4 (100).

So "the game world", "the HUD" and "the background" are three
independent transparent layers that can't corrupt each other — erasing a
bullet can't eat a letter, because they're in different planes. Overlap
indices (3, 5, 6, 7) are set to sensible colours in the palette.

One plane is 320×256 pixels = 40 bytes × 256 rows = 10 240 bytes. The
address of pixel (x, y) is `plane + y*40 + x/8`, bit `7-(x&7)` — you'll
see that computed all over the file, with `y*40` done as
`(y<<5)+(y<<3)` because shifts are cheaper than `mulu`.

### 4.2 The Copper: a GPU with three instructions

The **Copper** is a tiny processor inside Agnus that executes a program
(the *copper list*) in lockstep with the beam, restarting every frame.
It has literally two useful instructions:

- `WAIT line,pos` — sleep until the beam reaches this screen position
- `MOVE value,register` — write a value into any chipset register

That's enough to change *any* hardware setting mid-frame, per scanline.
Two effects in this game come from it:

**The background gradient.** `BuildCopper` writes a WAIT + `MOVE
COLOR00` pair every 4 scanlines, stepping through `GradTab` (64 colour
values, deep blue → black → violet glow). Cost to the CPU per frame:
zero. The copper repaints it forever.

**The rainbow alien rows.** Everything in plane 0 is "colour 1" — but
what colour 1 *means* is changed six times down the screen (`BandTab`):
red in the top alien band, orange below, then yellow, cyan-green, cyan,
and green for the shields/player zone. Objects get tinted by where they
are on screen, exactly like the coloured film strips glued onto the
original 1978 arcade monitor. One plane of graphics, six apparent
colours.

Quirk worth knowing: the WAIT instruction only holds 8 bits of the line
number, so a list crossing raster line 255 must insert a special
`$ffdf,$fffe` "cross the 256 boundary" wait — see the `.nocross` logic.

The copper list is *built at runtime* into a chip-RAM buffer (`CopBuf`):
first the bitplane pointers, sprite pointers and palette, then the
gradient/band section, terminated by `$fffffffe` (a WAIT for a position
that never comes). Two details:

- Bitplane and sprite **pointer registers are consumed** by the hardware
  as the frame is drawn (they increment while fetching), so something
  must reset them every frame. That something is the copper list itself
  — it runs from the top each vertical blank.
- The star twinkle: `BuildCopper` remembers the address of one word
  inside the list (`TwinkPtr`, the value written to `COLOR04`), and
  `TwinkleStars` pokes a new colour there every few frames. Writing
  into a *program* while it runs — self-modifying code, but on the
  copper, and completely idiomatic here.

### 4.3 Sprites: the two objects that draw themselves

Hardware **sprites** are small (16-pixel-wide) images that Denise
overlays on the picture with zero involvement from the bitplanes. No
erase, no redraw, no collision with the background — you write an (x,y)
into two control words and the object *is* there next frame.

The player cannon (sprite 0) and the UFO (sprite 2) are sprites, because
they move every frame and sit outside the formation redraw machinery.
The encoding (`SetSprPos`) is fiddly: 9-bit coordinates are split across
two words, with the 9th bits tucked into flag bits — the routine builds

```
POS word:  VSTART[7:0] << 8 | HSTART[8:1]
CTL word:  VSTOP[7:0] << 8  | V8 << 2 | S8 << 1 | H0
```

Sprite pixels have their own mini-palette (colours 17-19 for the pair
0/1, 21-23 for 2/3); a sprite is 2 bitplanes deep, so per-row data is
two words. "Hiding" a sprite = zeroing POS/CTL, making VSTART = VSTOP
so it never matches a scanline.

### 4.4 The Blitter: memcpy with opinions

The **Blitter** is a DMA engine that combines up to three source streams
(A, B, C) through an arbitrary boolean function into a destination (D),
operating on rectangular regions of bitplanes. It runs in parallel with
the CPU — you kick it and it works while you set up the next thing.
The `WAITBLT` macro (poll bit 6 of `DMACONR`) guards every use: never
touch blitter registers, or CPU-write memory the blitter may still be
writing, before it finishes.

The boolean function is the **minterm byte** — the blitter's LUT.
For each output bit, the three input bits A,B,C form a number 0–7;
the corresponding bit of the minterm byte is the answer. Used here:

| Minterm | Formula | Used for |
|---|---|---|
| `$00` | D = 0 | rectangle clear (`ClearRect`) |
| `$FA` | D = A OR C | draw object over background (`BlitObj16`) |
| `$F2` | D = A OR (NOT B AND C) | "cookie-cut": stamp A inside stencil B, keep C outside (`BlitCell`) |

Why `$FA` needs C at all: aliens are 16 px wide but a shifted blit
writes a 32-px window (two words). A plain copy would zero the second
half of that window — which overlaps the *neighbouring alien*. OR-ing
with the existing screen (C = D) makes the blit additive. And that's
also why every graphic is stored as `dc.w image,$0000` per row: the
extra zero word gives the hardware barrel shifter room to shift the
image right by 0–15 pixels without garbage entering the window.
Pixel-precise horizontal positioning of word-aligned data = shift value
in the top 4 bits of BLTCON0, destination address rounded down to a
word.

`$F2` solves the opposite problem: when an alien dies mid-formation we
want to *replace* one 16-px cell (erase alien, draw explosion) without
touching neighbours that live in the same words. B is a solid 16-px
stencil (`CellMask`); inside it C is discarded, outside it C survives.

**The formation strategy:** aliens don't move individually. On each
march tick, one `ClearRect` wipes the whole formation band, then up to
55 small OR-blits redraw every living alien at the new position
(`DrawAliens`). Sounds brutal; is nothing: the blitter fills at roughly
16 million pixels/sec, and the whole redraw fits comfortably in the
vertical blank. In exchange, all incremental-erase bookkeeping
disappears. While redrawing we also record the leftmost/rightmost
living column (`EdgeMinX/EdgeMaxX`) so edge-bounce uses the *live*
formation extent — a formation with dead outer columns marches further
before turning, like the original.

### 4.5 What the CPU draws itself

Small or byte-aligned things aren't worth the blitter's setup overhead:

- **Bullets and bombs** are 2-px-wide columns. X is forced even, so both
  pixels always sit in one byte, and drawing is a loop of `or.b
  mask,(a1)` stepping 40 bytes per row (`DrawVLine`); erasing is `and.b`
  with the inverted mask. Order per frame is load-bearing: *erase
  everything → move/collide → redraw survivors*. A bullet that dies
  this frame was already erased and simply never gets redrawn — no
  corpse pixels.
- **Text** (`DrawText`): 8×8 font, one byte per row, so a character at a
  multiple-of-8 x-position is 8 plain byte copies. The routine writes
  all 8 rows through displacement addressing (`(a1)`, `40(a1)`,
  `80(a1)`…`280(a1)`) without ever moving the pointer — then `addq #1`
  advances one character cell. Only ~40 glyphs exist (digits, A–Z,
  a few symbols), hand-drawn as hex in `Font`.
- **The 2× title** (`DrawText2x`): each font byte is stretched
  horizontally by a 16-entry lookup table (`NibExp`) that maps a nibble
  `abcd` to the byte `aabbccdd` — two lookups make 8 bits into 16 —
  and each row is written twice for vertical doubling.
- **Shield damage** (`BlastShield`): shields must be destroyed
  pixel-by-pixel, so hits AND an inverted 8×6 blob mask into plane 0 at
  the impact point, handling the two-byte straddle manually. Collision
  with shields is simply *"is there a pixel already set where my shot
  wants to be?"* (`TestPixel`) — the screen itself is the collision map,
  which is exactly how the 1978 original did it.

Collision with *aliens* is the opposite philosophy: pure arithmetic.
The formation is a grid, so `(bullet - formation origin) / 16` gives
row/column directly, then one byte lookup in `AlienTab` (55 alive
flags). No pixel scanning: O(1) per bullet per frame.

---

## 5. Game logic notes

**The march.** `MoveTimer` counts frames between formation steps;
`SetMoveDelay` recomputes it as roughly `AlienCnt/2 + 2`, so 55 aliens
step every ~29 frames and the last survivor every 2 — the accelerating
dread is emergent, no tuning table needed. Each step also toggles the
animation frame and plays the next of four descending bass notes
(`PlayMarch` + `MarchIdx`), so music tempo *is* game speed, exactly like
the arcade. Horizontal steps are 4 px; hitting an edge sets `DownFlag`,
and the next tick drops the formation 8 px and reverses direction.
If the formation bottom reaches the shields, that's an invasion →
game over.

**Mid-frame state changes.** `PlayState` calls subsystems in sequence,
but several of them can end the mode midway (`MoveBullet` may clear the
wave → `WaveEnter`; `MoveBombs` may kill the player → `PlayerHit`;
`MoveFormation` may trigger the invasion). After each such call the code
re-checks `GameState` and bails. Without that, the rest of the frame
would keep drawing into a screen that was just re-initialised.

**Scoring is BCD.** Scores are stored as binary-coded decimal — each
nibble is one decimal digit, `$00031240` reads directly as "031240".
The 68000 has a dedicated instruction for it: `abcd` (add BCD with
carry), used as a 4-byte chain in `AddScore`. Why bother? Because the
score is *displayed* every time it changes, and BCD→ASCII is just
peeling nibbles and adding `'0'` (`BCDToStr`) — no division by 10 in
sight. Consequence: point values in `RowPts`/`UfoPts` are BCD literals
(`$300` means three hundred) and must never be mixed with binary
arithmetic. Comparisons still work because BCD preserves ordering
byte-wise. Legit scores are always multiples of 10 — a handy corruption
canary that actually caught a real bug during development.

**The high-score table** (`HiTab`) lives in the initialised *data*
section, not BSS, so defaults (7500/5000/…) load with the program and
survive between games within a session. `GameOverEnter` does a plain
insertion: find slot, shift the tail down, write.

**RNG** (`Random`): a 16-bit linear-feedback shift register — shift
left, XOR with `$1d87` on carry. Deterministic chaos, two instructions.
Seeded from the beam position at the moment the player presses fire
(`VHPOSR`), the one genuinely unpredictable input available.

---

## 6. Sound: Paula from scratch

Paula plays memory directly: give a channel a sample address (chip RAM),
a length in words, a **period** (chipset clock ticks between bytes —
*smaller = higher pitch*; rate = 3 546 895 / period Hz) and a volume
(0–64). Enable the channel's DMA bit and it loops the sample forever
until told otherwise. There is no "stop at end" — one-shots are your
problem.

There are no sample files. `InitAudio` *synthesises* both instruments at
startup:

- `SqBuf`: 32 bytes, half `$7f` half `$81` — a square wave. Looped at
  period ~2000 it's the four-note march bass; at period ~340 with the
  pitch wobbled every frame by a sine table it's the UFO warble.
- `NoiseBuf`: 1 KB of LFSR white noise — every percussive effect
  (shots, explosions, death) is this same buffer at different
  period/volume/duration.

One-shot management is a 4-entry frame-countdown table (`ChTime`):
`PlaySound` stores a duration, `UpdateAudio` decrements each frame and
on zero disables the channel's DMA and zeroes its volume. Duration 0
means "loop until someone calls the stop routine" (the UFO).

Channel budget: 0 = march, 1 = player shot, 2 = all explosions,
3 = UFO. Same-channel effects simply cut each other off — authentic
and self-limiting.

**The one war story worth internalising:** `PlaySound` receives its five
arguments in d0–d4. In the alien-kill path, the sound call originally
ran *before* the code that used d3/d4 (the victim's column/row) to
position the explosion and look up the score value. The sfx wrapper
overwrote both registers, so the explosion blitted to garbage
coordinates and the score lookup indexed random memory *as BCD points* —
the score counter exploded to 40 000+ within seconds. In C the compiler
tracks register lifetimes for you; in assembly *you* are the register
allocator, and every `bsr` is a potential clobber. Fix: call sound
effects last (see the comment `; last: PlaySound eats d0-d4`).

---

## 7. Assembler & linker mechanics

- **vasm** (mot syntax) assembles the single source into an object with
  five sections; **vlink** emits an AmigaDOS "hunk" executable. Section
  names carry placement: `data_c`/`bss_c` become hunks flagged
  `MEMF_CHIP`, and the OS loader guarantees chip RAM for them. BSS hunks
  are zero-filled by the loader — all game variables boot as 0 for free.
- `(pc)`-relative addressing (`lea Table(pc),a0`) is shorter and
  position-independent, but only reaches labels in the *same section* —
  which is why every CPU-only lookup table sits in the code section,
  while anything DMA-read lives in a chip section and is addressed
  absolutely.
- Short branches (`bne.s`) reach ±128 bytes; vasm errors out rather than
  auto-widening a branch you explicitly suffixed, so long routines use
  plain `bne`.
- `WAITBLT` is a macro; `\@` expands to a unique number per expansion so
  its internal label never collides.

---

## 8. Reading order suggestion

1. `Start` → `InitDisplay` → `BuildCopper` (machine setup, display)
2. `MainLoop` → `WaitVBL` → `StateTab` (control flow)
3. `TitleEnter`/`TitleState` (simple state, uses most drawing routines)
4. `WaveEnter` → `PlayState` → `MoveFormation` → `DrawAliens` (the core)
5. `MoveBullet`/`MoveBombs` (collisions, both philosophies)
6. `BlitObj16`/`BlitCell`/`ClearRect` (blitter craft)
7. `PlaySound`/`UpdateAudio` (Paula)
8. Data sections at the bottom (art as hex, palette, tables)

Total: ~5.6 KB of code and ~36 KB of chip RAM to run an entire game.
The machine is small; the machine is knowable. Enjoy, and mind your
registers.
