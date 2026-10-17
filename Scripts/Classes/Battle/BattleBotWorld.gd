class_name BattleBotWorld
extends Node
## One Battle opponent's own game (doc 56). Not a picture and not a model of a game: the real level scene of the course
## it is on, with its own real Mario (Player.tscn), enemies, blocks and items, in its own World2D (BattleBotViewport), run
## by the game's own scripts at the game's own physics tick. Mario is driven by a BattleBotController through a
## BattleBotPad, i.e. by the same buttons a person presses. What happens to him is what the game does: he dies because
## the game killed him, clears a course because he touched its flagpole, and then really enters the next course.
##
## Everything the game keeps process-wide for the real player's game (score, the current level, the theme, pause, the
## level-complete signal, the camera's static limits...) this object holds for its own game; the gameplay scripts reach it
## through GameWorld. The session hears from it exactly what it hears from the real player's game: progress, power,
## level clears, the KO; enemies it defeats are sent like the player's, and enemies sent to it arrive in its level.
##
## Presentation-only parts of a level (the drop-shadow renderer, Mario's on-screen timers) are left out. The world never
## renders by itself: what is "on screen" is worked out from its camera every physics tick (`_update_screen`), so its
## simulation is the same with or without a renderer; BattleBotDirector renders its viewport for the pane.

signal level_complete_begin
signal course_entered(course: int)
signal knocked_out

enum Phase {PLAYING, CLEARING, FADING, DYING, OUT, FINISHED}

## After the slide, Mario holds at the pole's foot this long, then the picture darkens over FADE (one value per 60 fps
## frame) and cuts to the next course (doc 55, measured on the reference).
const FLAG_HOLD := 0.27
const FADE := [0.027, 0.158, 0.301, 0.521, 1.0, 1.0]
## The part of the 256x240 screen an opponent pane shows: a 1:1 crop, 131 x 166 game pixels from row 66 (the reference's
## panes, doc 56 section 3); Mario runs at about x 90 of it.
const PANE_CROP := Rect2(30, 66, 131, 166)
## A KO card is shown once the death animation has had this long, at the latest (the fall usually leaves the screen first).
const DEATH_SHOW_SECONDS := 2.2
const PIT_DEATH_SHOW_SECONDS := 0.6
const SCREEN := Vector2(256, 240)

static var _packed := {} ## scene path -> PackedScene, shared by every world
static var _tilesets := {} ## "base id|atlas:texture..." -> TileSet: the bot worlds' themed copies (never the real game's)
static var _registry: Array[BattleBotWorld] = []
static var _node_hook := false

var contestant_id := 1
var session: BattleSession = null
var seed_value := 0
var traits: BattleBotTraits = null
var controller: BattleBotController = null
var pad: BattleBotPad = null
var viewport: BattleBotViewport = null
var level: Level = null
var player: Player = null
var course := 0
var scene_path := ""
var phase := Phase.PLAYING
var fade := 0.0 ## 0..1 black over the pane (the cut between two courses)
var ko_shown := false ## the death animation has played: the pane may show the KO card
var ticks := 0 ## physics ticks this world has run
var load_us := 0 ## cost of the latest scene swap (free + instantiate + add), for measurements
var step_us := 0 ## cost of this world's own work in the latest physics tick (brain + screen + reports)
var trace: PackedVector3Array = PackedVector3Array() ## optional: Mario (x, y, buttons) every tick, for determinism checks
var record_trace := false
## TESTS ONLY: when set, called each tick for the buttons instead of the brain (`func(world) -> Dictionary`).
var script_buttons := Callable()

# ---- this game's own environment (what Global and the static vars are for the real player's game) ----------------
var score := 0
var coins := 0
var power := 0 ## Player.POWER_STATES index carried between levels
var character := 0
var theme := "Overworld"
var theme_time := "Day"
var room_type := Level.RoomType.NORMAL
var world_num := 1
var level_num := 1
var camera_right_limit := 99999999
var cam_locked := false
var exiting_pipe_id := -1
var pipes_open := true
var frozen := false

