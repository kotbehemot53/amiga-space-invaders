# Deep dive: `DrawAliens` — the formation redraw

*Source: `main.asm`, label `DrawAliens`. Called from `MoveFormation` on
each march tick and from `WaveEnter` once per wave.*

## Strategy first

The formation never moves incrementally. On every march step the code:

1. blitter-clears the whole horizontal band the formation occupies,
2. re-blits every living alien at its freshly computed position.

This trades raw fill work (cheap, the blitter's job) for bookkeeping
(expensive, the CPU's job). There is no per-alien "erase old position"
logic, no dirty rectangles, no overlap edge cases — the band clear also
disposes of explosion debris and stray bullet pixels in the area.
As a bonus, the same loop that redraws also recomputes the formation's
live extents, which the movement code needs for edge bouncing.

## Part 1: clear the band

```asm
DrawAliens:
	; clear the formation band (full width, from FormY-8)
	move.w	FormY,d1
	subq.w	#8,d1			; cover previous position too
	moveq	#0,d0
	moveq	#20,d2			; 20 words = 320px
	move.w	#ROWS*CELLH+16,d3
	; deep formations: never clear into the shield band
	move.w	#SHIELDY,d4
	sub.w	d1,d4
	cmp.w	d4,d3
	ble.s	.hok
	move.w	d4,d3
.hok	lea	Plane0,a1
	bsr	ClearRect
```

- `move.w FormY,d1` / `subq.w #8,d1` — start clearing 8 px *above* the
  formation's current top. Why: when the formation just stepped 8 px
  down, its previous position is 8 px higher, and those pixels must go.
  Rather than track "did we just move down?", the band is simply always
  tall enough to cover both cases (`+16` rows of margin at the bottom
  of the height calculation, `-8` at the top).
- `moveq #0,d0` — x = word column 0 (left edge). `moveq` is the 2-byte
  encoding for loading small constants; you use it wherever the value
  fits in a signed byte.
- `moveq #20,d2` — width: 20 words = 320 px, the full screen width.
  Clearing full width wastes nothing (the blitter is fast) and spares
  us computing the formation's horizontal bounds *before* drawing.
- `move.w #ROWS*CELLH+16,d3` — height: 5 rows × 16 px + 16 margin = 96
  raster lines. The expression is evaluated by the assembler, not at
  runtime — `ROWS*CELLH+16` is documentation that costs nothing.
- The `SHIELDY` clamp: once the surviving rows have marched deep, the
  96-line band would reach past y = 192 and the clear would eat the
  tops of the shields. `192 − band_top` is the tallest clear that stays
  above them; take the minimum. (Deep descents are possible because the
  invasion check in `MoveFormation` is based on the lowest *living*
  row — `LowestRow` scans `AlienTab` backwards — not on the full
  formation height; killing the bottom rows lets the rest march far
  lower before game over.)
- `bsr ClearRect` — D-only blit, minterm $00 (all outputs zero).
  Note this touches only **Plane 0** — text (plane 1) and stars
  (plane 2) physically cannot be harmed, which is the whole point of
  the layer separation.

## Part 2: the scan loop

```asm
	move.w	#$7fff,EdgeMinX
	clr.w	EdgeMaxX
	lea	AlienTab,a2
	moveq	#0,d6			; row
.row	moveq	#0,d5			; col
.col	tst.b	(a2)+
	beq.s	.next
```

- `EdgeMinX = $7fff`, `EdgeMaxX = 0` — classic min/max scan
  initialisation: start with "worse than anything", let the loop tighten.
- `lea AlienTab,a2` — a2 walks the 55-byte alive table linearly.
  Layout is row-major: `row*11 + col`, but the walk never computes
  that — the nested loop order matches memory order, so `(a2)+` visits
  aliens exactly in table order. Index arithmetic exists only where
  *random* access is needed (the bullet collision).
- `tst.b (a2)+` — read the alive flag, set Z if zero, advance the
  pointer *regardless*. The post-increment on a `tst` is load-bearing:
  dead or alive, the cursor must move to the next alien.
- `beq.s .next` — dead alien: skip everything.

## Part 3: per-alien work

```asm
	; live alien: track extents
	move.w	d5,d0
	lsl.w	#4,d0			; col*16
	cmp.w	EdgeMinX,d0
	bge.s	.nomin
	move.w	d0,EdgeMinX
.nomin	cmp.w	EdgeMaxX,d0
	ble.s	.nomax
	move.w	d0,EdgeMaxX
.nomax	add.w	FormX,d0
	move.w	d6,d1
	lsl.w	#4,d1			; row*16
	add.w	FormY,d1
```

- `lsl.w #4,d0` — col × 16: cell size is 16 px, so shifts, not
  multiplies.
- The two compare/store pairs maintain min and max of `col*16` over
  living aliens only. Note they run on the *formation-relative* value,
  before FormX is added — so `EdgeMinX/EdgeMaxX` describe the
  formation's live silhouette independent of where it currently stands.
  `MoveFormation` later asks "would the *living* edge cross the screen
  border?" — so when the outer columns die, the formation marches
  further before turning, exactly like the arcade original.
- `add.w FormX,d0` / same for y — convert to absolute screen pixels.

```asm
	; pick gfx: row type + anim frame
	lea	RowType(pc),a0
	move.b	(a0,d6.w),d2
	ext.w	d2
	lsl.w	#3,d2			; type*8
	move.w	AnimFrame,d3
	add.w	d3,d3
	add.w	d3,d3			; frame*4
	add.w	d3,d2
	lea	AlienGfxTab(pc),a0
	move.l	(a0,d2.w),a0
```

This resolves *which bitmap* to draw — in C:
`gfx = AlienGfxTab[RowType[row]*2 + AnimFrame]`.

- `move.b (a0,d6.w),d2` — `RowType[row]`: byte table `0,1,1,2,2`
  mapping the 5 rows to 3 species (squid / crab / octopus).
- `ext.w d2` — sign-extend byte→word. A byte loaded into a register
  leaves bits 8–15 untouched; before using d2 as an index it must be
  widened. (Values are 0–2, so this is just hygiene — but skipping it
  after some earlier negative byte in d2 would index into the weeds.)
- `lsl.w #3,d2` — type × 8: each type owns two 4-byte pointers
  (frame 0, frame 1) in the table, so the stride per type is 8 bytes.
- `AnimFrame` is 0/1, toggled once per march tick (`eor.w #1` in
  `MoveFormation`); ×4 selects the second pointer of the pair. All 55
  aliens share one frame counter — the whole formation snaps between
  poses in unison, which reads as the classic invader "march".
- `move.l (a0,d2.w),a0` — fetch the graphic's address. a0 now points
  at 8 rows × 2 words of chip-RAM image data.

```asm
	movem.l	d5/d6/a2,-(sp)
	bsr	BlitObj16
	movem.l	(sp)+,d5/d6/a2
.next	addq.w	#1,d5
	cmp.w	#COLS,d5
	blt.s	.col
	addq.w	#1,d6
	cmp.w	#ROWS,d6
	blt.s	.row
	rts
```

- `movem.l d5/d6/a2,-(sp)` — push the three registers the loop still
  needs (col, row, table cursor) in one instruction. `BlitObj16`
  documents that it trashes d2–d5/a1; nobody preserves registers *for*
  you — in assembly the caller and callee split that duty by
  convention, and here the caller pays.
- `bsr BlitObj16` — queue the OR-blit at (d0,d1). It returns without
  waiting for completion; the *next* alien's blit will wait on the
  hardware busy flag inside its own `WAITBLT`. CPU loop bookkeeping and
  blitter fills overlap in time — free parallelism.
- The rest is the two nested counter loops: `col` 0–10, `row` 0–4,
  written with `cmp/blt` rather than `dbf` because the counters are
  also *data* (they become coordinates), and up-counting keeps them
  directly usable.

## Why redraw-everything is the right call here

The numbers: band clear ≈ 0.5 ms of blitter time, 55 object blits
≈ 0.4 ms, total under 1 ms per march tick — and ticks happen at most
once per frame (20 ms), usually far less often. Meanwhile the
alternative (erase each alien at its old spot, redraw at the new one)
would double the blit count *and* require storing per-alien previous
positions, plus special cases when explosions overlap neighbours.

The lesson generalises: when a redraw is cheap and bounded, recomputing
the whole thing beats tracking deltas. The same reasoning that makes
immediate-mode GUIs and React's render model work — discovered here
because the hardware made the "dumb" approach the fast one.
