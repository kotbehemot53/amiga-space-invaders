;--------------------------------------------------------------------
; SPACE INVADERS  --  Amiga 500 OCS/PAL, 512k chip + 512k slow
; Kickstart 1.3+, hardware takeover, joystick in port 2
;
; vasm m68k (mot syntax) -> Amiga hunk, linked with vlink
; Copper: per-line background gradient + per-region colour bands
; Blitter: alien formation, explosions, shields, HUD icons
; Sprites: player cannon, UFO
; Paula: 4-channel generated SFX (march bass, shots, explosions,
;        UFO warble)
;--------------------------------------------------------------------

;-------------------------------- custom chip registers (offsets)
CUSTOM		equ	$dff000
DMACONR		equ	$002
VPOSR		equ	$004
VHPOSR		equ	$006
JOY1DAT		equ	$00c
INTENAR		equ	$01c
BLTCON0		equ	$040
BLTCON1		equ	$042
BLTAFWM		equ	$044
BLTALWM		equ	$046
BLTCPTH		equ	$048
BLTBPTH		equ	$04c
BLTAPTH		equ	$050
BLTDPTH		equ	$054
BLTSIZE		equ	$058
BLTCMOD		equ	$060
BLTBMOD		equ	$062
BLTAMOD		equ	$064
BLTDMOD		equ	$066
COP1LCH		equ	$080
COPJMP1		equ	$088
DIWSTRT		equ	$08e
DIWSTOP		equ	$090
DDFSTRT		equ	$092
DDFSTOP		equ	$094
DMACON		equ	$096
INTENA		equ	$09a
INTREQ		equ	$09c
ADKCON		equ	$09e
AUD0LCH		equ	$0a0		; +$10 per channel
BPLCON0		equ	$100
BPLCON1		equ	$102
BPLCON2		equ	$104
BPL1MOD		equ	$108
BPL2MOD		equ	$10a
SPR0PTH		equ	$120
COLOR00		equ	$180

CIAAPRA		equ	$bfe001

;-------------------------------- exec offsets
_LVOForbid	equ	-132
_LVOPermit	equ	-138
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552

;-------------------------------- layout
BPW		equ	40		; bytes per raster row
SCRH		equ	256
PLSIZE		equ	BPW*SCRH

ROWS		equ	5
COLS		equ	11
CELLW		equ	16
CELLH		equ	16

SHIELDY		equ	192		; shield band top (screen y)
PLAYERY		equ	216		; player cannon y
GROUNDY		equ	232
BULSPD		equ	4
FORMX0		equ	24
FORMY0		equ	48

; game states
ST_TITLE	equ	0
ST_PLAY		equ	1
ST_DEATH	equ	2
ST_OVER		equ	3
ST_WAVE		equ	4

;-------------------------------- macros
WAITBLT		macro
	tst.w	DMACONR(a5)		; A1000 compat dummy read
wblt\@	btst	#6,DMACONR(a5)
	bne.s	wblt\@
	endm

;=====================================================================
	section	code,code
;=====================================================================

Start:
	move.l	4.w,a6
	jsr	_LVOForbid(a6)
	lea	GfxName(pc),a1
	moveq	#0,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,GfxBase
	beq	QuitNoGfx

	lea	CUSTOM,a5		; a5 = custom base, kept forever

	move.w	DMACONR(a5),d0
	or.w	#$8000,d0
	move.w	d0,SavedDMA
	move.w	INTENAR(a5),d0
	or.w	#$8000,d0
	move.w	d0,SavedINT

	move.w	#$7fff,INTENA(a5)	; all interrupts off
	move.w	#$7fff,INTREQ(a5)
	move.w	#$7fff,INTREQ(a5)
	move.w	#$7fff,DMACON(a5)	; all DMA off
	move.w	#$00ff,ADKCON(a5)	; no audio modulation

	bsr	InitDisplay
	bsr	InitAudio
	bsr	BuildCopper
	bsr	DrawStars

	move.l	#CopBuf,COP1LCH(a5)
	move.w	COPJMP1(a5),d0
	move.w	#$83e0,DMACON(a5)	; SET|DMAEN|BPL|COP|BLT|SPR

	move.w	#1234,RndSeed
	bsr	TitleEnter

;-------------------------------- main loop, vblank locked
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

;-------------------------------- restore system and exit
Quit:
	moveq	#3,d0			; silence Paula
	lea	AUD0LCH+8(a5),a0
.vol	move.w	#0,(a0)
	lea	$10(a0),a0
	dbf	d0,.vol
	move.w	#$000f,DMACON(a5)

	move.w	#$7fff,DMACON(a5)
	move.w	SavedDMA,DMACON(a5)
	move.l	GfxBase,a1
	move.l	38(a1),COP1LCH(a5)	; gb_copinit
	move.w	COPJMP1(a5),d0
	move.w	SavedINT,INTENA(a5)

	move.l	4.w,a6
	move.l	GfxBase,a1
	jsr	_LVOCloseLibrary(a6)
QuitNoGfx:
	jsr	_LVOPermit(a6)
	moveq	#0,d0
	rts

StateTab:
	dc.l	TitleState
	dc.l	PlayState
	dc.l	DeathState
	dc.l	OverState
	dc.l	WaveState

;-------------------------------- wait for start of vertical blank
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

;-------------------------------- display registers + clear planes
InitDisplay:
	move.w	#$2c81,DIWSTRT(a5)
	move.w	#$2cc1,DIWSTOP(a5)
	move.w	#$0038,DDFSTRT(a5)
	move.w	#$00d0,DDFSTOP(a5)
	move.w	#$3200,BPLCON0(a5)	; 3 bitplanes, colour on
	move.w	#$0000,BPLCON1(a5)
	move.w	#$0024,BPLCON2(a5)	; sprites in front of playfield
	move.w	#0,BPL1MOD(a5)
	move.w	#0,BPL2MOD(a5)

	lea	Plane0,a0		; clear all three planes
	move.w	#PLSIZE*3/4-1,d0
	moveq	#0,d1
.clr	move.l	d1,(a0)+
	dbf	d0,.clr
	rts

;-------------------------------- build copper list in chip ram
BuildCopper:
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

	; sprite pointers
.spr	lea	SprPtrTab(pc),a1
	move.w	#$0120,d2
	moveq	#8-1,d7
.sprl	move.l	(a1)+,d1
	move.w	d2,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d2
	move.w	d2,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d2
	dbf	d7,.sprl

	; palette (reg,value pairs, negative terminator)
	lea	PalTab(pc),a1
.pal	move.w	(a1)+,d0
	bmi.s	.paldone
	move.w	d0,(a0)+
	move.w	(a1)+,(a0)+
	bra.s	.pal
