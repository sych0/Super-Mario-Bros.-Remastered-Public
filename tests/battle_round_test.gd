extends SceneTree
## Pure checks of the Battle round state machine (BattleRound): no scene tree, no session, no input.
## The same lifecycle against the real game is in tests/battle_round_lifecycle_test.gd.
##   godot --headless --path . -s tests/battle_round_test.gd

var failures := 0
var R

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func _initialize() -> void:
	R = load("res://Scripts/Classes/Battle/BattleRound.gd")
	R.pre_round_override = -1.0
	test_states_and_banner()
	test_no_preround()
	test_end_conditions()
	test_duplicates_and_guards()
	test_results_lockout_and_restart()
	test_many_rounds()
	test_override()
	if failures > 0:
		printerr("%d Battle round test(s) failed" % failures)
	else:
		print("All Battle round tests passed")
	quit(1 if failures > 0 else 0)

func new_round():
	var r = R.new()
	r.begin_round()
	return r

func test_states_and_banner() -> void:
	var r = new_round()
	check(r.state == R.State.LOADING and r.round_number == 1 and r.end_cause == R.End.NONE, "a new round starts LOADING as round 1")
	check(r.banner_text() == "" and not r.frozen(), "nothing is shown or frozen while loading")
	check(r.level_ready() and r.state == R.State.PRE_ROUND, "the first level being ready starts the pre-round")
	check(r.frozen() and r.banner_text() == "READY", "the pre-round freezes the game and shows READY")
	check(not r.level_ready(), "level_ready is ignored outside LOADING (a later level of the round does not restart it)")
	r.update(R.PRE_ROUND_SECONDS - 0.1)
	check(r.state == R.State.PRE_ROUND and r.frozen(), "still frozen just before the pre-round ends")
	var changed: bool = r.update(0.2)
	check(changed and r.state == R.State.PLAYING and not r.frozen(), "the pre-round releases into PLAYING")
	check(r.banner_text() == "GO!", "GO! shows as play is released")
	r.update(R.GO_SECONDS)
	check(r.banner_text() == "", "GO! goes away again")
	check(r.history == [R.State.LOADING, R.State.PRE_ROUND, R.State.PLAYING], "history is LOADING, PRE_ROUND, PLAYING")

func test_no_preround() -> void:
	R.pre_round_override = 0.0
	var r = new_round()
	check(r.level_ready() and r.state == R.State.PLAYING and not r.frozen() and r.banner_text() == "", "a pre-round of 0 plays at once, with no freeze or banner")
	R.pre_round_override = -1.0

func test_end_conditions() -> void:
	for cause in [R.End.DEATH, R.End.TIMEOUT]:
		var r = new_round()
		r.level_ready()
		r.update(10.0)
		check(r.end_round(cause) and r.state == R.State.ROUND_OVER and r.end_cause == cause, "a %s ends the round" % R.End.keys()[cause])
		r.update(5.0)
		check(r.state == R.State.ROUND_OVER, "...and waits for the death sequence (it does not skip it)")
		check(r.death_finished() and r.state == R.State.RESULTS, "...then the results come up")
	var w = new_round()
	w.level_ready()
	w.update(10.0)
	check(w.end_round(R.End.WIN) and w.state == R.State.ROUND_OVER and w.end_cause == R.End.WIN, "a win ends the round")
	check(not w.death_finished(), "a win has no death sequence to finish")
	w.update(R.WIN_HOLD_SECONDS - 0.1)
	check(w.state == R.State.ROUND_OVER, "a win holds for a moment")
	w.update(0.2)
	check(w.state == R.State.RESULTS, "...then the results come up")
	var s = new_round()
	s.level_ready()
	s.update(10.0)
	s.end_round(R.End.DEATH)
	s.update(R.ROUND_OVER_MAX_SECONDS + 0.1)
	check(s.state == R.State.RESULTS, "a death sequence that never reports still reaches the results (safety timeout)")

