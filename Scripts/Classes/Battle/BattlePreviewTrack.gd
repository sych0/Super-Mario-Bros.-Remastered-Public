class_name BattlePreviewTrack
extends RefCounted
## One opponent's visual reenactment of an authoritative bot run through a level.
##
## NOT a game engine. The BattleSession decides everything that matters (progress, hits,
## clears, KOs); this only decides how that looks. It follows the bot's authoritative progress
## a short, fixed time behind (BattlePreviewDriver.LAG) so it always knows the next outcome
## before it has to animate it, then walks Mario along the level's precomputed walk line,
## makes scripted ballistic jumps over obstacles, scripted stomps on enemies, and stages
## authoritative HIT / KO / LEVEL_CLEAR events (an enemy walks in, Mario falls short of a pit,
## the flagpole). There is no collision response, no player input and no pathfinding.
## It never writes anything back into the session and never touches the session's rng.
##
## A level clear is not the end of the run. After the flagpole the picture holds for a moment, darkens in three steps and cuts to the
## NEXT course's start (doc 55: measured on the reference at 60 fps: no castle walk, no card, no wipe): `enter_course` swaps in the next
## course's level and art (BattlePreviewStages) and starts the run again, in the same frame object, so a cell keeps its binding. The course
## it enters is the session's own next course (`levels_cleared`); a course whose level the sketch builder cannot read is shown by a stand-in
## level, labelled with the real course. Only the end of the last course, or a track with no stages, still ends in DONE (the placeholder).
##
## Incoming enemies (the visible side of an authoritative attack): an INCOMING_ACTIVATED event for
## this opponent makes a BattlePreviewInvader of the attack's kind at the edge of the view, ahead of
## Mario, when the picture's clock reaches the event's tick; the matching INCOMING_RESOLVED event
## (same sequence id) ends it. Invaders are drawn on top of the run and are nothing else: they are not
## in `enemies`, Mario never stomps or meets them, and they can never cause a HIT or a KO. Only the
## authoritative events decide when one exists; the picture's own KO (`_end_ko`) and the level's end
## (`_grab_pole`) merely clear what is still on screen.

enum Phase {RUN, DYING, FALLING, KO, FLAG, FADE, DONE}
enum EnemyState {WALK, STOMPED, SHELL, SLIDE}

const STEP := 1.0 / 30.0
const GRAVITY := BattleLevelSketch.GRAVITY
const MAX_STEPS_PER_ADVANCE := 90 ## 3 s of preview time; further behind than that snaps
const FOLLOW_GAIN := 3.0
const LEAD_ALLOW := 24.0 ## a jump waits until the authoritative position is this close
const SNAP_VIEWS := 1.4 ## falling this many views behind the target snaps to it
const CAMERA_FOCUS := 0.4
const ENEMY_SPEED := 28.0
const KILL_Y := 80.0 ## below this a falling Mario is gone
const FATAL_JUMP_SCALE := 0.55 ## a doomed pit jump covers this much of its distance
const POLE_SLIDE_SPEED := 100.0
const FLAG_HOLD := 0.27 ## seconds Mario stays at the pole's foot before the pane darkens (measured: 0.23-0.30)
## How dark the pane is on each fade step. The reference fades in six 60 fps frames, 3 / 16 / 30 / 52 / 100 / 100 % black, and then
## cuts to the next level; the track steps at 30 Hz, so each step here is the mean of a pair of those frames.
const FADE_STEPS := [0.10, 0.41, 1.0]
const INVADER_APPROACH := 44.0 ## px/s an incoming enemy closes in on Mario
const INVADER_MARGIN := 14.0 ## it appears this far beyond the right edge of the view
const INVADER_CLOSE := 36.0 ## where the first one settles ahead of Mario; each further one stands 24 px further out
const INVADER_SLOTS := 3
const INVADER_VANISH := 0.4 ## seconds it blinks out after its attack resolves
const INVADER_FOLLOW_Y := 140.0 ## px/s it follows a change in the ground level
const INVADER_HOP := 10.0 ## how high it floats while it crosses a pit
const MAX_INVADERS := 8 ## three can be ACTIVE; the rest are ones still blinking out

var id := 0
var course := 0 ## the real course this picture shows (the label); its level may be a stand-in's (`stage_geometry`)
var stage_geometry := 0 ## the course whose level is drawn (= `course` unless it is shown by a stand-in)
var stages: BattlePreviewStages = null ## where the next course's level comes from (null: a clear ends the run, as it did before doc 55)
var sketch: BattleLevelSketch = null
var assets: BattlePreviewAssets = null
var frame := BattlePreviewFrame.new()
var view_w := 117.0

