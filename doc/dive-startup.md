# Deep dive: taking the machine and giving it back (`Start`, `Quit`)

*Source: `main.asm`, labels `Start`, `Quit`, `QuitNoGfx`.*

The game does a full hardware takeover: after startup it talks straight
to the custom chips and never calls the OS again. But the user launched
it from AmigaDOS and expects their Workbench back when they left-click to
quit. This dive reads the entry and exit ritual line by line — the
"demo-scene protocol" for borrowing an Amiga politely and returning it in
the state you found it.

Two OS concepts show up here and nowhere else in the game: **library
calls** through Exec, and **restoring the system copper list**. Both are
worth understanding once.

## Calling the OS at all (the last time we do)

```asm
Start:
	move.l	4.w,a6			; a6 = ExecBase
	jsr	_LVOForbid(a6)		; stop multitasking
	lea	GfxName(pc),a1		; a1 -> "graphics.library"
	moveq	#0,d0			; d0 = version (0 = any)
	jsr	_LVOOpenLibrary(a6)	; returns lib base in d0
	move.l	d0,GfxBase
	beq	QuitNoGfx		; open failed -> bail
```

Line by line:

- `move.l 4.w,a6` — absolute address 4 holds a pointer to **ExecBase**,
  the AmigaOS kernel. This is the one fixed constant in the whole system.
  Every OS library call is `jsr negative_offset(base)`: the base register
  points at a struct, and just *below* it sits a jump table of function
  vectors. The equates near the top of `main.asm` name the offsets:

  ```asm
  _LVOForbid       equ	-132
  _LVOPermit       equ	-138
  _LVOCloseLibrary equ	-414
  _LVOOpenLibrary  equ	-552
  ```

  `_LVO` = "Library Vector Offset". `jsr _LVOForbid(a6)` calls the
  function 132 bytes below ExecBase.

- `jsr _LVOForbid(a6)` — `Forbid()` disables the task scheduler. Nothing
  else runs until we `Permit()`. We are about to seize every chip; we
  don't want another task waking up and finding the display gone.

- **Argument passing is by register, not stack.** AmigaOS uses a fixed
  register ABI: `OpenLibrary` takes the name pointer in **a1** and the
  version in **d0**, and returns the library base in **d0**. So:
  - `lea GfxName(pc),a1` loads a pointer to the string
    `dc.b 'graphics.library',0` into a1 — the *name* argument.
  - `moveq #0,d0` sets the *version* argument to 0, meaning "any version
    will do".
  - After the `jsr`, **d0 is no longer the argument — it's the result**:
    the base address of the opened library, or 0 on failure.

  This is the common point of confusion: the same register `d0` is an
  input (version) *before* the call and an output (base pointer) *after*
  it. Line 116 fills in an argument; line 118 stores a result.

