extends SceneTree
## Deterministic checks of how an attack on the real player LOOKS (doc 48, milestone M6b), without the game: the four
## presentation phases (QUEUED, ARRIVING, IN_LEVEL, RESOLVED) as plain functions of the session's own state, the
## strip rows' phase / in_transit / fresh / arrive fields, one arrival mark per physical spawn, the fading icons of
## just-resolved attacks, pause (a held clock freezes every fade), round cleanup, and the strip's model (merged
## list, per-phase counts). The strip's `rows` and `counts` stay exactly the session's unresolved attacks.
## The real game (the spawner, the arrival effect, the real strip on the real screen) is checked in
## tests/battle_arrival_game_test.gd and, under GL, tests/battle_arrival_render_test.gd.
##   godot --headless --path . -s tests/battle_incoming_view_test.gd

const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

var failures := 0
var S # BattleSession
var T # BattleEnemyType
var A # BattleAttack
var E # BattleSession.EventType
var R # BattleAttack.Resolution
var P # BattleAttackPresentation
var F # BattleAttackFlight
var STRIP # BattleIncomingStrip
var FixedPolicy
var GOOMBA := 1
var KOOPA := 2
var PH # BattleAttackPresentation.Phase

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	T = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	A = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	P = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
	F = load("res://Scripts/Classes/Battle/BattleAttackFlight.gd")
	STRIP = load("res://Scripts/Classes/Battle/BattleIncomingStrip.gd")
	E = S.EventType
	R = A.Resolution
	PH = P.Phase
	GOOMBA = T.Kind.GOOMBA
	KOOPA = T.Kind.KOOPA
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()

	test_phase_table()
	test_phase_lifecycle()
	test_in_transit_and_fresh_follow_the_line()
	test_ordering_with_several()
	test_phases_match_the_session_in_whole_matches()
	test_one_arrival_per_spawn()
	test_resolved_icons_fade()
	test_no_fade_when_everything_ends()
	test_pause_holds_every_fade()
	test_round_cleanup()
	test_strip_model()
	test_strip_redraws_while_icons_travel()
	test_late_creation_is_silent()
	test_animating_flag()
	test_presentation_is_read_only()

	if failures > 0:
		printerr("%d Battle incoming view test(s) failed" % failures)
	else:
		print("All Battle incoming view tests passed")
	quit(1 if failures > 0 else 0)

# ---- helpers -----------------------------------------------------------------------------------------

## A session whose bots send nothing on their own; every send goes to the real player (id 0).
func make_session(seed_value := 7):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	var p = FixedPolicy.new()
	p.target = 0
	s.attacks.targeting = p
	return s

func steps(s, n: int) -> void:
	for i in n:
		s.step()

## The authoritative phase of every unresolved attack aimed at the player, in send order, read from the session only.
func auth_phases(s) -> Array:
	var out := []
	for a in s.attacks.history:
		if a.target != 0 or a.state == A.State.RESOLVED:
			continue
		if a.state == A.State.QUEUED:
			out.append(PH.QUEUED)
		elif a.spawned_tick < 0:
			out.append(PH.ARRIVING)
		else:
			out.append(PH.IN_LEVEL)
	return out

func row_phases(v) -> Array:
	return v.player_incoming().map(func(r): return r.phase)

func close(a: float, b: float, eps := 0.02) -> bool:
	return absf(a - b) <= eps

## The lowest ACTIVE attack on the player whose enemy is not in the level yet (the one the spawner delivers next).
func next_to_spawn(s):
	for a in s.attacks.history:
		if a.target == 0 and a.state == A.State.ACTIVE and a.spawned_tick < 0:
			return a
	return null

# ---- tests --------------------------------------------------------------------------------------------

