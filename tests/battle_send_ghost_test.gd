extends SceneTree
## Deterministic checks of the enemy-send GHOSTS (doc 55): BattleSendGhost (the measured timeline and geometry, pure), the presentation's list
## of them (BattleAttackPresentation.send_ghosts: one per send, from the authoritative SENT event) and that none of it can change the session.
## The pixels are checked in tests/battle_attack_render_test.gd, the screen's wiring in tests/battle_attack_screen_test.gd.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_send_ghost_test.gd

const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

var failures := 0
var S # BattleSession
var T # BattleEnemyType
var P # BattleAttackPresentation
var G # BattleSendGhost
var GEO # BattleAttackGeometry
var LAYOUT # BattleHudLayout
var AS # BattlePreviewAssets
var K # BattleLevelSketch
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
	P = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
	G = load("res://Scripts/Classes/Battle/BattleSendGhost.gd")
	GEO = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	AS = load("res://Scripts/Classes/Battle/BattlePreviewAssets.gd")
	K = load("res://Scripts/Classes/Battle/BattleLevelSketch.gd")
	GOOMBA = T.Kind.GOOMBA
	KOOPA = T.Kind.KOOPA
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	layout = LAYOUT.compute()
	test_timeline()
	test_geometry()
	test_flash_look()
	test_clipping()
	test_layer_logic()
	test_art()
	test_from_sends()
	test_bots_and_player()
	test_rapid_sends()
	test_ko_pause_and_round_end()
	test_read_only_and_deterministic()
	if failures > 0:
		printerr("%d Battle send ghost test(s) failed" % failures)
	else:
		print("All Battle send ghost tests passed")
	quit(1 if failures > 0 else 0)

# ---- helpers -----------------------------------------------------------------------------------------

func make_session(seed_value := 7, target := -1):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	if target >= 0:
		var p = FixedPolicy.new()
		p.target = target
		s.attacks.targeting = p
	return s

func near(a: float, b: float, eps := 1e-6) -> bool:
	return absf(a - b) < eps

func near_v(a: Vector2, b: Vector2, eps := 1e-3) -> bool:
	return absf(a.x - b.x) < eps and absf(a.y - b.y) < eps

# ---- the timeline ------------------------------------------------------------------------------------

func test_timeline() -> void:
	print("-- the ghost's timeline (measured, doc 55)")
	check(G.FRAMES == 30 and near(G.SECONDS, 0.5) and near(G.FPS, 60.0), "a ghost flies for 30 frames = 0.5 s from the sender to the recipient")
	check(near(G.progress(0.0), 0.0) and near(G.progress(0.25), 0.5) and near(G.progress(0.5), 1.0) and near(G.progress(9.0), 1.0) and near(G.progress(-1.0), 0.0), "progress is linear in time and clamped")
	check(G.in_flight(0.0) and G.in_flight(0.499) and not G.in_flight(0.5) and not G.in_flight(-0.01), "it is in the air for [0, 0.5) s")
	check(G.flash_frame(0.499) == -1 and G.flash_frame(0.5) == 0 and G.flash_frame(0.5 + 1.0 / 60.0) == 1 and G.flash_frame(0.5 + 10.0 / 60.0) == 10 and G.flash_frame(0.5 + 11.0 / 60.0) == -1, "the burst starts on the frame after it arrives and lasts 11 frames")
	check(near(G.FLASH_SECONDS, 11.0 / 60.0) and G.FLASH.size() == G.FLASH_FRAMES, "(11 rows, one per frame)")
	check(not G.finished(0.5) and not G.finished(0.5 + 10.0 / 60.0) and G.finished(0.5 + 11.0 / 60.0), "it is finished when the burst is")
	# the burst: four opaque white frames growing, then translucent light cyan, then a thinning rim
	var w: Array = []
	for k in 4:
		w.append(float(G.FLASH[k][0]))
	check(w[0] < w[1] and w[1] < w[2] and w[2] < w[3] and near(float(G.FLASH[0][0]), 11.6) and near(float(G.FLASH[3][1]), 23.0), "the white square grows 11.6 -> 23 units over four frames")
	var opaque := true
	for k in 4:
		opaque = opaque and near(float(G.FLASH[k][2]), 1.0) and int(G.FLASH[k][3]) == 0
	check(opaque and float(G.FLASH[4][2]) < 1.0 and int(G.FLASH[4][3]) == 1, "...white and opaque, then translucent light cyan")
	var rims := []
	for k in range(7, 11):
		rims.append(float(G.FLASH[k][4]))
	check(rims == [3.0, 2.2, 1.5, 1.0] and float(G.FLASH[7][5]) > float(G.FLASH[10][5]), "the rim thins and fades: 3, 2.2, 1.5, 1.0 units")

