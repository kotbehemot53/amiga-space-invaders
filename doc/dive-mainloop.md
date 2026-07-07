# Deep dive: the main loop, `WaitVBL` and the state machine

*Source: `main.asm`, labels `MainLoop`, `StateTab`, `WaitVBL`.*

This is the smallest piece of the program and the best place to start,
because it contains three fundamental idioms: busy-wait timing, a jump
table, and hardware-register polling.

## The loop itself

```asm
MainLoop:
	bsr	WaitVBL
	addq.l	#1,Frame
	bsr	UpdateAudio
	bsr	TwinkleStars

	move.w	GameState,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	StateTab(pc),a0
	move.l	(a0,d0.w),a0
	jsr	(a0)

	btst	#6,CIAAPRA		; left mouse button = quit
	bne.s	MainLoop
```

Line by line:

- `bsr WaitVBL` — **b**ranch to **s**ub**r**outine: pushes the return
  address on the stack and jumps. This call *blocks* until the video
  beam reaches the vertical blank. It is the only thing pacing the
  game: everything below runs exactly once per 1/50 s.
- `addq.l #1,Frame` — increment a 32-bit frame counter in memory.
  `addq` is the short-encoded "add quick" for constants 1–8; the
  destination here is a memory address, so this is a read-modify-write
  straight to RAM. `Frame` is the game's clock — animation, blinking
  text and the RNG all derive from it.
- `bsr UpdateAudio` / `bsr TwinkleStars` — housekeeping that must run
  every frame regardless of game state: expiring one-shot sounds,
  wobbling the UFO pitch, cycling the star colour.
- `move.w GameState,d0` — load the current state number (0 = title,
  1 = play, 2 = death, 3 = game over, 4 = wave intro).
- `add.w d0,d0` twice — multiply by 4, because the table stores 4-byte
  pointers. Two adds are faster than a multiply and encode smaller
  than a shift here; you'll see this ×4 idiom everywhere in the file.
- `lea StateTab(pc),a0` — put the *address* of the table into a0.
  The `(pc)` suffix makes it a program-counter-relative reference
  (position-independent, shorter encoding). `lea` never reads memory —
  it's pointer arithmetic only, the `&` operator of assembly.
- `move.l (a0,d0.w),a0` — read a 32-bit value from `a0 + d0`, i.e.
  `StateTab[GameState]`, into a0. Now a0 holds the address of a
  routine. This plus the next line is C's
  `state_handlers[game_state]()`.
- `jsr (a0)` — call through the pointer.
- `btst #6,CIAAPRA` — test bit 6 of the byte at `$bfe001`, which is
  port A of the 8520 CIA chip; bit 6 is the left mouse button, wired
  active-low (0 = pressed). `btst` sets the Z flag to the *inverse* of
  the bit.
- `bne.s MainLoop` — "branch if not equal" really means "branch if
  Z = 0", i.e. the bit was 1, i.e. the button is *not* pressed. So:
  loop forever until left-click, then fall through into `Quit`.
  The `.s` suffix forces a short (8-bit displacement) branch encoding.

## The state table

```asm
StateTab:
	dc.l	TitleState
	dc.l	PlayState
	dc.l	DeathState
	dc.l	OverState
	dc.l	WaveState
```

`dc.l` = "declare constant, long". Five 32-bit routine addresses laid
out back to back — a `switch` statement's jump table, built by hand.
The linker patches the real addresses at load time (these are
relocations; an Amiga executable can load anywhere in RAM).

Changing state anywhere in the game is just
`move.w #ST_OVER,GameState` — the *next* frame dispatches elsewhere.

## `WaitVBL` — the clock

```asm
WaitVBL:
.pass	move.l	VPOSR(a5),d0
	and.l	#$1ff00,d0
	cmp.l	#303<<8,d0
	beq.s	.pass			; already there: wait till gone
.wait	move.l	VPOSR(a5),d0
	and.l	#$1ff00,d0
	cmp.l	#303<<8,d0
	bne.s	.wait
	rts
```

Background: a PAL Amiga draws 312 scanlines per frame, 50 frames per
second. The chipset exposes the beam's current position in two adjacent
registers: `VPOSR` ($dff004) holds the *9th* bit of the line number
(lines go up to 311, needing 9 bits), and `VHPOSR` ($dff006) holds the
low 8 bits of the line plus the horizontal position.

- `move.l VPOSR(a5),d0` — a **32-bit** read starting at $dff004
  captures both registers in one instruction: d0 now holds
  `VPOSR:VHPOSR` as `....xxxV VVVVVVVV Vhhhhhhh h...` conceptually —
  bit 16 is V8, bits 15–8 are V7–V0, bits 7–0 horizontal.
- `and.l #$1ff00,d0` — mask out everything except the full 9-bit line
  number (bit 16 + bits 15–8). Without the `$10000` part of the mask,
  line 47 and line 303 would look identical (47 + 256 = 303) and the
  game could trigger mid-picture.
- `cmp.l #303<<8,d0` — compare against line 303, pre-shifted left 8 to
  sit in the same bit positions the mask left populated. Line 303 is
  safely below the visible display (which ends at line 300), i.e.
  inside the vertical blank.
- The **two loops** are the subtle part. The second loop alone ("wait
  until line == 303") has a bug: if the game logic of the previous
  frame finished in less than one scanline (64 µs — possible on the
  title screen), the beam would *still* be on line 303 and the loop
  would fall straight through, running the game twice in one frame.
  The first loop ("while we're on 303, spin") guarantees we leave the
  line before waiting for its next arrival. Together they mean:
  *return exactly once per frame, at the same beam position*.
- `rts` — pop the return address, jump back.

There is no `sleep()`. The CPU burns cycles polling — and that's fine,
because there is nothing else it could possibly be doing.

## Why this design holds the whole game together

Every duration in the game is expressed in frames because of this loop:
`StateTimer` counts frames, bullet speed is pixels-per-frame, sound
durations are frames. On fixed hardware this gives perfectly
deterministic, jitter-free timing — the same reason console games of
that era feel so tight. The cost: the game logic *must* fit in 20 ms.
Ours fits with room to spare; the heaviest frame (full formation redraw
plus 55 blits) still completes during the blank.
