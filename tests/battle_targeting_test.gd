extends SceneTree
## Deterministic checks of the targeting core (doc 47 milestone M-T1, doc 49): every contestant holds one
## persistent, always valid target; sends go to it as the sender's mode updates it; the player's four modes
## (Random, Lowest Time, Most Coins, Attackers) are policies behind one router; a KO re-targets on the same
## tick; `attackers_of` is exact; and none of it touches the random streams' counts. Pure data: no scene tree.
##   godot --headless --path . -s tests/battle_targeting_test.gd

var failures := 0
var S # BattleSession
var A # BattleAttack
var T # BattleEnemyType
var E # BattleSession.EventType
var K # BattleSession.KoCause
var SYS # BattleAttackSystem
var TG # BattleTargeting
var M # BattleTargeting.Mode
var PRES # BattleAttackPresentation
var FixedPolicy

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
	A = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	T = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	E = S.EventType
	K = S.KoCause
	SYS = load("res://Scripts/Classes/Battle/BattleAttackSystem.gd")
	TG = load("res://Scripts/Classes/Battle/BattleTargeting.gd")
	M = TG.Mode
	PRES = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	S.default_attacks_enabled = true
	test_initial_targets()
	test_random_sends()
	test_random_distribution()
	test_ko_retarget()
	test_attackers_of()
	test_lowest_time()
	test_attackers_mode()
	test_most_coins()
	test_mode_api()
	test_modes_change_future_sends_only()
	test_streams_and_bots()
	test_whole_matches()
	test_determinism()
	test_presentation_target()
	test_event_numbering()
	S.default_attacks_enabled = true
	if failures > 0:
		printerr("%d Battle targeting test(s) failed" % failures)
	else:
		print("All Battle targeting tests passed")
	quit(1 if failures > 0 else 0)

## A session whose bots do not send, so a test controls every send.
func quiet(seed_value := 1):
	var s = S.new(seed_value)
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	return s

func events_of(s, type: int) -> Array:
	return s.events.filter(func(e): return e.type == type)

## The invariants of doc 47 B35-TARGET-001, for every contestant.
func targets_valid(s) -> bool:
	for c in s.contestants:
		if not c.alive:
			if c.target_id != -1:
				return false
		elif s.alive_count >= 2:
			if c.target_id < 0 or c.target_id == c.id or not s.contestants[c.target_id].alive:
				return false
		elif c.target_id != -1:
			return false
	return true

func attackers_recomputed(s, id: int) -> Array:
	var out := []
	for c in s.contestants:
		if c.alive and c.target_id == id:
			out.append(c.id)
	return out

# ------------------------------------------------------------------ initial targets

func test_initial_targets() -> void:
	var s = S.new(7)
	check(targets_valid(s) and s.alive_count == 35, "at the start every one of the 35 contestants holds a valid target (alive, not itself)")
	check(s.events.is_empty() and s.attacks.initial_targets.size() == 35, "...with no event: the first targets are state, recorded in initial_targets")
	var twin = S.new(7)
	check(twin.snapshot() == s.snapshot() and twin.attacks.initial_targets == s.attacks.initial_targets, "the same seed gives the same targets")
	var different := 0
	for seed_value in range(100, 140):
		if S.new(seed_value).attacks.initial_targets != s.attacks.initial_targets:
			different += 1
	check(different >= 38, "a different seed gives different ones (%d of 40)" % different)
	var fresh_player = RandomNumberGenerator.new()
	fresh_player.seed = 7 ^ SYS.PLAYER_SALT
	var fresh_bot = RandomNumberGenerator.new()
	fresh_bot.seed = 7 ^ SYS.BOT_SALT
	check(s.attacks.player_rng.state == fresh_player.state and s.attacks.bot_rng.state == fresh_bot.state, "choosing them drew nothing from either attack stream")
	var plain = S.new(7)
	var main_state: int = plain.rng.state
	S.default_attacks_enabled = false
	var off = S.new(7)
	S.default_attacks_enabled = true
	check(plain.rng.state == off.rng.state and main_state == off.rng.state, "...nor from the main simulation stream (its state equals an attack-free session's)")
	check(off.attacks.initial_targets.is_empty() and off.contestants.all(func(c): return c.target_id == -1) and off.attackers_of(0).is_empty(), "with the attack loop off nobody has a target")
	# roughly uniform: over many seeds, each other contestant is the player's first target about equally often
	var counts := {}
	for seed_value in 2000:
		var t: int = S.new(seed_value).attacks.initial_targets[0]
		counts[t] = int(counts.get(t, 0)) + 1
	var lo := 1 << 30
	var hi := 0
	for id in range(1, 35):
		lo = mini(lo, int(counts.get(id, 0)))
		hi = maxi(hi, int(counts.get(id, 0)))
	check(counts.size() == 34 and not counts.has(0) and lo > 30 and hi < 95, "the player's first target is spread over the 34 opponents (never itself): min %d, max %d of 2000 (mean 59)" % [lo, hi])
	check(TG.mix(5, 3) == TG.mix(5, 3) and TG.mix(5, 3) != TG.mix(5, 4) and TG.mix(-1, 0) >= 0 and TG.mix(1 << 40, 9) >= 0, "the hash is pure and non-negative")