var _start_x := 0.0
var _goal_x := 0.0
var _hold := 0.0
var _fade_i := 0
var _dying := 0.0
var _died_in_pit := false
var _notifiers := {} ## instance id -> [VisibleOnScreenNotifier2D, on screen]
## The enemies that have entered this world (the brain's list; freed ones are dropped as it meets them).
var enemies: Array = []
var _spawner: BattleIncomingSpawner = null
var _cleared_reported := false
## How this opponent's Mario died, as the game killed him: {pit, source, x, y, course, tick, near} (empty while alive).
var death := {}

func _init(contestant_id_ := 1, session_: BattleSession = null, seed_ := 0) -> void:
	contestant_id = contestant_id_
	session = session_
	seed_value = seed_
	name = "BotWorld%02d" % contestant_id
	process_physics_priority = -100 # the brain presses the buttons before this tick's Mario reads them

func _enter_tree() -> void:
	if not _registry.has(self):
		_registry.append(self)
		GameWorld.bot_worlds += 1
	if not _node_hook:
		_node_hook = true
		get_tree().node_added.connect(BattleBotWorld._on_node_added)

func _exit_tree() -> void:
	if _registry.has(self):
		_registry.erase(self)
		GameWorld.bot_worlds -= 1
	BattleBotPad.release(pad)

func _ready() -> void:
	var skill := 0.5
	if session != null and contestant_id < session.contestants.size():
		skill = session.contestants[contestant_id].skill
	traits = BattleBotTraits.roll(skill, seed_value, contestant_id)
	pad = BattleBotPad.register(contestant_id)
	controller = BattleBotController.new(self, traits)
	viewport = BattleBotViewport.new(self)
	add_child(viewport)

## Starts this opponent's game on `course_` (0 = World 1-1).
func start(course_ := 0) -> void:
	_load_course(course_)

# ---- the game's flow ----------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if level == null or phase == Phase.OUT or phase == Phase.FINISHED:
		return
	var t0 := Time.get_ticks_usec()
	ticks += 1
	_follow_session()
	var buttons := {}
	if phase == Phase.PLAYING and not frozen:
		buttons = script_buttons.call(self) if script_buttons.is_valid() else controller.update(delta)
	pad.set_buttons(buttons)
	if record_trace and is_instance_valid(player):
		trace.append(Vector3(player.global_position.x, player.global_position.y, pad.mask()))
	_update_screen()
	match phase:
		Phase.PLAYING:
			_report_progress()
			if is_instance_valid(player) and player.state_machine.is_state("FlagPole"):
				phase = Phase.CLEARING
				_hold = 0.0
		Phase.CLEARING:
			# The slide: once Mario stands at the pole's foot (or the game has moved him on), hold, then fade.
			var down: bool = not is_instance_valid(player) or player.is_on_floor() or not player.state_machine.is_state("FlagPole")
			if down:
				_hold += delta
			if _hold >= FLAG_HOLD - 1e-6:
				phase = Phase.FADING
				_fade_i = 0
		Phase.FADING:
			fade = FADE[_fade_i]
			_fade_i += 1
			if _fade_i >= FADE.size():
				_finish_course()
		Phase.DYING:
			_dying += delta
			var fell := is_instance_valid(player) and player.global_position.y > view_rect().end.y + 16.0
			if fell or _dying >= (PIT_DEATH_SHOW_SECONDS if _died_in_pit else DEATH_SHOW_SECONDS):
				_go_out()
	step_us = Time.get_ticks_usec() - t0

## The session's decisions about this opponent reach its game: a KO the session made (time ran out) is a death here too,
## like the real player's (BattleHandler); the round ending stops the game where it is.
func _follow_session() -> void:
	if session == null:
		return
	var c := session.contestants[contestant_id]
	if not c.alive and phase == Phase.PLAYING and is_instance_valid(player) and not player.is_dead:
		player.time_up()

func _report_progress() -> void:
	if session == null or not is_instance_valid(player) or _goal_x <= _start_x + 16.0:
		return
	session.report_bot_progress(contestant_id, (player.global_position.x - _start_x) / (_goal_x - _start_x))

