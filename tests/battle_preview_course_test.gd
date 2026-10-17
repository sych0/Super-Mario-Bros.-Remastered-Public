extends SceneTree
## Headless checks for the opponent previews' course transitions (doc 55): a preview that clears its course moves on to the next one
## instead of ending in the placeholder. Needs the imported project (autoloads, real level scenes, real art).
##   - BattlePreviewStages: which level stands for each course (pure rule + real levels), built lazily, never a dead end
##   - the walk audit: every level the previews are allowed to show is walked cleanly, start to flagpole
##   - the track: flagpole, hold, three dark steps, cut to the next course; nothing of the last level is left; KO and pending outcomes safe
##   - the driver and the screen: a whole match never leaves a pane in limbo; the results freeze never holds a black pane
## Run: godot --headless --fixed-fps 60 --path . -s tests/battle_preview_course_test.gd

var failures := 0
var S # BattleSession
var D # BattlePreviewDriver
var T # BattlePreviewTrack
var K # BattleLevelSketch
var A # BattlePreviewAssets
var C # BattleCourse
var ST # BattlePreviewStages

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
	await frames(5)
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	D = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	T = load("res://Scripts/Classes/Battle/BattlePreviewTrack.gd")
	K = load("res://Scripts/Classes/Battle/BattleLevelSketch.gd")
	A = load("res://Scripts/Classes/Battle/BattlePreviewAssets.gd")
	C = load("res://Scripts/Classes/Battle/BattleCourse.gd")
	ST = load("res://Scripts/Classes/Battle/BattlePreviewStages.gd")
	S.default_attacks_enabled = false
	test_geometry_rule()
	test_stages()
	test_walk_audit()
	test_transition()
	test_two_clears_in_a_row()
	test_no_stale_state()
	test_ko_and_pending()
	test_settle()
	test_no_stages_and_last_course()
	test_driver_matches()
	test_determinism()
	await test_screen()
	S.default_attacks_enabled = true
	if failures > 0:
		printerr("%d Battle preview course test(s) failed" % failures)
	else:
		print("All Battle preview course tests passed")
	quit(1 if failures > 0 else 0)

# ------------------------------------------------------------------ helpers

func make_track(seed_value := 7, with_stages := true):
	var st = ST.new()
	var first: Dictionary = st.stage(0)
	var tr = T.new(1, first.sketch, first.assets, seed_value, 117.0, 0, st if with_stages else null)
	return tr

## Feeds a track the authoritative state of a bot that clears course `from_course` at `clear_tick` (progress rising linearly to it) and
## carries on in the next course; `extra` maps a tick to events logged on it.
func feed_run(tr, clear_tick: int, total_ticks: int, extra := {}, power := 0, from_course := 0) -> void:
	for tick in range(total_ticks + 1):
		var after: bool = tick >= clear_tick
		var p := float(tick - clear_tick) / 120.0 if after else float(tick) / float(clear_tick)
		var ev: Array = []
		if tick == clear_tick:
			ev.append({"type": S.EventType.LEVEL_CLEAR, "id": 1, "tick": tick, "a": from_course + 1})
		if extra.has(tick):
			ev.append_array(extra[tick])
		tr.push(tick, from_course + (1 if after else 0), p, power, true, ev)

# ------------------------------------------------------------------ the stand-in rule (pure)

