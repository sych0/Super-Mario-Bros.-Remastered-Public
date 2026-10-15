extends SceneTree
## PROTOTYPE, NOT PRODUCT CODE. Reproduces the evidence for docs/38-battle-screen-architecture.md:
## the Battle screen as the root canvas (480x270 logical, rendered at display resolution), the
## classic level running unchanged inside a 256x240 SubViewport shown as the centre window, and
## the 34 opponent previews rendered at full internal resolution into one atlas SubViewport and
## downsampled into small panes. Nothing here is wired into the game.
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 \
##     -s tests/tools/battle_screen_spike.gd -- out=/some/dir [w=1920 h=1080] [tick=40] \
##     [pack=<resource pack>] [filter=box|linear] [hud=canvas|window]
##
## hud=window redirects the GameHUD CanvasLayer into the game SubViewport (custom_viewport) to show
## why that does not work for anchored UI; the default keeps it in the canvas, over the window.

const CANVAS := Vector2i(480, 270)
const GAME := Rect2(112, 3, 256, 240)
const PANEL_W := 108.0
const CELL := Vector2(32, 41)
const GAP := 2.0
const GRID_TOP := 12.0
const ATLAS_COLS := 7
const ATLAS_PAD := 4
const GOLD := Color(0.97, 0.70, 0.14)
const FRAME := Color(0.93, 0.55, 0.08)
const BOX_SHADER := """
shader_type canvas_item;
// Downsample: 4 bilinear taps spread over this pixel's footprint in the source (about a box
// filter over up to 4x4 texels), so a full-size picture minifies smoothly without mipmaps.
void fragment() {
	vec2 o = fwidth(UV) * 0.25;
	COLOR = 0.25 * (texture(TEXTURE, UV + vec2(-o.x, -o.y)) + texture(TEXTURE, UV + vec2(o.x, -o.y))
		+ texture(TEXTURE, UV + vec2(-o.x, o.y)) + texture(TEXTURE, UV + vec2(o.x, o.y)));
}
"""

var args := {}
var G
var game_vp: SubViewport

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func frames(n: int) -> void:
	for i in n:
		await process_frame

## 17 pane rects per side in reading order; the inner top corner of each side is the badge.
static func pane_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var grid_w := 3 * CELL.x + 2 * GAP
	for side in 2:
		var x0 := floorf((PANEL_W - grid_w) / 2.0) + (0.0 if side == 0 else CANVAS.x - PANEL_W)
		for k in 18:
			if k == (2 if side == 0 else 0):
				continue
			out.append(Rect2(x0 + (k % 3) * (CELL.x + GAP), GRID_TOP + (k / 3) * (CELL.y + GAP), CELL.x, CELL.y))
	return out

## The milestone-1 renderer zooms 1.6x and enlarges actors 1.35x to survive a 26x33-pixel cell.
## With full-resolution cells both go back to 1.0 (doc 38, section 6). The spike applies that in
## memory only, by compiling a copy of the shipped script with the two constants changed.
func _renderer_at_1x() -> GDScript:
	var src := FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleMiniGameRenderer.gd")
	src = src.replace("class_name BattleMiniGameRenderer\n", "")
	src = src.replace("const ZOOM := 1.6", "const ZOOM := 1.0").replace("const ACTOR_SCALE := 1.35", "const ACTOR_SCALE := 1.0")
	var script := GDScript.new()
	script.source_code = src
	script.reload()
	return script

func _window_canvas() -> void:
	root.size = Vector2i(int(args.get("w", "1920")), int(args.get("h", "1080")))
	root.content_scale_size = CANVAS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL

func _restore(settings: Node, saved: Dictionary) -> void:
	settings.file.visuals.resource_packs.assign(saved.packs)
	settings.file.video.hud_size = saved.hud_size
	G.get_node("GameHUD").offset = Vector2.ZERO
	G.get_node("GameHUD").custom_viewport = null
	G.get_node("Transition").custom_viewport = null
	root.size = saved.window
	await frames(2)

