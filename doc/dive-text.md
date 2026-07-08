# Deep dive: `DrawText`, `DrawText2x`, and the font

*Source: `main.asm`, labels `DrawText`, `DrawText2x`, `NibExp`, `Font`.
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
plane 1 contributes (index bit 1). Text never touches plane 0 (game
objects) or plane 2 (starfield).

A pixel at (x, y) lives at byte `y*40 + x/8`, bit `7 - (x & 7)`.
`DrawText` sidesteps the bit math entirely by taking its x already
divided by 8 — a **byte column** — so every glyph lands on an 8-pixel
boundary and each character is exactly one byte wide.

## `DrawText` — the setup

```asm
; a0=nul-terminated string, d0=byte x (x/8), d1=y
DrawText:
	movem.l	d2-d3/a1-a3,-(sp)
	WAITBLT
	lea	Plane1,a1
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
	dcb.b	8*12,0			; 34-45
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
short table. Coverage is space, `!`, `.`, `=`, digits `0-9`, and
uppercase `A-Z`. That's exactly why high-score names are uppercased and
restricted to `A-Z 0-9 space`.

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

## Adjacent: `BCDToStr`

Text usually arrives as a literal string, but scores are 6-digit BCD
longs. `BCDToStr` renders one into a nul-terminated ASCII string that
`DrawText` then draws — it rotates the packed nibbles out one at a time
and adds `'0'`. It's covered where the scoring lives, in
[dive-bullet.md](dive-bullet.md); the high-score table's
score+name string building leans on the fact that it leaves the
destination pointer sitting on the terminating nul (see
[dive-hiscore.md](dive-hiscore.md)).
