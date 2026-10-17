class_name BattleBotController
extends RefCounted
## A Battle opponent's brain (doc 56): every physics tick it looks at its own real game (Mario's position and speed, the
## level's shape, the enemies that are awake) and decides which buttons to hold: right, left, run, jump. It never moves
## Mario, never touches an enemy, never skips anything: the buttons go through BattleBotPad into the real Player, and what
## happens is what the game does with them.
##
## How it plays: it heads for the flag, running or walking (its traits). When something is near - a step or wall, a gap, a
## drop, an enemy - it plans: it plays a few button plans forward in time (carry on; take off after its reaction time, or a
## little later; a short hop or a full jump) with `_sim`, a model of Mario's own movement (the Normal state's accelerations,
## Player.jump, the jump release, gravity, all read from the real Mario's parameters) against the level's cells and the
## enemies' current motion, scores them (how far, how safe, whether stuck against a wall, whether it stomps), and presses
## jump only when the best plan says "now". In the air it holds jump as planned, and presses it again just before landing
## when it is coming down by an enemy or onto the edge of a gap or step (the game buffers that press into a jump on
## landing). It reacts a few frames late and presses a frame or two off, by its traits; it may stop to hit a ? block or
## hesitate; when it makes no progress it tries a jump, then backs off and tries again. Everything random comes from its
## own stream (the round's seed and its id).

const TILE := 16.0
const LOOK_AHEAD := 7 ## columns scanned ahead for steps, walls and gaps
const FULL := 80 ## a jump held to its top
const HOP := 10 ## a short hop
const HORIZON := 64 ## frames a plan is played forward
const PLAN_EVERY := 3 ## frames between plans while something is near

var world: BattleBotWorld = null
var traits: BattleBotTraits = null
var rng := RandomNumberGenerator.new()
var map: BattleBotCourseMap = null
var player: Player = null
var level: Node = null
var scene_path := ""
var decisions := 0 ## jump decisions taken (tests and measurements)
var jumps := 0 ## take-offs pressed
var plans := 0 ## plans evaluated (measurements)
var plan_us := 0 ## time spent planning, total (measurements)
var last_reason := ""
var reasons := {} ## reason -> take-offs pressed for it (tests and measurements)

var _frames := 0
var _map_wait := 0
var _hold := 0 ## frames left of holding jump after a take-off
var _press_at := -1 ## frame at which the decided jump is pressed
var _press_hold := 0
var _press_reason := ""
var _running := true
var _pace_left := 0.0
var _idle_left := 0.0
var _best_x := -INF
var _no_progress := 0
var _tries := 0
var _backoff := 0
var _stomp_choice := {} ## enemy instance id -> wants to stomp it
var _block_choice := {} ## block cell -> wants to hit it
var _hesitated := {} ## gap column -> already hesitated there
var _wait := 0 ## frames of a hesitation still to wait (counted while standing)
var _air_press_ready := true ## jump was released for at least a frame in the air (a press now is a fresh one)
var _buffered := false ## jump was pressed in the air for the game to buffer: held on through the landing
var _p := {} ## Mario's parameters for this plan (read once per plan)
var _run_until := -1 ## a plan's run button is held as planned until this frame (the press, then the jump itself)
var _run_planned := false

func _init(world_: BattleBotWorld = null, traits_: BattleBotTraits = null) -> void:
	world = world_
	traits = traits_ if traits_ != null else BattleBotTraits.new()
	rng.seed = hash([world.seed_value if world != null else 0, world.contestant_id if world != null else 0, 0x3C6EF372])

## A new level (a new course, or another part of the same one).
func on_level(level_: Node, player_: Player, path: String) -> void:
	level = level_
	player = player_
	scene_path = path
	map = null
	_map_wait = 2 # the level's scene tiles (bricks, ? blocks) are built at the end of its first frame
	_hold = 0
	_press_at = -1
	_best_x = -INF
	_no_progress = 0
	_tries = 0
	_backoff = 0
	_wait = 0
	_buffered = false
	_stomp_choice.clear()
	_block_choice.clear()
	_hesitated.clear()

