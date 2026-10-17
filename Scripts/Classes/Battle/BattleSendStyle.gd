class_name BattleSendStyle
extends RefCounted
## Every tunable of the player's send animation in one place: the reticle's trip from the middle of the game window to the
## recipient's pane. All of it is MEASURED from the reference video frame by frame at its source 60 fps (doc 54; the video is
## public: https://www.youtube.com/watch?v=AUcFTEfFp58). It supersedes both earlier readings: doc 51's guessed 0.25 s eased glide
## and doc 52's "the bracket holds in the window, then snaps" -- the latter came from contact sheets too coarse to see the
## bracket crossing the window; at 60 fps it is plain.
##
## What 55 sends between t=509 and t=623 show (tools/reference/extract_frames.py and measure_reference.py --mode reticle):
##   * the old bracket leaves its pane on the SAME frame the flying one appears; there is never a frame with neither;
##   * every flight starts at exactly (240.0, 120.0) canvas units, the middle of the game window, in all 55;
##   * it is a straight line at CONSTANT speed (no easing): frame n is at start + (pane centre - start) * n / 15, so the step
##     is the same on every frame (12.5, 8.4 units on the flight of t=526.683);
##   * it reaches the pane's centre on the 15th frame, i.e. FRAMES / 60 = 0.25 s after the frame it started on;
##   * nothing else is drawn: no flash at the window, none at the pane, no ring, no punch on landing (the bracket just stops
##     and settles into its idle pulse, below);
##   * its outer box is the pane's own size all the way: 32.0 x 41.0 on frame 0, 31.0 x 40.0 on landing, 30.5 x 39.0 at rest;
##   * a send that happens while another is in the air CANCELS it: the old bracket is simply gone on the next frame (it never
##     lands) and the new one starts at the window's middle -- there is only ever one bracket in flight (t=549.2 -> 549.217,
##     549.65 -> 549.667).
const FPS := 60.0
const FRAMES := 15 ## frames from the window's middle to the pane's centre
const SECONDS := FRAMES / FPS ## 0.25 s
const HOLD_SECONDS := 0.0 ## it starts moving on its first frame

## Where the outer box sits relative to a pane's own rectangle (all panes are 32.75 x 41.5 canvas units), as the inset on each side.
const REST_INSET := Vector2(1.125, 1.25) ## at rest: 30.5 x 39.0
const START_INSET := Vector2(0.375, 0.25) ## frame 0 of a flight: 32.0 x 41.0
const PEAK_INSET := Vector2(0.5, 0.25) ## the top of the idle pulse: 31.75 x 41.0

## The idle pulse of a bracket that has settled on a pane: a 59-frame (0.9833 s) cycle in which the box swells from rest to the
## peak and falls back (peaks 0.9833 s apart over 40 s of one bracket: 550.658, 551.642, 552.625, 553.608, 554.592). The cycle
## starts at the landing: in the 28 landings whose first peak nothing interrupted, 20 peak 0.76-0.83 s after the bracket first
## overlaps its pane (median 0.81 s; that is a frame or two before it is at the pane's centre), the others are cut short by the
## next send. From the landing the box rests for about 0.54 s, swells for 0.25 s to the peak (0.79 s), falls for 0.30 s and rests
## again until the next swell.
const PULSE_PERIOD := 59.0 / 60.0
const PULSE_RISE_START := 0.54 ## seconds after a landing (and after each period) that the swell begins
const PULSE_PEAK := 0.79 ## ... and the box is at its largest
const PULSE_FALL_END := 1.09 ## ... and it is back at rest (0.107 s into the next period; the next swell begins 0.43 s later)

## How far the box has swollen `age` seconds after the bracket landed: 0 at rest, 1 at the peak. Smooth rise and fall.
static func pulse(age: float) -> float:
	if age < 0.0:
		return 0.0
	var cycle := floori(age / PULSE_PERIOD)
	var phase := age - cycle * PULSE_PERIOD
	var v := _bump(phase)
	if cycle >= 1:
		v = maxf(v, _bump(phase + PULSE_PERIOD)) # the fall of the previous cycle runs a little into this one
	return v

static func _bump(x: float) -> float:
	if x <= PULSE_RISE_START or x >= PULSE_FALL_END:
		return 0.0
	if x <= PULSE_PEAK:
		return _smooth((x - PULSE_RISE_START) / (PULSE_PEAK - PULSE_RISE_START))
	return 1.0 - _smooth((x - PULSE_PEAK) / (PULSE_FALL_END - PULSE_PEAK))

static func _smooth(t: float) -> float:
	var u := clampf(t, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)

## The flight's easing: none. The reference moves the bracket the same distance every frame.
static func ease(t: float) -> float:
	return clampf(t, 0.0, 1.0)
