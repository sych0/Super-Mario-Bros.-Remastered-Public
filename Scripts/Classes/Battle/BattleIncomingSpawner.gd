class_name BattleIncomingSpawner
extends Node
## The bridge between the session's attacks on the real player and real enemies in the real level
## (doc 45, doc 46). One per level, a child of that level's BattleHandler, bound to the same session;
## it leaves with the level, and with it everything it knows.
##
## The session decides what attacks exist, their order and when they are ACTIVE. This node only makes
## the world match: every physics frame it
##   1. re-reads the session's rows for the real player (copies; the session is the truth),
##   2. forgets the enemies whose attack has ended (residue: a squashing Goomba, a woken Koopa), and
##      reports the real fate of the others that left play without being killed (DESPAWNED: fell into
##      a pit, left behind by the camera, ran off ahead, vanished),
##   3. spawns the next due attack (BattleIncomingPlan: strict order, grace, gap) at a safe spot
##      (BattleSpawnPlacer, on live physics probes) as the game's own enemy (BattleEnemyFactory), tagged
##      with its identity (BattleAttribution.tag_incoming), and reports it spawned
##      (BattleSession.report_player_incoming_spawned; refused means the node is removed at once, so
##      one attack is never two enemies). If no safe spot exists the attack is held, never dropped.
## Kills are not seen here at all: the enemy's own death path reports them (Enemy.report_battle_defeat),
## and the session resolves the attack from the kill. A level transition ends the spawned ones
## (BattleHandler._exit_tree), and the session ends everything when the player is out or the round ends.
## It never creates, targets, orders or times out an attack.

const DELIVERABLE_STATES := ["Normal", "WallSlide", "Climb"]
const TERRAIN_MASK := 2 ## tiles, blocks and pipes: what enemies stand on
const BODY_MASK := 16 | 32 ## enemy and shell bodies
const PIT_MARGIN := 8.0 ## feet this far below the view: it fell out of play
## Its whole body (16 px wide) outside the view's side: off screen. Not more: under a real renderer the
## game's own on-screen enabler freezes a Goomba as soon as its 20 px notifier rect leaves the view
## (about 10 px past the edge), so a larger margin would never be reached by a frozen enemy.
const EDGE_MARGIN := 8.0
const LEFT_BEHIND_SECONDS := 0.5 ## behind the camera that long: left behind (it never scrolls back)
const LEFT_BEHIND_SECONDS_BACKSCROLL := 6.0 ## ...unless the back-scroll setting lets the player return
const AHEAD_SECONDS := 6.0 ## ran off ahead that long: gone (a slot cannot be held forever)

## A switch for view-only tests that want the attack loop without enemies (like BattleScreen.live_previews).
static var enabled := true
## TESTS ONLY: headless runs never render, so no VisibleOnScreenEnabler2D ever switches an enemy on;
## with this set, a spawned enemy is switched on by hand as it enters the level.
static var force_process := false

var session: BattleSession = null
var plan := BattleIncomingPlan.new()
var live := {} ## seq -> the real enemy node of that attack, in this level
var spawn_log: Array[Dictionary] = [] ## {seq, kind, sender, frame, clock, position, direction, side, relaxed}
var resolve_log: Array[Dictionary] = [] ## {seq, cause, why, frame} for what this node reported
var fail_log: Array[Dictionary] = [] ## {seq, reason, clock}: placements that found no spot (the attack was held)
var last_spawn_us := 0 ## cost of the latest spawn (create + tag + add + report), for measurements
var tick_us := 0 ## cost of the latest physics frame of this node (reconcile + watch + deliver), for measurements
var max_live := 0
var _off_left := {} ## seq -> seconds spent behind the view
var _off_right := {} ## seq -> seconds spent ahead of the view
var _handler: Node = null
var _shape := RectangleShape2D.new()

## Adds a spawner to `handler` (a BattleHandler in a Battle level) for `session_`.
static func attach(handler: Node, session_: BattleSession) -> BattleIncomingSpawner:
	var spawner := BattleIncomingSpawner.new()
	spawner.name = "BattleIncomingSpawner"
	spawner.session = session_
	handler.add_child(spawner)
	return spawner

func _ready() -> void:
	_handler = get_parent()
	BattleEnemyFactory.warm() # the first load() costs ~3 ms: never on a spawn frame

func _exit_tree() -> void:
	live.clear() # the nodes go with the level; the handler ends their attacks
	_off_left.clear()
	_off_right.clear()

func level() -> Node:
	return _handler.get_parent() if _handler != null else null

func player() -> Node2D:
	return get_tree().get_first_node_in_group("Players") as Node2D

## Whether the real player is in normal play, so an enemy may appear.
func deliverable() -> bool:
	if session == null or session.finished or session.attacks.round_ended or not session.get_player().alive:
		return false
	if _handler == null or _handler.get("level_completed"):
		return false
	var p := player()
	if p == null or p.get("is_dead") or p.get("in_cutscene"):
		return false
	var machine: Node = p.get("state_machine")
	return machine != null and machine.get("state") != null and DELIVERABLE_STATES.has(String(machine.state.name))

## The visible game area in world coordinates (the GameViewport camera), or an empty rect.
func view_rect() -> Rect2:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return Rect2()
	var size := get_viewport().get_visible_rect().size / cam.zoom
	return Rect2(cam.get_screen_center_position() - size / 2.0, size)

