# Deep dive: `BuildCopper` — generating a copper list at runtime

*Source: `main.asm`, label `BuildCopper`; consumed every frame by the
Copper from `CopBuf` (chip RAM).*

## What a copper list even is

The Copper is a co-processor inside Agnus that re-executes a program
from chip RAM every frame, synchronised to the beam. Its instructions
are two 16-bit words each:

- **MOVE**: first word = target register offset (even, e.g. `$0180` =
  COLOR00), second word = value. Writes the value into the register.
- **WAIT**: first word = beam position with bit 0 **set** (that's how
  the hardware tells WAIT from MOVE), second word = a compare mask,
  `$fffe` meaning "match position exactly". Execution pauses until the
  beam gets there.
- End of list: `WAIT $ffff,$fffe` — a position that never arrives.

A copper list is therefore *data that acts like code*. This routine
writes that data with the CPU once at startup; after that the CPU never
touches the display again (except one twinkle word — see below).

Register `a0` is the write cursor into `CopBuf` for the entire routine;
every `(a0)+` stores one word and advances.

## Part 1: bitplane pointers

```asm
	lea	CopBuf,a0

	; bitplane pointers
	move.w	#$00e0,d2
	move.l	#Plane0,d1
	bsr.s	.ptr
	move.l	#Plane1,d1
	bsr.s	.ptr
	move.l	#Plane2,d1
	bsr.s	.ptr
	bra.s	.spr
.ptr	move.w	d2,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d2
	move.w	d2,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d2
	rts
```

Why this exists: the hardware's bitplane pointer registers are
*consumed* during the frame — Agnus increments them as it fetches each
row. Nothing resets them; if no one reloads the pointers, frame 2
displays garbage from past the end of the buffer. Convention: the
copper list itself reloads them at the top of every frame.

- `move.w #$00e0,d2` — `$e0` is BPL1PTH, the high word of bitplane 1's
  pointer. Each pointer is 32 bits split across two 16-bit registers
  (high word at `$e0`, low word at `$e2`), because the whole chipset
  speaks 16-bit.
- `move.l #Plane0,d1` — the 32-bit address of the first bitplane
  buffer. This is a relocated constant: the OS loader decided where
  `Plane0` really is (somewhere in chip RAM) and patched the value.
- `bsr.s .ptr` — emit one pointer's worth of copper MOVEs. The helper
  is called three times, once per plane. (`bra.s .spr` afterwards jumps
  over the helper's body — subroutines embedded mid-flow like this are
  normal in assembly.)

Inside `.ptr` — this emits **two MOVE instructions** (4 words):

- `move.w d2,(a0)+` — first word of a MOVE: the register offset
  (`$e0`). Bit 0 is clear, so the Copper decodes it as MOVE.
- `swap d1` — exchange the halves of d1: now the **high** 16 bits of
  the plane address sit in the low word, where `move.w` can reach them.
  This is the standard trick for splitting a longword.
- `move.w d1,(a0)+` — second word of the MOVE: the value (address high
  word). One complete copper instruction emitted: *MOVE addr.hi →
  BPLxPTH*.
- `addq.w #2,d2` — next register (`$e2`, the low-word half).
- `move.w d2,(a0)+` / `swap d1` (restores original order) /
  `move.w d1,(a0)+` — second MOVE: *addr.lo → BPLxPTL*.
- `addq.w #2,d2` — leave d2 pointing at the next plane's PTH (`$e4`),
  so the next call continues seamlessly.

## Part 2: sprite pointers

```asm
.spr	lea	SprPtrTab(pc),a1
	move.w	#$0120,d2
	moveq	#8-1,d7
.sprl	move.l	(a1)+,d1
	...same 4-word emission...
	dbf	d7,.sprl
```

Same idea, but a loop: 8 sprite channels, pointer registers starting at
`$120`, addresses taken from `SprPtrTab` (player sprite, UFO sprite,
and a shared 8-byte `BlankSpr` for the six unused channels — sprite
DMA is on globally, so *every* channel needs a valid pointer, even the
idle ones).

- `moveq #8-1,d7` — loop counter. `dbf` loops "until −1", so N
  iterations need an initial value of N−1. Writing `#8-1` instead of
  `#7` documents the intent; the assembler folds it.
- `move.l (a1)+,d1` — fetch next sprite's address, post-increment
  walks the table.
- `dbf d7,.sprl` — decrement d7, branch back while it hasn't wrapped
  below zero. The canonical 68k loop.

## Part 3: palette — a data-driven run of MOVEs

```asm
	lea	PalTab(pc),a1
.pal	move.w	(a1)+,d0
	bmi.s	.paldone
	move.w	d0,(a0)+
	move.w	(a1)+,(a0)+
	bra.s	.pal
.paldone
```

`PalTab` holds `register, value` pairs terminated by `$ffff`.

- `move.w (a1)+,d0` — read the register offset. All real chipset
  offsets are < `$200`, i.e. positive as signed 16-bit.
- `bmi.s .paldone` — "branch if minus": `move` set the N flag from the
  value, and the `$ffff` terminator is negative. A sentinel test with
  zero extra instructions.
