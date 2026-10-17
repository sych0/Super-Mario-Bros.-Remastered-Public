extends SceneTree
## Deterministic checks of the VISIBLE side of the Battle attack loop: BattleAttackPresentation (events ->
## lines, counts, the real player's incoming list), BattleAttackGeometry (where a line starts and ends),
## the incoming enemies in the opponents' previews (BattlePreviewTrack / BattlePreviewInvader) and that
## none of it can change the session. Needs the imported project (the real World 1-1 art and sketch).
## The screen itself (strip, layer, panes, the real game) is checked in tests/battle_attack_screen_test.gd.
##   godot --headless --path . -s tests/battle_attack_view_test.gd

const LEVEL := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""
const PRESENTATION_FILES := ["BattleAttackPresentation", "BattleAttackFlight", "BattleAttackGeometry", "BattleAttackLayer",
	"BattleIncomingStrip", "BattleEnemyIcon", "BattlePreviewInvader"]

var failures := 0
var S # BattleSession
var T # BattleEnemyType
var A # BattleAttack
var E # BattleSession.EventType
var R # BattleAttack.Resolution
var P # BattleAttackPresentation
var F # BattleAttackFlight
var SS # BattleSendStyle
var GEO # BattleAttackGeometry
var LAYOUT # BattleHudLayout
var K # BattleLevelSketch
var AS # BattlePreviewAssets
var TR # BattlePreviewTrack
var D # BattlePreviewDriver
var INV # BattlePreviewInvader
var FixedPolicy
var GOOMBA := 1
var KOOPA := 2
var layout := {}

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
	SS = load("res://Scripts/Classes/Battle/BattleSendStyle.gd")
	GEO = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	K = load("res://Scripts/Classes/Battle/BattleLevelSketch.gd")
	AS = load("res://Scripts/Classes/Battle/BattlePreviewAssets.gd")
	TR = load("res://Scripts/Classes/Battle/BattlePreviewTrack.gd")
	D = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	INV = load("res://Scripts/Classes/Battle/BattlePreviewInvader.gd")
	E = S.EventType
	R = A.Resolution
	GOOMBA = T.Kind.GOOMBA
	KOOPA = T.Kind.KOOPA
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	layout = LAYOUT.compute()

	test_geometry()
	test_send_rect()
	test_flights_from_sends()
	test_simultaneous_sends()
	test_counts_follow_the_session()
	test_target_out_and_round_end()
	test_late_creation()
	test_presentation_is_read_only()
	test_deterministic_replay()
	test_driver_replay()
	test_flight_timing()
	test_invaders_on_a_track()
	test_invaders_follow_the_session()
	test_ko_clears_invaders()
	test_twin_sessions()
	test_no_attack_visuals_when_off()

	if failures > 0:
		printerr("%d Battle attack view test(s) failed" % failures)
	else:
		print("All Battle attack view tests passed")
	quit(1 if failures > 0 else 0)

# ---- helpers -----------------------------------------------------------------------------------------

## A session whose bots send nothing on their own, so a test controls exactly what is sent. `target` >= 0
## makes every send go to that contestant.
func make_session(seed_value := 7, target := -1):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false # nothing that is sent can change how a bot plays
	if target >= 0:
		var p = FixedPolicy.new()
		p.target = target
		s.attacks.targeting = p
	return s

func auth_counts(s, id: int) -> Vector2i:
	var q := 0
	var a := 0
	for d in s.get_incoming(id):
		if d.state == A.State.ACTIVE:
			a += 1
		else:
			q += 1
	return Vector2i(q, a)

func rows_of(list: Array) -> Array:
	var out := []
	for r in list:
		out.append([r.seq, r.state])
	return out

func code_of(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var out := PackedStringArray()
	for line in text.split("\n"):
		var cut := line.find("#")
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)

# ---- geometry ----------------------------------------------------------------------------------------

func test_geometry() -> void:
	print("-- geometry")
	var game: Rect2 = layout.game
	var ok_pane := true
	for id in range(1, 35):
		var rect: Rect2 = GEO.rect_of(layout, id)
		if rect != layout.slots[id - 1] or GEO.center_of(layout, id) != rect.get_center():
			ok_pane = false
	check(ok_pane, "an opponent's end of a line is the middle of its own pane (all 34)")
	check(GEO.rect_of(layout, 0) == game, "the real player's end is the game window")
	var enters := true
	var pill: Rect2 = layout.pill
	for id in range(1, 35):
		var from: Vector2 = GEO.launch_point(layout, id, 0)
		var to: Vector2 = GEO.landing_point(layout, id, 0)
		if not (layout.slots[id - 1] as Rect2).has_point(from) or not to.is_equal_approx(GEO.pill_point(layout, GEO.center_of(layout, id))):
			enters = false
		if not (is_equal_approx(to.x, pill.position.x) or is_equal_approx(to.x, pill.end.x)) or not is_equal_approx(to.y, pill.position.y + GEO.PILL_LINE_DROP) or game.has_point(to):
			enters = false
		if (to.x < pill.get_center().x) != (GEO.center_of(layout, id).x < game.get_center().x):
			enters = false
	check(enters, "a red line to the player starts inside the sender's pane and ends on the WATCH OUT! pill's near edge, on the sender's side of the window (all 34)")
	check(GEO.send_start(layout) == game.get_center() and GEO.send_start(layout) == Vector2(240, 120), "the player's reticle starts at the middle of the game window (240, 120)")