## The buttons for this tick (action -> held).
func update(delta: float) -> Dictionary:
	_frames += 1
	if not is_instance_valid(player) or not player.is_inside_tree():
		return {}
	if map == null:
		_map_wait -= 1
		if _map_wait > 0:
			return {}
		map = BattleBotCourseMap.of_level(level, scene_path)
	if player.state_machine.get_state() != "Normal":
		_hold = 0
		_press_at = -1
		return {} # pipes, the flagpole, the castle walk and death play out by themselves
	var p := player.global_position
	var v := player.velocity
	var on_floor := player.is_on_floor()
	var b := {"move_right": true, "run": _running}
	_pace(delta, on_floor)
	_track_progress(p, on_floor)
	if _backoff > 0:
		_backoff -= 1
		return {"move_left": true}
	if on_floor:
		if _buffered:
			_buffered = false # the game turns the buffered press into a jump now: keep holding it
			b["jump"] = true
		else:
			_hold = 0
		if _idle_left > 0.0 and _foes(p, false).is_empty():
			_idle_left -= delta
			b = {}
		elif _wait > 0:
			b = {} # hesitating: it lets go, and still watches the edge
			if absf(v.x) < 5.0:
				_wait -= 1
		_ground(p, v, b)
	else:
		_air(p, v, b)
	if _frames < _run_until and b.has("move_right"):
		b["run"] = _run_planned # the jump is executed as it was planned
	if _press_at >= 0 and _frames >= _press_at:
		_press_at = -1
		if on_floor:
			b["jump"] = true
			_hold = _press_hold
			jumps += 1
			last_reason = _press_reason
			var key := _press_reason.get_slice(" ", 0)
			reasons[key] = int(reasons.get(key, 0)) + 1
	return b

# ---- walking ------------------------------------------------------------------------------------------------------------

func _pace(delta: float, on_floor: bool) -> void:
	_pace_left -= delta
	if _pace_left <= 0.0:
		_running = rng.randf() < traits.run_share
		_pace_left = rng.randf_range(1.0, 4.0)
	if on_floor and _idle_left <= 0.0 and rng.randf() < traits.idle_rate * delta:
		_idle_left = rng.randf_range(0.25, 1.0)

func _track_progress(p: Vector2, on_floor: bool) -> void:
	if p.x > _best_x + 2.0:
		_best_x = p.x
		_no_progress = 0
		_tries = 0
		return
	if on_floor and _idle_left <= 0.0 and _wait <= 0 and _backoff <= 0:
		_no_progress += 1
	if _no_progress >= traits.patience:
		_no_progress = 0
		_tries += 1
		if _tries >= 3:
			_tries = 0
			_backoff = rng.randi_range(10, 24) # back off for a run-up, then try again
		else:
			_schedule(0, FULL, "stuck")

# ---- on the ground: plan ---------------------------------------------------------------------------------------------------

func _ground(p: Vector2, v: Vector2, b: Dictionary) -> void:
	if _press_at >= 0:
		return
	var row := floori((p.y - 1.0) / TILE) # the row Mario stands in
	var cx := floori(p.x / TILE)
	var below := _drop_ahead(cx, row)
	var foes := _foes(p, below)
	var near := _terrain_ahead(p, v, cx, row)
	# A ? block above the way, for the bots that like them: stop under it and hit it (never with a gap or an enemy close).
	if foes.is_empty() and not _gap_within(cx, row, 4) and _block(p, v, row, cx, b):
		return
	if foes.is_empty() and near == "":
		return # open ground
	if near == "gap" and traits.skill > 0.5:
		b["run"] = true # a good player takes a gap at speed
	if near == "gap" and _hesitate(p, v, cx, row):
		return
	if foes.is_empty() and _frames % PLAN_EVERY != 0:
		return
	_plan(p, v, b, foes, near)

