extends SceneTree
## Deterministic checks of physical incoming-enemy delivery (doc 46), with no scene tree: the delivery
## plan (strict order, grace, gap, retry, relax, nothing dropped), the placement rule on ASCII maps,
## the session's spawn fact (one enemy per attack; transitions carry what never appeared), the kill of
## an incoming enemy (it resolves its own attack and never sends: rule R0), the identity tag, and the
## presentation clock that a held game holds.
##   godot --headless --path . -s tests/battle_incoming_plan_test.gd

var failures := 0
var S # BattleSession
var A # BattleAttack
var R # BattleAttack.Resolution
var SYS # BattleAttackSystem
var T # BattleEnemyType
var E # BattleSession.EventType
var AT # BattleAttribution
var SRC # BattleAttribution.Source
var PLAN # BattleIncomingPlan
var PL # BattleSpawnPlacer
var PRES # BattleAttackPresentation
var FixedPolicy

const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""
const DT := 1.0 / 60.0

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func _initialize() -> void:
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	A = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	R = A.Resolution
	SYS = load("res://Scripts/Classes/Battle/BattleAttackSystem.gd")
	T = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	E = S.EventType
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	SRC = AT.Source
	PLAN = load("res://Scripts/Classes/Battle/BattleIncomingPlan.gd")
	PL = load("res://Scripts/Classes/Battle/BattleSpawnPlacer.gd")
	PRES = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	S.default_attacks_enabled = true
	test_plan_basics()
	test_plan_pacing()
	test_plan_hold_and_relax()
	test_placer_maps()
	test_placer_random()
	test_session_spawn_fact()
	test_transition_rule()
	test_incoming_kill_routing()
	test_tag()
	test_whole_matches()
	test_presentation_clock()
	if failures > 0:
		printerr("%d Battle incoming plan test(s) failed" % failures)
	else:
		print("All Battle incoming plan tests passed")
	quit(1 if failures > 0 else 0)

## A session whose bots do not send, every attack aimed at `target`.
func quiet(seed_value := 1, target := 0):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	var p = FixedPolicy.new()
	p.target = target
	s.attacks.targeting = p
	return s

func events_of(s, type: int) -> Array:
	return s.events.filter(func(e): return e.type == type)

func row(seq: int, state: int, spawned_tick := -1, kind := 1) -> Dictionary:
	return {"seq": seq, "state": state, "spawned_tick": spawned_tick, "kind": kind}

## Advances `plan` `seconds` in 1/60 s steps; returns the clock values at which `next_due` gave a seq
## (and marks it spawned, as the spawner would), as [seq, clock].
func run_plan(plan, rows: Array, seconds: float, deliverable := true, spawn := true) -> Array:
	var out := []
	for i in int(round(seconds * 60.0)):
		plan.advance(DT, deliverable)
		var live_rows: Array = rows.filter(func(r): return not plan.spawned.has(int(r.seq)))
		plan.sync(live_rows)
		var seq: int = plan.next_due()
		if seq >= 0:
			out.append([seq, snappedf(plan.clock, 0.001)])
			if spawn:
				plan.on_spawned(seq)
	return out

# ------------------------------------------------------------------ plan

func test_plan_basics() -> void:
	var plan = PLAN.new()
	plan.sync([row(4, A.State.QUEUED), row(2, A.State.ACTIVE), row(3, A.State.ACTIVE, 7), row(1, A.State.ACTIVE)])
	check(plan.pending == [1, 2], "pending = the ACTIVE attacks whose enemy has not appeared, in seq order (QUEUED and spawned ones are not)")
	check(plan.next_due() == -1, "nothing is due before the level has been deliverable at all")
	plan.advance(1.0, false)
	check(plan.next_due() == -1 and plan.ready_at < 0.0, "nor while the player is not in normal play")
	var due := run_plan(plan, [row(1, A.State.ACTIVE), row(2, A.State.ACTIVE)], 4.0)
	check(due.size() == 2 and due[0][0] == 1 and due[1][0] == 2, "they come due in seq order (%s)" % str(due))
	check(absf(due[0][1] - (1.0 + PLAN.GRACE)) < 0.02, "the first only GRACE (%.1f s) after the level became deliverable (at %.3f)" % [PLAN.GRACE, due[0][1]])
	check(absf(due[1][1] - due[0][1] - PLAN.GAP) < 0.02, "the second GAP (%.1f s) after the first" % PLAN.GAP)
	# a spawned seq is never due again, even if a stale row still shows it unspawned
	var again = PLAN.new()
	var r1 := [row(9, A.State.ACTIVE)]
	var first := run_plan(again, r1, 2.0)
	again.sync(r1)
	again.advance(5.0, true)
	check(first.size() == 1 and again.next_due() == -1 and again.pending.is_empty(), "a seq that was spawned once is never due again (one attack, one enemy)")
	again.on_spawned(9)
	check(again.spawned.size() == 1, "on_spawned twice is harmless")

