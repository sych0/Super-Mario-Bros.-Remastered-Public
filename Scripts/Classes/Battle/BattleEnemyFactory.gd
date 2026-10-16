class_name BattleEnemyFactory
extends RefCounted
## Turns a BattleEnemyType.Kind into the game's own enemy: the real prefab (`BattleEnemyType.prefab`),
## instantiated unchanged. There are no Battle-specific enemies: physics, AI, animation, collisions and
## every way to die are the game's. The factory only adds what the game's own runtime spawners add to
## what they spawn (BlockClass.dispense_item, PipeGenerator):
##   block_item  the LevelPersistance component frees itself, so a level that recorded a defeat at the
##               same position cannot delete this enemy on arrival, and nothing restores it later
##   no_persist  its own defeat is never recorded as a level persistence entry
## Battle identity (BattleAttribution.tag_incoming) and placement are the spawner's business.
##
## PackedScenes are loaded once and cached (`warm`): a first load() costs about 3 ms, which must not land
## on the frame an enemy appears. The cache holds resources only and is dropped with the other Battle
## caches when the Battle screen goes (`clear_cache`).

static var _scenes := {} ## Kind -> PackedScene

## Loads every supported kind's prefab now (the spawner calls this when its level starts).
static func warm() -> void:
	for kind in BattleEnemyType.kinds():
		scene(kind)

static func scene(kind: int) -> PackedScene:
	if not _scenes.has(kind):
		var path := BattleEnemyType.prefab(kind)
		_scenes[kind] = load(path) as PackedScene if path != "" else null
	return _scenes[kind]

static func is_warm(kind: int) -> bool:
	return _scenes.has(kind) and _scenes[kind] != null

static func clear_cache() -> void:
	_scenes.clear()

## A new, unparented instance of `kind`'s prefab facing `direction` (-1 left, +1 right), or null for
## an unsupported kind. The caller tags it and then puts it in the level with `add`.
static func create(kind: int, direction: int) -> Node2D:
	var packed := scene(kind)
	if packed == null:
		return null
	var node := packed.instantiate() as Node2D
	node.set_meta("block_item", true)
	node.set_meta("no_persist", true)
	node.set("direction", direction)
	return node

## Adds `node` to `level`'s enemies with its feet at `global_pos` (set before it enters the tree, so its
## `_ready` already sees where it stands), and settles physics interpolation there.
static func add(node: Node2D, level: Node, global_pos: Vector2) -> void:
	var parent := parent_in(level)
	node.position = (parent as Node2D).to_local(global_pos) if parent is Node2D else global_pos
	parent.add_child(node)
	node.reset_physics_interpolation()

## Where a level keeps its enemies: its `Enemies` node, or the level itself.
static func parent_in(level: Node) -> Node:
	var enemies := level.get_node_or_null("Enemies")
	return enemies if enemies != null else level
