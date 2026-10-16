class_name BattleContestant
extends RefCounted
## Plain state for one Battle contestant. Slot 0 is the real player; 1+ are simulated bots.

var id := 0
var is_bot := true
var alive := true
var ko_tick := -1
var ko_cause := BattleSession.KoCause.NONE
var placement := 0 # 0 = undecided, 1 = winner

var levels_cleared := 0
var progress := 0.0 # 0..1 within the current level
var time_left := 0 # match-long seconds, owned by the session
var power := 0 # 0 small, 1 big, 2 fire
var skill := 0.5

## Unique rank (higher is better) drawn once from the match seed. Resolves exact ties
## without using the contestant id.
var tiebreak := 0

# Reserved for later phases; not interpreted yet.
var ko_by := -1
var incoming := 0

## Who this contestant is aiming at right now: an alive contestant other than itself, or -1 (nobody else
## is in, it is out, or the attack loop is off). Owned by BattleAttackSystem (doc 47 B35-TARGET-001).
var target_id := -1

## True if this contestant out-ranks `other` while both are still in the running.
func outranks(other: BattleContestant) -> bool:
	if levels_cleared != other.levels_cleared:
		return levels_cleared > other.levels_cleared
	if progress != other.progress:
		return progress > other.progress
	return tiebreak > other.tiebreak
