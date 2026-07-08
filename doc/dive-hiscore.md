# Deep dive: high-score table + name entry

*Source: `main.asm`, labels `HiTab`, `HiScoreInsert`, `GameOverEnter`,
`NameEnter`, `NameState`, `ReadJoyDir`, `CycleCur`, `DrawNameLine`.
Entered from `GameOverEnter` when the final score cracks the top 5;
runs as its own game state (`ST_NAME`) until the player commits.*

This is the game's only piece of *text input*, and it does it with no
keyboard driver at all — just the joystick the rest of the game already
reads. It also hides a subtle register-clobber bug that produced one of
the weirdest symptoms in the project (see the last section). Worth a
slow read for the input decode and the "keep it tidy" routine split.

## The table on disk

```asm
HiTab:					; survives between games; ENTSZ bytes/entry:
					; BCD score long + NAMESZ name chars
	dc.l	$00007500
	dc.b	'STEVO   '
	dc.l	$00004000
	dc.b	'BOB     '
	dc.l	$00002000
	dc.b	'FROOMCH '
	dc.l	$00001000
	dc.b	'DOOPA   '
	dc.l	$00000500
	dc.b	'CABBAGE '
HiScore:
	dc.l	$00007500
```

Each entry is `ENTSZ` = `4 + NAMESZ` = **12 bytes**: a 6-digit BCD score
long (see [dive-bullet.md](dive-bullet.md) for why scores are BCD) then
an 8-char name (`NAMESZ`), space-padded to a fixed width — no
terminator, so the whole table is a flat 60-byte array with a constant
stride. Names are uppercase because the font
([`Font`](../main.asm)) only has A-Z, 0-9, space, `.`, `!`, `=`.

`HiTab` lives in `section data`, not `bss`, so these defaults ship inside
the executable and load with the program. That's what makes them
*survive between games in a session* (the loader doesn't touch data
hunks between runs) while still resetting to Stevo-and-friends on a
fresh launch. `HiScore` right after it is a separate long — the running
"HI" shown in the HUD — deliberately independent of the table.

## Rendering the table (title screen)

The title state walks the five entries and composes one string per row:

```asm
	lea	HiTab,a2
	moveq	#0,d6			; entry index
.hisc	...				; build "N. " prefix in StrBuf
	move.l	(a2),d0			; BCD score (name follows at 4(a2))
	bsr	BCDToStr		; appends 6 digits + nul, a0 -> nul
	move.b	#' ',(a0)+		; separator, then name
	lea	4(a2),a3
	moveq	#NAMESZ-1,d0
.name	move.b	(a3)+,(a0)+
	dbf	d0,.name
	clr.b	(a0)
	...				; DrawText, then:
	lea	ENTSZ(a2),a2		; next entry
```

The trick is that `BCDToStr` leaves `a0` pointing at the nul it wrote, so
we just keep appending: overwrite that nul with a space, copy the 8 name
bytes, re-terminate. Result: `"1. 007500 STEVO   "`. That's why `StrBuf`
was bumped to 24 bytes — 3 (prefix) + 6 (digits) + 1 (space) + 8 (name)
+ 1 (nul) = 19. The `lea ENTSZ(a2),a2` at the bottom is the whole reason
the 12-byte stride is a named constant: change `NAMESZ` and every
consumer follows.

## Getting on the board: `HiScoreInsert`

`GameOverEnter` no longer inlines the merge; it delegates so the logic
stays in one testable place:

```asm
GameOverEnter:
	bsr	HideSprites
	move.l	Score,d0
	bsr	HiScoreInsert		; d2 = slot (0..4) or -1
	tst.w	d2
	bpl	NameEnter		; made the table -> type your name
	; ...else ordinary GAME OVER screen + ST_OVER timer
```

`HiScoreInsert` is a classic sorted-array insert, but over a 12-byte
stride instead of 4:

```asm
HiScoreInsert:
	lea	HiTab,a0
	moveq	#0,d2			; slot index
.find	cmp.l	(a0),d0			; new score > this entry ?
	bhi.s	.ins
	lea	ENTSZ(a0),a0
	addq.w	#1,d2
	cmp.w	#5,d2
	blt.s	.find
	moveq	#-1,d2			; not good enough, dawg
	rts
.ins	lea	HiTab+4*ENTSZ,a1	; last entry = first shift destination
	moveq	#4,d1
.shift	cmp.w	d2,d1
	ble.s	.place
	move.l	-ENTSZ(a1),(a1)		; copy a whole 12-byte entry down
	move.l	-ENTSZ+4(a1),4(a1)
	move.l	-ENTSZ+8(a1),8(a1)
	lea	-ENTSZ(a1),a1
	subq.w	#1,d1
	bra.s	.shift
.place	move.l	d0,(a1)			; a1 = HiTab + slot*ENTSZ
	lea	4(a1),a2		; name field of the new entry
	move.l	a2,NamePtr
	moveq	#NAMESZ-1,d1
.blank	move.b	#' ',(a2)+		; start with a blank name
	dbf	d1,.blank
	rts
```