func test_phase_table() -> void:
	print("-- the phase is a function of the authoritative state")
	check(P.phase_of(A.State.QUEUED, false) == PH.QUEUED, "QUEUED -> QUEUED")
	check(P.phase_of(A.State.ACTIVE, false) == PH.ARRIVING, "ACTIVE, enemy not in the level -> ARRIVING")
	check(P.phase_of(A.State.ACTIVE, true) == PH.IN_LEVEL, "ACTIVE, enemy in the level -> IN_LEVEL")
	check(P.phase_of(A.State.RESOLVED, false) == PH.RESOLVED and P.phase_of(A.State.RESOLVED, true) == PH.RESOLVED, "RESOLVED -> RESOLVED, spawned or not")
	check(P.phase_of(A.State.QUEUED, true) == PH.QUEUED, "a QUEUED attack is never shown as in the level")
	check(P.phase_name(PH.ARRIVING) == "ARRIVING" and P.phase_name(99) == "?", "phases have names")

func test_phase_lifecycle() -> void:
	print("-- one attack: QUEUED -> ARRIVING -> IN_LEVEL -> RESOLVED")
	var s = make_session()
	var v = P.new(s)
	var a = s.report_enemy_defeat(5, GOOMBA)
	v.update(0.0)
	var rows = v.player_incoming()
	check(rows.size() == 1 and rows[0].seq == a.seq and rows[0].phase == PH.QUEUED and not rows[0].spawned, "sent: one row, QUEUED, not spawned")
	check(v.player_phase_counts() == Vector3i(1, 0, 0) and v.counts(0) == Vector2i(1, 0), "(1 queued, 0 arriving, 0 in level)")
	steps(s, 3)
	v.update(0.0)
	check(a.state == A.State.ACTIVE and row_phases(v) == [PH.ARRIVING], "ACTIVE but not spawned: ARRIVING")
	check(v.player_phase_counts() == Vector3i(0, 1, 0) and v.counts(0) == Vector2i(0, 1), "(0, 1, 0): the session's one ACTIVE is the one arriving")
	check(v.player_incoming()[0].flash > 0.9 and v.player_incoming()[0].arrive == 0.0, "it flashes for becoming ACTIVE and has no arrival mark yet")
	check(s.report_player_incoming_spawned(a.seq), "(its enemy appears in the level)")
	v.update(0.0)
	rows = v.player_incoming()
	check(row_phases(v) == [PH.IN_LEVEL] and rows[0].spawned and rows[0].state == A.State.ACTIVE, "spawned: IN_LEVEL (still ACTIVE for the session)")
	check(v.player_phase_counts() == Vector3i(0, 0, 1) and v.counts(0) == Vector2i(0, 1), "(0, 0, 1): `counts` still says ACTIVE 1")
	check(close(rows[0].arrive, 1.0), "its arrival mark starts full at the moment it appears (%.2f)" % rows[0].arrive)
	v.update(P.SPAWN_FLASH * 0.5)
	check(close(v.player_incoming()[0].arrive, 0.5, 0.05), "...fades with time (%.2f at half)" % v.player_incoming()[0].arrive)
	v.update(P.SPAWN_FLASH)
	check(v.player_incoming()[0].arrive == 0.0 and row_phases(v) == [PH.IN_LEVEL], "...is gone after SPAWN_FLASH, and it stays IN_LEVEL")
	check(s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER), "(the player defeats it)")
	v.update(0.0)
	check(v.player_incoming().is_empty() and v.player_phase_counts() == Vector3i.ZERO and v.counts(0) == Vector2i.ZERO, "resolved: it is no longer a row, and no count includes it")
	var g = v.player_resolved()
	check(g.size() == 1 and g[0].seq == a.seq and g[0].cause == R.DEFEATED_BY_PLAYER and g[0].spawned and close(g[0].fade, 1.0), "...but its icon is remembered, to fade")

