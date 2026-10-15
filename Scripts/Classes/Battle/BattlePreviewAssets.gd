class_name BattlePreviewAssets
extends RefCounted
## Baked art for one level's opponent previews, shared by every preview on that level: one
## level-sized "strip" texture (terrain, deco, blocks, pipes, flagpole, castle), the parallax
## hills, and small mipmapped sprite frames for Mario and the enemies. Everything comes from
## the game's real artwork through BattlePreviewResolver, so resource packs and themes apply.
## Mipmaps matter: previews are drawn at ~0.15x, where raw nearest-filtered pixels alias.
##
## SCOPE (milestone 1): SMB1 terrain/deco/hills, Mario Small/Big/Fire, Goomba, green Koopa.

const SPRITES := "res://Assets/Sprites/"
const TILE := 16
const STRIP_BOTTOM := 64 ## world y of the strip's bottom edge
const MARIO_ANIMS := ["Idle", "Move", "Skid", "Jump", "Climb", "Die", "Grow"]
const MARIO_FILES := ["Small", "Big", "Fire"]

static var _cache := {}

var sketch: BattleLevelSketch = null
var errors: Array[String] = []

var sky_color := Color(0.46, 0.52, 1.0)
var strip: ImageTexture = null
var strip_origin := Vector2.ZERO
var strip_size := Vector2.ZERO
var hills: ImageTexture = null
var hills_y := 0.0 ## world y of the hills texture's top edge
var flag_cloth: BattlePreviewSprite = null
var mario := {} ## power -> anim -> {frames: Array[BattlePreviewSprite], fps: float}
var enemies := {} ## kind -> {walk: Array, fps: float, dead: BattlePreviewSprite}
var bake_ms := 0.0

var _images := {}

## Shared per (theme, time, campaign, level). Returns null if anything essential is missing.
static func build(sk: BattleLevelSketch) -> BattlePreviewAssets:
	var key := "%s|%s|%s|%s" % [sk.scene_path, sk.theme, sk.theme_time, sk.campaign]
	if _cache.has(key):
		return _cache[key]
	var a := BattlePreviewAssets.new()
	a.sketch = sk
	var t0 := Time.get_ticks_usec()
	var ok := a._bake()
	a.bake_ms = (Time.get_ticks_usec() - t0) / 1000.0
	if not ok:
		push_warning("Battle preview art unavailable: " + "; ".join(a.errors))
		a = null
	_cache[key] = a
	return a

static func clear_cache() -> void:
	_cache.clear()

func _resolve(json_name: String) -> Dictionary:
	var r := BattlePreviewResolver.resolve(SPRITES + json_name, sketch.theme, sketch.theme_time, sketch.campaign)
	if not r.ok:
		errors.append("cannot resolve " + json_name)
	return r

func _image(path: String) -> Image:
	if _images.has(path):
		return _images[path]
	var img: Image = null
	if path.begins_with("res://"):
		var tex := load(path) as Texture2D
		if tex != null:
			img = tex.get_image()
	elif FileAccess.file_exists(path):
		img = Image.load_from_file(path)
	if img != null:
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
	else:
		errors.append("cannot read " + path)
	_images[path] = img
	return img

## Image + the absolute rect of its first animation frame (or the variation rect).
func _frame_source(json_name: String, anim: String, frame := 0) -> Dictionary:
	var r := _resolve(json_name)
	if not r.ok:
		return {}
	var img := _image(r.source)
	if img == null:
		return {}
	var rect: Rect2i = r.rect
	if rect.size == Vector2i.ZERO:
		rect = Rect2i(Vector2i.ZERO, img.get_size())
	var frames: Array = []
	if r.animations.has(anim) and r.animations[anim].has("frames"):
		frames = r.animations[anim].frames
	if frames.size() > frame and frames[frame].size() == 4:
		var f: Array = frames[frame]
		rect = Rect2i(rect.position.x + int(f[0]), rect.position.y + int(f[1]), int(f[2]), int(f[3]))
	return {"image": img, "rect": rect, "resolved": r}