# ------------------------------------------------------------------ Random: the target is the last recipient

func test_random_sends() -> void:
	var s = quiet(11)
	check(s.player_target_mode == M.RANDOM and s.target_of(0) == s.attacks.initial_targets[0], "the default mode is Random and the player starts on their first target")
	var first: int = s.target_of(0)
	var a0 = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(a0 != null and a0.target == s.target_of(0), "after a send the player's target is the recipient")
	var ev: Array = events_of(s, E.TARGET_CHANGED)
	check(ev.size() == (1 if a0.target != first else 0), "a TARGET_CHANGED is logged when the target moved, and only then")
	if ev.size() == 1:
		check(ev[0].id == 0 and ev[0].a == a0.target and ev[0].b == first and ev[0].tick == s.tick_count, "TARGET_CHANGED: contestant, new target, old target, tick")
	# the order of one send: ENEMY_DEFEATED, SENT, RECEIVED, then TARGET_CHANGED
	var seq: Array = s.events.map(func(e): return e.type)
	var i := seq.find(E.ENEMY_DEFEATED)
	check(seq.slice(i, i + 3) == [E.ENEMY_DEFEATED, E.SENT, E.RECEIVED], "a send's own events keep their order (ENEMY_DEFEATED, SENT, RECEIVED)")
	if ev.size() == 1:
		check(seq.find(E.TARGET_CHANGED) == i + 3, "...and TARGET_CHANGED follows RECEIVED")
	# between sends it stays
	var before: int = s.target_of(0)
	for t in 30:
		s.step()
	var ticks_kept: bool = s.target_of(0) == before or not s.contestants[before].alive
	check(ticks_kept, "between sends the target stays put (it moves only if it is KO'd)")
	# every send draws a fresh target: many different recipients, repeats allowed
	var t = quiet(12)
	var recipients := []
	for n in 400:
		var a = t.report_enemy_defeat(0, T.Kind.KOOPA)
		recipients.append(a.target)
		if a.target != t.target_of(0):
			recipients.append(-99)
	var distinct := {}
	var repeats := 0
	for n in recipients.size():
		distinct[recipients[n]] = true
		if n > 0 and recipients[n] == recipients[n - 1]:
			repeats += 1
	check(not distinct.has(-99) and distinct.size() >= 30 and not distinct.has(0), "over 400 sends the target is always the last recipient, and many different survivors are drawn (%d)" % distinct.size())
	check(repeats > 0, "the same target can be drawn twice in a row (%d repeats): Random allows repeats" % repeats)
	# bots too: a bot's target is the last recipient of its own send
	var b = quiet(13)
	var ba = b.report_enemy_defeat(9, T.Kind.GOOMBA)
	check(b.target_of(9) == ba.target, "a bot that sends aims at its recipient too")
	# a send that nobody can receive changes nothing
	var lonely = quiet(14)
	for id in range(2, 35):
		lonely.report_ko(id, K.HAZARD)
	check(lonely.alive_count == 2 and lonely.target_of(0) == 1 and lonely.target_of(1) == 0, "with two left each aims at the other")
	lonely.report_ko(1, K.HAZARD)
	check(lonely.finished and lonely.target_of(0) == -1 and lonely.attacks.round_ended, "when one is left nobody has a target")
	var tt = quiet(15)
	var pol = FixedPolicy.new()
	pol.target = 0 # the sender itself: refused
	tt.attacks.targeting = pol
	var kept: int = tt.target_of(0)
	check(tt.report_enemy_defeat(0, T.Kind.GOOMBA) == null and tt.target_of(0) == kept, "a refused send (a policy that names the sender) leaves the target alone")