func test_in_transit_and_fresh_follow_the_line() -> void:
	print("-- an icon enters the bar at the send; the 'new' mark starts there (doc 54: no line to wait for)")
	var s = make_session()
	var v = P.new(s)
	var a = s.report_enemy_defeat(5, GOOMBA)
	v.update(0.0)
	var r = v.player_incoming()[0]
	check(not r.in_transit and r.fresh > 0.95 and r.phase == PH.QUEUED and r.age == 0.0, "at the send: the icon is in the bar (never in transit), the 'new' mark is full, QUEUED")
	v.update(P.RECEIVE_FLASH * 0.5)
	check(v.player_incoming()[0].fresh > 0.4 and v.player_incoming()[0].fresh < 0.6, "the mark fades from there")
	v.update(P.RECEIVE_FLASH)
	check(v.player_incoming()[0].fresh == 0.0, "...and is gone after RECEIVE_FLASH")
	check(v.flights.is_empty() and v.flight_of(a.seq) == null, "no flight exists for a bot's send: nothing outlives the icon's own flash")
	var s2 = make_session()
	var v2 = P.new(s2)
	s2.report_enemy_defeat(5, GOOMBA)
	v2.update(0.0)
	v2.update(0.1)
	check(v2.is_animating() and v2.player_incoming()[0].fresh > 0.0 and v2.player_incoming()[0].fresh < 1.0, "the strip keeps redrawing while the mark fades (%.2f)" % v2.player_incoming()[0].fresh)
	# a send that is not for the player has no strip row at all
	var s3 = S.new(3)
	s3.attacks.bots_send = false
	var p3 = FixedPolicy.new()
	p3.target = 9
	s3.attacks.targeting = p3
	var v3 = P.new(s3)
	s3.report_enemy_defeat(5, GOOMBA)
	v3.update(0.1)
	check(v3.player_incoming().is_empty() and v3.player_phase_counts() == Vector3i.ZERO and v3.player_resolved().is_empty(), "an attack on a bot is never a strip row, a phase count or a fading icon")

func test_ordering_with_several() -> void:
	print("-- several at once: in level, then arriving, then queued; counts add up")
	var s = make_session()
	var v = P.new(s)
	for i in 6:
		s.report_enemy_defeat(3 + i, GOOMBA if i % 2 == 0 else KOOPA)
	steps(s, 3)
	for i in 2:
		check(s.report_player_incoming_spawned(next_to_spawn(s).seq), "(spawn %d)" % [i + 1])
	v.update(0.0)
	check(row_phases(v) == [PH.IN_LEVEL, PH.IN_LEVEL, PH.ARRIVING, PH.QUEUED, PH.QUEUED, PH.QUEUED], "two in the level, one arriving, three queued, in that order")
	check(v.player_phase_counts() == Vector3i(3, 1, 2), "(3 queued, 1 arriving, 2 in level)")
	var c: Vector2i = v.counts(0)
	var pc: Vector3i = v.player_phase_counts()
	check(c.x == pc.x and c.y == pc.y + pc.z and pc.x + pc.y + pc.z == v.player_incoming().size(), "the phase counts split `counts` exactly: queued, and ACTIVE = arriving + in level")
	check(row_phases(v) == auth_phases(s), "and match the session's own state, attack by attack")
	check(v.player_incoming().map(func(r): return r.seq) == s.get_incoming(0).map(func(r): return r.seq), "the rows are the session's incoming queue, in its order")
	# the first one ends: the arriving one is next to appear, the queue moves up when the session activates one
	s.resolve_player_incoming(0, R.DEFEATED_BY_PLAYER)
	steps(s, 1)
	v.update(0.0)
	check(row_phases(v) == auth_phases(s) and v.player_phase_counts().y + v.player_phase_counts().z == s.get_incoming(0).filter(func(r): return r.state == A.State.ACTIVE).size(), "after a resolve and a tick the phases still match the session")