func test_send_rect() -> void:
	print("-- the reticle's flight geometry (doc 54)")
	var game: Rect2 = layout.game
	var ok := true
	var linear := true
	var inside := true
	var start_size := true
	for id in range(1, 35):
		var pane: Rect2 = layout.slots[id - 1]
		var r0: Rect2 = GEO.send_rect(layout, id, 0.0)
		var r1: Rect2 = GEO.send_rect(layout, id, 1.0)
		if not r0.get_center().is_equal_approx(game.get_center()) or not r1.is_equal_approx(GEO.rest_box(pane)) or not r1.get_center().is_equal_approx(pane.get_center()):
			ok = false
		if not r0.size.is_equal_approx(Vector2(32.0, 41.0)):
			start_size = false
		var step0 := Vector2.ZERO
		for k in 16:
			var r: Rect2 = GEO.send_rect(layout, id, k / 15.0)
			# frame k of 15 is exactly k/15 of the way along the straight line, the same distance every frame
			var want: Vector2 = game.get_center().lerp(pane.get_center(), k / 15.0)
			if not near_v(r.get_center(), want):
				linear = false
			if k > 0:
				var step: Vector2 = r.get_center() - GEO.send_rect(layout, id, (k - 1) / 15.0).get_center()
				if k == 1:
					step0 = step
				elif not near_v(step, step0):
					linear = false
			if k >= 1 and not pane.grow(1.0).encloses(GEO.send_rect(layout, id, 1.0)):
				inside = false
	check(ok, "a send starts centred on the window's middle (240, 120) and ends at the centre of the recipient's pane, at rest size (all 34)")
	check(linear, "frame n of 15 is exactly n/15 of the way along the straight line: the same distance every frame, no easing (all 34)")
	check(start_size and inside, "the box starts 32.0 x 41.0 and ends at the pane's rest box (30.5 x 39.0), inside the pane")
	check(GEO.send_rect(layout, 3, -1.0) == GEO.send_rect(layout, 3, 0.0) and GEO.send_rect(layout, 3, 2.0) == GEO.send_rect(layout, 3, 1.0), "progress outside 0..1 is clamped")
	var step_a: Vector2 = GEO.send_rect(layout, 5, 1.0 / 15.0).get_center() - GEO.send_rect(layout, 5, 0.0).get_center()
	var pane5: Rect2 = layout.slots[4]
	check(absf(step_a.length() * 15.0 - (pane5.get_center() - game.get_center()).length()) < 0.001, "(the measured flight of t=526.683 moved 12.5, 8.4 units a frame to a pane 187.5, 126.5 away)")

# ---- flights from sends ------------------------------------------------------------------------------

func test_flights_from_sends() -> void:
	print("-- flights from sends")
	var s = make_session(7, 9)
	var pres = P.new(s)
	check(pres.flights.is_empty() and pres.counts(9) == Vector2i.ZERO, "a presentation starts empty")
	var a = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	check(a != null and pres.flights.size() == 1, "the real player's send produces exactly one flight")
	var f = pres.flights[0]
	check(f.seq == a.seq and f.sender == 0 and f.target == a.target and f.target == 9 and f.kind == GOOMBA,
		"it targets the authoritative recipient (#%d), with the real enemy type and the attack's sequence id" % f.target)
	check(near_eq(f.duration, F.SEND_SECONDS) and near_eq(F.SEND_SECONDS, 0.25) and near_eq(F.SEND_SECONDS * 60.0, 15.0) and SS.HOLD_SECONDS == 0.0, "it is the reticle's flight: 15 frames = %.2f s (measured at 60 fps, doc 54), starting to move at once" % f.duration)
	check(pres.records[a.seq].sender == 0 and pres.records[a.seq].target == 9 and pres.records[a.seq].state == A.State.QUEUED,
		"the record of the attack starts QUEUED")
	check(pres.counts(9) == Vector2i(1, 0), "the target's queued count is 1")
	var in_air: Array = pres.player_flights()
	check(in_air.size() == 1 and in_air[0].seq == a.seq and in_air[0].target == 9 and in_air[0].progress == 0.0 and not in_air[0].cut and pres.player_sending(), "it is the player's flight in the air, at its start")
	pres.update(F.SEND_SECONDS * 0.4)
	in_air = pres.player_flights()
	check(in_air.size() == 1 and near_eq(in_air[0].progress, 0.4), "it moves at constant speed from its first frame: at 40%% of the time it is 40%% of the way (%.2f)" % in_air[0].progress)
	pres.update(F.SEND_SECONDS * 0.6 + 0.001)
	check(pres.player_flights().is_empty() and not pres.player_sending() and pres.flights.is_empty(), "after %.2f s it has landed and nothing is left (no tint, no line)" % F.SEND_SECONDS)
	# a bot sends to a bot: not presented at all (B35-ATTACK-002)
	var b = s.report_enemy_defeat(5, KOOPA)
	pres.update(0.0)
	check(b != null and pres.flight_of(b.seq) == null and pres.flights.is_empty(), "a bot-to-bot send is not drawn: no flight is made for it")
	check(pres.records[b.seq].sender == 5 and pres.records[b.seq].target == 9 and pres.counts(9) == Vector2i(2, 0), "...but it is still recorded and counted (the previews show it)")
	# a bot sends to the real player: an icon in the bar (the record and the counts), but no flight and no line of its own
	var s2 = make_session(7, 0)
	var pres2 = P.new(s2)
	var c = s2.report_enemy_defeat(4, GOOMBA)
	pres2.update(0.0)
	check(c != null and pres2.flights.is_empty() and pres2.flight_of(c.seq) == null and pres2.player_flights().is_empty(), "an attack on the real player is not a flight: its line (if any) belongs to the opponent that aims at the player")
	check(pres2.counts(0) == Vector2i(1, 0) and pres2.records[c.seq].landed_at == pres2.records[c.seq].sent_at and pres2.player_incoming().size() == 1, "...it is the player's queued count and an icon that enters the bar at the moment of the send")
	# nothing to send, nothing to show
	var s3 = make_session(7, 0)
	s3.attacks.enabled = true
	s3.report_ko(1, S.KoCause.HAZARD)
	var pres3 = P.new(s3)
	var none = s3.report_enemy_defeat(1, GOOMBA)
	pres3.update(0.0)
	check(none == null and pres3.flights.is_empty(), "a defeat that sends nothing (the defeater is out) shows nothing")

func near_eq(a: float, b: float) -> bool:
	return absf(a - b) < 1e-6

## Two points within a thousandth of a unit (the layout is float32).
func near_v(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) < 1e-3 and absf(a.y - b.y) < 1e-3

