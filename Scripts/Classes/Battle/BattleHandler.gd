class_name BattleHandler
extends Node
## The Battle piece that touches the game's scene tree. Added to each level by Level._enter_tree
## while a BattleSession is active (the level runs inside BattleScreen's GameViewport). Drives
## the session's fixed clock and forwards the real player's events to it. Its static functions
## are Battle's entry points into the rest of the game: starting a round, the player's death,
## and quitting. The round lifecycle itself lives in BattleRound / BattleScreen.

const TITLE_SCENE := "res://Scenes/Levels/TitleScreen.tscn"
const STEP_SECONDS := 1.0
const TIME_UP_RETRY_SECONDS := 1.0 ## the real game ignores a death while Mario is in a pipe / exiting: ask again
const SPEED_ARG := "--battle-sim-speed="
const SPEED_ENV := "SMB1R_BATTLE_SIM_SPEED"

static var _sim_speed := -1
## DISPLAY ONLY: how far through the current Battle second the clock is (0..1). The opponent
## previews use it to animate smoothly between session ticks; the session never reads it.
## It freezes with the handler, so previews stop while the game is paused.
static var presentation_alpha := 0.0
## Where a new round's seed comes from. Tests replace it with a scripted sequence.
static var seed_source := Callable()

## DEVELOPMENT ONLY: multiplies how fast the Battle clock/bots run so a short test shows a
## whole match. Needs a debug build plus `--battle-sim-speed=N` (after `--`) or the
## SMB1R_BATTLE_SIM_SPEED env var. Release builds and normal runs always return 1.
static func sim_speed() -> int:
	if _sim_speed >= 0:
		return _sim_speed
	_sim_speed = 1
	if OS.is_debug_build():
		var raw := OS.get_environment(SPEED_ENV)
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with(SPEED_ARG):
				raw = arg.substr(SPEED_ARG.length())
		if raw.is_valid_int():
			_sim_speed = clampi(raw.to_int(), 1, 100)
	return _sim_speed

var fresh_level := false
var bound_session: BattleSession = null ## the session this level belongs to, kept so its cleanup never reaches a later round's session
var accumulator := 0.0
var level_completed := false
var time_up_wait := 0.0 ## real seconds until the next "time up" is sent (only once the player is out of time)
var progress_start_x := 0.0
var progress_end_x := 0.0
var progress_ready := false
var progress_searched := false

static func attach_to(level: Node, fresh: bool) -> void:
	if level.has_node("BattleHandler"):
		return
	var handler := BattleHandler.new()
	handler.name = "BattleHandler"
	handler.fresh_level = fresh
	level.add_child.call_deferred(handler)

func _ready() -> void:
	var session := BattleSession.current
	if session == null:
		queue_free()
		return
	bound_session = session
	if session.attacks.enabled and BattleIncomingSpawner.enabled:
		BattleIncomingSpawner.attach(self, session) # attacks on the real player become real enemies here
	if fresh_level:
		session.report_level_start(Global.world_num, Global.level_num)
	Global.level_complete_begin.connect(_on_level_complete)

## The level is going away (cleared, a pipe to or from a bonus room, replaced, or the round restarting):
## the incoming enemies that were physically in it are over (LEVEL_TRANSITION). ACTIVE attacks whose
## enemy never appeared, and QUEUED ones, were never in it: they carry into the next level or room.
func _exit_tree() -> void:
	if bound_session != null:
		bound_session.resolve_player_spawned(BattleAttack.Resolution.LEVEL_TRANSITION)

func _on_level_complete() -> void:
	if level_completed or BattleSession.current == null:
		return
	level_completed = true
	BattleSession.current.report_level_complete()

