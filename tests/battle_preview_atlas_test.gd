extends SceneTree
## Headless checks for Battle screen milestone 2 (doc 38, section 6): full-resolution opponent
## previews in one shared atlas, downsampled into 34 panes. Covers the atlas geometry (cell size,
## unique non-overlapping regions, padding), the pane -> region mapping, the 1:1 renderer scale,
## live versus placeholder cells, determinism with previews on or off, the debug view and
## Classic. The GPU-side checks (bleed, captures) are in battle_preview_render_test.gd.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_preview_atlas_test.gd

var failures := 0
var G
var S
var D
var Screen
var Atlas
var Mini
var Pane
var Cell
var Layout

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	D = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	Screen = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	Atlas = load("res://Scripts/Classes/Battle/BattlePreviewAtlas.gd")
	Mini = load("res://Scripts/Classes/Battle/BattleMiniGameRenderer.gd")
	Pane = load("res://Scripts/Classes/Battle/BattleOpponentPane.gd")
	Cell = load("res://Scripts/Classes/Battle/BattlePreviewCell.gd")
	Layout = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	test_atlas_geometry()
	test_renderer_scale()
	test_uv_region()
	await test_screen_mapping()
	await test_fallback()
	await test_results_identical_with_previews()
	await test_classic_unaffected()
	if failures > 0:
		printerr("%d Battle preview atlas test(s) failed" % failures)
	else:
		print("All Battle preview atlas tests passed")
	quit(1 if failures > 0 else 0)

# ------------------------------------------------------------------ pure geometry

func test_atlas_geometry() -> void:
	check(Atlas.CELL_PX == Vector2i(187, 240), "an atlas cell is 187x240 texels (the classic camera band at 1:1)")
	check(Atlas.COLUMNS == 7 and Atlas.ROWS == 5 and Atlas.cell_count() == 34 and Atlas.COLUMNS * Atlas.ROWS >= 34, "7x5 layout holds the 34 cells")
	var size: Vector2i = Atlas.size_px()
	check(size == Vector2i(1337, 1220), "atlas is 1337x1220 texels (%s)" % size)
	check(Atlas.memory_bytes() == 1337 * 1220 * 4, "atlas costs %.2f MB as RGBA8" % (Atlas.memory_bytes() / 1048576.0))
	var rects: Array[Rect2i] = []
	for i in 34:
		rects.append(Atlas.cell_rect(i))
	var inside := true
	var sized := true
	for r in rects:
		if not Rect2i(Vector2i.ZERO, size).encloses(r):
			inside = false
		if r.size != Atlas.CELL_PX:
			sized = false
	check(inside and sized, "every cell lies inside the atlas and is exactly 187x240")
	var unique := {}
	for r in rects:
		unique[r.position] = true
	check(unique.size() == 34, "34 distinct atlas regions")
	# No overlap, and at least PAD texels of empty atlas between any two cells (room for the downsample taps).
	var min_gap := 9999
	var overlap := false
	for i in 34:
		for j in range(i + 1, 34):
			var a: Rect2i = rects[i]
			var b: Rect2i = rects[j]
			if a.intersects(b):
				overlap = true
			var gx := maxi(b.position.x - a.end.x, a.position.x - b.end.x)
			var gy := maxi(b.position.y - a.end.y, a.position.y - b.end.y)
			min_gap = mini(min_gap, maxi(gx, gy))
	check(not overlap, "no two atlas regions overlap")
	check(min_gap >= Atlas.PAD, "at least %d texels of padding between any two cells (smallest gap %d)" % [Atlas.PAD, min_gap])
	var edge := 9999
	for r in rects:
		edge = mini(edge, mini(r.position.x, r.position.y))
		edge = mini(edge, mini(size.x - r.end.x, size.y - r.end.y))
	check(edge >= Atlas.PAD / 2, "the outermost cells also keep %d texels from the atlas edge (%d)" % [Atlas.PAD / 2, edge])
	var slots: Array = Layout.compute().slots
	var cell: Vector2 = Layout.CELL
	check(absf(Atlas.CELL_PX.x / float(Atlas.CELL_PX.y) - cell.x / cell.y) < 0.01, "the cell aspect equals the pane aspect, so downsampling never distorts (%.3f vs %.3f)" % [Atlas.CELL_PX.x / float(Atlas.CELL_PX.y), cell.x / cell.y])
	check(slots.size() == 34, "34 pane slots on the canvas")

func test_renderer_scale() -> void:
	check(Mini.ZOOM == 1.0, "ZOOM == 1.0 (the preview draws at gameplay scale)")
	check(Mini.ACTOR_SCALE == 1.0, "ACTOR_SCALE == 1.0 (actors are normal gameplay size)")
	check(is_equal_approx(Mini.world_width(187.0), 187.0), "a 187-texel cell shows 187 world px (1:1)")