var phase := Phase.RUN
var sim_t := 0.0
var phase_t := 0.0

var x := 0.0
var y := 0.0
var vy := 0.0
var grounded := true
var power := 0
var pose := "Idle"
var speed := 0.0
var walk_phase := 0.0
var blink_t := 0.0
var freeze_t := 0.0
var transition_from := -1
var transition_to := -1
var jump := {} ## active scripted jump, empty if none
var jump_idx := 0
var camera_x := 0.0
var fade := 0.0
var flag_y := -151.0
var mario_hidden := false
var ko_overlay := false
var enemies: Array[Dictionary] = []
var invaders: Array[BattlePreviewInvader] = [] ## the pictures of this opponent's ACTIVE incoming attacks
var steps_taken := 0

var _inc_spawn: Array[Dictionary] = [] # INCOMING_ACTIVATED still to show: {tick, seq, kind}
var _live_attacks := {} # seq -> kind of the attacks the picture has reached ACTIVATED for and not RESOLVED: shown again on a new course
var _inc_end: Array[Dictionary] = [] # INCOMING_RESOLVED still to show: {tick, seq, cause}
var _keys: Array[Dictionary] = []
var _key_cursor := 0
var _pending: Array[Dictionary] = [] # HIT / KO still to be staged
var _clears := {} # course reached by the clear -> {tick, power_to}: every LEVEL_CLEAR still to be shown, as the session logged it
var _loose_power: Array[Dictionary] = [] # POWER_UP not tied to a clear
var _spawn_next := 0
var _prev_tx := 0.0
var _vmax := 100.0
var _stomp_dist := 36.0
var _fall_vx := 0.0
var _hopped := false
var _slide_done_t := -1.0
var _rng := RandomNumberGenerator.new()
var _seed := 0

func _init(id_: int, sketch_: BattleLevelSketch, assets_: BattlePreviewAssets, seed_value: int, view_w_: float, course_ := 0, stages_: BattlePreviewStages = null) -> void:
	id = id_
	course = course_
	stage_geometry = course_
	stages = stages_
	_seed = seed_value
	sketch = sketch_
	assets = assets_
	view_w = view_w_
	_rng.seed = hash([seed_value, id_, course_])
	_vmax = _rng.randf_range(92.0, 112.0)
	_stomp_dist = _rng.randf_range(30.0, 42.0)
	x = sketch.start_x
	y = sketch.ground_y_at(x)
	_prev_tx = x
	camera_x = _cam_min()
	frame.sketch = sketch
	frame.assets = assets
	_fill_frame()

func _cam_min() -> float:
	return sketch.level_min_x

func _cam_max() -> float:
	return sketch.level_max_x

# ---------------------------------------------------------------- inputs

## Authoritative state after session tick `tick`, plus the events logged since the last push.
func push(tick: int, course_: int, progress: float, power_: int, _alive: bool, events: Array) -> void:
	if _keys.is_empty():
		power = power_
	_keys.append({"t": float(tick), "course": course_, "p": progress})
	for e in events:
		match e.type:
			BattleSession.EventType.HIT:
				_pending.append({"tick": float(e.tick), "kind": "hit", "power_to": e.a, "planned": false})
			BattleSession.EventType.KO:
				var timed: bool = e.a != BattleSession.KoCause.HAZARD
				_pending.append({"tick": float(e.tick), "kind": "ko_time" if timed else "ko_hazard", "planned": false})
			BattleSession.EventType.LEVEL_CLEAR:
				if int(e.a) > course:
					_clears[int(e.a)] = {"tick": float(e.tick), "power_to": -1}
			BattleSession.EventType.POWER_UP:
				var with_clear := false
				for reached in _clears:
					if _clears[reached].tick == float(e.tick):
						_clears[reached].power_to = e.a
						with_clear = true
				if not with_clear:
					_loose_power.append({"tick": float(e.tick), "power_to": e.a})
			BattleSession.EventType.INCOMING_ACTIVATED:
				if phase != Phase.KO and phase != Phase.DONE:
					_inc_spawn.append({"tick": float(e.tick), "seq": int(e.a), "kind": int(e.kind)})
			BattleSession.EventType.INCOMING_RESOLVED:
				if phase != Phase.KO and phase != Phase.DONE:
					_inc_end.append({"tick": float(e.tick), "seq": int(e.a), "cause": int(e.cause)})

func _key_progress(k: Dictionary) -> float:
	if k.course < course:
		return 0.0 # a key from a course this picture has left: the next course starts from its beginning
	return 1.0 if k.course > course else clampf(k.p, 0.0, 1.0)

