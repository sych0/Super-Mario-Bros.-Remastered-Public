extends SceneTree
## The SMB35 UI fidelity pass (doc 50), on its own and without a level: the targeting selector's states and timeline, the
## reticle's geometry and punch, the incoming bar's icon placement and its phase mapping (from a real session and
## presentation), WATCH OUT! and the eye counter's state, the match-start banner, the KO card's timeline and state,
## the HUD's text, and that none of these views can reach the session. Everything here is pure data or a Control that is
## never drawn. The same pieces on the real screen (pause, round restart, the real game) are in
## tests/battle_attack_screen_test.gd and tests/battle_round_lifecycle_test.gd, and their pixels in the GL suites.
##   godot --headless --path . -s tests/battle_ui_test.gd

const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""
const UI_FILES := ["BattleTargetSelector", "BattleHud", "BattleHudText", "BattleHudShapes", "BattleBadge", "BattleBanner",
	"BattleStatusStrip", "BattleTargetReticle", "BattleOpponentPane", "BattleIncomingStrip"]

var failures := 0
var S # BattleSession
var A # BattleAttack
var P # BattleAttackPresentation
var F # BattleAttackFlight
var SEL # BattleTargetSelector
var RET # BattleTargetReticle
var STRIP # BattleIncomingStrip
var STATUS # BattleStatusStrip
var BANNER # BattleBanner
var PANE # BattleOpponentPane
var HUD # BattleHud
var TXT # BattleHudText
var LAYOUT # BattleHudLayout
var CONTESTANT # BattleContestant
var Mode
var Phase
var FixedPolicy
var layout := {}

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	A = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	P = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
	F = load("res://Scripts/Classes/Battle/BattleAttackFlight.gd")
	SEL = load("res://Scripts/Classes/Battle/BattleTargetSelector.gd")
	RET = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd")
	STRIP = load("res://Scripts/Classes/Battle/BattleIncomingStrip.gd")
	STATUS = load("res://Scripts/Classes/Battle/BattleStatusStrip.gd")
	BANNER = load("res://Scripts/Classes/Battle/BattleBanner.gd")
	PANE = load("res://Scripts/Classes/Battle/BattleOpponentPane.gd")
	HUD = load("res://Scripts/Classes/Battle/BattleHud.gd")
	TXT = load("res://Scripts/Classes/Battle/BattleHudText.gd")
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	CONTESTANT = load("res://Scripts/Classes/Battle/BattleContestant.gd")
	Mode = load("res://Scripts/Classes/Battle/BattleTargeting.gd").Mode
	Phase = P.Phase
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	layout = LAYOUT.compute()
	test_text_helper()
	test_selector_timeline()
	test_selector_state_and_geometry()
	test_reticle()
	test_incoming_bar_placement()
	test_incoming_bar_phase_mapping()
	test_watch_out_and_status()
	test_banner()
	test_ko_card()
	test_hud()
	test_read_only()
	if failures > 0:
		printerr("%d Battle UI test(s) failed" % failures)
	else:
		print("All Battle UI tests passed")
	quit(1 if failures > 0 else 0)

func make_session(target := -1):
	var s = S.new(7)
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	if target >= 0:
		var p = FixedPolicy.new()
		p.target = target
		s.attacks.targeting = p
	return s

# ---- text ------------------------------------------------------------------------------------------------------------

func test_text_helper() -> void:
	print("-- the bitmap text helper")
	check(near(TXT.ink_width("A", 1.0), 7.0) and near(TXT.ink_width("AB", 1.0), 15.0) and near(TXT.ink_width("AB", 0.5), 7.5) and TXT.ink_width("", 2.0) == 0.0, "n characters are 8n - 1 px of ink wide at scale 1 (the font advances 8 px with 7 px glyphs)")
	check(near(TXT.ink_height(2.0), 14.0), "and 7 px tall")
	check(near(TXT.fit_scale("LOWEST TIME", 40.0, 1.0), 40.0 / 87.0) and TXT.fit_scale("A", 40.0, 1.0) == 1.0, "a text is fitted to its room, never enlarged past the wanted scale")

# ---- the selector ----------------------------------------------------------------------------------------------------------