func test_geometry_rule() -> void:
	print("-- which level stands for a course")
	var list := [0, 9, 12, 17, 24]
	var ok_self := true
	for c in list:
		ok_self = ok_self and ST.geometry_for(c, list) == c
	check(ok_self, "a course the previews can walk is shown as itself")
	var seq := []
	for c in 14:
		seq.append(ST.geometry_for(c, list))
	var no_repeat := true
	for i in range(1, seq.size()):
		no_repeat = no_repeat and seq[i] != seq[i - 1]
	check(no_repeat, "no two consecutive courses show the same level (%s)" % [seq])
	check(seq[0] == 0 and seq[1] == 9 and seq[2] == 12 and seq[3] == 17 and seq[4] == 24, "an unreadable course takes the next level in the cycle after the one just left (%s)" % [seq.slice(0, 5)])
	var rule_ok := true
	for lst in [list, [0, 9], [9, 12, 17], [0, 24], [12, 17, 24]]:
		for c in range(1, C.COURSE_COUNT):
			var g: int = ST.geometry_for(c, lst)
			var shown_before: int = ST.geometry_for(c - 1, lst)
			var own: bool = lst.has(c)
			if not own and (g == shown_before and lst.size() > 1):
				rule_ok = false # (an unreadable course repeats the level just left)
			if not own and lst.has(c + 1) and g == c + 1 and lst.size() > 2:
				rule_ok = false # (...or shows the level the next course will show as itself)
	check(rule_ok, "for every course and several lists: a stand-in is never the level just left, nor the next course's own level (when there is a choice)")
	check(ST.geometry_for(3, list) == ST.geometry_for(3, list, {}), "the rule is pure")
	check(ST.geometry_for(1, list, {9: true}) == 12 and ST.geometry_for(9, list, {9: true}) != 9, "a level that failed to build is never chosen, even for its own course")
	check(ST.geometry_for(1, [], {}) == -1 and ST.geometry_for(-1, list) == -1 and ST.geometry_for(32, list) == -1, "no level at all, or a course outside 0..31, gives -1")
	check(ST.geometry_for(5, [0]) == 0 and ST.geometry_for(1, [0]) == 0, "with one level to show, it is shown")
	var all_ok := true
	for c in C.COURSE_COUNT:
		all_ok = all_ok and ST.SKETCHED.has(ST.geometry_for(c, ST.SKETCHED))
	check(all_ok, "every one of the 32 courses has a level to show")

# ------------------------------------------------------------------ the real levels

func test_stages() -> void:
	print("-- the stages, built from the real levels")
	var st = ST.new()
	var first: Dictionary = st.stage(0)
	check(not first.is_empty() and first.course == 0 and first.geometry == 0 and not first.stand_in and first.sketch.scene_path == C.scene_path(0), "course 0 is World 1-1 itself")
	check(first.assets != null and first.assets.sky_color.a == 1.0, "...with its art baked")
	check(st.stage(0) == first, "a stage is built once")
	var before: bool = st.is_built(1)
	st.prefetch(1)
	var second: Dictionary = st.stage(1)
	check(not before and st.is_built(1) and second.stand_in and second.course == 1 and second.geometry != 1 and second.geometry != 0, "course 1 (1-2, not walkable) is a stand-in level that is not 1-1 (geometry %d)" % second.geometry)
	check(second.sketch != null and second.assets != null and second.sketch.scene_path == C.scene_path(second.geometry), "...with its own level and art")
	st.prefetch(1)
	check(st.stage(1) == second, "prefetch of a built stage does nothing")
	check(st.stage(99).is_empty() and st.stage(-1).is_empty(), "a course outside 0..31 has no stage")
	var real: Dictionary = st.stage(9)
	check(real.geometry == 9 and not real.stand_in and real.sketch.scene_path == C.scene_path(9), "a walkable course (3-2) is shown as itself")
	# a listed level that fails to build is dropped and the choice made again
	var st2 = ST.new()
	st2._failed[9] = true
	var again: Dictionary = st2.stage(1)
	check(not again.is_empty() and again.geometry != 9 and again.geometry != 1, "a level that fails to build is skipped (course 1 shows %d)" % again.geometry)
	var st3 = ST.new()
	for g in ST.SKETCHED:
		st3._failed[g] = true
	check(st3.stage(0).is_empty() and st3.stage(1).is_empty(), "with no level buildable at all a stage is empty, and asking again is safe")
	# the cached list is true: every listed course really builds
	var built_ok := true
	for g in ST.SKETCHED:
		var sk = K.load_for(C.scene_path(g))
		built_ok = built_ok and sk != null and sk.goal_kind == "flagpole" and A.build(sk) != null
	check(built_ok, "every course in SKETCHED builds a sketch with a flagpole and baked art")

# ------------------------------------------------------------------ the walk audit

