class_name BattleBotDirector
extends Node
## The Battle opponents that play a real game (doc 56): one BattleBotWorld each, created with the round's session and
## gone with it. It runs them with the real player's game (frozen when the Battle screen freezes the game window: the
## pre-round, a win hold), stops them where they are when the round is over, and renders each one's screen for its pane
## (the reference's panes show every frame, doc 56 section 3).
##
## Which opponents play a real game: the first `count()` (1..N). The rest keep the previews of docs 36-55 until the
## real worlds take all 34 (the decision in doc 56 section 13). `--battle-real-bots=N` on the command line (before or
## after `--`), or SMB1R_BATTLE_REAL_BOTS=N, sets N (0 by default in this pass).
##
## Ownership (doc 57): an opponent is owned by exactly one system for the whole round. A world-driven contestant (the
## session's `world_driven`, set from `real_ids()` before the round's first tick) is its BattleBotWorld's alone: its game,
## its progress and its pane's picture. The legacy previews (BattlePreviewDriver / Track / Stages) get only the others,
## and refuse a world-driven id (`violation`). A real opponent whose world cannot be shown is drawn as a failure, never
## as a preview, a stand-in or the placeholder.

const COUNT_ARG := "--battle-real-bots="
const COUNT_ENV := "SMB1R_BATTLE_REAL_BOTS"

## Tests set this instead of the command line (-1: read the command line).
static var count_override := -1
static var _count := -1
## How many times anything tried to give a world-driven opponent to the legacy previews (or its pane to anything but its
## world). Always 0; tests read it, and each one is also a push_error.
static var violations := 0

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
		_count = parse_count(OS.get_environment(COUNT_ENV), OS.get_cmdline_args() + OS.get_cmdline_user_args())
	return _count

## The count `env` (the environment variable's value) and `args` (the command line) ask for; the last `--battle-real-bots=N`
## wins over the environment. Both halves of the command line are read: Godot hands an argument given without the `--`
## separator (`game --battle-real-bots=4`) only to OS.get_cmdline_args(), and reading the user arguments alone turned that
## into 0 real opponents without a word (doc 57: the "winter" panes were the legacy previews' stand-ins). A value that is not
## a number is an error, not a silent 0.
static func parse_count(env: String, args: PackedStringArray) -> int:
	var raw := env.strip_edges()
	var origin := COUNT_ENV
	for arg in args:
		if arg.begins_with(COUNT_ARG):
			raw = arg.substr(COUNT_ARG.length()).strip_edges()
			origin = arg
	if raw == "":
		return 0
	if not raw.is_valid_int():
		push_error("BattleBotDirector: '%s' is not a number of real opponents (%sN); no opponent plays a real game" % [origin, COUNT_ARG])
		return 0
	return clampi(raw.to_int(), 0, BattleHudLayout.OPPONENTS)

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

## The opponents of `session_` that are world-driven (their BattleBotWorld owns them), in id order.
static func world_driven_ids(session_: BattleSession) -> Array[int]:
	var out: Array[int] = []
	for id in range(1, BattleHudLayout.OPPONENTS + 1):
		if session_.contestants[id].world_driven:
			out.append(id)
	return out

## The opponents of `session_` the legacy previews may draw: every opponent that is not world-driven.
static func legacy_ids(session_: BattleSession) -> Array[int]:
	var out: Array[int] = []
	for id in range(1, BattleHudLayout.OPPONENTS + 1):
		if not session_.contestants[id].world_driven:
			out.append(id)
	return out

## One line saying who owns which opponent this round (printed by BattleScreen as the round's panes are given out).
static func describe(session_: BattleSession) -> String:
	var real := world_driven_ids(session_)
	var legacy := legacy_ids(session_)
	return "Battle: opponents %s play their real games (BattleBotWorld); %s are legacy previews" % [_span(real), _span(legacy)]

static func _span(ids: Array[int]) -> String:
	if ids.is_empty():
		return "none"
	if ids.size() == 1:
		return "#%d" % ids[0]
	if ids[-1] - ids[0] == ids.size() - 1:
		return "#%d-%d" % [ids[0], ids[-1]]
	return str(ids)

## Something tried to put world-driven opponent `id` on the legacy previews (or its pane on anything but its world): refused,
## counted, and reported. Never a fallback.
static func violation(id: int, what: String) -> void:
	violations += 1
	push_error("Battle ownership: opponent #%d is world-driven (BattleBotWorld) and %s" % [id, what])

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