func test_selector_timeline() -> void:
	print("-- the selector's timeline (doc 47 B35-TARGET-005)")
	check(SEL.opacity_at(0.0) == 1.0 and SEL.opacity_at(SEL.HOLD * 0.99) == 1.0, "on a change the whole cross is fully opaque at once, and stays so for %.1f s" % SEL.HOLD)
	check(near(SEL.opacity_at(SEL.FADE_END), SEL.REST_ALPHA) and SEL.opacity_at(99.0) == SEL.REST_ALPHA, "it is back at rest (translucent, %.2f) by %.2f s" % [SEL.REST_ALPHA, SEL.FADE_END])
	var monotone := true
	var last := 2.0
	for i in 200:
		var a: float = SEL.opacity_at(float(i) * 0.01)
		if a > last + 1e-6:
			monotone = false
		last = a
	check(monotone, "the fade never brightens again on its way down")
	check(SEL.FADE_END >= 1.5 and SEL.FADE_END <= 2.0, "the whole change takes between 1.5 and 2 s (the reference's 1.5-2 s)")
	check(SEL.label_scale_at(0.0) == 1.0 and near(SEL.label_scale_at(SEL.SWELL_PEAK), 1.0 + SEL.SWELL) and SEL.label_scale_at(SEL.SWELL_END) == 1.0 and SEL.label_scale_at(5.0) == 1.0, "the new pill's label swells to %.0f%% by %.2f s and settles by %.2f s" % [(1.0 + SEL.SWELL) * 100.0, SEL.SWELL_PEAK, SEL.SWELL_END])
	var never_smaller := true
	for i in 100:
		if SEL.label_scale_at(float(i) * 0.01) < 1.0:
			never_smaller = false
	check(never_smaller, "the label is never smaller than at rest")
	check(SEL.glow_at(0.0) == 1.0 and near(SEL.glow_at(SEL.SWELL_END), 0.45) and near(SEL.glow_at(9.0), 0.45), "the chosen pill's glow starts full and settles to a steady glow")
	check(SEL.shake_at(SEL.REFUSE_SECONDS) == 0.0 and absf(SEL.shake_at(0.05)) <= 1.5 and SEL.shake_at(-1.0) == 0.0, "a refused pill's shake is small and ends in %.1f s" % SEL.REFUSE_SECONDS)

