# Deep dive: the procedural background gradient

*Source: `main.asm`, labels `SetGradient`, `GradColor`, the `.grad` loop
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

## Part 2: the brightness curve — the `.grad` loop

Inside `BuildCopper`, the gradient loop runs 64 times (`d4` = screen line,
0..252 step 4; entry index `i = d4/4`). The copper-list plumbing (WAIT
words, the line-256 crossing, the `BandTab` check) is covered in
`dive-copper.md`; here's only the `COLOR00` part:

```asm
	move.w	d4,d5
	lsr.w	#2,d5			; entry index i = 0..63
	moveq	#32,d1
	sub.w	d5,d1			; top lobe: 32 - i
	bpl.s	.gtop
	moveq	#0,d1
.gtop	move.w	d5,d0
	sub.w	#44,d0			; bottom lobe: i - 44 (rises to 19)
	bmi.s	.gnobot
	cmp.w	d1,d0			; keep the brighter lobe
	bgt.s	.gfac
.gnobot	move.w	d1,d0
.gfac	bsr	GradColor		; d0 = factor -> scaled COLOR00
	move.w	#$0180,(a0)+		; COLOR00
	move.w	d0,(a0)+
```

The goal is to turn the entry index `i` (0..63) into a single *brightness
factor* (0..32) that `GradColor` will apply. The factor is the **maximum
of two triangular lobes**:

- `lsr.w #2,d5` — `i = d4/4`, the entry number 0..63.
- **Top lobe** `d1 = 32 - i`: at the very top (`i=0`) the factor is 32 =
  full brightness; it falls to 0 by `i=32` (screen middle). `bpl .gtop`
  keeps it, otherwise `moveq #0,d1` clamps the negative half to 0. So the
  top lobe lights entries 0..32 and is dark below.
- **Bottom lobe** `d0 = i - 44`: negative until `i=44`, then climbs to 19
  at `i=63` (screen bottom). `bmi .gnobot` skips it entirely when
  negative (upper part of the screen). Peak 19 < the top's 32, so the
  bottom glow is deliberately dimmer than the top.
- **Combine** `cmp.w d1,d0` / `bgt .gfac` — take whichever lobe is
  brighter at this line. Since the lobes never overlap (top dies at 32,
  bottom wakes at 44), the `max` just selects whichever is active, and the
  gap 33..43 stays black — the mid-screen black band.
- `bsr GradColor` — factor in `d0` → scaled colour in `d0`.
- `move.w #$0180,(a0)+` / `move.w d0,(a0)+` — emit *MOVE colour →
  COLOR00*, one copper instruction.

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

## Part 3: applying the factor — `GradColor`

```asm
; in:  d0 = factor 0..32   out: d0 = scaled $0RGB colour
; clobbers d1/d2/d3
GradColor:
	move.w	d0,d2			; d2 = factor
	move.w	GradStart,d1		; d1 = $0RGB source
	move.w	d1,d0			; blue
	and.w	#$0f,d0
	mulu	d2,d0
	lsr.w	#5,d0			; * factor / 32
	move.w	d1,d3			; green
	lsr.w	#4,d3
	and.w	#$0f,d3
	mulu	d2,d3
	lsr.w	#5,d3
	lsl.w	#4,d3
	or.w	d3,d0
	move.w	d1,d3			; red
	lsr.w	#8,d3
	and.w	#$0f,d3
	mulu	d2,d3
	lsr.w	#5,d3
	lsl.w	#8,d3
	or.w	d3,d0
	rts
```

Multiply each 4-bit channel of `GradStart` by `factor/32` and reassemble.
The `/32` is the key trick: at the peak factor of 32 a channel is scaled
by 32/32 = 1 (unchanged, full brightness), and dividing by a power of two
is a shift, not a real divide.

- `move.w d0,d2` — save the factor; `mulu` is about to reuse `d0`.
- `move.w GradStart,d1` — the source colour, read fresh each call so a new
  wave's `GradStart` takes effect on the next rebuild.
- **Blue** (low nibble): `and.w #$0f` isolates it, `mulu d2` multiplies by
  the factor (max `15 * 32 = 480`, fits a word), `lsr.w #5` divides by 32
  → back into 0..15. This first channel goes straight into `d0` as the
  running result.
- **Green** (bits 4..7): copy to `d3`, `lsr.w #4` to bring it down to the
  low nibble, same isolate/multiply/shift, then `lsl.w #4` to put it back
  in the green position and `or.w d3,d0` to merge.
- **Red** (bits 8..11): same with `lsr.w #8` / `lsl.w #8`.
- Result in `d0`: the `$0RGB` colour with every channel scaled, ready to
  drop into the copper `COLOR00` MOVE.

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
