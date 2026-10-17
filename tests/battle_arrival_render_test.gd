extends SceneTree
## What the incoming presentation looks like under a real GL renderer (doc 48, M6b): what a headless run cannot show.
## The same Goomba is spawned twice at the same spot, once with the arrival effect and once without
## (BattleIncomingSpawner.show_arrival), and the game window as the renderer drew it is compared frame by frame:
##   - every pixel the enemy itself draws is identical in every captured frame (the effect never covers or tints it);
##     only transparent parts of its box can change, where the game's own drop shadow of a bracket may fall
##   - the pictures differ only in a ring around the enemy while the effect runs, and the effect is really drawn there
##     (white corner brackets); nothing else in the window differs
##   - once the effect has ended the whole area around the enemy is identical: it looks completely normal
## and the real incoming strip, drawn on the real canvas, shows bare enemy sprites that travel left, wait at the gold boundary,
## and are gone (no marker, no flash, no fading ghost) when their enemy appears in the level (doc 54).
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/battle_arrival_render_test.gd -- [out=/some/dir] [pack=SandboxStandIn]
## (pack= adds a resource pack for this run only; out= saves the pictures it inspects)

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
const OFFSETS := [1, 4, 10, 18, 26, 40] ## physics frames after the spawn at which the window is compared
const SPRITE_DIFF := 0.35 ## a pixel the enemy draws differs from the empty level by more than this (its own drop shadow only darkens by 0.3)

var failures := 0
var args := {}
var out := ""
var G
var S
var BS
var SESSION
var KIND
var RES
var AT
var SPAWNER
var STRIP
var EFFECT
var PH
var FixedPolicy
var session

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func frames(n: int) -> void:
	for i in n:
		await process_frame

func wait_until(cond: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func player() -> Node2D:
	return get_first_node_in_group("Players") as Node2D

func level_running() -> bool:
	return current_scene != null and current_scene.get_script() == BS and not G.transitioning_scene \
		and is_instance_valid(G.current_level) and G.current_level.scene_file_path == LEVEL_1_1 \
		and G.current_level.get_parent() == current_scene.game_viewport and player() != null

func spawner():
	return G.current_level.get_node_or_null("BattleHandler/BattleIncomingSpawner")

func node_for(seq: int):
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			var o: PackedInt64Array = AT.origin_of(n)
			if o.size() == 4 and o[0] == session.uid and o[1] == seq:
				return n
	return null

func alive_bot(skip := 0) -> int:
	var seen := 0
	for id in range(1, 35):
		if session.contestants[id].alive:
			if seen == skip:
				return id
			seen += 1
	return -1

## Ends every incoming enemy and waits for the strip to be empty.
func drain() -> void:
	for i in 40:
		if session.get_incoming(0).is_empty():
			break
		for n in get_nodes_in_group("Enemies"):
			if is_instance_valid(n) and not n.is_queued_for_deletion() and AT.is_incoming(n) and n.has_method("die_from_object"):
				n.die_from_object(player())
		await frames(20)
	await frames(90)

## The game window as the renderer drew it (256x240).
func game_image(name := "") -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = current_scene.game_viewport.get_texture().get_image()
	if out != "" and name != "":
		DirAccess.make_dir_recursive_absolute(out)
		img.save_png(out.path_join(name + ".png"))
	return img

## The whole Battle window (the 480x270 canvas, scaled by a whole number and centred).
func screen_image(name := "") -> Image:
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	if out != "" and name != "":
		DirAccess.make_dir_recursive_absolute(out)
		img.save_png(out.path_join(name + ".png"))
	return img

## The colour of canvas pixel (cx, cy) in a screen image.
func canvas_color(img: Image, cx: int, cy: int) -> Color:
	var s := floorf(minf(img.get_width() / 480.0, img.get_height() / 270.0))
	var ox := floorf((img.get_width() - 480.0 * s) / 2.0)
	var oy := floorf((img.get_height() - 270.0 * s) / 2.0)
	return img.get_pixel(int(ox + (cx + 0.5) * s), int(oy + (cy + 0.5) * s))

func luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

func near(c: Color, want: Color, tol := 0.1) -> bool:
	return absf(c.r - want.r) <= tol and absf(c.g - want.g) <= tol and absf(c.b - want.b) <= tol

func near_white(c: Color) -> bool:
	return c.r > 0.92 and c.g > 0.92 and c.b > 0.92

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	KIND = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind
	RES = load("res://Scripts/Classes/Battle/BattleAttack.gd").Resolution
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	SPAWNER = load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd")
	STRIP = load("res://Scripts/Classes/Battle/BattleIncomingStrip.gd")
	EFFECT = load("res://Scripts/Classes/Battle/BattleArrivalEffect.gd")
	PH = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd").Phase
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0
	SPAWNER.force_process = false # the game's own on-screen enabler switches the enemy on
	SPAWNER.show_arrival = true
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	out = args.get("out", "")
	var packs: Array = S.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)

	G.current_game_mode = G.GameMode.NONE
	load("res://Scripts/Classes/Battle/BattleHandler.gd").start_match()
	var up: bool = await wait_until(func(): return level_running(), 1500)
	await frames(10)
	check(up and DisplayServer.get_name() != "headless", "Battle runs 1-1 under a real renderer (%s)" % DisplayServer.get_name())
	session = SESSION.current
	session.attacks.bots_send = false
	session.attacks.pressure_enabled = false
	var policy = FixedPolicy.new()
	policy.target = 0
	session.attacks.targeting = policy
	player().can_hurt = false

	await test_effect_pixels()
	await test_strip_colours()

	SPAWNER.show_arrival = true
	if added_pack != "":
		packs.erase(added_pack)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = -1.0
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle arrival render test(s) failed" % failures)
	else:
		print("All Battle arrival render tests passed")
	quit(1 if failures > 0 else 0)