func _bake() -> bool:
	# --- sources
	var terrain := _frame_source("Tilesets/Terrain/TerrainTiles.json", "")
	var deco := _frame_source("Tilesets/Deco/DecoTiles.json", "")
	var sky := _frame_source("Backgrounds/Skies/Sky.json", "default")
	var hill := _frame_source("Backgrounds/Hills/Hill.json", "default")
	var brick := _frame_source("Tilesets/Terrain/BrickBlock.json", "default")
	var question := _frame_source("Blocks/QuestionBlock.json", "default")
	var pole := _frame_source("Tilesets/FlagPole.json", "")
	var flag := _frame_source("Tilesets/Flag.json", "")
	if not errors.is_empty() or terrain.is_empty() or sky.is_empty() or hill.is_empty():
		return false
	sky_color = (sky.image as Image).get_pixel(0, 0)
	sky_color.a = 1.0
	_bake_hills(hill)
	_bake_strip(terrain, deco, brick, question, pole)
	if not flag.is_empty():
		flag_cloth = _crop(flag.image, flag.rect, Vector2(8, 8))
	_bake_mario()
	_bake_enemies()
	return errors.is_empty() and strip != null and mario.size() == 3 and enemies.has("goomba")

func _texture(img: Image) -> ImageTexture:
	img.fix_alpha_edges()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _bake_hills(hill: Dictionary) -> void:
	var img: Image = hill.image
	var rect: Rect2i = hill.rect
	var frame := img.get_region(rect)
	var used := frame.get_used_rect()
	if used.size == Vector2i.ZERO:
		return
	# keep full width (it tiles every 512 px) but only the rows that have art
	var cropped := frame.get_region(Rect2i(0, used.position.y, frame.get_width(), frame.get_height() - used.position.y))
	hills = _texture(cropped)
	# The hills sprite is placed at y = -512 under a layer offset of +32 in LevelBG.tscn.
	hills_y = -512.0 + 32.0 + used.position.y

func _bake_strip(terrain: Dictionary, deco: Dictionary, brick: Dictionary, question: Dictionary, pole: Dictionary) -> void:
	var x0 := floori(sketch.bounds_min_x() / TILE) * TILE - TILE
	var x1 := ceili(sketch.bounds_max_x() / TILE) * TILE + TILE
	var y0 := floori((sketch.vertical_top - TILE) / TILE) * TILE
	strip_origin = Vector2(x0, y0)
	strip_size = Vector2(x1 - x0, STRIP_BOTTOM - y0)
	var img := Image.create(int(strip_size.x), int(strip_size.y), false, Image.FORMAT_RGBA8)
	var t_img: Image = terrain.image
	var t_rect: Rect2i = terrain.rect
	var put := func(src: Image, src_rect: Rect2i, wx: int, wy: int) -> void:
		img.blend_rect(src, src_rect, Vector2i(wx - x0, wy - y0))
	# deco (bushes) first: it sits behind the terrain
	if not deco.is_empty():
		var d_img: Image = deco.image
		var d_rect: Rect2i = deco.rect
		for k in range(0, sketch.deco_cells.size(), 4):
			var src := Rect2i(d_rect.position.x + sketch.deco_cells[k + 2] * TILE, d_rect.position.y + sketch.deco_cells[k + 3] * TILE, TILE, TILE)
			put.call(d_img, src, sketch.deco_cells[k] * TILE, sketch.deco_cells[k + 1] * TILE)
	for k in range(0, sketch.castle_bg_cells.size(), 4):
		var src := Rect2i(t_rect.position.x + sketch.castle_bg_cells[k + 2] * TILE, t_rect.position.y + sketch.castle_bg_cells[k + 3] * TILE, TILE, TILE)
		put.call(t_img, src, sketch.castle_bg_cells[k], sketch.castle_bg_cells[k + 1])
	for k in range(0, sketch.castle_cells.size(), 4):
		var src := Rect2i(t_rect.position.x + sketch.castle_cells[k + 2] * TILE, t_rect.position.y + sketch.castle_cells[k + 3] * TILE, TILE, TILE)
		put.call(t_img, src, sketch.castle_cells[k], sketch.castle_cells[k + 1])
	if not pole.is_empty():
		put.call(pole.image, pole.rect, roundi(sketch.goal_x) - 8, -176)
	for k in range(0, sketch.terrain_cells.size(), 4):
		var src := Rect2i(t_rect.position.x + sketch.terrain_cells[k + 2] * TILE, t_rect.position.y + sketch.terrain_cells[k + 3] * TILE, TILE, TILE)
		put.call(t_img, src, sketch.terrain_cells[k] * TILE, sketch.terrain_cells[k + 1] * TILE)
	for b in sketch.blocks:
		var src: Dictionary = brick if b.kind == "brick" else question
		if not src.is_empty():
			put.call(src.image, src.rect, b.tx * TILE, b.ty * TILE)
	strip = _texture(img)