func test_simultaneous_sends() -> void:
	print("-- simultaneous sends")
	var s = make_session(11)
	var pres = P.new(s)
	var sent := []
	for id in range(0, 13):
		var atk = s.report_enemy_defeat(id, GOOMBA if id % 2 == 0 else KOOPA)
		if atk != null:
			sent.append(atk)
	pres.update(0.0)
	check(sent.size() == 13 and pres.flights.size() == 1 and pres.flights[0].sender == 0, "13 sends in the same moment: only the real player's is a flight (a bot's send is never one)")
	var f0 = pres.flights[0]
	var truth: Dictionary = s.attacks.attack_history()[f0.seq]
	check(f0.seq == sent[0].seq and f0.target == truth.target and f0.kind == truth.kind, "it matches its authoritative attack exactly")
	var counts_ok := true
	for id in 35:
		if pres.counts(id) != auth_counts(s, id):
			counts_ok = false
	check(counts_ok, "every contestant's queued / active counts equal the authoritative queue")
	# rapid sends: a newer send of the player's takes the bracket over (doc 54: only one bracket is ever in flight)
	pres.update(0.10)
	var late = s.report_enemy_defeat(0, KOOPA) # a second send by the player while the first is still flying
	pres.update(0.0)
	var last = pres.flight_of(late.seq)
	check(last != null and absf(last.born - 0.10) < 1e-6 and f0.born == 0.0, "flights keep their own start times (%.2f, %.2f)" % [f0.born, last.born])
	check(f0.cancelled_at >= 0.0 and absf(f0.cancelled_at - 0.10) < 1e-6 and last.cancelled_at < 0.0 and pres.flight_of(sent[0].seq) == null, "the newer send cancels the older one at that moment (it never lands, and is dropped at once)")
	var one: Array = pres.player_flights()
	check(one.size() == 1 and one[0].seq == late.seq and one[0].target == late.target and one[0].progress == 0.0 and pres.player_sending(), "only the newest is in the air, at its start (240, 120): the old bracket is gone that frame")
	pres.update(F.SEND_SECONDS * 0.5)
	one = pres.player_flights()
	check(one.size() == 1 and near_eq(one[0].progress, 0.5), "the new one flies on its own 15 frames from its own start")
	pres.update(F.SEND_SECONDS * 0.5 + 0.001)
	check(pres.player_flights().is_empty() and pres.flights.is_empty(), "everything is gone when the last bracket has landed")
	check(pres.records.size() == 14 and pres.records[late.seq].kind == KOOPA, "the records of all 14 attacks remain, by sequence id")
	# three in a row, each inside the previous one's flight
	var s3 = make_session(11, 9)
	var p3 = P.new(s3)
	var q1 = s3.report_enemy_defeat(0, GOOMBA)
	p3.update(0.05)
	var q2 = s3.report_enemy_defeat(0, GOOMBA)
	p3.update(0.05)
	var q3 = s3.report_enemy_defeat(0, KOOPA)
	p3.update(0.0)
	var live: Array = p3.player_flights()
	check(live.size() == 1 and live[0].seq == q3.seq and q1.seq != q2.seq, "three sends in 0.1 s: only the third bracket is left in the air")
	p3.update(1.0)
	check(p3.player_flights().is_empty() and p3.flights.is_empty(), "...and when it has landed nothing stale is left over the panes")
	var many = make_session(3, 0) # every send is at the real player
	var big = P.new(many)
	for i in 300:
		many.report_enemy_defeat(1 + i % 34, GOOMBA)
	big.update(0.0)
	check(big.flights.is_empty() and big.records.size() == 300, "300 bot sends at the player draw no flight at all, and every attack is still recorded")
	var mine = make_session(3, 5)
	var mp = P.new(mine)
	for i in 300:
		mine.report_enemy_defeat(0, GOOMBA)
	mp.update(0.0)
	check(mp.flights.size() <= mp.MAX_FLIGHTS and mp.player_flights().size() == 1 and mp.records.size() == 300, "300 sends by the player: the safety valve holds, one bracket is in the air, every attack is recorded")

# ---- counts follow the session -----------------------------------------------------------------------