func test_plan_pacing() -> void:
	# a burst of three activations on one tick arrives at 0 / 1 / 2 s after the grace
	var plan = PLAN.new()
	var rows := [row(5, A.State.ACTIVE), row(6, A.State.ACTIVE), row(7, A.State.ACTIVE)]
	var due := run_plan(plan, rows, 6.0)
	var times: Array = due.map(func(d): return d[1])
	check(due.map(func(d): return d[0]) == [5, 6, 7], "a burst of three is delivered in order")
	check(times.size() == 3 and absf(times[0] - PLAN.GRACE) < 0.02 and absf(times[1] - times[0] - 1.0) < 0.02 and absf(times[2] - times[1] - 1.0) < 0.02, "at grace, +1 s, +2 s (%s)" % str(times))
	# never two in the same step, whatever the clock does
	var fast = PLAN.new()
	fast.advance(DT, true)
	fast.advance(10.0, true)
	fast.sync(rows)
	var a: int = fast.next_due()
	fast.on_spawned(a)
	fast.sync(rows.filter(func(r): return r.seq != a))
	check(a == 5 and fast.next_due() == -1, "right after a spawn nothing else is due, even after a long wait before it")
	# not deliverable holds it, without losing it
	var held = PLAN.new()
	var d1 := run_plan(held, [row(1, A.State.ACTIVE)], 5.0, false)
	check(d1.is_empty() and held.pending == [1], "while the player is not in normal play nothing is delivered and nothing is lost")
	var d2 := run_plan(held, [row(1, A.State.ACTIVE)], 3.0, true)
	check(d2.size() == 1 and absf(d2[0][1] - 5.0 - PLAN.GRACE) < 0.02, "once in normal play it comes GRACE later (%s)" % str(d2))
	# the grace is per level: it does not restart when play is briefly interrupted
	var once = PLAN.new()
	run_plan(once, [], 2.0, true)
	run_plan(once, [], 0.5, false)
	var d3 := run_plan(once, [row(3, A.State.ACTIVE)], 1.0, true)
	check(d3.size() == 1 and d3[0][1] < 2.6, "an interruption after the grace does not start a new grace (%s)" % str(d3))
	# a resolved attack leaves pending; a held head never lets a later one pass
	var order = PLAN.new()
	order.advance(DT, true)
	order.advance(5.0, true)
	order.sync([row(1, A.State.ACTIVE), row(2, A.State.ACTIVE)])
	order.on_failed(1)
	order.advance(PLAN.RETRY / 2.0, true)
	check(order.next_due() == -1, "after a failed placement the head waits RETRY before it is tried again")
	order.advance(PLAN.RETRY, true)
	check(order.next_due() == 1, "...and then it is the head again, not the attack behind it (strict order)")
	order.sync([row(2, A.State.ACTIVE)])
	check(order.pending == [2] and order.next_due() == 2 and not order.holding(), "when the head attack ends (killed, despawned) the next one moves up")

func test_plan_hold_and_relax() -> void:
	var plan = PLAN.new()
	plan.advance(DT, true)
	plan.advance(5.0, true)
	var rows := [row(1, A.State.ACTIVE)]
	var tries := 0
	var relaxed_early := false
	for i in 60 * 4:
		plan.advance(DT, true)
		plan.sync(rows)
		var seq: int = plan.next_due()
		if seq >= 0:
			tries += 1
			plan.on_failed(seq)
		if plan.clock - 5.0 < PLAN.RELAX_AFTER - 0.1 and plan.relaxed():
			relaxed_early = true
	check(not relaxed_early, "the relaxed rule is not used before RELAX_AFTER")
	check(tries >= 12 and tries <= 17, "a head that cannot be placed is retried every RETRY seconds (%d tries in 4 s)" % tries)
	check(plan.relaxed() and plan.holding(), "after RELAX_AFTER (%.0f s) of holding, the relaxed rule may be used" % PLAN.RELAX_AFTER)
	check(plan.pending == [1], "and it is still pending: a held attack is never dropped")
	plan.on_spawned(1)
	check(not plan.holding() and not plan.relaxed(), "spawning it ends the hold")

# ------------------------------------------------------------------ placement