func test_selector_state_and_geometry() -> void:
	print("-- the selector's states and place")
	var sel = SEL.new(layout.hud.selector, null)
	check(sel.mode == Mode.RANDOM and not sel.is_animating() and sel.opacity() == SEL.REST_ALPHA, "a fresh selector shows Random, at rest and translucent")
	check(sel.available[Mode.RANDOM] and sel.available[Mode.LOWEST_TIME] and sel.available[Mode.ATTACKERS] and not sel.available[Mode.MOST_COINS], "Most Coins is drawn as unavailable (it has no data yet); the other three can be chosen")
	sel.set_mode(Mode.RANDOM)
	check(sel.age >= SEL.FADE_END and not sel.is_animating(), "setting the mode it already has does nothing")
	sel.set_mode(Mode.LOWEST_TIME)
	check(sel.mode == Mode.LOWEST_TIME and sel.age == 0.0 and sel.opacity() == 1.0 and sel.is_animating(), "a different mode takes effect at once: chosen, age 0, opaque")
	sel.advance(0.0)
	check(sel.age == 0.0, "no time passing (the game is paused) leaves the animation where it is")
	sel.advance(1.0)
	check(near(sel.age, 1.0) and sel.opacity() < 1.0 and sel.opacity() > SEL.REST_ALPHA, "a second later it is fading (opacity %.2f)" % sel.opacity())
	sel.advance(1.0)
	check(not sel.is_animating() and sel.opacity() == SEL.REST_ALPHA and sel.mode == Mode.LOWEST_TIME, "after two seconds it rests again, still on Lowest Time")
	sel.set_mode(Mode.LOWEST_TIME, true)
	check(sel.age == 0.0 and sel.mode == Mode.LOWEST_TIME, "choosing the mode it already has lights the cross again (a touch)")
	sel.advance(3.0)
	sel.refuse(Mode.MOST_COINS)
	check(sel.mode == Mode.LOWEST_TIME and sel.refused_mode == Mode.MOST_COINS and sel.refuse_age == 0.0 and sel.opacity() == 1.0 and sel.is_animating(), "trying Most Coins lights the cross and marks the pill but keeps the mode")
	sel.advance(SEL.REFUSE_SECONDS + 0.01)
	check(sel.refuse_age >= SEL.REFUSE_SECONDS and SEL.shake_at(sel.refuse_age) == 0.0, "the refusal ends by itself")
	sel.set_available(Mode.MOST_COINS, true)
	check(sel.available[Mode.MOST_COINS], "when coin data exists the pill becomes available")
	# arrangement: Lowest Time top, Random left, Most Coins right, Attackers bottom, the centre button between
	var s2 = SEL.new(layout.hud.selector, null)
	var lt: Rect2 = s2.pill_rect(Mode.LOWEST_TIME)
	var rn: Rect2 = s2.pill_rect(Mode.RANDOM)
	var mc: Rect2 = s2.pill_rect(Mode.MOST_COINS)
	var at: Rect2 = s2.pill_rect(Mode.ATTACKERS)
	var c: Vector2 = layout.hud.selector.center
	check(lt.end.y <= rn.position.y and rn.end.y <= at.position.y and mc.position.y == rn.position.y, "Lowest Time is the top pill, Random and Most Coins share the middle row, Attackers is the bottom pill")
	check(rn.end.x <= c.x - 3.0 and mc.position.x >= c.x + 3.0 and absf(lt.get_center().x - c.x) <= 1.0 and absf(at.get_center().x - c.x) <= 1.0, "Random is left of the centre button, Most Coins right of it, the other two centred above and below it")
	var clear := true
	var pills := [lt, rn, mc, at]
	for i in 4:
		for j in range(i + 1, 4):
			if (pills[i] as Rect2).intersects(pills[j]):
				clear = false
		if not (layout.game as Rect2).encloses(pills[i]):
			clear = false
	check(clear, "the four pills don't overlap and sit inside the game window")
	var swollen: Rect2 = s2.pill_rect(Mode.LOWEST_TIME, 1.0 + SEL.SWELL)
	check(swollen.size.x >= TXT.ink_width("LOWEST TIME", SEL.TEXT_SCALE * (1.0 + SEL.SWELL)) and (layout.game as Rect2).encloses(swollen) and not swollen.intersects(rn) and not swollen.intersects(mc), "the chosen pill grows with its swelling label and still clears its neighbours")
	var fit := true
	for m in SEL.LABELS:
		var r: Rect2 = s2.pill_rect(m)
		if TXT.ink_width(SEL.LABELS[m], SEL.TEXT_SCALE) > r.size.x - SEL.PAD * 2.0 + 0.001:
			fit = false
	check(fit, "every label fits its pill")
	check(SEL.LABELS == {Mode.LOWEST_TIME: "LOWEST TIME", Mode.RANDOM: "RANDOM", Mode.MOST_COINS: "MOST COINS", Mode.ATTACKERS: "ATTACKERS"}, "the labels are the four modes' names")
	sel.free()
	s2.free()

# ---- the reticle -------------------------------------------------------------------------------------------------------

func test_reticle() -> void:
	print("-- the reticle")
	var slots: Array = layout.slots
	var ok_outside := true
	var ok_gap := true
	var ok_arms := true
	for i in slots.size():
		var pane: Rect2 = slots[i]
		var rects: Array[Rect2] = RET.corner_rects(pane)
		if rects.size() != 8:
			ok_arms = false
		var union := Rect2()
		for k in rects.size():
			var r: Rect2 = rects[k]
			union = r if k == 0 else union.merge(r)
			if r.intersects(pane):
				ok_outside = false
			for j in slots.size():
				if j != i and r.intersects(slots[j]):
					ok_gap = false
			if not (is_equal_approx(minf(r.size.x, r.size.y), RET.THICKNESS)):
				ok_arms = false
		if not union.is_equal_approx(pane.grow(RET.OUTSET + RET.THICKNESS)):
			ok_arms = false
	check(ok_arms, "eight corner rects, 0.75 thick, whose union is the pane grown by 0.5 + 0.75 (all 34)")
	check(ok_outside, "the bracket never touches its own pane's picture (all 34)")
	check(ok_gap, "...nor any other pane: it lives in the gap between panes (all 34)")
	var one: Array[Rect2] = RET.corner_rects(slots[0])
	check(near(one[0].size.x, slots[0].size.x * RET.ARM_FRACTION + RET.THICKNESS), "an arm is a quarter of the pane's width (plus the corner)")
	var wide: Array[Rect2] = RET.corner_rects(slots[0], 2.0)
	check(wide[0].position.x < one[0].position.x and wide[0].position.y < one[0].position.y, "a punch spreads the bracket outward")
	var ret = RET.new(layout)
	check(not ret.visible and ret.target == 0, "no target: no reticle")
	ret.set_target(5)
	check(ret.visible and ret.target == 5 and ret.pulse_age == 0.0, "a target shows it, punching as it arrives")
	ret.advance(0.0)
	check(ret.pulse_age == 0.0, "paused time does not advance the punch")
	ret.advance(RET.PULSE_SECONDS + 0.1)
	check(RET.pulse_amount(ret.pulse_age) == 0.0, "the punch is over in %.1f s" % RET.PULSE_SECONDS)
	ret.set_target(5)
	check(ret.pulse_age >= RET.PULSE_SECONDS, "the same target again does not punch")
	ret.pulse()
	check(ret.pulse_age == 0.0 and RET.pulse_amount(0.0) == 1.0, "a mode change punches on the current pane")
	ret.set_target(0)
	check(not ret.visible, "no target hides it")
	ret.set_target(-1)
	check(not ret.visible and ret.target == 0, "-1 hides it too")
	ret.set_target(35)
	check(not ret.visible, "an id past the 34 opponents hides it")
	check(RET.COLOR.r > 225.0 / 255.0 and RET.COLOR.g < 50.0 / 255.0 and RET.COLOR.b < 70.0 / 255.0, "it is the reference's pure red (r>225, g<50, b<70)")
	ret.free()