func test_counts_follow_the_session() -> void:
	print("-- counts and the player's list follow the session")
	var mismatches := 0
	var checks := 0
	var saw_active_player := 0
	var saw_queued_player := 0
	var saw_activation := false
	for seed_value in [1, 2, 3, 5, 8]:
		var s = S.new(seed_value)
		var pres = P.new(s)
		var resolved_by_game := false
		for tick in 130:
			s.step()
			if tick % 6 == 0 and s.get_player().alive:
				s.report_enemy_defeat(0, GOOMBA if tick % 12 == 0 else KOOPA)
			if tick == 80 and not resolved_by_game:
				for d in s.get_incoming(0):
					if d.state == A.State.ACTIVE:
						resolved_by_game = s.resolve_player_incoming(d.seq, R.DEFEATED_BY_PLAYER)
						break
			pres.update(1.0 / 60.0)
			for id in 35:
				checks += 1
				if pres.counts(id) != auth_counts(s, id):
					mismatches += 1
			checks += 1
			if rows_of(pres.player_incoming()) != rows_of(s.get_incoming(0)):
				mismatches += 1
			var pc: Vector2i = pres.counts(0)
			saw_active_player += pc.y
			saw_queued_player += pc.x
			if not pres.last_activation().is_empty():
				saw_activation = true
	check(mismatches == 0, "the presented counts and the player's list equal the session's queues after every tick (%d comparisons, 5 seeds)" % checks)
	check(saw_active_player > 0 and saw_queued_player > 0 and saw_activation, "(the runs really had queued and active attacks on the real player, and activations)")
	# the player's list: QUEUED -> ACTIVE in order, resolved by the game, nothing timed
	var s = make_session(4, 0)
	var pres = P.new(s)
	var first = s.report_enemy_defeat(2, GOOMBA)
	var second = s.report_enemy_defeat(3, KOOPA)
	pres.update(0.0)
	check(rows_of(pres.player_incoming()) == [[first.seq, A.State.QUEUED], [second.seq, A.State.QUEUED]], "two sends at the player are two QUEUED icons, in send order")
	for i in 3:
		s.step()
	pres.update(0.0)
	var rows: Array = pres.player_incoming()
	check(rows_of(rows) == [[first.seq, A.State.ACTIVE], [second.seq, A.State.ACTIVE]] and pres.counts(0) == Vector2i(0, 2),
		"after the activation delay both are ACTIVE and the counts say 0 queued / 2 active")
	check(rows[0].kind == GOOMBA and rows[1].kind == KOOPA, "each icon carries its enemy type")
	check(rows[0].flash > 0.0 and pres.last_activation().seq == second.seq and pres.last_activation().kind == KOOPA,
		"a QUEUED -> ACTIVE change flashes, and the last activation is known")
	pres.update(1.0)
	check(pres.player_incoming()[0].flash == 0.0, "the flash dies down")
	for i in 40:
		s.step()
	pres.update(0.0)
	check(pres.counts(0) == Vector2i(0, 2), "attacks on the real player stay ACTIVE: no timer (40 more Battle seconds)")
	check(s.resolve_player_incoming(first.seq, R.DEFEATED_BY_PLAYER), "(the game resolves one)")
	pres.update(0.0)
	check(rows_of(pres.player_incoming()) == [[second.seq, A.State.ACTIVE]] and pres.counts(0) == Vector2i(0, 1)
		and pres.records[first.seq].cause == R.DEFEATED_BY_PLAYER, "only the game's explicit resolution removes an icon")
	# the list a presentation hands out is a copy
	var copy: Array = pres.player_incoming()
	copy[0].state = A.State.QUEUED
	copy.clear()
	check(pres.player_incoming().size() == 1 and pres.player_incoming()[0].state == A.State.ACTIVE, "the returned list is a copy")

func test_target_out_and_round_end() -> void:
	print("-- a KO and the end of the round")
	var s = make_session(5, 4)
	var pres = P.new(s)
	var a = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.1)
	check(pres.flight_of(a.seq) != null and pres.flight_of(a.seq).cut_at < 0.0, "a line in the air towards a bot that is still in")
	s.report_ko(4, S.KoCause.HAZARD)
	pres.update(0.0)
	var f = pres.flight_of(a.seq)
	check(f != null and f.cut_at >= 0.0, "its target is eliminated: the line is cut, not left to land on a KO")
	check(pres.records[a.seq].state == A.State.RESOLVED and pres.records[a.seq].cause == R.TARGET_OUT, "the record is resolved by the authoritative TARGET_OUT")
	check(pres.counts(4) == Vector2i.ZERO, "the eliminated bot has nothing queued or active")
	pres.update(0.2)
	check(pres.flights.is_empty() and pres.player_flights().is_empty(), "the flight has faded away and nothing is left")
	# attacks that were ACTIVE on it too
	var s2 = make_session(6, 8)
	var p2 = P.new(s2)
	var x = s2.report_enemy_defeat(0, GOOMBA)
	var y = s2.report_enemy_defeat(1, KOOPA)
	for i in 3:
		s2.step()
	p2.update(1.0)
	check(p2.counts(8) == Vector2i(0, 2), "two enemies are ACTIVE on bot #8")
	s2.report_ko(8, S.KoCause.TIME)
	p2.update(0.0)
	check(p2.counts(8) == Vector2i.ZERO and p2.records[x.seq].cause == R.TARGET_OUT and p2.records[y.seq].cause == R.TARGET_OUT,
		"its KO resolves them all as TARGET_OUT, and the presentation follows")
	# the end of the round
	var s3 = make_session(9, 5)
	var p3 = P.new(s3)
	var q1 = s3.report_enemy_defeat(0, GOOMBA)
	var q2 = s3.report_enemy_defeat(2, KOOPA)
	for i in 3:
		s3.step()
	s3.end_round()
	p3.update(0.0)
	check(p3.records[q1.seq].cause == R.ROUND_ENDED and p3.records[q2.seq].cause == R.ROUND_ENDED and p3.counts(5) == Vector2i.ZERO,
		"the end of the round resolves everything (ROUND_ENDED) and the counts are zero")

func test_late_creation() -> void:
	print("-- a presentation created mid-round")
	var s = make_session(8, 3)
	var a = s.report_enemy_defeat(0, GOOMBA)
	var b = s.report_enemy_defeat(2, KOOPA)
	for i in 4:
		s.step()
	var c = s.report_enemy_defeat(1, GOOMBA)
	var pres = P.new(s) # created after all that
	pres.update(0.0)
	check(pres.flights.is_empty(), "attacks that already happened draw no lines")
	check(pres.counts(3) == auth_counts(s, 3) and pres.counts(3) == Vector2i(1, 2), "but the counts are right (queued %s, active %s)" % [pres.counts(3).x, pres.counts(3).y])
	var d = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	check(pres.flights.size() == 1 and pres.flights[0].seq == d.seq, "a new send by the player after that is a flight")
	check(a.seq != b.seq and pres.records.size() == 4, "the records cover all four attacks")

# ---- read only ---------------------------------------------------------------------------------------