func test_random_distribution() -> void:
	var s = quiet(21)
	var counts := {}
	var n := 10000
	for i in n:
		var a = s.report_enemy_defeat(0, T.Kind.GOOMBA)
		counts[a.target] = int(counts.get(a.target, 0)) + 1
	var expected := float(n) / 34.0
	var worst := 0.0
	for id in range(1, 35):
		worst = maxf(worst, absf(float(counts.get(id, 0)) - expected) / expected)
	var chi := 0.0
	for id in range(1, 35):
		chi += pow(float(counts.get(id, 0)) - expected, 2.0) / expected
	check(not counts.has(0) and counts.size() == 34, "10,000 seeded sends reach all 34 opponents and never the player")
	check(chi < 60.0 and worst < 0.3, "...uniformly within statistical tolerance (chi-square %.1f for 33 degrees of freedom, worst deviation %.0f%%)" % [chi, worst * 100.0])
	check(s.attacks.player_defeats == n and s.target_of(0) == s.attacks.history[n - 1].target, "(and the target equals the last recipient)")

# ------------------------------------------------------------------ KO re-targeting

func test_ko_retarget() -> void:
	var s = quiet(31)
	var a = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	var gone: int = s.target_of(0)
	var n_events: int = s.events.size()
	s.report_ko(gone, K.HAZARD)
	var now: int = s.target_of(0)
	check(now != gone and now >= 1 and s.contestants[now].alive and targets_valid(s), "when the player's target goes out the player re-targets in the same call (#%d -> #%d)" % [gone, now])
	var changes: Array = events_of(s, E.TARGET_CHANGED).slice(-4).filter(func(e): return e.id == 0 and e.b == gone)
	check(changes.size() == 1 and changes[0].a == now and changes[0].tick == s.tick_count, "...with one TARGET_CHANGED from the old to the new")
	check(now == (gone % 35) + 1 or now == 1 or now > gone, "the replacement is the next survivor after the one that went out (a sweep, no random draw)")
	check(s.contestants[gone].target_id == -1, "the contestant who went out holds no target")
	# everybody who aimed at the KO'd contestant moved on
	var t = quiet(32)
	var victim: int = t.target_of(0)
	var attackers_before: Array = t.attackers_of(victim)
	t.report_ko(victim, K.HAZARD)
	check(t.attackers_of(victim).is_empty() and targets_valid(t), "every contestant that aimed at it (%d) re-targeted on the same tick" % attackers_before.size())
	# a KO of several in one tick
	var g = quiet(33)
	var group: Array[BattleContestant] = []
	for id in range(1, 18):
		g.contestants[id].ko_cause = K.HAZARD
		group.append(g.contestants[id])
	g._apply_kos(group)
	check(g.alive_count == 18 and targets_valid(g), "17 contestants going out in one tick: every survivor's target is valid afterwards")
	# the sweep wraps around the end
	var w = quiet(34)
	for id in range(2, 35):
		w.report_ko(id, K.HAZARD)
	check(w.target_of(0) == 1 and w.target_of(1) == 0, "(the last two aim at each other)")
	var v = quiet(35)
	v.contestants[0].target_id = 34
	v.report_ko(34, K.HAZARD)
	check(v.target_of(0) == 1, "past the highest id the sweep wraps to the lowest")
	# the player going out
	var p = quiet(36)
	p.report_ko(0, K.HAZARD)
	check(p.target_of(0) == -1 and p.attackers_of(0).is_empty() and targets_valid(p), "when the player is KO'd they hold no target and nobody aims at them")
	# a refused send never leaves a stale target either
	var q = quiet(37)
	q.report_ko(q.target_of(0), K.HAZARD)
	check(targets_valid(q), "(valid after every KO)")

# ------------------------------------------------------------------ attackers_of

func test_attackers_of() -> void:
	var s = quiet(41)
	check(s.attackers_of(0) == attackers_recomputed(s, 0), "attackers_of(player) is exactly the survivors that aim at the player")
	# bots send: some now aim at the player
	var made := 0
	for sender in range(1, 35):
		var pol = FixedPolicy.new()
		pol.target = 0 if sender % 3 == 0 else 5
		s.attacks.targeting = pol
		if s.report_enemy_defeat(sender, T.Kind.GOOMBA) != null:
			made += 1
	var att: Array = s.attackers_of(0)
	check(att == attackers_recomputed(s, 0) and att.size() >= 10 and att == range(1, 35).filter(func(i): return i % 3 == 0 and i != 0), "bots that sent at the player aim at the player: %s" % str(att))
	var sorted_att := att.duplicate()
	sorted_att.sort()
	check(att == sorted_att, "ascending id order")
	s.report_ko(att[0], K.HAZARD)
	check(not s.attackers_of(0).has(att[0]) and s.attackers_of(0) == attackers_recomputed(s, 0), "a KO'd attacker leaves the list at once")
	# it is exact after every tick of whole matches
	var bad := 0
	for seed_value in 12:
		var t = S.new(300 + seed_value)
		for i in 400:
			if t.finished:
				break
			t.step()
			if t.attackers_of(0) != attackers_recomputed(t, 0) or t.attackers_of(7) != attackers_recomputed(t, 7):
				bad += 1
	check(bad == 0, "attackers_of is correct after every tick of 12 whole matches")
	check(s.attackers_of(0).all(func(id): return s.contestants[id].alive and s.contestants[id].target_id == 0), "(only living contestants that aim at it)")