## Walks Mario through each level the previews may show, alone: three seeds, small and big, progress rising evenly. A level is only
## allowed in BattlePreviewStages.SKETCHED when this finds nothing: no frame inside solid terrain, none on foot over a pit, and the
## flagpole is reached and the pane fades to the next course.
func test_walk_audit() -> void:
	print("-- the walk audit: every level the previews may show is walked cleanly")
	for g in ST.SKETCHED:
		var sk = K.load_for(C.scene_path(g))
		var art = A.build(sk)
		var solid := 0
		var pit := 0
		var reached := 0
		var faded := 0
		var runs := 0
		for seed_value in [1, 2, 3]:
			for power in [0, 1]:
				runs += 1
				var tr = T.new(1, sk, art, seed_value, 117.0, g)
				var dur := 110
				feed_run(tr, dur, dur + 12, {}, power, g)
				var seen_flag := false
				var seen_fade := false
				var t := 0.0
				while t < dur + 20.0 and tr.phase != T.Phase.DONE and not seen_fade:
					t += 1.0 / 30.0
					tr.advance_to(t)
					var h: float = 28.0 if tr.power > 0 else 14.0
					seen_flag = seen_flag or tr.phase == T.Phase.FLAG
					seen_fade = seen_fade or tr.phase == T.Phase.FADE
					if tr.phase in [T.Phase.RUN, T.Phase.FLAG]:
						if sk.box_hits(tr.x, tr.y, h):
							solid += 1
						elif tr.phase == T.Phase.RUN and sk.is_pit_at(tr.x) and tr.jump.is_empty() and tr.grounded:
							pit += 1
				reached += int(seen_flag)
				faded += int(seen_fade)
		check(solid == 0 and pit == 0 and reached == runs and faded == runs, "%s: %d walks, %d frames in terrain, %d over a pit, flagpole reached %d / %d, faded %d / %d" % [C.text(g), runs, solid, pit, reached, runs, faded, runs])

# ------------------------------------------------------------------ the transition

func test_transition() -> void:
	print("-- the clear: flagpole, hold, three dark steps, the next course")
	var tr = make_track(7)
	var frame0 = tr.frame
	var sketch0 = tr.sketch
	feed_run(tr, 100, 160)
	var log := []
	var phases := []
	var t := 0.0
	var step := 1.0 / 30.0
	var pole_done := -1.0
	var fade_start := -1.0
	while t < 160.0 and tr.course == 0:
		t += step
		tr.advance_to(t)
		log.append({"t": tr.sim_t, "phase": tr.phase, "fade": tr.fade, "valid": tr.frame.valid, "pose": tr.pose, "y": tr.y})
		if phases.is_empty() or phases[phases.size() - 1] != tr.phase:
			phases.append(tr.phase)
		if tr.phase == T.Phase.FLAG and pole_done < 0.0 and tr._slide_done_t >= 0.0:
			pole_done = tr.sim_t
		if tr.phase == T.Phase.FADE and fade_start < 0.0:
			fade_start = tr.sim_t
	check(tr.course == 1, "the track is on course 1 after its clear (course %d)" % tr.course)
	check(phases.has(T.Phase.FLAG) and phases.has(T.Phase.FADE), "it went through the flagpole and the fade (%s)" % [phases])
	check(not phases.has(T.Phase.DONE) and not phases.has(T.Phase.KO), "...and never ended")
	var fades := []
	for e in log:
		if e.phase == T.Phase.FADE and e.fade > 0.0:
			fades.append(snappedf(e.fade, 0.001))
	check(fades.size() == 3 and is_equal_approx(fades[0], 0.10) and is_equal_approx(fades[1], 0.41) and is_equal_approx(fades[2], 1.0), "the pane darkens in three steps, 10 / 41 / 100 %% black (%s)" % [fades])
	check(tr.fade == 0.0 and tr.frame.fade == 0.0, "the next course starts at once with no fade in")
	check(log.all(func(e): return e.valid), "the frame was valid on every step: the cell never fell back to the placeholder")
	check(tr.frame == frame0 and tr.frame.sketch == tr.sketch and tr.sketch != sketch0 and tr.frame.assets == tr.assets, "the same frame object now carries the next level and its art (a cell stays bound)")
	check(tr.frame.displayed_course == 1 and tr.stage_geometry != 0, "it is labelled with the real course (1), drawn from another level (%d)" % tr.stage_geometry)
	check(tr.phase == T.Phase.RUN, "the run goes on")
	check(fade_start - pole_done > 0.2 and fade_start - pole_done < 0.4, "the pane waits %.2f s at the pole's foot before it darkens (measured 0.23-0.30 s)" % (fade_start - pole_done))
	# afterwards it plays the new level
	var x_at_entry: float = tr.x
	var t2 := t
	for i in 300:
		t2 += step
		tr.advance_to(t2)
	check(tr.course == 1 and tr.x > x_at_entry + 20.0 and tr.phase == T.Phase.RUN, "and then it walks the new level (x %.0f -> %.0f)" % [x_at_entry, tr.x])
	check(not tr.sketch.box_hits(tr.x, tr.y, 14.0), "...never inside terrain")