## Authoritative progress at preview time `t` (linear between the session's 1 Hz keyframes).
func target_progress(t: float) -> float:
	var n := _keys.size()
	if n == 0:
		return 0.0
	if t <= _keys[0].t:
		return _key_progress(_keys[0])
	while _key_cursor < n - 2 and _keys[_key_cursor + 1].t <= t:
		_key_cursor += 1
	while _key_cursor > 0 and _keys[_key_cursor].t > t:
		_key_cursor -= 1
	if _key_cursor >= n - 1:
		return _key_progress(_keys[n - 1])
	var a: Dictionary = _keys[_key_cursor]
	var b: Dictionary = _keys[_key_cursor + 1]
	if t >= b.t:
		return _key_progress(b)
	var u: float = (t - a.t) / maxf(b.t - a.t, 0.0001)
	return lerpf(_key_progress(a), _key_progress(b), u)

func target_x(t: float) -> float:
	return sketch.start_x + target_progress(t) * (sketch.goal_x - sketch.start_x)

# ---------------------------------------------------------------- stepping

## Runs fixed 1/30 s steps up to preview time `vt`. Returns true if the picture changed.
func advance_to(vt: float) -> bool:
	if phase == Phase.DONE or phase == Phase.KO:
		return false
	if vt - sim_t > STEP * MAX_STEPS_PER_ADVANCE:
		sim_t = vt - STEP * MAX_STEPS_PER_ADVANCE
	var changed := false
	while sim_t + STEP <= vt and phase != Phase.DONE and phase != Phase.KO:
		_step()
		changed = true
	if changed and (phase == Phase.DONE or phase == Phase.KO):
		_fill_frame()
	return changed

func _step() -> void:
	sim_t += STEP
	phase_t += STEP
	steps_taken += 1
	var running := phase == Phase.RUN and freeze_t <= 0.0 # the classic time stop (Mario growing) holds every enemy
	match phase:
		Phase.RUN:
			_step_run()
		Phase.DYING:
			_step_dying()
		Phase.FALLING:
			_step_falling()
		Phase.FLAG:
			_step_flag()
		Phase.FADE:
			_step_fade()
	_update_camera()
	_tick_invaders(running and phase == Phase.RUN)
	_fill_frame()

func _step_run() -> void:
	if freeze_t > 0.0:
		freeze_t -= STEP # classic time stop while Mario grows or shrinks
		pose = "Transition"
		return
	blink_t = maxf(blink_t - STEP, 0.0)
	_activate_spawns()
	_process_pending()
	if phase != Phase.RUN:
		return
	if not jump.is_empty():
		_step_jump()
	else:
		_step_ground()
	if phase != Phase.RUN:
		return
	_step_enemies()
	_contacts()

# ---- Mario on the walk line

## The clear of the course being shown (what opens the flagpole), or {}.
func _clear() -> Dictionary:
	return _clears.get(course + 1, {})

func _gate_open() -> bool:
	var c := _clear()
	return not c.is_empty() and sim_t >= c.tick - 0.7

func _step_ground() -> void:
	var tx := target_x(sim_t)
	var tspeed := (tx - _prev_tx) / STEP
	_prev_tx = tx
	# A doomed run heads for its pit even if the bot's own progress has stopped short of it.
	if jump_idx < sketch.jumps.size():
		for d in _pending:
			if d.get("fatal_jump", -1) == jump_idx and sim_t >= d.tick - 0.5:
				tx = maxf(tx, sketch.jumps[jump_idx].x_start + 1.0)
	if tx - x > view_w * SNAP_VIEWS:
		_snap_to(tx)
	var next: Dictionary = {}
	if jump_idx < sketch.jumps.size():
		next = sketch.jumps[jump_idx]
	var limit := sketch.goal_x - 8.0
	if not next.is_empty():
		limit = next.x_start
		var gated: bool = next.kind == "pole" and not _gate_open()
		if grounded and x >= next.x_start - 0.01 and tx >= next.x_start - LEAD_ALLOW and not gated:
			_start_route_jump(next)
			return
	var v := 0.0
	if tx > x:
		v = clampf(tspeed + FOLLOW_GAIN * (tx - x), 0.0, _vmax)
	var nx := minf(x + v * STEP, limit)
	if not grounded and sketch.box_hits(nx, y, BattleLevelSketch.BOX_H):
		nx = x # walked off a ledge beside a wall (the end of a staircase): drops straight down instead of through it
	speed = (nx - x) / STEP
	var old_x := x
	x = nx
	var s := sketch.support_y(x, y, BattleLevelSketch.BOX_HALF_W)
	if s >= BattleLevelSketch.PIT_Y * 0.5:
		_recover() # cannot happen on a planned route; never leave Mario over a pit
		return
	if y < s - 0.5:
		vy += GRAVITY * STEP # walked off a ledge
		y += vy * STEP
		grounded = false
		if y >= s:
			y = s
			vy = 0.0
			grounded = true
	elif s < y - 3.0:
		x = old_x # a wall the plan didn't expect: hold position
		speed = 0.0
		y = sketch.support_y(x, y, BattleLevelSketch.BOX_HALF_W)
	else:
		y = s
		vy = 0.0
		grounded = true
	if grounded:
		_try_stomp()
	if not grounded:
		pose = "Jump"
	elif speed < 3.0:
		pose = "Idle"
	else:
		pose = "Move"
		walk_phase += STEP * (4.0 + speed * 0.1)