# ---- the incoming bar -----------------------------------------------------------------------------------------------------

func item(phase: int, seq: int, extra := {}) -> Dictionary:
	var d := {"seq": seq, "kind": 1, "phase": phase, "in_transit": false, "age": 0.0, "waited": -1.0, "arrive": 0.0, "fresh": 0.0, "flash": 0.0, "spawned": false}
	d.merge(extra, true)
	return d

func test_incoming_bar_placement() -> void:
	print("-- the incoming bar: where icons are")
	var w: float = layout.strip_a.size.x
	var b: float = STRIP.gold_end(w)
	check(near(b, w / 3.0) and near(STRIP.ORANGE_FRACTION, 2.0 / 3.0) and STRIP.TEETH == 3, "the bar is gold for the left third, orange for the next third, darker orange after it, with 3-tooth boundaries")
	var pts: PackedVector2Array = STRIP.jagged(b, 12.0)
	check(pts.size() == 7 and pts[0].y == 0.0 and pts[6].y == 12.0 and near(pts[1].x, b + STRIP.TOOTH_DEPTH) and near(pts[0].x, b) and near(pts[2].x, b) and near(pts[5].x, b + STRIP.TOOTH_DEPTH), "a jagged boundary is a zig-zag of three teeth over the bar's height")
	var entry: float = STRIP.entry_x(w)
	var slot0: float = b + STRIP.WAIT_OFFSET
	# one icon in the air, then landed and travelling, then waiting
	var xs: PackedFloat32Array = STRIP.place_all([item(Phase.QUEUED, 1, {"in_transit": true})], w)
	check(near(xs[0], entry), "an attack whose line is still in the air waits at the bar's right end (%.1f)" % xs[0])
	var travel: float = STRIP.TRAVEL_SECONDS
	check(near(travel, 3.0 - F.DURATION), "an icon takes the attack system's activation delay, counted from the send, to reach the boundary (%.2f s after it lands)" % travel)
	xs = STRIP.place_all([item(Phase.QUEUED, 1, {"age": 0.0})], w)
	check(near(xs[0], entry), "a just-landed icon starts at the right end")
	xs = STRIP.place_all([item(Phase.QUEUED, 1, {"age": travel / 2.0})], w)
	check(near(xs[0], (entry + slot0) / 2.0), "half the time later it is half way to the boundary")
	xs = STRIP.place_all([item(Phase.QUEUED, 1, {"age": travel * 3.0})], w)
	check(near(xs[0], slot0) and xs[0] > b, "it stops at the boundary's right side and waits there")
	xs = STRIP.place_all([item(Phase.ARRIVING, 1, {"age": 0.5, "waited": 1.0, "state": 1})], w)
	check(near(xs[0], slot0), "an ACTIVE icon that is not at the boundary yet is there within %.1f s of becoming ACTIVE" % STRIP.CATCH_UP_SECONDS)
	# several: order, spacing, crossing
	var many: Array[Dictionary] = []
	for k in 6:
		many.append(item(Phase.QUEUED, k, {"age": 0.4 * (6 - k)}))
	xs = STRIP.place_all(many, w)
	var ordered := true
	for k in range(1, 6):
		if xs[k] <= xs[k - 1]:
			ordered = false
	check(ordered, "icons keep their send order along the bar: an older one is always nearer the boundary")
	many.clear()
	for k in 4:
		many.append(item(Phase.ARRIVING, k, {"age": 9.0, "waited": 5.0}))
	xs = STRIP.place_all(many, w)
	check(near(xs[1] - xs[0], STRIP.PITCH) and near(xs[3] - xs[0], 3.0 * STRIP.PITCH), "icons waiting at the boundary stand %.0f px apart" % STRIP.PITCH)
	# in the level: the gold zone
	xs = STRIP.place_all([item(Phase.IN_LEVEL, 1, {"arrive": 0.0, "age": 9.0, "waited": 9.0}), item(Phase.IN_LEVEL, 2, {"arrive": 0.0})], w)
	check(near(xs[0], STRIP.IN_LEVEL_X0) and near(xs[1], STRIP.IN_LEVEL_X0 + STRIP.PITCH) and xs[1] < b, "an enemy in the level is a marker in the gold zone, in send order")
	xs = STRIP.place_all([item(Phase.IN_LEVEL, 1, {"arrive": 1.0})], w)
	check(near(xs[0], b), "the moment it appears in the level its icon is at the gold boundary (the release), then moves into the gold zone")
	xs = STRIP.place_all([item(Phase.IN_LEVEL, 1, {"arrive": 0.5})], w)
	check(xs[0] > b - 0.001 and xs[0] < STRIP.IN_LEVEL_X0 + 0.001 or xs[0] > STRIP.IN_LEVEL_X0 - 0.001 and xs[0] < b, "...half way through it is between the two")
	# ghosts keep the slot of the phase they were in
	var merged: Array[Dictionary] = STRIP.merged([item(Phase.ARRIVING, 5, {"age": 9.0, "waited": 4.0})] as Array[Dictionary],
		[{"seq": 3, "kind": 1, "cause": 0, "spawned": true, "fade": 0.5}, {"seq": 4, "kind": 1, "cause": 0, "spawned": false, "fade": 0.5}] as Array[Dictionary])
	check(merged.size() == 3 and int(merged[0].seq) == 3 and merged[0].get("ghost", false) and int(merged[2].seq) == 5, "a fading icon is merged in send order, and is marked as a ghost")
	xs = STRIP.place_all(merged, w)
	check(near(xs[0], STRIP.IN_LEVEL_X0) and near(xs[1], slot0) and near(xs[2], slot0 + STRIP.PITCH), "a fading icon keeps the place it had (the gold zone if its enemy was in the level, else the waiting slots)")
	# everything stays inside the bar
	var crowd: Array[Dictionary] = []
	for k in 30:
		crowd.append(item(Phase.IN_LEVEL if k < 10 else Phase.ARRIVING, k, {"age": 99.0, "waited": 99.0}))
	xs = STRIP.place_all(crowd, w)
	var inside := true
	for x in xs:
		if x < 0.0 or x > w:
			inside = false
	check(inside, "even a crowd of 30 stays inside the bar")
	check(STRIP.progress_of(item(Phase.QUEUED, 1, {"in_transit": true, "age": 5.0})) == 0.0 and STRIP.progress_of(item(Phase.QUEUED, 1, {"age": travel})) == 1.0, "an icon in the air has gone nowhere; one that landed a travel time ago has gone all the way")

