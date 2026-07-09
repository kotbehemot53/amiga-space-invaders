# Deep dive: `DrawText`, `DrawText2x`, and the font

*Source: `main.asm`, labels `DrawText`, `DrawText2x`, `NibExp`, `Font`,
plus the HUD callers `DrawHud`, `RenderScores`, `WaveToStr`.
Called from almost every state (title, HUD, GAME OVER, name entry) to
stamp glyphs into plane 1.*

The game has no OS, so it has no `Text()` call and no system font — it
carries its own 8x8 bitmap font and pokes characters into the bitplane
byte by byte with the CPU. No blitter, no clipping, no proportional
spacing. This dive reads the small-text renderer line by line, then the
2x version, which is the same idea plus a neat nibble-doubling trick.

## Where the pixels live

Recall the display model (full detail in the walkthrough): 320x256, 3
bitplanes, **non-interleaved**, so each plane is a standalone 320x256x1
bitmap. 320 pixels / 8 = **40 bytes per row**. Plane 1 is the
text/HUD plane; whatever bit you set there shows up in the colour that
plane 1 contributes (index bit 1). Text normally never touches plane 0
(game objects) or plane 2 (starfield) — the exception is the
`DrawTextP0` entry point below, used by the title screen to stamp the
power-up legend tokens into plane 0 so they pick up the copper band
colours.

A pixel at (x, y) lives at byte `y*40 + x/8`, bit `7 - (x & 7)`.
`DrawText` sidesteps the bit math entirely by taking its x already
divided by 8 — a **byte column** — so every glyph lands on an 8-pixel
boundary and each character is exactly one byte wide.

## `DrawText` — the setup

```asm
; a0=nul-terminated string, d0=byte x (x/8), d1=y
DrawText:
	movem.l	d2-d3/a1-a3,-(sp)
	lea	Plane1,a1
	bra.s	DrawTextGo
; same, into plane 0: text gets the BandTab tint like game objects
DrawTextP0:
	movem.l	d2-d3/a1-a3,-(sp)
	lea	Plane0,a1
DrawTextGo:
	WAITBLT
	move.w	d1,d2
	lsl.w	#5,d2			; y*32
	move.w	d1,d3
	lsl.w	#3,d3			; y*8
	add.w	d3,d2			; y*40
	add.w	d0,d2			; + byte column
	ext.l	d2
	add.l	d2,a1			; a1 -> first glyph's top-left byte
	lea	Font,a3
```

- `movem.l d2-d3/a1-a3,-(sp)` — callee-saves the registers it's about
  to trash. Callers lean on this: the title/HUD code fires off a dozen
  `DrawText` calls without reloading scratch regs.
- Two entry points, one body: `DrawText` targets plane 1 (plain white
  text), `DrawTextP0` targets plane 0, where the copper's `BandTab`
  colour bands apply — that's how the title screen's `M+`/`S+` legend
  tokens come out tinted while the descriptions next to them stay
  white. Only the base plane differs; everything from `DrawTextGo` on
  is shared.
- `WAITBLT` — spin until the blitter is idle. Text is CPU-drawn, so why
  wait? Because the plane is usually **cleared by the blitter first**
  (`ClearRect` / `ClearGamePlanes` run a blit over plane 1). If the CPU
  started poking glyphs while that clear was still in flight, the blitter
  would erase them a moment later. `WAITBLT` is the fence between the
  blitter clear and the CPU draw.
- The address math is the classic Amiga `y*40` built from shifts:
  `y*40 = y*32 + y*8`, i.e. `(y<<5) + (y<<3)`. There's no multiply
  instruction in the hot path — two shifts and an add. Then `+ d0` adds
  the byte column, `ext.l` widens the 16-bit offset to 32 for the
  address add, and `add.l d2,a1` gives the byte address of the first
  glyph's top scanline.
- `lea Font,a3` — base of the 8x8 font. (Plain `lea`, not `(pc)`,
  because `Font` sits in the code section and is reachable directly.)

## `DrawText` — the per-character loop

```asm
.ch	moveq	#0,d2
	move.b	(a0)+,d2		; next char
	beq.s	.done			; nul terminates
	sub.w	#32,d2			; font starts at ' ' (ASCII 32)
	lsl.w	#3,d2			; index * 8 bytes/glyph
	lea	(a3,d2.w),a2		; a2 -> this glyph's 8 bytes
	move.b	(a2)+,(a1)
	move.b	(a2)+,40(a1)
	move.b	(a2)+,80(a1)
	move.b	(a2)+,120(a1)
	move.b	(a2)+,160(a1)
	move.b	(a2)+,200(a1)
	move.b	(a2)+,240(a1)
	move.b	(a2)+,280(a1)
	addq.l	#1,a1			; next char, one byte right (8px)
	bra.s	.ch
.done	movem.l	(sp)+,d2-d3/a1-a3
	rts
```