func test_geometry() -> void:
	print("-- where a ghost goes")
	var game: Rect2 = layout.game
	check(G.start_point(layout, 0) == game.get_center() and G.start_point(layout, 0) == Vector2(240, 120), "the real player's ghost starts at the middle of the game window")
	var ok := true
	for id in range(1, 35):
		var c: Vector2 = (layout.slots[id - 1] as Rect2).get_center()
		ok = ok and G.start_point(layout, id) == c and G.end_point(layout, id) == c
	check(ok, "a bot's ghost starts at the middle of its own pane, and every ghost ends at the middle of the recipient's (all 34)")
	var a: Vector2 = G.start_point(layout, 20)
	var b: Vector2 = G.end_point(layout, 23)
	check(G.point(layout, 20, 23, 0.0) == a and near_v(G.point(layout, 20, 23, 1.0), b) and near_v(G.point(layout, 20, 23, 0.5), (a + b) / 2.0), "a straight line from one middle to the other")
	var d: float = (b - a).length() / 30.0
	var even := true
	for k in range(1, 31):
		even = even and near((G.point(layout, 20, 23, k / 30.0) - G.point(layout, 20, 23, (k - 1) / 30.0)).length(), d, 1e-3)
	check(even and near(d, 43.0 / 30.0, 0.05), "...at a constant speed (%.2f units a frame: panes 20 and 23 are 43 apart, the measured 1.43)" % d)
	var far: Vector2 = G.end_point(layout, 33) - G.start_point(layout, 0)
	check(near(far.length() / 30.0, 7.5, 0.1), "from the window to the farthest panes it is about 7.5 units a frame (%.2f): a pane sees it for two or three frames" % (far.length() / 30.0))
	var beyond: Vector2 = G.point(layout, 20, 23, 5.0)
	check(near_v(beyond, b) and near_v(G.point(layout, 20, 23, -1.0), a), "outside 0..1 the position is clamped")

func test_flash_look() -> void:
	print("-- the burst's look")
	var pane: Rect2 = layout.slots[32]
	var ok := true
	var centred := true
	for k in 7:
		var l: Dictionary = G.flash_look(k, pane)
		var r: Rect2 = l.rect
		ok = ok and pane.encloses(r) and (l.fill as Color).a > 0.0 and float(l.rim) == 0.0
		centred = centred and near_v(r.get_center(), pane.get_center(), 0.01)
	check(ok and centred, "the square stays in the pane and is centred on its middle for the first seven frames")
	var k0: Dictionary = G.flash_look(0, pane)
	var k3: Dictionary = G.flash_look(3, pane)
	check(near_v((k0.rect as Rect2).size, Vector2(11.6, 11.6), 0.01) and near_v((k3.rect as Rect2).size, Vector2(21.0, 23.0), 0.01) and k0.fill == Color(1, 1, 1, 1), "frame 0 is a white square of 11.6 units, frame 3 one of 21 x 23")
	var k4: Dictionary = G.flash_look(4, pane)
	check((k4.fill as Color).a < 1.0 and (k4.fill as Color).b > 0.99 and (k4.fill as Color).r < 0.85, "frame 4 is translucent light cyan")
	var rim_ok := true
	for k in range(7, 11):
		var l: Dictionary = G.flash_look(k, pane)
		rim_ok = rim_ok and pane.encloses(l.rim_rect) and float(l.rim) > 0.0 and (l.fill as Color).a == 0.0 and (l.rect as Rect2).size == Vector2.ZERO
	check(rim_ok, "frames 7-10 are a rim inside the pane's edge, no fill")
	var none: Dictionary = G.flash_look(-1, pane)
	var over: Dictionary = G.flash_look(11, pane)
	check((none.fill as Color).a == 0.0 and none.rim == 0.0 and (over.fill as Color).a == 0.0 and over.rim == 0.0, "before and after the burst nothing is drawn")