func test_incoming_bar_phase_mapping() -> void:
	print("-- the incoming bar: phases follow the authoritative state")
	var s = make_session(0)
	var pres = P.new(s)
	var a = s.report_enemy_defeat(4, 1)
	pres.update(0.0)
	var row: Dictionary = pres.player_incoming()[0]
	check(a != null and row.seq == a.seq and row.phase == Phase.QUEUED and row.in_transit and row.waited < 0.0, "a bot's send at the player is a QUEUED icon whose line is in the air")
	var w: float = layout.strip_a.size.x
	check(near(STRIP.place_all([row], w)[0], STRIP.entry_x(w)), "...at the bar's right end")
	pres.update(F.DURATION + 0.05)
	row = pres.player_incoming()[0]
	check(row.phase == Phase.QUEUED and not row.in_transit and row.age > 0.0 and row.age < 0.2, "when the line lands the icon starts its trip (%.2f s)" % row.age)
	pres.update(1.0)
	var mid: float = STRIP.place_all([pres.player_incoming()[0]], w)[0]
	check(mid < STRIP.entry_x(w) and mid > STRIP.gold_end(w) + STRIP.WAIT_OFFSET, "a second on it is on its way (x %.1f)" % mid)
	for i in 3:
		s.step()
	pres.update(0.0)
	row = pres.player_incoming()[0]
	check(row.phase == Phase.ARRIVING and row.state == A.State.ACTIVE and row.waited >= 0.0, "when the session activates the attack the icon is ARRIVING (%s)" % [row])
	pres.update(1.0)
	check(near(STRIP.place_all([pres.player_incoming()[0]], w)[0], STRIP.gold_end(w) + STRIP.WAIT_OFFSET), "and waits at the gold boundary")
	check(s.report_player_incoming_spawned(a.seq), "(the real game puts the enemy in the level)")
	pres.update(0.0)
	row = pres.player_incoming()[0]
	check(row.phase == Phase.IN_LEVEL and row.arrive > 0.9, "the icon becomes IN_LEVEL and flashes")
	pres.update(1.0)
	var gold_x: float = STRIP.place_all([pres.player_incoming()[0]], w)[0]
	check(near(gold_x, STRIP.IN_LEVEL_X0) and gold_x < STRIP.gold_end(w), "and settles in the gold zone")
	check(s.resolve_player_incoming(a.seq, A.Resolution.DEFEATED_BY_PLAYER), "(the player defeats it)")
	pres.update(0.0)
	check(pres.player_incoming().is_empty() and pres.player_resolved().size() == 1 and pres.player_resolved()[0].spawned, "the icon leaves the list and fades where it was")
	pres.update(P.RESOLVE_FADE + 0.1)
	check(pres.player_resolved().is_empty(), "...and is gone")
	# a bar for the same attacks, drawn as a whole, is the same list as the session's: one icon per seq, in order
	var s2 = make_session(0)
	var pres2 = P.new(s2)
	for k in 5:
		s2.report_enemy_defeat(1 + k, 1 if k % 2 == 0 else 2)
	pres2.update(0.0)
	var seqs: Array = pres2.player_incoming().map(func(r): return r.seq)
	var seen := {}
	for q in seqs:
		seen[q] = true
	var auth: Array = s2.get_incoming(0).map(func(d): return d.seq)
	check(seqs == auth and seen.size() == seqs.size(), "the rows are exactly the authoritative queue, one icon per sequence id, in send order")
	# the bar reads the same presentation and never changes it
	var strip = STRIP.new(null)
	strip.bind(pres2, null)
	check(strip.rows.size() == 5 and strip.counts == Vector2i(5, 0) and strip.phases == Vector3i(5, 0, 0), "a strip bound to it shows 5 queued icons")
	strip.free()

