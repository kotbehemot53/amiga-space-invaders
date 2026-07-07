# Deep dive: the blitter routines — `CalcP0Word`, `BlitObj16`, `BlitCell`

*Source: `main.asm`, section "BLITTER HELPERS".*

## Blitter mental model

The blitter is a memory-to-memory DMA engine with four channels:
three sources (**A**, **B**, **C**) and one destination (**D**). For
every 16-bit word of a rectangular region it computes

```
D = LF(A, B, C)
```

where `LF` is an arbitrary 3-input boolean function you specify as one
byte (the **minterm**, explained below). Channels you don't enable
simply don't participate. On top of that, channels A and B each have a
**barrel shifter** (0–15 bits right) — that's how word-aligned data
lands on arbitrary pixel positions — and every channel has a **modulo**:
a byte count added to that channel's pointer at the end of each row,
which is how a narrow rectangle walks through a wide bitmap.

One golden rule: the blitter runs *in parallel with the CPU*. Before
touching its registers (or CPU-writing memory it may still be writing),
wait for it. That's the `WAITBLT` macro at the top of each routine:

```asm
	tst.w	DMACONR(a5)		; A1000 compat dummy read
wblt\@	btst	#6,DMACONR(a5)
	bne.s	wblt\@
```

Bit 6 of DMACONR is "blitter busy". (The dummy read first works around
a hardware bug on the earliest Agnus revisions where the busy bit could
read stale — costs 2 cycles, kept out of politeness to real hardware.)
`\@` is vasm's "unique number per macro expansion", so the label doesn't
collide when the macro is used twice in one routine.

## `CalcP0Word` — pixel (x,y) → destination address

```asm
; d0=x px, d1=y px -> a1 = Plane0 word-aligned dest (trashes d4/d5)
CalcP0Word:
	move.w	d1,d4
	lsl.w	#5,d4
	move.w	d1,d5
	lsl.w	#3,d5
	add.w	d5,d4			; y*40
	move.w	d0,d5
	lsr.w	#4,d5
	add.w	d5,d5
	add.w	d5,d4
	ext.l	d4
	lea	Plane0,a1
	add.l	d4,a1
	rts
```

A bitplane row is 40 bytes (320 px / 8). The byte address of a pixel is
`plane + y*40 + x/8`, but the blitter wants a *word*-aligned start, so
we use `(x/16)*2` instead:

- `lsl.w #5` / `lsl.w #3` / `add` — `y*32 + y*8 = y*40`. Two shifts
  and an add: 20-ish cycles versus ~70 for `mulu #40`. This is the
  single most common arithmetic idiom in the file.
- `lsr.w #4,d5` — x/16: which 16-pixel word column.
- `add.w d5,d5` — ×2: words to bytes.
- `ext.l d4` — sign-extend the 16-bit sum to 32 bits. Addresses are
  32-bit; the following `add.l` would otherwise pick up garbage in the
  upper half of d4. (The offset is always < 10240, so positive — the
  sign extension is really a zero extension here.)
- `lea Plane0,a1` + `add.l d4,a1` — final pointer.

The pixel-within-word remainder (`x & 15`) is *not* lost — the callers
feed it to the blitter's shifter.

## `BlitObj16` — draw one object (aliens, icons, explosion)

```asm
;--- OR-blit 16x8 object: a0=gfx (8 rows x 2 words), d0=x, d1=y
BlitObj16:
	WAITBLT
	bsr.s	CalcP0Word
	move.w	d0,d2
	and.w	#15,d2
	ror.w	#4,d2
	or.w	#$0bfa,d2		; USEA/USEC/USED, D = A|C
	move.w	d2,BLTCON0(a5)
	move.w	#0,BLTCON1(a5)
	move.l	#$ffffffff,BLTAFWM(a5)
	move.w	#0,BLTAMOD(a5)
	move.w	#36,BLTCMOD(a5)
	move.w	#36,BLTDMOD(a5)
	move.l	a0,BLTAPTH(a5)
	move.l	a1,BLTCPTH(a5)
	move.l	a1,BLTDPTH(a5)
	move.w	#(8<<6)+2,BLTSIZE(a5)
	rts
```

- `and.w #15,d2` — the sub-word pixel offset (0–15): how far right the
  image must shift inside its 32-px window.
- `ror.w #4,d2` — **ro**tate **r**ight by 4: moves the low nibble into
  bits 15–12, which is where BLTCON0 expects the A-channel shift count.
  A rotate is used instead of a 12-bit left shift because it's a single
  fast instruction and the low bits are guaranteed clear.
- `or.w #$0bfa,d2` — fold in the rest of the control word:
  - `$0B00` = bits 11/9/8: **USEA, USEC, USED** (B disabled).
  - `$FA` = the minterm. How to read it: for each of the 8 possible
    input combinations `ABC` (000…111), bit number `ABC` of the
    minterm byte is the output. Want `D = A OR C`? List the
    combinations where A or C is 1: 001,011,100,101,110,111 → bits
    1,3,4,5,6,7 → binary 11111010 → `$FA`. The blitter is a 256-case
    truth-table machine; `$F0` would be plain copy (D = A), `$00` is
    "fill with zeros" (used by `ClearRect`).