- `move.l d0,GfxBase` — stash the returned base. `beq QuitNoGfx` — if it
  was zero the open failed (no graphics.library — should never happen,
  it's ROM-resident), so jump to the minimal bail-out that skips the
  copper restore and the close (see the bottom of this dive).

### Why open graphics.library at all?

The game never draws through it, never uses a single graphics function.
It is opened for exactly **one field**, read once, at quit time. Everything
after this — display setup, copper, blitter — is done by poking custom
registers directly. If you `grep GfxBase main.asm` you'll find it used in
precisely two places, both inside `Quit`. So the honest answer to "why
open it" is: *only to be able to restore the system display when we
leave.* Hold that thought.

## The takeover proper

```asm
	lea	CUSTOM,a5		; a5 = $dff000, kept forever
	move.w	DMACONR(a5),d0
	or.w	#$8000,d0
	move.w	d0,SavedDMA
	move.w	INTENAR(a5),d0
	or.w	#$8000,d0
	move.w	d0,SavedINT
```

`a5 = $dff000` (the custom-chip base) is loaded once and, by whole-program
convention, never touched again — every routine assumes it. Then we snapshot
the state we're about to destroy so `Quit` can put it back:

- `DMACONR` / `INTENAR` are the **read** addresses of the DMA-enable and
  interrupt-enable masks. Quirk: the readable and writable versions live
  at *different addresses*, and the write format is unusual — **bit 15 is
  a set/clear switch**, bits 0–14 select which bits it applies to. Writing
  a value with bit 15 clear *clears* every set bit; with bit 15 set it
  *sets* them.
- So `or.w #$8000,d0` forces bit 15 on in the saved copy. When `Quit`
  writes `SavedDMA` back, the bits that were enabled get re-enabled rather
  than cleared. Save-with-the-set-flag-baked-in is the whole trick.

```asm
	move.w	#$7fff,INTENA(a5)	; all interrupts off
	move.w	#$7fff,INTREQ(a5)
	move.w	#$7fff,INTREQ(a5)
	move.w	#$7fff,DMACON(a5)	; all DMA off
	move.w	#$00ff,ADKCON(a5)	; no audio modulation
```

`$7fff` = bit 15 clear, all other bits set = "clear everything". Interrupts
and DMA go fully dark. (`INTREQ` is written twice for a documented A4000/hardware
race — one write can be missed.) From here the game configures its own
display and enables only the DMA channels it wants (`#$83e0` later: master +
bitplanes + copper + blitter + sprites).

## Giving it back (`Quit`)

Left mouse button in `MainLoop` falls through to here. The exit runs the
takeover backwards, plus the one line that actually matters for the
display:

```asm
Quit:
	moveq	#3,d0			; silence all 4 Paula channels
	lea	AUD0LCH+8(a5),a0
.vol	move.w	#0,(a0)
	lea	$10(a0),a0
	dbf	d0,.vol
	move.w	#$000f,DMACON(a5)	; audio DMA off

	move.w	#$7fff,DMACON(a5)	; all DMA off again
	move.w	SavedDMA,DMACON(a5)	; ...then restore what was on
	move.l	GfxBase,a1
	move.l	38(a1),COP1LCH(a5)	; gb_copinit: the OS copper list
	move.w	COPJMP1(a5),d0		; strobe: restart copper now
	move.w	SavedINT,INTENA(a5)	; restore interrupts

	move.l	4.w,a6
	move.l	GfxBase,a1
	jsr	_LVOCloseLibrary(a6)	; balance the OpenLibrary
QuitNoGfx:
	jsr	_LVOPermit(a6)		; multitasking back on
	moveq	#0,d0
	rts
```

- Zero the four channel volumes, drop audio DMA, then blank all DMA and
  write `SavedDMA` back — the DMA channels the OS had running return to
  life.

- **The crucial line: `move.l 38(a1),COP1LCH(a5)`.** `GfxBase` is not just
  an opaque handle — it points at the `GfxBase` struct in RAM. Offset **38**
  into that struct is the field `gb_copinit`: a pointer to **the OS's own
  copper list**, the one that sets up the plain Workbench/CLI display. The
  game trashed the copper long ago (pointed `COP1LCH` at its own `CopBuf`).
  To hand the screen back we reload the OS's copperinit pointer and then
  strobe `COPJMP1`, which makes the copper jump to it *immediately*. The
  Workbench display reappears. `38` is a hardcoded struct offset with no
  symbol — classic Amiga demo/game shorthand, and the single reason we
  bothered opening the library at the top.

- `move.w SavedINT,INTENA(a5)` — interrupts back on (bit 15 was baked into
  the saved value, so this *sets* them).

- `CloseLibrary` — every `OpenLibrary` bumps the library's `lib_OpenCnt`;
  every `CloseLibrary` drops it. They must balance. For graphics.library
  (permanently ROM-resident, never expunged) a missing close is invisible
  in practice — the leaked count just sits there until reboot and nothing
  breaks. But it would be a leak by principle: for a *disk-loaded* library,
  `OpenCnt > 0` means "in use, can't unload", so leaking opens across many
  runs would pin it in RAM forever. Always balance Open/Close; it costs
  three instructions here.

- `Permit()` undoes the `Forbid()` from `Start`, `moveq #0,d0` returns a
  clean exit code, `rts` hands control back to AmigaDOS.

### The `QuitNoGfx` bail path

Notice `QuitNoGfx` is a label *inside* `Quit`, below the CloseLibrary.
When `OpenLibrary` failed back in `Start`, jumping straight here skips
everything that needs `GfxBase` — the copper restore and the close — and
does only the two things that are still valid: `Permit` (to undo the
`Forbid`, which already happened) and return. There is nothing to restore
and nothing to close, so it's the correct minimal exit. (It's a *global*
label, not a `.local` one, precisely so a branch from another routine can
reach it — see the note on label scope in `CLAUDE.md`.)

## Takeaways

- OS calls are `jsr offset(base)` with arguments in fixed registers; the
  same register can be an input before the call and the result after it.
- `Forbid`/`Permit` and `OpenLibrary`/`CloseLibrary` are paired — enter
  and exit must mirror.
- Restoring the display is one line: point the copper back at
  `gb_copinit` (offset 38 in `GfxBase`) and strobe it. That one field is
  the whole reason graphics.library is opened.
- The "save with bit 15 pre-set" trick makes DMA/interrupt restore a plain
  write-back.