## Tries the plans and acts on the best: jump now, wait (a later take-off is better), or, if nothing is safe, stop or back off.
func _plan(p: Vector2, v: Vector2, b: Dictionary, foes: Array, near: String) -> void:
	var t0 := Time.get_ticks_usec()
	_read_params()
	var run: bool = b.get("run", false)
	var dir := 1 if b.get("move_right", false) else 0
	var react := traits.reaction_frames
	var stomp := not foes.is_empty() and _wants_stomp(foes)
	var go := _sim(p, v, -1, 0, maxi(dir, 1), run, foes)
	var go_score := _score(go, p, stomp)
	var best_score := -INF
	var best_k := -1
	var best_hold := FULL
	for k in [react, react + 5, react + 10]:
		for hold in [HOP, FULL]:
			var out := _sim(p, v, k, hold, 1, run, foes)
			var sc := _score(out, p, stomp)
			if sc > best_score + 0.5 or (absf(sc - best_score) <= 0.5 and k > best_k):
				best_score = sc
				best_k = k
				best_hold = hold
	plans += 1
	plan_us += Time.get_ticks_usec() - t0
	if best_k == react and best_score > go_score + 2.0:
		var jitter := int(traits.precision_px / 3.0)
		var delay := maxi(react + rng.randi_range(-jitter, jitter), 0)
		_schedule(delay, best_hold, ("enemy " if not foes.is_empty() else "") + near)
		_run_planned = run
		_run_until = _frames + delay + 70
	elif go_score == -INF and best_score == -INF:
		# Nothing gets him through from here: stop if that is safe, else back off.
		if not foes.is_empty() and _sim(p, v, -1, 0, 0, false, foes).safe:
			b["move_right"] = false
			b["run"] = false
		elif not foes.is_empty():
			b["move_right"] = false
			b["move_left"] = true

func _score(out: Dictionary, p: Vector2, stomp: bool) -> float:
	if not out.safe:
		return -INF
	var s: float = out.x - p.x - out.blocked * 3.0
	if out.air and not out.ground:
		s -= 200.0 # still in the air over nothing at the end of the plan
	s += out.stomps * (24.0 if stomp else 4.0)
	return s

## What terrain is close ahead: "wall" (a step or wall), "gap", "drop", or "" (open ground, or a pipe to walk into).
func _terrain_ahead(p: Vector2, v: Vector2, cx: int, row: int) -> String:
	var columns := clampi(2 + int(absf(v.x) * 0.5 / TILE), 2, LOOK_AHEAD)
	for d in range(1, columns + 1):
		var c := cx + d
		if map.is_solid(Vector2i(c, row)) or map.is_solid(Vector2i(c, row - 1)):
			return "" if _side_pipe_at(Vector2(c * TILE, p.y)) else "wall"
		if not map.ground_in_column(c, row + 1):
			return "gap"
		if not map.is_solid(Vector2i(c, row + 1)):
			return "drop"
	return ""

## A bot that hesitates stops short of a gap for a moment, where it still can (braking distance), once per gap.
func _hesitate(p: Vector2, v: Vector2, cx: int, row: int) -> bool:
	for d in range(1, LOOK_AHEAD + 1):
		var c := cx + d
		if map.ground_in_column(c, row + 1):
			continue
		if _hesitated.has(c):
			return false
		var edge := c * TILE - (p.x + _half_width())
		var braking := _braking_distance(absf(v.x))
		if edge > braking + 4.0 and edge < braking + 40.0:
			_hesitated[c] = true
			if rng.randf() < traits.hesitation:
				_wait = rng.randi_range(8, 30)
				return true
		return false
	return false

func _schedule(delay: int, hold: int, reason: String) -> void:
	if _press_at >= 0:
		return
	_press_at = _frames + delay
	_press_hold = hold
	_press_reason = reason if reason != "" else "jump"
	decisions += 1

# ---- in the air -----------------------------------------------------------------------------------------------------------