## The course is done (the cut): the session hears the clear, and the next course's real level is loaded.
func _finish_course() -> void:
	if session != null and not _cleared_reported:
		_cleared_reported = true
		session.report_bot_level_complete(contestant_id)
	fade = 0.0
	if course + 1 >= BattleCourse.COURSE_COUNT:
		phase = Phase.FINISHED
		set_frozen(true)
		return
	_load_course(course + 1)

## Called by Player.die() for this world's Mario: the KO counts now, as the real player's does.
func on_player_died(pit: bool) -> void:
	if phase == Phase.DYING or phase == Phase.OUT:
		return
	phase = Phase.DYING
	_dying = 0.0
	_died_in_pit = pit
	death = {"pit": pit, "source": player.last_damage_source if is_instance_valid(player) else "", "course": course, "tick": ticks,
		"x": player.global_position.x if is_instance_valid(player) else 0.0, "y": player.global_position.y if is_instance_valid(player) else 0.0,
		"near": _nearest_enemy_name()}
	if session != null and session.contestants[contestant_id].alive:
		session.report_ko(contestant_id, BattleSession.KoCause.HAZARD)

func _nearest_enemy_name() -> String:
	if not is_instance_valid(player):
		return ""
	var best := ""
	var best_d := 48.0
	for e in enemies:
		if is_instance_valid(e) and e.is_inside_tree():
			var d: float = (e as Node2D).global_position.distance_to(player.global_position)
			if d < best_d:
				best_d = d
				best = String(e.name)
	return best

## Called by Player.death_load(): the death animation and its music are over.
func on_death_finished() -> void:
	_go_out()

## The death has played: the game stops where it is (the pane shows the KO card over its last picture).
func _go_out() -> void:
	ko_shown = true
	if phase != Phase.OUT:
		phase = Phase.OUT
		knocked_out.emit()
	set_frozen(true)
	if is_instance_valid(player):
		player.process_mode = Node.PROCESS_MODE_DISABLED # (dying, he was set to always process)

## Mario's power state changed (a power-up, a hit, a death): it is carried into the next course, and the session hears it.
func on_power_stored(index: int) -> void:
	power = index
	if session != null:
		session.report_bot_power(contestant_id, mini(index, 2))

## The game's pause, for this world only: everything in the level stops but what is set to always process (Mario's
## death and power-up animations), as the whole SceneTree does for the real player's game.
func set_frozen(on: bool) -> void:
	frozen = on
	if level != null and is_instance_valid(level):
		level.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT

## The round is over: this game stops where it is (its last picture stays on the pane).
func stop() -> void:
	set_frozen(true)
	set_physics_process(false)

func is_clearing() -> bool:
	return phase == Phase.CLEARING or phase == Phase.FADING

# ---- levels ----------------------------------------------------------------------------------------------------------

func _load_course(course_: int) -> void:
	course = course_
	world_num = BattleCourse.world_of(course)
	level_num = BattleCourse.level_of(course)
	_cleared_reported = false
	_swap_scene(BattleCourse.scene_path(course))
	phase = Phase.PLAYING
	course_entered.emit(course)

## Leaves this level for `path` without leaving the course (a pipe to a bonus room or to a course's last part). Called
## through GameWorld.transition_to_scene, where the real player's game would change the whole scene.
func enter_scene(path: String) -> void:
	if path == "" or path.ends_with("LevelTransition.tscn"):
		return # a warp to another course goes through the session's course order (not in this slice)
	_swap_scene.call_deferred(path)

func _swap_scene(path: String) -> void:
	var t0 := Time.get_ticks_usec()
	if level != null and is_instance_valid(level):
		if session != null:
			session.resolve_spawned_on(contestant_id, BattleAttack.Resolution.LEVEL_TRANSITION)
		viewport.remove_child(level)
		level.queue_free()
	level = null
	player = null
	_spawner = null
	_notifiers.clear()
	enemies.clear()
	scene_path = path
	var packed := packed_scene(path)
	if packed == null:
		push_error("BattleBotWorld: cannot load " + path)
		phase = Phase.FINISHED
		return
	var lvl := packed.instantiate() as Level
	_prepare(lvl)
	level = lvl
	camera_right_limit = 99999999
	cam_locked = false
	var saved := push_skin()
	viewport.add_child(lvl)
	pop_skin(saved)
	player = _find_player(lvl)
	_find_goal()
	frozen = false
	if session != null and session.attacks.enabled and BattleIncomingSpawner.enabled:
		_spawner = BattleIncomingSpawner.attach(lvl, session, contestant_id)
	controller.on_level(lvl, player, path)
	load_us = Time.get_ticks_usec() - t0