.paldone

	; star twinkle colour, CPU pokes the value word each frame
	move.w	#$0188,(a0)+		; COLOR04
	move.l	a0,TwinkPtr
	move.w	#$0666,(a0)+

	; per-line background gradient + colour bands for COLOR01
	lea	GradTab(pc),a1
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
	move.w	#$0180,(a0)+		; COLOR00 gradient step
	move.w	(a1)+,(a0)+
	addq.w	#4,d4
	cmp.w	#256,d4
	blt.s	.grad

	move.l	#$fffffffe,(a0)+	; end of copper list
	rts

;=====================================================================
; STATE: TITLE
;=====================================================================
TitleEnter:
	move.w	#ST_TITLE,GameState
	clr.w	StateTimer
	st	FireLatch		; require fire release first
	bsr	HideSprites
	bsr	ClearGamePlanes

	lea	TxtTitle(pc),a0		; big 2x title
	moveq	#6,d0			; byte x (=x/8) for 2x renderer
	move.w	#28,d1
	bsr	DrawText2x

	lea	TxtHiHdr(pc),a0
	moveq	#15,d0
	move.w	#76,d1
	bsr	DrawText

	; high score table, 5 entries
	lea	HiTab,a2
	moveq	#0,d6			; entry index
.hisc	move.w	d6,d0
	addq.w	#1,d0
	add.w	#'0',d0
	lea	StrBuf,a0
	move.b	d0,(a0)+
	move.b	#'.',(a0)+
	move.b	#' ',(a0)+
	move.l	(a2)+,d0
	bsr	BCDToStr		; appends 6 digits + nul
	lea	StrBuf,a0
	moveq	#16,d0
	move.w	d6,d1
	mulu	#12,d1
	add.w	#92,d1
	movem.l	d6/a2,-(sp)
	bsr	DrawText
	movem.l	(sp)+,d6/a2
	addq.w	#1,d6
	cmp.w	#5,d6
	blt.s	.hisc

	; point value legend with alien graphics
	lea	SquidA,a0
	move.w	#120,d0
	move.w	#164,d1
	bsr	BlitObj16
	lea	TxtPts30(pc),a0
	moveq	#18,d0
	move.w	#168,d1
	bsr	DrawText
	lea	CrabA,a0
	move.w	#120,d0
	move.w	#180,d1
	bsr	BlitObj16
	lea	TxtPts20(pc),a0
	moveq	#18,d0
	move.w	#184,d1
	bsr	DrawText
	lea	OctoA,a0
	move.w	#120,d0
	move.w	#196,d1
	bsr	BlitObj16
	lea	TxtPts10(pc),a0
	moveq	#18,d0
	move.w	#200,d1
	bsr	DrawText
	rts

TitleState:
	addq.w	#1,StateTimer

	; blink PRESS FIRE
	move.w	StateTimer,d0
	and.w	#63,d0
	bne.s	.noblnk1
	lea	TxtPress(pc),a0
	moveq	#10,d0
	move.w	#226,d1
	bsr	DrawText
	bra.s	.blinkdn
.noblnk1
	cmp.w	#48,d0
	bne.s	.blinkdn
	moveq	#10,d0			; erase: x=80 y=226 w=10 words
	move.w	#226,d1
	moveq	#10,d2
	moveq	#8,d3
	lea	Plane1,a1
	bsr	ClearRect
.blinkdn

	; fire starts the game (after release)
	btst	#7,CIAAPRA
	bne.s	.nofire
	tst.b	FireLatch
	bne.s	.done
	move.w	VHPOSR(a5),d0		; season RNG with beam position
	eor.w	d0,RndSeed
	bra	PlayEnter
.nofire	clr.b	FireLatch
.done	rts

;=====================================================================
; STATE: PLAY  (entered per game / per wave)
;=====================================================================
PlayEnter:
	clr.l	Score
	st	ScoreDirty
	move.w	#3,Lives
	clr.w	Level
	; fall through
WaveEnter:
	move.w	#ST_WAVE,GameState
	move.w	#40,StateTimer
	bsr	HideSprites
	bsr	ClearGamePlanes
	bsr	DrawHud

	; formation setup
	move.w	#FORMX0,FormX
	move.w	Level,d0
	lsl.w	#3,d0
	cmp.w	#48,d0
	ble.s	.capok
	move.w	#48,d0
.capok	add.w	#FORMY0,d0
	move.w	d0,FormY
	move.w	#1,FormDir
	clr.w	DownFlag
	clr.w	AnimFrame
	clr.w	MarchIdx
	move.w	#ROWS*COLS,AlienCnt
	lea	AlienTab,a0
	moveq	#ROWS*COLS-1,d0
.alive	move.b	#1,(a0)+
	dbf	d0,.alive
	bsr	SetMoveDelay
	move.w	MoveDelay,MoveTimer

	clr.w	BulAct
	lea	BombTab,a0
	moveq	#3*3-1,d0
.bz	clr.w	(a0)+
	dbf	d0,.bz
	move.w	#60,BombCd
	clr.w	UfoAct
	move.w	#500,UfoCd

	move.w	#152,PlayerX
	bsr	DrawShields
	bsr	DrawGround
	bsr	DrawLives
	bsr	DrawAliens
	rts

WaveState:
	subq.w	#1,StateTimer
	bne.s	.w
	move.w	#ST_PLAY,GameState
	bsr	UpdatePlayerSpr
.w	rts

PlayState:
	bsr	EraseShots		; CPU-drawn objects off first
	bsr	MoveFormation		; blits: band clear + redraw
	cmp.w	#ST_PLAY,GameState	; invasion may end the game
	bne.s	.bail
	bsr	PlayerControl
	bsr	MoveBullet
	cmp.w	#ST_PLAY,GameState	; wave clear switches state
	bne.s	.bail
	bsr	MoveBombs
	cmp.w	#ST_PLAY,GameState	; player hit switches state
	bne.s	.bail
	bsr	DropBombs
	bsr	UfoLogic
	bsr	DrawShots
	bsr	RenderScores
.bail	rts

;-------------------------------- alien formation movement
SetMoveDelay:
	move.w	AlienCnt,d0
	lsr.w	#1,d0
	addq.w	#2,d0			; 2..29 frames between steps
	move.w	Level,d1
	add.w	d1,d1
	sub.w	d1,d0
	cmp.w	#2,d0
	bge.s	.ok
	moveq	#2,d0
.ok	move.w	d0,MoveDelay
	rts

MoveFormation:
	subq.w	#1,MoveTimer
	beq.s	.step
	rts
.step	move.w	MoveDelay,MoveTimer
	eor.w	#1,AnimFrame

	bsr	PlayMarch		; march bass note

	; vertical step pending?
	tst.w	DownFlag
	beq.s	.horiz
	clr.w	DownFlag
	addq.w	#8,FormY
	neg.w	FormDir
	; invasion check: formation bottom reaching shields?
	move.w	FormY,d0
	add.w	#ROWS*CELLH,d0
	cmp.w	#SHIELDY-8,d0
	blt.s	.redraw
	bra	GameOverEnter