func _recover() -> void:
	_snap_to(maxf(x - 24.0, sketch.start_x))

func _start_route_jump(j: Dictionary) -> void:
	x = j.x_start # the plan was validated from exactly here
	y = j.y_start
	var vx: float = j.vx
	var fatal := false
	if j.kind == "gap":
		for d in _pending:
			if d.get("fatal_jump", -1) == jump_idx:
				fatal = true
	if fatal:
		vx *= FATAL_JUMP_SCALE
	jump = {"x0": x, "y0": y, "vx": vx, "vy0": j.vy0, "T": j.T, "t": 0.0, "kind": j.kind, "y1": j.y_land, "fatal": fatal}
	jump_idx += 1
	grounded = false
	vy = 0.0
	pose = "Jump"

func _step_jump() -> void:
	var t: float = jump.t + STEP
	jump.t = t
	var p := BattleLevelSketch.arc_pos(jump.x0, jump.y0, jump.vx, jump.vy0, minf(t, jump.T))
	x = p.x
	y = p.y
	pose = "Jump"
	if t < jump.T:
		return
	var j := jump
	if j.fatal:
		jump = {}
		vy = j.vy0 + GRAVITY * j.T
		_fall_vx = j.vx
		phase = Phase.FALLING
		phase_t = 0.0
		return
	x = j.x0 + j.vx * j.T
	y = j.y1
	jump = {}
	vy = 0.0
	match j.kind:
		"pole":
			_grab_pole()
			return
		"stomp":
			_finish_stomp(j)
			return
	grounded = true
	speed = 0.0

# ---- stomping

func _try_stomp() -> void:
	if not jump.is_empty() or freeze_t > 0.0:
		return
	if jump_idx < sketch.jumps.size() and sketch.jumps[jump_idx].x_start < x + 60.0:
		return # an obstacle jump is about to start: don't tangle with it
	for e in enemies:
		if e.state != EnemyState.WALK or e.lethal:
			continue
		var dx: float = e.x - x
		if dx < 6.0 or dx > _stomp_dist or absf(e.y - y) > 14.0:
			continue
		var land_x: float = maxf(e.x + e.vx * 0.5, x + 4.0)
		var arc := BattleLevelSketch.solve_arc(x, y, land_x, y, 32.0, 120.0)
		if arc.is_empty() or not sketch.arc_clear(x, y, arc):
			continue
		if sketch.support_y(land_x, y - 1.0, BattleLevelSketch.BOX_HALF_W) != y or sketch.support_y(x, y - 1.0, BattleLevelSketch.BOX_HALF_W) != y:
			continue
		jump = {"x0": x, "y0": y, "vx": arc.vx, "vy0": arc.vy0, "T": arc.T, "t": 0.0, "kind": "stomp", "y1": y, "fatal": false, "target": e}
		grounded = false
		return

func _finish_stomp(j: Dictionary) -> void:
	var e: Dictionary = j.get("target", {})
	if not e.is_empty() and e.state == EnemyState.WALK and absf(e.x - x) < 16.0:
		_squash(e)
	_bounce(j.vx * 0.5)

func _bounce(vx: float) -> void:
	var arc := BattleLevelSketch.solve_arc(x, y, x + vx * 0.3, y, 14.0, 120.0)
	if not arc.is_empty() and sketch.arc_clear(x, y, arc) and sketch.support_y(x + vx * 0.3, y - 1.0, BattleLevelSketch.BOX_HALF_W) == y \
			and not (jump_idx < sketch.jumps.size() and sketch.jumps[jump_idx].x_start < x + 40.0):
		jump = {"x0": x, "y0": y, "vx": arc.vx, "vy0": arc.vy0, "T": arc.T, "t": 0.0, "kind": "bounce", "y1": y, "fatal": false}
		grounded = false
	else:
		grounded = true

func _squash(e: Dictionary) -> void:
	e.t = 0.0
	if e.kind == "koopa_green":
		e.state = EnemyState.SHELL
	else:
		e.state = EnemyState.STOMPED

# ---- enemies