func test_uv_region() -> void:
	var atlas_size := Vector2(Atlas.size_px())
	var ok := true
	for i in 34:
		var r: Rect2i = Atlas.cell_rect(i)
		var uv: Vector4 = Pane.uv_region(r, atlas_size)
		var x0 := uv.x * atlas_size.x
		var y0 := uv.y * atlas_size.y
		var x1 := (uv.x + uv.z) * atlas_size.x
		var y1 := (uv.y + uv.w) * atlas_size.y
		# Taps clamp to this rect: it must sit half a texel inside the cell, never reaching the padding.
		if not (is_equal_approx(x0, r.position.x + 0.5) and is_equal_approx(y0, r.position.y + 0.5) \
				and is_equal_approx(x1, r.end.x - 0.5) and is_equal_approx(y1, r.end.y - 0.5)):
			ok = false
	check(ok, "every pane's tap-clamp rect is its own cell inset by half a texel (no bleed from the padding or a neighbour)")
	var shader := load("res://Scenes/Parts/BattlePreviewDownsample.gdshader") as Shader
	check(shader != null and shader.code.contains("clamp(") and shader.code.contains("uniform vec4 region") and shader.code.contains("fwidth(UV)"), "the downsample shader clamps every tap to the pane's region and sizes the footprint from fwidth")

# ------------------------------------------------------------------ the screen

func test_screen_mapping() -> void:
	G.current_game_mode = G.GameMode.BATTLE
	var s = S.begin(19)
	var screen = Screen.new()
	root.add_child(screen)
	await frames(4)
	check(screen.panes.size() == 34 and screen.cells.size() == 34, "34 panes on the canvas and 34 cells in the atlas")
	var seen := {}
	var mapped := true
	var shared := true
	for i in 34:
		var pane = screen.panes[i]
		var tex := pane.picture.texture as AtlasTexture
		if tex == null or tex.atlas != screen.atlas.get_texture() or tex.region != Rect2(Atlas.cell_rect(i)) or pane.region_px != Atlas.cell_rect(i):
			mapped = false
		if tex != null and tex.atlas != screen.atlas.get_texture():
			shared = false
		seen[Vector2(tex.region.position)] = true
		if pane.cell != screen.cells[i] or pane.contestant_id != i + 1 or screen.cells[i].contestant_id != i + 1:
			mapped = false
		if screen.cells[i].get_parent() != screen.atlas or screen.cells[i].position != Vector2(Atlas.cell_rect(i).position):
			mapped = false
	check(mapped, "pane i shows exactly atlas cell i (contestant i+1) and nothing else")
	check(shared and seen.size() == 34, "all 34 panes sample the one shared atlas through 34 unique regions")
	var viewports := 0
	var players := 0
	var levels := 0
	for n in screen.find_children("*", "", true, false):
		if n is SubViewport:
			viewports += 1
		if n.is_in_group("Players"):
			players += 1
		if n.get("time_limit") != null: # a Level
			levels += 1
	check(viewports == 2, "the screen has exactly 2 SubViewports: the game window and the one preview atlas (%d)" % viewports)
	check(players == 0 and levels == 0, "no Player or Level nodes in the preview machinery")
	check(screen.atlas.size == Atlas.size_px() and screen.atlas.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "the atlas viewport is 1337x1220 and rendered every frame")
	var mats := {}
	var shaders := {}
	for pane in screen.panes:
		var m := pane.picture.material as ShaderMaterial
		if m != null:
			mats[m] = true
			shaders[m.shader] = true
			if pane.picture.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR:
				mats[null] = true
	check(mats.size() == 34 and shaders.size() == 1 and not mats.has(null), "34 pane materials share one downsample shader; panes filter linearly")
	check(screen.cells.all(func(c): return c.size == Vector2(187, 240) and c.clip_contents), "every cell is 187x240 and clips to itself")
	# Everything that must stay sharp is on the pane overlay (display resolution), not in the cell image.
	check(screen.panes.all(func(p): return p.overlay.get_parent() == p and p.picture.get_parent() == p and p.overlay.get_index() > p.picture.get_index()), "frame, ids and KO marking are a separate overlay drawn above each pane's picture")
	# All 34 live on World 1-1.
	check(screen.driver != null and screen.driver.tracks.size() == 34, "a preview track for each of the 34 opponents")
	check(screen.cells.filter(func(c): return c.is_live()).size() == 34, "all 34 supported 1-1 contestants use the live renderer")
	check(screen.cells.all(func(c): return c.live_renderer != null and c.live_renderer.get_script() == Mini), "...and it is the mini-game renderer")
	check(screen.debug_view == null, "no debug view in normal play")
	# Pane layout is the Doc 38 one, untouched.
	var l = Layout.compute()
	check(screen.panes.all(func(p): return p.size == l.cell) and screen.panes[0].position == l.slots[0].position and screen.panes[33].position == l.slots[33].position, "pane geometry is the accepted Battle layout")
	root.remove_child(screen)
	screen.free()
	S.clear()
	await frames(3)
	# Debug view: the same atlas cell, not a second render.
	OS.set_environment("SMB1R_BATTLE_PREVIEW_DEBUG", "1")
	D._flag_cache.clear()
	if OS.is_debug_build():
		S.begin(4)
		var screen2 = Screen.new()
		root.add_child(screen2)
		await frames(4)
		var dv: TextureRect = screen2.debug_view
		check(dv != null and dv.size == Vector2(187, 240), "the dev view shows one cell at its native 187x240")
		check(dv != null and (dv.texture as AtlasTexture).atlas == screen2.atlas.get_texture() and (dv.texture as AtlasTexture).region == Rect2(Atlas.cell_rect(0)), "...as a region of the existing atlas (no second render)")
		var viewports2 := 0
		for n in screen2.find_children("*", "SubViewport", true, false):
			viewports2 += 1
		check(viewports2 == 2, "the dev view adds no viewport")
		root.remove_child(screen2)
		screen2.free()
		S.clear()
		await frames(3)
	OS.set_environment("SMB1R_BATTLE_PREVIEW_DEBUG", "")
	D._flag_cache.clear()
	G.current_game_mode = G.GameMode.CAMPAIGN