.horiz	move.w	FormDir,d0
	add.w	d0,d0
	add.w	d0,d0			; 4px steps
	add.w	d0,FormX
	; edge check using live-alien extents from last draw
	tst.w	FormDir
	bmi.s	.leftck
	move.w	EdgeMaxX,d0
	add.w	FormX,d0
	cmp.w	#320-20,d0
	blt.s	.redraw
	move.w	#1,DownFlag
	bra.s	.redraw
.leftck	move.w	EdgeMinX,d0
	add.w	FormX,d0
	cmp.w	#8,d0
	bgt.s	.redraw
	move.w	#1,DownFlag
.redraw	bra	DrawAliens

;-------------------------------- redraw whole formation (blitter)
DrawAliens:
	; clear the formation band (full width, from FormY-8)
	move.w	FormY,d1
	subq.w	#8,d1			; cover previous position too
	moveq	#0,d0
	moveq	#20,d2			; 20 words = 320px
	move.w	#ROWS*CELLH+16,d3
	lea	Plane0,a1
	bsr	ClearRect

	move.w	#$7fff,EdgeMinX
	clr.w	EdgeMaxX
	lea	AlienTab,a2
	moveq	#0,d6			; row
.row	moveq	#0,d5			; col
.col	tst.b	(a2)+
	beq.s	.next
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

;-------------------------------- player input + sprite
PlayerControl:
	move.w	JOY1DAT(a5),d0
	btst	#9,d0			; left
	beq.s	.noleft
	subq.w	#2,PlayerX
	cmp.w	#8,PlayerX
	bge.s	.noleft
	move.w	#8,PlayerX
.noleft	btst	#1,d0			; right
	beq.s	.norght
	addq.w	#2,PlayerX
	cmp.w	#296,PlayerX
	ble.s	.norght
	move.w	#296,PlayerX
.norght	bsr	UpdatePlayerSpr

	; fire
	btst	#7,CIAAPRA
	bne.s	.nofire
	tst.w	BulAct
	bne.s	.nofire
	move.w	#1,BulAct
	move.w	PlayerX,d0
	addq.w	#7,d0
	and.w	#$fffe,d0		; even x
	move.w	d0,BulX
	move.w	#PLAYERY-6,BulY
	bsr	SfxShoot
.nofire	rts

;-------------------------------- player bullet
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
	clr.w	UfoAct
	clr.w	BulAct
	bsr	HideUfoSpr
	bsr	SfxUfoHit
	bsr	Random
	and.w	#3,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	UfoPts(pc),a0
	move.l	(a0,d0.w),d0
	bsr	AddScore
	bra	.done
.noufo
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
	add.w	d0,d0
	add.w	d0,d0
	move.l	(a0,d0.w),d0
	bsr	AddScore
	bsr	SfxExplode		; last: PlaySound eats d0-d4
	; wave cleared?
	tst.w	AlienCnt
	bne	.done
	addq.w	#1,Level
	bra	WaveEnter
.noalien
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

;-------------------------------- alien bombs
DropBombs:
	subq.w	#1,BombCd
	bgt	.done
	; reset cooldown (shrinks with level)
	bsr	Random
	and.w	#31,d0
	add.w	#24,d0
	move.w	Level,d1
	lsl.w	#2,d1
	sub.w	d1,d0
	cmp.w	#8,d0
	bge.s	.cdok
	moveq	#8,d0
.cdok	move.w	d0,BombCd
	; free bomb slot?
	lea	BombTab,a0
	moveq	#3-1,d7
.slot	tst.w	(a0)
	beq.s	.found
	addq.l	#6,a0
	dbf	d7,.slot
	bra	.done
.found	; random column with a live alien; lowest alien there drops
	bsr	Random
	and.w	#15,d0
	cmp.w	#COLS,d0
	bge	.done
	move.w	d0,d2			; col
	moveq	#ROWS-1,d3		; scan from bottom
.rows	move.w	d3,d1
	mulu	#COLS,d1
	add.w	d2,d1
	lea	AlienTab,a1
	tst.b	(a1,d1.w)
	bne.s	.drop
	dbf	d3,.rows
	bra	.done
.drop	move.w	#1,(a0)+		; active
	move.w	d2,d0
	lsl.w	#4,d0
	add.w	FormX,d0
	addq.w	#6,d0
	and.w	#$fffe,d0
	move.w	d0,(a0)+		; x
	move.w	d3,d0
	lsl.w	#4,d0
	add.w	FormY,d0
	add.w	#12,d0
	move.w	d0,(a0)			; y
.done	rts

MoveBombs:
	lea	BombTab,a3
	moveq	#3-1,d7
.loop	tst.w	(a3)
	beq	.next
	move.w	4(a3),d1
	addq.w	#2,d1
	move.w	d1,4(a3)
	move.w	2(a3),d0
	; hit ground?
	cmp.w	#GROUNDY-5,d1
	blt.s	.nogrnd
	clr.w	(a3)
	bra	.next
.nogrnd
	; hit player?
	cmp.w	#PLAYERY-4,d1
	blt.s	.noplay
	move.w	PlayerX,d2
	addq.w	#8,d2
	sub.w	d0,d2
	bpl.s	.abs
	neg.w	d2
.abs	cmp.w	#9,d2
	bge.s	.noplay
	clr.w	(a3)
	bra	PlayerHit		; tail call, frame ends there
.noplay
	; hit shield?
	cmp.w	#SHIELDY,d1
	blt.s	.next
	cmp.w	#SHIELDY+16,d1
	bge.s	.next
	addq.w	#4,d1			; test at bomb tip
	bsr	TestPixel
	beq.s	.next
	clr.w	(a3)
	move.w	2(a3),d0
	move.w	4(a3),d1
	addq.w	#4,d1
	bsr	BlastShield
.next	addq.l	#6,a3
	dbf	d7,.loop
	rts

;=====================================================================
; STATE: DEATH / GAME OVER
;=====================================================================
PlayerHit:
	move.w	#ST_DEATH,GameState
	move.w	#60,StateTimer
	bsr	SfxDeath
	bsr	HidePlayerSpr
	move.w	PlayerX,d0		; explosion where the cannon was
	move.w	#PLAYERY,d1
	lea	ExplGfx,a0
	bra	BlitObj16