func test_two_clears_in_a_row() -> void:
	print("-- two clears logged close together are both shown, in order")
	var tr = make_track(5)
	# course 0 clear at tick 40; the same bot clears course 1 at tick 44 (a later key says course 2 already)
	for tick in range(0, 121):
		var course := 0
		var p := float(tick) / 40.0
		var ev: Array = []
		if tick >= 40:
			course = 1
			p = float(tick - 40) / 4.0
		if tick >= 44:
			course = 2
			p = float(tick - 44) / 120.0
		if tick == 40:
			ev.append({"type": S.EventType.LEVEL_CLEAR, "id": 1, "tick": tick, "a": 1})
		if tick == 44:
			ev.append({"type": S.EventType.LEVEL_CLEAR, "id": 1, "tick": tick, "a": 2})
		tr.push(tick, course, minf(p, 1.0), 0, true, ev)
	check(tr._clears.has(1) and tr._clears.has(2), "both clears are remembered (%s)" % [tr._clears.keys()])
	var courses := [0]
	var t := 0.0
	while t < 118.0:
		t += 1.0 / 30.0
		tr.advance_to(t)
		if tr.course != courses[courses.size() - 1]:
			courses.append(tr.course)
	check(courses == [0, 1, 2], "the picture goes 0 -> 1 -> 2, one course at a time (%s)" % [courses])
	check(tr.frame.valid and tr.frame.displayed_course == tr.course and tr.phase != T.Phase.DONE, "and is live on course %d" % tr.course)
	check(tr._clears.is_empty() or not tr._clears.has(1), "a shown clear is forgotten")

func test_no_stale_state() -> void:
	print("-- nothing of the last level is left on the new one")
	var tr = make_track(11)
	var kept := {"tick": 90.0, "kind": "hit", "power_to": 0, "planned": true, "instant": true, "fatal_jump": 3}
	feed_run(tr, 60, 70, {20: [{"type": S.EventType.INCOMING_ACTIVATED, "id": 1, "tick": 20, "a": 8, "kind": 1}]})
	tr._pending.append(kept)
	tr._inc_spawn.append({"tick": 400.0, "seq": 9, "kind": 1})
	var t := 0.0
	var saw_enemies := false
	while tr.course == 0 and t < 120.0:
		t += 1.0 / 30.0
		tr.advance_to(t)
		saw_enemies = saw_enemies or not tr.enemies.is_empty()
	check(saw_enemies, "(the first level had enemies on screen)")
	check(tr.enemies.is_empty() and tr._spawn_next == 0, "no enemy of the last level, and the new level's spawns start from its beginning")
	check(tr.x == tr.sketch.start_x or tr.x < tr.sketch.start_x + 2.0, "Mario is at the new level's start (x %.1f, start %.1f)" % [tr.x, tr.sketch.start_x])
	check(tr.jump.is_empty() and tr.jump_idx == 0 and tr.vy == 0.0 and tr.grounded, "no jump of the last level's plan")
	check(tr.camera_x >= tr.sketch.level_min_x and tr.camera_x <= tr.sketch.start_x, "the camera is back at the new level's start, not where the last level ended (%.0f)" % tr.camera_x)
	check(tr.flag_y == -151.0 and not tr.mario_hidden and tr.fade == 0.0 and tr.freeze_t == 0.0 and tr.blink_t == 0.0, "no flag, fade, freeze or blink is left")
	check(tr.frame.actors.is_empty() and tr.frame.mario_visible and tr.frame.flag_y == -151.0 and tr.frame.fade == 0.0, "the frame shows a clean start: no actors, Mario visible, no flag cloth down, no fade")
	check(kept.get("planned", true) == false and not kept.has("fatal_jump") and not kept.has("instant"), "an outcome still to be shown is kept, to be planned again on the new level")
	check(tr._inc_spawn.size() == 1 and tr._inc_spawn[0].seq == 9, "an incoming attack still to be shown is kept")
	var inv = tr.invader_for(8)
	check(inv != null and not inv.is_vanishing() and tr.invaders.size() == 1, "an attack that is still ACTIVE on this opponent has its enemy on the new course too (and no other leftover)")
	check(tr.y == tr.sketch.ground_y_at(tr.x) or tr.y == 0.0, "Mario stands on the new level's ground")

