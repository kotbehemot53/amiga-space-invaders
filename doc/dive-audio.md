# Deep dive: Paula audio — `PlaySound`, `UpdateAudio`, `PlayMarch`

*Source: `main.asm`, section "AUDIO (Paula)".*

## Paula's model of sound

Each of Paula's four channels is a tiny tape loop:

| Register (ch 0) | Meaning |
|---|---|
| `AUD0LCH/LCL` ($a0) | sample start address — **must be chip RAM, even** |
| `AUD0LEN` ($a4) | sample length **in words** (so bytes/2) |
| `AUD0PER` ($a6) | period: chipset ticks between output bytes |
| `AUD0VOL` ($a8) | volume 0–64 |

Channel n's registers sit at `$a0 + n*16` — a stride that the code
exploits throughout. Enable the channel's DMA bit in DMACON and Paula
streams signed 8-bit bytes from memory to the output, **looping forever**
— when it exhausts LEN words it reloads the address and goes again.
There is no one-shot mode, no envelopes, no mixing API. A "sound
effect" is: point a channel at bytes, set pitch and volume, and *later
remember to turn it off*.

Pitch: output rate = 3 546 895 / period bytes per second (PAL master
clock). Small period = high pitch. The march bass uses period ≈ 2000 on
a 32-byte square wave: 3546895/2015/32 ≈ **55 Hz** — a proper sub bass.

There are no sample files in the project. `InitAudio` synthesises both
"instruments" into chip-RAM buffers at startup: `SqBuf` = 16 bytes of
`$7f` then 16 of `$81` (a square wave: max positive, max negative), and
`NoiseBuf` = 1024 bytes from a 16-bit LFSR (white noise). Every sound
in the game is one of these two buffers at some period/volume/duration.

## `PlaySound` — the one true entry point

```asm
; d0=channel 0-3, a0=sample, d1=len words, d2=period, d3=vol, d4=frames
; frames=0 -> keeps looping until stopped manually
PlaySound:
	movem.l	d5/a1,-(sp)
	moveq	#1,d5
	lsl.w	d0,d5
	move.w	d5,DMACON(a5)		; stop channel
	move.w	d0,d5
	lsl.w	#4,d5
	lea	AUD0LCH(a5),a1
	add.w	d5,a1
	move.l	a0,(a1)			; AUDxLC
	move.w	d1,4(a1)		; AUDxLEN
	move.w	d2,6(a1)		; AUDxPER
	move.w	d3,8(a1)		; AUDxVOL
	moveq	#1,d5
	lsl.w	d0,d5
	or.w	#$8200,d5
	move.w	d5,DMACON(a5)		; start channel
	move.w	d0,d5
	add.w	d5,d5
	lea	ChTime,a1
	move.w	d4,(a1,d5.w)
	movem.l	(sp)+,d5/a1
	rts
```

- `movem.l d5/a1,-(sp)` — this routine promises to preserve d5/a1 and
  keeps that promise by hand. It does **not** preserve d0–d4 — they're
  its arguments. That asymmetry caused the project's flagship bug (see
  the bullet deep dive): a caller kept live values in d3/d4 across a
  sound call. The register convention *is* the API contract, and it
  exists only in comments.
- `moveq #1,d5` / `lsl.w d0,d5` — build the channel's DMACON bit:
  audio channels are bits 0–3, so `1 << channel`.
- `move.w d5,DMACON(a5)` — **DMACON's set/clear protocol**: writes
  where bit 15 is 0 *clear* the written bits; writes with bit 15 set
  *set* them. So this line, without `$8000`, is "stop this channel's
  DMA". Stopping first matters: Paula latches the address/length
  registers into internal counters when a channel starts; rewriting
  them mid-play affects the *next* loop iteration, not the current one.
  Stop, rewrite, restart = the new sound plays now, from byte 0.
- `lsl.w #4,d5` (on a fresh copy of the channel number) — ×16, the
  register stride; `lea AUD0LCH(a5),a1` + `add.w d5,a1` — a1 now
  points at *this channel's* register block, and the next four writes
  use plain offsets 0/4/6/8. Computing a base pointer once beats four
  indexed address calculations.
- `move.l a0,(a1)` — one 32-bit write fills both halves of the sample
  pointer (LCH then LCL — adjacent registers, same trick as the copper
  and blitter pointers).
- `or.w #$8200,d5` — `$8000` = SET mode, `$0200` = DMAEN (the master
  DMA enable — writing it again is harmless insurance), plus the
  channel bit: "start playing".
- The tail stores `d4` into `ChTime[channel]` (`add.w d5,d5` — channel
  ×2, word-sized slots): the sound's lifetime in frames. Zero means
  "no timer — loop until someone stops you", used by the UFO drone.