- `move.w d0,(a0)+` then `move.w (a1)+,(a0)+` — emit the MOVE: offset
  word, then value word copied straight from the table,
  memory-to-memory.

## Part 4: the twinkle hook

```asm
	move.w	#$0188,(a0)+		; COLOR04
	move.l	a0,TwinkPtr
	move.w	#$0666,(a0)+
```

One more palette MOVE, written manually because of the middle line:
the address where the *value* word lands is saved to `TwinkPtr`.
Every frame, `TwinkleStars` writes a new colour to that address —
the CPU edits the copper program in place while the Copper keeps
executing it. Cheapest possible animation: one `move.w` per frame
makes all stars pulse.

## Part 5: the gradient and colour bands

```asm
	lea	BandTab(pc),a2
	moveq	#0,d4			; screen line 0..252 step 4
.grad	move.w	d4,d0
	add.w	#44,d0			; raster line
	cmp.w	#256,d0
	bne.s	.nocross
	move.w	#$ffdf,(a0)+		; cross line 255
	move.w	#$fffe,(a0)+
.nocross
	move.w	d0,d1
	and.w	#$ff,d1
	lsl.w	#8,d1
	or.w	#$07,d1
	move.w	d1,(a0)+		; WAIT line,hpos 6
	move.w	#$fffe,(a0)+
	cmp.w	(a2),d4			; band change on this line?
	bne.s	.noband
	addq.l	#2,a2
	move.w	#$0182,(a0)+		; COLOR01
	move.w	(a2)+,(a0)+
.noband
	; COLOR00 procedural gradient step: start * (32-i)/32 per channel
	move.w	d4,d5
	lsr.w	#2,d5			; entry index i = 0..63
	moveq	#32,d6
	sub.w	d5,d6			; factor = 32 - i
	bpl.s	.gpos
	moveq	#0,d6			; clamp to 0 for lower two thirds
.gpos	move.w	GradStart,d3
	... (extract R/G/B, mulu factor, lsr #5, reassemble) ...
	move.w	#$0180,(a0)+		; COLOR00
	move.w	d5,(a0)+
	addq.w	#4,d4
	cmp.w	#256,d4
	blt.s	.grad

	move.l	#$fffffffe,(a0)+	; end of copper list
	rts
```

The loop runs 64 times, once per 4 screen lines, and each iteration
emits: one WAIT, optionally one COLOR01 MOVE, and one COLOR00 MOVE.

- `add.w #44,d0` — screen coordinates start at raster line 44 (that's
  where `DIWSTRT $2c81` put the top of the display window; `$2c` = 44).
  All copper WAITs use raster lines, so convert.
- The `cmp.w #256` / `$ffdf,$fffe` pair is the famous **PAL line-256
  problem**: a WAIT instruction physically stores only 8 bits of the
  line number, so positions ≥ 256 can't be expressed directly.
  `$ffdf,$fffe` is a special WAIT for "line 255, rightmost pixel" —
  executing it arms the Copper's internal "we are now past 255" state,
  after which 8-bit line values mean 256+line. It must be emitted
  exactly once, at the crossing. Forget it and the bottom third of the
  gradient executes at the *top* of the screen, rainbow soup.
- Building the WAIT word: take the raster line (`and #$ff` keeps the
  low 8 bits — correct on both sides of the crossing), `lsl #8` moves
  it into the high byte, `or #$07` sets the horizontal position bits
  *including bit 0, which marks the instruction as a WAIT rather than
  a MOVE*. Position 6 is in the horizontal blank, before pixels are
  drawn, so the colour change never tears mid-line. Second word
  `$fffe`: compare all position bits.
- The band check: `BandTab` is a sorted list of `screenline, colour`
  pairs (terminated by an unreachable line `$7fff`). Because a2 only
  advances on a hit, a simple equality against the *next* pending entry
  suffices — a merge of two sorted streams. On a hit, emit
  *MOVE colour → COLOR01* ($182). This is what re-tints all plane-0
  graphics region by region (red aliens up top, green shields below).
- Unconditionally: *MOVE computed value → COLOR00* ($180) — the vertical
  gradient. It is **procedural**: `GradStart` (the current wave's top
  colour) is scaled per channel by `(32 - i)/32`, so the top line is the
  full `GradStart` and it fades to black over the top third (entries
  0..32), black below. `SetGradient` picks `GradStart` from the 24-entry
  `GradStartTab` (`GradStartTab[Level mod 24]`, wave 1 = `$0007`, the
  original blue) and rebuilds the whole list each wave — so every level
  gets a visibly different background.
- `move.l #$fffffffe,(a0)+` — the end sentinel, written as one
  longword (two words: `$ffff` position, `$fffe` mask): wait forever.
  The vertical blank restarts the Copper from the top of `CopBuf`.

## The payoff

Total: ~230 copper instructions, ~920 bytes, generated once. From then
on, per-scanline palette changes, plane pointer refresh and sprite
pointer refresh all cost the CPU **zero cycles per frame**. This is the
Amiga's core design idea: the display is programmable hardware, and the
CPU only edits that program when something actually changes.