func test_phases_match_the_session_in_whole_matches() -> void:
	print("-- whole matches: the phases equal the session's at every tick")
	var mismatches := 0
	var order_breaks := 0
	var checked := 0
	var saw := {PH.QUEUED: 0, PH.ARRIVING: 0, PH.IN_LEVEL: 0}
	for seed_value in 12:
		var s = S.new(100 + seed_value)
		var p = FixedPolicy.new()
		p.target = 0
		s.attacks.targeting = p # bots send on their own, all of it to the real player
		var v = P.new(s)
		var rng := RandomNumberGenerator.new()
		rng.seed = 900 + seed_value
		for tick in 400:
			if s.finished:
				break
			s.step()
			# the world, as the spawner and the game would: spawn the next one in order, sometimes; resolve sometimes
			var nxt = next_to_spawn(s)
			if nxt != null and rng.randf() < 0.5:
				s.report_player_incoming_spawned(nxt.seq)
			for a in s.attacks.history:
				if a.target == 0 and a.state == A.State.ACTIVE and a.spawned_tick >= 0 and rng.randf() < 0.12:
					s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER if rng.randf() < 0.7 else R.DESPAWNED)
			v.update(0.25)
			var got := row_phases(v)
			var want := auth_phases(s)
			checked += 1
			if got != want:
				mismatches += 1
			var last := 99 # IN_LEVEL (2) runs first, then ARRIVING (1), then QUEUED (0): never rising
			for ph in got:
				saw[ph] += 1
				if ph > last:
					order_breaks += 1
				last = ph
			var pc: Vector3i = v.player_phase_counts()
			if pc.x + pc.y + pc.z != got.size() or Vector2i(pc.x, pc.y + pc.z) != v.counts(0):
				mismatches += 1
	check(checked > 1000 and mismatches == 0, "the strip's phases equal the session's at every tick (%d ticks, %d mismatches)" % [checked, mismatches])
	check(order_breaks == 0, "an icon later in the strip is never in an earlier phase than one before it")
	check(saw[PH.QUEUED] > 0 and saw[PH.ARRIVING] > 0 and saw[PH.IN_LEVEL] > 0, "(the matches visited every phase: %s)" % [saw])

func test_one_arrival_per_spawn() -> void:
	print("-- one arrival mark per physical spawn")
	var s = make_session()
	var v = P.new(s)
	var a = s.report_enemy_defeat(5, GOOMBA)
	steps(s, 3)
	check(s.report_player_incoming_spawned(a.seq), "the first spawn report is accepted")
	check(not s.report_player_incoming_spawned(a.seq) and not s.report_player_incoming_spawned(a.seq), "a second and a third report for the same attack are refused")
	var spawned_events: Array = s.events.filter(func(e): return e.type == E.INCOMING_SPAWNED)
	check(spawned_events.size() == 1, "the log has one INCOMING_SPAWNED for it")
	v.update(0.0)
	var at: float = v.records[a.seq].spawned_at
	var count: int = v.trace_count
	v.update(0.3)
	# even a repeated event in the log (it cannot happen, the session refuses) would not restart the mark
	s.events.append(spawned_events[0].duplicate())
	v.update(0.0)
	check(v.records[a.seq].spawned_at == at and v.trace_count == count, "a repeated event does not restart the mark or count as a new presentation event")
	check(close(v.player_incoming()[0].arrive, 1.0 - 0.3 / P.SPAWN_FLASH, 0.05), "the mark is still fading from the first spawn (%.2f)" % v.player_incoming()[0].arrive)
	# a spawn the session would refuse never becomes a mark
	var s2 = make_session()
	var v2 = P.new(s2)
	var q = s2.report_enemy_defeat(5, GOOMBA)
	check(not s2.report_player_incoming_spawned(q.seq), "an attack that is only QUEUED cannot be spawned")
	v2.update(0.0)
	check(v2.records[q.seq].spawned_at < 0.0 and v2.player_incoming()[0].arrive == 0.0 and v2.player_incoming()[0].phase == PH.QUEUED, "...so it has no mark and is not IN_LEVEL")
	# three attacks: three spawns, each its own mark, in order
	var s3 = make_session()
	var v3 = P.new(s3)
	for i in 3:
		s3.report_enemy_defeat(3 + i, GOOMBA)
	steps(s3, 3)
	var marked_after_each := []
	var spawned_seqs := []
	for i in 3:
		var sq: int = next_to_spawn(s3).seq
		spawned_seqs.append(sq)
		s3.report_player_incoming_spawned(sq)
		v3.update(0.0)
		marked_after_each.append(v3.player_incoming().filter(func(r): return r.arrive > 0.0).map(func(r): return r.seq))
		v3.update(P.SPAWN_FLASH + 0.1) # let this mark finish before the next spawn
	check(marked_after_each == [[spawned_seqs[0]], [spawned_seqs[1]], [spawned_seqs[2]]], "each spawn marks exactly its own attack, once (marked right after each spawn: %s)" % [marked_after_each])
	check(s3.events.filter(func(e): return e.type == E.INCOMING_SPAWNED).size() == 3 and v3.player_incoming().all(func(r): return r.arrive == 0.0), "(three spawns, three events, no mark left over)")

