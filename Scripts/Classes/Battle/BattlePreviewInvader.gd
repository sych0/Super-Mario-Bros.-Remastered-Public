class_name BattlePreviewInvader
extends RefCounted
## An incoming enemy shown inside an opponent's miniature run: the picture of one authoritative
## attack (BattleAttack.seq) that is ACTIVE against that opponent. A presentation object only: it has
## no physics, never touches Mario, cannot hurt or kill anything, holds no reference to the session,
## and lives exactly as long as the authoritative attack does (the track makes it from
## INCOMING_ACTIVATED and ends it on INCOMING_RESOLVED, never on its own).

enum State {HOLD, VANISH}

var seq := 0 ## the authoritative attack this is the picture of
var kind := 0 ## BattleEnemyType.Kind
var preview_kind := "" ## the preview art key ("goomba", "koopa_green")
var state := State.HOLD
var x := 0.0 ## world position of its feet
var y := 0.0
var ground_y := 0.0 ## the last ground level it stood on
var ahead := 0.0 ## distance in front of Mario (px); starts at the view's edge and closes in
var close := 40.0 ## where it settles ahead of Mario
var slot := 0 ## order among the enemies on this run, so several do not stand on each other
var phase := 0.0 ## offset of its small back-and-forth, from the sequence id
var t := 0.0 ## age in preview seconds (also drives its walk animation)
var vanish_t := 0.0 ## how long it has been vanishing
var cause := 0 ## BattleAttack.Resolution it ended with (NONE while it is alive)

func is_vanishing() -> bool:
	return state == State.VANISH
