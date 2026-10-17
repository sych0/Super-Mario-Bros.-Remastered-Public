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
	"BattleStatusStrip", "BattleTargetReticle", "BattleOpponentPane", "BattleIncomingStrip", "BattleAttackLayer", "BattleAttackGeometry", "BattleSendStyle"]

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
	test_attack_visuals_removed()
	test_lines()
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
	print("-- the reticle (doc 54: thick rounded corners inside the pane, a 59-frame idle pulse, no punch)")
	var GEO = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	var SS = load("res://Scripts/Classes/Battle/BattleSendStyle.gd")
	var slots: Array = layout.slots
	var ok_inside := true
	var ok_corners := true
	var ok_arms := true
	var ok_open := true
	for i in slots.size():
		var pane: Rect2 = slots[i]
		var box: Rect2 = GEO.rest_box(pane)
		if not pane.encloses(box):
			ok_inside = false
		var polys: Array[PackedVector2Array] = RET.corner_polygons(box)
		if polys.size() != 4:
			ok_corners = false
			continue
		var union := Rect2()
		for k in 4:
			var pb := Rect2(polys[k][0], Vector2.ZERO)
			for pt in polys[k]:
				pb = pb.expand(pt)
			union = pb if k == 0 else union.merge(pb)
			if not near(pb.size.x, RET.ARM, 0.01) or not near(pb.size.y, RET.ARM, 0.01):
				ok_arms = false
		if not union.is_equal_approx(box):
			ok_corners = false
		for c in RET.arm_centers(box):
			var inside := false
			for poly in polys:
				if Geometry2D.is_point_in_polygon(c, poly):
					inside = true
			if not inside:
				ok_arms = false
		var middle := box.get_center()
		for poly in polys:
			if Geometry2D.is_point_in_polygon(middle, poly):
				ok_open = false
	check(ok_inside, "the bracket's outer box is inside its pane (all 34): it covers the corners of the picture")
	check(ok_corners, "four corners whose union is the box, on every pane")
	check(ok_arms and RET.arm_centers(GEO.rest_box(slots[0])).size() == 8, "each corner is an L of %.0f units each way, and the middle of every arm is red" % RET.ARM)
	check(ok_open, "the bracket is open: the middle of the pane is not covered")
	var box0: Rect2 = GEO.rest_box(slots[0])
	var tl: PackedVector2Array = RET.corner_polygons(box0)[0]
	check(not Geometry2D.is_point_in_polygon(box0.position + Vector2(0.2, 0.2), tl) and Geometry2D.is_point_in_polygon(box0.position + Vector2(RET.RADIUS, RET.RADIUS) * 0.75, tl), "the outer corner is rounded; the inner corner is square")
	check(near(RET.THICK, 4.5) and near(RET.ARM, 11.0) and near(box0.size.x, 30.5) and near(box0.size.y, 39.0), "measured: arms 11 long, 4.5 thick, a 30.5 x 39.0 box on a 32.75 x 41.5 pane")
	var peak_box: Rect2 = GEO.pulse_box(slots[0], 1.0)
	check(near(peak_box.size.x, 31.75) and near(peak_box.size.y, 41.0) and GEO.pulse_box(slots[0], 0.0).is_equal_approx(box0), "at the top of the idle pulse the box is 31.75 x 41.0; at rest 30.5 x 39.0")
	# the idle pulse
	var T: float = SS.PULSE_PERIOD
	check(near(T, 59.0 / 60.0) and SS.pulse(0.0) == 0.0 and SS.pulse(0.3) == 0.0 and SS.pulse(-1.0) == 0.0, "the pulse is a 59-frame cycle and the box rests for the first half second after it lands")
	check(near(SS.pulse(SS.PULSE_PEAK), 1.0) and SS.pulse(SS.PULSE_PEAK - 0.1) > 0.0 and SS.pulse(SS.PULSE_PEAK - 0.1) < 1.0 and SS.pulse(SS.PULSE_PEAK + 0.1) < 1.0, "it swells to its peak %.2f s after the landing and falls again" % SS.PULSE_PEAK)
	check(near(SS.pulse(SS.PULSE_PEAK + T), 1.0) and near(SS.pulse(SS.PULSE_PEAK + 5.0 * T), 1.0) and SS.pulse(T + 0.2) == 0.0, "...and does it again every 59 frames, resting in between")
	check(near(SS.pulse(SS.PULSE_FALL_END - 0.001), 0.0, 0.01) and SS.pulse(T + (SS.PULSE_FALL_END - T) * 0.5) > 0.0, "(a fall runs a little into the next period)")
	var ret = RET.new(layout)
	check(not ret.visible and ret.target == 0 and not ret.has_content(), "no target: no reticle")
	ret.set_target(5)
	check(ret.visible and ret.target == 5 and ret.persistent_visible() and ret.age == 0.0, "a target shows the bracket on its pane and starts its idle cycle")
	ret.advance(0.0)
	check(ret.age == 0.0, "paused time does not advance the pulse")
	ret.advance(0.4)
	check(near(ret.age, 0.4), "the idle clock follows the screen's")
	ret.set_target(7)
	check(ret.target == 7 and ret.age == 0.0 and not ("pulses" in ret) and not ret.has_method("pulse") and not ret.has_method("pulse_at"), "the bracket moves at once to the next pane and starts its cycle again; there is no punch (nothing happens when it lands)")
	ret.advance(0.9)
	ret.set_target(7)
	check(near(ret.age, 0.9), "asking for the same pane again does nothing")
	check(ret.persistent_box(7, 0.0).is_equal_approx(GEO.rest_box(slots[6])) and ret.persistent_box(7, SS.PULSE_PEAK).is_equal_approx(GEO.pulse_box(slots[6], 1.0)), "the persistent box follows the pulse")
	# the send
	var flying: Array[Dictionary] = [{"seq": 4, "target": 12, "progress": 0.3, "cut": false, "fade": 1.0}]
	ret.sync_flights(flying)
	check(ret.flying.size() == 1 and not ret.persistent_visible() and ret.visible and ret.target == 7, "a send in the air: the bracket is the one flying, the persistent one is not drawn")
	ret.advance(1.0)
	check(near(ret.age, 0.9), "(the idle clock does not run while it is hidden)")
	ret.sync_flights([] as Array[Dictionary])
	check(ret.flying.is_empty() and ret.persistent_visible() and ret.age == 0.0, "when it is gone the persistent bracket is back and its cycle starts at the landing")
	ret.sync_flights(flying)
	ret.clear()
	check(not ret.visible and ret.target == 0 and ret.flying.is_empty() and not ret.has_content(), "clearing the reticle leaves nothing: no bracket, no flight")
	ret.set_target(0)
	check(not ret.visible, "no target hides it")
	ret.set_target(-1)
	check(not ret.visible and ret.target == 0, "-1 hides it too")
	ret.set_target(35)
	check(not ret.visible, "an id past the 34 opponents hides it")
	check(RET.COLOR.r > 225.0 / 255.0 and RET.COLOR.g < 50.0 / 255.0 and RET.COLOR.b < 70.0 / 255.0, "it is the reference's pure red (r>225, g<50, b<70)")
	ret.free()

