extends SceneTree
## Development tool (M6b, doc 48): renders the real Battle screen with the real spawner running and saves PNGs of the
## display framebuffer at the moments that matter for the incoming presentation: the strip while lines are in the air,
## queued, arriving and in the level; the arrival effect on a real enemy at several frames after it appears; the strip
## right after a stomp; and a crowded strip. Needs a display and a GL renderer:
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/tools/battle_incoming_capture.gd -- out=/some/dir [pack=SandboxStandIn]
## Under --fixed-fps 60 a frame is 1/60 s of game time whatever the wall clock does, so every picture is of a known frame.

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(session, sender, _draw) -> int:
	if sender != target:
		return target
	for c in session.contestants:
		if c.alive and c.id != sender:
			return c.id
	return -1
"""

var args := {}
var G
var BS
var SESSION
var ROUND
var TYPES
var FixedPolicy
var out := "/tmp/battle_incoming"

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func frames(n: int) -> void:
	for i in n:
		await process_frame

func wait_until(cond: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func session():
	return SESSION.current

func screen():
	return current_scene

func spawner():
	return G.current_level.get_node_or_null("BattleHandler/BattleIncomingSpawner")

func alive_bot(skip := 0) -> int:
	var seen := 0
	for id in range(1, 35):
		if session().contestants[id].alive:
			if seen == skip:
				return id
			seen += 1
	return -1

## Saves the window, or `crop` (canvas pixels) of it, magnified `magnify` times (nearest).
func grab(name: String, crop := Rect2(), magnify := 1) -> void:
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	# the 480x270 canvas is scaled by a whole number and centred in the window
	var s := floorf(minf(img.get_width() / 480.0, img.get_height() / 270.0))
	var origin := Vector2(floorf((img.get_width() - 480.0 * s) / 2.0), floorf((img.get_height() - 270.0 * s) / 2.0))
	if crop.size != Vector2.ZERO:
		img = img.get_region(Rect2i(Vector2i(origin + crop.position * s), Vector2i(crop.size * s)))
	if magnify > 1:
		img.resize(img.get_width() * magnify, img.get_height() * magnify, Image.INTERPOLATE_NEAREST)
	var file := "%s/%s.png" % [out, name]
	img.save_png(file)
	print("CAPTURE ", file, " ", img.get_size())

func strip_rect() -> Rect2:
	var l: Dictionary = screen().layout
	var r: Rect2 = l.strip_a
	return Rect2(r.position - Vector2(0, 2), Vector2(r.size.x, r.size.y + 4))

## The canvas rect around world point `p` (feet), `half` px each way in world pixels.
func around(p: Vector2, half := Vector2(40, 40)) -> Rect2:
	var view: Rect2 = spawner().view_rect()
	var game: Rect2 = screen().layout.game
	return Rect2(game.position + (p - view.position) - half + Vector2(0, -8), half * 2.0)

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	out = args.get("out", out)
	DirAccess.make_dir_recursive_absolute(out)
	var settings = root.get_node("Settings")
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	var packs: Array = settings.file.visuals.resource_packs
	if args.get("pack", "") != "":
		packs.insert(0, args.pack)
	ROUND.pre_round_override = 0.0
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 900)
	current_scene.start_battle()
	await wait_until(func(): return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and get_first_node_in_group("Players") != null and BS.instance.battle_round.state == ROUND.State.PLAYING, 1500)
	await frames(10)
	var p = get_first_node_in_group("Players")
	p.can_hurt = false
	var pol = FixedPolicy.new()
	pol.target = 0
	session().attacks.targeting = pol
	session().attacks.bots_send = false
	session().attacks.pressure_enabled = false

	# 1. three sends: lines in the air, hollow icons
	session().report_enemy_defeat(alive_bot(0), TYPES.Kind.GOOMBA)
	session().report_enemy_defeat(alive_bot(1), TYPES.Kind.KOOPA)
	session().report_enemy_defeat(alive_bot(2), TYPES.Kind.GOOMBA)
	await frames(18)
	await grab("01_in_transit_strip", strip_rect(), 2)
	await grab("01_in_transit_screen")
	# 2. landed, queued
	await frames(30)
	await grab("02_queued_strip", strip_rect(), 2)
	# 3. ACTIVE, not yet in the level (activation after 3 Battle seconds, then the 1.5 s grace)
	await wait_until(func(): return session().attacks.history[0].state == 1, 400)
	await frames(10)
	await grab("03_arriving_strip", strip_rect(), 2)
	# 4. the first spawn and its arrival effect, frame by frame
	var sp = spawner()
	await wait_until(func(): return sp.arrival_log.size() >= 1, 600)
	var seq0: int = sp.arrival_log[0].seq
	var enemy = sp.live.get(seq0)
	for f in [0, 3, 6, 12, 18, 24, 36]:
		var target_frame: int = sp.arrival_log[0].frame + f
		await wait_until(func(): return Engine.get_physics_frames() >= target_frame, 200)
		if is_instance_valid(enemy):
			await grab("04_spawn_f%02d_enemy" % f, around(enemy.global_position, Vector2(36, 28)), 4)
		await grab("04_spawn_f%02d_strip" % f, strip_rect(), 2)
	await grab("04_spawn_screen")
	# 5. everything on: two in the level, one more arriving, with queued behind
	session().report_enemy_defeat(alive_bot(3), TYPES.Kind.GOOMBA)
	session().report_enemy_defeat(alive_bot(4), TYPES.Kind.KOOPA)
	session().report_enemy_defeat(alive_bot(5), TYPES.Kind.GOOMBA)
	await wait_until(func(): return sp.live.size() >= 3, 1500)
	await frames(60)
	await grab("05_crowded_strip", strip_rect(), 2)
	await grab("05_crowded_screen")
	# 6. a stomp: the icon fades where it was (green)
	var first_seq: int = sp.live.keys()[0]
	var victim = sp.live[first_seq]
	victim.stomped_on(p)
	await frames(4)
	await grab("06_stomped_strip_a", strip_rect(), 2)
	await frames(14)
	await grab("06_stomped_strip_b", strip_rect(), 2)
	# 7. a level end: the icons that were in the level fade grey
	session().resolve_player_spawned(4)
	await frames(6)
	await grab("07_transition_strip", strip_rect(), 2)

	ROUND.pre_round_override = -1.0
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	quit(0)