# ------------------------------------------------------------------ Lowest Time

func test_lowest_time() -> void:
	var s = quiet(51)
	s.contestants[9].time_left = 100
	s.contestants[4].time_left = 250
	s.contestants[20].time_left = 80
	check(s.set_player_target_mode(M.LOWEST_TIME) and s.player_target_mode == M.LOWEST_TIME, "Lowest Time can be selected")
	check(s.target_of(0) == 20, "it aims at the survivor with the lowest time (#20, 80 s)")
	var ev: Array = events_of(s, E.TARGET_CHANGED)
	check(ev.size() >= 1 and ev[-1].id == 0 and ev[-1].a == 20, "selecting it re-targets at once, logged")
	var a = s.report_enemy_defeat(0, T.Kind.KOOPA)
	var b = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(a.target == 20 and b.target == 20 and s.target_of(0) == 20, "sends go to that target and do not change it")
	check(s.attacks.player_defeats == 2, "(each accepted send still takes one draw from the player stream)")
	# continuous: it follows the clock
	s.contestants[9].time_left = 10
	check(s.target_of(0) == 20, "(nothing moves between ticks)")
	s.step()
	check(s.target_of(0) == 9, "the next tick it follows a new lowest time (#9)")
	var tick_events: Array = events_of(s, E.TARGET_CHANGED).filter(func(e): return e.id == 0).slice(-1)
	check(tick_events[0].a == 9 and tick_events[0].b == 20, "...logged old to new")
	# ties go to the lower id
	var t = quiet(52)
	for id in range(1, 35):
		t.contestants[id].time_left = 77
	t.set_player_target_mode(M.LOWEST_TIME)
	check(t.target_of(0) == 1, "a tie goes to the lower id (all equal: #1)")
	t.contestants[5].time_left = 60
	t.contestants[3].time_left = 60
	t.step()
	check(t.target_of(0) == 3, "...among the tied lowest too (#3 over #5)")
	# the player's own time never counts; a KO of the target replaces it with the next lowest on the same tick
	t.contestants[0].time_left = 5
	t.step()
	check(t.target_of(0) == 3, "the player's own (lower) time never makes them their own target")
	t.report_ko(3, K.HAZARD)
	check(t.target_of(0) == 5, "when the lowest-time target is KO'd the next lowest takes over on the same tick (#5)")
	# stability when times do not change
	var u = quiet(53)
	u.set_player_target_mode(M.LOWEST_TIME)
	var held: int = u.target_of(0)
	var changes := 0
	for i in 20:
		u.report_enemy_defeat(0, T.Kind.GOOMBA)
		if u.target_of(0) != held:
			changes += 1
	check(changes == 0, "with times unchanged it keeps the same target across sends (the reticle does not wander)")
	# invalid never
	var v = quiet(54)
	v.set_player_target_mode(M.LOWEST_TIME)
	for id in range(2, 35):
		v.report_ko(id, K.HAZARD)
	check(v.target_of(0) == 1, "with one opponent left it is that opponent")

# ------------------------------------------------------------------ Attackers

