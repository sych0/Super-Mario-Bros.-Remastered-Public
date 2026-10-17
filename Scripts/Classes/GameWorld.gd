class_name GameWorld
extends RefCounted
## Which game a gameplay node belongs to (doc 56).
##
## The MAIN world is the game the real player plays (and every mode outside Battle): its environment is the
## process-wide state the gameplay code has always used - Global's score, time, current level and signals, the
## SceneTree's groups and pause, AudioManager, the classes' static vars. A BOT world is one Battle opponent's
## own game (BattleBotWorld): its own World2D (physics), level, Mario and enemies, whose environment is that
## BattleBotWorld object. The gameplay scripts reach their environment through the functions below, so the same
## real code runs in either world. For a node of the main world every function does exactly what the code did
## before it was routed through here; while no bot world exists (`bot_worlds == 0`) that is also the only path.
##
## A node's world is its viewport: a bot world's nodes live under a BattleBotViewport.

## Live bot worlds. 0 (everything outside Battle's real opponents) keeps every call on the main-world path.
static var bot_worlds := 0

## The bot world `node` lives in, or null for the main world.
static func bot_of(node: Node) -> BattleBotWorld:
	if bot_worlds == 0 or node == null or not node.is_inside_tree():
		return null
	var vp := node.get_viewport()
	if vp is BattleBotViewport:
		return (vp as BattleBotViewport).world
	return null

static func is_bot(node: Node) -> bool:
	return bot_of(node) != null

## The Level `node` plays in (Global.current_level in the main world).
static func level(node: Node) -> Level:
	var bot := bot_of(node)
	return bot.level if bot != null else Global.current_level

# ---- groups ----------------------------------------------------------------------------------------------------

## The members of `group` that are in `node`'s world.
static func group(node: Node, group_name: StringName) -> Array[Node]:
	var all := node.get_tree().get_nodes_in_group(group_name)
	if bot_worlds == 0:
		return all
	var bot := bot_of(node)
	var out: Array[Node] = []
	for n in all:
		if bot_of(n) == bot:
			out.append(n)
	return out

## The Players of `node`'s world (a bot world has exactly its own Mario).
static func players(node: Node) -> Array[Node]:
	var bot := bot_of(node)
	if bot != null:
		var out: Array[Node] = []
		if is_instance_valid(bot.player) and bot.player.is_inside_tree():
			out.append(bot.player)
		return out
	return group(node, &"Players")

static func first_player(node: Node) -> Node:
	var bot := bot_of(node)
	if bot != null:
		return bot.player if is_instance_valid(bot.player) and bot.player.is_inside_tree() else null
	if bot_worlds == 0:
		return node.get_tree().get_first_node_in_group(&"Players")
	var all := players(node)
	return all[0] if not all.is_empty() else null

## SceneTree.call_group, limited to `node`'s world.
static func call_group(node: Node, group_name: StringName, method: StringName) -> void:
	if bot_worlds == 0:
		node.get_tree().call_group(group_name, method)
		return
	for n in group(node, group_name):
		if n.has_method(method):
			n.call(method)

# ---- pause -----------------------------------------------------------------------------------------------------

## The game freezing everything but what is set to always process (a death, a power-up animation): the whole
## SceneTree in the main world, only the bot's own level in a bot world.
static func set_paused(node: Node, paused: bool) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.set_frozen(paused)
	else:
		node.get_tree().paused = paused

# ---- what only the main world has: sound, music, the shared counters ------------------------------------------

static func sfx(node: Node, stream_name: String, position := Vector2.ZERO, pitch := 1.0, can_overlap := true) -> void:
	if not is_bot(node):
		AudioManager.play_sfx(stream_name, position, pitch, can_overlap)

static func global_sfx(node: Node, stream_name: String, pitch := 1.0) -> void:
	if not is_bot(node):
		AudioManager.play_global_sfx(stream_name, pitch)

static func kill_sfx(node: Node, stream_name: String) -> void:
	if not is_bot(node):
		AudioManager.kill_sfx(stream_name)

static func music_override(node: Node, stream: AudioManager.MUSIC_OVERRIDES, priority := 0, stop_on_finish := true, restart := true) -> void:
	if not is_bot(node):
		AudioManager.set_music_override(stream, priority, stop_on_finish, restart)