func test_duplicates_and_guards() -> void:
	var r = new_round()
	check(not r.end_round(R.End.DEATH), "a round cannot end while LOADING")
	r.level_ready()
	check(not r.end_round(R.End.DEATH), "a round cannot end during the pre-round")
	r.update(10.0)
	check(not r.end_round(R.End.NONE), "ending with no cause is ignored")
	check(r.end_round(R.End.DEATH), "the round ends once")
	check(not r.end_round(R.End.DEATH) and not r.end_round(R.End.TIMEOUT) and not r.end_round(R.End.WIN), "a second end report (duplicate KO, late timeout, a win) is ignored")
	check(r.end_cause == R.End.DEATH and r.history.count(R.State.ROUND_OVER) == 1, "the first cause stands and ROUND_OVER was entered once")
	r.death_finished()
	check(not r.death_finished() and not r.end_round(R.End.WIN), "nothing but the results' dismissal moves a finished round on")

func test_results_lockout_and_restart() -> void:
	var r = new_round()
	r.level_ready()
	r.update(10.0)
	r.end_round(R.End.DEATH)
	r.death_finished()
	var restarts := [0]
	r.state_changed.connect(func(_from, to): restarts[0] += 1 if to == R.State.LOADING else 0)
	r.update(R.RESULTS_MIN_SECONDS * 0.5, true)
	check(r.state == R.State.RESULTS and not r.results_dismissed(true), "confirm during the lockout is ignored")
	r.update(R.RESULTS_MIN_SECONDS * 0.4, true)
	check(r.state == R.State.RESULTS, "...still ignored just before the lockout ends")
	r.update(R.RESULTS_MIN_SECONDS * 0.2, false)
	check(r.state == R.State.RESULTS and r.results_dismissed(true) and not r.results_dismissed(false), "after the lockout confirm is accepted, and without it the results stay")
	check(r.update(0.1, true) and r.state == R.State.LOADING and r.round_number == 2, "confirm after the lockout starts the next round (LOADING, round 2)")
	check(restarts[0] == 1 and r.end_cause == R.End.NONE and r.history.back() == R.State.LOADING, "the next round was announced once and its end cause is cleared")
	# no confirm: the timeout advances on its own
	var t = new_round()
	t.level_ready()
	t.update(10.0)
	t.end_round(R.End.TIMEOUT)
	t.death_finished()
	t.update(R.RESULTS_MAX_SECONDS - 0.5, false)
	check(t.state == R.State.RESULTS, "without confirm the results wait")
	t.update(0.6, false)
	check(t.state == R.State.LOADING and t.round_number == 2, "the results advance by themselves at the timeout, to the next round")
	check(not t.history.has(99) and t.history.count(R.State.RESULTS) == 1, "the next round never re-enters a state it was not in")

func test_many_rounds() -> void:
	var r = new_round()
	for i in 5:
		r.level_ready()
		r.update(R.PRE_ROUND_SECONDS + 0.1)
		r.end_round([R.End.DEATH, R.End.TIMEOUT, R.End.WIN][i % 3])
		r.update(R.ROUND_OVER_MAX_SECONDS + 0.1) # death sequence or win hold: results by the safety timeout at the latest
		r.update(R.RESULTS_MAX_SECONDS + 0.1)
	check(r.round_number == 6 and r.state == R.State.LOADING, "five rounds in a row end on the sixth, LOADING")
	check(r.history.count(R.State.PRE_ROUND) == 5 and r.history.count(R.State.RESULTS) == 5 and r.history.count(R.State.LOADING) == 6, "each round went LOADING, PRE_ROUND, PLAYING, ROUND_OVER, RESULTS once")

func test_override() -> void:
	R.pre_round_override = 0.25
	var r = new_round()
	check(is_equal_approx(r.pre_round_seconds, 0.25) and R.default_pre_round_seconds() == 0.25, "the test hook shortens the pre-round")
	R.pre_round_override = -1.0
	check(R.default_pre_round_seconds() == R.PRE_ROUND_SECONDS or OS.is_debug_build(), "the default pre-round is %.1f s" % R.PRE_ROUND_SECONDS)