func test_presentation_is_read_only() -> void:
	print("-- read only")
	for name in PRESENTATION_FILES:
		var code := code_of("res://Scripts/Classes/Battle/%s.gd" % name)
		var bad := []
		for token in [".attacks", "report_", "resolve_", "end_round", ".step(", "targeting", ".record(", "events.append", "events.erase", "events.clear",
				"BattleSession.current", "queues", "history", "next_seq"]:
			if code.contains(token):
				bad.append(token)
		if name != "BattleAttackPresentation":
			if code.contains("session"):
				bad.append("session")
		else:
			var writes := RegEx.create_from_string("session\\.[A-Za-z_\\.\\[\\]]+\\s*(=|\\+=|-=)[^=]")
			if writes.search(code) != null:
				bad.append("an assignment to the session")
		check(bad.is_empty(), "%s never touches the session's mutating API or the attack system (%s)" % [name, bad])
	var track_code := code_of("res://Scripts/Classes/Battle/BattlePreviewTrack.gd")
	var bad_track := []
	for token in ["BattleSession.current", ".attacks", "resolve_", "report_", "report_ko", "session."]:
		if track_code.contains(token):
			bad_track.append(token)
	check(bad_track.is_empty(), "the preview track still has no way into the session (%s)" % [bad_track])
	# the presentation's only handle on the session is its event list: nothing it stores is a session object
	var s = make_session(7, 9)
	var pres = P.new(s)
	s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	var holds_session := false
	for prop in INV.new().get_property_list():
		if prop.type == TYPE_OBJECT and prop.name != "script":
			holds_session = true
	for f in pres.flights:
		for prop in f.get_property_list():
			if prop.type == TYPE_OBJECT and prop.name != "script":
				holds_session = true
	check(not holds_session, "invaders and flights hold no object references at all (so none to the session or its attacks)")
	# using the presentation changes nothing in the session
	var s_a = S.new(21)
	var s_b = S.new(21)
	var pres_a = P.new(s_a)
	var changed := false
	for tick in 100:
		s_a.step()
		s_b.step()
		if tick % 7 == 0:
			s_a.report_enemy_defeat(0, GOOMBA)
			s_b.report_enemy_defeat(0, GOOMBA)
		pres_a.update(0.25)
		var rows: Array = pres_a.player_incoming()
		rows.clear()
		pres_a.flights.clear() # even wiping its own state leaves the session alone
		if str(s_a.snapshot()) != str(s_b.snapshot()) or s_a.events.size() != s_b.events.size():
			changed = true
	check(not changed, "a session read by a presentation is identical to the same session without one, tick by tick (snapshots and event counts)")

# ---- deterministic replay ----------------------------------------------------------------------------

func run_signature(seed_value: int, delta: float) -> Array:
	var s = S.new(seed_value)
	var pres = P.new(s)
	pres.keep_trace = true
	var states := PackedStringArray()
	for tick in 90:
		s.step()
		if tick % 5 == 2 and s.get_player().alive:
			s.report_enemy_defeat(0, GOOMBA if tick % 10 == 2 else KOOPA)
		pres.update(delta)
		var line := PackedStringArray()
		for f in pres.flights:
			line.append("%d>%d:%d@%.3f/%.3f" % [f.seq, f.target, f.kind, f.born, f.strength(pres.clock)])
		for pf in pres.player_flights():
			line.append("p%d>%d=%.3f" % [pf.seq, pf.target, pf.progress])
		states.append("|".join(line) + "#" + str(pres.player_incoming().size()))
	return [pres.signature(), "\n".join(pres.trace), "\n".join(states)]

func test_deterministic_replay() -> void:
	print("-- deterministic replay")
	var one := run_signature(13, 0.25)
	var two := run_signature(13, 0.25)
	check(one[0] == two[0] and one[1] == two[1] and one[2] == two[2], "the same match and the same frame deltas present the same event sequence and the same lines, tick by tick (%s)" % one[0])
	check(not (one[1] as String).is_empty() and (one[1] as String).contains("\n"), "(and that sequence is not empty)")
	var other := run_signature(14, 0.25)
	check(other[0] != one[0], "a different match presents a different sequence")
	var slow := run_signature(13, 0.5)
	check(slow[0] == one[0] and slow[1] == one[1], "the presented event sequence does not depend on the frame rate (only the lines' timing does)")

## The whole picture of a match with attacks, as text: every preview's frame (incoming enemies included)
## and the presentation's lines, after every Battle second.
func run_pictures(seed_value: int) -> Array:
	var s = S.new(seed_value)
	var d = D.create(s, range(1, 35), 187.0)
	var pres = P.new(s)
	var parts := PackedStringArray()
	var shown := 0
	for tick in 70:
		s.step()
		if tick % 5 == 1 and s.get_player().alive:
			s.report_enemy_defeat(0, GOOMBA if tick % 10 == 1 else KOOPA)
		pres.update(0.2)
		for k in 4:
			d.update(float(k) / 4.0)
		var line := PackedStringArray()
		for id in d.tracks:
			var sig: String = d.tracks[id].frame.signature()
			line.append(sig)
			shown += d.tracks[id].frame.invaders.size()
		parts.append("|".join(line))
	return [hash("\n".join(parts)), pres.signature(), shown]

func test_driver_replay() -> void:
	print("-- deterministic replay of the pictures")
	var one := run_pictures(17)
	var two := run_pictures(17)
	check(one[0] == two[0] and one[1] == two[1] and one[2] > 0, "the same match replays the same pictures in all 34 previews, incoming enemies included (%d invader frames, hash %d)" % [one[2], one[0]])
	check(run_pictures(18)[0] != one[0], "and another match does not")