func _physics_process(delta: float) -> void:
	if session == null or session != BattleSession.current or level() == null:
		return
	var t0 := Time.get_ticks_usec()
	plan.advance(delta, deliverable())
	var rows := session.get_incoming(BattleSession.PLAYER_ID)
	var active := {}
	for r in rows:
		if int(r.state) == BattleAttack.State.ACTIVE:
			active[int(r.seq)] = r
	var view := view_rect()
	_watch(active, view, delta)
	plan.sync(rows)
	if view.has_area():
		_deliver(active, view)
	max_live = maxi(max_live, live.size())
	if live.size() > BattleAttackSystem.MAX_ACTIVE:
		push_error("BattleIncomingSpawner: %d live incoming enemies (cap %d)" % [live.size(), BattleAttackSystem.MAX_ACTIVE])
	tick_us = Time.get_ticks_usec() - t0

# ---- what happened to the live ones -----------------------------------------------------------------

func _watch(active: Dictionary, view: Rect2, delta: float) -> void:
	for seq in live.keys():
		if not active.has(seq):
			_forget(seq) # its attack ended (killed, or the session ended it): what is left is residue
			continue
		var node: Node2D = live[seq] if is_instance_valid(live[seq]) else null
		if node == null or not node.is_inside_tree() or node.is_queued_for_deletion():
			# Every kill path reports before the enemy goes, so gone while ACTIVE is never a kill. At the
			# flag the game clears the screen itself: that ends with the level (LEVEL_TRANSITION) instead.
			if not _handler.get("level_completed"):
				_despawn(seq, null, "vanished")
			else:
				_forget(seq)
			continue
		if not view.has_area():
			continue
		var pos := node.global_position
		if pos.y > view.end.y + PIT_MARGIN:
			_despawn(seq, node, "pit")
		elif pos.x < view.position.x - EDGE_MARGIN:
			_off_right.erase(seq)
			_off_left[seq] = float(_off_left.get(seq, 0.0)) + delta
			if _off_left[seq] >= _left_limit() - 1e-6:
				_despawn(seq, node, "left behind")
		elif pos.x > view.end.x + EDGE_MARGIN:
			_off_left.erase(seq)
			_off_right[seq] = float(_off_right.get(seq, 0.0)) + delta
			if _off_right[seq] >= AHEAD_SECONDS - 1e-6:
				_despawn(seq, node, "ran off ahead")
		else:
			_off_left.erase(seq)
			_off_right.erase(seq)

func _left_limit() -> float:
	var lvl := level()
	return LEFT_BEHIND_SECONDS_BACKSCROLL if lvl != null and lvl.get("can_backscroll") == true else LEFT_BEHIND_SECONDS

func _despawn(seq: int, node: Node, why: String) -> void:
	if session.resolve_player_incoming(seq, BattleAttack.Resolution.DESPAWNED):
		resolve_log.append({"seq": seq, "cause": BattleAttack.Resolution.DESPAWNED, "why": why, "frame": Engine.get_physics_frames()})
	if node != null and is_instance_valid(node) and not node.is_queued_for_deletion():
		node.queue_free()
	_forget(seq)

func _forget(seq: int) -> void:
	live.erase(seq)
	_off_left.erase(seq)
	_off_right.erase(seq)

# ---- delivery ---------------------------------------------------------------------------------------

func _deliver(active: Dictionary, view: Rect2) -> void:
	var seq := plan.next_due()
	if seq < 0 or not active.has(seq):
		return
	var row: Dictionary = active[seq]
	var p := player()
	var others: Array = []
	for s in live:
		if is_instance_valid(live[s]):
			others.append((live[s] as Node2D).global_position)
	var relaxed := plan.relaxed()
	var spot := BattleSpawnPlacer.place(view, p.global_position, _solid, _blocked, others, relaxed)
	if not spot.ok:
		plan.on_failed(seq)
		if fail_log.size() < 256:
			fail_log.append({"seq": seq, "reason": spot.reason, "clock": plan.clock})
		return
	var t0 := Time.get_ticks_usec()
	var kind := int(row.kind)
	var node := BattleEnemyFactory.create(kind, int(spot.direction))
	if node == null:
		plan.on_failed(seq)
		return
	BattleAttribution.tag_incoming(node, session.uid, seq, int(row.sender), kind)
	BattleEnemyFactory.add(node, level(), spot.position)
	if not session.report_player_incoming_spawned(seq):
		node.get_parent().remove_child(node) # the session already has an enemy for this attack: never two
		node.free()
		plan.on_spawned(seq) # and never try this seq again here
		return
	if force_process:
		node.process_mode = Node.PROCESS_MODE_INHERIT
	live[seq] = node
	plan.on_spawned(seq)
	last_spawn_us = Time.get_ticks_usec() - t0
	spawn_log.append({"seq": seq, "kind": kind, "sender": int(row.sender), "frame": Engine.get_physics_frames(), "clock": plan.clock,
		"position": spot.position, "direction": int(spot.direction), "side": spot.side, "relaxed": relaxed})

# ---- live physics probes for the placer ----------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState2D:
	return get_viewport().find_world_2d().direct_space_state # the GameViewport's world: the level's physics

func _solid(cell: Vector2i) -> bool:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = Vector2(cell.x * BattleSpawnPlacer.TILE + BattleSpawnPlacer.HALF_TILE, cell.y * BattleSpawnPlacer.TILE + BattleSpawnPlacer.HALF_TILE)
	q.collision_mask = TERRAIN_MASK
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not _space().intersect_point(q, 1).is_empty()

func _blocked(rect: Rect2) -> bool:
	_shape.size = rect.size
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = _shape
	q.transform = Transform2D(0.0, rect.get_center())
	q.collision_mask = BODY_MASK
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not _space().intersect_shape(q, 1).is_empty()
