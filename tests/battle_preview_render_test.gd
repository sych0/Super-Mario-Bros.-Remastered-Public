extends SceneTree
## Render checks for Battle screen milestone 2 (doc 38, section 6): the 34 opponent panes as a real GL
## renderer draws them, read back from the display framebuffer at 1080p and 720p. Checks that
##  - every pane really shows ITS OWN atlas cell, smoothly downsampled (compared with a software
##    downsample of that cell's pixels),
##  - nothing bleeds between neighbouring atlas cells (34 cells painted in 34 different flat
##    colours must come out as exactly those colours, to the pixel, in every pane),
##  - every live pane has recognisable detail (many distinct colours, ground, sky).
## The standalone Battle screen is used (no level in the game window): only the previews are tested.
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/battle_preview_render_test.gd -- out=/some/dir [pack=SandboxStandIn]

## A flat-colour renderer, so bleed between atlas cells is unmistakable. Built at run time: a -s script
## is compiled before the autoloads exist, and the renderer base class drags in scripts that use them.
const SOLID_SOURCE := """extends "res://Scripts/Classes/Battle/BattlePreviewRenderer.gd"
var color := Color.WHITE
func draw(canvas, _c, size, _frame = null) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, size), color)
"""
var solid_script: GDScript = null

var failures := 0
var args := {}
var G
var S
var SESSION
var HANDLER
var SCREEN
var ATLAS
var out := "/tmp/battle_preview_render"
var scale_px := 4.0
var xform := Transform2D.IDENTITY ## canvas -> display pixels (scale and letterbox offset)

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
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func ensure_window(size: Vector2i) -> void:
	DisplayServer.window_set_position(Vector2i.ZERO)
	root.size = size
	for i in 180:
		await process_frame
		await RenderingServer.frame_post_draw
		var corner := DisplayServer.screen_get_image(0).get_pixel(size.x - 1, size.y - 1)
		if DisplayServer.window_get_size() == size and corner != Color.WHITE and corner.get_luminance() < 0.99:
			break
	await frames(3)