func test_fallback() -> void:
	G.current_game_mode = G.GameMode.BATTLE
	var s = S.begin(19)
	var screen = Screen.new()
	root.add_child(screen)
	await frames(4)
	# A picture's frame goes invalid when it has no level to show (after the last course; a track with no stages: doc 55): its cell must
	# fall back cleanly. A normal match never gets there (a clear moves a preview on to the next course), so one run is ended by hand.
	for i in 30:
		s.step()
		screen.driver.update(0.0)
	screen.driver.tracks[1].frame.valid = false
	screen.cells[0].queue_redraw()
	await frames(3)
	var fell = null # BattlePreviewCell (not named: a -s script is compiled before the autoloads exist)
	for c in screen.cells:
		if c.frame != null and not c.frame.valid:
			fell = c
			break
	check(fell != null and fell.contestant_id == 1, "a contestant whose preview has no level to show has an invalid frame")
	if fell != null:
		check(not fell.is_live(), "a cell with no level to show is not drawn by the live renderer")
		var before: int = Cell.stat_placeholder_draws
		fell.queue_redraw()
		await frames(3)
		check(Cell.stat_placeholder_draws > before, "...the placeholder renderer draws that cell instead")
		check(screen.panes[fell.contestant_id - 1].cell == fell and screen.panes[fell.contestant_id - 1].region_px == Atlas.cell_rect(fell.contestant_id - 1), "...in the same atlas region, so the pane is unchanged")
	var others = screen.cells.filter(func(c): return c.frame.valid)
	check(others.size() == 33 and others.all(func(c): return c.is_live()), "every other cell stays live (%d)" % others.size())
	root.remove_child(screen)
	screen.free()
	S.clear()
	await frames(3)
	# Previews off: every cell uses the placeholder.
	Screen.live_previews = false
	S.begin(19)
	var off = Screen.new()
	root.add_child(off)
	await frames(4)
	check(off.driver == null and off.cells.all(func(c): return not c.is_live() and c.renderer.get_script() == load("res://Scripts/Classes/Battle/BattlePlaceholderRenderer.gd")), "previews disabled: all 34 cells use the placeholder")
	root.remove_child(off)
	off.free()
	Screen.live_previews = true
	S.clear()
	await frames(3)
	G.current_game_mode = G.GameMode.CAMPAIGN

func test_results_identical_with_previews() -> void:
	G.current_game_mode = G.GameMode.BATTLE
	var results := {}
	for enabled in [true, false]:
		Screen.live_previews = enabled
		var s = S.begin(23)
		var screen = Screen.new()
		root.add_child(screen)
		await frames(3)
		for i in 600:
			if s.finished:
				break
			s.step()
			if i % 49 == 0:
				s.report_ko(1 + (i % 34), S.KoCause.HAZARD) # external events, the same in both runs
			await process_frame # the screen's driver updates and every cell redraws
		var snap: Dictionary = s.snapshot()
		results[enabled] = [s.tick_count, s.alive_count, s.winner_id, str(snap), s.rng.state, s.get_ranking()]
		root.remove_child(screen)
		screen.free()
		S.clear()
		await frames(2)
	Screen.live_previews = true
	check(results[true] == results[false], "authoritative Battle state (ticks, alive, winner, snapshot, rng state, ranking) is identical with previews on and off")
	var a: Array = results[true]
	check(a[0] > 100, "the compared match ran %d ticks" % a[0])
	G.current_game_mode = G.GameMode.CAMPAIGN

func test_classic_unaffected() -> void:
	G.current_game_mode = G.GameMode.CAMPAIGN
	G.current_campaign = "SMB1"
	G.reset_values()
	var LV = load("res://Scripts/Classes/LevelClass.gd")
	LV.first_load = true
	change_scene_to_file("res://Scenes/Levels/SMB1/World1/1-1.tscn")
	await frames(40)
	check(Screen.instance == null and not Screen.is_active(), "Classic has no Battle screen")
	check(root.find_children("PreviewAtlas", "", true, false).is_empty() and get_nodes_in_group("Players").size() == 1, "Classic has no preview atlas and exactly one Player")
	check(Atlas.size_px() == Vector2i(1337, 1220), "the atlas is only a class: nothing is allocated until a Battle screen builds one")
