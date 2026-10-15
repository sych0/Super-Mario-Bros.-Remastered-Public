class_name BattleLevelSketch
extends RefCounted
## Read-only, lightweight description of one level for the opponent previews. Built from the
## saved level scene's data (PackedScene.get_state()) without instantiating the level: tile
## cells, solidity from the real TileSet's collision data, block / enemy / goal / start
## positions and the level's theme. Plus a precomputed "walk line" with the jumps Mario would
## need. It is pure data shared by every preview on that level; it is NOT a level engine.

const TILE := 16
const PIT_Y := 1.0e9 ## "no ground here" marker in ground[]
const GRAVITY := 1000.0
const BOX_HALF_W := 5.0
const BOX_H := 28.0 ## validate arcs for big Mario so one arc works for every power state
const MAX_RISE := 64.0 ## highest ledge a jump can reach
const HEADROOM_ROWS := 2

const TILES_SCENE := "res://Scenes/Parts/Tiles.tscn"
const SMALL_CASTLE_VISUAL := "res://Scenes/Parts/SmallCastleVisual.tscn"
const CASTLE_SCENE := "res://Scenes/Prefabs/LevelObjects/EndSmallCastle.tscn"
## Entity scenes the previews know how to show (anything else is dropped, so new content
## degrades instead of breaking).
const ENEMY_KINDS := {
	"Goomba.tscn": "goomba",
	"GreenKoopaTroopa.tscn": "koopa_green",
}

static var _cache := {}
static var _tileset: TileSet = null
static var _solidity_cache := {}

var scene_path := ""
var theme := "Overworld"
var theme_time := "Day"
var campaign := "SMB1"
var vertical_top := -208.0

var grid_x0 := 0 ## in tiles
var grid_y0 := 0
var grid_w := 0
var grid_h := 0
var grid := PackedByteArray() ## 0 empty, 1 solid, 2 one-way platform

var terrain_cells := PackedInt32Array() ## stride 4: tx, ty, atlas_x, atlas_y (TileSet source 0)
var deco_cells := PackedInt32Array() ## stride 4: tx, ty, atlas_x, atlas_y (DecoTiles)
var castle_cells := PackedInt32Array() ## stride 4: world px x, y, atlas_x, atlas_y (terrain atlas)
var castle_bg_cells := PackedInt32Array()
var blocks: Array[Dictionary] = [] ## {tx, ty, kind: "brick"|"question"}
var spawns: Array[Dictionary] = [] ## {id, kind, x, y}, sorted by x
var dropped_entities := 0

var level_min_x := 0.0 ## horizontal extent of the level's tiles (px); the camera never shows outside it
var level_max_x := 0.0
var start_x := 0.0
var start_y := 0.0
var goal_x := 0.0
var goal_kind := "" ## "flagpole" | "bridge" | ""
var castle_x := 0.0

var ground := PackedFloat32Array() ## per tile column: feet y of the walk line, or PIT_Y
var pits: Array[Vector2] = [] ## x ranges (px) with no ground
var jumps: Array[Dictionary] = [] ## sorted by x_start

static func load_for(path: String) -> BattleLevelSketch:
	if _cache.has(path):
		return _cache[path]
	var sk: BattleLevelSketch = null
	if ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			sk = _build(ps, path)
	_cache[path] = sk
	return sk

static func clear_cache() -> void:
	_cache.clear()

# ---------------------------------------------------------------- queries

func bounds_min_x() -> float:
	return grid_x0 * float(TILE)

func bounds_max_x() -> float:
	return (grid_x0 + grid_w) * float(TILE)

func cell(tx: int, ty: int) -> int:
	var gx := tx - grid_x0
	var gy := ty - grid_y0
	if gx < 0 or gy < 0 or gx >= grid_w or gy >= grid_h:
		return 0
	return grid[gy * grid_w + gx]

func solid_at(px: float, py: float) -> bool:
	return cell(floori(px / TILE), floori(py / TILE)) == 1

## Top of the first walkable tile at or below `y_feet` under a body `half_w` either side of x,
## or PIT_Y. With half_w > 0 a body stays supported until it has fully cleared the ledge.
func support_y(x: float, y_feet: float, half_w := 0.0) -> float:
	var best := _support_column(floori((x - half_w + 0.01) / TILE), y_feet)
	if half_w > 0.0:
		best = minf(best, _support_column(floori((x + half_w - 0.01) / TILE), y_feet))
	return best