func _activate_spawns() -> void:
	while _spawn_next < sketch.spawns.size():
		var sp: Dictionary = sketch.spawns[_spawn_next]
		if sp.x > camera_x + view_w + 16.0:
			break
		_spawn_next += 1
		if sp.x < camera_x - 24.0:
			continue
		enemies.append(_make_enemy(sp.kind, sp.x, sp.y, false))

func _make_enemy(kind: String, ex: float, ey: float, lethal: bool) -> Dictionary:
	return {"kind": kind, "x": ex, "y": ey, "vx": -ENEMY_SPEED, "vy": 0.0, "state": EnemyState.WALK, "t": 0.0, "lethal": lethal}

func _step_enemies() -> void:
	var keep: Array[Dictionary] = []
	for e in enemies:
		e.t += STEP
		var alive := true
		match e.state:
			EnemyState.WALK:
				e.x += e.vx * STEP
				if sketch.solid_at(e.x + signf(e.vx) * 7.0, e.y - 5.0):
					e.vx = -e.vx
				var s := sketch.support_y(e.x, e.y)
				if s < BattleLevelSketch.PIT_Y * 0.5 and s - e.y <= 0.5:
					e.y = s
					e.vy = 0.0
				else:
					e.vy += GRAVITY * STEP
					e.y += e.vy * STEP
					if s < BattleLevelSketch.PIT_Y * 0.5 and e.y >= s:
						e.y = s
						e.vy = 0.0
				alive = e.y < KILL_Y + 16.0
			EnemyState.STOMPED:
				alive = e.t < 0.45
			EnemyState.SHELL:
				if e.t > 0.3:
					e.state = EnemyState.SLIDE
					e.vx = 110.0
			EnemyState.SLIDE:
				e.x += e.vx * STEP
				alive = e.x < camera_x + view_w + 24.0 and not sketch.solid_at(e.x + 8.0, e.y - 5.0)
		if e.x < camera_x - 48.0:
			alive = false
		if alive:
			keep.append(e)
	enemies = keep

func _contacts() -> void:
	for e in enemies:
		if e.state != EnemyState.WALK:
			continue
		var passed: bool = e.lethal and e.x < x + 6.0 and absf(e.y - y) < 28.0 # slipped under a jump
		if passed or (absf(e.x - x) < 9.0 and absf(e.y - y) < 12.0):
			if e.lethal:
				_damage_from(e)
			else:
				_squash(e)
				if grounded and jump.is_empty():
					_bounce(40.0)

# ---- staging authoritative outcomes

func _process_pending() -> void:
	for d in _pending.duplicate():
		if not d.planned:
			_plan(d)
		var late: bool = sim_t >= d.tick + 2.0
		match d.kind:
			"ko_time":
				if sim_t >= d.tick:
					_pending.erase(d)
					_begin_dying()
					return
			_:
				if (d.get("instant", false) and sim_t >= d.tick) or late:
					_pending.erase(d)
					_apply(d)
					return
	if not _loose_power.is_empty() and sim_t >= _loose_power[0].tick:
		var lp: Dictionary = _loose_power.pop_front()
		_begin_transition(lp.power_to)

## Decides how a known-in-advance HIT / hazard KO will look.
func _plan(d: Dictionary) -> void:
	d.planned = true
	if d.kind == "ko_time":
		return
	var time_left := maxf(d.tick - sim_t, 0.4)
	if d.kind == "ko_hazard":
		# prefer a pit Mario will reach about when the event lands
		for idx in range(jump_idx, sketch.jumps.size()):
			var j: Dictionary = sketch.jumps[idx]
			if j.x_start - x > 90.0:
				break
			if j.kind != "gap":
				continue
			var arrive: float = maxf(j.x_start - x, 0.0) / maxf(_prev_speed(), 20.0)
			if absf(arrive - time_left) <= 1.2:
				d.fatal_jump = idx
				return
	var x_hit := minf(target_x(maxf(d.tick, sim_t)), sketch.goal_x - 60.0)
	var spawn_x := maxf(x_hit + ENEMY_SPEED * time_left, camera_x + view_w + 12.0)
	if _path_clear(x, spawn_x):
		enemies.append(_make_enemy("goomba", spawn_x, sketch.ground_y_at(spawn_x), true))
	else:
		d.instant = true # nothing believable can reach Mario: it just happens on time

func _prev_speed() -> float:
	return maxf(speed, 1.0)

## True if an enemy could walk from `b` to `a` without a pit or a step in between.
func _path_clear(a: float, b: float) -> bool:
	var level := sketch.ground_y_at(a)
	if level >= BattleLevelSketch.PIT_Y * 0.5 or b > sketch.goal_x - 40.0:
		return false
	var px := a
	while px <= b:
		if absf(sketch.ground_y_at(px) - level) > 0.5:
			return false
		px += 8.0
	return true