# ---- WATCH OUT! and the eye counter --------------------------------------------------------------------------------------------

func test_watch_out_and_status() -> void:
	print("-- WATCH OUT! and the eye counter")
	var s = make_session(0)
	var pres = P.new(s)
	check(not pres.watch_out(), "nothing aimed at the player: no WATCH OUT!")
	s.report_enemy_defeat(3, 1)
	pres.update(0.0)
	check(pres.watch_out(), "a bot sends an enemy at the player: WATCH OUT! shows at once")
	pres.update(F.DURATION + P.WATCH_OUT_HOLD - 0.1)
	check(pres.watch_out(), "...through the flight and for about a second after the line lands")
	pres.update(0.2)
	check(not pres.watch_out(), "...then it goes (%.2f s after the send)" % pres.clock)
	s.report_enemy_defeat(5, 2)
	pres.update(0.0)
	var until: float = pres.clock
	pres.update(0.5)
	s.report_enemy_defeat(6, 1)
	pres.update(0.0)
	pres.update(F.DURATION + P.WATCH_OUT_HOLD - 0.05)
	check(pres.watch_out() and pres.clock > until + F.DURATION + P.WATCH_OUT_HOLD - 0.1, "a second send while it shows extends it")
	pres.update(0.2)
	check(not pres.watch_out(), "...and it ends once the last one has been up for the hold")
	var s2 = make_session(9)
	var pres2 = P.new(s2)
	s2.report_enemy_defeat(0, 1)
	s2.report_enemy_defeat(4, 1)
	pres2.update(0.0)
	check(not pres2.watch_out(), "the player's own sends and bots' sends at other bots never show it")
	var s3 = make_session(0)
	s3.report_enemy_defeat(2, 1)
	var late = P.new(s3) # made mid-round: what already happened is replayed silently
	check(not late.watch_out(), "a presentation made mid-round does not replay an old WATCH OUT!")
	# the strip's state
	var strip = STATUS.new(null)
	check(strip.eye == -1 and not strip.watch_out, "the status strip starts empty (no eye counter without the attack loop, no pill)")
	strip.set_eye(3)
	strip.set_watch_out(true)
	check(strip.eye == 3 and strip.watch_out and strip.age == 0.0, "the eye shows a count; the pill appears with its pop")
	strip.advance(0.0)
	check(strip.age == 0.0, "paused time holds the pop")
	strip.advance(1.0)
	check(STATUS.pop_scale(strip.age) == 1.0 and STATUS.pop_scale(0.0) < 0.7 and STATUS.pop_scale(STATUS.POP_SECONDS * 0.5) > 0.9, "the pill pops in and settles at full size")
	strip.set_watch_out(true)
	check(strip.age >= STATUS.POP_SECONDS, "asking for the same state again does not restart the pop")
	check(near(STATUS.PILL_LOCAL.position.x + 111.5, 185.5, 0.6) and near(STATUS.PILL_LOCAL.end.x + 111.5, 289.5, 0.6), "the pill sits at the reference's x 185..290")
	check(not ("chest" in strip) and not ("bonus" in strip), "there is no chest bonus: its formula is unknown, so nothing stands in for it")
	strip.free()

