class_name BattleRound
extends RefCounted
## The Battle round lifecycle (doc 38, section 7) as a pure state machine: no scene tree, no
## session, no input. BattleScreen owns one and feeds it real time and events; everything it
## decides is a state change it announces through `state_changed`, which the screen turns into
## freezing the game window, showing the banner or the results, and starting the next round.
##
##   LOADING ─► PRE_ROUND ─► PLAYING ─► ROUND_OVER ─► RESULTS ─┐
##      ▲                                                       │ confirm (after the lockout) / timeout
##      └──────────────────── next round ───────────────────────┘
##
## * LOADING     a fresh round has been started; the game window is loading World 1-1.
## * PRE_ROUND   World 1-1 is on screen, gameplay and the Battle clock are frozen ("READY").
## * PLAYING     normal play; the Battle clock runs.
## * ROUND_OVER  the player died, ran out of time, or is the last one standing. A death plays out
##               its animation first (`death_finished()` ends it); a win holds for a moment.
## * RESULTS     the result card is up. Confirm (after a short lockout) or the timeout starts the
##               next round, never the title screen. Quit is not a state: it leaves Battle.
## Timing here is real time (the screen's frame delta), not the Battle clock.

enum State {LOADING, PRE_ROUND, PLAYING, ROUND_OVER, RESULTS}
enum End {NONE, DEATH, TIMEOUT, WIN}

const PRE_ROUND_SECONDS := 2.5
const GO_SECONDS := 0.8 ## how long "GO!" lingers once play is released
const WIN_HOLD_SECONDS := 1.0 ## a win has no death animation: hold this long before the results
const ROUND_OVER_MAX_SECONDS := 12.0 ## safety: a death sequence that never reports still reaches the results
const RESULTS_MIN_SECONDS := 1.0 ## confirm is ignored until the results have been up this long
const RESULTS_MAX_SECONDS := 10.0 ## the results advance on their own after this long
const PREROUND_ARG := "--battle-preround="
const PREROUND_ENV := "SMB1R_BATTLE_PREROUND"

## Test hook: >= 0 replaces the pre-round length (0 skips it entirely).
static var pre_round_override := -1.0

signal state_changed(from: int, to: int) ## values of State

var state: int = State.LOADING
var round_number := 0
var end_cause: int = End.NONE
var time_in_state := 0.0
var pre_round_seconds := PRE_ROUND_SECONDS
var history: Array[int] = [] ## every state entered, in order (for tests and debugging)
var released_from_pre_round := false

## DEVELOPMENT ONLY (debug builds): `--battle-preround=SECONDS` (after `--`) or the
## SMB1R_BATTLE_PREROUND env var replaces the pre-round length; 0 skips the countdown.
static func default_pre_round_seconds() -> float:
	if pre_round_override >= 0.0:
		return pre_round_override
	if OS.is_debug_build():
		var raw := OS.get_environment(PREROUND_ENV)
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with(PREROUND_ARG):
				raw = arg.substr(PREROUND_ARG.length())
		if raw.is_valid_float():
			return maxf(raw.to_float(), 0.0)
	return PRE_ROUND_SECONDS

## Starts a new round (the first one, or the next). Everything per-round is reset.
func begin_round() -> void:
	round_number += 1
	end_cause = End.NONE
	released_from_pre_round = false
	pre_round_seconds = default_pre_round_seconds()
	_enter(State.LOADING)

## The round's first level is on screen. Freezes for the pre-round (or plays at once if it is 0).
func level_ready() -> bool:
	if state != State.LOADING:
		return false
	_enter(State.PRE_ROUND if pre_round_seconds > 0.0 else State.PLAYING)
	return true

## The round ends: the player died, ran out of time, or won. Only possible while PLAYING, so a
## second report for the same round (a duplicate KO, a late timeout) is ignored.
func end_round(cause: int) -> bool:
	if state != State.PLAYING or cause == End.NONE:
		return false
	end_cause = cause
	_enter(State.ROUND_OVER)
	return true

## The player's death sequence (animation and music) has finished.
func death_finished() -> bool:
	if state != State.ROUND_OVER or end_cause == End.WIN:
		return false
	_enter(State.RESULTS)
	return true

## True once the results may be dismissed: after the lockout on confirm, or at the timeout.
func results_dismissed(confirm: bool) -> bool:
	return state == State.RESULTS and (time_in_state >= RESULTS_MAX_SECONDS \
		or (time_in_state >= RESULTS_MIN_SECONDS and confirm))

## Advances real time. `confirm` is "the player pressed jump / accept this frame". Returns true
## if the state changed.
func update(delta: float, confirm := false) -> bool:
	time_in_state += delta
	match state:
		State.PRE_ROUND:
			if time_in_state >= pre_round_seconds:
				released_from_pre_round = true
				_enter(State.PLAYING)
				return true
		State.ROUND_OVER:
			if (end_cause == End.WIN and time_in_state >= WIN_HOLD_SECONDS) or time_in_state >= ROUND_OVER_MAX_SECONDS:
				_enter(State.RESULTS)
				return true
		State.RESULTS:
			if results_dismissed(confirm):
				begin_round()
				return true
	return false

## "READY" while frozen, "GO!" just after play is released, otherwise nothing.
func banner_text() -> String:
	if state == State.PRE_ROUND:
		return "READY"
	if state == State.PLAYING and released_from_pre_round and time_in_state < GO_SECONDS:
		return "GO!"
	return ""

## True while the game window and the Battle clock must be frozen.
func frozen() -> bool:
	return state == State.PRE_ROUND

func state_name() -> String:
	return State.keys()[state]

func _enter(new_state: int) -> void:
	var old: int = state
	state = new_state
	time_in_state = 0.0
	history.append(new_state)
	state_changed.emit(old, new_state)