func test_ko_and_pending() -> void:
	print("-- KOs around a transition are safe")
	# a time KO logged while the pole is being slid down: shown after the cut, in the new level, ending in the KO phase
	var tr = make_track(3)
	feed_run(tr, 60, 90, {62: [{"type": S.EventType.KO, "id": 1, "tick": 62, "a": S.KoCause.TIME}]})
	var t := 0.0
	var phases := []
	while t < 90.0 and tr.phase != T.Phase.KO:
		t += 1.0 / 30.0
		tr.advance_to(t)
		if phases.is_empty() or phases[phases.size() - 1] != tr.phase:
			phases.append(tr.phase)
	check(tr.phase == T.Phase.KO and tr.ko_overlay and tr.frame.ko_overlay and tr.frame.valid and tr.mario_hidden, "a KO logged during the pole ends the preview in the KO phase with its overlay (%s)" % [phases])
	check(tr.frame.fade == 0.0 and tr.course == 1, "...in the new level, with no fade left over the KO card (fade %.2f, course %d)" % [tr.frame.fade, tr.course])
	check(tr.advance_to(t + 5.0) == false, "a KO is final: nothing moves after it")
	# a hazard KO and a HIT logged for the new level are staged on it
	var tr2 = make_track(4)
	feed_run(tr2, 50, 130, {80: [{"type": S.EventType.HIT, "id": 1, "tick": 80, "a": 0}], 100: [{"type": S.EventType.KO, "id": 1, "tick": 100, "a": S.KoCause.HAZARD}]}, 1)
	t = 0.0
	while t < 130.0 and tr2.phase != T.Phase.KO:
		t += 1.0 / 30.0
		tr2.advance_to(t)
	check(tr2.course == 1 and tr2.phase == T.Phase.KO and tr2.ko_overlay, "a HIT and a hazard KO of the new course play on the new course and end in KO (course %d)" % tr2.course)
	check(tr2.frame.valid and tr2.frame.displayed_course == 1, "...with the picture still live and labelled with course 1")
	# the session KO of a bot that never gets to show its clear
	var tr3 = make_track(6)
	feed_run(tr3, 30, 40, {31: [{"type": S.EventType.KO, "id": 1, "tick": 31, "a": S.KoCause.HAZARD}]})
	t = 0.0
	while t < 60.0 and tr3.phase != T.Phase.KO:
		t += 1.0 / 30.0
		tr3.advance_to(t)
	check(tr3.phase == T.Phase.KO and tr3.frame.valid, "a clear and a hazard KO one tick apart still end in a clean KO")