# ---- the banner ---------------------------------------------------------------------------------------------------------------

func test_banner() -> void:
	print("-- the match-start words")
	var banner = BANNER.new(null)
	banner.size = layout.game.size
	check(not banner.visible and banner.text == "", "no words, no banner")
	banner.text = "READY"
	check(banner.visible and banner.age == 0.0, "a word shows the banner and starts its pop")
	banner.advance(0.0)
	check(banner.age == 0.0, "paused time holds the pop")
	banner.advance(0.1)
	var a1: float = banner.age
	banner.text = "READY"
	check(banner.age == a1, "the same word again does not restart it")
	banner.text = "3"
	check(banner.age == 0.0, "a new word does")
	banner.advance(1.0)
	check(BANNER.pop_scale(banner.age) == 1.0 and BANNER.pop_scale(0.0) < 0.6, "the pop settles at full size")
	var peak := 0.0
	for i in 100:
		peak = maxf(peak, BANNER.pop_scale(float(i) * BANNER.POP_SECONDS / 100.0))
	check(peak > 1.0 and peak < 1.5, "...overshooting a little on the way (%.2f)" % peak)
	var fits := true
	for word in ["HERE WE GO...", "READY", "3", "2", "1", "GO!"]:
		var sc: float = BANNER.word_scale(word, banner.size.x - 16.0)
		if TXT.ink_width(word, sc) > banner.size.x - 16.0 + 0.01:
			fits = false
	check(fits, "every word of the sequence fits the window")
	check(BANNER.word_scale("3", 240.0) > BANNER.word_scale("READY", 240.0) and BANNER.word_scale("READY", 240.0) > BANNER.word_scale("HERE WE GO...", 240.0), "the numerals are the biggest, the long lead-in the smallest")
	banner.text = ""
	check(not banner.visible, "no words hide it again")
	banner.free()

# ---- the KO card ----------------------------------------------------------------------------------------------------------------

func contestant(alive: bool, placement := 0):
	var c = CONTESTANT.new()
	c.alive = alive
	c.placement = placement
	return c