- `moveq #0,d2` then `move.b (a0)+,d2` — zero-extend the character byte
  into a word so the arithmetic below is clean. `beq.s .done` catches
  the nul terminator (a zero byte after zero-extension).
- `sub.w #32,d2` — the font table begins at ASCII 32 (space), so
  subtracting 32 turns a character code into a glyph index. `lsl.w #3`
  multiplies by 8 (bytes per glyph). `lea (a3,d2.w),a2` points at the
  glyph.
- The eight unrolled `move.b` writes are the whole render: one font byte
  per scanline, stepped down the bitplane by 40 bytes each (`(a1)`,
  `40(a1)`, `80(a1)` … `280(a1)` = rows 0..7). Unrolled because it's
  faster than a loop and eight `move.b`s with fixed displacements are
  trivially encodable. `280` is the largest offset; it fits the 68000's
  8-bit indexed... no — these are *address-register indirect with
  displacement* (`d16(An)`), which allows a full 16-bit displacement, so
  `280(a1)` is fine. (Contrast the cursor poke in `DrawNameLine`, which
  uses the *indexed* mode `d8(An,Rn)` capped at 8 bits and therefore has
  to fold its offset into the register — see
  [dive-hiscore.md](dive-hiscore.md).)
- `addq.l #1,a1` advances one byte = 8 pixels = one character cell to
  the right, then loops.

### What it deliberately doesn't do

- **No OR-merge.** Each `move.b` *overwrites* the destination byte, it
  doesn't OR into it. So glyphs stamp a clean 8x8 cell (drawing a space
  blanks the cell), but text can't overlap other plane-1 content without
  erasing it. Fine here — plane 1 is text-only.
- **No clipping and no bounds checks.** x is trusted to be 0..39, y such
  that `y*40 + 7*40` stays in-plane. A bad coordinate scribbles into
  whatever follows `Plane1`. Callers just pass sane constants.
- **No lowercase, fixed 8px advance.** The font only has a subset of
  ASCII (see below), and every glyph is one byte wide — monospaced by
  construction.

## The font format

```asm
Font:
	dcb.b	8,0			; 32 space
	dc.b	$18,$18,$18,$18,$18,$00,$18,$00	; 33 !
	dcb.b	8*9,0			; 34-42
	dc.b	$00,$18,$18,$7e,$18,$18,$00,$00	; 43 +
	dcb.b	8*2,0			; 44-45
	dc.b	$00,$00,$00,$00,$00,$18,$18,$00	; 46 .
	dcb.b	8,0			; 47 /
	dc.b	$3c,$66,$6e,$76,$66,$66,$3c,$00	; 0
	...
	dc.b	$18,$3c,$66,$66,$7e,$66,$66,$00	; A
```

Each glyph is **8 bytes = 8 rows**, MSB is the leftmost pixel. Read the
bits of `A` as `.`=0 `#`=1:

```
$18  ...##...
$3c  ..####..
$66  .##..##.
$66  .##..##.
$7e  .######.
$66  .##..##.
$66  .##..##.
$00  ........
```

The table runs contiguously from ASCII 32, so glyph *n* is at
`Font + (n-32)*8`. Unused codes (most of 34–45, `/`, the gap after `9`,
etc.) are filled with `dcb.b …,0` — blank glyphs — so any character in
range renders *something* (usually blank) rather than reading past a
short table. Coverage is space, `!`, `+`, `.`, `:`, `=`, digits `0-9`,
and uppercase `A-Z` (`:` is used by the HUD `WAVE:n` counter, `+` by
the `M+`/`S+` power-up texts — it was added when a power-up rendered
with an invisible plus sign out of the blank-slot pool). That's
exactly why high-score names are uppercased and restricted to
`A-Z 0-9 space`.

## `DrawText2x` — double size via nibble doubling

The title uses a 2x renderer for the big "SPACE INVADERS". Same setup,
but each source row becomes **two rows**, and each source *nibble*
becomes a full byte, so one 8x8 glyph paints a 16x16 block.