static func packed_scene(path: String) -> PackedScene:
	if not _packed.has(path):
		_packed[path] = load(path) if ResourceLoader.exists(path) else null
	return _packed[path]

## Before the level enters the tree: what only presents the real player's game goes, and Mario takes this opponent's pad.
func _prepare(lvl: Node) -> void:
	for n in ["DropShadowRenderer"]:
		var node := lvl.get_node_or_null(n)
		if node != null:
			lvl.remove_child(node)
			node.free()
	var p := _find_player(lvl)
	if p != null:
		p.player_id = pad.player_id
		var hud := p.get_node_or_null("CanvasLayer")
		if hud != null:
			p.remove_child(hud)
			hud.free()
	var themed := theme_for(lvl, world_num)
	theme = themed[0]
	theme_time = themed[1]
	room_type = lvl.room_type

## Called by Level._enter_tree for this world's level, instead of everything that level would do to the real game.
func on_level_entering(lvl: Level) -> void:
	room_type = lvl.room_type
	lvl.world_id = world_num
	lvl.level_id = level_num
	if Settings.file.gameplay.back_scroll == 1:
		lvl.can_backscroll = true

## The theme a level is shown with in world `world_` (Level.update_theme's rule for the SMB1 campaign).
static func theme_for(lvl: Node, world_: int) -> Array:
	var t: String = lvl.get("theme")
	var time: String = lvl.get("theme_time")
	if lvl.get("auto_set_theme"):
		t = Level.SMB1_THEMES.get(world_, "Overworld")
		time = "Night" if world_ > 4 and world_ < 9 else "Day"
	return [t, time]

static func _find_player(lvl: Node) -> Player:
	for c in lvl.get_children():
		if c is Player:
			return c
	return null

func _find_goal() -> void:
	_start_x = player.global_position.x if is_instance_valid(player) else 0.0
	_goal_x = 0.0
	for n in level.find_children("*", "Node2D", true, false):
		if BattleCourse.is_goal_script(n.get_script() as Script):
			_goal_x = (n as Node2D).global_position.x
			break

# ---- the skin (themed resources) of this world -------------------------------------------------------------------------

## Makes Global's skin inputs this world's while a resource of this world is resolved (ResourceSetterNew, LevelBG). The
## overrides are plain fields: nothing is emitted, and `pop_skin` puts back exactly what was there.
func push_skin() -> Array:
	var saved := [Global.theme_override, Global.time_override, Global.current_room_type, Global.world_num, Global.level_num]
	Global.theme_override = theme
	Global.time_override = theme_time
	Global.current_room_type = room_type
	Global.world_num = world_num
	Global.level_num = level_num
	return saved

static func pop_skin(saved: Array) -> void:
	Global.theme_override = saved[0]
	Global.time_override = saved[1]
	Global.current_room_type = saved[2]
	Global.world_num = saved[3]
	Global.level_num = saved[4]

## The TileSet a bot world's TileMapLayer uses when atlas `atlas_id` of `current` should show `texture`. The real game's
## shared TileSet is retextured in place for each level; bot worlds of different themes run at once, so each combination
## of textures is its own copy, shared by every bot world showing it (and never the real player's TileSet).
static func tileset_with(current: TileSet, atlas_id: int, texture: Texture) -> TileSet:
	if current == null:
		return null
	var base: TileSet = current.get_meta(&"bot_base") if current.has_meta(&"bot_base") else current
	var overrides: Dictionary = (current.get_meta(&"bot_textures") as Dictionary).duplicate() if current.has_meta(&"bot_textures") else {}
	overrides[atlas_id] = texture
	var keys := overrides.keys()
	keys.sort()
	var key := str(base.get_instance_id())
	for k in keys:
		key += "|%d:%d" % [k, overrides[k].get_instance_id() if overrides[k] != null else 0]
	if not _tilesets.has(key):
		var copy := base.duplicate_deep() as TileSet # internal sub-resources (the atlas sources) are copied, files (textures, scenes) shared
		for k in keys:
			var src := copy.get_source(k) as TileSetAtlasSource
			if src != null:
				src.texture = overrides[k]
		copy.set_meta(&"bot_base", base)
		copy.set_meta(&"bot_textures", overrides)
		_tilesets[key] = copy
	return _tilesets[key]