func test_clipping() -> void:
	print("-- a ghost is drawn only inside panes")
	var pane := Rect2(100, 100, 30, 40)
	var rect := Rect2(90, 110, 20, 20) # half out of the pane's left side
	var cut: Array[Rect2] = G.clipped(rect, pane, Vector2(60, 60))
	check(cut[0] == Rect2(100, 110, 10, 20) and near_v(cut[1].position, Vector2(30, 0)) and near_v(cut[1].size, Vector2(30, 60)), "the part inside the pane and the matching part of the picture")
	var inside: Array[Rect2] = G.clipped(Rect2(105, 105, 10, 10), pane, Vector2(30, 30))
	check(inside[0] == Rect2(105, 105, 10, 10) and inside[1] == Rect2(0, 0, 30, 30), "a ghost wholly inside is drawn whole")
	var out: Array[Rect2] = G.clipped(Rect2(0, 0, 10, 10), pane, Vector2(30, 30))
	check(out[0].size == Vector2.ZERO and out[1].size == Vector2.ZERO, "a ghost outside draws nothing")
	# the game window and the gaps are never in a pane
	var game: Rect2 = layout.game
	var any_in_window := false
	for r in layout.slots:
		any_in_window = any_in_window or (r as Rect2).intersects(game)
	var body: Rect2 = G.body_rect(Vector2(16, 16), game.get_center())
	var drawn := 0.0
	for r in layout.slots:
		var c: Array[Rect2] = G.clipped(body, r, Vector2(66, 66))
		drawn += c[0].size.x * c[0].size.y
	check(not any_in_window and drawn == 0.0, "the middle of the game window is in no pane: a send leaves it unseen")
	var in_pane: Rect2 = G.body_rect(Vector2(16, 16), (layout.slots[9] as Rect2).get_center())
	var area := 0.0
	for r in layout.slots:
		var c: Array[Rect2] = G.clipped(in_pane, r, Vector2(66, 66))
		area += c[0].size.x * c[0].size.y
	check(near(area, in_pane.size.x * in_pane.size.y, 0.01), "a ghost at a pane's middle is drawn whole (%.1f of %.1f)" % [area, in_pane.size.x * in_pane.size.y])
	check(near_v(G.body_rect(Vector2(16, 16), Vector2.ZERO).size, Vector2(22, 22) * 10.0 / 16.0), "a 16-pixel enemy is drawn about 10 units wide with its glow (%s)" % [G.body_rect(Vector2(16, 16), Vector2.ZERO).size])

func test_layer_logic() -> void:
	print("-- the layer's own decisions")
	var BattleLayer = load("res://Scripts/Classes/Battle/BattleSendGhostLayer.gd")
	var Pane = load("res://Scripts/Classes/Battle/BattleOpponentPane.gd")
	var gl = BattleLayer.new(layout)
	check(gl.drawn().is_empty() and gl.ghost_art(1) == null, "an unbound layer draws nothing and has no art")
	check(gl.shows_burst(5) and not gl.shows_burst(0) and not gl.shows_burst(35), "a burst can be on any of the 34 panes, and on no other")
	var pane = Pane.new(5)
	pane.marked = true
	gl.panes = [null, null, null, null, pane]
	check(not gl.shows_burst(5) and gl.shows_burst(4), "a pane showing its KO card gets no burst; its neighbours do")
	pane.marked = false
	check(gl.shows_burst(5), "...and does again when it is not showing one")
	var s = make_session(7, 9)
	var pres = P.new(s)
	gl.bind(pres, null)
	s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	check(gl.drawn().size() == 1 and gl.drawn()[0].target == 9, "a bound layer reads the presentation's ghosts")
	gl.bind(null, null)
	check(gl.drawn().is_empty(), "...and nothing once unbound (a new round)")
	var sk = K.load_for("res://Scenes/Levels/SMB1/World1/1-1.tscn")
	var art = AS.build(sk)
	gl.bind(pres, art)
	check(gl.ghost_art(GOOMBA) != null and gl.ghost_art(KOOPA) != null and gl.ghost_art(GOOMBA) != gl.ghost_art(KOOPA) and gl.ghost_art(0) == null, "with the level's art each supported enemy type has its own ghost, and an unsupported one has none")
	pane.free()
	gl.free()