func test_attackers_mode() -> void:
	var s = quiet(61)
	for id in range(1, 35):
		s.contestants[id].target_id = 5 # nobody aims at the player
	s.contestants[5].target_id = 6
	check(s.attackers_of(0).is_empty(), "(setup: nobody aims at the player)")
	var kept: int = s.target_of(0)
	check(s.set_player_target_mode(M.ATTACKERS) and s.player_target_mode == M.ATTACKERS, "Attackers can be selected")
	check(s.target_of(0) == kept and targets_valid(s), "with no attackers the target is left as it is (still valid): nothing is invented")
	s.step()
	check(s.target_of(0) == kept, "...and stays so through ticks")
	# the send falls back to Random and uses the draw
	var twin = quiet(61)
	for id in range(1, 35):
		twin.contestants[id].target_id = 5
	twin.contestants[5].target_id = 6
	twin.set_player_target_mode(M.ATTACKERS)
	var expected_draw := RandomNumberGenerator.new()
	expected_draw.seed = 61 ^ SYS.PLAYER_SALT
	var u: float = expected_draw.randf()
	var cands: Array = TG.eligible(twin, 0)
	var a = twin.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(a != null and a.target == cands[mini(int(u * cands.size()), cands.size() - 1)], "with no attackers a send falls back to Random: the player stream's draw picks the recipient")
	check(twin.target_of(0) == a.target and twin.attacks.player_defeats == 1, "...which becomes the target, with exactly one draw taken")
	# attackers appear: the lowest id wins, and it stays
	s.contestants[12].target_id = 0
	s.contestants[8].target_id = 0
	s.contestants[30].target_id = 0
	s.step()
	check(s.attackers_of(0) == [8, 12, 30] and s.target_of(0) == 8, "with attackers 8, 12 and 30 it aims at the lowest id (#8) at the end of the tick")
	s.contestants[8].target_id = 3 # #8 stops aiming at the player
	s.step()
	check(s.target_of(0) == 12, "when its attacker stops attacking, it moves to the next (#12)")
	s.contestants[8].target_id = 0
	s.step()
	check(s.target_of(0) == 12, "...and a new lower-id attacker does not pull it away: the current attacker is kept")
	var sent = s.report_enemy_defeat(0, T.Kind.KOOPA)
	check(sent.target == 12 and s.target_of(0) == 12, "sends go to the current attacker")
	s.report_ko(12, K.HAZARD)
	check(s.target_of(0) == 8 and s.attackers_of(0) == [8, 30], "when the attacker is KO'd the next attacker takes over on the same tick (#8)")
	# only ever an actual attacker, when there is one
	check(s.attackers_of(0).has(s.target_of(0)), "(the target is one of the contestants aiming at the player)")
	s.report_ko(8, K.HAZARD)
	s.report_ko(30, K.HAZARD)
	check(s.attackers_of(0).is_empty() and targets_valid(s), "when the last attacker goes the target stays valid")
	# in a whole match, whenever there are attackers at a tick's end the target is one of them
	var bad := 0
	var with_attackers := 0
	for seed_value in 10:
		var t = S.new(700 + seed_value)
		t.set_player_target_mode(M.ATTACKERS)
		for i in 300:
			if t.finished:
				break
			t.step()
			var att: Array = t.attackers_of(0)
			if not att.is_empty():
				with_attackers += 1
				if not att.has(t.target_of(0)):
					bad += 1
	check(bad == 0 and with_attackers > 200, "in 10 whole matches the target is an actual attacker whenever there is one (%d ticks with attackers)" % with_attackers)

# ------------------------------------------------------------------ Most Coins (deferred)

func test_most_coins() -> void:
	var s = quiet(71)
	var c = s.contestants[1]
	var has_coins := false
	for prop in c.get_property_list():
		if str(prop.name).to_lower().contains("coin"):
			has_coins = true
	check(not has_coins, "no coin state exists on a contestant: none was invented")
	check(not s.target_mode_available(M.MOST_COINS), "Most Coins is unavailable: there is no authoritative coin data yet")
	var kept: int = s.target_of(0)
	var n_events: int = s.events.size()
	check(not s.set_player_target_mode(M.MOST_COINS) and s.player_target_mode == M.RANDOM and s.target_of(0) == kept and s.events.size() == n_events, "selecting it is refused and changes nothing (mode, target, log)")
	check(s.target_mode_available(M.RANDOM) and s.target_mode_available(M.LOWEST_TIME) and s.target_mode_available(M.ATTACKERS), "(the other three are available)")
	# the strategy itself is complete: with a coin source it picks the richest survivor, ties to the lower id
	var router = s.attacks.targeting
	var coins := {3: 5, 9: 40, 14: 40, 20: 12}
	router.most_coins.coin_source = func(contestant): return int(coins.get(contestant.id, 0))
	check(s.target_mode_available(M.MOST_COINS) and router.most_coins.available(), "a coin source makes the strategy available (the later coin milestone supplies it)")
	check(s.set_player_target_mode(M.MOST_COINS) and s.target_of(0) == 9, "with coins 3:5, 9:40, 14:40, 20:12 it aims at the richest, ties to the lower id (#9)")
	coins[14] = 41
	s.step()
	check(s.target_of(0) == 14, "it follows the coins each tick (#14)")
	var a = s.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(a.target == 14 and s.target_of(0) == 14, "and sends go to it")
	coins[0] = 999 # the player's own coins never count
	s.step()
	check(s.target_of(0) == 14, "the player's own coins never make them their own target")
	s.report_ko(14, K.HAZARD)
	check(s.target_of(0) == 9, "a KO'd richest target is replaced on the same tick (#9)")
	router.most_coins.coin_source = Callable()
	check(not router.most_coins.available() and not s.target_mode_available(M.MOST_COINS), "without the source it is unavailable again")
	s.step()
	check(targets_valid(s), "(a mode whose data vanished leaves the target valid)")