```asm
	lea	Font,a3
	lea	NibExp(pc),a4
.ch	moveq	#0,d2
	move.b	(a0)+,d2
	beq.s	.done
	sub.w	#32,d2
	lsl.w	#3,d2
	lea	(a3,d2.w),a2
	moveq	#8-1,d3			; 8 source rows
.row	moveq	#0,d2
	move.b	(a2)+,d2		; one font row
	move.w	d2,d4
	lsr.w	#4,d4			; high nibble (left 4 px)
	move.b	(a4,d4.w),(a1)		; -> 8 px, top output row
	move.b	(a4,d4.w),40(a1)	; -> same, second output row
	and.w	#$0f,d2			; low nibble (right 4 px)
	move.b	(a4,d2.w),1(a1)		; -> next byte over
	move.b	(a4,d2.w),41(a1)
	lea	80(a1),a1		; down two scanlines
	dbf	d3,.row
	lea	-638(a1),a1		; back to top, 2 bytes right
	bra.s	.ch
```

- `NibExp` is a 16-entry lookup that **doubles every bit** of a 4-bit
  value into an 8-bit value: bit pattern `abcd` → `aabbccdd`. So a
  4-pixel nibble stretches to 8 pixels horizontally.

  ```asm
  NibExp:
  	dc.b	$00,$03,$0c,$0f,$30,$33,$3c,$3f
  	dc.b	$c0,$c3,$cc,$cf,$f0,$f3,$fc,$ff
  ```

  e.g. `%0110` (index 6) → `$3c` = `%00111100`.
- Each source row's 8 bits are split into two nibbles. The **high**
  nibble (`lsr.w #4`) is the left 4 pixels → expands to the left output
  byte `(a1)`; the **low** nibble (`and.w #$0f`) is the right 4 pixels →
  the byte one column over, `1(a1)`. Vertical doubling is just writing
  each expanded byte twice, at `(a1)` and `40(a1)` (one row down).
- `lea 80(a1),a1` steps down **two** scanlines per source row (2x
  vertical). After 8 source rows that's `8*80 = 640` bytes.
- `lea -638(a1),a1` rewinds: `640 - 638 = 2`, i.e. back to the glyph's
  top row and **2 bytes (16px) to the right** — the width of one 2x
  character. Then the next character.

So `DrawText2x` is `DrawText` with two multiplications baked in: a
horizontal one done by table (`NibExp`) and a vertical one done by
writing each row twice.

## The HUD: `DrawText` in use

Everything above is the *engine*. The in-game HUD is the clearest example
of driving it. The top status line — `SCORE nnnnnn   HI nnnnnn   WAVE:n` —
is split across two routines: `DrawHud` paints the static labels (and the
wave counter) once per wave, and `RenderScores` repaints just the numbers
when they change.

### `DrawHud` — the static parts, once per wave

```asm
DrawHud:
	lea	TxtScore(pc),a0
	moveq	#2,d0			; byte column 2
	moveq	#4,d1			; pixel row 4
	bsr	DrawText
	lea	TxtHi(pc),a0
	moveq	#22,d0
	moveq	#4,d1
	bsr	DrawText
	; WAVE:n on the right (redrawn each wave, plane1 is cleared first)
	lea	StrBuf,a0
	lea	TxtWave(pc),a1
.cpw	move.b	(a1)+,(a0)+		; copy "WAVE:" into StrBuf
	bne.s	.cpw
	subq.l	#1,a0			; back over the nul, append digits here
	move.w	Level,d0
	addq.w	#1,d0			; wave = Level+1
	bsr	WaveToStr
	lea	StrBuf,a0
	moveq	#32,d0			; byte column 32 (right edge)
	moveq	#4,d1
	bsr	DrawText
	st	ScoreDirty
	st	HiDirty
	rts
```

- The whole HUD sits on **pixel row 4** (`d1=4`), the labels at fixed
  **byte columns**: `SCORE` at 2, `HI` at 22, `WAVE:` at 32. Remember
  `DrawText` takes x already divided by 8, so these are pixel x = 16, 176,
  256. There's no clipping, so the layout is hand-placed to not collide:
  `SCORE` + its 6 digits (col 8) run to col 13, `HI` + digits (col 25) run
  to col 30, and `WAVE:` (5 chars, cols 32-36) leaves cols 37-39 for up to
  3 wave digits — 40-byte row, everything fits with margin.
- **The wave counter is built inline.** `Level` is a plain binary word
  (0-based), so it can't go through `BCDToStr` like the scores. The code
  copies the literal `"WAVE:"` into `StrBuf`, rewinds `a0` one byte to sit
  *on* the terminating nul (so the number overwrites it), then
  `WaveToStr` appends the decimal of `Level+1` and re-terminates. One
  string, one `DrawText`.
