class_name BattleHandler
extends Node
## The only Battle piece that touches the scene tree. Added to each level by Level._enter_tree
## while a BattleSession is active. Drives the session's fixed clock and forwards the real
## player's events to it.

const TITLE_SCENE := "res://Scenes/Levels/TitleScreen.tscn"
const STEP_SECONDS := 1.0
const RESULT_MIN_SECONDS := 1.0
const RESULT_MAX_SECONDS := 10.0
const SPEED_ARG := "--battle-sim-speed="
const SPEED_ENV := "SMB1R_BATTLE_SIM_SPEED"

static var _sim_speed := -1
## DISPLAY ONLY: how far through the current Battle second the clock is (0..1). The opponent
## previews use it to animate smoothly between session ticks; the session never reads it.
## It freezes with the handler, so previews stop while the game is paused.
static var presentation_alpha := 0.0
static var ending_session: BattleSession = null

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
var accumulator := 0.0
var level_completed := false
var timeout_sent := false
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
	if fresh_level:
		session.report_level_start(Global.world_num, Global.level_num)
	Global.level_complete_begin.connect(_on_level_complete)
	BattleHud.ensure(get_tree())

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
		if not timeout_sent:
			timeout_sent = true
			get_tree().call_group("Players", "time_up")
	elif session.finished:
		end_match()

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

## Finishes the match from the real player's side, logs the ranking, clears the session and
## returns to the title screen. Safe to call more than once.
static func end_match(cause := BattleSession.KoCause.HAZARD) -> void:
	var session := BattleSession.current
	if session == null or ending_session == session:
		return
	ending_session = session
	session.report_ko(BattleSession.PLAYER_ID, cause)
	var others_alive := session.alive_count
	session.resolve_to_end()
	print(session.describe_result())
	AudioManager.stop_all_music()
	Global.death_load = false
	var tree := Engine.get_main_loop() as SceneTree
	var hud := BattleHud.ensure(tree)
	if not hud.is_inside_tree():
		await hud.ready
	hud.show_result(session, others_alive)
	while is_instance_valid(hud) and not hud.result_dismissed():
		await tree.process_frame
	if is_instance_valid(hud):
		hud.queue_free()
	BattleSession.clear()
	ending_session = null
	Global.transition_to_scene(TITLE_SCENE)

static func quit_battle() -> void:
	end_match(BattleSession.KoCause.FORFEIT)