DeathState:
	subq.w	#1,StateTimer
	bne.s	.wait
	; wipe the explosion (32px window, nothing else lives there)
	move.w	PlayerX,d0
	lsr.w	#4,d0
	add.w	d0,d0			; word-aligned byte offset
	move.w	#PLAYERY,d1
	moveq	#3,d2
	moveq	#8,d3
	lea	Plane0,a1
	bsr	ClearRectB
	subq.w	#1,Lives
	bsr	DrawLives
	tst.w	Lives
	ble	GameOverEnter
	move.w	#152,PlayerX
	bsr	UpdatePlayerSpr
	move.w	#ST_PLAY,GameState
.wait	rts

GameOverEnter:
	move.w	#ST_OVER,GameState
	move.w	#200,StateTimer
	bsr	HideSprites
	lea	TxtOver(pc),a0
	moveq	#15,d0
	move.w	#120,d1
	bsr	DrawText
	; merge score into the high-score table
	move.l	Score,d0
	lea	HiTab,a0
	moveq	#0,d2			; slot index
.find	cmp.l	(a0)+,d0
	bhi.s	.insert
	addq.w	#1,d2
	cmp.w	#5,d2
	blt.s	.find
	rts				; not good enough, dawg
.insert	lea	HiTab+16,a1		; shift lower entries down
	moveq	#4,d1
.shift	cmp.w	d2,d1
	ble.s	.place
	move.l	-4(a1),(a1)
	subq.l	#4,a1
	subq.w	#1,d1
	bra.s	.shift
.place	move.l	d0,(a1)
	rts

OverState:
	subq.w	#1,StateTimer
	bne.s	.wait
	bra	TitleEnter
.wait	rts

;=====================================================================
; UFO
;=====================================================================
UfoLogic:
	tst.w	UfoAct
	bne.s	.active
	subq.w	#1,UfoCd
	bgt.s	.done
	move.w	#1,UfoAct		; spawn
	bsr	SfxUfoStart
	bsr	Random
	and.w	#$01ff,d0
	add.w	#600,d0
	move.w	d0,UfoCd
	bsr	Random
	and.w	#1,d0
	bne.s	.fromr
	move.w	#1,UfoDir
	move.w	#-16,UfoX
	bra.s	.active
.fromr	move.w	#-1,UfoDir
	move.w	#320,UfoX
.active	move.w	UfoDir,d0
	add.w	d0,UfoX
	move.w	UfoX,d0
	cmp.w	#-16,d0
	blt.s	.gone
	cmp.w	#320,d0
	bgt.s	.gone
	bra	UpdateUfoSpr
.gone	clr.w	UfoAct
	bsr	HideUfoSpr
	bra	SfxUfoStop
.done	rts

;=====================================================================
; SPRITES
;=====================================================================
; d0=screen x, d1=screen y, d2=height, a0=sprite data
SetSprPos:
	add.w	#$81,d0			; hardware hstart
	add.w	#44,d1			; hardware vstart
	move.w	d1,d3
	add.w	d2,d3			; vstop
	moveq	#0,d4
	move.b	d1,d4
	lsl.w	#8,d4
	move.w	d0,d5
	lsr.w	#1,d5
	and.w	#$ff,d5
	or.w	d5,d4
	move.w	d4,(a0)			; SPRxPOS
	moveq	#0,d4
	move.b	d3,d4
	lsl.w	#8,d4
	btst	#8,d1
	beq.s	.nv8
	or.w	#4,d4
.nv8	btst	#8,d3
	beq.s	.ns8
	or.w	#2,d4
.ns8	btst	#0,d0
	beq.s	.nh0
	or.w	#1,d4
.nh0	move.w	d4,2(a0)		; SPRxCTL
	rts

UpdatePlayerSpr:
	move.w	PlayerX,d0
	move.w	#PLAYERY,d1
	moveq	#8,d2
	lea	PlayerSpr,a0
	bra.s	SetSprPos

UpdateUfoSpr:
	move.w	UfoX,d0
	moveq	#20,d1
	moveq	#7,d2
	lea	UfoSpr,a0
	bra.s	SetSprPos

HidePlayerSpr:
	lea	PlayerSpr,a0
	clr.l	(a0)
	rts

HideUfoSpr:
	lea	UfoSpr,a0
	clr.l	(a0)
	rts

HideSprites:
	bsr.s	HidePlayerSpr
	bsr.s	HideUfoSpr
	bra	SfxUfoStop

;=====================================================================
; BLITTER HELPERS
;=====================================================================
; d0=x px, d1=y px -> a1 = Plane0 word-aligned dest (trashes d4/d5)
CalcP0Word:
	move.w	d1,d4
	lsl.w	#5,d4
	move.w	d1,d5
	lsl.w	#3,d5
	add.w	d5,d4			; y*40
	move.w	d0,d5
	lsr.w	#4,d5
	add.w	d5,d5
	add.w	d5,d4
	ext.l	d4
	lea	Plane0,a1
	add.l	d4,a1
	rts

;--- OR-blit 16x8 object: a0=gfx (8 rows x 2 words), d0=x, d1=y
BlitObj16:
	WAITBLT
	bsr.s	CalcP0Word
	move.w	d0,d2
	and.w	#15,d2
	ror.w	#4,d2
	or.w	#$0bfa,d2		; USEA/USEC/USED, D = A|C
	move.w	d2,BLTCON0(a5)
	move.w	#0,BLTCON1(a5)
	move.l	#$ffffffff,BLTAFWM(a5)
	move.w	#0,BLTAMOD(a5)
	move.w	#36,BLTCMOD(a5)
	move.w	#36,BLTDMOD(a5)
	move.l	a0,BLTAPTH(a5)
	move.l	a1,BLTCPTH(a5)
	move.l	a1,BLTDPTH(a5)
	move.w	#(8<<6)+2,BLTSIZE(a5)
	rts

;--- cookie-cut cell replace: gfx replaces 16px cell, neighbours kept
; a0=gfx, d0=x, d1=y   D = A | (~B & C), B = solid cell mask
BlitCell:
	WAITBLT
	bsr.s	CalcP0Word
	move.w	d0,d2
	and.w	#15,d2
	ror.w	#4,d2
	move.w	d2,d3
	or.w	#$0ff2,d2		; USEA/USEB/USEC/USED, LF $F2
	move.w	d2,BLTCON0(a5)
	move.w	d3,BLTCON1(a5)		; B shift = A shift
	move.l	#$ffffffff,BLTAFWM(a5)
	move.w	#0,BLTAMOD(a5)
	move.w	#0,BLTBMOD(a5)
	move.w	#36,BLTCMOD(a5)
	move.w	#36,BLTDMOD(a5)
	move.l	a0,BLTAPTH(a5)
	move.l	#CellMask,BLTBPTH(a5)
	move.l	a1,BLTCPTH(a5)
	move.l	a1,BLTDPTH(a5)
	move.w	#(8<<6)+2,BLTSIZE(a5)
	rts