# ---- what is no longer drawn, and the lines that are --------------------------------------------------------------

## Makes `bot` aim at `target` (the session logs TARGET_CHANGED, which is all a line needs), whatever it aimed at before.
func aim(s, bot: int, target: int) -> void:
	if s.contestants[bot].target_id == target:
		s.attacks.set_target(s, bot, 3 if target != 3 else 4)
	s.attacks.set_target(s, bot, target)

func test_attack_visuals_removed() -> void:
	print("-- the old attack effects are gone (doc 51) and a line belongs to an opponent that aims at the player (doc 54)")
	var LAYER = load("res://Scripts/Classes/Battle/BattleAttackLayer.gd")
	var s = make_session(9) # everybody's sends go to contestant 9
	var pres = P.new(s)
	s.report_enemy_defeat(0, 1) # the player's send: the reticle flies, no line
	s.report_enemy_defeat(5, 1) # a bot's send at contestant 9
	pres.update(0.0)
	check(LAYER.drawn_lines(null).is_empty(), "no presentation, no lines")
	check(LAYER.drawn_lines(pres).is_empty() and not pres.watch_out(), "sends, the player's or a bot's, draw no line and no WATCH OUT!: the line is the aim, not the send")
	var sp = make_session(0) # everybody's sends go to the player
	var pp = P.new(sp)
	sp.report_enemy_defeat(5, 1)
	pp.update(0.0)
	var only_aimers := true
	for l in LAYER.drawn_lines(pp):
		if pp.target_of(int(l.sender)) != 0:
			only_aimers = false
	check(pp.player_incoming().size() == 1 and only_aimers, "a bot's send at the player is an icon in the bar; a line exists only for a bot whose target IS the player")
	var s2 = make_session(9)
	var p2 = P.new(s2)
	s2.report_enemy_defeat(3, 1)
	s2.report_enemy_defeat(4, 2)
	p2.update(0.0)
	check(p2.flights.is_empty() and LAYER.drawn_lines(p2).is_empty(), "bot-to-bot sends are neither flights nor lines")
	var s3 = make_session(0)
	var p3 = P.new(s3)
	aim(s3, 6, 0)
	p3.update(0.0)
	check(LAYER.drawn_lines(p3).size() == 1 and LAYER.drawn_lines(p3)[0].sender == 6, "a bot that aims at the player is one line, from that bot")
	var layer = LAYER.new(layout)
	for gone in ["_draw_target", "_draw_flight", "_draw_piece", "_draw_line"]:
		check(not layer.has_method(gone), "the layer has no %s any more (gold line, target tint, frame flash, launch ring)" % gone)
	check(not ("assets" in layer), "and it carries no enemy art (no enemy rides a line)")
	var pane = PANE.new(3, null)
	pane.refresh(contestant(true))
	pane.set_incoming(Vector2i(2, 1))
	check(not pane.draws_pips(), "a pane with enemies on their way shows no pip")
	PANE.show_labels = true
	check(pane.draws_pips(), "...unless the debug labels mode is on")
	pane.refresh(contestant(false, 20))
	check(not pane.draws_pips(), "...and never on a KO card")
	PANE.show_labels = false
	layer.free()
	pane.free()