func _air(p: Vector2, v: Vector2, b: Dictionary) -> void:
	var landing := _frames_to_land(p, v)
	var buffer := maxi(int(player.physics_params("JUMP_BUFFER")) - 1, 1)
	var threat := v.y > 0.0 and landing <= buffer and (_enemy_ahead(p, 40.0 + absf(v.x) * landing / 60.0 + 24.0, true) != null \
		or _landing_needs_jump(p, v, landing))
	if threat:
		# Coming down by an enemy, or onto the edge of a gap or the foot of a step: a fresh press now is held into the
		# bounce off the enemy, or buffered by the game into a jump the moment he lands (Normal.in_air's jump buffer).
		if _air_press_ready:
			b["jump"] = true
			_hold = FULL
			_buffered = true
		_air_press_ready = true
	elif _hold > 0:
		_hold -= 1
		b["jump"] = true
		_air_press_ready = false
	else:
		_air_press_ready = true

## Whether Mario, landing in `landing` frames, lands just before a gap or a step (he would have no time to take off).
func _landing_needs_jump(p: Vector2, v: Vector2, landing: int) -> bool:
	if v.x < 30.0:
		return false
	var lx := p.x + v.x * landing / 60.0
	var cx := floori(lx / TILE)
	var row := 0
	var found := false
	for r in range(floori(p.y / TILE), map.floor_row + 1):
		if map.is_solid(Vector2i(cx, r)):
			row = r - 1
			found = true
			break
	if not found:
		return false
	var reach := 1 + int(v.x * 0.12 / TILE) # what he covers in the time a take-off needs
	for d in range(1, reach + 2):
		if map.is_solid(Vector2i(cx + d, row)):
			return true # a step
		if not map.ground_in_column(cx + d, row + 1):
			return true # a gap
	return false

## Roughly how many frames until Mario, falling, reaches the ground under him (99 if none or rising).
func _frames_to_land(p: Vector2, v: Vector2) -> int:
	if v.y <= 0.0:
		return 99
	var cx := floori((p.x + v.x / 15.0) / TILE)
	for r in range(floori(p.y / TILE), map.floor_row + 1):
		if map.is_solid(Vector2i(cx, r)):
			return int((r * TILE - p.y) / maxf(v.y / 60.0, 1.0))
	return 99

# ---- blocks ----------------------------------------------------------------------------------------------------------------

## Stops under a ? block it wants and hits it: eases off, stops, jumps from standing.
func _block(p: Vector2, v: Vector2, row: int, cx: int, b: Dictionary) -> bool:
	for cell in map.question_blocks:
		if cell.x < cx - 1:
			continue
		if cell.x > cx + 3:
			break
		if row - cell.y < 3 or row - cell.y > 5:
			continue
		if not _block_choice.has(cell):
			_block_choice[cell] = rng.randf() < traits.block_interest
		if not _block_choice[cell]:
			continue
		var center := cell.x * TILE + TILE / 2.0
		if p.x > center + 6.0:
			_block_choice[cell] = false # went past it
			continue
		b["run"] = false
		if center - p.x <= 6.0:
			b["move_right"] = false # stop under it
			if absf(v.x) < 30.0:
				_block_choice[cell] = false # once
				_schedule(traits.reaction_frames, 12, "block")
			return true
		return false
	return false

# ---- what is around ----------------------------------------------------------------------------------------------------------

func _gap_within(cx: int, row: int, columns: int) -> bool:
	for d in range(0, columns + 1):
		if not map.ground_in_column(cx + d, row + 1):
			return true
	return false

## Whether the ground ahead drops below the row Mario stands on (he is on a ledge, a pipe, a step).
func _drop_ahead(cx: int, row: int) -> bool:
	for d in range(1, 4):
		if map.is_solid(Vector2i(cx + d, row)):
			return false
		if not map.is_solid(Vector2i(cx + d, row + 1)) and map.ground_in_column(cx + d, row + 1):
			return true
	return false

## How far Mario slides on the ground from `speed` once he lets go (the Normal state's deceleration).
func _braking_distance(speed: float) -> float:
	var decel: float = maxf(player.physics_params("GROUND_WALK_DECEL"), 0.5)
	return speed * speed / (2.0 * decel * 60.0)

func _side_pipe_at(at: Vector2) -> bool:
	for r in map.side_pipes:
		if r.grow(8.0).has_point(at):
			return true
	return false

func _half_width() -> float:
	var size = player.physics_params("COLLISION_SIZE")
	return (size.x if size is Vector2 else 8.0) / 2.0