;--- rectangle clear: d0=x(words), d1=y, d2=w(words), d3=h, a1=plane
ClearRect:
	add.w	d0,d0
ClearRectB:				; d0 = byte offset variant
	WAITBLT
	move.w	d1,d4
	lsl.w	#5,d4
	move.w	d1,d5
	lsl.w	#3,d5
	add.w	d5,d4
	add.w	d0,d4
	ext.l	d4
	add.l	d4,a1
	move.w	#$0100,BLTCON0(a5)	; USED only, LF=0 -> zeros
	move.w	#0,BLTCON1(a5)
	moveq	#40,d4
	move.w	d2,d5
	add.w	d5,d5
	sub.w	d5,d4
	move.w	d4,BLTDMOD(a5)
	move.l	a1,BLTDPTH(a5)
	move.w	d3,d4
	lsl.w	#6,d4
	or.w	d2,d4
	move.w	d4,BLTSIZE(a5)
	rts

ClearGamePlanes:
	moveq	#0,d0
	moveq	#0,d1
	moveq	#20,d2
	move.w	#256,d3
	lea	Plane0,a1
	bsr.s	ClearRect
	moveq	#0,d0
	moveq	#0,d1
	moveq	#20,d2
	move.w	#256,d3
	lea	Plane1,a1
	bra.s	ClearRect

;=====================================================================
; CPU DRAWING
;=====================================================================
; d0=x, d1=y -> a1 = Plane0 byte address, d5 = 2px mask (x even)
CalcP0Pix:
	move.w	d1,d4
	lsl.w	#5,d4
	move.w	d1,d5
	lsl.w	#3,d5
	add.w	d5,d4
	move.w	d0,d5
	lsr.w	#3,d5
	add.w	d5,d4
	ext.l	d4
	lea	Plane0,a1
	add.l	d4,a1
	move.w	d0,d4
	and.w	#7,d4
	move.b	#$c0,d5
	lsr.b	d4,d5
	rts

; d0=x(even), d1=y, d2=height-1
DrawVLine:
	bsr.s	CalcP0Pix
.dl	or.b	d5,(a1)
	lea	40(a1),a1
	dbf	d2,.dl
	rts

EraseVLine:
	bsr.s	CalcP0Pix
	not.b	d5
.el	and.b	d5,(a1)
	lea	40(a1),a1
	dbf	d2,.el
	rts

; test 2px at d0=x, d1=y in Plane0 -> NE if any pixel set
TestPixel:
	movem.l	d4/d5/a1,-(sp)
	WAITBLT
	bsr.s	CalcP0Pix
	and.b	(a1),d5
	movem.l	(sp)+,d4/d5/a1	; movem keeps flags
	rts

EraseShots:
	WAITBLT
	tst.w	BulAct
	beq.s	.nobul
	move.w	BulX,d0
	move.w	BulY,d1
	moveq	#6-1,d2
	bsr.s	EraseVLine
.nobul	lea	BombTab,a3
	moveq	#3-1,d3
.bl	tst.w	(a3)
	beq.s	.nb
	move.w	2(a3),d0
	move.w	4(a3),d1
	moveq	#5-1,d2
	bsr.s	EraseVLine
.nb	addq.l	#6,a3
	dbf	d3,.bl
	rts

DrawShots:
	WAITBLT
	tst.w	BulAct
	beq.s	.nobul
	move.w	BulX,d0
	move.w	BulY,d1
	moveq	#6-1,d2
	bsr	DrawVLine
.nobul	lea	BombTab,a3
	moveq	#3-1,d3
.bl	tst.w	(a3)
	beq.s	.nb
	move.w	2(a3),d0
	move.w	4(a3),d1
	moveq	#5-1,d2
	bsr	DrawVLine
.nb	addq.l	#6,a3
	dbf	d3,.bl
	rts

;--- punch a hole in a shield around d0=x, d1=y
BlastShield:
	movem.l	d2-d5/a0/a1,-(sp)
	WAITBLT
	subq.w	#4,d0
	subq.w	#2,d1
	move.w	d1,d4
	lsl.w	#5,d4
	move.w	d1,d5
	lsl.w	#3,d5
	add.w	d5,d4
	move.w	d0,d5
	lsr.w	#3,d5
	add.w	d5,d4
	ext.l	d4
	lea	Plane0,a1
	add.l	d4,a1
	move.w	d0,d2
	and.w	#7,d2
	moveq	#8,d3
	sub.w	d2,d3			; left shift for 16-bit window
	lea	BlastMask(pc),a0
	moveq	#6-1,d5
.row	moveq	#0,d2
	move.b	(a0)+,d2
	lsl.w	d3,d2
	not.w	d2
	and.b	d2,1(a1)
	move.w	d2,d4
	lsr.w	#8,d4
	and.b	d4,(a1)
	lea	40(a1),a1
	dbf	d5,.row
	movem.l	(sp)+,d2-d5/a0/a1
	bra	SfxShieldHit

BlastMask:
	dc.b	$3c,$7e,$ff,$ff,$7e,$3c
	even

;=====================================================================
; SHIELDS / GROUND / HUD
;=====================================================================
DrawShields:
	WAITBLT
	moveq	#4-1,d7
	lea	Plane0+SHIELDY*40+6,a1
.sh	lea	ShieldGfx(pc),a0
	move.l	a1,a2
	moveq	#16-1,d6
.row	move.b	(a0)+,(a2)
	move.b	(a0)+,1(a2)
	move.b	(a0)+,2(a2)
	lea	40(a2),a2
	dbf	d6,.row
	addq.l	#8,a1			; next shield 64px right
	dbf	d7,.sh
	rts

DrawGround:
	WAITBLT
	lea	Plane0+GROUNDY*40,a0
	moveq	#40/4-1,d0
	moveq	#-1,d1
.g	move.l	d1,(a0)+
	dbf	d0,.g
	rts

DrawLives:
	moveq	#0,d0
	move.w	#240,d1
	moveq	#6,d2
	moveq	#8,d3
	lea	Plane0,a1
	bsr	ClearRect
	move.w	Lives,d7
	subq.w	#1,d7
	ble.s	.done
	moveq	#8,d6			; x
.ic	move.w	d6,d0
	move.w	#240,d1
	lea	LifeIcon,a0
	movem.l	d6/d7,-(sp)
	bsr	BlitObj16
	movem.l	(sp)+,d6/d7
	add.w	#24,d6
	subq.w	#1,d7
	bne.s	.ic
.done	rts

DrawHud:
	lea	TxtScore(pc),a0
	moveq	#2,d0
	moveq	#4,d1
	bsr	DrawText
	lea	TxtHi(pc),a0
	moveq	#22,d0
	moveq	#4,d1
	bsr	DrawText
	st	ScoreDirty
	st	HiDirty
	rts