# ------------------------------------------------------------------ the mode API

func test_mode_api() -> void:
	var s = quiet(81)
	check(s.player_target_mode == M.RANDOM, "every round starts in Random")
	check(not s.set_player_target_mode(-1) and not s.set_player_target_mode(4) and not s.set_player_target_mode(99), "an unknown mode is refused")
	check(s.set_player_target_mode(M.RANDOM) and s.player_target_mode == M.RANDOM, "selecting the current mode is a harmless yes")
	var n_events: int = s.events.size()
	var tgt: int = s.target_of(0)
	s.set_player_target_mode(M.RANDOM)
	check(s.events.size() == n_events and s.target_of(0) == tgt, "...that changes nothing")
	s.set_player_target_mode(M.ATTACKERS)
	check(s.player_target_mode == M.ATTACKERS, "the mode changes during the round")
	for i in 50:
		s.step()
	check(s.player_target_mode == M.ATTACKERS, "...and survives ticks")
	s.report_ko(s.target_of(0), K.HAZARD)
	check(s.player_target_mode == M.ATTACKERS, "...and KOs")
	# a new round starts from the default
	S.begin(82)
	check(S.current.player_target_mode == M.RANDOM and S.current != s, "a new round is a new session: the mode is Random again, nothing carries over")
	S.clear()
	# refused when it cannot matter
	var dead = quiet(83)
	dead.report_ko(0, K.HAZARD)
	check(not dead.set_player_target_mode(M.LOWEST_TIME) and dead.player_target_mode == M.RANDOM, "a player who is out cannot change mode")
	var done = quiet(84)
	for id in range(1, 35):
		done.report_ko(id, K.HAZARD)
	check(done.finished and not done.set_player_target_mode(M.LOWEST_TIME), "nor once the round is over")
	S.default_attacks_enabled = false
	var off = S.new(85)
	S.default_attacks_enabled = true
	check(not off.set_player_target_mode(M.LOWEST_TIME) and off.target_of(0) == -1, "nor in a round without the attack loop")
	# the mode names
	check(TG.mode_name(M.LOWEST_TIME) == "LOWEST_TIME" and TG.mode_name(M.ATTACKERS) == "ATTACKERS" and TG.mode_name(9) == "?", "modes have readable names")
	# a custom policy (what tests and later features use) routes every send and keeps working
	var f = quiet(86)
	var pol = FixedPolicy.new()
	pol.target = 9
	f.attacks.targeting = pol
	var fa = f.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(fa.target == 9 and f.target_of(0) == 9 and not f.target_mode_available(M.LOWEST_TIME) and f.target_mode_available(M.RANDOM), "a custom policy still routes every send, and the modes it does not offer are unavailable")

func test_modes_change_future_sends_only() -> void:
	var s = quiet(91)
	for id in range(1, 35):
		s.contestants[id].time_left = 500
	s.contestants[27].time_left = 30
	var before := []
	for i in 5:
		before.append(s.report_enemy_defeat(0, T.Kind.GOOMBA))
	var history_before: Array = s.attacks.attack_history().duplicate(true)
	var counts_before := [s.attacks.history.size(), s.attacks.next_seq, s.attacks.defeats, s.attacks.player_defeats]
	s.set_player_target_mode(M.LOWEST_TIME)
	check(s.attacks.attack_history() == history_before, "changing the mode does not touch attacks already made (targets, kinds, states)")
	var after := []
	for i in 5:
		after.append(s.report_enemy_defeat(0, T.Kind.KOOPA))
	check(after.all(func(a): return a.target == 27), "every later send goes to the new mode's target (#27)")
	check(counts_before == [5, 5, 5, 5] and s.attacks.history.size() == 10 and s.attacks.next_seq == 10 and s.attacks.defeats == 10, "what counts as a send, and the counts, are unchanged by the mode")
	check(s.attacks.history.slice(0, 5).all(func(a): return a.state == A.State.QUEUED) and after.all(func(a): return a.kind == T.Kind.KOOPA), "queue state and enemy kinds are untouched")
	s.set_player_target_mode(M.RANDOM)
	var again := []
	for i in 30:
		again.append(s.report_enemy_defeat(0, T.Kind.GOOMBA).target)
	var distinct := {}
	for t in again:
		distinct[t] = true
	check(distinct.size() > 10, "back in Random the sends spread out again (%d distinct recipients in 30)" % distinct.size())
	# activation, pressure and the rest of the loop do not depend on the mode
	var x = quiet(92)
	var y = quiet(92)
	y.set_player_target_mode(M.LOWEST_TIME)
	x.report_enemy_defeat(3, T.Kind.GOOMBA)
	y.report_enemy_defeat(3, T.Kind.GOOMBA)
	for i in 10:
		x.step()
		y.step()
	check(x.attacks.attack_history() == y.attacks.attack_history() and x.get_incoming(0) == y.get_incoming(0), "queues, activation and expiry are the same in any mode")