# ---- the effect, pixel by pixel -----------------------------------------------------------------------------------

## One Goomba spawned with the effect `shown` or not, and the game window at each of OFFSETS (physics frames after the spawn).
func capture_run(kind: int, shown: bool, tag: String) -> Dictionary:
	SPAWNER.show_arrival = shown
	var sp = spawner()
	var a = session.report_enemy_defeat(alive_bot(), kind)
	await wait_until(func(): return a.spawned_tick >= 0, 60 * 8)
	var spawn_frame: int = sp.spawn_log[-1].frame
	var node = node_for(a.seq)
	var run := {"spot": sp.spawn_log[-1].position, "shots": {}, "fx": {}, "view": sp.view_rect()}
	for k in OFFSETS:
		await wait_until(func(): return Engine.get_physics_frames() >= spawn_frame + k, 120)
		var img := await game_image("effect_%s_%s_f%02d" % [KIND.keys()[kind].to_lower(), tag, k])
		var fx = sp.arrivals.get(a.seq, null)
		run.shots[k] = {"image": img, "feet": node.global_position, "actual": Engine.get_physics_frames() - spawn_frame,
			"fx_pos": fx.global_position if fx != null and is_instance_valid(fx) else Vector2.INF, "fx_step": fx.step() if fx != null and is_instance_valid(fx) else -1}
	node.die_from_object(player())
	await drain()
	return run

func test_effect_pixels() -> void:
	for kind in [KIND.GOOMBA, KIND.KOOPA]:
		await test_effect_pixels_for(kind)