func test_resolved_icons_fade() -> void:
	print("-- a resolved attack's icon fades where it was")
	for cause in [R.DEFEATED_BY_PLAYER, R.DESPAWNED, R.LEVEL_TRANSITION, R.OTHER]:
		var s = make_session()
		var v = P.new(s)
		var a = s.report_enemy_defeat(5, KOOPA)
		steps(s, 3)
		s.report_player_incoming_spawned(a.seq)
		s.resolve_player_incoming(a.seq, cause)
		v.update(0.0)
		var g = v.player_resolved()
		check(g.size() == 1 and g[0].cause == cause and g[0].kind == KOOPA, "%s: one fading icon with that cause" % A.resolution_name(cause))
		v.update(P.RESOLVE_FADE * 0.5)
		check(close(v.player_resolved()[0].fade, 0.5, 0.05), "  half way: fade %.2f" % v.player_resolved()[0].fade)
		v.update(P.RESOLVE_FADE)
		check(v.player_resolved().is_empty(), "  and it is gone after RESOLVE_FADE")
	# an attack that never appeared can end too (carried, then a level change cannot resolve it, but the round can't either: only through the game)
	var s = make_session()
	var v = P.new(s)
	var a = s.report_enemy_defeat(5, GOOMBA)
	steps(s, 3)
	s.resolve_player_incoming(a.seq, R.OTHER)
	v.update(0.0)
	check(v.player_resolved().size() == 1 and not v.player_resolved()[0].spawned, "an attack that ended before its enemy appeared fades too, and says it never appeared")
	# several at once: they keep send order and none is lost
	var s2 = make_session()
	var v2 = P.new(s2)
	for i in 3:
		s2.report_enemy_defeat(3 + i, GOOMBA)
	steps(s2, 3)
	for i in 3:
		s2.report_player_incoming_spawned(next_to_spawn(s2).seq)
	check(s2.resolve_player_spawned(R.LEVEL_TRANSITION) == 3, "(a level change ends all three)")
	v2.update(0.0)
	check(v2.player_resolved().map(func(r): return r.seq) == [0, 1, 2] and v2.player_incoming().is_empty(), "all three fade, in send order, and none stays a row")
	# a resolved attack is not resurrected by anything later
	v2.update(1.0)
	check(v2.player_resolved().is_empty() and v2.records.size() == 3, "(and they are gone, though their records stay for the log)")

func test_no_fade_when_everything_ends() -> void:
	print("-- the player out or the round over clears the strip at once: no fading icons")
	var s = make_session()
	var v = P.new(s)
	for i in 3:
		s.report_enemy_defeat(3 + i, GOOMBA)
	steps(s, 3)
	s.report_player_incoming_spawned(next_to_spawn(s).seq)
	s.report_ko(0, S.KoCause.HAZARD)
	v.update(0.0)
	var causes: Array = s.attacks.history.map(func(a): return a.resolution)
	check(causes.all(func(c): return c == R.TARGET_OUT), "(the KO resolved every attack as TARGET_OUT)")
	check(v.player_incoming().is_empty() and v.player_resolved().is_empty(), "the strip is empty and nothing fades: it is the end of the player's round")
	var s2 = make_session()
	var v2 = P.new(s2)
	for i in 3:
		s2.report_enemy_defeat(3 + i, GOOMBA)
	steps(s2, 3)
	s2.report_player_incoming_spawned(next_to_spawn(s2).seq)
	s2.end_round()
	v2.update(0.0)
	check(s2.attacks.history.all(func(a): return a.resolution == R.ROUND_ENDED), "(ending the round resolved them as ROUND_ENDED)")
	check(v2.player_incoming().is_empty() and v2.player_resolved().is_empty(), "nothing fades at the round's end either")