# ---- the screen ----------------------------------------------------------------------------------------------------------

## The game screen in world coordinates: this world's camera over the 256x240 viewport.
func view_rect() -> Rect2:
	var cam := viewport.get_camera_2d() if viewport != null else null
	if cam == null:
		return Rect2()
	var size := SCREEN / cam.zoom
	return Rect2(cam.get_screen_center_position() - size / 2.0, size)

static func _on_node_added(node: Node) -> void:
	if _registry.is_empty() or not (node is VisibleOnScreenNotifier2D or node.is_in_group(&"Enemies")):
		return
	var bot := GameWorld.bot_of(node)
	if bot == null:
		return
	if node is VisibleOnScreenNotifier2D:
		bot._adopt_notifier.call_deferred(node)
	else:
		bot.enemies.append(node)

func _adopt_notifier(n: VisibleOnScreenNotifier2D) -> void:
	if not is_instance_valid(n) or not n.is_inside_tree() or GameWorld.bot_of(n) != self:
		return
	var id := n.get_instance_id()
	if _notifiers.has(id):
		return
	n.visible = false # never reported by a renderer: this world's screen is worked out below
	_notifiers[id] = [n, false]

## What the renderer does for the real player's game, from this world's camera: an enemy's VisibleOnScreenEnabler2D
## switches it on as it enters the screen and off as it leaves, and every notifier's screen_entered / screen_exited is
## sent. Run before the level's own nodes each tick, so it depends on nothing but the game state.
func _update_screen() -> void:
	var view := view_rect()
	if not view.has_area():
		return
	for id in _notifiers.keys():
		var entry: Array = _notifiers[id]
		var n = entry[0]
		if not is_instance_valid(n) or not n.is_inside_tree():
			_notifiers.erase(id)
			continue
		var r: Rect2 = n.get_global_transform() * n.rect
		var on := r.intersects(view)
		if on == entry[1]:
			continue
		entry[1] = on
		if n is VisibleOnScreenEnabler2D:
			var target: Node = n.get_node_or_null(n.enable_node_path)
			if target != null:
				target.process_mode = _enable_mode(n.enable_mode) if on else Node.PROCESS_MODE_DISABLED
		if on:
			n.screen_entered.emit()
		else:
			n.screen_exited.emit()

static func _enable_mode(mode: int) -> Node.ProcessMode:
	match mode:
		VisibleOnScreenEnabler2D.ENABLE_MODE_ALWAYS:
			return Node.PROCESS_MODE_ALWAYS
		VisibleOnScreenEnabler2D.ENABLE_MODE_WHEN_PAUSED:
			return Node.PROCESS_MODE_WHEN_PAUSED
	return Node.PROCESS_MODE_INHERIT

func notifier_on_screen(n: VisibleOnScreenNotifier2D) -> bool:
	var entry = _notifiers.get(n.get_instance_id())
	return entry != null and entry[1]

# ---- the pane ------------------------------------------------------------------------------------------------------------

func pane_texture() -> Texture2D:
	return viewport.get_texture() if viewport != null else null

## Mario, his enemies and the course as plain numbers (tests and traces).
func describe() -> Dictionary:
	var d := {"id": contestant_id, "course": course, "scene": scene_path, "phase": Phase.keys()[phase], "ticks": ticks}
	if is_instance_valid(player):
		d["x"] = player.global_position.x
		d["y"] = player.global_position.y
		d["vx"] = player.velocity.x
		d["state"] = player.state_machine.get_state()
		d["power"] = player.power_state.state_name if player.power_state != null else ""
	return d