func test_effect_pixels_for(kind: int) -> void:
	var kn: String = KIND.keys()[kind]
	print("-- the arrival effect on a %s, drawn: only a ring around the enemy, the enemy itself untouched, nothing left afterwards" % kn)
	await drain()
	var before := await game_image("effect_%s_before" % kn.to_lower()) # the empty level: the enemy's pixels are what differs from it
	var on := await capture_run(kind, true, "on")
	var off := await capture_run(kind, false, "off")
	SPAWNER.show_arrival = true
	var h := int(EFFECT.body_height(kind))
	check(on.spot == off.spot and on.view == off.view, "%s: both runs spawned at the same spot with the same camera (%s)" % [kn, on.spot])
	var identical_sprite := true
	var outside_ring := 0
	var detail := []
	for k in OFFSETS:
		var a: Dictionary = on.shots[k]
		var b: Dictionary = off.shots[k]
		if a.actual != b.actual or a.feet != b.feet:
			check(false, "%s: frame +%d: both runs captured the same frame with the enemy in the same place (%d vs %d, %s vs %s)" % [kn, k, a.actual, b.actual, a.feet, b.feet])
			continue
		var feet: Vector2i = Vector2i((a.feet as Vector2).round()) - Vector2i((on.view as Rect2).position)
		var box := Rect2i(feet + Vector2i(-8, 1 - h), Vector2i(16, h)) # the sprite's frame: rows 1-h..0, columns -8..7
		var ring := box.grow(14) # the brackets reach 10 px beyond the sprite, and the game's drop shadow a few more
		var area := box.grow(40)
		var enemy_diff := 0 # pixels the enemy draws that differ with the effect on
		var enemy_pixels := 0
		var ring_diff := 0
		var far_diff := 0
		var enemy_detail := []
		for y in range(maxi(area.position.y, 0), mini(area.end.y, 240)):
			for x in range(maxi(area.position.x, 0), mini(area.end.x, 256)):
				var off_c: Color = b.image.get_pixel(x, y)
				var before_c: Color = before.get_pixel(x, y)
				var is_enemy: bool = box.has_point(Vector2i(x, y)) and maxf(absf(off_c.r - before_c.r), maxf(absf(off_c.g - before_c.g), absf(off_c.b - before_c.b))) > SPRITE_DIFF
				if is_enemy:
					enemy_pixels += 1
				if a.image.get_pixel(x, y) != off_c:
					if is_enemy:
						enemy_diff += 1
						if enemy_detail.size() < 6:
							enemy_detail.append("(%d,%d on=%s off=%s)" % [x - feet.x, y - feet.y, a.image.get_pixel(x, y).to_html(false), off_c.to_html(false)])
					elif ring.has_point(Vector2i(x, y)):
						ring_diff += 1
					else:
						far_diff += 1
		identical_sprite = identical_sprite and enemy_diff == 0 and enemy_pixels > 60
		if enemy_diff > 0 or enemy_pixels <= 60:
			print("%s enemy pixels at +%d: %d drawn, %d differ with the effect on: %s" % [kn, k, enemy_pixels, enemy_diff, enemy_detail])
		outside_ring += far_diff
		detail.append("+%d:%d" % [k, ring_diff])
		a["ring_diff"] = ring_diff
		a["enemy_diff"] = enemy_diff
	check(identical_sprite, "%s: every pixel the enemy itself draws is identical with and without the effect, in every compared frame (and it really is drawn: more than 60 pixels each time)" % kn)
	check(outside_ring == 0, "%s: nothing differs anywhere else in the window: no flash, tint or stray pixel beyond the ring (%d pixels)" % [kn, outside_ring])
	var early: Dictionary = on.shots[1]
	check(early.get("ring_diff", 0) > 10 and early.get("ring_diff", 0) < 260, "%s: while it runs the pictures differ in a ring around the enemy (%d pixels at +1; per frame %s)" % [kn, early.get("ring_diff", 0), detail])
	var late: Dictionary = on.shots[40]
	check(late.get("ring_diff", -1) == 0 and late.get("enemy_diff", -1) == 0, "%s: 40 frames after the spawn the whole area around the enemy is identical to the run without the effect: completely normal" % kn)
	check(on.shots[40].fx_step == -1 and on.shots[26].fx_step >= 3, "%s: (the effect was still running at +26 and gone at +40)" % kn)
	# the brackets are really drawn: white corners just outside the sprite (margin 2 at the first step)
	var fx_pos: Vector2 = early.fx_pos
	check(fx_pos != Vector2.INF and early.fx_step == 0, "%s: (at +1 the effect is in its first step)" % kn)
	var m: int = EFFECT.MARGINS[0]
	var view_pos: Vector2 = (on.view as Rect2).position
	var tl: Vector2 = fx_pos + Vector2(-8 - m, 1 - h - m) - view_pos # the top-left bracket's corner pixel
	var bl: Vector2 = fx_pos + Vector2(-8 - m, m) - view_pos # the bottom-left one (an enemy at the view's right edge has its right-hand brackets clipped by the window)
	var img1: Image = early.image
	var img0: Image = off.shots[1].image
	var c_on := img1.get_pixel(int(tl.x), int(tl.y))
	check(near_white(c_on) and not near_white(img0.get_pixel(int(tl.x), int(tl.y))), "%s: the top-left bracket is white on screen at the first step, and that pixel is not white without the effect (%s)" % [kn, c_on])
	check(near_white(img1.get_pixel(int(bl.x), int(bl.y))) and not near_white(img0.get_pixel(int(bl.x), int(bl.y))), "%s: ...and so is the bottom-left one" % kn)
	var after: Image = on.shots[40].image
	check(not near_white(after.get_pixel(int(tl.x), int(tl.y))), "%s: 40 frames later nothing white is left at the place of the bracket" % kn)

# ---- the strip's colours -------------------------------------------------------------------------------------------

## The colour of the `slot`-th icon's tile on the incoming bar (icons in send order; see BattleIncomingStrip.place_all), sampled `dx`
## from the icon's centre and `dy` below the bar's top: by default just inside the tile's top-left, left of the enemy's little picture.
func slot_color(img: Image, slot: int, dx := -3.4, dy := 2.4) -> Color:
	var bar = current_scene.incoming_strip
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var strip_rect: Rect2 = current_scene.layout.strip_a
	return canvas_color(img, int(floorf(strip_rect.position.x + xs[slot] + dx)), int(floorf(strip_rect.position.y + dy)))