func test_settle() -> void:
	print("-- the results freeze never holds a pane in the dark")
	var tr = make_track(7)
	feed_run(tr, 100, 160)
	var t := 0.0
	while t < 160.0 and tr.phase != T.Phase.FADE:
		t += 1.0 / 30.0
		tr.advance_to(t)
	t += 1.0 / 30.0
	tr.advance_to(t)
	check(tr.phase == T.Phase.FADE and tr.frame.fade > 0.0, "(caught in the fade: %.2f black)" % tr.frame.fade)
	tr.settle()
	check(tr.course == 1 and tr.phase == T.Phase.RUN and tr.frame.fade == 0.0 and tr.frame.valid and tr.frame.displayed_course == 1, "settling a pane mid-fade puts it on the next course, with no darkness (course %d, fade %.2f)" % [tr.course, tr.frame.fade])
	var sig: String = tr.frame.signature()
	tr.settle()
	check(tr.frame.signature() == sig, "settling a pane that is at rest changes nothing")
	var tr_flag = make_track(7)
	feed_run(tr_flag, 100, 160)
	t = 0.0
	while t < 160.0 and tr_flag.phase != T.Phase.FLAG:
		t += 1.0 / 30.0
		tr_flag.advance_to(t)
	var flag_sig: String = tr_flag.frame.signature()
	tr_flag.settle()
	check(tr_flag.phase == T.Phase.FLAG and tr_flag.frame.signature() == flag_sig, "a pane on the flagpole is left on the flagpole (a picture that reads)")

func test_no_stages_and_last_course() -> void:
	print("-- the ends of the run")
	var tr = make_track(7, false)
	feed_run(tr, 100, 160)
	var t := 0.0
	while t < 160.0 and tr.phase != T.Phase.DONE:
		t += 1.0 / 30.0
		tr.advance_to(t)
	check(tr.phase == T.Phase.DONE and tr.course == 0 and not tr.frame.valid, "a track with no stages still ends its run dark and hands back to the placeholder (the old behaviour)")
	var st = ST.new()
	var stage: Dictionary = st.stage(30)
	var last = T.new(1, stage.sketch, stage.assets, 9, 117.0, 31, st)
	check(last.course == 31, "(a track can start on the last course)")
	feed_run(last, 100, 170, {}, 0, 31)
	t = 0.0
	while t < 170.0 and last.phase != T.Phase.DONE:
		t += 1.0 / 30.0
		last.advance_to(t)
	check(last.phase == T.Phase.DONE and last.course == 31 and last.frame.fade == 1.0 and not last.frame.valid, "the last course has no next one: the run ends dark, never on a made-up course 32")

# ------------------------------------------------------------------ a whole match

func run_match(seed_value: int, ticks: int, ids: Array, check_each := true) -> Dictionary:
	var s = S.new(seed_value)
	var d = D.create(s, ids, 188.0)
	var out := {"s": s, "d": d, "dead_frames": 0, "done": 0, "max_course": 0, "stage_swaps": 0, "black_rests": 0, "mismatch": 0, "built_ahead": 0, "frames": []}
	var last_geo := {}
	for tick in ticks:
		s.step()
		for k in 3:
			d.update(float(k) / 3.0)
			for id in ids:
				var tr = d.tracks[id]
				var c = s.contestants[id]
				out.max_course = maxi(out.max_course, tr.course)
				if tr.phase == T.Phase.DONE:
					out.done += 1
				if not tr.frame.valid:
					out.dead_frames += 1
				if tr.phase == T.Phase.RUN and tr.frame.fade > 0.0:
					out.black_rests += 1
				if tr.course > c.levels_cleared or tr.frame.displayed_course != tr.course:
					out.mismatch += 1
				if last_geo.has(id) and last_geo[id] != tr.stage_geometry:
					out.stage_swaps += 1
				last_geo[id] = tr.stage_geometry
		if check_each:
			out.frames.append(d.tracks[ids[0]].frame.signature())
	return out