func _damage_from(e: Dictionary) -> void:
	e.lethal = false
	for d in _pending:
		if d.kind == "hit" or d.kind == "ko_hazard":
			_pending.erase(d)
			_apply(d)
			return

func _apply(d: Dictionary) -> void:
	if d.kind == "hit":
		_begin_transition(d.power_to, true)
	else:
		_begin_dying()

func _begin_transition(new_power: int, hurt := false) -> void:
	transition_from = power
	transition_to = new_power
	power = new_power
	freeze_t = 0.8
	if hurt:
		blink_t = 1.8 + freeze_t

func _begin_dying() -> void:
	phase = Phase.DYING
	phase_t = 0.0
	jump = {}
	grounded = false
	_hopped = false
	pose = "Die"
	for e in enemies:
		e.lethal = false

func _step_dying() -> void:
	pose = "Die"
	if phase_t < 0.45:
		return
	if not _hopped:
		_hopped = true
		vy = -330.0
	vy += GRAVITY * STEP
	y += vy * STEP
	if y > KILL_Y:
		_end_ko()

func _step_falling() -> void:
	pose = "Jump"
	vy += GRAVITY * STEP
	y += vy * STEP
	x += _fall_vx * STEP
	if y > KILL_Y:
		_end_ko()

func _end_ko() -> void:
	phase = Phase.KO
	mario_hidden = true
	ko_overlay = true
	_clear_invaders() # the KO picture stands alone; whatever was still coming is gone with the run

# ---- level clear

func _grab_pole() -> void:
	phase = Phase.FLAG
	phase_t = 0.0
	grounded = false
	x = sketch.goal_x - 7.0
	pose = "Climb"
	_slide_done_t = -1.0
	for inv in invaders:
		_begin_vanish(inv, BattleAttack.Resolution.NONE) # the level is over; the attacks themselves run on in the session

func _step_flag() -> void:
	pose = "Climb"
	var bottom := sketch.support_y(x, y, BattleLevelSketch.BOX_HALF_W)
	if y < bottom - 0.5:
		y = minf(y + POLE_SLIDE_SPEED * STEP, bottom)
	elif _slide_done_t < 0.0:
		_slide_done_t = phase_t
	flag_y = minf(-151.0 + phase_t * 122.0, -29.0)
	walk_phase += STEP * 6.0
	if _slide_done_t >= 0.0 and phase_t >= _slide_done_t + FLAG_HOLD:
		phase = Phase.FADE
		phase_t = 0.0

## The pane darkens in FADE_STEPS, one per step, and then cuts to the next course (no fade in: the reference shows the new level on the
## frame after the last black one). With no next course to show the run ends dark.
func _step_fade() -> void:
	flag_y = -29.0
	var k := roundi(phase_t / STEP)
	if k <= FADE_STEPS.size():
		fade = FADE_STEPS[k - 1]
		return
	if not _enter_next_course():
		fade = 1.0
		phase = Phase.DONE
		frame.valid = false

## Starts the run again on the next course. False if there is no next course or no level to show for it.
func _enter_next_course() -> bool:
	if stages == null or course + 1 >= BattleCourse.COURSE_COUNT:
		return false
	var st := stages.stage(course + 1)
	if st.is_empty():
		return false
	var want: int = _clear().get("power_to", -1)
	if want >= 0:
		power = want # grown (or kept) by the clear: the run starts with it
	_clears.erase(course + 1)
	enter_course(course + 1, st)
	return true

## Puts the picture on `st` (a BattlePreviewStages.stage): course `course_`'s level and art, Mario at its start, the camera at its left
## edge, no enemy of the last level, nothing of its pole or fade. The frame object stays the same (a cell is bound to it). What the
## session already said about this opponent (HIT / KO still to be shown, incoming attacks) is kept; how it will be shown is planned again
## on the new level.
func enter_course(course_: int, st: Dictionary) -> void:
	course = course_
	stage_geometry = st.geometry
	sketch = st.sketch
	assets = st.assets
	frame.sketch = sketch
	frame.assets = assets
	_rng.seed = hash([_seed, id, course_])
	_vmax = _rng.randf_range(92.0, 112.0)
	_stomp_dist = _rng.randf_range(30.0, 42.0)
	phase = Phase.RUN
	phase_t = 0.0
	fade = 0.0
	flag_y = -151.0
	mario_hidden = false
	freeze_t = 0.0
	blink_t = 0.0
	pose = "Idle"
	speed = 0.0
	walk_phase = 0.0
	jump = {}
	jump_idx = 0
	vy = 0.0
	grounded = true
	enemies.clear()
	_spawn_next = 0
	_slide_done_t = -1.0
	_hopped = false
	x = sketch.start_x
	y = sketch.ground_y_at(x)
	_prev_tx = x
	camera_x = _cam_min()
	for d in _pending:
		d.planned = false
		d.erase("fatal_jump")
		d.erase("instant")
	invaders.clear() # (the last level's were blinked out at the flagpole)
	for seq in _live_attacks: # an attack that is still ACTIVE on this opponent is still in its world: its enemy is on the new course too
		_spawn_invader(seq, _live_attacks[seq])
	_fill_frame()