RenderScores:
	tst.b	ScoreDirty
	beq.s	.nos
	clr.b	ScoreDirty
	lea	StrBuf,a0
	move.l	Score,d0
	bsr	BCDToStr
	lea	StrBuf,a0
	moveq	#8,d0
	moveq	#4,d1
	bsr	DrawText
.nos	tst.b	HiDirty
	beq.s	.noh
	clr.b	HiDirty
	lea	StrBuf,a0
	move.l	HiScore,d0
	bsr	BCDToStr
	lea	StrBuf,a0
	moveq	#25,d0
	moveq	#4,d1
	bsr	DrawText
.noh	rts

;=====================================================================
; SCORE (BCD)
;=====================================================================
; d0.l = BCD points to add
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
	move.l	Score,d0
	cmp.l	HiScore,d0
	bls.s	.nohi
	move.l	d0,HiScore
	st	HiDirty
.nohi	rts

; d0.l = BCD (6 digits), a0 = dest string (advances, nul-terminated)
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
	rts

;=====================================================================
; TEXT RENDERING (into Plane1)
;=====================================================================
; a0=nul-terminated string, d0=byte x (x/8), d1=y
DrawText:
	movem.l	d2-d3/a1-a3,-(sp)
	WAITBLT
	lea	Plane1,a1
	move.w	d1,d2
	lsl.w	#5,d2
	move.w	d1,d3
	lsl.w	#3,d3
	add.w	d3,d2
	add.w	d0,d2
	ext.l	d2
	add.l	d2,a1
	lea	Font,a3
.ch	moveq	#0,d2
	move.b	(a0)+,d2
	beq.s	.done
	sub.w	#32,d2
	lsl.w	#3,d2
	lea	(a3,d2.w),a2
	move.b	(a2)+,(a1)
	move.b	(a2)+,40(a1)
	move.b	(a2)+,80(a1)
	move.b	(a2)+,120(a1)
	move.b	(a2)+,160(a1)
	move.b	(a2)+,200(a1)
	move.b	(a2)+,240(a1)
	move.b	(a2)+,280(a1)
	addq.l	#1,a1
	bra.s	.ch
.done	movem.l	(sp)+,d2-d3/a1-a3
	rts

; double-size text: a0=string, d0=byte x, d1=y
DrawText2x:
	movem.l	d2-d4/a1-a4,-(sp)
	WAITBLT
	lea	Plane1,a1
	move.w	d1,d2
	lsl.w	#5,d2
	move.w	d1,d3
	lsl.w	#3,d3
	add.w	d3,d2
	add.w	d0,d2
	ext.l	d2
	add.l	d2,a1
	lea	Font,a3
	lea	NibExp(pc),a4
.ch	moveq	#0,d2
	move.b	(a0)+,d2
	beq.s	.done
	sub.w	#32,d2
	lsl.w	#3,d2
	lea	(a3,d2.w),a2
	moveq	#8-1,d3
.row	moveq	#0,d2
	move.b	(a2)+,d2
	move.w	d2,d4
	lsr.w	#4,d4
	move.b	(a4,d4.w),(a1)
	move.b	(a4,d4.w),40(a1)
	and.w	#$0f,d2
	move.b	(a4,d2.w),1(a1)
	move.b	(a4,d2.w),41(a1)
	lea	80(a1),a1
	dbf	d3,.row
	lea	-638(a1),a1		; back to top, 2 bytes right
	bra.s	.ch
.done	movem.l	(sp)+,d2-d4/a1-a4
	rts

NibExp:
	dc.b	$00,$03,$0c,$0f,$30,$33,$3c,$3f
	dc.b	$c0,$c3,$cc,$cf,$f0,$f3,$fc,$ff

;=====================================================================
; STARFIELD
;=====================================================================
DrawStars:
	lea	Plane2,a1
	moveq	#80-1,d7
.st	bsr	Random
	move.w	d0,d1
	and.w	#$ff,d1			; y
	cmp.w	#20,d1
	blo.s	.st
	cmp.w	#228,d1
	bhs.s	.st
	move.w	d0,d2
	lsr.w	#8,d2			; x 0..255
	move.w	d1,d3
	lsl.w	#5,d3
	move.w	d1,d4
	lsl.w	#3,d4
	add.w	d4,d3
	move.w	d2,d4
	lsr.w	#3,d4
	add.w	d4,d3
	move.w	d2,d4
	and.w	#7,d4
	moveq	#7,d5
	sub.w	d4,d5
	bset	d5,(a1,d3.w)
	dbf	d7,.st
	rts

TwinkleStars:
	move.l	TwinkPtr,a0
	move.l	Frame,d0
	lsr.l	#3,d0
	and.w	#7,d0
	add.w	d0,d0
	lea	StarCols(pc),a1
	move.w	(a1,d0.w),(a0)
	rts

StarCols:
	dc.w	$0446,$0557,$0668,$077a,$0889,$0778,$0667,$0556

;=====================================================================
; RANDOM
;=====================================================================
Random:
	move.w	RndSeed,d0
	add.w	d0,d0
	bcc.s	.nc
	eor.w	#$1d87,d0
.nc	tst.w	d0
	bne.s	.ok
	move.w	#$7717,d0
.ok	move.w	d0,RndSeed
	rts

;=====================================================================
; AUDIO (Paula)
; ch0 = march bass, ch1 = player shot, ch2 = explosions, ch3 = UFO
;=====================================================================
InitAudio:
	lea	SqBuf,a0		; 32-byte square wave
	moveq	#16-1,d0
.sq1	move.b	#$7f,(a0)+
	dbf	d0,.sq1
	moveq	#16-1,d0
.sq2	move.b	#$81,(a0)+
	dbf	d0,.sq2
	lea	NoiseBuf,a0		; 1k of LFSR noise
	move.w	#$ace1,d1
	move.w	#1024-1,d0
.nz	move.b	d1,(a0)+
	move.w	d1,d2
	lsr.w	#1,d1
	and.w	#1,d2
	beq.s	.noeor
	eor.w	#$b400,d1
.noeor	dbf	d0,.nz
	rts

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

SfxShoot:
	moveq	#1,d0
	lea	NoiseBuf,a0
	move.w	#256,d1
	move.w	#140,d2
	move.w	#38,d3
	moveq	#8,d4
	bra	PlaySound

SfxExplode:
	moveq	#2,d0
	lea	NoiseBuf,a0
	move.w	#512,d1
	move.w	#380,d2
	move.w	#55,d3
	moveq	#14,d4
	bra	PlaySound

SfxShieldHit:
	moveq	#2,d0
	lea	NoiseBuf,a0
	move.w	#256,d1
	move.w	#520,d2
	move.w	#28,d3
	moveq	#7,d4
	bra	PlaySound

