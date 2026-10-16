class_name BattleSendStyle
extends RefCounted
## Every tunable of the player's send animation in one place (doc 51): the reticle's flight from the game window to the recipient's
## pane. Each constant says where its value comes from. Doc 47 B35-TARGET-003 records the flight from the reference at 10 fps; the
## values marked UNMEASURED are not in doc 47 and could not be read from the video in the session that wrote this (the video was
## not reachable there); `tools/reference/measure_reference.py --mode reticle` measures every one of them locally, and applying the
## numbers is an edit of this file only. Pure: no scene tree.

## Doc 47: "within 0.2-0.3 s it lands on the recipient's pane" (leaves its old pane, appears in the window, lands). The split between
## a hold at the origin and the flight itself is UNMEASURED; the whole 0.25 s is the flight.
const SECONDS := 0.25
## The origin is the middle of the game window (BattleAttackGeometry.send_start). Doc 47: 8 of the 10 sampled sends show the bracket
## at the exact window centre (1080p 960,480); the other two are consistent with mid-flight samples of a flight from the centre. The
## defeated enemy's position is the alternative; it would need a hand-off from the enemy and is not built (doc 51, unresolved).
## Seconds the bracket sits at the origin before it moves. UNMEASURED (0: it starts moving at once).
const HOLD_SECONDS := 0.0
## The bracket's size at the origin as a multiple of the recipient pane's. UNMEASURED (1: the pane's own size all the way).
const START_SCALE := 1.0
## Doc 47 says "eased". The curve is UNMEASURED: ease-out (fast leave, soft landing), the one the old send line's head used.
static func ease(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u
## How long the recipient's pane punches when the bracket lands (the arrival emphasis). UNMEASURED.
const LANDING_PUNCH_SECONDS := 0.3
