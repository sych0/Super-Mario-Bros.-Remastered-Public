extends SceneTree
## Headless tests for the pure Battle layer.
## Run: godot --headless --path . -s tests/battle_session_test.gd

var failures := 0

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func _init() -> void:
	test_init()
	test_determinism()
	test_reaches_single_winner()
	test_player_ko_resolution()
	test_ko_ordering_and_ties()
	test_no_state_inheritance()
	test_save_isolation()
	if failures > 0:
		printerr("%d Battle test(s) failed" % failures)
	else:
		print("All Battle tests passed")
	quit(1 if failures > 0 else 0)

func snapshot(s: BattleSession) -> Array:
	return [s.tick_count, s.winner_id, s.get_ranking()]

func test_init() -> void:
	var s := BattleSession.new(1)
	check(s.contestants.size() == 35, "35 contestants")
	check(not s.contestants[0].is_bot, "contestant 0 is the real player")
	var bots := 0
	for i in range(1, 35):
		if s.contestants[i].is_bot:
			bots += 1
	check(bots == 34, "contestants 1-34 are bots")
	var ranks := {}
	for c in s.contestants:
		ranks[c.tiebreak] = true
	check(ranks.size() == 35, "tiebreak values are unique")

func test_determinism() -> void:
	var a := BattleSession.new(42)
	var b := BattleSession.new(42)
	var c := BattleSession.new(43)
	a.resolve_to_end()
	b.resolve_to_end()
	c.resolve_to_end()
	check(snapshot(a) == snapshot(b), "identical seeds give identical results")
	check(snapshot(a) != snapshot(c), "different seeds differ")

func test_reaches_single_winner() -> void:
	var ok := true
	var ticks := []
	for seed_value in 200:
		var s := BattleSession.new(seed_value)
		s.resolve_to_end()
		var winners := 0
		var places := {}
		for c in s.contestants:
			places[c.placement] = true
			if c.placement == 1:
				winners += 1
		if not (s.finished and winners == 1 and places.size() == 35 and s.contestants[s.winner_id].placement == 1):
			ok = false
		ticks.append(s.tick_count)
	ticks.sort()
	print("match length ticks: min %d median %d max %d" % [ticks[0], ticks[100], ticks[199]])
	check(ok, "200 seeds each end with one winner and placements 1..35")
	check(ticks[199] < 20000, "matches end before the safety cap")

func test_player_ko_resolution() -> void:
	var a := BattleSession.new(7)
	for i in 30:
		a.step()
	a.report_ko(0, BattleSession.KoCause.HAZARD)
	var placement := a.get_player().placement
	check(placement == a.alive_count + 1 + 0 or placement > 1, "player gets placement on KO")
	a.resolve_to_end()
	var b := BattleSession.new(7)
	for i in 30:
		b.step()
	b.report_ko(0, BattleSession.KoCause.HAZARD)
	b.resolve_to_end()
	check(a.finished and snapshot(a) == snapshot(b), "same seed + player outcome reproduces ranking")
	check(a.get_player().alive == false and a.get_player().placement == placement, "player placement stays stable after resolution")

func test_ko_ordering_and_ties() -> void:
	var s := BattleSession.new(5)
	var p := s.contestants[0]
	var q := s.contestants[1]
	var r := s.contestants[2]
	# Identical on levels/progress: only the seeded tiebreak decides, never the id.
	for c in [p, q, r]:
		c.levels_cleared = 2
		c.progress = 0.5
	p.tiebreak = 0
	q.tiebreak = 1
	r.tiebreak = 2
	s._apply_kos([p, q, r] as Array[BattleContestant])
	check(r.placement < q.placement and q.placement < p.placement, "exact ties follow the seeded tiebreak")
	check(p.placement == 35 and r.placement == 33, "tied group takes the lowest placements")
	var s2 := BattleSession.new(5)
	var p2 := s2.contestants[0]
	var q2 := s2.contestants[1]
	p2.tiebreak = 100
	q2.tiebreak = -1
	s2._apply_kos([p2, q2] as Array[BattleContestant])
	check(p2.placement < q2.placement, "player does not lose a tie by being slot 0, nor win by it")
	# More progress beats a better tiebreak.
	var s3 := BattleSession.new(5)
	var a3 := s3.contestants[3]
	var b3 := s3.contestants[4]
	a3.levels_cleared = 1
	b3.levels_cleared = 0
	a3.tiebreak = 0
	b3.tiebreak = 34
	s3._apply_kos([a3, b3] as Array[BattleContestant])
	check(a3.placement < b3.placement, "levels cleared outrank tiebreak")
	# Earlier KO always places below a later KO.
	var s4 := BattleSession.new(9)
	s4.report_ko(10, BattleSession.KoCause.HAZARD)
	s4.step()
	s4.report_ko(11, BattleSession.KoCause.HAZARD)
	check(s4.contestants[10].placement == 35 and s4.contestants[11].placement == 34, "KO order sets placement")

func test_no_state_inheritance() -> void:
	var first := BattleSession.begin(11)
	first.report_ko(0, BattleSession.KoCause.FORFEIT)
	first.resolve_to_end()
	var second := BattleSession.begin(11)
	check(second != first and BattleSession.current == second, "begin makes a new current session")
	check(second.alive_count == 35 and second.tick_count == 0 and not second.finished and second.get_player().alive, "new session starts fresh")
	check(second.get_player().placement == 0 and second.get_player().levels_cleared == 0, "new session has no leftover placements")
	BattleSession.clear()
	check(BattleSession.current == null, "clear drops the session")

func test_save_isolation() -> void:
	# Static check of the guard: SaveManager.write_save must bail out for BATTLE before touching any file.
	var src := FileAccess.get_file_as_string("res://Scripts/Classes/Singletons/SaveManager.gd")
	var fn := src.find("func write_save(")
	var guard := src.find("GameMode.BATTLE", fn)
	var first_io := src.find("FileAccess.file_exists", fn)
	check(fn >= 0 and guard > fn and guard < first_io, "write_save returns for BATTLE before any file access")
