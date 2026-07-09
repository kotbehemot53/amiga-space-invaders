# Deep dive: the procedural background gradient

*Source: `main.asm`, labels `SetGradient`, `GradColorT`, the `.grad` loop
inside `BuildCopper`, and the `GradStartTab` table. The output is the
per-scanline `COLOR00` (register `$0180`) run inside the copper list —
see `dive-copper.md` for how the copper list as a whole is assembled.*

## The idea

The background is a vertical gradient: a coloured glow at the **top** of
the screen fading to black, plus a dimmer glow near the **bottom**, with a
black band in the middle. Two things make it interesting:

1. **It's computed, not stored.** Only *one* colour is kept per wave — the
   top colour, `GradStart`. Every one of the 64 gradient steps is derived
   from it by scaling its brightness. No 64-entry colour table.
2. **It changes every wave.** `GradStartTab` holds 24 top colours; each
   wave picks the next one, so level 1 is the original blue, level 2 is
   orange, and so on, wrapping after 24.

Amiga colours are `$0RGB` — 4 bits per channel, 0..15. "Scaling
brightness" means multiplying each of the three nibbles by the same
fraction and clamping back into 0..15.

## Part 1: picking the wave's colour — `SetGradient`

```asm
SetGradient:
	move.w	Level,d0
.mod	cmp.w	#24,d0
	blt.s	.modok
	sub.w	#24,d0
	bra.s	.mod
.modok	add.w	d0,d0			; word index
	lea	GradStartTab(pc),a0
	move.w	(a0,d0.w),GradStart
	bra	BuildCopper
```

Called from `WaveEnter`, once per wave.

- `move.w Level,d0` — `Level` is 0 on the first wave and increments each
  time a wave is cleared.
- `.mod` loop — reduce `Level` modulo 24 by repeated subtraction. There's
  no 68000 modulo instruction for this small a case that's worth the
  setup; a subtract loop is smaller and, since `Level` rarely exceeds a
  handful, faster in practice. After the loop `d0` is in 0..23.
- `add.w d0,d0` — double it: the table is words, so index *i* lives at
  byte offset *2i*.
- `lea GradStartTab(pc),a0` / `move.w (a0,d0.w),GradStart` — fetch the
  chosen top colour and stash it in the `GradStart` variable. Everything
  downstream reads `GradStart`, so this one write retargets the whole
  gradient.
- `bra BuildCopper` — tail-call: rebuild the entire copper list with the
  new `GradStart`, then `BuildCopper`'s `rts` returns straight to
  `WaveEnter`'s caller. Rebuilding the whole list (not just the gradient)
  is simplest and happens during the between-waves banner, where a
  one-frame glitch would be invisible anyway.

### The table

```asm
GradStartTab:				; 24 per-wave COLOR00 top colours ($0RGB)
	dc.w	$0007			; 1  blue (original)
	dc.w	$0940			; 2  orange
	dc.w	$0079			; 3  cyan
	...
	dc.w	$0099			; 24 aqua
```

24 hand-picked `$0RGB` values. Two design rules:

- **Entry 0 is `$0007`** — the exact blue the game shipped with before the
  gradient went procedural, so the first wave looks unchanged.
- **Adjacent entries are far apart in hue** (blue→orange→cyan→magenta…),
  alternating warm and cool, so consecutive levels look obviously
  different rather than drifting through neighbouring shades. Peak channel
  values stay moderate (~7–9) so the background never overpowers the
  plane-0 sprites drawn on top of it.

## Part 2: the brightness curve — `GradFactor`

Inside `BuildCopper`, the gradient loop runs 64 times (`d4` = screen line,
0..252 step 4; entry index `i = d4/4`). For each line it just calls two
helpers — `GradFactor` (line → factor) then `GradColorT` (factor →
colour) — and emits the resulting `COLOR00` MOVE. `GradColorT` is actually
called *twice* per block with different dither thresholds, emitting two
COLOR00 MOVEs (see Part 3), but the brightness curve below is per-block.
The copper-list plumbing (WAIT words, the line-256 crossing, the `BandTab`
check) is covered in `dive-copper.md`.

`GradFactor` turns the entry index `i` (0..63) into a single *brightness
factor* (0..32). The factor is the **maximum of two triangular lobes**:

```asm
; in:  d4 = screen line (0..252, step 4)   out: d0 = factor 0..32
; clobbers d1/d5
GradFactor:
	move.w	d4,d5
	lsr.w	#2,d5			; entry index i = 0..63
	moveq	#32,d1
	sub.w	d5,d1			; top lobe: 32 - i
	bpl.s	.top
	moveq	#0,d1
.top	move.w	d5,d0
	sub.w	#44,d0			; bottom lobe: i - 44 (rises to 19)
	bmi.s	.nobot
	cmp.w	d1,d0			; keep the brighter lobe
	bgt.s	.done
.nobot	move.w	d1,d0
.done	rts
```

- `lsr.w #2,d5` — `i = d4/4`, the entry number 0..63.
- **Top lobe** `d1 = 32 - i`: at the very top (`i=0`) the factor is 32 =
  full brightness; it falls to 0 by `i=32` (screen middle). `bpl .top`
  keeps it, otherwise `moveq #0,d1` clamps the negative half to 0. So the
  top lobe lights entries 0..32 and is dark below.