# Pausable by default (process_mode inherits from the level), so bots freeze with the game.
func _process(delta: float) -> void:
	var session := BattleSession.current
	if session == null or session.finished:
		return
	accumulator += delta
	var step_seconds := STEP_SECONDS / sim_speed()
	while accumulator >= step_seconds and not session.finished:
		accumulator -= step_seconds
		session.step()
	presentation_alpha = clampf(accumulator / step_seconds, 0.0, 1.0)
	_report_progress(session)
	# The session timer is authoritative; the level timer just mirrors it for display.
	Global.time = maxi(session.get_player().time_left, 0)
	if not session.get_player().alive:
		# The session KO'd the player (time ran out): have the real player die so the round ends the
		# normal way. The game ignores a death in some states (pipes, level exit), so keep asking.
		time_up_wait -= delta
		if time_up_wait <= 0.0:
			time_up_wait = TIME_UP_RETRY_SECONDS
			get_tree().call_group("Players", "time_up")
	# (A win - everyone else out - is noticed by BattleScreen, which also sees it between levels.)

## Live progress of the real player = how far they are between where they started the level
## and its goal object (flagpole / castle bridge). No goal found -> no live progress.
func _report_progress(session: BattleSession) -> void:
	if level_completed:
		return
	var player := get_tree().get_first_node_in_group("Players") as Node2D
	if player == null:
		return
	if not progress_searched:
		progress_searched = true
		progress_start_x = player.global_position.x
		for n in owner_level_nodes():
			if BattleCourse.is_goal_script(n.get_script() as Script):
				progress_end_x = (n as Node2D).global_position.x
				break
		progress_ready = progress_end_x > progress_start_x + 16.0
	if progress_ready:
		session.report_player_progress((player.global_position.x - progress_start_x) / (progress_end_x - progress_start_x))

func owner_level_nodes() -> Array[Node]:
	return get_parent().find_children("*", "Node2D", true, false)

## A seed for a new round: from `seed_source` if a test set one, else the global RNG, and never
## the same as the previous round's.
static func new_seed(previous := -1) -> int:
	var value := 0
	for attempt in 8:
		value = seed_source.call() if seed_source.is_valid() else randi()
		if value != previous:
			return value
	return value + 1

## Starts a Battle round: from the title (the first round) and from the results (every next round).
## The one shared reset path: the same reset a new Classic run does, a fresh session with a new
## seed, then a transition into 1-1 that BattleScreen routes into its own GameViewport. It never
## goes through the title screen.
static func start_match() -> void:
	var previous_seed := BattleSession.current.seed_value if BattleSession.current != null else -1
	Global.current_game_mode = Global.GameMode.BATTLE
	Global.current_campaign = "SMB1"
	Global.second_quest = false
	Global.clear_saved_values()
	Global.world_num = 1
	Global.level_num = 1
	Global.reset_values()
	BattleSession.begin(new_seed(previous_seed))
	presentation_alpha = 0.0
	PipeCutscene.seen_cutscene = false
	Level.first_load = true # a win leaves no death to set it: 1-1 must start as a fresh level
	Global.death_load = false
	(Engine.get_main_loop() as SceneTree).paused = false
	LevelTransition.level_to_transition_to = Level.get_scene_string(1, 1)
	Global.transition_to_scene("res://Scenes/Levels/LevelTransition.tscn")

## Called by Player.die() (Battle only), at the moment of death: the player's KO is registered
## now, so their placement reflects when they actually died. A KO the session already made
## (time ran out) is not repeated, and a second death report for the round changes nothing.
static func on_player_died() -> void:
	var session := BattleSession.current
	if session == null:
		return
	var player := session.get_player()
	if player.alive:
		session.report_ko(BattleSession.PLAYER_ID, BattleSession.KoCause.HAZARD)
	if BattleScreen.is_active():
		var cause: int = BattleRound.End.TIMEOUT if player.ko_cause == BattleSession.KoCause.TIME else BattleRound.End.DEATH
		BattleScreen.instance.round_over(cause)

## Called by Player.death_load() (Battle only), once the death animation and music are done.
static func on_death_finished() -> void:
	if BattleScreen.is_active():
		BattleScreen.instance.death_finished()

## Explicit Quit (the Battle pause menu): the only way out of Battle. No results, no next round:
## the session goes, Battle mode ends, and the title is next (which frees the Battle screen and
## hands the window back to the user's settings).
static func quit_battle() -> void:
	BattleSession.clear()
	Global.death_load = false
	Global.current_game_mode = Global.GameMode.NONE
	Global.transition_to_scene(TITLE_SCENE)