func _height() -> float:
	var size = player.physics_params("COLLISION_SIZE")
	return size.y if size is Vector2 else 14.0

func _wants_stomp(foes: Array) -> bool:
	var id: int = foes[0][4]
	if not _stomp_choice.has(id):
		_stomp_choice[id] = rng.randf() < traits.stomp_bias
	return _stomp_choice[id]

## The awake enemy nearest ahead of Mario (within `range_` px, at about his height; with `below`, also on the ground
## under a ledge he is on), or null.
func _enemy_ahead(p: Vector2, range_: float, below := false) -> Node2D:
	var best: Node2D = null
	var best_d := range_
	for e in _foe_nodes():
		var n := e as Node2D
		var dx := n.global_position.x - p.x
		var dy := n.global_position.y - p.y
		if dx < -8.0 or dx > best_d or dy < -40.0 or dy > (112.0 if below else 40.0):
			continue
		best = n
		best_d = dx
	return best

## Awake enemies near Mario as [x, y (feet), vx, deadly, id], nearest first.
func _foes(p: Vector2, below: bool) -> Array:
	var out: Array = []
	for e in _foe_nodes():
		var n := e as Node2D
		var dx := n.global_position.x - p.x
		var dy := n.global_position.y - p.y
		if dx < -24.0 or dx > 160.0 or dy < -64.0 or dy > (112.0 if below else 48.0):
			continue
		var vx: float = (e as CharacterBody2D).velocity.x if e is CharacterBody2D else 0.0
		var deadly := not (e is Shell and absf(vx) < 1.0) # a resting shell is kicked, not deadly
		out.append([n.global_position.x, n.global_position.y, vx, deadly, e.get_instance_id()])
	out.sort_custom(func(a, c): return absf(a[0] - p.x) < absf(c[0] - p.x))
	return out

## The world's enemies that are awake and in play (piranhas in their pipes left out: the bot treats the pipe as a wall).
func _foe_nodes() -> Array:
	var out: Array = []
	var dead := 0
	for e in world.enemies:
		if not is_instance_valid(e) or not e.is_inside_tree() or e.is_queued_for_deletion():
			dead += 1
			continue
		if not e.can_process():
			continue
		var s: Script = e.get_script()
		if s != null and s.resource_path.ends_with("PiranhaPlant.gd"):
			continue
		out.append(e)
	if dead > 8:
		world.enemies = world.enemies.filter(func(e): return is_instance_valid(e) and e.is_inside_tree() and not e.is_queued_for_deletion())
	return out

# ---- Mario, forward ------------------------------------------------------------------------------------------------------

func _read_params() -> void:
	_p = {
		"walk": player.physics_params("WALK_SPEED"), "run": player.physics_params("RUN_SPEED"),
		"g_walk": player.physics_params("GROUND_WALK_ACCEL"), "g_run": player.physics_params("GROUND_RUN_ACCEL"),
		"a_walk": player.physics_params("AIR_WALK_ACCEL"), "a_run": player.physics_params("AIR_RUN_ACCEL"),
		"decel": player.physics_params("GROUND_WALK_DECEL"), "max_fall": player.physics_params("MAX_FALL_SPEED"),
		"cancel": player.physics_params("JUMP_CANCEL_DIVIDE"), "bounce": player.physics_params("BOUNCE_SPEED"),
		"bump": player.physics_params("CEILING_BUMP_SPEED"),
		"jump_vy": player.calculate_jump_height(player.calculate_speed_param("JUMP_SPEED")),
		"jump_g": player.calculate_speed_param("JUMP_GRAVITY"), "fall_g": player.calculate_speed_param("FALL_GRAVITY", player.velocity.x),
		"half": _half_width(), "h": _height(),
	}

var _grid := PackedByteArray()
var _gx := 0
var _gy := 0
var _gw := 0
var _gh := 0

## The course map's cell at world point (px, py), read straight from the grid (the plan loop's hot path).
func _solid(px: float, py: float) -> bool:
	var cx := floori(px / TILE) - _gx
	var cy := floori(py / TILE) - _gy
	return cx >= 0 and cx < _gw and cy >= 0 and cy < _gh and _grid[cy * _gw + cx] == 1