func test_art() -> void:
	print("-- the ghost's picture")
	var sk = K.load_for("res://Scenes/Levels/SMB1/World1/1-1.tscn")
	var art = AS.build(sk)
	for kind in ["goomba", "koopa_green"]:
		var spr = art.enemy_frame(kind, 0.0)
		var ghost = G.ghost_of(spr)
		check(ghost != null and ghost.texture != null and ghost.texture.get_width() == (int(spr.size.x) + G.PAD * 2) * G.SCALE and ghost.texture.get_height() == (int(spr.size.y) + G.PAD * 2) * G.SCALE, "%s: a ghost texture %dx%d, the sprite enlarged %dx with a margin" % [kind, ghost.texture.get_width(), ghost.texture.get_height(), G.SCALE])
		check(G.ghost_of(spr) == ghost, "%s: built once and cached" % kind)
		var img: Image = ghost.texture.get_image()
		var max_a := 0.0
		var whites := 0
		var greys := 0
		var opaque := 0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				max_a = maxf(max_a, c.a)
				if c.a > 0.5:
					opaque += 1
					if c.r > 0.9 and c.g > 0.9 and c.b > 0.9:
						whites += 1
					elif absf(c.r - c.g) < 0.2 and c.b >= c.r - 0.05 and c.r < 0.7:
						greys += 1
		check(max_a <= G.ALPHA + 0.02 and max_a > 0.5, "%s: translucent (most opaque pixel %.2f)" % [kind, max_a])
		check(whites > 10 and greys > 10 and opaque > 100, "%s: white where the sprite is light, grey-teal where it is dark (%d white, %d grey of %d)" % [kind, whites, greys, opaque])
	var goomba_size: Vector2 = G.body_rect(art.enemy_frame("goomba", 0.0).size, Vector2.ZERO).size
	var koopa_size: Vector2 = G.body_rect(art.enemy_frame("koopa_green", 0.0).size, Vector2.ZERO).size
	check(goomba_size.x > 8.0 and goomba_size.x < 16.0 and koopa_size.y > goomba_size.y, "a Goomba's ghost is about 10-14 units wide and a Koopa's is taller (%s, %s)" % [goomba_size, koopa_size])
	check(G.ghost_of(null) == null, "no sprite, no ghost")

# ---- from sends --------------------------------------------------------------------------------------

func test_from_sends() -> void:
	print("-- ghosts from the session's sends")
	var s = make_session(7, 9)
	var pres = P.new(s)
	check(pres.send_ghosts().is_empty(), "a presentation starts with no ghost")
	var a = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	var gs: Array = pres.send_ghosts()
	check(gs.size() == 1 and gs[0].seq == a.seq and gs[0].sender == 0 and gs[0].target == 9 and gs[0].kind == GOOMBA and gs[0].age == 0.0, "the real player's send makes one ghost, at the authoritative recipient (#9), of the enemy type sent, from the real player")
	pres.update(0.25)
	gs = pres.send_ghosts()
	check(gs.size() == 1 and near(gs[0].age, 0.25) and near(G.progress(gs[0].age), 0.5), "it flies for 0.5 s: half way at 0.25 s")
	pres.update(0.25)
	gs = pres.send_ghosts()
	check(gs.size() == 1 and G.flash_frame(gs[0].age) == 0, "it bursts on the recipient's pane the frame after it arrives (age %.3f)" % gs[0].age)
	pres.update(G.FLASH_SECONDS - 0.001)
	check(pres.send_ghosts().size() == 1 and G.flash_frame(pres.send_ghosts()[0].age) == 10, "the burst's last frame")
	pres.update(0.01)
	check(pres.send_ghosts().is_empty(), "...and then nothing is left (%.3f s after the send)" % (G.SECONDS + G.FLASH_SECONDS))
	check(pres.is_animating() == false, "the presentation is at rest again")
	var b = s.report_enemy_defeat(0, KOOPA)
	pres.update(0.0)
	check(pres.send_ghosts().size() == 1 and pres.send_ghosts()[0].kind == KOOPA and pres.send_ghosts()[0].seq == b.seq, "a Koopa's send is a Koopa's ghost")
	check(pres.is_animating(), "a ghost in the air keeps the presentation animating")
	# silent replay: a presentation made mid-round draws nothing for what already happened
	var late = P.new(s)
	check(late.send_ghosts().is_empty(), "a presentation made after the sends has no ghost for them")