func test_lines() -> void:
	print("-- the attacker lines and WATCH OUT! (doc 54: measured at 60 fps)")
	var GEO = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	var LAYER = load("res://Scripts/Classes/Battle/BattleAttackLayer.gd")
	var s = make_session(0)
	var pres = P.new(s)
	check(pres.lines().is_empty() and not pres.watch_out() and pres.watch_out_age() == -1.0, "nobody aims at the player: no line, no WATCH OUT!")
	check(near(P.LINE_SECONDS, 0.25) and near(P.LINE_SECONDS * 60.0, 15.0), "a line's head takes 15 frames (0.25 s) to reach the pill")
	aim(s, 6, 0)
	pres.update(0.0)
	var ls: Array[Dictionary] = pres.lines()
	check(ls.size() == 1 and ls[0].sender == 6 and ls[0].progress == 0.0 and pres.watch_out() and near(pres.watch_out_age(), 0.0), "a bot that starts aiming at the player: its line starts at its pane and WATCH OUT! appears at once")
	pres.update(P.LINE_SECONDS * 0.5)
	check(near(pres.lines()[0].progress, 0.5) and near(pres.watch_out_age(), P.LINE_SECONDS * 0.5), "the head moves at constant speed: half the time, half the way")
	pres.update(P.LINE_SECONDS * 0.5)
	check(near(pres.lines()[0].progress, 1.0), "...and is at the pill after 0.25 s")
	pres.update(30.0)
	check(near(pres.lines()[0].progress, 1.0) and pres.watch_out(), "the line then stays for as long as the bot aims at the player (30 s later it is still there)")
	var born_age: float = pres.watch_out_age()
	aim(s, 20, 0)
	pres.update(0.0)
	check(pres.lines().size() == 2 and pres.lines()[0].sender == 6 and pres.lines()[1].progress == 0.0 and near(pres.watch_out_age(), born_age), "a second bot aiming at the player is a second line; the pill keeps its age (it is one pill)")
	aim(s, 6, 9)
	pres.update(0.0)
	check(pres.lines().size() == 1 and pres.lines()[0].sender == 20 and pres.watch_out(), "when a bot re-targets its line goes that frame; the pill stays while one line is left")
	s.attacks.set_target(s, 20, -1) # what a KO does: the session logs the target as gone
	pres.update(0.0)
	check(pres.lines().is_empty() and not pres.watch_out() and pres.watch_out_age() == -1.0, "a knocked-out opponent's line goes with it, and with the last line WATCH OUT! goes")
	aim(s, 7, 0)
	pres.update(0.0)
	pres.update(1.0)
	check(near(pres.watch_out_age(), 1.0), "a pill after a gap has its own clock")
	var ign = make_session(0)
	var pi = P.new(ign)
	ign.attacks.set_target(ign, 0, 5) # the player's own aim is nobody's line
	pi.update(0.0)
	check(pi.lines().is_empty(), "the player's own target changes are not lines")
	var s3 = make_session(0)
	aim(s3, 2, 0)
	var late = P.new(s3) # made mid-round: what already happened is replayed silently
	check(late.lines().is_empty() and not late.watch_out(), "a presentation made mid-round does not replay an old line")
	pres.clear_flights()
	check(pres.lines().is_empty() and not pres.watch_out(), "ending the round clears the lines")
	# geometry: from the pane's middle to the pill's near edge, on the sender's side
	var pill: Rect2 = layout.pill
	check(near(pill.position.x, 189.5) and near(pill.end.x, 290.5) and near(pill.position.y, 248.75) and near(pill.size.y, 13.0), "the pill is where the reference has it: x 189.5..290.5, y 248.75..261.75")
	var left_end: Vector2 = GEO.landing_point(layout, 6, 0)
	var right_end: Vector2 = GEO.landing_point(layout, 20, 0)
	check(layout.slots[5].get_center().x < 240.0 and layout.slots[19].get_center().x > 240.0, "(contestant 6 is in the left panel, 20 in the right)")
	check(near(left_end.x, 189.5) and near(right_end.x, 290.5) and near(left_end.y, 253.75) and near(right_end.y, 253.75), "a line from the left panel ends on the pill's left edge, one from the right panel on its right edge, at y 253.75")
	check(GEO.launch_point(layout, 20, 0) == layout.slots[19].get_center(), "it starts at the middle of the sender's pane")
	var head: Vector2 = LAYER.head_of(layout, 20, 0.5)
	check(head.is_equal_approx((GEO.launch_point(layout, 20, 0) + right_end) / 2.0) and LAYER.head_of(layout, 20, 0.0) == GEO.launch_point(layout, 20, 0) and LAYER.head_of(layout, 20, 1.0).is_equal_approx(right_end), "the head moves along the line linearly")
	check(near(LAYER.LINE_WIDTH, 0.65), "the line is 2.5 device px thick (0.65 units)")