SfxUfoHit:
	moveq	#2,d0
	lea	NoiseBuf,a0
	move.w	#512,d1
	move.w	#260,d2
	move.w	#60,d3
	moveq	#20,d4
	bra	PlaySound

SfxDeath:
	moveq	#2,d0
	lea	NoiseBuf,a0
	move.w	#512,d1
	move.w	#700,d2
	move.w	#64,d3
	move.w	#30,d4
	bra	PlaySound

SfxUfoStart:
	moveq	#3,d0
	lea	SqBuf,a0
	moveq	#16,d1
	move.w	#340,d2
	move.w	#22,d3
	moveq	#0,d4			; loops until stopped
	bra	PlaySound

SfxUfoStop:
	move.w	#$0008,DMACON(a5)
	move.w	#0,AUD0LCH+$38(a5)	; AUD3VOL
	lea	ChTime,a0
	clr.w	6(a0)
	rts

MarchPer:
	dc.w	2015,2151,2287,2423
SinTab:
	dc.b	0,6,12,18,24,30,36,42,48,54,60,66,72,78,84,90
	dc.b	96,90,84,78,72,66,60,54,48,42,36,30,24,18,12,6
	even

;=====================================================================
; CPU DATA (code section: reachable pc-relative, no chip needed)
;=====================================================================
GfxName:
	dc.b	'graphics.library',0
	even

TxtTitle:	dc.b	'SPACE INVADERS',0
TxtHiHdr:	dc.b	'HIGH SCORES',0
TxtPress:	dc.b	'PRESS FIRE TO START',0
TxtOver:	dc.b	'GAME OVER',0
TxtScore:	dc.b	'SCORE',0
TxtHi:		dc.b	'HI',0
TxtPts30:	dc.b	'= 30 PTS',0
TxtPts20:	dc.b	'= 20 PTS',0
TxtPts10:	dc.b	'= 10 PTS',0
	even

RowType:
	dc.b	0,1,1,2,2		; squid / crab crab / octo octo
	even

AlienGfxTab:
	dc.l	SquidA,SquidB
	dc.l	CrabA,CrabB
	dc.l	OctoA,OctoB

RowPts:					; BCD points per row
	dc.l	$30,$20,$20,$10,$10
UfoPts:
	dc.l	$50,$100,$150,$300

SprPtrTab:
	dc.l	PlayerSpr,BlankSpr
	dc.l	UfoSpr,BlankSpr
	dc.l	BlankSpr,BlankSpr
	dc.l	BlankSpr,BlankSpr

PalTab:					; copper palette, reg/value
	dc.w	$0180,$0000
	dc.w	$0182,$0fff		; col1: game objects
	dc.w	$0184,$0fff		; col2: text
	dc.w	$0186,$0fff
	dc.w	$018a,$0fff		; star overlaps
	dc.w	$018c,$0fff
	dc.w	$018e,$0fff
	dc.w	$01a2,$0053		; player sprite
	dc.w	$01a4,$00c6
	dc.w	$01a6,$08fb
	dc.w	$01aa,$0625		; UFO sprite
	dc.w	$01ac,$0b3c
	dc.w	$01ae,$0f7f
	dc.w	$ffff

BandTab:				; COLOR01 per screen region
	dc.w	40,$0f55		; top alien rows: red
	dc.w	72,$0fa4		; orange
	dc.w	104,$0fe5		; yellow
	dc.w	136,$05fa		; green-cyan
	dc.w	168,$04cf		; cyan
	dc.w	188,$03f6		; shields + player zone: green
	dc.w	$7fff,0

GradTab:				; COLOR00, one entry per 4 lines
	dc.w	$0007,$0007,$0006,$0006,$0005,$0005,$0004,$0004
	dc.w	$0004,$0003,$0003,$0003,$0002,$0002,$0002,$0002
	dc.w	$0001,$0001,$0001,$0001,$0000,$0000,$0000,$0000
	dc.w	$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
	dc.w	$0000,$0000,$0100,$0100,$0101,$0101,$0102,$0102
	dc.w	$0102,$0103,$0103,$0104,$0104,$0105,$0105,$0106
	dc.w	$0106,$0107,$0107,$0108,$0108,$0209,$0209,$0209
	dc.w	$0206,$0207,$0207,$0208,$0208,$0209,$0209,$020a

ShieldGfx:				; 24x16, CPU drawn
	dc.b	$3f,$ff,$fc
	dc.b	$7f,$ff,$fe
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$ff,$ff
	dc.b	$ff,$e7,$ff
	dc.b	$ff,$c3,$ff
	dc.b	$fc,$00,$3f
	dc.b	$fc,$00,$3f
	even

;--------------------------------------------------------------------
; 8x8 font, ASCII 32..90 (blanks for unused slots)
;--------------------------------------------------------------------
Font:
	dcb.b	8,0			; 32 space
	dc.b	$18,$18,$18,$18,$18,$00,$18,$00	; 33 !
	dcb.b	8*12,0			; 34-45
	dc.b	$00,$00,$00,$00,$00,$18,$18,$00	; 46 .
	dcb.b	8,0			; 47 /
	dc.b	$3c,$66,$6e,$76,$66,$66,$3c,$00	; 0
	dc.b	$18,$38,$18,$18,$18,$18,$7e,$00	; 1
	dc.b	$3c,$66,$06,$0c,$30,$60,$7e,$00	; 2
	dc.b	$3c,$66,$06,$1c,$06,$66,$3c,$00	; 3
	dc.b	$0c,$1c,$3c,$6c,$7e,$0c,$0c,$00	; 4
	dc.b	$7e,$60,$7c,$06,$06,$66,$3c,$00	; 5
	dc.b	$3c,$66,$60,$7c,$66,$66,$3c,$00	; 6
	dc.b	$7e,$06,$0c,$18,$30,$30,$30,$00	; 7
	dc.b	$3c,$66,$66,$3c,$66,$66,$3c,$00	; 8
	dc.b	$3c,$66,$66,$3e,$06,$66,$3c,$00	; 9
	dcb.b	8*3,0			; 58-60
	dc.b	$00,$00,$7e,$00,$7e,$00,$00,$00	; 61 =
	dcb.b	8*3,0			; 62-64
	dc.b	$18,$3c,$66,$66,$7e,$66,$66,$00	; A
	dc.b	$7c,$66,$66,$7c,$66,$66,$7c,$00	; B
	dc.b	$3c,$66,$60,$60,$60,$66,$3c,$00	; C
	dc.b	$78,$6c,$66,$66,$66,$6c,$78,$00	; D
	dc.b	$7e,$60,$60,$78,$60,$60,$7e,$00	; E
	dc.b	$7e,$60,$60,$78,$60,$60,$60,$00	; F
	dc.b	$3c,$66,$60,$6e,$66,$66,$3e,$00	; G
	dc.b	$66,$66,$66,$7e,$66,$66,$66,$00	; H
	dc.b	$3c,$18,$18,$18,$18,$18,$3c,$00	; I
	dc.b	$1e,$0c,$0c,$0c,$0c,$6c,$38,$00	; J
	dc.b	$66,$6c,$78,$70,$78,$6c,$66,$00	; K
	dc.b	$60,$60,$60,$60,$60,$60,$7e,$00	; L
	dc.b	$63,$77,$7f,$6b,$63,$63,$63,$00	; M
	dc.b	$66,$76,$7e,$7e,$6e,$66,$66,$00	; N
	dc.b	$3c,$66,$66,$66,$66,$66,$3c,$00	; O
	dc.b	$7c,$66,$66,$7c,$60,$60,$60,$00	; P
	dc.b	$3c,$66,$66,$66,$66,$3c,$0e,$00	; Q
	dc.b	$7c,$66,$66,$7c,$78,$6c,$66,$00	; R
	dc.b	$3c,$66,$60,$3c,$06,$66,$3c,$00	; S
	dc.b	$7e,$18,$18,$18,$18,$18,$18,$00	; T
	dc.b	$66,$66,$66,$66,$66,$66,$3c,$00	; U
	dc.b	$66,$66,$66,$66,$66,$3c,$18,$00	; V
	dc.b	$63,$63,$63,$6b,$7f,$77,$63,$00	; W
	dc.b	$66,$66,$3c,$18,$3c,$66,$66,$00	; X
	dc.b	$66,$66,$66,$3c,$18,$18,$18,$00	; Y
	dc.b	$7e,$06,$0c,$18,$30,$60,$7e,$00	; Z
	even