func _rect(parent: Node, r: Rect2, c: Color) -> ColorRect:
	var n := ColorRect.new()
	n.position = r.position
	n.size = r.size
	n.color = c
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(n)
	return n

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	var settings = root.get_node("Settings")
	# The game writes its settings file on exit, so everything touched here is put back in _restore().
	var saved := {"packs": settings.file.visuals.resource_packs.duplicate(), "hud_size": settings.file.video.hud_size, "window": root.size}
	if args.has("pack"):
		settings.file.visuals.resource_packs.insert(0, args.pack)
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Driver = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	var Surface = load("res://Scripts/Classes/Battle/BattlePreviewSurface.gd")
	var Renderer = _renderer_at_1x()
	_window_canvas()

	# ---- the Battle screen (would be the current scene during Battle) ----
	var screen := Control.new()
	screen.name = "BattleScreenSpike"
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.process_mode = Node.PROCESS_MODE_ALWAYS
	_rect(screen, Rect2(Vector2.ZERO, CANVAS), GOLD)
	_rect(screen, Rect2(GAME.position.x - 4, 0, GAME.size.x + 8, CANVAS.y - 2), FRAME)
	# strips below the game window (placeholders: progress / incoming, coins / item)
	_rect(screen, Rect2(GAME.position.x, GAME.end.y + 2, GAME.size.x, 11), Color(0.98, 0.62, 0.12))
	_rect(screen, Rect2(GAME.position.x, GAME.end.y + 14, GAME.size.x, 11), Color(0.99, 0.80, 0.30))
	# the classic game: a 256x240 SubViewport shown 1:1 (logical) as the centre window
	var box := SubViewportContainer.new()
	box.position = GAME.position
	box.size = GAME.size
	box.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	game_vp = SubViewport.new()
	game_vp.name = "GameViewport"
	game_vp.size = Vector2i(GAME.size)
	game_vp.audio_listener_enable_2d = true
	game_vp.process_mode = Node.PROCESS_MODE_PAUSABLE
	box.add_child(game_vp)
	screen.add_child(box)
	# opponent previews: one atlas SubViewport at internal resolution (classic camera band, 1:1)
	var cell_px := Vector2(roundf(240.0 * CELL.x / CELL.y), 240.0)
	var atlas := SubViewport.new()
	atlas.name = "PreviewAtlas"
	atlas.size = Vector2i(ATLAS_COLS * int(cell_px.x + ATLAS_PAD), 5 * int(cell_px.y + ATLAS_PAD))
	atlas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	screen.add_child(atlas)
	var mat: ShaderMaterial = null
	if args.get("filter", "box") == "box":
		mat = ShaderMaterial.new()
		mat.shader = Shader.new()
		mat.shader.code = BOX_SHADER
	var session = Session.new(int(args.get("seed", "19")))
	# create() divides by the shipped renderer's ZOOM; pass the width that yields a 1:1 world view.
	var driver = Driver.create(session, range(1, 35), cell_px.x * load("res://Scripts/Classes/Battle/BattleMiniGameRenderer.gd").ZOOM)
	var cells: Array = []
	var panes := pane_rects()
	for i in 34:
		var id := i + 1
		var cell = Surface.new(id, null) # milestone-1 surface reused as the atlas cell for the spike
		cell.position = Vector2((i % ATLAS_COLS) * (cell_px.x + ATLAS_PAD), (i / ATLAS_COLS) * (cell_px.y + ATLAS_PAD))
		cell.size = cell_px
		cell.set_live(Renderer.new(), driver.tracks[id].frame)
		atlas.add_child(cell)
		cells.append(cell)
		var tex := AtlasTexture.new()
		tex.atlas = atlas.get_texture()
		tex.region = Rect2(cell.position, cell_px)
		var pane := TextureRect.new()
		pane.texture = tex
		pane.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pane.stretch_mode = TextureRect.STRETCH_SCALE
		pane.position = panes[i].position
		pane.size = panes[i].size
		pane.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		pane.material = mat
		screen.add_child(pane)
	# badges (inner top corners)
	var bl := _rect(screen, Rect2(panes[1].end.x + GAP, 0, CELL.x, 30), Color(0.4, 0.22, 0.1))
	_rect(bl, Rect2(1, 1, CELL.x - 2, 28), Color(0.99, 0.97, 0.9))
	var br := _rect(screen, Rect2(panes[17].position.x - GAP - CELL.x, 0, CELL.x, 44), Color(0.4, 0.22, 0.1))
	_rect(br, Rect2(1, 1, CELL.x - 2, 42), Color(0.99, 0.97, 0.9))

	G.current_game_mode = G.GameMode.CAMPAIGN # the spike drives the plain classic level
	G.clear_saved_values()
	G.world_num = 1
	G.level_num = 1
	G.reset_values()
	change_scene_to_node(screen)
	await scene_changed
	game_vp.add_child(load("res://Scenes/Levels/SMB1/World1/1-1.tscn").instantiate())
	G.get_node("Transition").custom_viewport = game_vp # full-rect fade: renders inside the window
	var hud: CanvasLayer = G.get_node("GameHUD")
	if args.get("hud", "canvas") == "window":
		hud.custom_viewport = game_vp
	else:
		settings.file.video.hud_size = 1 # CENTER_TOP, what Battle forces
		hud.offset = Vector2(0, GAME.position.y)
	await frames(30)
	_window_canvas() # Level.reset_resolution stomps root while a level loads; Battle must own it
	while session.tick_count < int(args.get("tick", "40")):
		session.step()
		driver.update(0.0)
		driver.update(0.5)
	driver.update(0.0)
	for c in cells:
		c.refresh(session.contestants[c.contestant_id])
		c.queue_redraw()
	Input.action_press("move_right_0")
	await frames(40)
	Input.action_release("move_right_0")
	await frames(10)
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	var out: String = args.get("out", "/tmp/battle_screen_spike")
	DirAccess.make_dir_recursive_absolute(out)
	var file := "%s/battle_screen_%dx%d_%s_%s.png" % [out, root.size.x, root.size.y, args.get("filter", "box"), args.get("hud", "canvas")]
	img.save_png(file)
	print("CAPTURE ", file, " window ", DisplayServer.window_get_size(), " at ", DisplayServer.window_get_position(), " game viewport ", game_vp.get_visible_rect().size, " level in game viewport: ", G.current_level != null and G.current_level.get_viewport() == game_vp)
	await _restore(settings, saved)
	quit(0)