# ---- the incoming bar -----------------------------------------------------------------------------------------------------

func item(phase: int, seq: int, extra := {}) -> Dictionary:
	var d := {"seq": seq, "kind": 1, "phase": phase, "in_transit": false, "age": 0.0, "waited": -1.0, "arrive": 0.0, "fresh": 0.0, "flash": 0.0, "spawned": false}
	d.merge(extra, true)
	return d

func test_incoming_bar_placement() -> void:
	print("-- the incoming bar: where icons are (doc 54: measured at 60 fps)")
	var w: float = layout.strip_a.size.x
	var b: float = STRIP.gold_end(w)
	check(near(b, 91.1, 0.2) and near(STRIP.orange_end(w), 176.5, 0.2), "the boundaries are where the reference has them: x 202.6 and 288.0 on the canvas (%.1f, %.1f in the strip)" % [b, STRIP.orange_end(w)])
	check(STRIP.ZONE_GOLD == Color8(255, 189, 9) and STRIP.ZONE_ORANGE == Color8(255, 118, 0) and STRIP.ZONE_DARK == Color8(245, 85, 17), "the zones are the reference's flat gold, orange and darker orange")
	var pts: PackedVector2Array = STRIP.jagged(b, 12.0)
	var lo := 1.0e9
	var hi := -1.0e9
	for pt in pts:
		lo = minf(lo, pt.x)
		hi = maxf(hi, pt.x)
	check(pts.size() == 5 and pts[0].y == 0.0 and pts[4].y == 12.0 and near(hi - lo, STRIP.TOOTH_DEPTH, 0.2) and near((hi + lo) / 2.0, b, 0.2), "a jagged boundary is a zig-zag of two teeth, %.1f units deep, centred on the boundary" % STRIP.TOOTH_DEPTH)
	var entry: float = STRIP.entry_x(w)
	var slot0: float = b + STRIP.WAIT_OFFSET
	check(near(STRIP.ICON_W, 8.0) and near(STRIP.PITCH, 10.8), "an icon is a bare 8-unit sprite; waiting icons stand 10.8 apart")
	var travel: float = STRIP.TRAVEL_SECONDS
	check(near(travel, 3.0), "an icon takes the attack system's activation delay (3 s), counted from the send, to reach the boundary")
	var speed: float = STRIP.travel_speed(w)
	check(near(speed, (entry - slot0) / 3.0) and speed > 40.0 and speed < 60.0, "...which is a constant %.0f units/s (the reference's is 47)" % speed)
	var xs: PackedFloat32Array = STRIP.place_all([item(Phase.QUEUED, 1, {"age": 0.0})], w)
	check(near(xs[0], entry), "a just-sent icon starts at the right end")
	var x1: float = STRIP.place_all([item(Phase.QUEUED, 1, {"age": 0.5})], w)[0]
	var x2: float = STRIP.place_all([item(Phase.QUEUED, 1, {"age": 1.0})], w)[0]
	var x3: float = STRIP.place_all([item(Phase.QUEUED, 1, {"age": 2.0})], w)[0]
	check(near(entry - x1, speed * 0.5, 0.01) and near(x1 - x2, speed * 0.5, 0.01) and near(x2 - x3, speed, 0.01), "it moves the same distance in the same time: no easing")
	xs = STRIP.place_all([item(Phase.QUEUED, 1, {"age": travel * 3.0})], w)
	check(near(xs[0], slot0) and xs[0] > b, "it stops at the boundary's right side and waits there")
	xs = STRIP.place_all([item(Phase.ARRIVING, 1, {"age": 0.5, "waited": 1.0, "state": 1})], w)
	check(near(xs[0], slot0), "an ACTIVE icon that is not at the boundary yet is there within %.1f s of becoming ACTIVE" % STRIP.CATCH_UP_SECONDS)
	# several: order, spacing
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
	check(near(xs[1] - xs[0], STRIP.PITCH) and near(xs[3] - xs[0], 3.0 * STRIP.PITCH), "icons waiting at the boundary stand %.1f units apart" % STRIP.PITCH)
	# in the level: across the boundary, then gone
	xs = STRIP.place_all([item(Phase.IN_LEVEL, 1, {"arrive": 1.0})], w)
	check(near(xs[0], slot0) and STRIP.crossed(item(Phase.IN_LEVEL, 1, {"arrive": 1.0})) == 0.0, "the moment its enemy appears in the level its icon is where it waited")
	var run: float = STRIP.WAIT_OFFSET / STRIP.CROSS_SPEED
	var half := item(Phase.IN_LEVEL, 1, {"arrive": 1.0 - (run * 0.5) / P.SPAWN_FLASH})
	check(near(STRIP.crossed(half), 0.5, 0.01) and near(STRIP.place_all([half], w)[0], (slot0 + b) / 2.0, 0.05), "it runs on across the boundary at the travel speed...")
	var gone := item(Phase.IN_LEVEL, 1, {"arrive": 1.0 - (run * 1.2) / P.SPAWN_FLASH})
	check(STRIP.crossed(gone) == 1.0 and near(STRIP.place_all([gone], w)[0], b), "...and when it reaches the boundary it is gone (not drawn): the reference leaves no marker, no flash")
	var inst = STRIP.new(null)
	check(not inst.has_method("_boundary_flash") and not inst.has_method("_ghost") and not inst.has_method("_dotted") and not STRIP.get_script_constant_map().has("IN_LEVEL_X0"), "no hollow place-holder, no gold-zone marker, no fading ghost, no boundary flash any more")
	inst.free()
	# a fading ghost is no longer a thing the bar draws
	var rows_only: Array[Dictionary] = STRIP.merged([item(Phase.ARRIVING, 5, {"age": 9.0, "waited": 4.0})] as Array[Dictionary],
		[{"seq": 3, "kind": 1, "cause": 0, "spawned": true, "fade": 0.5}] as Array[Dictionary])
	check(rows_only.size() == 1 and int(rows_only[0].seq) == 5, "an attack that ended leaves the bar at once: its fading ghost is not drawn")
	# everything stays inside the bar
	var crowd: Array[Dictionary] = []
	for k in 30:
		crowd.append(item(Phase.ARRIVING, k, {"age": 99.0, "waited": 99.0}))
	xs = STRIP.place_all(crowd, w)
	var inside := true
	for x in xs:
		if x < 0.0 or x > w:
			inside = false
	check(inside, "even a crowd of 30 stays inside the bar")
	check(STRIP.progress_of(item(Phase.QUEUED, 1, {"age": 0.0})) == 0.0 and STRIP.progress_of(item(Phase.QUEUED, 1, {"age": travel})) == 1.0, "an icon that was just sent has gone nowhere; one sent a travel time ago has gone all the way")

