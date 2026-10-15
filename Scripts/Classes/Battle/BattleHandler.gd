class_name BattleHandler
extends Node
## The only Battle piece that touches the scene tree. Added to each level by Level._enter_tree
## while a BattleSession is active. Drives the session's fixed clock and forwards the real
## player's events to it.

const TITLE_SCENE := "res://Scenes/Levels/TitleScreen.tscn"
const STEP_SECONDS := 1.0

var fresh_level := false
var accumulator := 0.0
var level_completed := false
var timeout_sent := false

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
	while accumulator >= STEP_SECONDS and not session.finished:
		accumulator -= STEP_SECONDS
		session.step()
	# The session timer is authoritative; the level timer just mirrors it for display.
	Global.time = maxi(session.get_player().time_left, 0)
	if not session.get_player().alive:
		if not timeout_sent:
			timeout_sent = true
			get_tree().call_group("Players", "time_up")
	elif session.finished:
		end_match()

## Finishes the match from the real player's side, logs the ranking, clears the session and
## returns to the title screen. Safe to call more than once.
static func end_match(cause := BattleSession.KoCause.HAZARD) -> void:
	var session := BattleSession.current
	if session == null:
		return
	session.report_ko(BattleSession.PLAYER_ID, cause)
	session.resolve_to_end()
	print(session.describe_result())
	BattleSession.clear()
	AudioManager.stop_all_music()
	Global.death_load = false
	Global.transition_to_scene(TITLE_SCENE)

static func quit_battle() -> void:
	end_match(BattleSession.KoCause.FORFEIT)