func _support_column(tx: int, y_feet: float) -> float:
	var row := ceili((y_feet - 1.0) / TILE)
	var last := grid_y0 + grid_h
	while row < last:
		if cell(tx, row) > 0:
			return row * float(TILE)
		row += 1
	return PIT_Y

## True if a Mario-sized box standing with its feet at (x, y_feet) overlaps solid terrain.
func box_hits(x: float, y_feet: float, h := BOX_H) -> bool:
	var x0 := floori((x - BOX_HALF_W + 0.05) / TILE) # a hair of tolerance: touching is not overlapping
	var x1 := floori((x + BOX_HALF_W - 0.05) / TILE)
	var y0 := floori((y_feet - h) / TILE)
	var y1 := floori((y_feet - 0.5) / TILE)
	for tx in range(x0, x1 + 1):
		for ty in range(y0, y1 + 1):
			if cell(tx, ty) == 1:
				return true
	return false

func ground_y_at(x: float) -> float:
	var i := floori(x / TILE) - grid_x0
	if i < 0 or i >= ground.size():
		return PIT_Y
	return ground[i]

func is_pit_at(x: float) -> bool:
	return ground_y_at(x) >= PIT_Y * 0.5

## Ballistic arc position `t` seconds after launch (screen y grows downward, vy0 < 0 is up).
static func arc_pos(x0: float, y0: float, vx: float, vy0: float, t: float) -> Vector2:
	return Vector2(x0 + vx * t, y0 + vy0 * t + 0.5 * GRAVITY * t * t)

## Solves a jump from (x0, y0) to (x1, y1) peaking `clearance` above the higher of the two
## feet heights. Returns {vx, vy0, T}, or {} if it would be unreasonably fast.
static func solve_arc(x0: float, y0: float, x1: float, y1: float, clearance: float, max_vx := 150.0) -> Dictionary:
	var apex := minf(y0, y1) - clearance
	var vy0 := -sqrt(2.0 * GRAVITY * (y0 - apex))
	var t_up := -vy0 / GRAVITY
	var t_down := sqrt(2.0 * (y1 - apex) / GRAVITY)
	var T := t_up + t_down
	var vx := (x1 - x0) / T
	if absf(vx) > max_vx:
		return {}
	return {"vx": vx, "vy0": vy0, "T": T}

## Samples an arc against solid terrain (big-Mario sized box).
func arc_clear(x0: float, y0: float, arc: Dictionary) -> bool:
	var T: float = arc.T
	var steps := maxi(int(T * 90.0), 4)
	for i in range(steps):
		var t := T * float(i) / float(steps)
		var p := arc_pos(x0, y0, arc.vx, arc.vy0, t)
		if box_hits(p.x, p.y):
			return false
	return true

# ---------------------------------------------------------------- building

static func _tile_set() -> TileSet:
	if _tileset == null:
		var st := (load(TILES_SCENE) as PackedScene).get_state()
		for i in st.get_node_count():
			for j in st.get_node_property_count(i):
				if st.get_node_property_name(i, j) == &"tile_set":
					_tileset = st.get_node_property_value(i, j)
					return _tileset
	return _tileset

static func _prop(st: SceneState, i: int, name: StringName, default: Variant) -> Variant:
	for j in st.get_node_property_count(i):
		if st.get_node_property_name(i, j) == name:
			return st.get_node_property_value(i, j)
	return default