# ------------------------------------------------------------------ the random streams

func test_streams_and_bots() -> void:
	# the player stream: exactly one draw per accepted player send, in every mode
	var counts_ok := true
	for mode in [M.RANDOM, M.LOWEST_TIME, M.ATTACKERS]:
		var s = S.new(101)
		s.attacks.bots_send = false
		s.set_player_target_mode(mode)
		var probe := RandomNumberGenerator.new()
		probe.seed = 101 ^ SYS.PLAYER_SALT
		var sends := 0
		for tick in 60:
			if tick % 4 == 0 and s.get_player().alive:
				s.report_enemy_defeat(0, T.Kind.GOOMBA)
				sends += 1
				probe.randf()
			s.step()
			if s.attacks.player_rng.state != probe.state:
				counts_ok = false
		if s.attacks.player_defeats != sends:
			counts_ok = false
	check(counts_ok, "the player stream advances exactly once per accepted player send in Random, Lowest Time and Attackers (and by nothing else)")
	var probe_pl := RandomNumberGenerator.new()
	var s2 = S.new(102)
	s2.attacks.bots_send = false
	for i in 3:
		s2.report_enemy_defeat(0, T.Kind.GOOMBA)
	for id in range(1, 35):
		if s2.alive_count > 2:
			s2.report_ko(id, K.HAZARD)
	probe_pl.seed = 102 ^ SYS.PLAYER_SALT
	for i in 3:
		probe_pl.randf()
	check(s2.attacks.player_rng.state == probe_pl.state, "KOs, re-targeting and mode changes draw nothing from the player stream")
	# the bot stream: exactly DRAWS_PER_BOT x 34 per tick, targets or not
	var bot_ok := true
	var s3 = S.new(103)
	s3.set_player_target_mode(M.ATTACKERS)
	var bprobe := RandomNumberGenerator.new()
	bprobe.seed = 103 ^ SYS.BOT_SALT
	var ticks := 0
	for i in 200:
		if s3.finished:
			break
		s3.step()
		ticks += 1
		for d in SYS.DRAWS_PER_BOT * 34:
			bprobe.randf()
		if s3.attacks.bot_rng.state != bprobe.state:
			bot_ok = false
	check(bot_ok and ticks > 100, "the bot stream advances exactly %d x 34 draws per tick, however many bots send, retarget or go out (%d ticks)" % [SYS.DRAWS_PER_BOT, ticks])
	# changing the player's mode (or sends) never perturbs the bots: their attacks are identical
	var plain = S.new(104)
	var moded = S.new(104)
	for sess in [plain, moded]:
		sess.attacks.pressure_enabled = false
	for tick in 150:
		if tick % 10 == 3:
			moded.set_player_target_mode([M.LOWEST_TIME, M.ATTACKERS, M.RANDOM][(tick / 10) % 3])
		plain.step()
		moded.step()
	var bots_a: Array = plain.attacks.attack_history().filter(func(d): return d.sender != 0).map(func(d): return [d.sender, d.target, d.kind, d.sent_tick])
	var bots_b: Array = moded.attacks.attack_history().filter(func(d): return d.sender != 0).map(func(d): return [d.sender, d.target, d.kind, d.sent_tick])
	check(bots_a.size() > 20 and bots_a == bots_b, "the player's mode never changes what the bots send, to whom or when (%d bot attacks identical)" % bots_a.size())
	check(plain.attacks.bot_rng.state == moded.attacks.bot_rng.state and plain.rng.state == moded.rng.state, "...nor the bot stream or the main simulation stream")
	# bots always use Random: no bot ever aims by time, coins or attackers
	var bot_targets_ok := true
	for id in range(1, 35):
		if moded.contestants[id].alive and not TG.is_valid_target(moded, id, moded.target_of(id)):
			bot_targets_ok = false
	check(bot_targets_ok, "(every bot's target is valid)")

# ------------------------------------------------------------------ whole matches

