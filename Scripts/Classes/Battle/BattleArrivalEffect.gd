class_name BattleArrivalEffect
extends Node2D
## The brief mark that says "this enemy just arrived" when a Battle-sent enemy physically appears in the
## real player's level (doc 48, M6b): four thin corner brackets that open outward around the enemy and fade,
## in five steps over DURATION seconds, then the node frees itself. Nothing else. (It draws no shadow of its own:
## like every other sprite it gets the game's own drop shadow when the player has that setting on.)
##
## It is a SIBLING of the enemy, never a child, and never touches it: no tint, no modulate, no shader, no
## material, no scale, no child node, no signal, no physics body. So the enemy's physics, AI, collisions and
## every way to die are exactly the prefab's, the enemy looks completely normal once the brackets are gone
## (and it never looks different at any moment: the brackets are around it, not on it), and the game's own
## `Node.duplicate()` (a Koopa waking from its shell copies the Koopa) can never copy the effect.
##
## BattleIncomingSpawner owns it: creates exactly one per successful spawn report, moves it with the enemy
## (`follow`), advances it with its own physics delta (so it stops with the game: pause, freeze) and removes
## it when it ends or when the attack does. It is parented to the spawner, which is not a CanvasItem, so its
## position is a world position. It reads nothing from the session and decides nothing.

const DURATION := 0.5
const STEPS := 5
const MARGINS := [2, 3, 5, 7, 9] ## px between the sprite and the brackets, per step: they open outward (never touching it)
const ALPHAS := [1.0, 0.9, 0.7, 0.45, 0.2]
const ARM := 4 ## px, the length of each bracket arm
const COLOR := Color(1.0, 1.0, 1.0, 1.0)
const BODY_WIDTH := 16.0 ## the sprite's width; its columns are -8..7 around the origin

var seq := -1 ## the attack this marks (BattleAttack.seq); one effect per seq, ever
var kind := 0 ## BattleEnemyType.Kind: sets the height of the box
var elapsed := 0.0
var target: Node2D = null ## followed, never modified

func _init() -> void:
	name = "BattleArrivalEffect"
	z_index = 0 # above the level's enemies and tiles (tree order), below Mario (z 1)
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF # whole pixels, set every physics frame: never drawn between two of them

## A new effect for `enemy` (feet at its origin), already placed on it.
static func create(seq_: int, kind_: int, enemy: Node2D) -> BattleArrivalEffect:
	var e := BattleArrivalEffect.new()
	e.seq = seq_
	e.kind = kind_
	e.target = enemy
	e.follow()
	return e

## The sprite's height in px. Its bottom pixel row is the one the origin sits in (rows 1 - height .. 0), so the
## box around it runs from y = 1 - height to y = 1.
static func body_height(kind_: int) -> float:
	return 16.0 if kind_ == BattleEnemyType.Kind.GOOMBA else 24.0

func finished() -> bool:
	return elapsed >= DURATION

## Which of the STEPS is showing (0-based), or STEPS once it is over.
func step() -> int:
	return mini(int(elapsed / (DURATION / STEPS) + 1e-6), STEPS)

## 1..0, the brackets' opacity now (0 once over).
func strength() -> float:
	var s := step()
	return ALPHAS[s] if s < STEPS else 0.0

## Moves the effect onto its enemy (whole pixels, so the brackets stay crisp).
func follow() -> void:
	if target != null and is_instance_valid(target):
		global_position = target.global_position.round()

## Advances by `delta` seconds and follows the enemy. Returns true while the effect still shows.
func advance(delta: float) -> bool:
	elapsed += maxf(delta, 0.0)
	follow()
	queue_redraw()
	return not finished()

func _draw() -> void:
	var s := step()
	if s >= STEPS:
		return
	var m: int = MARGINS[s]
	var h := body_height(kind)
	var box := Rect2(-BODY_WIDTH / 2.0 - m, 1.0 - h - m, BODY_WIDTH + 2.0 * m, h + 2.0 * m)
	var c := COLOR
	c.a *= ALPHAS[s]
	_corner(box.position, 1, 1, c)
	_corner(Vector2(box.end.x, box.position.y), -1, 1, c)
	_corner(Vector2(box.position.x, box.end.y), 1, -1, c)
	_corner(box.end, -1, -1, c)

## One bracket at the box corner `p`, its arms running inward (`dx`, `dy` = +1 / -1 toward the box's middle).
func _corner(p: Vector2, dx: int, dy: int, color: Color) -> void:
	var arm := float(ARM)
	draw_rect(Rect2(Vector2(p.x if dx > 0 else p.x - arm, p.y if dy > 0 else p.y - 1.0), Vector2(arm, 1.0)), color)
	draw_rect(Rect2(Vector2(p.x if dx > 0 else p.x - 1.0, p.y if dy > 0 else p.y - arm), Vector2(1.0, arm)), color)