static func stop_music_override(node: Node, stream: AudioManager.MUSIC_OVERRIDES, force := false) -> void:
	if not is_bot(node):
		AudioManager.stop_music_override(stream, force)

static func add_score(node: Node, amount: int) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.score += amount
	else:
		Global.score += amount

static func add_coins(node: Node, amount: int) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.coins += amount
	else:
		Global.coins += amount

static func add_lives(node: Node, amount: int) -> void:
	if not is_bot(node): # an opponent has no lives: in Battle a death is an elimination
		Global.lives += amount

## Whether `node` may write the main game's process-wide state (pause permission, the level timer, the theme, the
## last-level bookkeeping...). False in a bot world, whose own object holds all of that.
static func owns_globals(node: Node) -> bool:
	return not is_bot(node)

# ---- level flow ------------------------------------------------------------------------------------------------

## The signal a flagpole / axe sends when the level is complete (Global.level_complete_begin in the main world).
static func level_complete(node: Node) -> Signal:
	var bot := bot_of(node)
	return bot.level_complete_begin if bot != null else Global.level_complete_begin

static func emit_level_complete(node: Node) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.level_complete_begin.emit()
	else:
		Global.level_complete_begin.emit()

## Leaves the current scene for `scene_path` (a pipe, a death reload...): the whole game in the main world, the
## bot's own level in a bot world.
static func transition_to_scene(node: Node, scene_path: String) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.enter_scene(scene_path)
	else:
		Global.transition_to_scene(scene_path)

# ---- statics that are really per world -------------------------------------------------------------------------

static func camera_right_limit(node: Node) -> int:
	var bot := bot_of(node)
	return bot.camera_right_limit if bot != null else Player.camera_right_limit

static func set_camera_right_limit(node: Node, value: int) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.camera_right_limit = value
	else:
		Player.camera_right_limit = value

static func cam_locked(node: Node) -> bool:
	var bot := bot_of(node)
	return bot.cam_locked if bot != null else CameraHandler.cam_locked

static func set_cam_locked(node: Node, value: bool) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.cam_locked = value
	else:
		CameraHandler.cam_locked = value

static func pipe_cutscene(node: Node) -> bool:
	return false if is_bot(node) else Player.pipe_cutscene

static func exiting_pipe_id(node: Node) -> int:
	var bot := bot_of(node)
	return bot.exiting_pipe_id if bot != null else PipeArea.exiting_pipe_id

static func set_exiting_pipe_id(node: Node, value: int) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.exiting_pipe_id = value
	else:
		PipeArea.exiting_pipe_id = value

static func pipes_open(node: Node) -> bool:
	var bot := bot_of(node)
	return bot.pipes_open if bot != null else PipeArea.can_enter

static func set_pipes_open(node: Node, value: bool) -> void:
	var bot := bot_of(node)
	if bot != null:
		bot.pipes_open = value
	else:
		PipeArea.can_enter = value

# ---- the player's character and power state ----------------------------------------------------------------------

## Which character `player` is (an index into Player.CHARACTERS).
static func character_index(player: Player) -> int:
	var bot := bot_of(player)
	return bot.character if bot != null else int(Global.player_characters[player.player_id])

## The power state (index into Player.POWER_STATES) `player` carries between levels.
static func stored_power(player: Player) -> int:
	var bot := bot_of(player)
	return bot.power if bot != null else int(Global.player_power_states[player.player_id])

static func store_power(player: Player, index: int) -> void:
	var bot := bot_of(player)
	if bot != null:
		bot.on_power_stored(index)
	else:
		Global.player_power_states[player.player_id] = str(index)

# ---- the screen --------------------------------------------------------------------------------------------------

## Whether a VisibleOnScreenNotifier2D is on its game's screen. A bot world never renders its own screen, so its
## notifiers are worked out from its camera each physics tick (BattleBotWorld); the main world asks the renderer.
static func on_screen(notifier: VisibleOnScreenNotifier2D) -> bool:
	if notifier == null:
		return false
	var bot := bot_of(notifier)
	return bot.notifier_on_screen(notifier) if bot != null else notifier.is_on_screen()