## A probe over an ASCII map: rows top to bottom starting at cell row `y0`, columns from cell `x0`.
## '#' solid, 'E' an enemy body standing on the floor below it.
func make_map(rows: Array, x0: int, y0: int) -> Dictionary:
	var cells := {}
	var bodies := []
	for j in rows.size():
		var line: String = rows[j]
		for i in line.length():
			var c := line[i]
			if c == "#":
				cells[Vector2i(x0 + i, y0 + j)] = true
			elif c == "E":
				bodies.append(Rect2((x0 + i) * 16, (y0 + j) * 16, 16, 16))
	var solid := func(cell: Vector2i) -> bool: return cells.has(cell)
	var blocked := func(rect: Rect2) -> bool:
		for b in bodies:
			if (b as Rect2).intersects(rect):
				return true
		return false
	return {"solid": solid, "blocked": blocked}

## A 256x240 view whose left edge is cell `x0`, with 1-1's vertical framing (y -208..32).
func view_at(x0: int) -> Rect2:
	return Rect2(x0 * 16, -208, 256, 240)

func flat(extra := {}) -> Array:
	# 15 rows from y = -208 (cell -13) to y = 16 (cell 1); ground at cell 0 and 1
	var rows := []
	for j in 13:
		rows.append(".................")
	rows.append("#################") # cell 0: ground surface y = 0
	rows.append("#################")
	for k in extra:
		rows[int(k)] = extra[k]
	return rows