func test_pause_holds_every_fade() -> void:
	print("-- pause: a held presentation clock freezes every fade, and resuming continues")
	var s = make_session()
	var v = P.new(s)
	var a = s.report_enemy_defeat(5, GOOMBA)
	var b = s.report_enemy_defeat(6, KOOPA)
	steps(s, 3)
	v.update(0.35)
	s.report_player_incoming_spawned(a.seq)
	s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER)
	s.report_player_incoming_spawned(b.seq)
	v.update(0.1)
	var rows_before = v.player_incoming()
	var ghosts_before = v.player_resolved()
	check(rows_before[0].arrive > 0.0 and rows_before[0].flash > 0.0 and ghosts_before[0].fade > 0.0, "(something of each kind is mid-fade)")
	for i in 120: # two seconds of a paused game: the screen advances the presentation by 0
		v.update(0.0)
	check(v.player_incoming() == rows_before and v.player_resolved() == ghosts_before, "2 s held: every row field and every fading icon is exactly as it was")
	check(v.is_animating(), "(still animating: the strip keeps its place on screen)")
	v.update(0.2)
	var after = v.player_incoming()
	check(after[0].arrive < rows_before[0].arrive and v.player_resolved()[0].fade < ghosts_before[0].fade, "resuming continues from where it stopped")
	v.update(1.0)
	check(v.player_resolved().is_empty() and v.player_incoming()[0].arrive == 0.0, "...and finishes normally")

func test_round_cleanup() -> void:
	print("-- round cleanup: nothing of one round survives into the next")
	var s = make_session()
	var v = P.new(s)
	for i in 3:
		s.report_enemy_defeat(3 + i, GOOMBA)
	steps(s, 3)
	s.report_player_incoming_spawned(next_to_spawn(s).seq)
	s.resolve_player_incoming(0, R.DEFEATED_BY_PLAYER)
	v.update(0.0)
	check(not v.player_resolved().is_empty() and not v.player_incoming().is_empty(), "(a fading icon and live rows exist)")
	v.clear_flights()
	check(v.player_resolved().is_empty(), "clearing the lines also clears the fading icons")
	check(v.player_incoming().size() == 2 and v.player_phase_counts().x + v.player_phase_counts().y + v.player_phase_counts().z == 2, "...while the rows and counts keep mirroring the session")
	var s2 = make_session(8)
	var v2 = P.new(s2)
	check(v2.records.is_empty() and v2.player_incoming().is_empty() and v2.player_resolved().is_empty() and v2.player_phase_counts() == Vector3i.ZERO and v2.signature() == "0:0", "a new round's presentation starts empty")
	check(not v2.is_animating(), "...and idle")
	var strip = STRIP.new(null)
	strip.bind(v, null)
	check(strip.rows.size() == 2 and strip.items.size() == 2, "(the strip shows what is left)")
	strip.bind(null, null)
	check(strip.rows.is_empty() and strip.ghosts.is_empty() and strip.items.is_empty() and strip.phases == Vector3i.ZERO and strip.counts == Vector2i.ZERO, "unbinding the strip clears rows, fading icons, items and counts")

