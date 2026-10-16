extends SceneTree
## Deterministic checks of the Battle enemy send / receive loop (BattleAttackSystem and friends):
## sends, targeting, events, incoming queues, the QUEUED -> ACTIVE -> RESOLVED lifecycle, the
## pressure it puts on simulated bots, and that switching it off restores the attack-free model.
## Pure data: no scene tree. The real game's kill hook is in tests/battle_attack_game_test.gd.
##   godot --headless --path . -s tests/battle_attack_test.gd

var failures := 0
var S
var T # BattleEnemyType
var A # BattleAttack
var SYS # BattleAttackSystem
var BOT # BattleBotSimulator
var Policy # BattleTargeting
var FixedPolicy # a test policy that always picks one contestant
var RecordPolicy # a test policy that records the draw it is handed
var K # BattleSession.KoCause
var E # BattleSession.EventType
var R # BattleAttack.Resolution
var AT # BattleAttribution
var SRC # BattleAttribution.Source

const RECORD_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var draws: Array = []
func choose(session, sender, draw) -> int:
	if sender == 0:
		draws.append(draw) # only the real player's picks
	return load("res://Scripts/Classes/Battle/BattleTargeting.gd").eligible(session, sender)[0]
"""

const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func _initialize() -> void:
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	T = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	A = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	SYS = load("res://Scripts/Classes/Battle/BattleAttackSystem.gd")
	BOT = load("res://Scripts/Classes/Battle/BattleBotSimulator.gd")
	Policy = load("res://Scripts/Classes/Battle/BattleTargeting.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	RecordPolicy = GDScript.new()
	RecordPolicy.source_code = RECORD_SOURCE
	RecordPolicy.reload()
	K = S.KoCause
	E = S.EventType
	R = A.Resolution
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	SRC = AT.Source
	S.default_attacks_enabled = true
	test_enemy_types()
	test_player_defeat_creates_one_send()
	test_target_rules()
	test_target_determinism_and_policy_api()
	test_event_and_queue()
	test_lifecycle()
	test_pressure()
	test_pressure_raises_bot_elimination()
	test_bot_sends()
	test_player_incoming()
	test_rng_streams()
	test_player_incoming_resolution()
	test_round_cleanup()
	test_attribution_model()
	test_senders_out()
	test_enabled_disabled()
	test_round_isolation()
	test_read_only_views()
	S.default_attacks_enabled = true
	if failures > 0:
		printerr("%d Battle attack test(s) failed" % failures)
	else:
		print("All Battle attack tests passed")
	quit(1 if failures > 0 else 0)

## A session whose bots do not send, so a test controls every send; target 5 unless said otherwise.
func quiet(seed_value := 1, target := -1):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	if target >= 0:
		var p = FixedPolicy.new()
		p.target = target
		s.attacks.targeting = p
	return s

func events_of(s, type: int) -> Array:
	return s.events.filter(func(e): return e.type == type)

# ------------------------------------------------------------------ enemy types

func test_enemy_types() -> void:
	check(T.kind_for_script("res://Scripts/Classes/Entities/Enemies/Goomba.gd") == T.Kind.GOOMBA, "the Goomba script is the GOOMBA kind")
	check(T.kind_for_script("res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd") == T.Kind.KOOPA, "the Koopa Troopa script is the KOOPA kind")
	check(T.kind_for_script("res://Scripts/Classes/Entities/ShellClass.gd") == T.Kind.NONE and T.kind_for_script("") == T.Kind.NONE and T.kind_for_script("res://Scripts/Classes/Entities/Enemies/PiranhaPlant.gd") == T.Kind.NONE, "shells, plants and unknown scripts are not supported kinds")
	check(T.kinds() == [T.Kind.GOOMBA, T.Kind.KOOPA] and T.is_supported(T.Kind.GOOMBA) and not T.is_supported(T.Kind.NONE), "supported kinds: Goomba and Koopa")
	var plain := true
	for k in T.DATA:
		if not (k is int):
			plain = false
		for f in T.DATA[k]:
			var v = T.DATA[k][f]
			if v is Object:
				plain = false
	check(plain, "the type table holds only plain data (no nodes, scenes or objects)")
	check(T.kind_name(T.Kind.GOOMBA) == "GOOMBA" and T.weight(T.Kind.KOOPA) > T.weight(T.Kind.GOOMBA) and T.active_ticks(T.Kind.KOOPA) > T.active_ticks(T.Kind.GOOMBA), "kinds carry a name, a pressure weight and an active time")
	check(T.pick_for_bot(0.0) == T.Kind.GOOMBA and T.pick_for_bot(0.69) == T.Kind.GOOMBA and T.pick_for_bot(0.71) == T.Kind.KOOPA and T.pick_for_bot(0.9999) == T.Kind.KOOPA, "a bot's defeat kind follows the table's weights")

# ------------------------------------------------------------------ player defeat -> one send

func test_player_defeat_creates_one_send() -> void:
	var s = quiet(3)
	var attack = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(attack != null and s.attacks.history.size() == 1 and s.attacks.defeats == 1, "a supported defeat by the real player creates exactly one send")
	check(attack.sender == 0 and attack.kind == T.Kind.GOOMBA and attack.target >= 1 and attack.target <= 34, "...from the player, of that kind, to one of the 34 opponents (#%d)" % attack.target)
	var d: Array = events_of(s, E.ENEMY_DEFEATED)
	var sent: Array = events_of(s, E.SENT)
	var got: Array = events_of(s, E.RECEIVED)
	check(d.size() == 1 and sent.size() == 1 and got.size() == 1, "one ENEMY_DEFEATED, one SENT and one RECEIVED event")
	check(d[0].id == 0 and d[0].a == T.Kind.GOOMBA and d[0].b == attack.seq, "ENEMY_DEFEATED: the defeater, the kind and the attack's seq")
	check(sent[0].id == 0 and sent[0].a == attack.seq and sent[0].b == attack.target and sent[0].kind == T.Kind.GOOMBA, "SENT: sender, seq, target and kind")
	check(got[0].id == attack.target and got[0].a == attack.seq and got[0].b == 0 and got[0].kind == T.Kind.GOOMBA, "RECEIVED: the same send from the target's side")
	check(d[0].defeat == 0 and attack.defeat_seq == 0, "...numbered as the round's first defeat")
	S.clear()
	check(S.report_enemy_kill("res://Scripts/Classes/Entities/Enemies/Goomba.gd", SRC.PLAYER) == null, "(no current session: nothing happens)")
	S.begin(9)
	S.current.attacks.bots_send = false
	check(S.report_enemy_kill("res://Scripts/Classes/Entities/ShellClass.gd", SRC.PLAYER) == null and S.current.attacks.history.is_empty(), "an unsupported enemy sends nothing, even when the player killed it")
	var via_game_path = S.report_enemy_kill("res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd", SRC.PLAYER)
	check(via_game_path != null and via_game_path.sender == 0 and via_game_path.kind == T.Kind.KOOPA, "the game's entry point turns a script path into a KOOPA send by the player")
	S.clear()

# ------------------------------------------------------------------ targeting

func test_target_rules() -> void:
	var self_hit := 0
	var sends := 0
	for sender in 35:
		var s = quiet(100 + sender)
		for i in 25:
			var a = s.report_enemy_defeat(sender, T.Kind.GOOMBA)
			sends += 1
			if a == null or a.target == sender:
				self_hit += 1
	check(sends == 875 and self_hit == 0, "a sender never targets itself (875 sends from all 35 contestants)")
	# eliminated contestants are never targeted
	var s = quiet(7)
	for id in range(1, 21):
		s.report_ko(id, K.HAZARD)
	var bad := 0
	var targets := {}
	for i in 600:
		var a = s.report_enemy_defeat(25, T.Kind.KOOPA)
		if a == null or not s.contestants[a.target].alive or a.target == 25:
			bad += 1
		else:
			targets[a.target] = true
	check(bad == 0, "eliminated contestants are never targeted (20 are out, 600 sends)")
	check(targets.has(0) and targets.size() >= 10, "the player is eligible while alive, and every survivor can be picked (%d distinct targets)" % targets.size())
	# the player is a valid target only while alive
	var p = quiet(8)
	p.report_ko(0, K.HAZARD)
	var player_hits := 0
	for i in 300:
		var a = p.report_enemy_defeat(4, T.Kind.GOOMBA)
		if a != null and a.target == 0:
			player_hits += 1
	check(player_hits == 0, "the player is not targeted once out")
	# two left: the only possible target is the other one
	var q = quiet(9)
	for id in range(2, 35):
		q.report_ko(id, K.HAZARD)
	var a2 = q.report_enemy_defeat(1, T.Kind.GOOMBA)
	check(q.alive_count == 2 and not q.finished and a2 != null and a2.target == 0, "with two left the only target is the other contestant")

func targets_for(seed_value: int, n: int) -> Array:
	var s = quiet(seed_value)
	var out := []
	for i in n:
		var a = s.report_enemy_defeat(1 + (i % 34), T.Kind.GOOMBA)
		out.append(a.target if a != null else -1)
	return out

func test_target_determinism_and_policy_api() -> void:
	check(targets_for(5, 200) == targets_for(5, 200), "the same seed gives identical target choices")
	check(targets_for(5, 200) != targets_for(6, 200), "a different seed gives different ones")
	var s1 = quiet(5)
	var s2 = quiet(5)
	for i in 50:
		s1.report_enemy_defeat(1 + i % 34, T.Kind.KOOPA)
		s2.report_enemy_defeat(1 + i % 34, T.Kind.KOOPA)
	check(s1.attacks.snapshot() == s2.attacks.snapshot() and s1.events == s2.events, "the whole attack state and event log are reproducible")
	# the policy is replaceable without touching delivery
	var fixed = quiet(5, 9)
	var a = fixed.report_enemy_defeat(2, T.Kind.GOOMBA)
	check(a != null and a.target == 9 and fixed.get_incoming(9).size() == 1, "a different policy picks the target and delivery is unchanged")
	check(fixed.attacks.targeting.get_script().get_base_script() == Policy or fixed.attacks.targeting.get_script().resource_path.ends_with("BattleTargetingRandomSurvivor.gd") or fixed.attacks.targeting.get_script() == FixedPolicy and Policy.eligible(fixed, 2).size() == 34 and not Policy.eligible(fixed, 2).has(2), "policies share one list of eligible contestants (alive, not the sender)")
	var bad_self = quiet(5, 2)
	check(bad_self.report_enemy_defeat(2, T.Kind.GOOMBA) == null and bad_self.attacks.history.is_empty(), "a policy that returns the sender is refused: nothing is sent")
	var dead = quiet(5, 9)
	dead.report_ko(9, K.HAZARD)
	check(dead.report_enemy_defeat(2, T.Kind.GOOMBA) == null and dead.attacks.history.is_empty(), "a policy that returns an eliminated contestant is refused too")
	check(not dead.events.filter(func(e): return e.type == E.SENT).size() > 0 and dead.events.filter(func(e): return e.type == E.ENEMY_DEFEATED and e.b == -1).size() == 1, "...and the defeat is still logged, with no attack (seq -1)")

# ------------------------------------------------------------------ attack event + queue

func test_event_and_queue() -> void:
	var s = quiet(11, 6)
	s.step()
	s.step()
	var a0 = s.report_enemy_defeat(3, T.Kind.GOOMBA)
	var a1 = s.report_enemy_defeat(4, T.Kind.KOOPA)
	s.step()
	var a2 = s.report_enemy_defeat(1, T.Kind.GOOMBA)
	check([a0.seq, a1.seq, a2.seq] == [0, 1, 2], "attacks are numbered in send order (0, 1, 2)")
	check(a0.sent_tick == 2 and a1.sent_tick == 2 and a2.sent_tick == 3, "each carries the tick it was sent on")
	var sent: Array = events_of(s, E.SENT)
	check(sent.size() == 3 and sent.map(func(e): return [e.tick, e.id, e.b, e.kind, e.a]) == [[2, 3, 6, T.Kind.GOOMBA, 0], [2, 4, 6, T.Kind.KOOPA, 1], [3, 1, 6, T.Kind.GOOMBA, 2]], "SENT events carry tick, sender, target, kind and seq")
	var q: Array = s.get_incoming(6)
	check(q.size() == 3 and q.map(func(d): return d.seq) == [0, 1, 2], "the target's queue holds all three, in send order")
	check(q.map(func(d): return [d.sender, d.kind, d.state]) == [[3, T.Kind.GOOMBA, A.State.QUEUED], [4, T.Kind.KOOPA, A.State.QUEUED], [1, T.Kind.GOOMBA, A.State.QUEUED]], "the target received the right enemies from the right senders, QUEUED")
	check(s.get_incoming(5).is_empty() and s.get_incoming(0).is_empty(), "nobody else received anything")
	check(s.attacks.attack_history().size() == 3, "the round's attack history lists every attack")

# ------------------------------------------------------------------ lifecycle

func test_lifecycle() -> void:
	var s = quiet(12, 6)
	var g = s.report_enemy_defeat(3, T.Kind.GOOMBA)
	var k = s.report_enemy_defeat(4, T.Kind.KOOPA)
	var states: Array = []
	for tick in 14:
		s.step()
		states.append([s.tick_count, g.state, k.state])
	var by_tick := {}
	for row in states:
		by_tick[row[0]] = row
	check(by_tick[2][1] == A.State.QUEUED and by_tick[2][2] == A.State.QUEUED, "sent on tick 0, both are QUEUED during the delay")
	check(by_tick[SYS.ACTIVATION_DELAY][1] == A.State.ACTIVE and by_tick[SYS.ACTIVATION_DELAY][2] == A.State.ACTIVE and g.activated_tick == SYS.ACTIVATION_DELAY, "after ACTIVATION_DELAY (%d ticks) both are ACTIVE" % SYS.ACTIVATION_DELAY)
	var g_end: int = g.activated_tick + T.active_ticks(T.Kind.GOOMBA)
	var k_end: int = k.activated_tick + T.active_ticks(T.Kind.KOOPA)
	check(by_tick[g_end - 1][1] == A.State.ACTIVE and by_tick[g_end][1] == A.State.RESOLVED and g.resolved_tick == g_end, "the Goomba is RESOLVED after %d active ticks (tick %d)" % [T.active_ticks(T.Kind.GOOMBA), g_end])
	check(by_tick[k_end - 1][2] == A.State.ACTIVE and by_tick[k_end][2] == A.State.RESOLVED and k.resolved_tick == k_end, "the Koopa after %d (tick %d)" % [T.active_ticks(T.Kind.KOOPA), k_end])
	check(s.get_incoming(6).is_empty() and s.attacks.attack_history().size() == 2 and g.resolution == R.EXPIRED and k.resolution == R.EXPIRED, "resolved attacks leave the queue but stay in the round's history, EXPIRED (bots' timer)")
	var order: Array = s.events.filter(func(e): return e.type in [E.INCOMING_ACTIVATED, E.INCOMING_RESOLVED]).map(func(e): return [e.tick, e.type, e.a, e.id, e.b])
	check(order == [[3, E.INCOMING_ACTIVATED, 0, 6, 3], [3, E.INCOMING_ACTIVATED, 1, 6, 4], [g_end, E.INCOMING_RESOLVED, 0, 6, 3], [k_end, E.INCOMING_RESOLVED, 1, 6, 4]], "INCOMING_ACTIVATED / INCOMING_RESOLVED events come in a fixed order (%s)" % str(order))
	# a replay is identical
	var r = quiet(12, 6)
	r.report_enemy_defeat(3, T.Kind.GOOMBA)
	r.report_enemy_defeat(4, T.Kind.KOOPA)
	for tick in 14:
		r.step()
	check(r.events == s.events and r.attacks.snapshot() == s.attacks.snapshot(), "queued -> active -> resolved progression is deterministic (a replay matches)")
	# the cap: five at once, three active, two wait their turn, in order
	var c = quiet(13, 6)
	for i in 5:
		c.report_enemy_defeat(1 + i, T.Kind.GOOMBA)
	for i in SYS.ACTIVATION_DELAY:
		c.step()
	var inc: Array = c.get_incoming(6)
	check(inc.map(func(d): return d.state) == [A.State.ACTIVE, A.State.ACTIVE, A.State.ACTIVE, A.State.QUEUED, A.State.QUEUED], "at most MAX_ACTIVE (%d) are active; the rest wait" % SYS.MAX_ACTIVE)
	for i in T.active_ticks(T.Kind.GOOMBA):
		c.step()
	var after: Array = c.get_incoming(6)
	check(after.size() == 2 and after.map(func(d): return d.seq) == [3, 4] and after.all(func(d): return d.state == A.State.ACTIVE), "when the first three expire the waiting two activate, in send order")
	# an eliminated target ends what was coming for it
	var t = quiet(14, 9)
	t.report_enemy_defeat(2, T.Kind.KOOPA)
	t.report_enemy_defeat(3, T.Kind.GOOMBA)
	t.step()
	t.report_ko(9, K.HAZARD)
	check(t.get_incoming(9).is_empty() and t.attacks.attack_history().all(func(d): return d.state == A.State.RESOLVED and d.resolution == R.TARGET_OUT), "an eliminated target's attacks are all resolved at once, marked TARGET_OUT")
	var res: Array = events_of(t, E.INCOMING_RESOLVED)
	check(res.size() == 2 and res.all(func(e): return e.cause == R.TARGET_OUT), "...with INCOMING_RESOLVED events carrying that cause")

# ------------------------------------------------------------------ pressure

func test_pressure() -> void:
	var s = quiet(15, 6)
	check(s.attacks.pressure(6) == 0.0, "no incoming: no pressure")
	s.report_enemy_defeat(1, T.Kind.GOOMBA)
	check(s.attacks.pressure(6) == 0.0, "a QUEUED enemy adds no pressure yet")
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	var one: float = s.attacks.pressure(6)
	check(is_equal_approx(one, T.weight(T.Kind.GOOMBA)), "one ACTIVE Goomba adds its weight (%.2f)" % one)
	s.report_enemy_defeat(2, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	var two: float = s.attacks.pressure(6)
	check(is_equal_approx(two, T.weight(T.Kind.GOOMBA) + T.weight(T.Kind.KOOPA)) and two > one, "a second active enemy adds its weight on top (%.2f)" % two)
	check(s.attacks.pressure(5) == 0.0, "pressure belongs to the target only")
	for i in 10:
		s.step()
	check(s.attacks.pressure(6) == 0.0 and s.get_incoming(6).is_empty(), "once they are RESOLVED they stop contributing")
	var full = quiet(16, 6)
	for i in 6:
		full.report_enemy_defeat(1 + i, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		full.step()
	check(full.attacks.pressure(6) <= SYS.MAX_PRESSURE and is_equal_approx(full.attacks.pressure(6), SYS.MAX_ACTIVE * T.weight(T.Kind.KOOPA)), "pressure is the active weights, capped by MAX_ACTIVE (%.2f)" % full.attacks.pressure(6))

## Bot hazard with the same random draws: more pressure can only eliminate sooner.
func test_pressure_raises_bot_elimination() -> void:
	var pressures := [0.0, T.weight(T.Kind.GOOMBA), T.weight(T.Kind.GOOMBA) + T.weight(T.Kind.KOOPA), 3.0 * T.weight(T.Kind.KOOPA)]
	var rates := []
	var coupling_violations := 0
	for pressure in pressures:
		var ko := 0
		for seed_value in 3000:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_value
			var c = load("res://Scripts/Classes/Battle/BattleContestant.gd").new()
			c.skill = 0.5
			c.time_left = 600
			var out: bool = false
			for tick in range(40, 60):
				if BOT.step_bot(c, tick, rng, pressure) != K.NONE:
					out = true
					break
			if out:
				ko += 1
		rates.append(ko / 3000.0)
	check(rates[0] < rates[1] and rates[1] < rates[2] and rates[2] < rates[3], "the more active enemies, the likelier a bot is eliminated (%s)" % str(rates))
	check(rates[2] > rates[0] * 1.5, "two active enemies make elimination over 1.5x as likely (%.3f vs %.3f)" % [rates[2], rates[0]])
	# coupled draws: the same random numbers, with and without pressure, never eliminate the other way round
	var only_pressured := 0
	for seed_value in 3000:
		var pair := []
		for pressure in [0.0, 1.3]:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_value
			var c = load("res://Scripts/Classes/Battle/BattleContestant.gd").new()
			c.skill = 0.5
			c.time_left = 600
			var out := false
			for tick in range(40, 60):
				if BOT.step_bot(c, tick, rng, pressure) != K.NONE:
					out = true
					break
			pair.append(out)
		if pair[0] and not pair[1]:
			coupling_violations += 1
		if pair[1] and not pair[0]:
			only_pressured += 1
	check(coupling_violations == 0 and only_pressured > 100, "with identical draws, pressure only ever eliminates bots that would have survived (%d such, 0 the other way)" % only_pressured)
	# the whole loop: enemies sent to bot 5 shorten its life (the sender keeps sending Goombas and Koopas to it)
	var with_attacks := 0.0
	var without := 0.0
	var n := 200
	var out_with := 0
	var out_without := 0
	for seed_value in n:
		for enabled in [true, false]:
			S.default_attacks_enabled = enabled
			var s = S.new(seed_value)
			s.attacks.bots_send = false
			var p = FixedPolicy.new()
			p.target = 5
			s.attacks.targeting = p
			for tick in 45:
				if tick % 3 == 0 and s.contestants[20].alive:
					s.report_enemy_defeat(20, T.Kind.GOOMBA if tick % 2 == 0 else T.Kind.KOOPA)
				s.step()
				if not s.contestants[5].alive:
					break
			var life: float = s.contestants[5].ko_tick if not s.contestants[5].alive else 45.0
			if enabled:
				with_attacks += life
				out_with += 0 if s.contestants[5].alive else 1
			else:
				without += life
				out_without += 0 if s.contestants[5].alive else 1
	S.default_attacks_enabled = true
	check(out_with > out_without * 1.3 and with_attacks < without * 0.85, "sending enemies to a bot measurably shortens its life: %d of %d eliminated within 45 s with attacks vs %d without (mean %.1f vs %.1f s)" % [out_with, n, out_without, with_attacks / n, without / n])

# ------------------------------------------------------------------ bots send

func test_bot_sends() -> void:
	var s = S.new(21)
	for i in 200:
		if s.finished:
			break
		s.step()
	var sent: Array = events_of(s, E.SENT)
	check(sent.size() >= 5, "simulated bots generate sends (%d in %d ticks)" % [sent.size(), s.tick_count])
	check(sent.all(func(e): return e.id >= 1 and e.b != e.id), "all of them are from bots, never to themselves")
	check(sent.any(func(e): return e.b >= 1), "bots can send to other bots")
	var to_player := 0
	var kinds := {}
	for seed_value in 40:
		var t = S.new(seed_value)
		for i in 150:
			if t.finished:
				break
			t.step()
		for e in events_of(t, E.SENT):
			kinds[e.kind] = true
			if e.b == 0:
				to_player += 1
	check(to_player > 0, "bots can target the real player (%d sends to the player over 40 matches)" % to_player)
	check(kinds.has(T.Kind.GOOMBA) and kinds.has(T.Kind.KOOPA), "bots defeat both Goombas and Koopas")
	# every defeat has its send, in order, on the same tick
	var ok := true
	for i in range(0, s.events.size()):
		var e: Dictionary = s.events[i]
		if e.type == E.ENEMY_DEFEATED and e.b >= 0:
			if s.events[i + 1].type != E.SENT or s.events[i + 2].type != E.RECEIVED or s.events[i + 1].a != e.b or s.events[i + 1].tick != e.tick:
				ok = false
	check(ok, "every defeat is followed by its SENT and RECEIVED on the same tick")
	var again = S.new(21)
	for i in 200:
		if again.finished:
			break
		again.step()
	check(again.events == s.events and again.snapshot() == s.snapshot(), "bot sends are reproducible for a seed")
	var faster := 0
	var gains_checked := 0
	# a bot that advances further sends more: compare the fastest and slowest bots over many matches
	var counts := {}
	for seed_value in 30:
		var t = S.new(seed_value)
		for i in 120:
			if t.finished:
				break
			t.step()
		for e in events_of(t, E.SENT):
			var sk: float = t.contestants[e.id].skill
			var bucket := 0 if sk < 0.5 else 1
			counts[bucket] = counts.get(bucket, 0) + 1
	check(counts.get(1, 0) > counts.get(0, 0), "faster (higher-skill) bots send more (%s)" % str(counts))

# ------------------------------------------------------------------ the player as a target

func test_player_incoming() -> void:
	var s = quiet(31, 0)
	var before = s.contestants[0]
	var row_before := [before.alive, before.power, before.levels_cleared, before.progress]
	s.report_enemy_defeat(7, T.Kind.KOOPA)
	s.report_enemy_defeat(8, T.Kind.GOOMBA)
	check(s.get_incoming(0).size() == 2 and s.get_incoming(0).all(func(d): return d.target == 0), "attacks aimed at the real player are recorded in the player's queue")
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	check(s.get_incoming(0).all(func(d): return d.state == A.State.ACTIVE) and events_of(s, E.INCOMING_ACTIVATED).any(func(e): return e.id == 0), "...and they activate like anyone's (the events show them going active on the player)")
	var p = s.contestants[0]
	check(p.alive and [p.alive, p.power, p.levels_cleared, p.progress] == row_before, "the real player's state is untouched by them (alive, power, progress, levels)")
	# identical to a run with the system off, as far as the player goes
	var off = S.new(31)
	off.attacks.enabled = false
	var on = S.new(31)
	on.attacks.bots_send = false
	var fixed = FixedPolicy.new()
	fixed.target = 0
	on.attacks.targeting = fixed
	for i in 60:
		if i % 4 == 0:
			on.report_enemy_defeat(9, T.Kind.KOOPA)
		on.step()
		off.step()
	check(on.get_player().time_left == off.get_player().time_left and on.get_player().alive == off.get_player().alive and on.get_player().ko_cause == off.get_player().ko_cause, "heavy incoming fire at the player changes nothing about the player: no hidden penalty (time %d, alive %s)" % [on.get_player().time_left, str(on.get_player().alive)])
	check(on.attacks.pressure(0) > 0.0, "(the player does carry pressure as plain state, for a future UI)")
	var hits := 0
	for e in on.events:
		if e.type == E.HIT and e.id == 0:
			hits += 1
	check(hits == 0, "no HIT event is ever generated for the player by an attack")

# ------------------------------------------------------------------ separate random streams

## Runs a session `ticks` ticks with bots sending; `kill_at` maps tick -> how many player defeats are
## reported at the start of that tick. Returns the session.
func run_with_player_kills(seed_value: int, ticks: int, kill_at: Dictionary, pressure := true):
	var s = S.new(seed_value)
	s.attacks.pressure_enabled = pressure
	for tick in ticks:
		for i in kill_at.get(tick, 0):
			s.report_enemy_defeat(0, T.Kind.GOOMBA if (tick + i) % 2 == 0 else T.Kind.KOOPA)
		s.step()
	return s

## A bot's attack is identified by who, to whom, what and when; `seq` and `defeat_seq` are round-wide
## counters that the player's own sends also advance, so they are not part of a bot's identity.
func bot_attacks(s) -> Array:
	return s.attacks.attack_history().filter(func(d): return d.sender != 0).map(func(d): return [d.sender, d.target, d.kind, d.sent_tick])

func test_rng_streams() -> void:
	var s = S.new(500)
	check(SYS.BOT_SALT != SYS.PLAYER_SALT and s.attacks.bot_rng.seed == (500 ^ SYS.BOT_SALT) and s.attacks.player_rng.seed == (500 ^ SYS.PLAYER_SALT), "each stream is the session seed xor its own salt (bot %x, player %x)" % [SYS.BOT_SALT, SYS.PLAYER_SALT])
	check(s.attacks.bot_rng.seed != s.attacks.player_rng.seed and s.attacks.bot_rng.seed != s.rng.seed and s.attacks.player_rng.seed != s.rng.seed, "...and all three streams (bot, player, main simulation) differ")
	check(s.attacks.bot_rng.randf() != s.attacks.player_rng.randf(), "the bot and player streams do not produce the same numbers")
	# the main simulation stream is never touched by the attack streams, whatever they are used for
	var plain = S.new(500)
	plain.attacks.enabled = false
	var busy = S.new(500)
	var main_before: int = busy.rng.state
	for i in 40:
		busy.attacks.report_defeat(busy, 0, T.Kind.GOOMBA)
		busy.attacks.report_defeat(busy, 1 + i % 34, T.Kind.KOOPA)
	check(busy.rng.state == main_before and busy.rng.state == plain.rng.state, "sending enemies never draws from the main simulation stream (its state is untouched)")
	# the bot stream advances by a fixed amount per tick: its state depends on the tick count alone
	var ref = S.new(501)
	var ref_states := []
	for tick in 60:
		ref.step()
		ref_states.append(ref.attacks.bot_rng.state)
	var other = S.new(501)
	var killed = S.new(501)
	var kills := {5: 2, 6: 1, 20: 3, 33: 1, 50: 2}
	var same_states := true
	for tick in 60:
		for i in kills.get(tick, 0):
			killed.report_enemy_defeat(0, T.Kind.GOOMBA)
		killed.step()
		other.step()
		if killed.attacks.bot_rng.state != ref_states[tick] or other.attacks.bot_rng.state != ref_states[tick]:
			same_states = false
	check(same_states, "the bot stream's state after every tick is the same whether or not the player defeated enemies (60 ticks)")
	check(killed.attacks.player_defeats == 9 and killed.attacks.player_rng.state != other.attacks.player_rng.state and other.attacks.player_rng.state == S.new(501).attacks.player_rng.state, "the player stream advances only with the player's own defeats (9 accepted draws)")
	var one_tick = S.new(502)
	var before: int = one_tick.attacks.bot_rng.state
	one_tick.step()
	var probe = RandomNumberGenerator.new()
	probe.seed = 502 ^ SYS.BOT_SALT
	for i in (S.CONTESTANT_COUNT - 1) * SYS.DRAWS_PER_BOT:
		probe.randf()
	check(one_tick.attacks.bot_rng.state == probe.state and before != probe.state, "one tick consumes exactly DRAWS_PER_BOT (%d) draws for each of the 34 bots, sending or not" % SYS.DRAWS_PER_BOT)

	# bot-vs-bot outcomes for a seed do not move when the player defeats enemies at other times
	var quiet_run = run_with_player_kills(503, 150, {}, false)
	var kill_a = run_with_player_kills(503, 150, {10: 1, 11: 2, 40: 1, 90: 3}, false)
	var kill_b = run_with_player_kills(503, 150, {3: 2, 77: 1, 120: 4}, false)
	var none_sent: Array = bot_attacks(quiet_run)
	check(none_sent.size() > 5 and bot_attacks(kill_a) == none_sent and bot_attacks(kill_b) == none_sent, "every bot attack (sender, target, kind, tick) is identical with no player kills, early ones and late ones (%d bot attacks)" % none_sent.size())
	check(kill_a.attacks.player_defeats == 7 and kill_b.attacks.player_defeats == 7 and quiet_run.attacks.player_defeats == 0, "(and the player's defeats really were reported)")
	var bot_rows_equal := true
	for i in range(1, 35):
		var a = quiet_run.contestants[i]
		var b = kill_a.contestants[i]
		if [a.alive, a.ko_tick, a.levels_cleared, a.progress, a.power] != [b.alive, b.ko_tick, b.levels_cleared, b.progress, b.power]:
			bot_rows_equal = false
	check(bot_rows_equal and quiet_run.rng.state == kill_a.rng.state and quiet_run.alive_count == kill_a.alive_count, "...and so is every bot's state and the main stream, when the player's sends add no pressure")
	check(quiet_run.attacks.bot_rng.state == kill_a.attacks.bot_rng.state and quiet_run.attacks.bot_rng.state == kill_b.attacks.bot_rng.state, "the bot stream state is the same after 150 ticks in all three runs")
	# with pressure on, what the player sends can change bots' fates, but never the bot stream's draws
	var hot = run_with_player_kills(503, 150, {10: 3, 11: 3, 12: 3, 13: 3, 14: 3}, true)
	check(hot.attacks.bot_rng.state == quiet_run.attacks.bot_rng.state and hot.events.size() > 0, "even with pressure on, the player's sends cannot shift the bot stream (only game state can differ)")
	# the player's targets are a function of the seed and the player's own defeat sequence
	var seq_a := player_targets(504, [0, 0, 0, 0, 0, 0], false)
	var seq_b := player_targets(504, [0, 0, 0, 0, 0, 0], true)
	check(seq_a == seq_b and seq_a.size() == 6 and not seq_a.has(-1), "the same seed and the same defeat sequence give the same player targets, bots sending or not: %s" % str(seq_a))
	# whenever the defeats happen, the player's n-th pick is the same random draw (the survivors it
	# is applied to can differ by then, since the bots keep playing, but the draw does not)
	var draws_now := player_draws(504, 6, 0, false)
	var draws_spaced := player_draws(504, 6, 7, true)
	var draws_late := player_draws(504, 6, 31, false)
	check(draws_now.size() == 6 and draws_now == draws_spaced and draws_now == draws_late, "the player's n-th pick is the same draw whether the defeats come at once or tens of ticks apart, with the bots sending or not")
	check(draws_now != player_draws(505, 6, 0, false), "...and another seed draws differently")
	check(player_targets(505, [0, 0, 0, 0, 0, 0], false) != seq_a, "a different seed gives different player targets")
	var later := player_targets(504, [0, 0, 0, 0, 0, 0, 0], false)
	check(later.slice(0, 6) == seq_a, "the player's n-th target does not depend on how many defeats follow it")
	# changing the player's timing or order only touches the player stream
	var early = run_with_player_kills(506, 100, {2: 3}, false)
	var late = run_with_player_kills(506, 100, {80: 3}, false)
	var early_t: Array = early.attacks.attack_history().filter(func(d): return d.sender == 0).map(func(d): return d.target)
	var late_t: Array = late.attacks.attack_history().filter(func(d): return d.sender == 0).map(func(d): return d.target)
	check(early_t.size() == 3 and late_t.size() == 3, "(three player sends in each run)")
	check(early.attacks.player_rng.state == late.attacks.player_rng.state, "the same number of player defeats leaves the player stream in the same place, whenever they happen")

func player_targets(seed_value: int, senders: Array, bots_send: bool) -> Array:
	var s = S.new(seed_value)
	s.attacks.bots_send = bots_send
	s.attacks.pressure_enabled = false
	var out := []
	for i in senders.size():
		var a = s.report_enemy_defeat(0, T.Kind.GOOMBA)
		out.append(a.target if a != null else -1)
	return out

## The uniform draws the targeting policy was handed for the player's first `n` defeats, with `gap`
## ticks of the match played between them.
func player_draws(seed_value: int, n: int, gap: int, bots_send: bool) -> Array:
	var s = S.new(seed_value)
	s.attacks.bots_send = bots_send
	s.attacks.pressure_enabled = false
	var rec = RecordPolicy.new()
	s.attacks.targeting = rec
	for i in n:
		for t in gap:
			s.step()
		s.report_enemy_defeat(0, T.Kind.GOOMBA)
	return rec.draws

# ------------------------------------------------------------------ the real player's incoming attacks

func test_player_incoming_resolution() -> void:
	var s = quiet(600, 0)
	var a0 = s.report_enemy_defeat(3, T.Kind.GOOMBA)
	var a1 = s.report_enemy_defeat(4, T.Kind.KOOPA)
	var a2 = s.report_enemy_defeat(5, T.Kind.GOOMBA)
	var a3 = s.report_enemy_defeat(6, T.Kind.KOOPA)
	check(s.get_incoming(0).map(func(d): return d.state) == [A.State.QUEUED, A.State.QUEUED, A.State.QUEUED, A.State.QUEUED], "QUEUED against the real player first")
	check(s.resolve_player_incoming(a0.seq, R.OTHER) == false and a0.state == A.State.QUEUED, "a QUEUED attack cannot be resolved by the game: it is not in a level yet")
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	check(s.get_incoming(0).map(func(d): return d.state) == [A.State.ACTIVE, A.State.ACTIVE, A.State.ACTIVE, A.State.QUEUED], "...then ACTIVE in send order, at most MAX_ACTIVE (%d) at a time" % SYS.MAX_ACTIVE)
	# no timer: far longer than any enemy's active time
	for i in 120:
		s.step()
	check(s.get_incoming(0).map(func(d): return d.state) == [A.State.ACTIVE, A.State.ACTIVE, A.State.ACTIVE, A.State.QUEUED] and a0.resolved_tick == -1, "an ACTIVE attack on the player does not resolve on a timer (still active after 120 ticks)")
	check(events_of(s, E.INCOMING_RESOLVED).is_empty(), "...no INCOMING_RESOLVED event was produced")
	# explicit resolution by sequence id
	var tick_before: int = s.tick_count
	check(s.resolve_player_incoming(a1.seq, R.DEFEATED_BY_PLAYER) == true, "the game resolves one specific active attack by its sequence id")
	check(a1.state == A.State.RESOLVED and a1.resolution == R.DEFEATED_BY_PLAYER and a1.resolved_tick == tick_before and a0.state == A.State.ACTIVE and a2.state == A.State.ACTIVE, "...only that one: it is RESOLVED with the reported cause, the others stay ACTIVE")
	var ev: Array = events_of(s, E.INCOMING_RESOLVED)
	check(ev.size() == 1 and ev[0].id == 0 and ev[0].a == a1.seq and ev[0].b == 4 and ev[0].kind == T.Kind.KOOPA and ev[0].cause == R.DEFEATED_BY_PLAYER, "an INCOMING_RESOLVED event records target, seq, sender, kind and the cause")
	check(s.get_incoming(0).map(func(d): return d.seq) == [a0.seq, a2.seq, a3.seq], "the resolved attack left the player's queue")
	# duplicate and bad resolves are harmless
	var snap = s.attacks.snapshot()
	var n_events: int = s.events.size()
	check(s.resolve_player_incoming(a1.seq, R.DEFEATED_BY_PLAYER) == false and s.resolve_player_incoming(a1.seq, R.OTHER) == false, "resolving the same attack again is refused")
	check(s.resolve_player_incoming(999, R.OTHER) == false and s.resolve_player_incoming(-1, R.OTHER) == false, "an unknown id is refused")
	check(s.resolve_player_incoming(a0.seq, R.NONE) == false and s.resolve_player_incoming(a0.seq, R.EXPIRED) == false, "NONE and EXPIRED are not causes the game can report")
	check(s.attacks.snapshot() == snap and s.events.size() == n_events, "...and none of that changed anything")
	# the freed slot lets the waiting one in, in order
	s.step()
	check(a3.state == A.State.ACTIVE, "a QUEUED attack activates when a slot frees (the next tick)")
	# each cause can be reported
	for cause in [R.DESPAWNED, R.OTHER]:
		var live: Array = s.get_incoming(0).filter(func(d): return d.state == A.State.ACTIVE)
		check(s.resolve_player_incoming(live[0].seq, cause) and s.attacks.history[live[0].seq].resolution == cause, "the game can report %s" % A.resolution_name(cause))
	# attacks aimed at a bot are not the game's to resolve; they stay timed
	var b = quiet(601, 6)
	var ba = b.report_enemy_defeat(1, T.Kind.GOOMBA)
	for i in SYS.ACTIVATION_DELAY:
		b.step()
	check(ba.state == A.State.ACTIVE and b.resolve_player_incoming(ba.seq, R.DEFEATED_BY_PLAYER) == false and ba.state == A.State.ACTIVE, "an attack aimed at a bot cannot be resolved through the player API")
	for i in T.active_ticks(T.Kind.GOOMBA):
		b.step()
	check(ba.state == A.State.RESOLVED and ba.resolution == R.EXPIRED and ba.resolved_tick == ba.activated_tick + T.active_ticks(T.Kind.GOOMBA), "...it expires on its deterministic timer, exactly as before")
	# a bot-targeted attack timed exactly like the original model, in the same session as a player one
	var mix = quiet(602, 0)
	var to_player = mix.report_enemy_defeat(1, T.Kind.GOOMBA)
	var fixed = FixedPolicy.new()
	fixed.target = 7
	mix.attacks.targeting = fixed
	var to_bot = mix.report_enemy_defeat(1, T.Kind.GOOMBA)
	for i in 30:
		mix.step()
	check(to_bot.state == A.State.RESOLVED and to_player.state == A.State.ACTIVE, "side by side, the bot's attack resolved on its timer and the player's is still active")
	# the player's elimination ends them, with their own cause
	var dead = quiet(603, 0)
	var d0 = dead.report_enemy_defeat(2, T.Kind.GOOMBA)
	var d1 = dead.report_enemy_defeat(3, T.Kind.KOOPA)
	for i in 4:
		dead.step()
	dead.report_ko(0, K.HAZARD)
	check(d0.resolution == R.TARGET_OUT and d1.resolution == R.TARGET_OUT and dead.get_incoming(0).is_empty(), "when the real player is eliminated, everything aimed at them ends as TARGET_OUT")
	check(dead.resolve_player_incoming(d0.seq, R.OTHER) == false, "...and nothing can resolve it again")
	# nothing spawns, nothing is applied: the player's own state stays exactly what the real game made it
	var p = s.contestants[0]
	check(p.alive and p.levels_cleared == 0 and p.power == 0, "(resolving or not, the contestant record of the real player is untouched)")

# ------------------------------------------------------------------ round cleanup

func test_round_cleanup() -> void:
	var s = quiet(610, 0)
	var a = s.report_enemy_defeat(2, T.Kind.GOOMBA)
	var b = s.report_enemy_defeat(3, T.Kind.KOOPA)
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	var c = s.report_enemy_defeat(4, T.Kind.GOOMBA) # still QUEUED
	var mid: Array = s.get_incoming(0).map(func(d): return d.state)
	check(mid == [A.State.ACTIVE, A.State.ACTIVE, A.State.QUEUED], "(setup: two ACTIVE and one QUEUED against the player)")
	# a level transition ends only what was ACTIVE in the level that went away
	var n: int = s.resolve_player_active(R.LEVEL_TRANSITION)
	check(n == 2 and a.resolution == R.LEVEL_TRANSITION and b.resolution == R.LEVEL_TRANSITION and c.state == A.State.QUEUED, "a level transition resolves the ACTIVE attacks (LEVEL_TRANSITION) and leaves the QUEUED one waiting")
	check(s.resolve_player_active(R.LEVEL_TRANSITION) == 0 and events_of(s, E.INCOMING_RESOLVED).size() == 2, "...and doing it twice changes nothing")
	for i in SYS.ACTIVATION_DELAY:
		s.step()
	check(c.state == A.State.ACTIVE, "the waiting one becomes active in the next level, in order")
	# the round ends: everything left is resolved, with an explicit cause
	var d = s.report_enemy_defeat(5, T.Kind.KOOPA)
	var bot_one = quiet(611, 6)
	var bo = bot_one.report_enemy_defeat(1, T.Kind.GOOMBA)
	check(s.end_round() == 2 and c.resolution == R.ROUND_ENDED and d.resolution == R.ROUND_ENDED and s.get_incoming(0).is_empty(), "ending the round resolves both the active and the queued attack on the player as ROUND_ENDED")
	var ends: Array = events_of(s, E.INCOMING_RESOLVED).filter(func(e): return e.cause == R.ROUND_ENDED)
	check(ends.size() == 2 and s.attacks.round_ended, "...each with an INCOMING_RESOLVED event, and the system is closed")
	var n_events: int = s.events.size()
	var snap = s.attacks.snapshot()
	check(s.end_round() == 0 and s.report_enemy_defeat(7, T.Kind.GOOMBA) == null and s.resolve_player_incoming(c.seq, R.OTHER) == false and s.events.size() == n_events and s.attacks.snapshot() == snap, "after that nothing is sent or resolved, and ending again is harmless")
	s.step()
	check(s.events.size() == n_events or s.events.slice(n_events).all(func(e): return e.type != E.INCOMING_ACTIVATED), "a closed round activates nothing")
	check(bo.state == A.State.QUEUED and bot_one.end_round() == 1 and bo.resolution == R.ROUND_ENDED, "it covers attacks aimed at bots too")
	# a match that finishes closes its round by itself
	var w = quiet(612, 0)
	var wa = w.report_enemy_defeat(2, T.Kind.KOOPA)
	var wb = w.report_enemy_defeat(3, T.Kind.GOOMBA)
	for i in 4:
		w.step()
	for id in range(1, 35):
		w.report_ko(id, K.HAZARD)
	check(w.finished and w.winner_id == 0 and wa.resolution == R.ROUND_ENDED and wb.resolution == R.ROUND_ENDED and w.attacks.round_ended, "when the player wins, what was still active against them ends as ROUND_ENDED")
	var lost = quiet(613, 0)
	var la = lost.report_enemy_defeat(2, T.Kind.KOOPA)
	lost.step()
	lost.report_ko(0, K.HAZARD)
	lost.resolve_to_end()
	check(lost.finished and la.resolution == R.TARGET_OUT and lost.get_incoming(0).is_empty(), "when the player is out first, their attacks ended as TARGET_OUT and the bots can still play the match out")
	check(lost.attacks.history.all(func(d): return d.state == A.State.RESOLVED) and lost.attacks.round_ended, "after the match is finished nothing anywhere is unresolved")
	# a full simulated match leaves nothing behind
	var full = S.new(614)
	full.resolve_to_end()
	var leftover := 0
	for id in 35:
		leftover += full.get_incoming(id).size()
	check(full.finished and leftover == 0 and full.attacks.history.all(func(d): return d.state == A.State.RESOLVED and d.resolution != R.NONE), "a full match ends with every attack RESOLVED and given a cause (%d attacks)" % full.attacks.history.size())
	# nothing leaks into the next round
	S.begin(615)
	var fresh = S.current
	check(fresh.attacks.history.is_empty() and not fresh.attacks.round_ended and fresh.get_incoming(0).is_empty() and fresh.attacks.defeats == 0 and fresh.attacks.defeat_sources.is_empty(), "the next round starts with no attacks, no kills counted and an open attack system")
	S.clear()

# ------------------------------------------------------------------ kill attribution (pure model)

func test_attribution_model() -> void:
	check(SRC.keys().has("UNKNOWN") and SRC.keys().has("PLAYER") and SRC.keys().has("ENEMY") and SRC.keys().has("ENVIRONMENT") and SRC.UNKNOWN == 0, "the model distinguishes PLAYER, ENEMY, ENVIRONMENT and UNKNOWN, and UNKNOWN is the zero value")
	check(AT.of(null) == SRC.UNKNOWN and AT.of(5) == SRC.UNKNOWN and AT.of("x") == SRC.UNKNOWN, "no cause, or something that is not a node, is UNKNOWN")
	var freed := Node.new()
	freed.free()
	check(AT.of(freed) == SRC.UNKNOWN, "a freed object is UNKNOWN")
	var plain := Node.new()
	check(AT.of(plain) == SRC.UNKNOWN, "an unrecognised node is UNKNOWN")
	var player := Node.new()
	player.add_to_group("Players")
	check(AT.of(player) == SRC.PLAYER, "a player (stomp, hammer, star) is PLAYER")
	var bolt := Node.new()
	bolt.set_meta("IsPlayerProjectile", "true")
	check(AT.of(bolt) == SRC.PLAYER, "a projectile the player threw is PLAYER")
	var enemy := Node.new()
	enemy.add_to_group("Enemies")
	check(AT.of(enemy) == SRC.ENEMY, "another enemy is ENEMY")
	# the real game scripts (a shell a real player kicked is checked in tests/battle_attack_game_test.gd)
	var shell_like: Node = load("res://Scripts/Classes/Entities/ShellClass.gd").new()
	shell_like.add_to_group("Enemies")
	check(AT.of(shell_like) == SRC.UNKNOWN, "a shell nobody has kicked is UNKNOWN (not ENEMY, not PLAYER)")
	var gone := Node.new()
	gone.add_to_group("Players")
	gone.free()
	var spike: Node = load("res://Scripts/Classes/Entities/Objects/SpikeBall.gd").new()
	spike.add_to_group("Enemies")
	check(AT.of(spike) == SRC.ENVIRONMENT, "a spike ball is ENVIRONMENT")
	var icicle: Node = load("res://Scripts/Classes/Entities/Enemies/Icicle.gd").new()
	icicle.add_to_group("Enemies")
	check(AT.of(icicle) == SRC.ENVIRONMENT, "a falling icicle is ENVIRONMENT, though it is an Enemy subclass")
	# blocks: only a bump the player made, recently, counts
	var block := Node.new()
	check(AT.of(block) == SRC.UNKNOWN, "a bouncing block nobody was seen bumping is UNKNOWN")
	AT.tag_block_bump(block, player)
	check(AT.of(block) == SRC.PLAYER, "a block the player just bumped is PLAYER")
	block.set_meta(AT.BUMP_META, [player, Engine.get_physics_frames() - AT.BUMP_FRAMES - 1])
	check(AT.of(block) == SRC.UNKNOWN, "...but not once the bump is old")
	block.set_meta(AT.BUMP_META, [gone, Engine.get_physics_frames()])
	check(AT.of(block) == SRC.UNKNOWN, "...nor when the bumper is gone")
	AT.tag_block_bump(null, player)
	AT.tag_block_bump(block, null) # (must not raise)
	check(AT.name_of(SRC.PLAYER) == "PLAYER" and AT.name_of(99) == "UNKNOWN", "names are readable")
	# what the session does with an attribution
	var g := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
	S.begin(620)
	S.current.attacks.bots_send = false
	var sent = S.report_enemy_kill(g, SRC.PLAYER)
	check(sent != null and sent.sender == 0 and S.current.attacks.history.size() == 1, "a PLAYER kill sends")
	var counts_before: int = S.current.events.size()
	for source in [SRC.ENEMY, SRC.ENVIRONMENT, SRC.UNKNOWN]:
		check(S.report_enemy_kill(g, source) == null, "a %s kill sends nothing" % AT.name_of(source))
	check(S.current.attacks.history.size() == 1 and S.current.events.size() == counts_before and S.current.attacks.defeats == 1 and S.current.attacks.player_defeats == 1, "...and leaves no event, no defeat and no attack behind")
	check(S.current.attacks.defeat_sources == {SRC.PLAYER: 1, SRC.ENEMY: 1, SRC.ENVIRONMENT: 1, SRC.UNKNOWN: 1}, "every reported kill is still counted by source (%s)" % str(S.current.attacks.defeat_sources))
	var rng_before: int = S.current.attacks.player_rng.state
	S.report_enemy_kill(g, SRC.UNKNOWN)
	check(S.current.attacks.player_rng.state == rng_before, "an unattributed kill does not touch the player's random stream")
	S.clear()
	for n in [player, bolt, enemy, shell_like, spike, icicle, block, plain]:
		if is_instance_valid(n):
			n.free()

# ------------------------------------------------------------------ eliminated senders

func test_senders_out() -> void:
	var s = quiet(41)
	s.report_ko(3, K.HAZARD)
	var n: int = s.events.size()
	check(s.report_enemy_defeat(3, T.Kind.GOOMBA) == null and s.attacks.history.is_empty() and s.events.size() == n, "an eliminated bot cannot send: nothing is sent or logged")
	s.report_ko(0, K.HAZARD)
	n = s.events.size()
	check(s.report_enemy_defeat(0, T.Kind.KOOPA) == null and s.events.size() == n, "an eliminated player cannot send either")
	# over a whole match, no send or defeat ever comes from someone already out
	var violations := 0
	for seed_value in 25:
		var t = S.new(seed_value)
		for i in 400:
			if t.finished:
				break
			t.step()
		for e in t.events:
			if e.type in [E.ENEMY_DEFEATED, E.SENT]:
				var c = t.contestants[e.id]
				if not c.alive and c.ko_tick <= e.tick:
					violations += 1
	check(violations == 0, "no attack event is ever generated by a contestant who is already out (25 matches)")
	# a match that is over sends nothing
	var f = quiet(42)
	for id in range(1, 35):
		f.report_ko(id, K.HAZARD)
	check(f.finished and f.report_enemy_defeat(0, T.Kind.GOOMBA) == null, "nothing is sent once the match is over")
	# but what an eliminated sender already sent still arrives
	var g = quiet(43, 6)
	g.report_enemy_defeat(3, T.Kind.KOOPA)
	g.report_ko(3, K.HAZARD)
	check(g.get_incoming(6).size() == 1, "an enemy already sent still arrives after its sender is eliminated")

# ------------------------------------------------------------------ enabled / disabled

func test_enabled_disabled() -> void:
	var results := {}
	for mode in ["on", "off", "idle"]:
		S.default_attacks_enabled = mode != "off"
		var s = S.new(1234)
		if mode == "idle":
			s.attacks.bots_send = false # machinery on, but nothing is ever sent
		s.resolve_to_end()
		results[mode] = s
	S.default_attacks_enabled = true
	var off = results.off
	var on = results.on
	var idle = results.idle
	check(off.events.filter(func(e): return e.type >= E.ENEMY_DEFEATED).is_empty() and off.attacks.history.is_empty(), "with attacks off there are no attack events and no attacks")
	# Persistent targets (doc 47 M-T1) are bookkeeping, not a send: with the loop on, contestants re-target when
	# their target goes out, and that is logged as TARGET_CHANGED. Nothing else may differ from the attack-free log.
	var idle_events: Array = idle.events.filter(func(e): return e.type != E.TARGET_CHANGED)
	check(idle_events == off.events and idle.events.any(func(e): return e.type == E.TARGET_CHANGED) and off.events.filter(func(e): return e.type == E.TARGET_CHANGED).is_empty(), "with the machinery on but nothing sent, the match is bit-identical to the attack-free one apart from the targets' own TARGET_CHANGED bookkeeping")
	check(idle.rng.state == off.rng.state and idle.tick_count == off.tick_count and idle.winner_id == off.winner_id and idle.snapshot().rows == off.snapshot().rows, "...the bots' own random stream, the match length, the winner and every contestant's outcome are exactly the attack-free ones")
	var differ := 0
	for seed_value in 30:
		var a = S.new(seed_value)
		a.resolve_to_end()
		S.default_attacks_enabled = false
		var b = S.new(seed_value)
		b.resolve_to_end()
		S.default_attacks_enabled = true
		if a.tick_count != b.tick_count or a.winner_id != b.winner_id or a.get_ranking() != b.get_ranking():
			differ += 1
	check(differ >= 20, "enabling attacks changes how matches play out (%d of 30 seeds differ)" % differ)
	var again = S.new(1234)
	again.resolve_to_end()
	check(again.snapshot() == on.snapshot() and again.events == on.events and again.winner_id == on.winner_id, "...and the new outcome is exactly reproducible for a seed")
	check(on.events.filter(func(e): return e.type == E.SENT).size() > 20, "(a full match contains plenty of sends: %d)" % on.events.filter(func(e): return e.type == E.SENT).size())
	var off2 = S.new(1234)
	off2.attacks.enabled = false
	off2.resolve_to_end()
	check(off2.snapshot().rows == off.snapshot().rows and off2.rng.state == off.rng.state, "switching the system off on an existing session gives the same attack-free outcome as creating it off")

# ------------------------------------------------------------------ rounds

func test_round_isolation() -> void:
	S.begin(77)
	var first = S.current
	first.attacks.bots_send = true
	for i in 120:
		if first.finished:
			break
		first.step()
	first.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(first.attacks.history.size() > 0 and first.attacks.next_seq > 0 and first.events.any(func(e): return e.type == E.SENT), "round 1 has attack state")
	var old_policy = first.attacks.targeting
	S.begin(78)
	var fresh = S.current
	check(fresh != first and fresh.attacks != first.attacks, "a fresh round is a fresh session with its own attack system")
	var fresh_ok: bool = fresh.attacks.history.is_empty() and fresh.attacks.next_seq == 0 and fresh.attacks.defeats == 0 and fresh.events.is_empty()
	for id in 35:
		if not fresh.get_incoming(id).is_empty() or fresh.attacks.pressure(id) != 0.0:
			fresh_ok = false
	check(fresh_ok, "incoming queues, active attacks, sequence numbers and the event history are all empty")
	check(fresh.attacks.targeting != old_policy and fresh.attacks.bot_rng.state == S.new(78).attacks.bot_rng.state and fresh.attacks.player_rng.state == S.new(78).attacks.player_rng.state and not fresh.attacks.round_ended, "targeting state is new and both random streams start from the new seed")
	var a = fresh.report_enemy_defeat(0, T.Kind.KOOPA)
	check(a != null and a.seq == 0, "the first attack of the new round is seq 0 again")
	S.clear()

# ------------------------------------------------------------------ read-only views

func test_read_only_views() -> void:
	var s = quiet(51, 6)
	s.report_enemy_defeat(2, T.Kind.GOOMBA)
	var view: Array = s.get_incoming(6)
	view[0].state = A.State.RESOLVED
	view[0].kind = 99
	view.clear()
	var hist: Array = s.attacks.attack_history()
	hist.clear()
	check(s.get_incoming(6).size() == 1 and s.get_incoming(6)[0].state == A.State.QUEUED and s.get_incoming(6)[0].kind == T.Kind.GOOMBA and s.attacks.history.size() == 1, "the queue handed to presentation code is a copy: changing it changes nothing")