func test_bots_and_player() -> void:
	print("-- bot sends, and sends at the real player")
	var s = make_session(7, 9)
	var pres = P.new(s)
	var a = s.report_enemy_defeat(5, KOOPA) # a bot sends at bot 9
	pres.update(0.0)
	var gs: Array = pres.send_ghosts()
	check(gs.size() == 1 and gs[0].sender == 5 and gs[0].target == 9 and gs[0].kind == KOOPA and gs[0].seq == a.seq, "a bot's send at another bot makes a ghost from the bot's pane to the recipient's (doc 51's 'bot sends are not drawn' was wrong)")
	check(pres.flights.is_empty() and pres.player_flights().is_empty(), "...but no reticle flight: that is the real player's alone")
	var s2 = make_session(7, 0)
	var p2 = P.new(s2)
	for id in range(1, 8):
		s2.report_enemy_defeat(id, GOOMBA)
	p2.update(0.0)
	check(p2.send_ghosts().is_empty() and p2.counts(0).x == 7, "sends at the real player make no ghost on any pane (their picture is the line and the bar's icon): 7 attacks, none")
	var s3 = make_session(7, 4)
	var p3 = P.new(s3)
	var made := 0
	for id in range(0, 12):
		if s3.report_enemy_defeat(id, GOOMBA if id % 2 == 0 else KOOPA) != null:
			made += 1
	p3.update(0.0)
	var ghosts: Array = p3.send_ghosts()
	var by_seq := {}
	for g in ghosts:
		by_seq[g.seq] = g
	var truth: Array = s3.attacks.attack_history()
	var match_ok := true
	var at_player := 0
	for t in truth:
		if t.target == 0:
			at_player += 1
			continue
		match_ok = match_ok and by_seq.has(t.seq) and by_seq[t.seq].sender == t.sender and by_seq[t.seq].target == t.target and by_seq[t.seq].kind == t.kind
	check(made >= 10 and ghosts.size() == made - at_player and match_ok, "twelve sends at once: a ghost for each, matching its authoritative attack (%d ghosts)" % ghosts.size())
	var ordered := true
	for i in range(1, ghosts.size()):
		ordered = ordered and ghosts[i].seq > ghosts[i - 1].seq
	check(ordered, "...in send order, oldest first")

func test_rapid_sends() -> void:
	print("-- rapid sends")
	var s = make_session(11, 9)
	var pres = P.new(s)
	var q1 = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	pres.update(0.05)
	var q2 = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	pres.update(0.05)
	var q3 = s.report_enemy_defeat(0, KOOPA)
	pres.update(0.0)
	check(pres.player_flights().size() == 1 and pres.player_flights()[0].seq == q3.seq, "three sends in 0.1 s: one bracket in the air (the newest)")
	var gs: Array = pres.send_ghosts()
	check(gs.size() == 3 and gs[0].seq == q1.seq and gs[1].seq == q2.seq and gs[2].seq == q3.seq, "...but a ghost for each of the three: a cancelled bracket does not cancel the enemy that was sent")
	check(near(gs[0].age, 0.10) and near(gs[1].age, 0.05) and near(gs[2].age, 0.0), "each has its own clock, the oldest the furthest along (%.2f, %.2f, %.2f)" % [gs[0].age, gs[1].age, gs[2].age])
	check(gs[0].kind == GOOMBA and gs[2].kind == KOOPA, "each carries its own enemy type")
	pres.update(0.40)
	gs = pres.send_ghosts()
	check(G.flash_frame(gs[0].age) == 0 and G.flash_frame(gs[1].age) == -1 and gs.size() == 3, "the bursts come in the order of the sends, one frame-step apart")
	pres.update(0.05)
	gs = pres.send_ghosts()
	check(G.flash_frame(gs[1].age) == 0 and G.flash_frame(gs[0].age) == 3, "...each on its own schedule")
	pres.update(2.0)
	check(pres.send_ghosts().is_empty(), "and all of them are gone in the end")
	var big = make_session(3, 5)
	var bp = P.new(big)
	for i in 400:
		big.report_enemy_defeat(0, GOOMBA)
	bp.update(0.0)
	check(bp.send_ghosts().size() <= bp.MAX_GHOSTS and bp.send_ghosts().size() > 0 and bp.records.size() == 400, "400 sends at once: the safety valve holds (%d ghosts), every attack is still recorded" % bp.send_ghosts().size())

