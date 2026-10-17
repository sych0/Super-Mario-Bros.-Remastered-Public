class_name BattleAttackFlight
extends RefCounted
## One of the real player's sends in the air: the reticle's trip from the middle of the game window to the recipient's pane. Presentation
## only. It is created by BattleAttackPresentation when the authoritative SENT event for `seq` is read, carries nothing but the plain
## facts of that event (who, to whom, which enemy) and a start time on the presentation clock, and is never read back by the session.
##
## Only the real player's sends are flights (doc 47 B35-TARGET-003, measured at 60 fps in doc 54): the bracket moves in a straight line at
## constant speed for BattleSendStyle.SECONDS (15 frames) and nothing else is drawn for it. A bot's send is not a flight: the thin red
## lines of the reference belong to the opponents who are AIMING at the real player (BattleAttackPresentation.lines), not to sends, and a
## bot's send at another bot is not presented at all (B35-ATTACK-002). A newer send of the player's cancels an older one still in the
## air (`cancel`): the old bracket is gone on the next frame and never lands, as in the reference.
## Where it is drawn is the view's business (BattleAttackGeometry, BattleTargetReticle); this class only knows how far along it is.

const SEND_SECONDS := BattleSendStyle.SECONDS ## the player's reticle flight (15 frames; BattleSendStyle)
const CUT_FADE := 0.12 ## a flight whose target was eliminated fades out this fast

var seq := 0 ## the authoritative attack's sequence id (BattleAttack.seq)
var duration := SEND_SECONDS ## seconds from the window to the target
var sender := 0
var target := 0
var kind := 0 ## BattleEnemyType.Kind
var born := 0.0 ## presentation clock when it was started
var cut_at := -1.0 ## presentation clock when its target was eliminated (-1: it was not)
var cancelled_at := -1.0 ## presentation clock when a newer send of the player's took over (-1: it was not)

## 0..1: how far the bracket is along its line, linear in time (the reference moves it the same distance every frame).
func travel(clock: float) -> float:
	return clampf((clock - born) / duration, 0.0, 1.0)

## The bracket's position along the line, 0..1. Linear: BattleSendStyle.ease is the identity, kept as the one place that would say otherwise.
func eased(clock: float) -> float:
	return BattleSendStyle.ease(clampf((clock - born - BattleSendStyle.HOLD_SECONDS) / maxf(duration - BattleSendStyle.HOLD_SECONDS, 0.001), 0.0, 1.0))

func arrived(clock: float) -> bool:
	return clock >= born + duration

## A newer send of the player's took over: this bracket is gone from now on.
func cancel(clock: float) -> void:
	if cancelled_at < 0.0:
		cancelled_at = clock

## 1 while the bracket is in the air, fading to 0 only when its target was eliminated; 0 once it has landed or been cancelled.
func strength(clock: float) -> float:
	if cancelled_at >= 0.0 and clock >= cancelled_at:
		return 0.0
	if cut_at >= 0.0:
		return clampf(1.0 - (clock - cut_at) / CUT_FADE, 0.0, 1.0) if clock >= cut_at else 1.0
	return 1.0 if clock <= born + duration else 0.0

func finished(clock: float) -> bool:
	return strength(clock) <= 0.0

## How long a send from `sender` takes to land: the player's reticle flight (the only kind there is).
static func duration_for(_sender: int) -> float:
	return SEND_SECONDS