## Crops `rect` out of `img`, trims transparent borders, and anchors it at `anchor` (given in
## the uncropped rect's own coordinates).
func _crop(img: Image, rect: Rect2i, anchor: Vector2) -> BattlePreviewSprite:
	var cell := img.get_region(rect)
	var used := cell.get_used_rect()
	if used.size == Vector2i.ZERO:
		used = Rect2i(0, 0, 1, 1)
	var piece := cell.get_region(used)
	var s := BattlePreviewSprite.new()
	s.texture = _texture(piece)
	s.size = Vector2(used.size)
	s.offset = Vector2(used.position) - anchor
	return s

func _frames(img: Image, base: Rect2i, frames: Array) -> Array[BattlePreviewSprite]:
	var out: Array[BattlePreviewSprite] = []
	for f in frames:
		var rect := Rect2i(base.position.x + int(f[0]), base.position.y + int(f[1]), int(f[2]), int(f[3]))
		out.append(_crop(img, rect, Vector2(rect.size.x / 2.0, rect.size.y)))
	return out

func _bake_mario() -> void:
	for power in MARIO_FILES.size():
		var r := _resolve("Players/Mario/%s.json" % MARIO_FILES[power])
		if not r.ok:
			return
		var img := _image(r.source)
		if img == null:
			return
		var base: Rect2i = r.rect
		var set := {}
		for anim in MARIO_ANIMS:
			if r.animations.has(anim):
				var a: Dictionary = r.animations[anim]
				set[anim] = {"frames": _frames(img, base, a.frames), "fps": float(a.get("speed", 5))}
		mario[power] = set

func _bake_enemy(kind: String, json_name: String, walk_anim: String, dead_json: String, dead_anim: String) -> void:
	var r := _resolve(json_name)
	if not r.ok:
		return
	var img := _image(r.source)
	if img == null or not r.animations.has(walk_anim):
		return
	var walk: Dictionary = r.animations[walk_anim]
	var entry := {"walk": _frames(img, r.rect, walk.frames), "fps": float(walk.get("speed", 5))}
	var rd: Dictionary = r if dead_json == json_name else _resolve(dead_json)
	if rd.ok and rd.animations.has(dead_anim):
		var dimg := _image(rd.source)
		if dimg != null:
			var dead := _frames(dimg, rd.rect, rd.animations[dead_anim].frames)
			if not dead.is_empty():
				entry["dead"] = dead[0]
	enemies[kind] = entry

func _bake_enemies() -> void:
	_bake_enemy("goomba", "Enemies/Goomba.json", "Walk", "Enemies/Goomba.json", "Stomped")
	_bake_enemy("koopa_green", "Enemies/GreenKoopaTroopa.json", "Walk", "Enemies/GreenKoopaShell.json", "Idle")

# ---- lookups used while drawing

func mario_frame_at(power: int, anim: String, index: int) -> BattlePreviewSprite:
	var set: Dictionary = mario.get(clampi(power, 0, 2), {})
	var a: Dictionary = set.get(anim, set.get("Idle", {}))
	if a.is_empty():
		return null
	var frames: Array = a.frames
	return frames[index % frames.size()]

func enemy_frame(kind: String, t: float) -> BattlePreviewSprite:
	var e: Dictionary = enemies.get(kind, {})
	if e.is_empty():
		return null
	var frames: Array = e.walk
	return frames[int(t * e.fps) % frames.size()]

func enemy_dead(kind: String) -> BattlePreviewSprite:
	return enemies.get(kind, {}).get("dead", null)
