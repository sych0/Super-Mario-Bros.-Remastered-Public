class_name BattleAttackFlight
extends RefCounted
## One attack's trip across the Battle screen. Presentation only. It is created by BattleAttackPresentation when
## the authoritative SENT event for `seq` is read, carries nothing but the plain facts of that event (who, to whom,
## which enemy) and a start time on the presentation clock, and is never read back by the session.
##
## Two kinds exist, as in the reference (doc 47 B35-TARGET-003, B35-INCOMING-004, B35-ATTACK-002):
##   the real player's send    the reticle itself holds at the game window, then snaps onto the recipient's pane, together
##                             taking SEND_SECONDS (doc 52: the reference shows a hold, not a glide), and nothing else is
##                             drawn for it (no line, no enemy, no pane tint)
##   a bot's send at the player a thin red line runs from the sender's pane into the incoming bar (DURATION, then LINGER)
##   a bot's send at another bot is not presented at all (no flight is created for it)
## Where it is drawn is the view's business (BattleAttackGeometry, BattleTargetReticle, BattleAttackLayer); this class
## only knows how far along it is.

const DURATION := 0.55 ## seconds a bot's red line to the player takes to reach the bar
const SEND_SECONDS := BattleSendStyle.SECONDS ## the player's reticle flight (doc 47: it lands 0.2-0.3 s after it leaves; BattleSendStyle)
const LINGER := 0.3 ## the red line stays this long after its head lands
const CUT_FADE := 0.12 ## a flight whose target was eliminated fades out this fast

var seq := 0 ## the authoritative attack's sequence id (BattleAttack.seq)
var duration := DURATION ## seconds from the sender to the target
var linger := LINGER ## seconds it stays after it landed
var sender := 0
var target := 0
var kind := 0 ## BattleEnemyType.Kind
var born := 0.0 ## presentation clock when it was started
var cut_at := -1.0 ## presentation clock when its target was eliminated (-1: it was not)

## 0..1: how far the head is along the line, linear in time.
func travel(clock: float) -> float:
	return clampf((clock - born) / duration, 0.0, 1.0)

## The head's position along the line, 0..1: it leaves fast and settles on the target (for the player's reticle flight the curve and
## the hold at the start are BattleSendStyle's).
func eased(clock: float) -> float:
	if sender == BattleSession.PLAYER_ID:
		return BattleSendStyle.ease(clampf((clock - born - BattleSendStyle.HOLD_SECONDS) / maxf(duration - BattleSendStyle.HOLD_SECONDS, 0.001), 0.0, 1.0))
	var u := 1.0 - travel(clock)
	return 1.0 - u * u

func arrived(clock: float) -> bool:
	return clock >= born + duration

## 1 while the head is travelling, then fading to 0: the target's marking and the line's opacity.
func strength(clock: float) -> float:
	if cut_at >= 0.0:
		return clampf(1.0 - (clock - cut_at) / CUT_FADE, 0.0, 1.0) if clock >= cut_at else 1.0
	if clock <= born + duration:
		return 1.0
	if linger <= 0.0:
		return 0.0
	return clampf(1.0 - (clock - born - duration) / linger, 0.0, 1.0)

func finished(clock: float) -> bool:
	return strength(clock) <= 0.0

## How long a send from `sender` to `target` takes to land (the player's reticle flight is brisk; a bot's line to the bar is not).
static func duration_for(sender: int) -> float:
	return SEND_SECONDS if sender == BattleSession.PLAYER_ID else DURATION