## `UpdateAudio` — the four-entry scheduler

Called every frame from `MainLoop`, before the game state runs.

```asm
UpdateAudio:
	lea	ChTime,a0
	lea	AUD0LCH(a5),a1
	moveq	#0,d1			; channel
.ch	move.w	(a0),d0
	beq.s	.next
	subq.w	#1,d0
	move.w	d0,(a0)
	bne.s	.next
	moveq	#1,d2			; time up: silence channel
	lsl.w	d1,d2
	move.w	d2,DMACON(a5)
	move.w	d1,d2
	lsl.w	#4,d2
	move.w	#0,8(a1,d2.w)		; AUDxVOL = 0
.next	addq.l	#2,a0
	addq.w	#1,d1
	cmp.w	#4,d1
	blt.s	.ch
```

Per channel: if the countdown is 0, inactive, skip. Otherwise decrement
and write back; if it *just reached* zero, clear the channel's DMA bit
(no `$8000` → clear mode) and zero its volume. Both are needed: DMA-off
stops fetching but the last byte would keep sounding as a DC hum at
whatever volume was set — volume 0 actually silences it.
`8(a1,d2.w)` — base + channel×16 + 8 = AUDxVOL — is the indexed
addressing mode doing struct-array access.

This is cooperative audio scheduling in 14 instructions: `PlaySound`
books a lifetime, `UpdateAudio` evicts on expiry. Two sounds wanting
one channel? Later booking wins, earlier one is cut off mid-sample —
authentically arcade, and self-limiting by design (shot on ch 1,
explosions on ch 2, so your own shot never silences a kill).

```asm
	; UFO warble: wobble ch3 period while it flies
	tst.w	UfoAct
	beq.s	.noufo
	move.l	Frame,d0
	lsr.l	#1,d0
	and.w	#31,d0
	lea	SinTab(pc),a0
	moveq	#0,d1
	move.b	(a0,d0.w),d1
	add.w	#340,d1
	move.w	d1,AUD0LCH+$36(a5)	; AUD3PER
.noufo	rts
```

The UFO's siren: while it flies, channel 3 loops the square wave with
`frames=0`, and this code *re-tunes it live*. `Frame/2 & 31` walks a
32-entry triangle table every other frame; `+340` centres the period.
Rewriting AUDxPER while a channel plays is legal and takes effect at
the next sample fetch — pitch bends for free. Period wobbling between
~340 and ~436 sweeps the tone by a musical third about 1.5 times a
second: the classic UFO "woo-woo". (`AUD0LCH+$36` = `$d6` = AUD3PER —
channel 3's period register addressed as a flat offset.)

## `PlayMarch` — where music and game speed fuse

```asm
PlayMarch:
	move.w	MarchIdx,d0
	add.w	d0,d0
	lea	MarchPer(pc),a0
	move.w	(a0,d0.w),d2
	addq.w	#1,MarchIdx
	and.w	#3,MarchIdx
	moveq	#0,d0			; ch0
	lea	SqBuf,a0
	moveq	#16,d1
	move.w	#44,d3
	moveq	#7,d4
	bra	PlaySound
```

Called from `MoveFormation` on every march tick — *not* on a timer.

- `MarchPer` holds four periods (2015/2151/2287/2423 ≈ 55/52/49/46 Hz)
  — the descending four-note bass loop from the 1978 original.
  `MarchIdx` cycles 0–3 via `and.w #3` (wrap by masking — works because
  4 is a power of two).
- The argument load: channel 0, the square buffer, 16 words (= all 32
  bytes), volume 44, **7 frames** of life. Seven frames of a 55 Hz
  square is a short "doom" thud with a hard cutoff — percussive by
  construction, no envelope needed.
- `bra PlaySound` — a **tail call**: jump, don't `bsr`. `PlaySound`'s
  `rts` returns straight to `PlayMarch`'s caller. Saves a stack frame
  and four cycles; the pattern for every `Sfx*` wrapper in the file.

The design consequence: the march tempo is `MoveDelay`, the formation's
step interval, which shrinks as aliens die. Music accelerating with
danger isn't a feature that was *added* — the beat is literally the
march clock. One mechanism, two senses.

## Recap of the register-clobber contract

`PlaySound` consumes d0–d4 as arguments. Every wrapper (`SfxShoot`,
`SfxExplode`, …) loads all five and tail-jumps. Therefore **calling any
sound effect clobbers d0–d4**, and any caller with live data there must
either save it or sequence the call last. That single fact — obvious in
hindsight, invisible in a 20-line diff — produced blits at garbage
coordinates and a score counter reading pointer bytes as decimal
digits. If you take one assembly habit from this project: *when you
call something, know what it eats.*
