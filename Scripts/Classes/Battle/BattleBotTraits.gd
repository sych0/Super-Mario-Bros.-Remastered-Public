class_name BattleBotTraits
extends RefCounted
## How one Battle opponent plays (doc 56): stable for the round, drawn from the round's seed and the opponent's id, so a
## round replays exactly. Every opponent is trying to win; the traits make them different players, not worse ones on
## purpose. `skill` is the session's own per-contestant draw (BattleContestant.skill), so the bots that the abstract
## model treated as strong are the strong players here too.
##
## Calibrated against the reference's opponents (doc 56 section 3): they run about a sixth of the time, walk a quarter,
## stop often (mostly to hit blocks), jump about 0.45 times a second, take a median 55 s over the first course (the
## fastest 33 s), and about four in ten are out before finishing it.

const SALT := 0x6A09E667

var skill := 0.5
## Frames between seeing a reason to press a button and pressing it.
var reaction_frames := 4
## How far (px) a take-off can land from where the brain meant it to (timing error at speed).
var precision_px := 4.0
## Share of open ground crossed holding run (the rest is walked).
var run_share := 0.4
## Chance to stop for a moment before a gap or an enemy instead of going straight at it.
var hesitation := 0.2
## Chance to go for the stomp on an enemy ahead rather than just clearing it.
var stomp_bias := 0.5
## Chance to stop under a ? block on the way and hit it (coins, items).
var block_interest := 0.4
## Short stops per second on open ground (looking, waiting for the screen).
var idle_rate := 0.05
## Frames of no progress before trying something else (a jump, then backing off).
var patience := 24

static func roll(skill_: float, seed_value: int, contestant_id: int) -> BattleBotTraits:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_value ^ SALT, contestant_id])
	var t := BattleBotTraits.new()
	t.skill = clampf(skill_, 0.0, 1.0)
	var s := t.skill
	t.reaction_frames = clampi(roundi(lerpf(9.0, 2.0, s) + rng.randf_range(-1.5, 1.5)), 1, 12)
	t.precision_px = lerpf(9.0, 1.5, s) * rng.randf_range(0.8, 1.2)
	t.run_share = clampf(lerpf(0.15, 0.75, s) * rng.randf_range(0.6, 1.3), 0.05, 0.95)
	t.hesitation = clampf(lerpf(0.45, 0.05, s) * rng.randf_range(0.5, 1.5), 0.0, 0.8)
	t.stomp_bias = rng.randf_range(0.25, 0.85)
	t.block_interest = rng.randf_range(0.15, 0.75)
	t.idle_rate = lerpf(0.12, 0.02, s) * rng.randf_range(0.5, 1.5)
	t.patience = clampi(roundi(lerpf(40.0, 16.0, s)), 10, 60)
	return t

func describe() -> Dictionary:
	return {"skill": skill, "reaction": reaction_frames, "precision": precision_px, "run": run_share, "hesitation": hesitation,
		"stomp": stomp_bias, "blocks": block_interest, "idle": idle_rate, "patience": patience}