func test_placer_maps() -> void:
	var m := make_map(flat(), 0, -13)
	var view := view_at(0)
	var mario := Vector2(40, 0)
	var spot: Dictionary = PL.place(view, mario, m.solid, m.blocked)
	check(spot.ok and spot.side == "ahead" and spot.position == Vector2(15 * 16 + 8, 0) and spot.direction == -1, "flat ground: the last column inside the right edge, on the floor, facing Mario (%s)" % str(spot))
	# Mario at a camera limit near the right edge: behind
	var near_end: Dictionary = PL.place(view, Vector2(240, 0), m.solid, m.blocked)
	check(near_end.ok and near_end.side == "behind" and near_end.direction == 1 and near_end.position.x <= 240 - PL.MIN_BEHIND and near_end.position == Vector2(8, 0), "Mario near the right edge: the first column inside the left edge, facing him (%s)" % str(near_end))
	# Mario in the middle: ahead needs 80 px, so the far right still works
	var mid: Dictionary = PL.place(view, Vector2(128, 0), m.solid, m.blocked)
	check(mid.ok and mid.side == "ahead" and mid.position.x - 128 >= PL.MIN_AHEAD, "always at least MIN_AHEAD (%d px) ahead" % PL.MIN_AHEAD)
	# a pit at the right edge: its columns are skipped, and the lip next to it has no footing
	var pit := flat({13: "############.....", 14: "############....."})
	var mp := make_map(pit, 0, -13)
	var over: Dictionary = PL.place(view, mario, mp.solid, mp.blocked)
	check(over.ok and over.position.x == 11 * 16 + 8, "pit columns are skipped: the last floor before the gap, which walks away from it toward Mario (%s)" % str(over))
	# a lip on the far side of a 1-wide gap: no footing
	var gap1 := flat({13: "##############.##", 14: "##############.##"})
	var mg := make_map(gap1, 0, -13)
	var g1: Dictionary = PL.place(view, mario, mg.solid, mg.blocked)
	check(g1.ok and g1.position.x == 13 * 16 + 8, "a column whose neighbour toward Mario is a gap is rejected; the next one in is used (%s)" % str(g1))
	# a pipe near the right edge: its top is a floor, its inside is not
	var pipe := flat({11: "..............##.", 12: "..............##."})
	var mpi := make_map(pipe, 0, -13)
	var pt: Dictionary = PL.place(view, mario, mpi.solid, mpi.blocked)
	check(pt.ok and pt.position == Vector2(16 * 16 + 8, 0) or pt.position == Vector2(15 * 16 + 8, -32), "a pipe: the top is a floor with footing on the pipe's own right column, never inside it (%s)" % str(pt))
	var col15: float = PL.floor_in(15, view, 0.0, mpi.solid)
	var col14: float = PL.floor_in(14, view, 0.0, mpi.solid)
	check(col15 == -32.0 and col14 == -32.0, "(the floor in a pipe column is its top, not the ground inside it: %s / %s)" % [col14, col15])
	# no headroom: a ceiling one cell above the ground
	var low := flat({0: "#################", 1: "#################", 2: "#################", 3: "#################", 4: "#################", 5: "#################", 6: "#################", 7: "#################", 8: "#################", 9: "#################", 10: "#################", 11: "#################"})
	var ml := make_map(low, 0, -13)
	var lo: Dictionary = PL.place(view, mario, ml.solid, ml.blocked)
	check(not lo.ok, "a floor with one empty cell above it (under a solid ceiling that reaches the HUD) is not a floor (%s)" % str(lo))
	# the HUD band: a floor up there does not count
	var hud := []
	for j in 15:
		hud.append(".................")
	hud[2] = "#################" # cell -11: surface y = -176, inside the HUD band + 32
	var mh := make_map(hud, 0, -13)
	var hu: Dictionary = PL.place(view, Vector2(40, -176), mh.solid, mh.blocked)
	check(not hu.ok and hu.reason == "no visible floor", "a floor in or right below the HUD band is not used (%s)" % str(hu))
	# an enemy standing where it would appear: the next column
	var occ := flat({12: "...............E."})
	var mo := make_map(occ, 0, -13)
	var oc: Dictionary = PL.place(view, mario, mo.solid, mo.blocked)
	check(oc.ok and oc.position.x == 14 * 16 + 8 or oc.position.x == 13 * 16 + 8, "a spot with an enemy body in it is skipped (%s)" % str(oc))
	check(not Rect2(oc.position + PL.CLEAR_BOX.position, PL.CLEAR_BOX.size).intersects(Rect2(15 * 16, -16, 16, 16)), "(and the chosen box is clear of it)")
	# separation from a live incoming enemy that physics has not seen yet
	var sep: Dictionary = PL.place(view, mario, m.solid, m.blocked, [Vector2(15 * 16 + 8, 0)])
	check(sep.ok and absf(sep.position.x - (15 * 16 + 8)) >= PL.SEPARATION, "at least SEPARATION (%d px) from another live incoming enemy on the same floor (%s)" % [PL.SEPARATION, str(sep)])
	var sep2: Dictionary = PL.place(view, mario, m.solid, m.blocked, [Vector2(15 * 16 + 8, -96)])
	check(sep2.ok and sep2.position.x == 15 * 16 + 8, "one on another floor does not count")
	# nothing valid: a reason, no spot
	var none_rows := []
	for j in 15:
		none_rows.append(".................")
	var mn := make_map(none_rows, 0, -13)
	var nn: Dictionary = PL.place(view, mario, mn.solid, mn.blocked)
	check(not nn.ok and nn.reason == "no visible floor" and not nn.has("position"), "no floor anywhere (coin heaven, a long pit): no spot, and a reason (%s)" % nn.reason)
	var tight: Dictionary = PL.place(Rect2(0, -208, 160, 240), Vector2(80, 0), m.solid, m.blocked)
	check(not tight.ok and tight.reason == "no column far enough from Mario", "a view too narrow for the distances: no spot (%s)" % tight.reason)
	# relaxed: smaller distances, no footing
	var narrow: Dictionary = PL.place(Rect2(0, -208, 192, 240), Vector2(110, 0), m.solid, m.blocked)
	var narrow_relaxed: Dictionary = PL.place(Rect2(0, -208, 192, 240), Vector2(110, 0), m.solid, m.blocked, [], true)
	check(not narrow.ok and narrow_relaxed.ok and narrow_relaxed.position.x - 110 >= PL.RELAXED_AHEAD, "the relaxed rule finds a spot the strict one cannot, still RELAXED_AHEAD (%d px) away (%s)" % [PL.RELAXED_AHEAD, str(narrow_relaxed)])
	var lip_only := flat({13: "###############.#", 14: "###############.#"})
	var mlo := make_map(lip_only, 0, -13)
	var strict_lip: Dictionary = PL.place(Rect2(0, -208, 272, 240), Vector2(150, 0), mlo.solid, mlo.blocked)
	var relaxed_lip: Dictionary = PL.place(Rect2(0, -208, 272, 240), Vector2(150, 0), mlo.solid, mlo.blocked, [], true)
	check(strict_lip.ok and relaxed_lip.ok and relaxed_lip.position.x >= strict_lip.position.x, "relaxed drops the footing rule (strict %s, relaxed %s)" % [strict_lip.position, relaxed_lip.position])
	# the floor nearest Mario's feet wins in a column with several
	var two := flat({7: "..............###", 6: "................."})
	var mt := make_map(two, 0, -13)
	var high: Dictionary = PL.place(view, Vector2(40, -96), mt.solid, mt.blocked)
	var low_m: Dictionary = PL.place(view, Vector2(40, 0), mt.solid, mt.blocked)
	check(high.ok and high.position.y == -96.0 and low_m.ok and low_m.position.y == 0.0, "of two floors in a column, the one nearest Mario's feet (%s / %s)" % [high.position, low_m.position])
	# Mario's own body is never overlapped
	var all_ok := true
	for x in range(0, 256, 4):
		var sp: Dictionary = PL.place(view, Vector2(x, 0), m.solid, m.blocked, [], true)
		if sp.ok and Rect2(sp.position + PL.BODY_BOX.position, PL.BODY_BOX.size).intersects(Rect2(Vector2(x, 0) + PL.MARIO_BOX.position, PL.MARIO_BOX.size)):
			all_ok = false
	check(all_ok, "for Mario anywhere on the screen, no spot overlaps his body")