- `cmp.l (a0),d0` + `bhi.s` — unsigned compare. It works on BCD only
  because BCD preserves numeric ordering byte-for-byte (a 6-digit BCD
  long compares the same as its decimal value). Same reason the HUD's
  hi-score check works.
- The shift walks **from the bottom up**, copying entry *i-1* into *i*,
  so nothing is overwritten before it's read. Each entry is moved as
  three longs (12 bytes).
- When the loop exits, `a1` sits exactly on the freed slot. Score goes
  in; the name is blanked to 8 spaces; and — the important handoff —
  `NamePtr` is stashed with the address of that name field. The name
  editor never needs to know the slot index; it just edits bytes at
  `NamePtr` in place.
- Return contract: `d2` = slot 0-4 on success, `-1` if the score didn't
  make it. `tst.w d2 / bpl` in the caller reads that as "non-negative =
  qualified."

## The name-entry state

Reaching a high score switches `GameState` to `ST_NAME`, so the main
loop's jump table calls `NameState` every frame (see
[dive-mainloop.md](dive-mainloop.md)). `NameEnter` sets it up once:

```asm
NameEnter:
	move.w	#ST_NAME,GameState
	clr.w	NamePos
	clr.w	JoyPrev			; fresh edge detection
	st	FireLatch		; require fire release before commit
	bsr	HideSprites
	bsr	ClearGamePlanes
	...				; draw NEW HIGH SCORE / ENTER YOUR NAME / help
	bsr	DrawNameLine
	rts
```

`st FireLatch` (set to $ff) is the same "require a release first" guard
the title screen uses: the player is very likely still mashing fire from
the death that ended the game, so the first fire *press* mustn't
instantly commit an empty name. The commit only happens after fire has
been seen released once.

Per-frame logic is a straight dispatch on four direction edges plus the
fire test:

```asm
NameState:
	bsr	ReadJoyDir		; d1 = fresh-press bits 0=up 1=dn 2=L 3=R
	btst	#0,d1
	beq.s	.nu
	moveq	#1,d0
	bsr	CycleCur		; next letter
.nu	btst	#1,d1
	beq.s	.nd
	moveq	#-1,d0
	bsr	CycleCur		; prev letter
.nd	btst	#2,d1
	beq.s	.nl
	subq.w	#1,NamePos		; cursor left
	bpl.s	.nl
	clr.w	NamePos
.nl	btst	#3,d1
	beq.s	.nr
	move.w	NamePos,d0		; cursor right
	addq.w	#1,d0
	cmp.w	#NAMESZ,d0
	blt.s	.rok
	moveq	#NAMESZ-1,d0
.rok	move.w	d0,NamePos
.nr	bsr	DrawNameLine
	; fire commits (after a release)
	btst	#7,CIAAPRA
	bne.s	.nofire
	tst.b	FireLatch
	bne.s	.done
	bra	TitleEnter		; name is already stored in the table
.nofire	clr.b	FireLatch
.done	rts
```

Up/down cycle the letter under the cursor, left/right move the cursor
(clamped to 0..`NAMESZ-1`), fire commits. There's no separate "save"
step: because `CycleCur` edits the byte at `NamePtr+NamePos` directly,
the table already holds the current name at all times. Committing is
just `bra TitleEnter`. An empty (all-spaces) name is allowed — that was
a deliberate product choice.

## No keyboard: reading a joystick as an alphabet dial

`CycleCur` maps the character under the cursor to its index in a lookup
string, nudges the index, and writes the new character back:

```asm
CHARSETN	equ	37			; A-Z 0-9 space
...
CharSet:	dc.b	'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '
```

```asm
CycleCur:
	move.l	NamePtr,a0
	move.w	NamePos,d3
	lea	(a0,d3.w),a0		; a0 -> current char
	move.b	(a0),d2
	lea	CharSet(pc),a1
	moveq	#0,d3			; scan for current char's index
.scan	cmp.b	(a1,d3.w),d2
	beq.s	.found
	addq.w	#1,d3
	cmp.w	#CHARSETN,d3
	blt.s	.scan
	moveq	#0,d3			; not in set -> index 0
.found	add.w	d0,d3
	bpl.s	.nounder
	moveq	#CHARSETN-1,d3		; wrapped below -> last
.nounder cmp.w	#CHARSETN,d3
	blt.s	.store
	moveq	#0,d3			; wrapped past end -> first
.store	move.b	(a1,d3.w),(a0)
	rts
```

The blank name starts as spaces, and space is the *last* entry in
`CharSet` (index 36), so nudging up from blank wraps neatly to `A`
(index 0) and nudging down gives `9`. Linear scan of 37 bytes is
nothing.

### The direction decode (`ReadJoyDir`)