;=====================================================================
	section	chipdata,data_c
;=====================================================================

; sprites: pos,ctl then A/B word pairs per line, 0,0 terminator
PlayerSpr:
	dc.w	0,0
	dc.w	$0180,$0180
	dc.w	$0180,$0180
	dc.w	$0180,$07e0
	dc.w	$0180,$07e0
	dc.w	$0000,$3ffc
	dc.w	$0000,$7ffe
	dc.w	$0000,$ffff
	dc.w	$0000,$ffff
	dc.w	0,0

UfoSpr:
	dc.w	0,0
	dc.w	$0000,$07e0
	dc.w	$0000,$1ff8
	dc.w	$0000,$3ffc
	dc.w	$36d8,$7ffe
	dc.w	$0000,$ffff
	dc.w	$0000,$39ce
	dc.w	$0000,$0810
	dc.w	0,0

BlankSpr:
	dc.w	0,0
	dc.w	0,0

; blitter objects: 8 rows x 2 words (image word + zero pad)
SquidA:
	dc.w	$0180,0
	dc.w	$03c0,0
	dc.w	$07e0,0
	dc.w	$0db0,0
	dc.w	$0ff0,0
	dc.w	$0240,0
	dc.w	$05a0,0
	dc.w	$0a50,0
SquidB:
	dc.w	$0180,0
	dc.w	$03c0,0
	dc.w	$07e0,0
	dc.w	$0db0,0
	dc.w	$0ff0,0
	dc.w	$0240,0
	dc.w	$0420,0
	dc.w	$0240,0
CrabA:
	dc.w	$0820,0
	dc.w	$0440,0
	dc.w	$0fe0,0
	dc.w	$1bb0,0
	dc.w	$3ff8,0
	dc.w	$2fe8,0
	dc.w	$2828,0
	dc.w	$06c0,0
CrabB:
	dc.w	$0820,0
	dc.w	$2488,0
	dc.w	$2fe8,0
	dc.w	$3bb8,0
	dc.w	$3ff8,0
	dc.w	$1ff0,0
	dc.w	$0820,0
	dc.w	$1010,0
OctoA:
	dc.w	$03c0,0
	dc.w	$1ff8,0
	dc.w	$3ffc,0
	dc.w	$399c,0
	dc.w	$3ffc,0
	dc.w	$0660,0
	dc.w	$1998,0
	dc.w	$2664,0
OctoB:
	dc.w	$03c0,0
	dc.w	$1ff8,0
	dc.w	$3ffc,0
	dc.w	$399c,0
	dc.w	$3ffc,0
	dc.w	$0660,0
	dc.w	$2664,0
	dc.w	$1998,0
ExplGfx:
	dc.w	$0920,0
	dc.w	$4489,0
	dc.w	$2252,0
	dc.w	$0d80,0
	dc.w	$01b0,0
	dc.w	$4a24,0
	dc.w	$8912,0
	dc.w	$2049,0
LifeIcon:
	dc.w	$0180,0
	dc.w	$0180,0
	dc.w	$07e0,0
	dc.w	$07e0,0
	dc.w	$3ffc,0
	dc.w	$7ffe,0
	dc.w	$ffff,0
	dc.w	$ffff,0
CellMask:
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0
	dc.w	$ffff,0

;=====================================================================
	section	data,data
;=====================================================================
HiTab:					; survives between games
	dc.l	$00007500,$00005000,$00004000,$00003000,$00002000
HiScore:
	dc.l	$00007500

;=====================================================================
	section	bss,bss
;=====================================================================
GfxBase		ds.l	1
TwinkPtr	ds.l	1
Frame		ds.l	1
Score		ds.l	1
TmpBCD		ds.l	1
SavedDMA	ds.w	1
SavedINT	ds.w	1
GameState	ds.w	1
StateTimer	ds.w	1
RndSeed		ds.w	1
Lives		ds.w	1
Level		ds.w	1
FormX		ds.w	1
FormY		ds.w	1
FormDir		ds.w	1
DownFlag	ds.w	1
MoveTimer	ds.w	1
MoveDelay	ds.w	1
AnimFrame	ds.w	1
MarchIdx	ds.w	1
AlienCnt	ds.w	1
EdgeMinX	ds.w	1
EdgeMaxX	ds.w	1
BulAct		ds.w	1
BulX		ds.w	1
BulY		ds.w	1
BombTab		ds.w	9
BombCd		ds.w	1
PlayerX		ds.w	1
UfoAct		ds.w	1
UfoX		ds.w	1
UfoDir		ds.w	1
UfoCd		ds.w	1
ChTime		ds.w	4
AlienTab	ds.b	ROWS*COLS
ScoreDirty	ds.b	1
HiDirty		ds.b	1
FireLatch	ds.b	1
StrBuf		ds.b	16

;=====================================================================
	section	chipbss,bss_c
;=====================================================================
Plane0		ds.b	PLSIZE
Plane1		ds.b	PLSIZE
Plane2		ds.b	PLSIZE
CopBuf		ds.b	4096
SqBuf		ds.b	32
NoiseBuf	ds.b	1024