func test_flight_timing() -> void:
	print("-- flight timing (doc 54)")
	var r = F.new()
	r.sender = 0
	r.born = 5.0
	r.duration = F.SEND_SECONDS
	check(r.travel(5.0) == 0.0 and near_eq(r.travel(5.0 + F.SEND_SECONDS), 1.0) and r.eased(5.0) == 0.0 and near_eq(r.eased(5.0 + F.SEND_SECONDS), 1.0) and r.travel(4.0) == 0.0 and r.travel(9.0) == 1.0, "the reticle flight goes from 0 to 1 in %.2f s and never leaves that range" % F.SEND_SECONDS)
	var steps_ok := true
	var step0 := 0.0
	for k in 16:
		var e: float = r.eased(5.0 + k / 60.0)
		if k == 1:
			step0 = e
		if not near_eq(e, k / 15.0):
			steps_ok = false
	check(steps_ok and near_eq(step0, 1.0 / 15.0), "it moves exactly 1/15 of the way every 60 fps frame: constant speed, no easing, no hold")
	check(SS.ease(0.3) == 0.3 and SS.HOLD_SECONDS == 0.0 and F.SEND_SECONDS >= 0.2 and F.SEND_SECONDS <= 0.3, "(BattleSendStyle.ease is the identity, and 15 frames is inside doc 47's 0.2-0.3 s)")
	check(r.strength(5.0 + F.SEND_SECONDS) == 1.0 and r.strength(5.0 + F.SEND_SECONDS + 0.001) == 0.0 and r.finished(5.0 + F.SEND_SECONDS + 0.001), "it is gone the moment it lands: no linger, no tint")
	r.cut_at = 5.1
	check(r.strength(5.1) == 1.0 and r.finished(5.1 + F.CUT_FADE + 0.01), "a flight whose target went out fades within %.2f s" % F.CUT_FADE)
	var c = F.new()
	c.sender = 0
	c.born = 7.0
	c.duration = F.SEND_SECONDS
	check(c.strength(7.05) == 1.0, "a flight in the air is whole...")
	c.cancel(7.1)
	check(c.strength(7.09) == 1.0 and c.strength(7.1) == 0.0 and c.finished(7.1) and c.cancelled_at == 7.1, "...until a newer send cancels it: it is gone that instant, not faded")
	c.cancel(7.2)
	check(c.cancelled_at == 7.1, "(cancelling twice keeps the first time)")

# ---- incoming enemies in a preview -------------------------------------------------------------------

func new_track(id := 1):
	var sk = K.load_for(LEVEL)
	var tr = TR.new(id, sk, AS.build(sk), 11, 187.0, 0)
	tr.push(0, 0, 0.0, 0, true, [])
	return tr

func ev(type: int, tick: int, id: int, seq: int, kind: int, cause := 0) -> Dictionary:
	return {"tick": tick, "id": id, "type": type, "a": seq, "b": 0, "kind": kind, "cause": cause}

## Pushes `events` for `tick` and runs the track to `tick` + 1 (a plain run: progress keeps rising).
func run_track(tr, from_tick: int, to_tick: int, events_at := {}, progress_step := 0.01) -> void:
	for tick in range(from_tick, to_tick):
		tr.push(tick, 0, progress_step * tick, 0, true, events_at.get(tick, []))
		for k in 30:
			tr.advance_to(float(tick) + float(k) / 30.0)

func test_invaders_on_a_track() -> void:
	print("-- incoming enemies in a preview")
	var tr = new_track()
	var before: String = tr.frame.signature()
	run_track(tr, 1, 3)
	check(tr.invaders.is_empty() and tr.frame.invaders.is_empty(), "nothing is shown without an attack")
	run_track(tr, 3, 5, {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 42, GOOMBA)]})
	check(tr.invaders.size() == 1 and tr.invaders[0].seq == 42, "an ACTIVE Goomba attack produces one invader, with the attack's sequence id")
	var inv = tr.invaders[0]
	check(inv.kind == GOOMBA and inv.preview_kind == "goomba", "it is a Goomba")
	check(tr.frame.invaders.size() == 1 and tr.frame.invaders[0].seq == 42 and tr.frame.invaders[0].kind == GOOMBA, "and the picture carries it (a Goomba, seq 42)")
	var goomba_sprite = tr.frame.invaders[0].sprite
	check(goomba_sprite != null and goomba_sprite in tr.assets.enemies.goomba.walk, "drawn with the Goomba's own art")
	check(inv.x > tr.x + 20.0 and inv.x <= tr.camera_x + tr.view_w + TR.INVADER_MARGIN + 1.0, "it is ahead of Mario and no further than the edge of the view (%.0f vs Mario %.0f, edge %.0f)" % [inv.x, tr.x, tr.camera_x + tr.view_w])
	run_track(tr, 5, 11)
	check(tr.invaders.size() == 1 and inv.x > tr.x + 20.0 and inv.x < tr.camera_x + tr.view_w, "it keeps ahead of Mario and inside the view as the run goes on (%.0f vs Mario %.0f)" % [inv.x, tr.x])
	check(tr.enemies.all(func(e): return not e.has("seq")) and tr.phase == TR.Phase.RUN and tr.power == 0, "it is not one of the run's own enemies, and Mario was not touched")
	# a Koopa
	var tk = new_track()
	run_track(tk, 1, 5, {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 7, KOOPA)]})
	check(tk.invaders.size() == 1 and tk.invaders[0].kind == KOOPA and tk.invaders[0].preview_kind == "koopa_green" and tk.frame.invaders[0].kind == KOOPA,
		"an ACTIVE Koopa attack produces a Koopa")
	check(tk.frame.invaders[0].sprite != goomba_sprite, "with the Koopa's art, not the Goomba's")
	# several at once, each its own sequence id and place
	var tm = new_track()
	run_track(tm, 1, 9, {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 10, GOOMBA)], 4: [ev(E.INCOMING_ACTIVATED, 4, 1, 11, KOOPA)], 5: [ev(E.INCOMING_ACTIVATED, 5, 1, 12, GOOMBA)]})
	var seqs := []
	var xs := []
	for i in tm.invaders:
		seqs.append(i.seq)
		xs.append(roundi(i.x))
	check(seqs == [10, 11, 12] and tm.frame.invaders.size() == 3, "three attacks are three invaders, one per sequence id")
	var distinct := {}
	for i in tm.invaders:
		distinct[i.slot] = true
	check(distinct.size() == 3, "standing in three different places ahead of Mario (slots %s)" % [distinct.keys()])
	# resolve
	var resolve_tick := 12
	var tg = new_track()
	run_track(tg, 1, 20, {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 5, GOOMBA)], 4: [ev(E.INCOMING_ACTIVATED, 4, 1, 6, KOOPA)],
		resolve_tick: [ev(E.INCOMING_RESOLVED, resolve_tick, 1, 5, GOOMBA, R.EXPIRED)]})
	check(tg.invader_for(5) == null and tg.invader_for(6) != null, "RESOLVED removes the invader with that sequence id, and only that one")
	check(tg.frame.invaders.size() == 1 and tg.frame.invaders[0].seq == 6, "the picture follows")
	# it blinks out before it goes
	var tb = new_track()
	run_track(tb, 1, 8, {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 5, GOOMBA)]})
	tb.push(8, 0, 0.08, 0, true, [ev(E.INCOMING_RESOLVED, 8, 1, 5, GOOMBA, R.EXPIRED)])
	var blink_seen := false
	var gone_at := -1.0
	for k in range(0, 60):
		var t := 7.0 + float(k) / 30.0
		tb.advance_to(t)
		var i = tb.invader_for(5)
		if i != null and i.is_vanishing() and not tb.frame.invaders.is_empty() and tb.frame.invaders[0].vanish > 0.0:
			blink_seen = true
		if i == null and gone_at < 0.0:
			gone_at = t
	check(blink_seen and gone_at >= 8.0 and gone_at <= 8.0 + TR.INVADER_VANISH + 0.2, "it blinks out for %.1f s after the resolution (gone at preview time %.2f)" % [TR.INVADER_VANISH, gone_at])
	# no events, no pending: a resolution for an attack that never became active is ignored
	var tq = new_track()
	run_track(tq, 1, 6, {3: [ev(E.INCOMING_RESOLVED, 3, 1, 99, GOOMBA, R.TARGET_OUT)]})
	check(tq.invaders.is_empty() and tq._inc_end.is_empty(), "a resolution of an attack that was never active shows nothing")
	# the same activation and resolution in one tick
	var ts = new_track()
	run_track(ts, 1, 8, {4: [ev(E.INCOMING_ACTIVATED, 4, 1, 9, GOOMBA), ev(E.INCOMING_RESOLVED, 4, 1, 9, GOOMBA, R.TARGET_OUT)]})
	check(ts.invaders.is_empty(), "an attack that activates and resolves in the same tick is shown briefly and then cleared")
	# a Mario who is not in the run any more gets nothing new
	var tr2 = new_track()
	tr2.phase = TR.Phase.DONE
	tr2.push(3, 0, 0.5, 0, true, [ev(E.INCOMING_ACTIVATED, 3, 1, 1, GOOMBA)])
	check(tr2._inc_spawn.is_empty() and tr2.invaders.is_empty(), "a finished preview takes no more attacks")
	check(not before.contains(";i"), "(the signature of a frame without invaders has no invader part)")
	# identical input, identical picture
	var sig_a := PackedStringArray()
	var sig_b := PackedStringArray()
	for pass_ in 2:
		var t0 = new_track()
		for tick in range(1, 25):
			var events := {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 1, GOOMBA)], 5: [ev(E.INCOMING_ACTIVATED, 5, 1, 2, KOOPA)], 14: [ev(E.INCOMING_RESOLVED, 14, 1, 1, GOOMBA, R.EXPIRED)]}
			run_track(t0, tick, tick + 1, events)
			(sig_a if pass_ == 0 else sig_b).append(t0.frame.signature())
	check(sig_a == sig_b and "".join(sig_a).contains(";i1,"), "a preview with invaders is deterministic (same input, the same picture every step)")

