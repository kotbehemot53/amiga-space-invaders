# Deep dive: `MoveBullet` + BCD scoring

*Source: `main.asm`, labels `MoveBullet`, `AddScore`, `BCDToStr`.
Runs every frame from `PlayState`, between `EraseShots` and
`DrawShots`.*

This routine is the busiest intersection in the game: movement, three
different collision systems (bounding box, grid lookup, pixel test),
score bookkeeping, and the site of the project's best bug. Worth
reading slowly.

## Context: the erase → move → draw contract

`PlayState` calls, in order: `EraseShots` (removes bullet/bomb pixels
from plane 0), `MoveFormation`, `PlayerControl`, **`MoveBullet`**,
`MoveBombs`, `DropBombs`, `UfoLogic`, `DrawShots` (draws survivors).
Because the bullet is *already erased* when this routine runs, any
path that kills it can simply clear the active flag and walk away — no
cleanup, the pixels are already gone. And `TestPixel` (the shield
check) can't be fooled by the bullet's own pixels, because they aren't
on screen at test time. The frame order is the invariant that makes
every individual routine simple.

## Movement and the top edge

```asm
MoveBullet:
	tst.w	BulAct
	beq	.done
	move.w	BulY,d1
	sub.w	#BULSPD,d1
	cmp.w	#16,d1
	bgt.s	.fly
	clr.w	BulAct			; off the top
	bra	.done
.fly	move.w	d1,BulY
	move.w	BulX,d0
```

- `tst.w BulAct` / `beq .done` — no bullet in flight, nothing to do.
  One live player bullet maximum, like the arcade — that limit *is*
  the game's difficulty curve (you can't spray; every shot must land
  before the next).
- `sub.w #BULSPD,d1` — up is smaller y; speed is 4 px/frame.
- `cmp.w #16,d1` / `bgt.s .fly` — y ≤ 16 is the HUD score line;
  reaching it means the shot missed everything. `clr.w BulAct`
  deactivates; done. Note the *new* y is only committed to memory
  (`move.w d1,BulY`) on the survive path.

## Collision 1: the UFO (box test)

```asm
	; --- vs UFO
	tst.w	UfoAct
	beq.s	.noufo
	cmp.w	#32,d1
	bgt.s	.noufo
	move.w	UfoX,d2
	sub.w	d0,d2
	neg.w	d2
	addq.w	#4,d2			; bullet vs ufo x window
	cmp.w	#24,d2
	bhi.s	.noufo
```

- Cheap rejections first: no UFO active, or bullet not yet in the UFO's
  altitude band (y ≤ 32).