## Decodes TileMapLayer.tile_map_data (format 0, 12 bytes per cell) to stride-6 ints:
## x, y, source, atlas_x, atlas_y, alternative.
static func decode_cells(data: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	if data.size() < 2 or data.decode_u16(0) != 0:
		return out
	var k := 2
	while k + 12 <= data.size():
		out.append(data.decode_s16(k))
		out.append(data.decode_s16(k + 2))
		out.append(data.decode_u16(k + 4))
		out.append(data.decode_u16(k + 6))
		out.append(data.decode_u16(k + 8))
		out.append(data.decode_u16(k + 10))
		k += 12
	return out

## 0 not solid, 1 solid, 2 one-way, from the real TileSet's physics polygons.
static func _atlas_solidity(src: TileSetAtlasSource, ax: int, ay: int) -> int:
	var key := Vector3i(src.get_instance_id() & 0xFFFF, ax, ay)
	if _solidity_cache.has(key):
		return _solidity_cache[key]
	var result := 0
	var coords := Vector2i(ax, ay)
	if src.has_tile(coords):
		var td := src.get_tile_data(coords, 0)
		if td != null and td.get_collision_polygons_count(0) > 0:
			result = 2 if td.is_collision_polygon_one_way(0, 0) else 1
	_solidity_cache[key] = result
	return result

static func _block_kind(scene: PackedScene) -> String:
	if scene == null:
		return ""
	var f := scene.resource_path.get_file()
	if f.begins_with("Invisible"):
		return ""
	if f.contains("BrickBlock"):
		return "brick"
	if f.contains("QuestionBlock"):
		return "question"
	return ""

static func _build(ps: PackedScene, path: String) -> BattleLevelSketch:
	var sk := BattleLevelSketch.new()
	sk.scene_path = path
	var st := ps.get_state()
	var n := st.get_node_count()
	if n == 0:
		return null
	sk.theme = _prop(st, 0, &"theme", "Overworld")
	sk.theme_time = _prop(st, 0, &"theme_time", "Day")
	sk.campaign = _prop(st, 0, &"campaign", "SMB1")
	sk.vertical_top = float(_prop(st, 0, &"vertical_height", -208))
	var tile_set := _tile_set()
	var terrain_src: TileSetAtlasSource = tile_set.get_source(0) if tile_set != null else null
	var scenes_src: TileSetScenesCollectionSource = tile_set.get_source(1) if tile_set != null else null

	# world positions: node path -> index, accumulate Node2D positions of ancestors
	var by_path := {}
	for i in n:
		by_path[str(st.get_node_path(i))] = i
	var world_pos := func(i: int) -> Vector2:
		var p: Vector2 = _prop(st, i, &"position", Vector2.ZERO)
		var pp := str(st.get_node_path(i)).get_base_dir()
		var guard := 0
		while by_path.has(pp) and pp != "." and guard < 16:
			var pi: int = by_path[pp]
			p += _prop(st, pi, &"position", Vector2.ZERO)
			pp = pp.get_base_dir()
			guard += 1
		return p

	var solid_cells: Array[Vector3i] = [] # tx, ty, solidity
	var terrain := PackedInt32Array()
	var deco := PackedInt32Array()
	var min_t := Vector2i(1 << 30, 1 << 30)
	var max_t := Vector2i(-(1 << 30), -(1 << 30))
	var scene_blocks: Array[Dictionary] = []
	var castle_pos := Vector2.ZERO
	var has_small_castle := false

	for i in n:
		var inst := st.get_node_instance(i)
		var ipath := inst.resource_path if inst != null else ""
		var npath := str(st.get_node_path(i))
		if npath.contains("ChallengeModeNodes"):
			continue
		var file := ipath.get_file()
		if file == "Tiles.tscn":
			var cells := decode_cells(_prop(st, i, &"tile_map_data", PackedByteArray()))
			for k in range(0, cells.size(), 6):
				var tx := cells[k]
				var ty := cells[k + 1]
				var source := cells[k + 2]
				min_t = Vector2i(mini(min_t.x, tx), mini(min_t.y, ty))
				max_t = Vector2i(maxi(max_t.x, tx), maxi(max_t.y, ty))
				if source == 0:
					terrain.append_array([tx, ty, cells[k + 3], cells[k + 4]])
					var s := _atlas_solidity(terrain_src, cells[k + 3], cells[k + 4]) if terrain_src != null else 1
					if s > 0:
						solid_cells.append(Vector3i(tx, ty, s))
				elif source == 1 and scenes_src != null and scenes_src.has_scene_tile_id(cells[k + 5]):
					var kind := _block_kind(scenes_src.get_scene_tile_scene(cells[k + 5]))
					if kind != "":
						scene_blocks.append({"tx": tx, "ty": ty, "kind": kind})
		elif file == "DecoTiles.tscn":
			var cells := decode_cells(_prop(st, i, &"tile_map_data", PackedByteArray()))
			for k in range(0, cells.size(), 6):
				if cells[k + 2] == 0:
					deco.append_array([cells[k], cells[k + 1], cells[k + 3], cells[k + 4]])
		elif npath.begins_with("./Blocks/"):
			var kind := _block_kind(inst)
			if kind != "":
				var p: Vector2 = world_pos.call(i)
				scene_blocks.append({"tx": floori(p.x / TILE), "ty": floori(p.y / TILE), "kind": kind})
		elif ENEMY_KINDS.has(file) and npath.begins_with("./Enemies/"):
			var p: Vector2 = world_pos.call(i)
			sk.spawns.append({"id": 0, "kind": ENEMY_KINDS[file], "x": p.x, "y": p.y})
		elif file == "EndFlagpole.tscn":
			sk.goal_x = (world_pos.call(i) as Vector2).x
			sk.goal_kind = "flagpole"
		elif file == "EndSmallCastle.tscn":
			castle_pos = world_pos.call(i)
			sk.castle_x = castle_pos.x
			has_small_castle = true
		elif file == "Player.tscn":
			var p: Vector2 = world_pos.call(i)
			sk.start_x = p.x
			sk.start_y = p.y
		elif ipath != "" and npath.begins_with("./Enemies/"):
			sk.dropped_entities += 1
	if terrain.is_empty() or sk.goal_kind == "":
		return null # not a level the previews can show

	sk.terrain_cells = terrain
	sk.deco_cells = deco
	for b in scene_blocks:
		sk.blocks.append(b)
		solid_cells.append(Vector3i(b.tx, b.ty, 1))
		min_t = Vector2i(mini(min_t.x, b.tx), mini(min_t.y, b.ty))
		max_t = Vector2i(maxi(max_t.x, b.tx), maxi(max_t.y, b.ty))
	sk.spawns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.x < b.x)
	for i in sk.spawns.size():
		sk.spawns[i].id = i
	if has_small_castle:
		sk._add_castle(castle_pos)
		for k in range(0, sk.castle_cells.size(), 4):
			max_t = Vector2i(maxi(max_t.x, floori(sk.castle_cells[k] / float(TILE))), max_t.y)

	sk.level_min_x = min_t.x * float(TILE)
	sk.level_max_x = (max_t.x + 1) * float(TILE)
	# solidity grid covering the camera band and the whole level
	var top_row := mini(floori(sk.vertical_top / TILE) - 2, min_t.y)
	sk.grid_x0 = min_t.x - 2
	sk.grid_y0 = top_row
	sk.grid_w = max_t.x - min_t.x + 5
	sk.grid_h = maxi(max_t.y, 4) - top_row + 3
	sk.grid.resize(sk.grid_w * sk.grid_h)
	for c in solid_cells:
		var gx := c.x - sk.grid_x0
		var gy := c.y - sk.grid_y0
		if gx >= 0 and gy >= 0 and gx < sk.grid_w and gy < sk.grid_h:
			sk.grid[gy * sk.grid_w + gx] = maxi(sk.grid[gy * sk.grid_w + gx], c.z)
	sk._build_route()
	return sk