## Mario's next frames on a button plan: from `p`/`v` on the ground, holding `dir` (and run), pressing jump at frame
## `jump_at` (-1: never) for `hold` frames. The Normal state's rules (Player.jump, apply_gravity, the ground and air
## accelerations, the jump release), the level's cells, and `foes` moving straight on; touching a foe while falling is a
## stomp (the game's rule) and bounces him, any other touch of a deadly foe ends the plan unsafe, as does a fall into a
## pit. Returns {safe, x, stomps, blocked (frames pressed against a wall), air, ground (ground under him at the end)}.
func _sim(p: Vector2, v: Vector2, jump_at: int, hold: int, dir: int, run: bool, foes: Array) -> Dictionary:
	_grid = map.solid
	_gx = map.origin.x
	_gy = map.origin.y
	_gw = map.size.x
	_gh = map.size.y
	var dt := 1.0 / 60.0
	var x := p.x
	var y := p.y
	var vx := v.x
	var vy := 0.0
	var air := false
	var g := 0.0
	var jumped_at := -1
	var cancelled := false
	var walk: float = _p.walk
	var top: float = _p.run if run else _p.walk
	var g_accel: float = _p.g_run if run else _p.g_walk
	var a_accel: float = _p.a_run if run else _p.a_walk
	var half: float = _p.half
	var h: float = _p.h
	var fx: Array = []
	for f in foes:
		fx.append([f[0], f[1], f[2], f[3], true])
	var max_fall: float = _p.max_fall
	var fall_g: float = _p.fall_g
	var out := {"safe": true, "stomps": 0, "x": x, "blocked": 0, "air": false, "ground": true}
	for f in HORIZON:
		if not air and f == jump_at:
			vy = _p.jump_vy
			g = _p.jump_g
			air = true
			jumped_at = f
			cancelled = false
		if air:
			if vy > 0.0:
				g = _p.fall_g
			vy = minf(vy + g, _p.max_fall)
			if jumped_at >= 0 and f - jumped_at >= hold and not cancelled:
				cancelled = true
				if vy < 0.0:
					vy /= _p.cancel
				g = _p.fall_g
			var cap: float = _p.run if (run and absf(vx) > walk) else walk
			var target := cap * dir
			vx = move_toward(vx, target, a_accel)
		elif dir == 0:
			vx = move_toward(vx, 0.0, _p.decel)
		else:
			vx = move_toward(vx, top * dir, g_accel)
		var nx := x + vx * dt
		var ahead := nx + half * signf(vx)
		if vx != 0.0 and (_solid(ahead, y - 2.0) or _solid(ahead, y - h + 2.0)):
			vx = 0.0
			nx = x
			out.blocked += 1
		x = nx
		if air:
			var ny := y + vy * dt
			if vy < 0.0 and (_solid(x - half + 1.0, ny - h) or _solid(x + half - 1.0, ny - h)):
				vy = _p.bump
				ny = y
			elif vy > 0.0 and (_solid(x - half + 1.0, ny) or _solid(x + half - 1.0, ny)):
				ny = floorf(ny / TILE) * TILE
				air = false
				vy = 0.0
				jumped_at = -1
			y = ny
		elif not (_solid(x - half + 1.0, y + 1.0) or _solid(x + half - 1.0, y + 1.0)):
			air = true # walked off an edge
			g = _p.fall_g
			vy = 0.0
		for e in fx:
			if not e[4]:
				continue
			e[0] += e[2] * dt
			if absf(x - e[0]) < half + 7.0 and y > e[1] - 15.0 and y - h < e[1] + 1.0:
				if vy >= 15.0 or y + 4.0 < e[1]:
					e[4] = false # stomped
					out.stomps += 1
					vy = -_p.bounce
					air = true
				elif e[3]:
					out.safe = false
					return out
		if y > (map.floor_row + 2) * TILE:
			out.safe = false
			return out
	out.x = x
	out.air = air
	out.ground = not air or map.ground_in_column(floori(x / TILE), floori(y / TILE))
	return out