func test_ko_card() -> void:
	print("-- the KO card")
	check(PANE.KO_SECONDS >= 0.7 and PANE.KO_SECONDS <= 0.9, "the animation lasts %.1f s (0.8 +- 0.1)" % PANE.KO_SECONDS)
	check(PANE.flash_at(0.0) == 1.0 and PANE.flash_at(PANE.FLASH_1_END * 0.99) > 0.25 and PANE.flash_at(PANE.FLASH_1_END + 0.01) == 0.0, "it opens with a white flash that is gone within a tenth of a second")
	check(PANE.flash_at((PANE.FLASH_2_START + PANE.FLASH_2_END) / 2.0) > 0.0 and PANE.flash_at(PANE.FLASH_2_END + 0.01) == 0.0 and PANE.flash_at(0.3) == 0.0, "a second flash comes at about %.2f s" % PANE.FLASH_2_START)
	check(PANE.card_scale_at(0.0) == 0.0 and PANE.card_scale_at(PANE.POP_START - 0.001) == 0.0 and PANE.card_scale_at(PANE.POP_END) == 1.0 and PANE.card_scale_at(PANE.KO_SECONDS) == 1.0, "the card is nothing until it pops, and full size once it has")
	var peak := 0.0
	for i in 200:
		peak = maxf(peak, PANE.card_scale_at(PANE.POP_START + (PANE.POP_END - PANE.POP_START) * i / 199.0))
	check(peak > 1.02 and peak < 1.4, "it overshoots on the way (%.2f)" % peak)
	check(PANE.puff_progress_at(0.0) < 0.0 and PANE.puff_progress_at(PANE.PUFFS_START) == 0.0 and PANE.puff_progress_at(PANE.PUFFS_END) < 0.0 and PANE.puff_progress_at(0.3) > 0.0, "smoke and the starburst run between their own times")
	var pane = PANE.new(5, null)
	pane.refresh(contestant(true))
	check(not pane.ko and not pane.marked and not pane.is_animating() and pane.ko_age > 1.0e8, "an opponent that is in has no card")
	pane.refresh(contestant(false, 31))
	check(pane.ko and pane.marked and pane.placement == 31 and pane.ko_age == 0.0 and pane.is_animating(), "when it goes out the card starts: placement 31, animation at 0")
	pane.advance(0.0)
	check(pane.ko_age == 0.0, "paused time holds the animation")
	pane.advance(0.4)
	check(near(pane.ko_age, 0.4) and pane.is_animating(), "it plays with the screen's clock")
	pane.refresh(contestant(false, 31))
	check(near(pane.ko_age, 0.4), "refreshing every frame does not restart it")
	pane.advance(5.0)
	check(pane.ko_age == PANE.KO_SECONDS and not pane.is_animating() and pane.marked, "it settles after %.1f s and stays the card" % PANE.KO_SECONDS)
	pane.position = Vector2(10, 20)
	pane.size = Vector2(32.75, 41.5)
	pane.refresh(contestant(false, 31))
	check(pane.position == Vector2(10, 20) and pane.size == Vector2(32.75, 41.5), "the pane never moves or changes size: no reordering")
	pane.refresh(contestant(true))
	check(not pane.marked and not pane.ko and pane.ko_age > 1.0e8, "a new round (alive again) clears the card")
	var late = PANE.new(6, null)
	late.refresh(contestant(false, 20))
	check(late.marked and late.ko_age == PANE.KO_SECONDS and not late.is_animating(), "a pane that is already out when first seen is a settled card, not an animation")
	check(not PANE.show_labels, "the contestant number and course text are off by default (the live pane carries no text)")
	pane.free()
	late.free()

# ---- the HUD ---------------------------------------------------------------------------------------------------------------------

func test_hud() -> void:
	print("-- the window's HUD")
	check(HUD.timer_text(600) == "600" and HUD.timer_text(36) == "36" and HUD.timer_text(7) == "7" and HUD.timer_text(0) == "0" and HUD.timer_text(-5) == "0", "the timer shows whole seconds with no leading zeros, never negative")
	var hud = HUD.new(layout, null)
	hud.set_values(5, 590, 1)
	check(hud.coins == 5 and hud.time_left == 590 and hud.speed == 1 and hud.selector != null and hud.selector.get_parent() == hud, "the HUD holds what it is told and carries the selector")
	check(not hud.layout.hud.has("chest") and hud.layout.hud.item_box == LAYOUT.HUD_ITEM_BOX, "the item box is a reserved rect only (no roulette, no chest)")
	hud.free()

# ---- read only ---------------------------------------------------------------------------------------------------------------------

func code_of(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var out := PackedStringArray()
	for line in text.split("\n"):
		var cut := line.find("#")
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)

func test_read_only() -> void:
	print("-- the new views cannot reach the session")
	for name in UI_FILES:
		var code := code_of("res://Scripts/Classes/Battle/%s.gd" % name)
		var bad := []
		for token in [".attacks", "report_", "resolve_", "end_round", ".step(", "set_player_target_mode", "BattleSession.current", "queues", "history", "next_seq", ".record("]:
			if code.contains(token):
				bad.append(token)
		check(bad.is_empty(), "%s never touches the session's mutating API or the attack system (%s)" % [name, bad])