func grab(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	xform = root.get_final_transform()
	scale_px = xform.get_scale().x
	if name != "":
		DirAccess.make_dir_recursive_absolute(out)
		var file := "%s/%s_%dx%d_%.2fx.png" % [out, name, img.get_width(), img.get_height(), scale_px]
		img.save_png(file)
		print("CAPTURE ", file)
	return img

## The pane's picture area in display pixels, inset so the 1-logical-px frame is never read.
func pane_rect_px(pane: Control, inset_px: float) -> Rect2i:
	var r := Rect2(xform * pane.position, pane.size * scale_px)
	return Rect2i(Vector2i(r.position + Vector2(inset_px, inset_px)), Vector2i(r.size - Vector2(inset_px, inset_px) * 2.0))

func mean_error(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := a.get_width() * a.get_height()
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			sum += (absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)) / 3.0
	return sum / maxf(n, 1.0)

func build_screen(live: bool) -> Node:
	var scr = SCREEN.new()
	SCREEN.live_previews = live
	root.add_child(scr)
	return scr

func drop_screen(scr: Node) -> void:
	root.remove_child(scr)
	scr.free()
	SESSION.clear()
	SCREEN.live_previews = true

func run_resolution(size: Vector2i, fractional: bool) -> void:
	S.file.video.scaling = 1 if fractional else 0 # 0 = integer (letterboxed), 1 = fractional
	await ensure_window(size)
	var tag := "%dp%s" % [size.y, " fractional" if fractional else ""]
	# ---- live previews: each pane shows its own cell
	var s = SESSION.begin(int(args.get("seed", "19")))
	var scr = build_screen(true)
	await frames(4)
	for t in 14: # a few seconds in: Marios have spread out along 1-1
		s.step()
		scr.driver.update(0.0)
		scr.driver.update(0.5)
	scr.driver.update(0.0)
	for c in scr.cells:
		c.queue_redraw()
	await frames(6)
	var img: Image = await grab("preview_all34_live")
	var want := float(size.x) / 480.0 if fractional or size.x % 480 == 0 else float(size.x / 480)
	check(absf(scale_px - want) < 0.01 and img.get_size() == size, "[%s] the canvas is shown at %.3fx (integer scaling letterboxes, fractional fills) in a %s window" % [tag, scale_px, size])
	var atlas_img: Image = scr.atlas.get_texture().get_image()
	check(atlas_img.get_size() == Vector2i(1337, 1220), "[%s] the atlas renders at 1337x1220 (%s)" % [tag, atlas_img.get_size()])
	var live: int = scr.cells.filter(func(c): return c.is_live()).size()
	check(live == 34, "[%s] all 34 panes are live" % tag)
	var worst := 0.0
	var worst_id := 0
	var wins := 0
	var compared := 0
	var detail_ok := 0
	var shown := 0
	for i in 34:
		var pane = scr.panes[i]
		if pane.marked:
			continue
		var cell_px: Rect2i = ATLAS.cell_rect(i)
		var own := atlas_img.get_region(cell_px)
		# Compare the right 40% of the picture (the left holds the id / level text drawn at display resolution).
		var r := pane_rect_px(pane, 2.0)
		var strip := Rect2i(r.position.x + int(r.size.x * 0.6), r.position.y, int(r.size.x * 0.4), r.size.y)
		var got := img.get_region(strip)
		var src_strip := Rect2i(int(cell_px.size.x * 0.6), 0, int(cell_px.size.x * 0.4), cell_px.size.y)
		var mine := own.get_region(src_strip)
		mine.resize(strip.size.x, strip.size.y, Image.INTERPOLATE_TRILINEAR)
		var err := mean_error(got, mine)
		if err > worst:
			worst = err
			worst_id = i + 1
		var other := atlas_img.get_region(ATLAS.cell_rect((i + 7) % 34)).get_region(src_strip)
		other.resize(strip.size.x, strip.size.y, Image.INTERPOLATE_TRILINEAR)
		var err_other := mean_error(got, other)
		if mean_error(mine, other) > 0.06: # only pairs of clearly different pictures
			compared += 1
			if err < err_other:
				wins += 1
		# recognisable detail: several distinct colours (sky, ground, bricks/hills, Mario, ...)
		var colors := {}
		var full := img.get_region(Rect2i(r.position.x, r.position.y, r.size.x, r.size.y))
		for y in range(0, full.get_height(), 2):
			for x in range(0, full.get_width(), 2):
				colors[full.get_pixel(x, y).to_html(false).substr(0, 3)] = true
		shown += 1
		if colors.size() >= 6:
			detail_ok += 1
	check(shown >= 15, "[%s] %d unmarked panes were compared" % [tag, shown])
	check(worst < 0.07, "[%s] every pane matches a smooth downsample of its own cell (worst mean error %.3f, pane %d)" % [tag, worst, worst_id])
	check(compared == 0 or wins == compared, "[%s] each pane is closer to its own cell than to another cell (%d/%d)" % [tag, wins, compared])
	check(detail_ok == shown, "[%s] every live pane shows recognisable detail (>= 6 distinct colours): %d/%d" % [tag, detail_ok, shown])
	drop_screen(scr)
	await frames(3)

	# ---- bleed: 34 flat colours, no mixing at pane edges
	SESSION.begin(7)
	var scr2 = build_screen(false)
	await frames(3)
	var colors: Array[Color] = []
	for i in 34:
		var col := Color.from_hsv(fmod(i * 0.381966, 1.0), 0.9, 0.55 + 0.4 * ((i * 7) % 3) / 2.0)
		colors.append(col)
		var solid = solid_script.new()
		solid.color = col
		scr2.cells[i].renderer = solid
		scr2.cells[i].queue_redraw()
	await frames(6)
	var img2: Image = await grab("preview_flat_colours")
	var bad := 0
	var worst_diff := 0.0
	for i in 34:
		var r := pane_rect_px(scr2.panes[i], 2.0)
		# Edge and corner samples that avoid the id (top-left) and level text (bottom-left) drawn on the pane.
		for f in [Vector2(0.0, 0.5), Vector2(0.75, 0.0), Vector2(0.75, 0.5), Vector2(0.75, 1.0), Vector2(1.0, 0.0), Vector2(1.0, 0.5), Vector2(1.0, 1.0)]:
			var x := mini(r.position.x + int(r.size.x * f.x), r.end.x - 1)
			var y := mini(r.position.y + int(r.size.y * f.y), r.end.y - 1)
			var p := img2.get_pixel(x, y)
			var d := maxf(absf(p.r - colors[i].r), maxf(absf(p.g - colors[i].g), absf(p.b - colors[i].b)))
			worst_diff = maxf(worst_diff, d)
			if d > 0.03:
				bad += 1
	check(bad == 0, "[%s] flat-colour cells show no bleed from their neighbours, edges and corners included (worst channel diff %.3f)" % [tag, worst_diff])
	drop_screen(scr2)
	await frames(3)

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	SCREEN = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ATLAS = load("res://Scripts/Classes/Battle/BattlePreviewAtlas.gd")
	out = args.get("out", out)
	solid_script = GDScript.new()
	solid_script.source_code = SOLID_SOURCE
	solid_script.reload()
	var packs: Array = S.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR) # the game saves it on every window change
	var original_window := root.size
	G.current_game_mode = G.GameMode.BATTLE
	# 1080p (4x), 720p with the integer setting (2x, letterboxed) and 720p fractional (2.667x: the
	# awkward, shimmer-prone minification).
	await run_resolution(Vector2i(1920, 1080), false)
	await run_resolution(Vector2i(1280, 720), false)
	await run_resolution(Vector2i(1280, 720), true)
	G.current_game_mode = G.GameMode.NONE
	if added_pack != "":
		packs.erase(added_pack)
	if root.size != original_window:
		root.size = original_window
		await frames(30)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle preview render test(s) failed" % failures)
	else:
		print("All Battle preview render tests passed")
	quit(1 if failures > 0 else 0)