- The x test computes `bullet_x - ufo_x + 4` and asks if it's within
  0–24: `sub`/`neg` produce `d0 - d2` into d2 (the operand order of
  `sub` is backwards from what you'd want, hence the negate), `+4`
  shifts the window so a bullet up to 4 px left of the UFO's origin
  still counts, and…
- `cmp.w #24,d2` / `bhi.s` — **bhi = branch if higher, an *unsigned*
  compare.** If the subtraction went negative, the unsigned view sees
  a huge number (> 24) and rejects. One unsigned compare implements
  `-4 <= dx < 20` — the classic range-check-with-one-branch trick
  (`(unsigned)(x - lo) < span`), same as you'd write in C.

```asm
	clr.w	UfoAct
	clr.w	BulAct
	bsr	HideUfoSpr
	bsr	SfxUfoHit
	bsr	Random
	and.w	#3,d0
	MUL4	d0
	lea	UfoPts(pc),a0
	move.l	(a0,d0.w),d0
	bsr	AddScore
	bra	.done
```

Hit: kill both objects, hide the hardware sprite, sound, then score —
`Random & 3` picks one of four BCD values from `UfoPts`
(50/100/150/300, mystery bonus like the original). Note `bsr SfxUfoHit`
runs *before* the random score draw here — safe, because nothing in
d0–d4 is live across it. Contrast with the alien path below.

## Collision 2: the formation (grid math, no pixels)

```asm
	; --- vs alien formation (grid test)
	move.w	FormY,d2
	cmp.w	d2,d1
	blt	.noalien
	move.w	d2,d3
	add.w	#ROWS*CELLH,d3
	cmp.w	d3,d1
	bge	.noalien
	move.w	d0,d3
	sub.w	FormX,d3
	blt	.noalien
	cmp.w	#COLS*CELLW,d3
	bge.s	.noalien
```

Four half-open range checks: `FormY <= y < FormY+80` and
`0 <= x-FormX < 176`. Mind `cmp.w d2,d1`: 68k compare computes
*destination minus source* (`d1 - d2`), so `blt` after it means
"branch if y < FormY" — reading cmp operands backwards is the most
common 68k reading mistake.

```asm
	move.w	d1,d4
	sub.w	d2,d4
	lsr.w	#4,d4			; row
	lsr.w	#4,d3			; col
	move.w	d4,d2
	mulu	#COLS,d2
	add.w	d3,d2
	lea	AlienTab,a0
	tst.b	(a0,d2.w)
	beq.s	.noalien
```

Inside the box, position → cell is two shifts: `(y-FormY)/16` = row,
`(x-FormX)/16` = col (cells are 16×16). Then `row*11 + col` indexes
`AlienTab` — here the multiply *is* a `mulu` because 11 isn't a power
of two and this path runs at most once per frame. `tst.b` asks "is
that alien alive?" — dead cells are holes the bullet flies through,
which is why shots visibly thread gaps in the formation.

Nothing here reads the screen. The formation is *data*; plane 0 is
merely its projection. Compare with the shields below, where it's the
other way round.

## The kill — and the register-clobber lesson

```asm
	; kill it
	clr.b	(a0,d2.w)
	subq.w	#1,AlienCnt
	clr.w	BulAct
	bsr	SetMoveDelay		; only d0/d1 harmed, col/row live
	; explosion gfx into the cell
	move.w	d4,-(sp)
	move.w	d3,d0
	lsl.w	#4,d0
	add.w	FormX,d0
	move.w	d4,d1
	lsl.w	#4,d1
	add.w	FormY,d1
	lea	ExplGfx,a0
	bsr	BlitCell
	move.w	(sp)+,d4
	; score by row
	lea	RowPts(pc),a0
	move.w	d4,d0
	MUL4	d0
	move.l	(a0,d0.w),d0
	bsr	AddScore
	bsr	SfxExplode		; last: PlaySound eats d0-d4
```

- `clr.b (a0,d2.w)` — the alien dies by one byte in a table.
- `bsr SetMoveDelay` — fewer aliens → shorter march delay → the
  speed-up. The comment `only d0/d1 harmed, col/row live` is a register
  *contract*: this call is safe because d3 (col) and d4 (row) survive
  it.
- `move.w d4,-(sp)` … `move.w (sp)+,d4` — d4 is pushed around
  `BlitCell` because that routine's address math trashes d2–d5. The
  stack is the spill slot; there are no callee-saved guarantees except
  the ones you write yourself.
- `bsr BlitCell` — cookie-cut the explosion into the cell (see the
  blitter deep dive). It stays until the next march tick's band clear
  wipes it — a free-of-charge decay timer.
- Score: `RowPts[row]` — rows are worth 30/20/20/10/10 from top to
  bottom, matching species.
- **`bsr SfxExplode` last, and the war story.** `SfxExplode` tail-calls
  `PlaySound`, whose argument convention is d0=channel, d1=length,
  d2=period, d3=volume, d4=duration — it *loads all five registers*.
  In the first version of this code the sound call sat right after
  `SetMoveDelay`, i.e. before the explosion/score code — so d3 and d4
  (col/row) were silently replaced by volume 55 and duration 14. The
  explosion blitted at garbage coordinates and, worse,
  `RowPts + 14*4` read *past the table* — neighbouring pointer data
  interpreted as BCD points. Score: +40 000-ish per kill. In a
  high-level language the compiler's register allocator makes this
  entire class of bug impossible; in assembly, **every `bsr` is a
  potential clobber and the comments are your type system.** The fix
  is ordering, and the comment now standing guard.

```asm
	; wave cleared?
	tst.w	AlienCnt
	bne	.done
	addq.w	#1,Level
	bra	WaveEnter
```

Last alien → next wave. Note `bra`, not `bsr`: `WaveEnter` rebuilds the
whole play state and returns to `PlayState`'s caller directly. That's
also why `PlayState` re-checks `GameState` right after `bsr MoveBullet`
— the world may have been rebuilt under it mid-frame.

## Collision 3: the shields (the screen is the collision map)

```asm
	; --- vs shields (pixel test)
	move.w	BulY,d1
	cmp.w	#SHIELDY,d1
	blt.s	.done
	cmp.w	#SHIELDY+16,d1
	bge.s	.done
	move.w	BulX,d0
	bsr	TestPixel
	beq.s	.done
	clr.w	BulAct
	move.w	BulX,d0
	move.w	BulY,d1
	bsr	BlastShield
.done	rts
```

Shields erode pixel by pixel, so no data structure mirrors them — the
authoritative state is plane 0 itself. Inside the shield altitude band,
`TestPixel` reads the screen byte under the bullet and ANDs it with the
bullet's 2-pixel mask; non-zero = something's there. On a hit,
`BlastShield` ANDs an inverted 8×6 blob mask into the plane — chewing a
hole. Subsequent bullets fly *through* the hole because the test reads
the same pixels the blast removed. Damage model, permanence and
collision all fall out of one bitmap — the 1978 original worked exactly
this way.

(The y-band check is what keeps this honest: only shield pixels live at
those heights during play, so "any pixel set" can't false-positive on
aliens or text — aliens live higher, text lives in another plane.)

## `AddScore` / `BCDToStr` — decimal arithmetic in hardware

```asm
AddScore:
	move.l	d0,TmpBCD
	lea	TmpBCD+4,a0
	lea	Score+4,a1
	move.w	#4,ccr			; X=0, Z=1 for abcd chain
	abcd	-(a0),-(a1)
	abcd	-(a0),-(a1)
	abcd	-(a0),-(a1)
	abcd	-(a0),-(a1)
	st	ScoreDirty
```

Scores are **binary-coded decimal**: `$00031240` *is* "031240", one
digit per nibble. Why: the score is redrawn every time it changes, and
BCD→ASCII is trivial nibble-peeling — no division by 10 anywhere
(the 68000's `divu` costs ~140 cycles *each*).

- `move.w #4,ccr` — write the condition-code register directly:
  X (extend/carry) = 0, Z = 1. `abcd` adds *with* X, and — unusually —
  only ever *clears* Z, never sets it, so a whole multi-byte chain can
  be tested for zero afterwards. Both flags must be preseeded.
- `abcd -(a0),-(a1)` — "add BCD with extend": adds one byte = two
  decimal digits, digit-correcting the result (9+1 becomes 10, carry
  out, not $0A). The only addressing mode it accepts is predecrement
  on both operands — the instruction was *designed* for exactly this
  loop shape: point past the least significant byte of both numbers
  and chain from right to left, X carrying between bytes. Four of them
  = 8 digits (we display 6; the top byte is headroom).
- `st ScoreDirty` — set a flag byte to $ff; `RenderScores` redraws HUD
  digits only when this is set. Classic dirty-flag pattern.

```asm
BCDToStr:
	lsl.l	#8,d0
	moveq	#6-1,d2
.dig	rol.l	#4,d0
	move.b	d0,d1
	and.b	#$0f,d1
	add.b	#'0',d1
	move.b	d1,(a0)+
	dbf	d2,.dig
	clr.b	(a0)
```

Rendering: `lsl.l #8` discards the unused top byte so the first
significant digit sits at the very top of the register; then six times:
`rol.l #4` rotates the *next* nibble around into the low bits, mask it,
add ASCII `'0'`, store. The rotate (rather than shift) means the
register cycles rather than drains, so no second working register is
needed. Terminate with a NUL for `DrawText`. Ten instructions,
no division — this is why the score is BCD.

One consequence to respect everywhere: point values in `RowPts`/`UfoPts`
are BCD literals (`dc.l $300` = "300 points"), and mixing them with
binary arithmetic produces garbage. Comparisons (`cmp.l` for the
high-score check) still work, because BCD ordering matches unsigned
binary ordering byte-wise. Handy corruption canary: every legit score
is a multiple of 10 — a score ending in anything else means someone
scribbled on memory (that's exactly how the clobber bug was caught).