## Which attacks should be on screen in `id`'s preview when the picture has reached preview time `vt`.
func expected_invaders(history: Array, id: int, vt: float) -> Array:
	var out := []
	for d in history:
		if d.target != id or d.activated_tick < 0 or float(d.activated_tick) > vt:
			continue
		if d.resolved_tick >= 0 and float(d.resolved_tick) <= vt:
			continue
		out.append(d.seq)
	return out

func test_invaders_follow_the_session() -> void:
	print("-- the previews show exactly the session's ACTIVE attacks")
	var comparisons := 0
	var mismatches := 0
	var appearances := 0
	var alien := 0
	var kinds_seen := {}
	for seed_value in [2, 4, 6]:
		var s = S.new(seed_value)
		var ids := range(1, 35)
		var d = D.create(s, ids, 187.0)
		for tick in 150:
			s.step()
			if tick % 4 == 1 and s.get_player().alive:
				s.report_enemy_defeat(0, GOOMBA if tick % 8 == 1 else KOOPA)
			d.update(0.5) # the picture is at tick + 0.5 - LAG: well away from any whole tick
			var vt: float = d.visual_time(0.5)
			var history: Array = s.attacks.attack_history()
			for id in ids:
				var track = d.tracks[id]
				for inv in track.invaders:
					if inv.seq >= history.size() or history[inv.seq].target != id or history[inv.seq].kind != inv.kind:
						alien += 1
					kinds_seen[inv.kind] = true
				if not [TR.Phase.RUN, TR.Phase.DYING, TR.Phase.FALLING].has(track.phase):
					continue
				var shown := []
				for inv in track.invaders:
					if not inv.is_vanishing():
						shown.append(inv.seq)
				shown.sort()
				var want := expected_invaders(history, id, vt)
				comparisons += 1
				appearances += shown.size()
				if shown != want:
					mismatches += 1
	check(comparisons > 3000 and appearances > 100, "(the runs compare %d preview moments and show %d invader appearances)" % [comparisons, appearances])
	check(mismatches == 0, "in every preview, at every moment, the invaders present are exactly the attacks that are ACTIVE on that opponent (by sequence id) at the picture's time")
	check(alien == 0, "no invader exists for an attack that was not aimed at that opponent or that has another kind")
	check(kinds_seen.has(GOOMBA) and kinds_seen.has(KOOPA), "both enemy types were seen")
	# a send goes to exactly the opponent it was aimed at
	var s2 = make_session(9, 2)
	var d2 = D.create(s2, range(1, 35), 187.0)
	var atk = s2.report_enemy_defeat(0, KOOPA)
	for tick in 8:
		s2.step()
		d2.update(0.5)
	var holders := []
	for id in d2.tracks:
		if d2.tracks[id].invader_for(atk.seq) != null:
			holders.append(id)
	check(holders == [2] and d2.tracks[2].invader_for(atk.seq).kind == KOOPA, "a Koopa sent to #2 appears in #2's preview and in no other")