func test_placer_random() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var bad := 0
	var found := 0
	var same := true
	for n in 1000:
		var rows := []
		for j in 15:
			var line := ""
			for i in 17:
				var r := rng.randf()
				line += "#" if (j >= 13 and r < 0.8) or (j < 13 and r < 0.12) else "."
			rows.append(line)
		var m := make_map(rows, 0, -13)
		var mario := Vector2(rng.randi_range(8, 248), [0.0, -32.0, -64.0][rng.randi_range(0, 2)])
		var view := view_at(0)
		var a: Dictionary = PL.place(view, mario, m.solid, m.blocked)
		var b: Dictionary = PL.place(view, mario, m.solid, m.blocked)
		if str(a) != str(b):
			same = false
		if a.ok:
			found += 1
			var cx := int(a.position.x) / 16
			var cy := int(a.position.y) / 16
			var inside: bool = a.position.x - 8 >= view.position.x and a.position.x + 8 <= view.end.x and a.position.y >= view.position.y + PL.HUD_BAND + 32 and a.position.y <= view.end.y
			var distance_ok: bool = (a.side == "ahead" and a.position.x - mario.x >= PL.MIN_AHEAD) or (a.side == "behind" and mario.x - a.position.x >= PL.MIN_BEHIND)
			if not PL.is_floor(cx, cy, m.solid) or not PL.is_floor(cx + a.direction, cy, m.solid) or not inside or not distance_ok:
				bad += 1
	check(same, "the same map and Mario always give the same answer (1000 random maps, twice)")
	check(bad == 0 and found > 300, "every spot found is a visible floor with headroom and footing, at the required distance (%d spots, %d bad)" % [found, bad])

# ------------------------------------------------------------------ session