func _add_castle(castle_pos: Vector2) -> void:
	# The castle is a little tile picture (SmallCastleVisual) placed by EndSmallCastle.tscn.
	var cs := (load(CASTLE_SCENE) as PackedScene).get_state()
	var origin := castle_pos
	for i in cs.get_node_count():
		if cs.get_node_name(i) == &"SmallCastleVisual":
			origin += _prop(cs, i, &"position", Vector2.ZERO)
	var vs := (load(SMALL_CASTLE_VISUAL) as PackedScene).get_state()
	for i in vs.get_node_count():
		var npath := str(vs.get_node_path(i))
		if npath != "./Tiles" and npath != "./Tiles/BG":
			continue
		# BG is a child of Tiles with no offset of its own, so both sit at the Tiles position.
		var layer_pos: Vector2 = origin + _prop(vs, _index_of(vs, "./Tiles"), &"position", Vector2.ZERO)
		var cells := decode_cells(_prop(vs, i, &"tile_map_data", PackedByteArray()))
		for k in range(0, cells.size(), 6):
			var entry := [roundi(layer_pos.x + cells[k] * TILE), roundi(layer_pos.y + cells[k + 1] * TILE), cells[k + 3], cells[k + 4]]
			if npath == "./Tiles":
				castle_cells.append_array(entry)
			else:
				castle_bg_cells.append_array(entry)

static func _index_of(st: SceneState, path: String) -> int:
	for i in st.get_node_count():
		if str(st.get_node_path(i)) == path:
			return i
	return 0