func test_ko_clears_invaders() -> void:
	print("-- a KO with attacks active")
	var s = make_session(5, 6)
	var d = D.create(s, range(1, 35), 187.0)
	var a = s.report_enemy_defeat(0, GOOMBA)
	var b = s.report_enemy_defeat(1, KOOPA)
	var track = d.tracks[6]
	var saw := false
	var still_shown_at_ko := false
	var ko_called := false
	for tick in 40:
		s.step()
		d.update(0.5)
		if track.invaders.size() == 2:
			saw = true
		if saw and not ko_called:
			s.report_ko(6, S.KoCause.HAZARD)
			ko_called = true
			still_shown_at_ko = track.invaders.size() == 2 # the picture trails the session: it still shows them
	check(saw, "both enemies were on screen in #6's preview before it was eliminated")
	check(s.attacks.history[a.seq].resolution == R.TARGET_OUT and s.attacks.history[b.seq].resolution == R.TARGET_OUT and s.get_incoming(6).is_empty(),
		"the session resolved both as TARGET_OUT at the KO")
	check(still_shown_at_ko, "the picture trails the session, so the enemies were still there when the KO was decided")
	check(track.phase == TR.Phase.KO and track.ko_overlay and track.mario_hidden, "the opponent's own KO presentation plays out normally")
	check(track.invaders.is_empty() and track.frame.invaders.is_empty() and track._inc_spawn.is_empty() and track._inc_end.is_empty(),
		"and leaves no invader behind")
	var other_ok := true
	for id in d.tracks:
		if id != 6 and not d.tracks[id].invaders.is_empty() and not s.contestants[id].alive:
			other_ok = false
	check(other_ok, "no other opponent was touched")
	check(s.report_enemy_defeat(0, GOOMBA) == null, "an eliminated opponent cannot be sent anything any more")
	for tick in 5:
		s.step()
		d.update(0.5)
	check(track.invaders.is_empty(), "nothing appears in a finished preview afterwards")
	# The backstop: if the picture's own KO arrives while an enemy is still on screen (no resolution event
	# yet), the KO still wins and the enemy goes with the run.
	var tr = new_track()
	tr.push(1, 0, 0.01, 0, true, [])
	var events := {3: [ev(E.INCOMING_ACTIVATED, 3, 1, 1, GOOMBA), ev(E.INCOMING_ACTIVATED, 3, 1, 2, KOOPA)], 5: [{"tick": 5, "id": 1, "type": E.KO, "a": S.KoCause.TIME, "b": 0}]}
	var saw_two := false
	for tick in range(1, 40):
		run_track(tr, tick, tick + 1, events)
		if tr.invaders.size() == 2:
			saw_two = true
	check(saw_two and tr.phase == TR.Phase.KO and tr.invaders.is_empty() and tr.frame.invaders.is_empty(),
		"a KO that arrives with enemies still on screen ends the run with none left")

func test_twin_sessions() -> void:
	print("-- the previews and the presentation cannot change the session")
	var plain = S.new(33)
	var watched = S.new(33)
	var d = D.create(watched, range(1, 35), 187.0)
	var pres = P.new(watched)
	var diverged := 0
	var invader_moments := 0
	for tick in 200:
		plain.step()
		watched.step()
		if tick % 5 == 0:
			plain.report_enemy_defeat(0, GOOMBA)
			watched.report_enemy_defeat(0, GOOMBA)
		d.update(0.5)
		pres.update(0.1)
		for id in d.tracks:
			invader_moments += d.tracks[id].invaders.size()
		if str(plain.snapshot()) != str(watched.snapshot()) or plain.events.size() != watched.events.size():
			diverged += 1
	check(invader_moments > 200, "(the watched run showed plenty of invaders: %d invader-moments)" % invader_moments)
	check(diverged == 0, "a session with live previews and a presentation is identical to the same session without them, every tick (snapshots, event counts)")
	var same_events := true
	for i in plain.events.size():
		if str(plain.events[i]) != str(watched.events[i]):
			same_events = false
	check(same_events and plain.winner_id == watched.winner_id, "every logged event is identical")
	# The picture can only show what the session decided: with invaders on screen it never shows a death,
	# a hit or a growth the session did not log first.
	var s = make_session(5, 9)
	var d2 = D.create(s, range(1, 35), 187.0)
	for i in 6:
		s.report_enemy_defeat(0 if i % 2 == 0 else 2, GOOMBA if i % 3 else KOOPA)
	var illegal := 0
	var saw_invaders := false
	var track9 = d2.tracks[9]
	var power_before: int = track9.power
	for tick in 60:
		s.step()
		d2.update(0.5)
		saw_invaders = saw_invaders or not track9.invaders.is_empty()
		var ko_logged := false
		var hit_logged := false
		for e in s.events:
			if e.id == 9 and e.type == E.KO:
				ko_logged = true
			if e.id == 9 and e.type == E.HIT:
				hit_logged = true
		if [TR.Phase.DYING, TR.Phase.FALLING, TR.Phase.KO].has(track9.phase) and not ko_logged:
			illegal += 1
		if track9.power < power_before and not hit_logged:
			illegal += 1
		power_before = track9.power
	check(saw_invaders and illegal == 0, "a preview with invaders on screen never shows a death or a hit that the session had not logged")

func test_no_attack_visuals_when_off() -> void:
	print("-- attacks off")
	S.default_attacks_enabled = false
	var s = S.new(5)
	var pres = P.new(s)
	var d = D.create(s, [1, 2, 3], 187.0)
	for tick in 60:
		s.step()
		pres.update(0.1)
		d.update(0.5)
	S.default_attacks_enabled = true
	check(s.attacks.enabled == false and pres.flights.is_empty() and pres.records.is_empty() and pres.signature() == "0:0", "with the attack loop off there are no events, so nothing is presented")
	var none := true
	for id in d.tracks:
		if not d.tracks[id].invaders.is_empty() or not d.tracks[id].frame.invaders.is_empty():
			none = false
	check(none, "and no preview shows an incoming enemy")