func test_session_spawn_fact() -> void:
	var s = quiet(10, 0)
	var a0 = s.report_enemy_defeat(3, T.Kind.GOOMBA)
	check(not s.report_player_incoming_spawned(a0.seq) and a0.spawned_tick == -1, "a QUEUED attack cannot be spawned")
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	check(s.report_player_incoming_spawned(a0.seq) and a0.spawned_tick == s.tick_count, "an ACTIVE attack on the player is reported spawned once, at the current tick")
	var ev: Array = events_of(s, E.INCOMING_SPAWNED)
	check(ev.size() == 1 and ev[0].id == 0 and ev[0].a == a0.seq and ev[0].b == 3 and ev[0].kind == T.Kind.GOOMBA, "INCOMING_SPAWNED: target, seq, sender, kind")
	var snap = s.attacks.snapshot()
	check(not s.report_player_incoming_spawned(a0.seq) and s.attacks.snapshot() == snap and events_of(s, E.INCOMING_SPAWNED).size() == 1, "a second report for the same attack is refused and changes nothing")
	check(not s.report_player_incoming_spawned(999) and not s.report_player_incoming_spawned(-1), "an unknown seq is refused")
	var b = quiet(11, 6)
	var ba = b.report_enemy_defeat(2, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		b.step()
	check(ba.state == A.State.ACTIVE and not b.report_player_incoming_spawned(ba.seq), "an attack aimed at a bot is never spawned")
	s.resolve_player_incoming(a0.seq, R.OTHER)
	check(not s.report_player_incoming_spawned(a0.seq), "a resolved attack is refused")
	var a1 = s.report_enemy_defeat(4, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	s.end_round()
	check(a1.state == A.State.RESOLVED and not s.report_player_incoming_spawned(a1.seq), "after the round has ended nothing is spawned")
	check(s.get_incoming(0).is_empty(), "(nothing left)")
	check(a0.to_dict().spawned_tick == a0.spawned_tick and s.attacks.snapshot().history[0].size() == 11, "spawned_tick is in the copies and the snapshot")
	# a fresh round starts clean
	S.begin(12)
	var fresh = S.current
	check(fresh.attacks.history.is_empty() and events_of(fresh, E.INCOMING_SPAWNED).is_empty() and fresh.attacks.incoming_kill_sources.is_empty(), "a new round has no spawn state")
	S.clear()

func test_transition_rule() -> void:
	var s = quiet(20, 0)
	var made := []
	for i in 4:
		made.append(s.report_enemy_defeat(2 + i, T.Kind.GOOMBA))
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	# three ACTIVE (cap), one QUEUED; the first two have their enemies in the level
	s.report_player_incoming_spawned(made[0].seq)
	s.report_player_incoming_spawned(made[1].seq)
	check(made.map(func(a): return a.state) == [A.State.ACTIVE, A.State.ACTIVE, A.State.ACTIVE, A.State.QUEUED], "(setup: 3 ACTIVE, 2 of them spawned, 1 QUEUED)")
	var n: int = s.resolve_player_spawned(R.LEVEL_TRANSITION)
	check(n == 2 and made[0].resolution == R.LEVEL_TRANSITION and made[1].resolution == R.LEVEL_TRANSITION, "a transition resolves the spawned ACTIVE attacks as LEVEL_TRANSITION")
	check(made[2].state == A.State.ACTIVE and made[2].spawned_tick == -1 and made[3].state == A.State.QUEUED, "the ACTIVE one that never appeared stays ACTIVE (carried), the QUEUED one stays QUEUED")
	check(s.get_incoming(0).map(func(d): return d.seq) == [made[2].seq, made[3].seq], "...in their order")
	check(s.resolve_player_spawned(R.LEVEL_TRANSITION) == 0, "a second transition with nothing spawned resolves nothing")
	s.step()
	check(made[3].state == A.State.ACTIVE, "the freed slots let the queued one activate on the next tick")
	check(s.report_player_incoming_spawned(made[2].seq), "the carried attack can be spawned in the next level, once")
	check(not s.report_player_incoming_spawned(made[2].seq), "...and only once")
	# many transitions in a row never erase an attack that never appeared
	var t = quiet(21, 0)
	var c = t.report_enemy_defeat(3, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		t.step()
	for i in 10:
		t.resolve_player_spawned(R.LEVEL_TRANSITION)
		t.step()
	check(c.state == A.State.ACTIVE and c.resolution == R.NONE, "ten transitions (pipes back and forth) later the unspawned attack is still ACTIVE")
	t.report_ko(0, S.KoCause.HAZARD)
	check(c.resolution == R.TARGET_OUT, "it ends only with the player (TARGET_OUT) or the round")

func test_incoming_kill_routing() -> void:
	var s = quiet(30, 0)
	S.current = s
	var g = s.report_enemy_defeat(5, T.Kind.GOOMBA)
	var k = s.report_enemy_defeat(6, T.Kind.KOOPA)
	var h = s.report_enemy_defeat(7, T.Kind.GOOMBA)
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	for a in [g, k, h]:
		s.report_player_incoming_spawned(a.seq)
	var origin_g := PackedInt64Array([s.uid, g.seq, 5, T.Kind.GOOMBA])
	var defeats0: int = s.attacks.defeats
	var player_defeats0: int = s.attacks.player_defeats
	var rng0: int = s.attacks.player_rng.state
	var sent0: int = events_of(s, E.SENT).size()
	var defeated0: int = events_of(s, E.ENEMY_DEFEATED).size()
	var hist0: int = s.attacks.history.size()
	var res = S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, origin_g)
	check(res == null and g.state == A.State.RESOLVED and g.resolution == R.DEFEATED_BY_PLAYER, "the player killing an incoming Goomba resolves its attack, DEFEATED_BY_PLAYER")
	var ev: Array = events_of(s, E.INCOMING_RESOLVED).filter(func(e): return e.a == g.seq)
	check(ev.size() == 1 and ev[0].source == SRC.PLAYER and ev[0].cause == R.DEFEATED_BY_PLAYER, "the INCOMING_RESOLVED event carries who killed it")
	check(s.attacks.history.size() == hist0 and events_of(s, E.SENT).size() == sent0 and events_of(s, E.ENEMY_DEFEATED).size() == defeated0, "NO send: no new attack, no SENT, no ENEMY_DEFEATED")
	check(s.attacks.defeats == defeats0 and s.attacks.player_defeats == player_defeats0 and s.attacks.player_rng.state == rng0, "the defeat counts and the player's random stream are untouched")
	check(s.attacks.incoming_kill_sources == {SRC.PLAYER: 1} and s.attacks.defeat_sources.is_empty(), "it is counted as an incoming kill, not a native one")
	S.report_enemy_kill(T.DATA[T.Kind.KOOPA].script, SRC.ENEMY, PackedInt64Array([s.uid, k.seq, 6, T.Kind.KOOPA]))
	check(k.resolution == R.OTHER and s.attacks.history.size() == hist0, "killed by something else (an enemy): OTHER, and still no send")
	for source in [SRC.ENVIRONMENT, SRC.UNKNOWN]:
		var x = s.report_enemy_defeat(8, T.Kind.GOOMBA)
		for i in SYS.ACTIVATION_DELAY:
			s.step()
		s.report_player_incoming_spawned(x.seq)
		var hist1: int = s.attacks.history.size()
		S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, source, PackedInt64Array([s.uid, x.seq, 8, T.Kind.GOOMBA]))
		check(x.resolution == R.OTHER and s.attacks.history.size() == hist1, "killed by %s: OTHER, no send" % AT.name_of(source))
	# residue and stale identities do nothing
	var snap = s.attacks.snapshot()
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, origin_g)
	check(g.resolution == R.DEFEATED_BY_PLAYER and s.attacks.snapshot().history == snap.history, "residue (an attack already resolved, e.g. a woken Koopa) changes nothing")
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, PackedInt64Array([s.uid + 1000, h.seq, 7, T.Kind.GOOMBA]))
	check(h.state == A.State.ACTIVE, "another session's identity (a stale uid) changes nothing, even with the same seq")
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, PackedInt64Array([s.uid, h.seq, 9, T.Kind.GOOMBA]))
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, PackedInt64Array([s.uid, h.seq, 7, T.Kind.KOOPA]))
	check(h.state == A.State.ACTIVE, "an identity whose sender or kind does not match the attack changes nothing")
	var unspawned = s.report_enemy_defeat(9, T.Kind.GOOMBA)
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, PackedInt64Array([s.uid, unspawned.seq, 9, T.Kind.GOOMBA]))
	check(unspawned.state == A.State.ACTIVE, "an attack whose enemy was never spawned cannot be killed")
	S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER, PackedInt64Array([s.uid, 1, 2]))
	check(s.attacks.history.size() == snap.history.size() + 1, "a malformed identity is not a kill of anything")
	check(int(s.attacks.incoming_kill_sources.get(SRC.PLAYER, 0)) >= 4 and s.attacks.defeat_sources.is_empty(), "(all of them were counted as incoming kills)")
	# a native kill in the same session still sends
	s.attacks.targeting.target = 9
	var native = S.report_enemy_kill(T.DATA[T.Kind.GOOMBA].script, SRC.PLAYER)
	check(native != null and native.sender == 0 and s.attacks.defeat_sources == {SRC.PLAYER: 1}, "a native kill by the player still sends, exactly as before")
	S.clear()