## Holds the picture at a state that can be shown at rest (the round is over): a pane caught mid-fade is on the next course, not black.
func settle() -> void:
	if phase == Phase.FADE and not _enter_next_course():
		fade = 1.0
		phase = Phase.DONE
		frame.valid = false
	_fill_frame()

# ---- incoming enemies (authoritative attacks, shown)

## Runs every step in every live phase. Spawns the invaders whose INCOMING_ACTIVATED tick the picture
## has reached, ends the ones whose INCOMING_RESOLVED tick it has reached (spawns first, so an attack
## that activates and resolves in the same tick still shows for a moment), moves them while the run
## is moving, and removes the ones that have finished blinking out.
func _tick_invaders(moving: bool) -> void:
	if invaders.is_empty() and _inc_spawn.is_empty() and _inc_end.is_empty():
		return
	while not _inc_spawn.is_empty() and _inc_spawn[0].tick <= sim_t:
		var s: Dictionary = _inc_spawn.pop_front()
		_live_attacks[s.seq] = s.kind
		if phase == Phase.RUN or phase == Phase.DYING or phase == Phase.FALLING: # nothing arrives at the flagpole
			_spawn_invader(s.seq, s.kind)
	while not _inc_end.is_empty() and _inc_end[0].tick <= sim_t:
		var r: Dictionary = _inc_end.pop_front()
		_live_attacks.erase(r.seq)
		var inv := invader_for(r.seq)
		if inv != null:
			_begin_vanish(inv, r.cause)
	var kept: Array[BattlePreviewInvader] = []
	for inv in invaders:
		inv.t += STEP
		if inv.is_vanishing():
			inv.vanish_t += STEP
			if inv.vanish_t >= INVADER_VANISH:
				continue
		elif moving:
			_move_invader(inv)
		kept.append(inv)
	invaders = kept

## The picture of attack `seq` on this run, or null.
func invader_for(seq: int) -> BattlePreviewInvader:
	for inv in invaders:
		if inv.seq == seq:
			return inv
	return null

func _spawn_invader(seq: int, kind: int) -> void:
	var preview_kind := BattleEnemyIcon.preview_kind(kind)
	if preview_kind == "" or invader_for(seq) != null or invaders.size() >= MAX_INVADERS:
		return
	var inv := BattlePreviewInvader.new()
	inv.seq = seq
	inv.kind = kind
	inv.preview_kind = preview_kind
	inv.slot = _free_invader_slot(seq)
	inv.close = INVADER_CLOSE + 24.0 * inv.slot
	inv.phase = float(seq % 7) * 0.9
	inv.ahead = maxf(camera_x + view_w + INVADER_MARGIN - x, inv.close + 24.0)
	inv.x = minf(x + inv.ahead, sketch.goal_x - 12.0)
	var g := sketch.ground_y_at(inv.x)
	if g >= BattleLevelSketch.PIT_Y * 0.5:
		g = sketch.ground_y_at(x)
	if g >= BattleLevelSketch.PIT_Y * 0.5:
		g = 0.0
	inv.ground_y = g
	inv.y = g
	invaders.append(inv)

## The first of the INVADER_SLOTS places ahead of Mario that no live invader holds (several incoming
## enemies stand at different distances); with every place taken it is chosen by the sequence id.
func _free_invader_slot(seq: int) -> int:
	for slot in INVADER_SLOTS:
		var taken := false
		for inv in invaders:
			if inv.slot == slot and not inv.is_vanishing():
				taken = true
		if not taken:
			return slot
	return seq % INVADER_SLOTS

func _begin_vanish(inv: BattlePreviewInvader, cause: int) -> void:
	if inv.is_vanishing():
		return
	inv.state = BattlePreviewInvader.State.VANISH
	inv.vanish_t = 0.0
	inv.cause = cause