- **Bottom lobe** `d0 = i - 44`: negative until `i=44`, then climbs to 19
  at `i=63` (screen bottom). `bmi .nobot` skips it entirely when
  negative (upper part of the screen). Peak 19 < the top's 32, so the
  bottom glow is deliberately dimmer than the top.
- **Combine** `cmp.w d1,d0` / `bgt .done` — take whichever lobe is
  brighter at this line. Since the lobes never overlap (top dies at 32,
  bottom wakes at 44), the `max` just selects whichever is active, and the
  gap 33..43 stays black — the mid-screen black band.

Back in the loop, the factor in `d0` is handed to `GradColorT`, whose
returned colour becomes a *MOVE → COLOR00* copper instruction.
Splitting the work this way mirrors the two questions each line asks —
*how bright?* (`GradFactor`) and *what colour is that?* (`GradColorT`).

Factor as a function of line:

```
factor
 32 |*                                              (top lobe: 32 - i)
    | *
    |  *
    |   *
    |    *
    |     *
  0 |______*_________________________ . . . ______________
    0      i=32        black band         i=44        i=63
                                              *
                                           *      (bottom lobe: i - 44,
                                        *          peaks at 19)
```

## Part 3: applying the factor — `GradColorT`

```asm
; in:  d7 = factor 0..32   d6 = dither threshold 0..31
; out: d0 = dithered $0RGB colour   clobbers d0/d1/d2/d5
GradColorT:
	move.w	GradStart,d5		; d5 = $0RGB source
	moveq	#0,d0			; result accumulator
	move.w	d5,d1			; blue
	and.w	#$0f,d1
	bsr.s	.chan
	or.w	d1,d0
	move.w	d5,d1			; green
	lsr.w	#4,d1
	and.w	#$0f,d1
	bsr.s	.chan
	lsl.w	#4,d1
	or.w	d1,d0
	move.w	d5,d1			; red
	lsr.w	#8,d1
	and.w	#$0f,d1
	bsr.s	.chan
	lsl.w	#8,d1
	or.w	d1,d0
	rts
.chan	mulu	d7,d1			; factor*ch, 0..480
	move.w	d1,d2
	and.w	#$1f,d2			; discarded fraction (low 5 bits)
	lsr.w	#5,d1			; scaled channel 0..15
	cmp.w	d6,d2			; fraction over threshold?
	bls.s	.cd
	addq.w	#1,d1			; round up
	cmp.w	#15,d1
	bls.s	.cd
	moveq	#15,d1			; clamp
.cd	rts
```

Multiply each 4-bit channel of `GradStart` by `factor/32` and reassemble.
The `/32` is the key trick: at the peak factor of 32 a channel is scaled
by 32/32 = 1 (unchanged, full brightness), and dividing by a power of two
is a shift, not a real divide.

**The dither.** `factor*ch` is 0..480; `lsr.w #5` (÷32) is the 4-bit
result and the low 5 bits (`and.w #$1f`) are the *fraction* that plain
truncation would throw away — the source of the visible banding, since the
hardware only has 16 levels per channel. When that fraction beats the
caller's `d6` threshold the channel is rounded **up** by one (clamped to
15). `BuildCopper`'s gradient loop calls `GradColorT` twice per 4-line
block — first with a low threshold (8), then a high one (24) two rasters
lower — so a channel whose fraction lands between the two thresholds is
one level brighter on the lower pair of scanlines than the upper pair. The
eye averages the alternating pairs into an in-between colour: **ordered
vertical dithering** that fakes shades between the 16 hardware levels and
smooths the gradient. Thresholds 8/24 split each fractional unit into three
perceived sub-levels (both floor, split, both ceil).

- `move.w GradStart,d5` — the source colour, read fresh each call so a new
  wave's `GradStart` takes effect on the next rebuild.
- **Blue** (low nibble): `and.w #$0f` isolates it, `.chan` multiplies by
  the factor (max `15 * 32 = 480`, fits a word), dithers, and shifts back
  to 0..15. This first channel `or`s straight into the `d0` result.
- **Green** (bits 4..7): `lsr.w #4` down to the low nibble, `.chan`, then
  `lsl.w #4` back into the green position and `or.w d1,d0` to merge.
- **Red** (bits 8..11): same with `lsr.w #8` / `lsl.w #8`.
- Result in `d0`: the dithered `$0RGB` colour, ready to drop into the
  copper `COLOR00` MOVE.

Because all three channels share one factor, the colour keeps its **hue**
and only its **brightness** changes down the screen — the gradient is a
single tint fading to black, which is why one stored top colour per wave
is enough.

## Why it's cheap

The whole gradient is regenerated only when the wave changes (inside
`SetGradient` → `BuildCopper`), not per frame. Once built, the copper
repaints all 64 colour steps every frame at **zero CPU cost** — see the
payoff note in `dive-copper.md`. Adding 24 backgrounds cost 24 words of
table plus one small routine, no per-frame work at all.