func test_strip_model() -> void:
	print("-- the strip's model")
	var s = make_session()
	var v = P.new(s)
	for i in 5:
		s.report_enemy_defeat(3 + i, GOOMBA if i != 1 else KOOPA)
	steps(s, 3)
	s.report_player_incoming_spawned(next_to_spawn(s).seq)
	s.report_player_incoming_spawned(next_to_spawn(s).seq)
	v.update(0.35)
	s.resolve_player_incoming(0, R.DEFEATED_BY_PLAYER)
	v.update(0.05)
	var strip = STRIP.new(null)
	strip.bind(v, null)
	strip.sync()
	check(strip.rows.map(func(r): return r.seq) == s.get_incoming(0).map(func(r): return r.seq) and strip.counts == v.counts(0), "`rows` and `counts` are exactly the session's unresolved attacks")
	check(not strip.rows.any(func(r): return r.seq == 0) and strip.ghosts.size() == 1 and strip.ghosts[0].seq == 0, "...a fading icon is never among them")
	check(strip.items.size() == strip.rows.size() and not strip.items.any(func(i): return i.get("ghost", false)), "`items` (what is drawn) is the rows: an ended attack's icon is not drawn fading (the reference removes it)")
	check(strip.items.map(func(i): return i.seq) == [1, 2, 3, 4], "...in send order")
	check(strip.phases == Vector3i(2, 1, 1), "the phases are (queued, arriving, in level) = %s" % [strip.phases])
	# merged(): the rows alone (ghosts are not drawn any more)
	var rows: Array[Dictionary] = [{"seq": 1, "phase": PH.IN_LEVEL}, {"seq": 5, "phase": PH.QUEUED}]
	var ghosts: Array[Dictionary] = [{"seq": 3, "cause": R.OTHER, "fade": 0.5}]
	var m = STRIP.merged(rows, ghosts)
	check(m.map(func(i): return i.seq) == [1, 5] and not m[0].has("ghost"), "merged(): the live rows in send order; a fading icon is not among them")
	check(rows[0].keys() == ["seq", "phase"] and ghosts[0].keys() == ["seq", "cause", "fade"], "(merged() copies: neither input is changed)")
	var none: Array[Dictionary] = []
	check(STRIP.merged(none, none).is_empty() and STRIP.merged(rows, none).size() == 2 and STRIP.merged(none, ghosts).is_empty(), "(empty inputs)")
	# the count text
	check(STRIP.legend(Vector3i.ZERO).is_empty(), "no attacks: no count text")
	var lg = STRIP.legend(Vector3i(3, 1, 2))
	check(lg.map(func(t): return t.text) == ["IN LEVEL 2", "ARRIVING 1", "QUEUED 3"], "the counts, in the order the icons run: %s" % [lg.map(func(t): return t.text)])
	check(lg.map(func(t): return t.phase) == [PH.IN_LEVEL, PH.ARRIVING, PH.QUEUED], "...each tied to its phase (its colour)")
	check(STRIP.legend(Vector3i(0, 2, 0)).map(func(t): return t.text) == ["ARRIVING 2"], "only phases that have any are listed")
	check(STRIP.legend(Vector3i(3, 1, 2), true).map(func(t): return t.text) == ["LVL 2", "ARR 1", "Q 3"], "a crowded strip uses the short forms")
	check(STRIP.legend(Vector3i(0, 0, 4)).map(func(t): return t.text) == ["IN LEVEL 4"], "(a count is the number of attacks, not of icons)")

func test_strip_redraws_while_icons_travel() -> void:
	print("-- the strip redraws every frame while an icon travels, and rests once all have arrived")
	var s = make_session()
	var v = P.new(s)
	s.report_enemy_defeat(3, GOOMBA)
	s.report_enemy_defeat(4, KOOPA)
	v.update(0.0)
	var strip = STRIP.new(null)
	strip.size = Vector2(257.0, 12.0)
	strip.bind(v, null)
	var sigs := []
	for i in 40:
		v.update(1.0 / 60.0)
		strip.sync()
		sigs.append(strip._signature)
	# (a negative signature is "something moves": it is built from the engine's frame count, so it differs on every real frame)
	check(sigs.all(func(g): return g < 0), "40 frames of travel: every sync reports motion, so the strip is redrawn on every frame (%d of %d)" % [sigs.filter(func(g): return g < 0).size(), sigs.size()])
	var xs: PackedFloat32Array = STRIP.place_all(strip.items, strip.size.x)
	check(xs[0] < STRIP.entry_x(strip.size.x) - 5.0 and absf(strip._shown[int(strip.items[0].seq)] - xs[0]) < 0.01, "...and the drawn icon is on its way, where place_all puts it (%.1f from %.1f)" % [xs[0], STRIP.entry_x(strip.size.x)])
	for i in 60 * 5:
		v.update(1.0 / 60.0)
		strip.sync()
	var a: int = strip._signature
	v.update(1.0 / 60.0)
	strip.sync()
	check(strip._signature == a and a >= 0, "once every icon is in its place and still, the strip stops redrawing (signature %d, steady)" % a)

