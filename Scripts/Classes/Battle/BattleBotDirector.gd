class_name BattleBotDirector
extends Node
## The Battle opponents that play a real game (doc 56): one BattleBotWorld each, created with the round's session and
## gone with it. It runs them with the real player's game (frozen when the Battle screen freezes the game window: the
## pre-round, a win hold), stops them where they are when the round is over, and renders each one's screen for its pane
## (the reference's panes show every frame, doc 56 section 3).
##
## Which opponents play a real game: the first `count()` (1..N). The rest keep the previews of docs 36-55 until the
## real worlds take all 34 (the decision in doc 56 section 13). `--battle-real-bots=N` after `--` on the command line,
## or SMB1R_BATTLE_REAL_BOTS=N, sets N (0 by default in this pass).

const COUNT_ARG := "--battle-real-bots="
const COUNT_ENV := "SMB1R_BATTLE_REAL_BOTS"

## Tests set this instead of the command line (-1: read the command line).
static var count_override := -1
static var _count := -1

var session: BattleSession = null
var worlds := {} ## contestant id -> BattleBotWorld
var follow: Node = null ## whose process mode the worlds follow (BattleScreen's game viewport)
var render := true ## render each world's screen for its pane every frame
var stopped := false

## How many opponents play a real game.
static func count() -> int:
	if count_override >= 0:
		return clampi(count_override, 0, BattleHudLayout.OPPONENTS)
	if _count < 0:
		_count = 0
		var raw := OS.get_environment(COUNT_ENV)
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with(COUNT_ARG):
				raw = arg.substr(COUNT_ARG.length())
		if raw.is_valid_int():
			_count = clampi(raw.to_int(), 0, BattleHudLayout.OPPONENTS)
	return _count

## The ids that play a real game.
static func real_ids() -> Array[int]:
	var out: Array[int] = []
	for i in count():
		out.append(i + 1)
	return out

## Marks `session_`'s real-game opponents, before its first tick (BattleHandler.start_match does it as the round begins).
static func configure(session_: BattleSession) -> void:
	for id in real_ids():
		session_.set_world_driven(id)

func _init(session_: BattleSession = null) -> void:
	session = session_
	name = "BotWorlds"
	process_mode = Node.PROCESS_MODE_ALWAYS # (it keeps following `follow`; the worlds themselves pause with the game)

## Creates and starts the games of `ids` (each on World 1-1).
func start(ids: Array) -> void:
	for id in ids:
		if worlds.has(id):
			continue
		session.set_world_driven(id)
		var w := BattleBotWorld.new(id, session, session.seed_value)
		w.process_mode = _world_mode()
		add_child(w)
		w.start(0)
		worlds[id] = w

## The worlds run when the real player's game runs: frozen with the game window, paused with the SceneTree.
func _world_mode() -> Node.ProcessMode:
	if stopped:
		return Node.PROCESS_MODE_DISABLED
	if is_instance_valid(follow) and follow.process_mode == Node.PROCESS_MODE_DISABLED:
		return Node.PROCESS_MODE_DISABLED
	return Node.PROCESS_MODE_PAUSABLE

func _process(_delta: float) -> void:
	var mode := _world_mode()
	for id in worlds:
		var w: BattleBotWorld = worlds[id]
		if w.process_mode != mode:
			w.process_mode = mode
	if not render or stopped or mode == Node.PROCESS_MODE_DISABLED or get_tree().paused:
		return
	for id in worlds:
		var w: BattleBotWorld = worlds[id]
		if w.viewport != null and w.phase != BattleBotWorld.Phase.OUT:
			w.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

## The round is over: every game stops where it is; the panes keep their last pictures.
func stop() -> void:
	stopped = true
	for id in worlds:
		var w: BattleBotWorld = worlds[id]
		w.stop()
		w.process_mode = Node.PROCESS_MODE_DISABLED

func world(id: int) -> BattleBotWorld:
	return worlds.get(id)