- **Why OR and not copy?** The image is 16 px wide but after shifting
  it occupies a 32-px (2-word) window. A plain `D = A` would write
  zeros over the window's unused half — and formation cells are 16 px
  apart, so that half *contains the neighbouring alien*. OR-ing with
  the current screen (C, pointed at the same place as D) makes the
  blit purely additive. Erasure is handled elsewhere (the band clear).
- `move.w #0,BLTCON1(a5)` — no B shift, no special modes.
- `move.l #$ffffffff,BLTAFWM(a5)` — one 32-bit write covers *two*
  registers: BLTAFWM ($44) and BLTALWM ($46), the first/last-word
  masks. These can trim pixels at the row edges; we don't need
  trimming because…
- …the graphics are stored **pre-padded**: each row is
  `dc.w image,$0000`. The genuine data sits in word 1; the zero word
  gives the shifter room, so whatever spills right during shifting is
  shifted-in zeros, harmless under OR. This storage convention is what
  keeps this routine mask-free and fast.
- `BLTAMOD = 0` — source rows are contiguous (2 words each, and the
  blit is 2 words wide).
- `BLTCMOD/BLTDMOD = 36` — after each 2-word (4-byte) row of the
  window, skip 36 bytes to reach the next screen row: 40 − 4 = 36.
  The modulo is what makes a 4-byte-wide blit crawl down a
  40-byte-wide screen.
- Pointer setup: A = graphics, C = D = screen. Writing `BLTxPTH` as a
  longword fills both the high and low pointer registers.
- `move.w #(8<<6)+2,BLTSIZE(a5)` — the trigger. BLTSIZE packs
  height (bits 15–6) and width-in-words (bits 5–0): 8 rows, 2 words.
  **Writing this register starts the blit.** It must be written last —
  hence the whole setup order above. The routine returns immediately;
  the blit finishes on its own (the *next* blitter user's WAITBLT
  will absorb any remaining busy time).

## `BlitCell` — the cookie-cut replace

Used when an alien dies: stamp the explosion into its 16-px cell,
erasing the alien, *without* damaging neighbours sharing the same words.

```asm
; a0=gfx, d0=x, d1=y   D = A | (~B & C), B = solid cell mask
BlitCell:
	WAITBLT
	bsr.s	CalcP0Word
	move.w	d0,d2
	and.w	#15,d2
	ror.w	#4,d2
	move.w	d2,d3
	or.w	#$0ff2,d2		; USEA/USEB/USEC/USED, LF $F2
	move.w	d2,BLTCON0(a5)
	move.w	d3,BLTCON1(a5)		; B shift = A shift
	...
	move.l	#CellMask,BLTBPTH(a5)
	...
```

Differences from `BlitObj16`, line by line:

- `move.w d2,d3` — keep a copy of the rotated shift value *before*
  OR-ing in the control bits, because BLTCON1 wants the **B-channel
  shift** in its top nibble. B must shift by the same amount as A so
  the stencil tracks the image.
- `or.w #$0ff2,d2` — `$0F00` enables all four channels;
  minterm `$F2` = `A | (~B & C)`. Derivation: output 1 whenever A=1
  (combinations 100,101,110,111 → bits 4–7) plus where A=0,B=0,C=1
  (001 → bit 1) → 11110010 → `$F2`. In words: **inside the stencil
  (B=1) show exactly A; outside it (B=0) keep the screen (C).**
- `move.l #CellMask,BLTBPTH(a5)` — B reads `CellMask`: 8 rows of
  `dc.w $ffff,$0000` — a solid 16-px square with the same zero padding
  as every sprite image. Shifted along with A, it defines "the cell"
  at any pixel position.
- Everything else (mods, C=D=screen, same BLTSIZE) is identical.

Effect: the 16 px under the stencil are wiped and replaced by the
explosion pixels; the other up-to-16 px of the shifted window pass
through untouched. One blit, no read-modify-write dance, no neighbour
damage. This is *the* classic Amiga "bob" (blitter object) technique —
game sprites beyond the 8 hardware ones were all drawn this way.

## Cost accounting (why "redraw all 55 aliens" is fine)

One object blit moves 8 rows × 2 words through 3 channels ≈ 50 memory
cycles ≈ 7 µs. The band clear (`ClearRect`, D-only, LF=$00) is
20 words × 96 rows ≈ 550 µs at worst. Full formation redraw:
0.55 + 55 × 0.007 ≈ **under 1 ms**, out of the 20 ms frame — and the
blitter does it while the CPU sets up the next thing. The 68000 doing
the same job with `or.w` loops would take an order of magnitude longer
and could never hold 50 fps late in a wave.