## The bar's zone colour at the bar-local x `x`.
func zone_at(x: float) -> Color:
	var bar = current_scene.incoming_strip
	if x < bar.gold_end(bar.size.x):
		return STRIP.ZONE_GOLD
	if x < bar.orange_end(bar.size.x):
		return STRIP.ZONE_ORANGE
	return STRIP.ZONE_DARK

## Whether slot `slot`'s little sprite is on the bar: some pixel of its 8 x 8 box differs clearly from the zone colour under it.
func icon_on_bar(img: Image, slot: int) -> bool:
	var bar = current_scene.incoming_strip
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var strip_rect: Rect2 = current_scene.layout.strip_a
	var zone := zone_at(xs[slot])
	for dy in range(2, 11, 2):
		for dx in range(-3, 4, 2):
			if not near(canvas_color(img, int(floorf(strip_rect.position.x + xs[slot] + dx)), int(floorf(strip_rect.position.y + dy))), zone, 0.15):
				return true
	return false

## Whether the gold zone just left of the boundary is clean (nothing of an icon is there).
func gold_clean(img: Image) -> bool:
	var bar = current_scene.incoming_strip
	var strip_rect: Rect2 = current_scene.layout.strip_a
	var bx: float = strip_rect.position.x + bar.gold_end(bar.size.x)
	for dx in range(-14, -5, 2):
		for dy in range(3, 10, 2):
			if not near(canvas_color(img, int(floorf(bx + dx)), int(floorf(strip_rect.position.y + dy))), STRIP.ZONE_GOLD, 0.1):
				return false
	return true

func test_strip_colours() -> void:
	print("-- the strip, drawn: bare icons that travel, wait, and leave when their enemy appears (doc 54)")
	await drain()
	var atks := []
	for i in 5:
		atks.append(session.report_enemy_defeat(alive_bot(i), KIND.GOOMBA if i % 2 == 0 else KIND.KOOPA))
	await frames(8)
	var img := await screen_image("strip_1_just_sent")
	var bar = current_scene.incoming_strip
	var drawn := 0
	var plated := 0
	for i in 5:
		if icon_on_bar(img, i):
			drawn += 1
		if not near(slot_color(img, i, -5.6, 4.0), STRIP.ZONE_DARK, 0.1):
			plated += 1
	check(drawn == 5 and plated == 0, "just sent: five sprites at the bar's right end, bare: no plate or outline in the bar's own dark orange (%d drawn, %d plated)" % [drawn, plated])
	await frames(75)
	img = await screen_image("strip_2_travelling")
	var xs_now: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	check(xs_now[0] < bar.entry_x(bar.size.x) - 20.0 and icon_on_bar(img, 0), "a second and a quarter later they are well on their way, still bare sprites")
	# the first enemy appears in the level: its icon runs on across the boundary and is gone, leaving nothing in the gold zone
	await wait_until(func(): return atks[0].spawned_tick >= 0, 60 * 8)
	await frames(60)
	img = await screen_image("strip_3_released")
	check(atks[0].spawned_tick >= 0 and gold_clean(img), "when its enemy is in the level the icon has crossed the boundary and is gone: no marker, no flash left in the gold zone")
	await wait_until(func(): return atks[1].spawned_tick >= 0, 60 * 8)
	await frames(30) # (the third appears a second after the second)
	img = await screen_image("strip_4_phases")
	check(atks[0].spawned_tick >= 0 and atks[1].spawned_tick >= 0 and atks[2].spawned_tick < 0 and gold_clean(img), "(the first two enemies are in the level, the third is still arriving) and the gold zone is still clean")
	check(icon_on_bar(img, 2) and icon_on_bar(img, 3), "the ones still arriving and queued are on the bar")
	# the player defeats the first one: nothing is drawn for it (no green fade)
	node_for(atks[0].seq).stomped_on(player())
	await frames(6)
	img = await screen_image("strip_5_defeated")
	check(gold_clean(img), "defeated: no icon fades green in the gold zone (the reference's icon was gone when its enemy appeared)")
	await frames(45)
	img = await screen_image("strip_6_after")
	check(gold_clean(img) and icon_on_bar(img, 1), "half a second later the strip is as it was (%s)" % [slot_color(img, 1)])
	await drain()