func test_driver_matches() -> void:
	print("-- whole matches: no pane is ever in limbo")
	var dead := 0
	var done := 0
	var swaps := 0
	var mismatch := 0
	var black := 0
	var deepest := 0
	var all_ids := range(1, 35)
	for seed_value in [2, 8, 19, 33]:
		var r = run_match(seed_value, 260, all_ids, false)
		dead += r.dead_frames
		done += r.done
		swaps += r.stage_swaps
		mismatch += r.mismatch
		black += r.black_rests
		deepest = maxi(deepest, r.max_course)
	check(deepest >= 2 and swaps > 20, "the four matches have panes that clear courses (deepest course %d, %d level changes across the 34 panes)" % [deepest, swaps])
	check(dead == 0 and done == 0, "no pane ever has an invalid frame or ends its run: no placeholder fallback, no frozen end of course (%d invalid frames, %d done)" % [dead, done])
	check(black == 0, "no pane is ever at rest in the dark (%d)" % black)
	check(mismatch == 0, "a pane is never ahead of the session's course and always labelled with its own (%d)" % mismatch)
	# a bot's next course is baked before the picture needs it
	var s = S.new(8)
	var d = D.create(s, all_ids, 188.0)
	var primed := 0
	var late := 0
	for tick in 200:
		s.step()
		d.update(0.0)
		for id in all_ids:
			var c = s.contestants[id]
			if c.alive and c.progress >= ST.PREFETCH_PROGRESS:
				primed += 1
				if not d.stages.is_built(c.levels_cleared + 1):
					late += 1
	check(primed > 0 and late == 0, "the next course is built once a bot is half way through its course (%d bot-ticks, %d not built)" % [primed, late])
	# pane order and KO behaviour do not depend on the previews
	var plain = S.new(19)
	var shown = S.new(19)
	var dd = D.create(shown, all_ids, 188.0)
	for tick in 200:
		plain.step()
		shown.step()
		dd.update(0.5)
	var same := true
	for id in all_ids:
		var a = plain.contestants[id]
		var b = shown.contestants[id]
		same = same and a.alive == b.alive and a.levels_cleared == b.levels_cleared and a.placement == b.placement and a.ko_tick == b.ko_tick and a.progress == b.progress
	check(same and JSON.stringify(plain.snapshot()) == JSON.stringify(shown.snapshot()), "the session is identical with the previews attached (course changes included): they only read it")

func test_determinism() -> void:
	print("-- the same match gives the same pictures, course changes included")
	var a = run_match(19, 220, [1], true)
	var b = run_match(19, 220, [1], true)
	check(a.frames.size() == 220 and a.frames == b.frames, "two identical runs give identical frames")
	check(a.max_course >= 1 and a.stage_swaps >= 1, "(the run includes a level change: course %d)" % a.max_course)

# ------------------------------------------------------------------ the screen

func test_screen() -> void:
	print("-- the screen: results freeze")
	var G = root.get_node("Global")
	var Screen = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	G.current_game_mode = G.GameMode.BATTLE
	var s = S.begin(19)
	var scr = Screen.new()
	root.add_child(scr)
	await frames(4)
	check(scr.driver != null and scr.driver.stages != null and scr.driver.tracks.size() == 34, "the screen's driver has stages and a track for each of the 34 opponents")
	# play the match on until some pane is in the dark between two courses, then freeze the field
	var caught := -1
	for tick in 260:
		s.step()
		for k in 15:
			scr.driver.update(float(k) / 15.0)
			for id in scr.driver.tracks:
				if scr.driver.tracks[id].phase == T.Phase.FADE and scr.driver.tracks[id].frame.fade > 0.0 and caught < 0:
					caught = id
			if caught >= 0:
				break # (stop the very update that caught it: the next one would carry it on)
		if caught >= 0:
			break
	check(caught >= 0, "a pane was caught between two courses (opponent %d)" % caught)
	if caught >= 0:
		var tr = scr.driver.tracks[caught]
		var course_before: int = tr.course
		scr._freeze_field()
		check(tr.frame.fade == 0.0 and tr.course == course_before + 1 and tr.frame.valid, "the freeze settles it on the next course: no black pane in the results (course %d -> %d)" % [course_before, tr.course])
		var live := 0
		for cell in scr.cells:
			live += int(cell.is_live() or cell.ko)
		check(live == 34, "every pane is live or a KO card in the frozen field (%d / 34)" % live)
		for i in 30:
			s.step()
			scr.driver.update(0.5) # (the session keeps running behind the results)
		check(scr.field_frozen, "(the field stays frozen while the session runs on behind the results)")
	root.remove_child(scr)
	scr.free()
	S.clear()
	await frames(3)
	G.current_game_mode = G.GameMode.CAMPAIGN