func test_incoming_bar_phase_mapping() -> void:
	print("-- the incoming bar: phases follow the authoritative state")
	var s = make_session(0)
	var pres = P.new(s)
	var a = s.report_enemy_defeat(4, 1)
	pres.update(0.0)
	var row: Dictionary = pres.player_incoming()[0]
	check(a != null and row.seq == a.seq and row.phase == Phase.QUEUED and not row.in_transit and row.age == 0.0 and row.waited < 0.0, "a bot's send at the player is a QUEUED icon at once: it enters the bar at the moment of the send")
	var w: float = layout.strip_a.size.x
	check(near(STRIP.place_all([row], w)[0], STRIP.entry_x(w)), "...at the bar's right end")
	pres.update(1.0)
	row = pres.player_incoming()[0]
	var mid: float = STRIP.place_all([row], w)[0]
	check(near(row.age, 1.0) and mid < STRIP.entry_x(w) and mid > STRIP.gold_end(w) + STRIP.WAIT_OFFSET and near(STRIP.entry_x(w) - mid, STRIP.travel_speed(w), 0.01), "a second on it is on its way (x %.1f, one second's travel)" % mid)
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
	check(row.phase == Phase.IN_LEVEL and row.arrive > 0.9 and STRIP.crossed(row) < 0.1, "the icon becomes IN_LEVEL and starts across the boundary")
	pres.update(0.5)
	row = pres.player_incoming()[0]
	check(STRIP.crossed(row) == 1.0, "half a second later it has crossed and is gone from the bar (its attack is still in the list: the session's queue is unchanged)")
	check(s.resolve_player_incoming(a.seq, A.Resolution.DEFEATED_BY_PLAYER), "(the player defeats it)")
	pres.update(0.0)
	check(pres.player_incoming().is_empty() and pres.player_resolved().size() == 1 and pres.player_resolved()[0].spawned, "the attack leaves the list (the strip draws no fading ghost for it)")
	pres.update(P.RESOLVE_FADE + 0.1)
	check(pres.player_resolved().is_empty(), "...and its record is gone")
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