func test_late_creation_is_silent() -> void:
	print("-- a presentation made mid-round shows no lines and no fading icons")
	var s = make_session()
	var a = s.report_enemy_defeat(5, GOOMBA)
	var b = s.report_enemy_defeat(6, GOOMBA)
	steps(s, 3)
	s.report_player_incoming_spawned(a.seq)
	s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER)
	var v = P.new(s)
	check(v.flights.is_empty() and v.player_resolved().is_empty(), "no line in the air and no fading icon for what already happened")
	var rows = v.player_incoming()
	check(rows.size() == 1 and rows[0].seq == b.seq and rows[0].phase == PH.ARRIVING and not rows[0].in_transit, "the live attack is there in its true phase, not 'in transit'")
	check(v.player_phase_counts() == Vector3i(0, 1, 0), "(0, 1, 0)")

func test_animating_flag() -> void:
	print("-- the strip animates exactly while something is timed or arriving")
	var s = make_session()
	var v = P.new(s)
	check(not v.is_animating(), "idle: nothing to animate")
	var a = s.report_enemy_defeat(5, GOOMBA)
	v.update(0.0)
	check(v.is_animating(), "a line in the air")
	v.update(5.0)
	check(not v.is_animating(), "everything settled: idle again (a QUEUED attack just waits)")
	steps(s, 3)
	v.update(5.0)
	check(v.is_animating(), "ARRIVING pulses, so the strip keeps redrawing for as long as an attack is arriving")
	s.report_player_incoming_spawned(a.seq)
	v.update(0.0)
	check(v.is_animating(), "the arrival mark is timed")
	v.update(P.SPAWN_FLASH + P.ACTIVATION_FLASH)
	check(not v.is_animating(), "IN_LEVEL is steady: idle")
	s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER)
	v.update(0.0)
	check(v.is_animating(), "a fading icon is timed")
	v.update(P.RESOLVE_FADE + 0.1)
	check(not v.is_animating(), "...and idle when it is gone")

func test_presentation_is_read_only() -> void:
	print("-- the new presentation can change nothing in the session")
	var plain = make_session(21)
	var watched = make_session(21)
	var v = P.new(watched)
	var strip = STRIP.new(null)
	strip.bind(v, null)
	var same := true
	for tick in 300:
		if plain.finished or watched.finished:
			break
		plain.step()
		watched.step()
		for s in [plain, watched]:
			var nxt = next_to_spawn(s)
			if nxt != null and tick % 7 == 0:
				s.report_player_incoming_spawned(nxt.seq)
			for a in s.attacks.history:
				if a.target == 0 and a.state == A.State.ACTIVE and a.spawned_tick >= 0 and (tick + a.seq) % 11 == 0:
					s.resolve_player_incoming(a.seq, R.DEFEATED_BY_PLAYER)
		v.update(0.1)
		strip.sync()
		if plain.snapshot() != watched.snapshot() or plain.events.size() != watched.events.size():
			same = false
			break
	check(same, "300 ticks with the presentation and the strip reading every frame: the session's snapshot and event log are identical to a session nobody watched")
	var src := FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleIncomingStrip.gd") + FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleArrivalEffect.gd")
	var calls := ["report_", "resolve_", "mark_spawned", ".attacks.", "session."]
	var found := calls.filter(func(c): return src.contains(c) and not src.contains("# " + c))
	check(found.is_empty(), "the strip and the effect never name a mutating session call (%s)" % [found])
