class_name BattleBotCourseMap
extends RefCounted
## What an opponent knows of a level's fixed shape (doc 56): which 16 px cells are solid ground, walls, pipes or blocks, read
## once from the real level's own TileMapLayers and blocks after it is built. Immutable and shared by every bot world on
## that level scene. It is the brain's perception only: Mario still collides with the real tiles through the real physics.
## Blocks count as solid for the whole level (a brick another bot - or this one - breaks is not taken out); question
## blocks are also listed, for the bots that like to hit them.

const TILE := 16
const TERRAIN_BIT := 2

static var _cache := {} ## scene path -> BattleBotCourseMap

var origin := Vector2i.ZERO ## the first cell of the grid
var size := Vector2i.ZERO
var solid := PackedByteArray()
var question_blocks: Array[Vector2i] = [] ## cells of blocks that still hold something when the level starts
var side_pipes: Array[Rect2] = [] ## mouths of pipes entered sideways (walk in, do not jump over)
var floor_row := 0 ## the lowest solid row: anything below it is a pit

## The map of the level now in `level` (its scene `path`), built on first use. Needs the level's scene tiles to exist
## (one frame after it entered the tree).
static func of_level(level: Node, path: String) -> BattleBotCourseMap:
	if _cache.has(path):
		return _cache[path]
	var m := BattleBotCourseMap.new()
	m._build(level)
	_cache[path] = m
	return m

static func clear_cache() -> void:
	_cache.clear()

func _build(level: Node) -> void:
	var cells := {}
	for tm in level.find_children("*", "TileMapLayer", true, false):
		var layer := tm as TileMapLayer
		if not layer.collision_enabled or layer.tile_set == null or layer.tile_set.get_physics_layers_count() == 0:
			continue
		if layer.tile_set.get_physics_layer_collision_layer(0) & TERRAIN_BIT == 0:
			continue
		for c in layer.get_used_cells():
			var data := layer.get_cell_tile_data(c)
			if data != null and data.get_collision_polygons_count(0) > 0:
				cells[_cell_at(layer.to_global(layer.map_to_local(c)))] = true
	for n in level.find_children("*", "", true, false):
		if n is Block:
			var cell := _cell_at((n as Node2D).global_position)
			cells[cell] = true
			if (n as Block).item != null and (n as Block).visible:
				question_blocks.append(cell)
		elif n is PipeArea and (n as PipeArea).enter_direction >= 2 and not (n as PipeArea).exit_only:
			var pa := n as PipeArea
			side_pipes.append(Rect2(pa.global_position - Vector2(16, 24), Vector2(32, 32)))
	if cells.is_empty():
		return
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for c in cells:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	origin = lo
	size = hi - lo + Vector2i.ONE
	solid.resize(size.x * size.y)
	for c in cells:
		solid[(c.y - origin.y) * size.x + (c.x - origin.x)] = 1
	floor_row = hi.y
	question_blocks.sort_custom(func(a, b): return a.x < b.x)

static func _cell_at(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / TILE), floori(p.y / TILE))

func is_solid(c: Vector2i) -> bool:
	var x := c.x - origin.x
	var y := c.y - origin.y
	if x < 0 or x >= size.x or y < 0 or y >= size.y:
		return false
	return solid[y * size.x + x] == 1

func solid_at(p: Vector2) -> bool:
	return is_solid(_cell_at(p))

## Whether column `cx` has ground anywhere from row `from_row` down to the bottom of the level.
func ground_in_column(cx: int, from_row: int) -> bool:
	for r in range(from_row, floor_row + 1):
		if is_solid(Vector2i(cx, r)):
			return true
	return false

## How many cells are stacked solid in column `cx` going up from row `row` (0 if that cell is free).
func height_at(cx: int, row: int) -> int:
	var h := 0
	while is_solid(Vector2i(cx, row - h)) and h < 16:
		h += 1
	return h