func test_tag() -> void:
	var n := Node.new()
	check(AT.origin_of(n).is_empty() and not AT.is_incoming(n), "a native enemy has no origin")
	AT.tag_incoming(n, 77, 5, 12, T.Kind.KOOPA)
	var o: PackedInt64Array = AT.origin_of(n)
	check(o == PackedInt64Array([77, 5, 12, T.Kind.KOOPA]) and AT.is_incoming(n), "the tag is [session uid, seq, sender, kind]")
	var copy := n.duplicate()
	var co: PackedInt64Array = AT.origin_of(copy)
	co[1] = 99
	check(AT.origin_of(copy) == o and AT.origin_of(n) == o, "Node.duplicate (the Koopa that wakes from a shell) carries the same value, and changing a read copy changes neither")
	n.set_meta(AT.ORIGIN_META, PackedInt64Array([1, 2]))
	check(AT.origin_of(n).is_empty(), "a malformed tag reads as no origin")
	n.set_meta(AT.ORIGIN_META, "x")
	check(AT.origin_of(n).is_empty() and AT.origin_of(null).is_empty(), "so does a wrong type, or no node")
	n.free()
	copy.free()
	var u1: int = S.new(1).uid
	var u2: int = S.new(1).uid
	check(u2 > u1 and S.new(1).snapshot() == S.new(1).snapshot(), "every session has its own uid, and it is not part of the snapshot (twin sessions compare equal)")

# ------------------------------------------------------------------ whole simulated matches