The reusable part is `ReadJoyDir`, which turns the raw `JOY1DAT` word
into four *edge-triggered* direction flags (one press = one step, so the
letter doesn't blur past you while you hold the stick):

```asm
ReadJoyDir:
	move.w	JOY1DAT(a5),d0
	moveq	#0,d2			; raw direction bits this frame
	btst	#8,d0			; up = bit8 without bit9
	beq.s	.nu
	btst	#9,d0
	bne.s	.nu
	bset	#0,d2
.nu	btst	#0,d0			; down = bit0 without bit1
	beq.s	.nd
	btst	#1,d0
	bne.s	.nd
	bset	#1,d2
.nd	btst	#9,d0			; left
	beq.s	.nl
	bset	#2,d2
.nl	btst	#1,d0			; right
	beq.s	.nr
	bset	#3,d2
.nr	move.w	d2,d1
	move.w	JoyPrev,d3
	not.w	d3
	and.w	d3,d1			; keep only newly-set bits
	move.w	d2,JoyPrev
	rts
```

The `JOY1DAT` bit patterns were **measured empirically** by dumping the
raw register on screen (an FS-UAE digital joystick, cursor keys):

| Direction | `JOY1DAT` |
|---|---|
| rest  | `$0000` |
| up    | `$0100` |
| down  | `$0001` |
| left  | `$FF00` |
| right | `$00FF` |

Note the overlap: `up` and `left` both set bit 8; `down` and `right`
both set bit 0. So up must be *bit 8 and **not** bit 9* (otherwise left
reads as up), and down must be *bit 0 and **not** bit 1*. Left is just
bit 9, right just bit 1. The edge filter (`d1 = raw AND NOT JoyPrev`,
then store raw into `JoyPrev`) is what makes each press count once.

> Aside: the "textbook" Amiga joystick decode uses a Gray-code
> quadrature XOR (`d0 ^ (d0 >> 1)`). That's correct for a real analog
> mouse/joystick counter, but FS-UAE's keyboard-joystick emits the clean
> patterns above, and the XOR version silently swapped up/down here.
> Measure, don't assume.

## The cursor, and why redraw is free

`DrawNameLine` re-renders the 8-char name every frame and draws the
cursor as an underline beneath the current cell:

```asm
DrawNameLine:
	move.l	NamePtr,a1
	lea	StrBuf,a0		; copy name -> nul-terminated StrBuf
	moveq	#NAMESZ-1,d0
.cpy	move.b	(a1)+,(a0)+
	dbf	d0,.cpy
	clr.b	(a0)
	lea	StrBuf,a0
	moveq	#NAMEBX,d0
	move.w	#NAMEBY,d1
	bsr	DrawText
	lea	Plane1,a1		; underline cursor cell (cell row 7)
	move.w	#NAMEBY,d2
	lsl.w	#5,d2
	move.w	#NAMEBY,d3
	lsl.w	#3,d3
	add.w	d3,d2			; y*40
	add.w	#NAMEBX,d2
	add.w	NamePos,d2
	add.w	#280,d2			; +cell row 7 (7*40)
	move.b	#$ff,(a1,d2.w)
```

The neat part: `DrawText` writes all 8 rows of every character cell,
including row 7 (the bottom), which for letters is blank ($00). So each
redraw *automatically clears* last frame's underline — no separate erase
needed. Then we set a single `$ff` byte at row 7 of the current cell to
draw the fresh cursor. The `add.w #280,d2` fold (7 * 40 bytes/row) is
there because the 68000's indexed addressing mode only allows an 8-bit
displacement — `280(a1,d2.w)` won't assemble, so the offset has to go
into the index register.

## The best bug: a clobbered `d1`

The first working version had a bizarre symptom: name entry behaved
*differently depending on the cursor position*. At the 3rd character,
"down" stopped cycling; at the 4th or 5th, the cursor jumped backwards
on its own. The joystick debug readout proved the hardware bits were
perfectly clean — so it wasn't the decode.

The culprit was `CycleCur`. Its first draft loaded `NamePos` into `d1`:

```asm
	move.w	NamePos,d1		; <-- the bug
	lea	(a0,d1.w),a0
```

But `NameState` holds the joystick edge-bits in `d1` and keeps testing
it *after* calling `CycleCur`:

```asm
	btst	#0,d1
	...
	bsr	CycleCur		; trashes d1 = NamePos!
.nu	btst	#1,d1			; now testing NamePos, not the joystick
.nd	btst	#2,d1
.nl	btst	#3,d1
```

Once a cycle fired, `d1` became `NamePos`, and the remaining `btst`s
read *cursor-position bits as fake directions*:

- `NamePos = 2` (`%010`) → bit 1 set → phantom **down**
- `NamePos = 4` (`%100`) → bit 2 set → phantom **left** (cursor jumps back)

Exactly the position-dependent nonsense observed. The fix was one
register: `CycleCur` scratches `d3` instead of `d1`, and its header
comment now explicitly promises *not* to touch `d1`. The lesson is the
same one that bit `MoveBullet` (see [dive-bullet.md](dive-bullet.md)):
in hand-written assembly, a routine's clobber list is part of its
contract, and a caller holding live values in a scratch register across
a `bsr` is a bug waiting to bite.