func test_whole_matches() -> void:
	var invalid := 0
	var attacker_bad := 0
	var recipients_bad := 0
	var matches := 0
	var steps := 0
	var modes := [M.RANDOM, M.LOWEST_TIME, M.ATTACKERS, M.RANDOM]
	for seed_value in 200:
		var s = S.new(1000 + seed_value)
		matches += 1
		for tick in 600:
			if s.finished:
				break
			if tick % 6 == 1 and s.get_player().alive:
				var a = s.report_enemy_defeat(0, T.Kind.GOOMBA if tick % 12 == 1 else T.Kind.KOOPA)
				if a != null and (a.target == 0 or not s.contestants[a.target].alive or s.target_of(0) != a.target and s.player_target_mode == M.RANDOM):
					recipients_bad += 1
			if tick % 40 == 5:
				s.set_player_target_mode(modes[(tick / 40) % modes.size()])
			s.step()
			steps += 1
			if not targets_valid(s):
				invalid += 1
			if s.player_target_mode == M.ATTACKERS and s.get_player().alive:
				var att: Array = s.attackers_of(0)
				if not att.is_empty() and not att.has(s.target_of(0)):
					attacker_bad += 1
	check(invalid == 0, "200 whole matches (%d ticks, every mode): no target was ever invalid (self, eliminated, or -1 while two or more were in)" % steps)
	check(recipients_bad == 0, "no send ever went to the player, to an eliminated contestant, or (in Random) somewhere other than the new target")
	check(attacker_bad == 0, "Attackers never aimed at a non-attacker while one existed")

func test_determinism() -> void:
	var a = S.new(2001)
	var b = S.new(2001)
	for tick in 220:
		if tick % 5 == 2:
			a.report_enemy_defeat(0, T.Kind.GOOMBA)
			b.report_enemy_defeat(0, T.Kind.GOOMBA)
		if tick % 37 == 4:
			var m: int = [M.LOWEST_TIME, M.ATTACKERS, M.RANDOM][(tick / 37) % 3]
			a.set_player_target_mode(m)
			b.set_player_target_mode(m)
		a.step()
		b.step()
	check(a.snapshot() == b.snapshot() and a.events == b.events, "twin sessions with the same seed, sends and mode changes are identical (state, targets and event log)")
	var c = S.new(2001)
	for tick in 220:
		if tick % 5 == 2:
			c.report_enemy_defeat(0, T.Kind.GOOMBA)
		c.step()
	check(c.snapshot() != a.snapshot(), "(and a different mode history gives a different one)")

# ------------------------------------------------------------------ presentation

func test_presentation_target() -> void:
	var s = quiet(3001)
	var view = PRES.new(s)
	check(view.player_target == s.target_of(0) and view.target_of(5) == s.target_of(5), "a presentation starts on the session's targets")
	s.report_enemy_defeat(0, T.Kind.GOOMBA)
	check(view.player_target != s.target_of(0) or s.attacks.history[0].target == s.attacks.initial_targets[0], "(it has not read the new event yet)")
	view.update(0.016)
	check(view.player_target == s.target_of(0) and view.target_of(0) == s.target_of(0), "after update() the reticle's target is the session's")
	s.report_ko(s.target_of(0), K.HAZARD)
	view.update(0.016)
	check(view.player_target == s.target_of(0) and view.player_target > 0, "it follows a KO re-target")
	# a presentation made mid-round replays the history
	for i in 40:
		s.report_enemy_defeat(0, T.Kind.KOOPA)
	s.step()
	var late = PRES.new(s)
	check(late.player_target == s.target_of(0) and late.target_of(11) == s.target_of(11), "one created mid-round shows the current targets (initial targets plus the logged changes)")
	for tick in 120:
		s.step()
		view.update(0.0) # a held presentation still reads events
		if view.player_target != s.target_of(0):
			check(false, "the presentation fell behind at tick %d" % tick)
			break
	check(view.player_target == s.target_of(0), "it stays on the session's target through a match")
	# the trace (attack replay hashes) does not see targets
	var t1 = quiet(3002)
	var v1 = PRES.new(t1)
	v1.keep_trace = true
	t1.report_enemy_defeat(0, T.Kind.GOOMBA)
	v1.update(0.0)
	check(v1.trace_count == 2 and v1.trace.size() == 2, "attack traces still count only attack events (SENT and RECEIVED of one send, not its target change)")

func test_event_numbering() -> void:
	check(E.HIT == 0 and E.KO == 3 and E.ENEMY_DEFEATED == 4 and E.INCOMING_ACTIVATED == 7 and E.INCOMING_RESOLVED == 8 and E.INCOMING_SPAWNED == 9, "existing event types keep their numbers")
	check(E.TARGET_CHANGED == 10 and E.keys().size() == 11, "TARGET_CHANGED is appended after them")