## Plays matches with bots sending, a scripted "spawner" (the plan plus random real-world outcomes) and
## random transitions; checks at every step that nothing is dropped or doubled, and the R0 invariant.
func test_whole_matches() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var drift := 0
	var doubled := 0
	var r0_bad := 0
	var bad_causes := 0
	var spawned_total := 0
	var resolved_total := 0
	var transitions := 0
	for m in 12:
		var s = S.new(700 + m)
		S.current = s
		var plan = PLAN.new()
		var live := {} # seq -> true (a "node" in the level)
		var spawns := {}
		for frame in 60 * 260:
			plan.advance(DT, true)
			if frame % 60 == 0:
				s.step()
				if s.finished:
					break
			var rows: Array = s.get_incoming(0)
			for seq in live.keys():
				var still := rows.any(func(r): return int(r.seq) == seq and int(r.state) == A.State.ACTIVE)
				if not still:
					live.erase(seq)
				elif rng.randf() < 0.004:
					# a real outcome: the player kills it, something else does, or it despawns
					var roll := rng.randf()
					var a = s.attacks.history[seq]
					if roll < 0.6:
						S.report_enemy_kill(T.DATA[a.kind].script, SRC.PLAYER, PackedInt64Array([s.uid, seq, a.sender, a.kind]))
					elif roll < 0.8:
						S.report_enemy_kill(T.DATA[a.kind].script, SRC.ENEMY, PackedInt64Array([s.uid, seq, a.sender, a.kind]))
					else:
						s.resolve_player_incoming(seq, R.DESPAWNED)
			plan.sync(s.get_incoming(0))
			var unspawned_active: Array = s.get_incoming(0).filter(func(r): return int(r.state) == A.State.ACTIVE and int(r.spawned_tick) < 0).map(func(r): return int(r.seq))
			if plan.pending != unspawned_active:
				drift += 1
			var due: int = plan.next_due()
			if due >= 0 and rng.randf() < 0.7:
				if spawns.has(due):
					doubled += 1
				if s.report_player_incoming_spawned(due):
					spawns[due] = true
					live[due] = true
					spawned_total += 1
				plan.on_spawned(due)
			elif due >= 0:
				plan.on_failed(due) # nowhere to put it this time: held
			if rng.randf() < 0.0008:
				# a level transition: spawned ones end, the bridge is a new one
				s.resolve_player_spawned(R.LEVEL_TRANSITION)
				transitions += 1
				live.clear()
				plan = PLAN.new()
			if s.get_player().alive and rng.randf() < 0.00008:
				s.report_ko(0, S.KoCause.HAZARD)
		s.resolve_to_end()
		for a in s.attacks.history:
			if a.target == 0:
				resolved_total += 1
				if a.state != A.State.RESOLVED or a.resolution == R.NONE or a.resolution == R.EXPIRED:
					bad_causes += 1
				if a.resolution == R.LEVEL_TRANSITION and a.spawned_tick < 0:
					bad_causes += 1 # an attack that never appeared was erased by a transition
				if (a.resolution == R.DEFEATED_BY_PLAYER or a.resolution == R.DESPAWNED) and a.spawned_tick < 0:
					bad_causes += 1
		# R0: every player send follows its own native defeat, and no incoming kill made one
		for i in s.events.size():
			var e: Dictionary = s.events[i]
			if e.type == E.SENT and e.id == 0:
				if i == 0 or s.events[i - 1].type != E.ENEMY_DEFEATED or s.events[i - 1].id != 0:
					r0_bad += 1
		if s.attacks.player_defeats != int(s.attacks.defeat_sources.get(SRC.PLAYER, 0)):
			r0_bad += 1
	S.clear()
	check(drift == 0, "at every frame of 12 whole matches the plan's pending list is exactly the session's ACTIVE-unspawned list (nothing dropped, nothing invented)")
	check(doubled == 0 and spawned_total > 40, "no attack was ever spawned twice (%d spawns)" % spawned_total)
	check(bad_causes == 0 and resolved_total > 100, "every attack on the player ended with a real cause; none that never appeared was erased by one of %d transitions (%d attacks)" % [transitions, resolved_total])
	check(r0_bad == 0, "R0 over whole matches: every player send follows a native defeat by the player, and incoming kills never send")

# ------------------------------------------------------------------ presentation clock

func test_presentation_clock() -> void:
	var s = quiet(40, 7)
	var view = PRES.new(s)
	var a = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	view.update(0.1)
	var f = view.flight_of(a.seq)
	check(f != null, "(a line is in the air)")
	var p0: float = f.travel(view.clock)
	var c0: float = view.clock
	for i in 60:
		view.update(0.0) # what BattleScreen passes while the game is held
	check(view.clock == c0 and f.travel(view.clock) == p0 and view.flight_of(a.seq) == f, "while held, the presentation clock and the line stand still (60 frames)")
	for i in 10:
		view.update(DT)
	check(view.clock > c0 and f.travel(view.clock) > p0, "released, it resumes from where it stood")
	# the spawned field
	var t = quiet(41, 0)
	var tv = PRES.new(t)
	var b = t.report_enemy_defeat(3, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		t.step()
	tv.update(0.1)
	check(tv.player_incoming().size() == 1 and tv.player_incoming()[0].spawned == false, "the strip rows say an ACTIVE attack is still arriving")
	t.report_player_incoming_spawned(b.seq)
	tv.update(0.1)
	check(tv.player_incoming()[0].spawned == true, "...and once its enemy is in the level, that it is spawned")
	var screen_src := FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleScreen.gd")
	check(screen_src.contains("attack_view.update(0.0 if presentation_held() else") and screen_src.contains("return get_tree().paused or game_frozen"), "BattleScreen holds the presentation exactly when the tree is paused or the game window is frozen")