- **Why redraw the label every wave** instead of once at game start?
  `WaveEnter` clears plane 1 wholesale (`ClearGamePlanes` blits both game
  planes to zero) before calling `DrawHud`, so the labels are wiped each
  wave and must be restamped. That whole-plane clear is also why the wave
  number needs **no dirty flag or padding** — the field is blank before
  each draw, so a shrinking string (e.g. wave 10 → a new game's wave 1)
  can't leave a stale trailing digit behind.
- The two `st` writes at the end set `ScoreDirty`/`HiDirty` to `$ff` so
  the *next* `RenderScores` repaints the numbers — `DrawHud` itself only
  drew labels.

### `WaveToStr` — binary word to decimal

```asm
; d0.w = value (0..999), a0 = dest string (advances, nul-terminated)
; decimal, leading zeros suppressed. Clobbers d0-d2.
WaveToStr:
	and.l	#$ffff,d0
	cmp.l	#999,d0			; clamp for the fixed 3-digit field
	bls.s	.ok
	move.l	#999,d0
.ok	moveq	#0,d2			; d2 = have we emitted a digit yet
	divu	#100,d0
	move.w	d0,d1			; quotient low word = hundreds
	clr.w	d0
	swap	d0			; d0 = remainder 0..99
	tst.w	d1
	beq.s	.noh			; suppress a leading-zero hundreds
	add.b	#'0',d1
	move.b	d1,(a0)+
	st	d2			; a digit has now been emitted
.noh	divu	#10,d0
	move.w	d0,d1			; tens
	clr.w	d0
	swap	d0			; d0 = ones
	tst.b	d2
	bne.s	.pt			; already printing -> always emit tens
	tst.w	d1
	beq.s	.not			; else suppress a leading-zero tens
.pt	add.b	#'0',d1
	move.b	d1,(a0)+
.not	add.b	#'0',d0
	move.b	d0,(a0)+		; ones always emitted
	clr.b	(a0)
	rts
```

- `divu #100,d0` puts the **quotient in the low word, remainder in the
  high word** of `d0`. So `move.w d0,d1` grabs the hundreds digit, then
  `clr.w d0` / `swap d0` shifts the remainder down into the low word for
  the next divide. Same trick again for tens vs ones.
- **Leading-zero suppression** is the `d2` flag. It starts 0; a digit is
  only skipped while `d2` is still 0 *and* the digit is 0. The moment any
  non-zero digit prints, `d2` goes `$ff` and every following place is
  emitted unconditionally (so wave 10 shows `10`, not `1`). The ones place
  is always emitted, so wave 0/1 still renders a `0`/`1` rather than an
  empty string.
- The `#999` clamp guards the fixed 3-digit field: `divu` by 100 of a
  value ≥ 1000 would leave a two-digit quotient in the hundreds place and
  scribble an extra byte. Nobody clears 999 waves, but the clamp keeps the
  output width bounded regardless.

### `RenderScores` — repaint only what changed

```asm
RenderScores:
	tst.b	ScoreDirty
	beq.s	.nos
	clr.b	ScoreDirty
	lea	StrBuf,a0
	move.l	Score,d0
	bsr	BCDToStr		; BCD score -> ASCII
	lea	StrBuf,a0
	moveq	#8,d0			; byte column 8, right after "SCORE "
	moveq	#4,d1
	bsr	DrawText
.nos	tst.b	HiDirty
	beq.s	.noh
	...				; same for HiScore at column 25
.noh	rts
```

- `RenderScores` runs **every frame** in `PlayState`, but does nothing
  unless a dirty flag is set. `AddScore` sets `ScoreDirty` (and `HiDirty`
  if a new record) exactly when the number changes, so the CPU only
  restamps 6 glyphs on the frames a score actually ticked — the rest of
  the time it's two `tst.b`/`beq` and out.
- The scores go through `BCDToStr` (next section); the wave counter went
  through `WaveToStr` above. Both end as nul-terminated strings that
  `DrawText` renders identically — the renderer neither knows nor cares
  where the digits came from.

## Adjacent: `BCDToStr`

Text usually arrives as a literal string, but scores are 6-digit BCD
longs. `BCDToStr` renders one into a nul-terminated ASCII string that
`DrawText` then draws — it rotates the packed nibbles out one at a time
and adds `'0'`. It's covered where the scoring lives, in
[dive-bullet.md](dive-bullet.md); the high-score table's
score+name string building leans on the fact that it leaves the
destination pointer sitting on the terminating nul (see
[dive-hiscore.md](dive-hiscore.md)).
