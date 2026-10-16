class_name BattleAttackFlight
extends RefCounted
## One attack's trip across the Battle screen: the line that leaves the sender and lands on the
## target. Presentation only. It is created by BattleAttackPresentation when the authoritative SENT
## event for `seq` is read, carries nothing but the plain facts of that event (who, to whom, which
## enemy) and a start time on the presentation clock, and is never read back by the session.
##
## Where it is drawn is the view's business (BattleAttackGeometry + BattleAttackLayer); this class
## only knows how far along it is.

const DURATION := 0.55 ## seconds the head takes from the sender to the target
const LINGER := 0.3 ## the target stays marked this long after the head lands
const CUT_FADE := 0.12 ## a flight whose target was eliminated fades out this fast

var seq := 0 ## the authoritative attack's sequence id (BattleAttack.seq)
var sender := 0
var target := 0
var kind := 0 ## BattleEnemyType.Kind
var born := 0.0 ## presentation clock when it was started
var cut_at := -1.0 ## presentation clock when its target was eliminated (-1: it was not)

## 0..1: how far the head is along the line, linear in time.
func travel(clock: float) -> float:
	return clampf((clock - born) / DURATION, 0.0, 1.0)

## The head's position along the line, 0..1: it leaves fast and settles on the target.
func eased(clock: float) -> float:
	var u := 1.0 - travel(clock)
	return 1.0 - u * u

func arrived(clock: float) -> bool:
	return clock >= born + DURATION

## 1 while the head is travelling, then fading to 0: the target's marking and the line's opacity.
func strength(clock: float) -> float:
	if cut_at >= 0.0:
		return clampf(1.0 - (clock - cut_at) / CUT_FADE, 0.0, 1.0) if clock >= cut_at else 1.0
	if clock <= born + DURATION:
		return 1.0
	return clampf(1.0 - (clock - born - DURATION) / LINGER, 0.0, 1.0)

func finished(clock: float) -> bool:
	return strength(clock) <= 0.0

## How long ago it was launched (for the launch ring), in seconds.
func age(clock: float) -> float:
	return clock - born