func test_ko_pause_and_round_end() -> void:
	print("-- the recipient out, pause, round end")
	var s = make_session(7, 9)
	var pres = P.new(s)
	var a = s.report_enemy_defeat(0, GOOMBA)
	pres.update(0.0)
	pres.update(0.2)
	s.report_ko(9, S.KoCause.HAZARD) # the recipient is eliminated while the ghost is in the air
	pres.update(0.0)
	var gs: Array = pres.send_ghosts()
	check(gs.size() == 1 and gs[0].seq == a.seq and gs[0].target == 9, "the recipient's KO does not change the ghost: it flies on and arrives (the pane decides whether to burst)")
	pres.update(0.4)
	check(pres.send_ghosts().size() == 1 and G.flash_frame(pres.send_ghosts()[0].age) >= 0, "(and its burst frame comes on time)")
	pres.update(1.0)
	check(pres.send_ghosts().is_empty(), "...and then it is gone: nothing is left on a KO'd pane")
	# pause: the presentation clock does not advance
	var s2 = make_session(7, 9)
	var p2 = P.new(s2)
	s2.report_enemy_defeat(0, GOOMBA)
	p2.update(0.1)
	var age: float = p2.send_ghosts()[0].age
	for i in 120:
		p2.update(0.0)
	check(near(p2.send_ghosts()[0].age, age) and p2.send_ghosts().size() == 1, "while paused (no presentation time passes) a ghost does not move, not even in 120 frames")
	p2.update(0.1)
	check(near(p2.send_ghosts()[0].age, age + 0.1), "...and carries on from where it stopped")
	# round end
	s2.report_enemy_defeat(0, KOOPA)
	p2.update(0.0)
	check(p2.send_ghosts().size() == 2, "(two ghosts in the air)")
	p2.clear_flights()
	check(p2.send_ghosts().is_empty(), "the round ending clears every transient send animation at once")
	p2.update(1.0)
	check(p2.send_ghosts().is_empty(), "...and they do not come back")
	# the session resolving the round's attacks never revives a ghost
	s2.resolve_to_end()
	p2.update(0.0)
	check(p2.send_ghosts().is_empty(), "(and nothing is drawn after the end)")

func test_read_only_and_deterministic() -> void:
	print("-- presentation only")
	var plain = S.new(19)
	var shown = S.new(19)
	var pres = P.new(shown)
	for tick in 150:
		plain.step()
		shown.step()
		if tick % 5 == 0 and shown.get_player().alive:
			plain.report_enemy_defeat(0, GOOMBA)
			shown.report_enemy_defeat(0, GOOMBA)
		pres.update(1.0)
		pres.send_ghosts()
	check(JSON.stringify(plain.snapshot()) == JSON.stringify(shown.snapshot()) and plain.attacks.attack_history().size() == shown.attacks.attack_history().size(), "the session is identical with the ghosts attached: they only read it")
	var counts_ok := true
	for g in pres.send_ghosts():
		var truth: Dictionary = shown.attacks.attack_history()[g.seq]
		counts_ok = counts_ok and truth.target == g.target and truth.sender == g.sender and truth.kind == g.kind
	check(counts_ok, "every ghost on screen is an authoritative attack with its own recipient")
	var a = run_script(31)
	var b = run_script(31)
	check(a.size() > 20 and a == b, "the same events and deltas give identical ghosts (%d samples)" % a.size())
	var code := FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleSendGhost.gd") + FileAccess.get_file_as_string("res://Scripts/Classes/Battle/BattleSendGhostLayer.gd")
	var banned := ["report_", "attacks.", ".targeting", "randf", "randi", "RandomNumberGenerator", "choose("]
	var hits := []
	for word in banned:
		if code.contains(word):
			hits.append(word)
	check(hits.is_empty(), "the ghost classes never call into the session, the attack system or any rng (%s)" % [hits])

func run_script(seed_value: int) -> Array:
	var s = S.new(seed_value)
	var pres = P.new(s)
	var out := []
	for tick in 80:
		s.step()
		if tick % 3 == 0 and s.get_player().alive:
			s.report_enemy_defeat(0, GOOMBA if tick % 2 == 0 else KOOPA)
		pres.update(0.5)
		for g in pres.send_ghosts():
			out.append("%d:%d>%d:%d:%.3f" % [g.seq, g.sender, g.target, g.kind, g.age])
	return out