# ---- the WATCH OUT! pill ---------------------------------------------------------------------------------------------------

func test_watch_out_and_status() -> void:
	print("-- the WATCH OUT! pill (doc 54: a white flash that decays, every 59 frames; no eye counter)")
	var strip = STATUS.new(null)
	check(not strip.is_showing() and strip.pill_age == -1.0, "the status strip starts empty (no pill)")
	check(not ("eye" in strip) and not strip.has_method("set_eye") and not strip.has_method("_eye"), "there is no eye counter: the reference shows none while lines are up (t=600, 745, 870, 892, 905)")
	strip.set_pill(0.0)
	check(strip.is_showing() and strip.pill_age == 0.0, "the pill appears when it is told its age")
	strip.set_pill(-3.0)
	check(not strip.is_showing() and strip.pill_age == -1.0, "a negative age hides it")
	check(near(STATUS.FLASH_PERIOD, 59.0 / 60.0), "the white flash comes round every 59 frames")
	check(STATUS.flash_alpha(-1.0) == 0.0 and STATUS.flash_alpha(0.0) == 1.0 and STATUS.flash_alpha(0.9 / 60.0) == 1.0, "the pill's first frame is solid white")
	var fell := true
	var last := 2.0
	for f in range(1, 9):
		var al: float = STATUS.flash_alpha(float(f) / 60.0)
		if al >= last:
			fell = false
		last = al
	check(fell and near(STATUS.flash_alpha(1.0 / 60.0), 0.97, 0.01) and near(STATUS.flash_alpha(2.0 / 60.0), 0.825, 0.01) and STATUS.flash_alpha(8.0 / 60.0) == 0.0, "then it falls in a straight line, 0.145 a frame, and is gone by the eighth")
	check(STATUS.flash_alpha(20.0 / 60.0) == 0.0 and STATUS.flash_alpha(58.0 / 60.0) == 0.0 and STATUS.flash_alpha(STATUS.FLASH_PERIOD) == 1.0 and near(STATUS.flash_alpha(STATUS.FLASH_PERIOD * 3.0 + 2.0 / 60.0), 0.825, 0.01), "...and it comes again every 59 frames while the pill stays")
	var layers: Array[Rect2] = STATUS.pill_layers(layout.pill)
	check(layers.size() == 4 and layers[0] == layout.pill and near(layers[1].position.x - layers[0].position.x, 3.0) and near(layers[2].position.x - layers[0].position.x, 6.0) and near(layers[3].position.x - layers[0].position.x, 8.5), "the pill is four layers inward from the ends: crimson, orange, the red ring and the black plate (3, 6 and 8.5 units in)")
	check(near(layers[3].position.y - layers[0].position.y, 1.25) and near(layers[1].size.y, layers[0].size.y) and near(layers[2].size.y, layers[0].size.y), "...the stripes as tall as the pill, the plate 1.25 inside the ring")
	check(STATUS.CRIMSON == Color8(225, 48, 55) and STATUS.ORANGE == Color8(255, 95, 0) and STATUS.RED == Color8(255, 0, 0) and STATUS.BLACK == Color8(0, 0, 0) and STATUS.YELLOW == Color8(255, 248, 0), "the reference's colours")
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
	print("-- the KO card (doc 54: measured at 60 fps on t=526.333 and t=518.367)")
	var f := 1.0 / 60.0
	check(near(PANE.KO_SECONDS, 0.95, 0.06), "the animation lasts %.2f s (0.95 +- 0.06): the first flash to the card at rest" % PANE.KO_SECONDS)
	check(PANE.square_side_at(0.0) == 11.0 and PANE.square_side_at(f * 1.1) == 14.5 and PANE.square_side_at(f * 2.1) == 0.0 and PANE.square_side_at(-0.1) == 0.0, "it opens with a white rounded square at the middle: 11 units on the first frame, 14.5 on the second, then the card")
	check(not PANE.card_visible_at(0.0) and not PANE.card_visible_at(f * 1.5) and PANE.card_visible_at(f * 2.0) and PANE.card_visible_at(PANE.KO_SECONDS), "the blue card is there from the third frame, whole (it does not pop in from nothing)")
	var b0: Dictionary = PANE.burst_at(f * 2.0)
	check(near(b0.alpha, 1.0) and PANE.burst_at(f * 1.9).alpha == 0.0 and PANE.burst_at(f * 4.0).alpha > 0.0 and PANE.burst_at(f * 4.0).alpha < 1.0 and PANE.burst_at(PANE.BURST_END).alpha == 0.0, "a white burst covers the card as it appears and has cleared four frames later")
	var st0: Dictionary = PANE.stars_at(f * 1.0)
	var st1: Dictionary = PANE.stars_at(0.2)
	check(PANE.STAR_COUNT == 8 and st0.alpha > 0.9 and st1.radius > st0.radius * 2.0 and PANE.stars_at(0.0).alpha == 0.0 and PANE.stars_at(PANE.STARS_END + 0.01).alpha == 0.0, "eight yellow stars fly outward from the second frame and are gone by %.2f s" % PANE.STARS_END)
	check(PANE.puffs_at(0.0).alpha == 0.0 and PANE.puffs_at(PANE.PUFFS_START).alpha > 0.0 and PANE.puffs_at(0.3).grow == 1.0 and PANE.puffs_at(0.3).ring == 0.0 and PANE.puffs_at(0.55).ring > 0.5 and PANE.puffs_at(PANE.PUFFS_END).alpha == 0.0, "smoke builds up, then thins into rings and is gone by %.2f s" % PANE.PUFFS_END)
	var fl2: Dictionary = PANE.flash_2_at(PANE.FLASH_2_START)
	var fl2b: Dictionary = PANE.flash_2_at(PANE.FLASH_2_PEAK)
	check(fl2.alpha == 1.0 and fl2b.w > fl2.w and fl2b.h > fl2.h and PANE.flash_2_at(PANE.FLASH_2_END - 0.01).alpha < 0.2 and PANE.flash_2_at(PANE.FLASH_2_END + 0.01).alpha == 0.0 and PANE.flash_2_at(0.1).alpha == 0.0, "a second white square grows at the middle at %.2f s and fades by %.2f s" % [PANE.FLASH_2_START, PANE.FLASH_2_END])
	var fl3: Dictionary = PANE.flash_3_at(PANE.FLASH_3_START)
	check(fl3.alpha == 1.0 and PANE.flash_3_at(PANE.FLASH_3_PEAK).w > fl3.w and PANE.flash_3_at(PANE.FLASH_3_END + 0.01).alpha == 0.0 and PANE.flash_3_at(0.5).alpha == 0.0, "a third flashes over the plate at %.2f s" % PANE.FLASH_3_START)
	check(PANE.glow_at(PANE.GLOW_START) > 0.3 and PANE.glow_at(PANE.KO_SECONDS) == 0.0 and PANE.glow_at(0.5) == 0.0, "a pale rim round the plate fades as the card comes to rest")
	var ordered: bool = PANE.SQUARE_2 < PANE.PUFFS_START and PANE.PUFFS_START < PANE.FLASH_2_START and PANE.FLASH_2_START < PANE.FLASH_2_PEAK and PANE.FLASH_2_PEAK < PANE.FLASH_2_END \
		and PANE.PUFFS_END < PANE.FLASH_3_START and PANE.FLASH_3_START < PANE.FLASH_3_PEAK and PANE.FLASH_3_PEAK < PANE.FLASH_3_END and PANE.FLASH_3_END <= PANE.GLOW_START + 0.001 and PANE.GLOW_START < PANE.KO_SECONDS
	check(ordered, "the pieces run in the reference's order: square, card, smoke, second flash, third flash, rim")
	# the card's own geometry, in design units
	var inside := true
	for r in [PANE.FIELD_RECT, PANE.PLATE_RECT, PANE.BLOCK_EDGE_RECT, PANE.BLOCK_RECT]:
		if not PANE.RING_RECT.encloses(r):
			inside = false
	check(inside and PANE.FIELD_RECT.encloses(PANE.PLATE_RECT) and PANE.PLATE_RECT.encloses(PANE.BLOCK_EDGE_RECT) and PANE.BLOCK_EDGE_RECT.encloses(PANE.BLOCK_RECT), "the card is nested: ring, field, plate, the teal block's edge, the block")
	check(PANE.CARD_RING == Color8(3, 102, 193) and PANE.CARD_FIELD == Color8(32, 78, 147) and PANE.CARD_PLATE == Color8(22, 137, 211) and PANE.BLOCK_TEAL == Color8(0, 120, 152), "the reference's blues and teal")
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
	check(pane.ko_age == PANE.KO_SECONDS and not pane.is_animating() and pane.marked, "it settles after %.2f s and stays the card" % PANE.KO_SECONDS)
	pane.position = Vector2(10, 20)
	pane.size = Vector2(32.75, 41.5)
	pane.refresh(contestant(false, 31))
	check(pane.position == Vector2(10, 20) and pane.size == Vector2(32.75, 41.5), "the pane never moves or changes size: no reordering")
	pane.refresh(contestant(true))
	check(not pane.marked and not pane.ko and pane.ko_age > 1.0e8, "a new round (alive again) clears the card")
	var late = PANE.new(6, null)
	late.refresh(contestant(false, 20))
	check(late.marked and late.ko_age == PANE.KO_SECONDS and not late.is_animating(), "a pane that is already out when first seen is a settled card, not an animation")
	# the results: an opponent who is out in the session whose (lagging) picture had not shown it
	var lag = PANE.new(7, null)
	lag.refresh(contestant(true))
	var gone = contestant(false, 12)
	lag.settle_as_card(gone)
	check(lag.ko and lag.marked and lag.placement == 12 and lag.ko_age == PANE.KO_SECONDS and not lag.is_animating(), "settle_as_card puts the finished card on a pane whose picture is still alive: no animation, its placement, at rest")
	var half = PANE.new(8, null)
	half.refresh(contestant(true))
	half.refresh(contestant(false, 9))
	half.advance(0.3)
	half.settle_as_card(contestant(false, 9))
	check(half.ko_age == PANE.KO_SECONDS and not half.is_animating(), "...and on a card that is mid-animation it ends the animation")
	check(not PANE.show_labels, "the contestant number and course text are off by default (the live pane carries no text)")
	pane.free()
	late.free()
	lag.free()
	half.free()

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