## It closes in from the edge of the view, then keeps its distance ahead of Mario with a small
## back-and-forth, standing on the walk line's ground (floating over a pit). No collision, no stomp.
func _move_invader(inv: BattlePreviewInvader) -> void:
	var want := inv.close + 8.0 * sin(inv.t * 2.2 + inv.phase)
	inv.ahead = move_toward(inv.ahead, want, INVADER_APPROACH * STEP)
	inv.x = minf(x + inv.ahead, sketch.goal_x - 12.0)
	var g := sketch.ground_y_at(inv.x)
	var floor_y := inv.ground_y - INVADER_HOP
	if g < BattleLevelSketch.PIT_Y * 0.5:
		inv.ground_y = g
		floor_y = g
	inv.y = move_toward(inv.y, floor_y, INVADER_FOLLOW_Y * STEP)

func _clear_invaders() -> void:
	invaders.clear()
	_inc_spawn.clear()
	_inc_end.clear()
	_live_attacks.clear()

# ---- placement helpers

func _snap_to(tx: float) -> void:
	var cand := minf(tx, sketch.goal_x - 80.0)
	var found := false
	for _i in 200:
		if cand <= sketch.start_x:
			cand = sketch.start_x
			found = true
			break
		if _safe_column(cand):
			found = true
			break
		cand -= 8.0
	if not found:
		cand = sketch.start_x
	x = cand
	y = sketch.ground_y_at(x)
	vy = 0.0
	grounded = true
	jump = {}
	speed = 0.0
	jump_idx = 0
	while jump_idx < sketch.jumps.size() and sketch.jumps[jump_idx].x_start < x - 0.5:
		jump_idx += 1

func _safe_column(px: float) -> bool:
	var g := sketch.ground_y_at(px)
	if g >= BattleLevelSketch.PIT_Y * 0.5:
		return false
	for dx in [-10.0, 10.0]:
		if absf(sketch.ground_y_at(px + dx) - g) > 0.5:
			return false
	for j in sketch.jumps:
		if px > j.x_start - 12.0 and px < j.x_land + 12.0:
			return false
	return true

func _update_camera() -> void:
	var want := x - CAMERA_FOCUS * view_w
	want = clampf(want, _cam_min(), maxf(_cam_min(), _cam_max() - view_w))
	if phase == Phase.RUN or phase == Phase.FLAG or phase == Phase.FADE:
		camera_x = maxf(camera_x, want) # SMB1 never scrolls back

# ---------------------------------------------------------------- output

func _mario_sprite() -> BattlePreviewSprite:
	if assets == null:
		return null
	if pose == "Transition" and transition_from >= 0:
		var seq: Array = [transition_from, -1, transition_to]
		var pick: int = seq[int(sim_t * 12.0) % 3]
		if pick < 0:
			return assets.mario_frame_at(1, "Grow", 0)
		return assets.mario_frame_at(pick, "Idle", 0)
	var index := int(walk_phase) if pose == "Move" or pose == "Climb" else 0
	return assets.mario_frame_at(power, pose, index)

func _fill_frame() -> void:
	var f := frame
	if phase != Phase.DONE:
		f.valid = true
	f.camera_x = camera_x
	f.view_w = view_w
	f.cam_min = _cam_min()
	f.cam_max = _cam_max()
	f.displayed_course = course
	f.time = sim_t
	f.pose = pose
	f.pose_index = int(walk_phase) if pose == "Move" or pose == "Climb" else 0
	f.mario_x = x
	f.mario_y = y
	f.mario_visible = not mario_hidden and (blink_t <= 0.0 or (steps_taken / 2) % 2 == 0) # blink at 15 Hz, exact in steps
	f.mario_sprite = _mario_sprite()
	f.flag_y = flag_y
	f.flag_visible = true
	f.fade = fade
	f.ko_overlay = ko_overlay
	f.actors.clear()
	f.invaders.clear()
	if assets == null:
		return
	for inv in invaders:
		if inv.x < camera_x - 24.0 or inv.x > camera_x + view_w + 24.0:
			continue
		var ispr := assets.enemy_frame(inv.preview_kind, inv.t)
		if ispr != null:
			f.invaders.append({"seq": inv.seq, "kind": inv.kind, "sprite": ispr, "x": inv.x, "y": inv.y,
				"vanish": inv.vanish_t / INVADER_VANISH if inv.is_vanishing() else 0.0})
	for e in enemies:
		if e.x < camera_x - 20.0 or e.x > camera_x + view_w + 20.0:
			continue
		var spr: BattlePreviewSprite = null
		match e.state:
			EnemyState.WALK, EnemyState.SLIDE:
				spr = assets.enemy_frame(e.kind, e.t) if e.state == EnemyState.WALK else assets.enemy_dead(e.kind)
			_:
				spr = assets.enemy_dead(e.kind)
		if spr != null:
			f.actors.append([spr, e.x, e.y, e.vx > 0.0 and e.state == EnemyState.WALK])