func _build_route() -> void:
	var x_tile0 := grid_x0
	ground.resize(grid_w)
	ground.fill(PIT_Y)
	var start_col := floori(start_x / TILE)
	var last_col := floori(castle_x / TILE) + 4
	var cur_y := start_y
	var primed := false
	for col in range(x_tile0, mini(last_col, grid_x0 + grid_w - 1) + 1):
		# candidate standing surfaces in this column (top of a solid cell with 2 free rows above)
		var best := PIT_Y
		var best_d := 1.0e9
		for row in range(grid_y0, grid_y0 + grid_h):
			if cell(col, row) > 0 and cell(col, row - 1) == 0 and cell(col, row - 2) == 0:
				var y := row * float(TILE)
				if primed and cur_y - y > MAX_RISE:
					continue
				var d := absf(y - cur_y)
				if d < best_d:
					best_d = d
					best = y
		if col < start_col - 1:
			continue # nothing to plan left of the start
		ground[col - x_tile0] = best
		if best < PIT_Y * 0.5:
			cur_y = best
			primed = true
	# pits: runs of PIT_Y between the start and the goal
	var run_start := -1
	var goal_col := floori(goal_x / TILE)
	for col in range(start_col, goal_col + 1):
		var is_pit := ground[col - x_tile0] >= PIT_Y * 0.5
		if is_pit and run_start < 0:
			run_start = col
		elif not is_pit and run_start >= 0:
			pits.append(Vector2(run_start * float(TILE), col * float(TILE)))
			run_start = -1
	_plan_jumps(start_col, goal_col)

func _g(col: int) -> float:
	var i := col - grid_x0
	if i < 0 or i >= ground.size():
		return PIT_Y
	return ground[i]

func _plan_jumps(start_col: int, goal_col: int) -> void:
	jumps.clear()
	var prev_land := -1.0e9
	var col := start_col
	# The last stretch is the pole leap's job (see below), not ordinary hops.
	var plan_end := goal_col - 3 if goal_kind == "flagpole" else goal_col + 1
	while col < plan_end:
		var g0 := _g(col)
		var g1 := _g(col + 1)
		if g0 >= PIT_Y * 0.5:
			col += 1
			continue
		if g1 >= PIT_Y * 0.5:
			# a gap: find where ground resumes
			var e := col + 1
			while e <= goal_col + 8 and _g(e) >= PIT_Y * 0.5:
				e += 1
			var j := _plan_one((col + 1) * float(TILE), e * float(TILE) + 8.0, g0, _g(e), prev_land, "gap")
			if not j.is_empty():
				j.pit = Vector2((col + 1) * float(TILE), e * float(TILE))
				jumps.append(j)
				prev_land = j.x_land
			col = e - 1
		elif g1 < g0 - 0.5:
			var j := _plan_one((col + 1) * float(TILE), (col + 1) * float(TILE) + 8.0, g0, g1, prev_land, "up")
			if not j.is_empty():
				jumps.append(j)
				prev_land = j.x_land
		col += 1
	# the final leap onto the flagpole
	if goal_kind == "flagpole":
		var gy := ground_y_at(goal_x - 40.0)
		if gy < PIT_Y * 0.5:
			for lead in [44.0, 36.0, 52.0, 30.0]:
				var x0: float = goal_x - lead
				if prev_land > x0 or ground_y_at(x0) != gy:
					continue
				var arc := solve_arc(x0, gy, goal_x - 7.0, gy - 92.0, 106.0)
				if not arc.is_empty() and arc_clear(x0, gy, arc):
					jumps.append({"x_start": x0, "y_start": gy, "x_land": goal_x - 7.0, "y_land": gy - 92.0,
						"vx": arc.vx, "vy0": arc.vy0, "T": arc.T, "kind": "pole"})
					break
	jumps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.x_start < b.x_start)

## Finds the smallest run-up / clearance whose arc is free of terrain.
func _plan_one(edge_x: float, x_land: float, y0: float, y1: float, prev_land: float, kind: String) -> Dictionary:
	if y1 >= PIT_Y * 0.5 or y0 - y1 > MAX_RISE:
		return {}
	var leads: Array = [8.0, 12.0, 16.0, 20.0, 26.0, 32.0, 40.0, 52.0]
	var clears: Array = [10.0, 16.0, 24.0, 32.0, 44.0]
	for lead in leads:
		var x0: float = edge_x - lead
		# a hop that follows another landing starts exactly where that landing was
		if x0 < prev_land + 0.5:
			x0 = prev_land
			if edge_x - x0 > 16.0:
				continue
		if ground_y_at(x0) != y0:
			continue
		for clearance in clears:
			var arc := solve_arc(x0, y0, x_land, y1, clearance)
			if arc.is_empty():
				continue
			if arc_clear(x0, y0, arc):
				return {"x_start": x0, "y_start": y0, "x_land": x_land, "y_land": y1,
					"vx": arc.vx, "vy0": arc.vy0, "T": arc.T, "kind": kind}
	return {}
