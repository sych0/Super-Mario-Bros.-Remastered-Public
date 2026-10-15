extends SceneTree
## Headless checks for the Battle opponent previews (milestone 1: World 1-1, opponent #1).
## Needs the imported project (autoloads, real level scenes, real art).
## Run: godot --headless --path . -s tests/battle_preview_test.gd

var failures := 0
var S # BattleSession
var D # BattlePreviewDriver
var K # BattleLevelSketch
var A # BattlePreviewAssets
var T # BattlePreviewTrack
var R # BattlePreviewResolver
var C # BattleCourse
const LEVEL := "res://Scenes/Levels/SMB1/World1/1-1.tscn"

## Match results of the *unmodified* session code (commit 6eb7562) for these seeds, so event
## logging provably changed no outcome. Key "<seed>" = resolved to the end, "<seed>m" = after 150 ticks.
const GOLDEN := {"1":"a7caee2e4f473a0b33b80bceb2e678d8","2":"44777af7d4aa2430196fad7cb4135021","3":"c9146a55bdc302b45cac9eb43c5786e9","7":"9ed98e3ddf6b94af49a232667d14f15f","42":"b9edf93bdc4b20855320c26a69f58cbb","1234":"cab7df5b375ad8bfebf5774de829ba8a","99999":"f44ca568f3741d531f381b328a6950e4","1234m":"00b6b4bef8e13a2b12099f720cc1ce51","1m":"976c23f0fcfc2e2012b444f80d6f1d4d","2m":"ae38c8e474e94f9e73bd1e61d59948d4","3m":"93b85e66ab239c3d88de49f17fcea1ed","42m":"79a9b001b117767e2046b3f5bbf225d3","7m":"149897557866150fb1b63f95f37d686e","99999m":"62243279f763fdcd141a420fb401fbe8"}

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func frames(n: int) -> void:
	for i in n:
		await process_frame

func sig(s) -> String:
	var parts := []
	for c in s.contestants:
		parts.append("%s,%d,%d,%d,%d,%d,%d,%s" % [c.alive, c.ko_tick, c.ko_cause, c.placement, c.levels_cleared, c.power, c.time_left, str(c.progress)])
	return "|".join(parts) + "|%d|%d" % [s.tick_count, s.winner_id]

func _initialize() -> void:
	await frames(5)
	S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	D = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	K = load("res://Scripts/Classes/Battle/BattleLevelSketch.gd")
	A = load("res://Scripts/Classes/Battle/BattlePreviewAssets.gd")
	T = load("res://Scripts/Classes/Battle/BattlePreviewTrack.gd")
	R = load("res://Scripts/Classes/Battle/BattlePreviewResolver.gd")
	C = load("res://Scripts/Classes/Battle/BattleCourse.gd")
	test_course()
	var sk = test_sketch()
	test_resolver()
	test_assets(sk)
	test_events()
	test_outcomes_unchanged()
	test_staging_and_invariants(sk)
	test_synthetic_hit_and_ko(sk)
	test_coarse_updates()
	test_determinism()
	test_fallback_and_hud()
	await test_hud_integration()
	if failures > 0:
		printerr("%d Battle preview test(s) failed" % failures)
	else:
		print("All Battle preview tests passed")
	quit(1 if failures > 0 else 0)

# ------------------------------------------------------------------ course

func test_course() -> void:
	check(C.scene_path(0) == LEVEL, "course 0 is World 1-1 (%s)" % C.scene_path(0))
	check(C.scene_path(5) == "res://Scenes/Levels/SMB1/World2/2-2.tscn" and C.text(5) == "2-2", "course numbering (5 = 2-2)")
	check(C.scene_path(32) == "" and C.scene_path(-1) == "", "no scene outside courses 0..31")

# ------------------------------------------------------------------ sketch

func test_sketch():
	var sk = K.load_for(LEVEL)
	check(sk != null, "1-1 sketch decodes from the saved level without instantiating it")
	check(K.load_for(LEVEL) == sk, "sketches are cached and shared")
	check(sk.start_x == -208.0, "player start x = -208 (%s)" % sk.start_x)
	check(sk.goal_x == 2920.0 and sk.goal_kind == "flagpole", "flagpole at x=2920 (%s)" % sk.goal_x)
	check(sk.castle_x == 3016.0, "castle at x=3016")
	check(sk.theme == "Overworld" and sk.theme_time == "Day" and sk.campaign == "SMB1", "theme Overworld/Day/SMB1")
	# pits: tile columns 53-54, 70-72, 137-138 (end exclusive)
	var pit_cols := []
	for p in sk.pits:
		pit_cols.append([int(p.x / 16.0), int(p.y / 16.0) - 1])
	check(pit_cols == [[53, 54], [70, 72], [137, 138]], "pits are tile columns 53-54, 70-72, 137-138 (%s)" % [pit_cols])
	var kinds := {}
	for sp in sk.spawns:
		kinds[sp.kind] = kinds.get(sp.kind, 0) + 1
	check(kinds == {"goomba": 16, "koopa_green": 1}, "16 Goombas + 1 green Koopa (%s)" % [kinds])
	check(sk.dropped_entities == 0, "no entity type was dropped in 1-1")
	check(sk.spawns[0].x == 104.0 and sk.spawns[0].y == 0.0, "first Goomba at (104, 0)")
	# solid facts straight from the real TileSet collision data
	check(sk.solid_at(0.0, 8.0) and sk.solid_at(100.0, 40.0), "ground rows are solid")
	check(not sk.solid_at(860.0, 8.0) and not sk.solid_at(860.0, 40.0), "the first pit is empty")
	check(sk.solid_at(360.0, -8.0) and sk.support_y(360.0, -100.0) == -48.0, "a pipe is solid and its top is at y=-48")
	check(sk.blocks.size() > 20, "bricks/?-blocks are decoded (%d)" % sk.blocks.size())
	# walk line: ground exists everywhere except in the pits
	var bad := 0
	for px in range(int(sk.start_x), int(sk.goal_x), 4):
		var in_pit := false
		for p in sk.pits:
			if px >= p.x and px < p.y:
				in_pit = true
		if in_pit != sk.is_pit_at(float(px)):
			bad += 1
	check(bad == 0, "the walk line has no ground over pits and ground everywhere else")
	# every planned jump is free of terrain, lands on ground and never starts over a pit
	var jumps_ok := true
	var prev_x := -1.0e9
	for j in sk.jumps:
		var arc := {"vx": j.vx, "vy0": j.vy0, "T": j.T}
		if not sk.arc_clear(j.x_start, j.y_start, arc) or sk.is_pit_at(j.x_start) or j.x_start < prev_x:
			jumps_ok = false
		var land: Vector2 = K.arc_pos(j.x_start, j.y_start, j.vx, j.vy0, j.T)
		if absf(land.x - j.x_land) > 0.01 or absf(land.y - j.y_land) > 0.01:
			jumps_ok = false
		prev_x = j.x_start
	check(jumps_ok and sk.jumps.size() > 20, "%d planned jumps are terrain-free, ordered and land where planned" % sk.jumps.size())
	var gap_jumps = sk.jumps.filter(func(j): return j.kind == "gap").size()
	check(gap_jumps == 3, "one leap per pit (%d)" % gap_jumps)
	check(sk.jumps[sk.jumps.size() - 1].kind == "pole", "the last leap grabs the flagpole")
	# unsupported / missing levels do not produce a sketch
	check(K.load_for("res://Scenes/Levels/DoesNotExist.tscn") == null, "a missing level gives no sketch")
	return sk

# ------------------------------------------------------------------ resolver

func test_resolver() -> void:
	var G = root.get_node("Global")
	var packs: Array = ["BaseAssets"]
	var cfg: String = "user://battle_preview_test_cfg"
	var gob := "res://Assets/Sprites/Enemies/Goomba.json"
	var over = R.resolve(gob, "Overworld", "Day", "SMB1", packs, cfg)
	var under = R.resolve(gob, "Underground", "Day", "SMB1", packs, cfg)
	check(over.ok and over.rect == Rect2i(0, 0, 48, 16) and over.source.ends_with("Enemies/Goomba.png"), "Overworld Goomba resolves to its first variant (%s)" % over.rect)
	check(under.ok and under.rect == Rect2i(48, 0, 48, 16), "Underground Goomba resolves to the second variant (%s)" % under.rect)
	var old_theme = G.level_theme
	G.level_theme = "Castle"
	var again = R.resolve(gob, "Overworld", "Day", "SMB1", packs, cfg)
	G.level_theme = old_theme
	check(again.rect == over.rect, "resolution ignores the real player's global theme")
	check(over.animations.has("Walk") and over.animations.Walk.frames.size() == 2, "animation frames come with the resolution")
	var terrain = R.resolve("res://Assets/Sprites/Tilesets/Terrain/TerrainTiles.json", "Underground", "Day", "SMB1", packs, cfg)
	check(terrain.ok and terrain.source.ends_with("Terrain/Underground.png"), "terrain picks the themed atlas (%s)" % terrain.get("source", ""))
	var deco = R.resolve("res://Assets/Sprites/Tilesets/Deco/DecoTiles.json", "Overworld", "Night", "SMB1", packs, cfg)
	check(deco.ok and deco.rect == Rect2i(0, 32, 80, 32), "time of day selects the deco strip (%s)" % deco.get("rect", ""))
	check(not R.resolve("res://Assets/Sprites/Nope.json", "Overworld", "Day", "SMB1", packs, cfg).ok, "a missing JSON fails cleanly")
	# resource packs: the first pack that has the file wins, like ResourceSetterNew
	var dir := ProjectSettings.globalize_path(cfg) + "/resource_packs/TestPack/Sprites/Enemies"
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/Goomba.png", FileAccess.WRITE)
	f.store_buffer(FileAccess.get_file_as_bytes("res://Assets/Sprites/Enemies/Goomba.png"))
	f.close()
	var with_pack = R.resolve(gob, "Overworld", "Day", "SMB1", ["TestPack", "BaseAssets"], cfg)
	check(with_pack.ok and with_pack.source.contains("resource_packs/TestPack/Sprites/Enemies/Goomba.png"), "a resource pack's own file overrides the base art (%s)" % with_pack.get("source", ""))
	var without = R.resolve(gob, "Overworld", "Day", "SMB1", ["BaseAssets"], cfg)
	check(without.source == "res://Assets/Sprites/Enemies/Goomba.png", "without the pack the base art is used")
	DirAccess.remove_absolute(dir + "/Goomba.png")

# ------------------------------------------------------------------ assets

func test_assets(sk) -> void:
	var a = A.build(sk)
	check(a != null and a.errors.is_empty(), "1-1 preview art bakes from the real resource files (%s)" % [a.errors if a else "null"])
	if a == null:
		return
	check(A.build(sk) == a, "the baked level is shared: a second request returns the same object")
	check(a.strip.get_width() > 3500 and a.strip.get_height() >= 256, "one level-wide strip texture (%s)" % a.strip.get_size())
	check(a.strip.get_image().has_mipmaps(), "the strip has mipmaps (it is drawn heavily minified)")
	check(a.mario.size() == 3 and a.mario[0].Move.frames.size() == 3 and a.mario[2].Jump.frames.size() == 1, "Mario Small/Big/Fire frames are baked")
	check(a.enemies.has("goomba") and a.enemies.has("koopa_green") and a.enemies.goomba.has("dead"), "Goomba and Koopa frames are baked")
	var small = a.mario_frame_at(0, "Idle", 0)
	var big = a.mario_frame_at(1, "Idle", 0)
	check(small.size.y <= 16.5 and big.size.y > small.size.y, "small Mario is one tile tall and big Mario is taller (%s, %s)" % [small.size, big.size])
	check(a.bake_ms < 3000.0, "baking takes %.0f ms" % a.bake_ms)

# ------------------------------------------------------------------ events

func test_events() -> void:
	var ok_hit := true
	var ok_clear := true
	var ok_ko := true
	var seen := {0: 0, 1: 0, 2: 0, 3: 0}
	for seed_value in [3, 7, 19, 42, 77]:
		var s = S.new(seed_value)
		var last_power := {}
		var last_cleared := {}
		for c in s.contestants:
			last_power[c.id] = c.power
			last_cleared[c.id] = c.levels_cleared
		var logged := 0
		for t in 200:
			s.step()
			var fresh: Array = s.events.slice(logged)
			logged = s.events.size()
			for c in s.contestants:
				var mine = fresh.filter(func(e): return e.id == c.id)
				var hits = mine.filter(func(e): return e.type == S.EventType.HIT).size()
				var ups = mine.filter(func(e): return e.type == S.EventType.POWER_UP).size()
				var clears = mine.filter(func(e): return e.type == S.EventType.LEVEL_CLEAR).size()
				if (c.power < last_power[c.id]) != (hits == 1) or (c.power > last_power[c.id]) != (ups == 1):
					ok_hit = false
				if clears != c.levels_cleared - last_cleared[c.id]:
					ok_clear = false
				last_power[c.id] = c.power
				last_cleared[c.id] = c.levels_cleared
			for e in fresh:
				seen[e.type] += 1
				if e.tick != s.tick_count:
					ok_ko = false
		var kos = s.events.filter(func(e): return e.type == S.EventType.KO)
		var dead = s.contestants.filter(func(c): return not c.alive)
		if kos.size() != dead.size():
			ok_ko = false
		for e in kos:
			if s.contestants[e.id].ko_tick != e.tick or s.contestants[e.id].ko_cause != e.a:
				ok_ko = false
	check(ok_hit, "HIT / POWER_UP events appear exactly when a bot's power drops / rises")
	check(ok_clear, "LEVEL_CLEAR events match levels cleared")
	check(ok_ko, "every KO is logged once with its tick and cause, and events carry the tick they happened in")
	check(seen[S.EventType.HIT] > 0 and seen[S.EventType.POWER_UP] > 0 and seen[S.EventType.LEVEL_CLEAR] > 0 and seen[S.EventType.KO] > 0, "all four event kinds occur in normal matches (%s)" % [seen])

# ------------------------------------------------------------------ determinism of the session

func test_outcomes_unchanged() -> void:
	var all_same := true
	for key in GOLDEN:
		var seed_value := int(key.trim_suffix("m"))
		var s = S.new(seed_value)
		if key.ends_with("m"):
			for i in 150:
				s.step()
		else:
			s.resolve_to_end()
		if sig(s).md5_text() != GOLDEN[key]:
			all_same = false
			printerr("  mismatch for ", key)
	check(all_same, "match results are bit-identical to the pre-event-log code for %d seed/point pairs" % GOLDEN.size())
	# previews attached and drawing every tick change nothing either (rng state included)
	var same := true
	for seed_value in [1, 5, 19, 42, 1234]:
		var plain = S.new(seed_value)
		for i in 300:
			plain.step()
		var shown = S.new(seed_value)
		var d = D.create(shown, range(1, 35), 188.0)
		for i in 300:
			shown.step()
			d.update(0.0)
			d.update(0.5)
		if JSON.stringify(plain.snapshot()) != JSON.stringify(shown.snapshot()):
			same = false
	check(same, "identical authoritative results with previews attached (all 34) and without, including rng state")

# ------------------------------------------------------------------ staging + invariants

func feed(seed_value: int, ticks: int, sub := 3):
	var s = S.new(seed_value)
	var d = D.create(s, [1], 188.0)
	var t = d.tracks[1]
	var log := {"solid": 0, "pit": 0, "goal": 0, "frames": [], "dying_seen": false, "ko_tick": -1, "clear_tick": -1}
	for tick in ticks:
		s.step()
		for k in sub:
			d.update(float(k) / sub)
			var h: float = 28.0 if t.power > 0 else 14.0
			if t.phase in [T.Phase.RUN, T.Phase.FLAG, T.Phase.WALK_OUT]:
				if d.sketch.box_hits(t.x, t.y, h):
					log.solid += 1
				if t.phase == T.Phase.RUN and d.sketch.is_pit_at(t.x) and t.jump.is_empty() and t.grounded:
					log.pit += 1
				if t.phase == T.Phase.RUN and t.x > d.sketch.goal_x - 7.0 + 0.01:
					log.goal += 1
			log.frames.append(t.frame.signature())
		for e in s.events:
			if e.id == 1:
				if e.type == S.EventType.KO and log.ko_tick < 0:
					log.ko_tick = e.tick
				if e.type == S.EventType.LEVEL_CLEAR and log.clear_tick < 0:
					log.clear_tick = e.tick
		if t.phase == T.Phase.KO or t.phase == T.Phase.DONE:
			break
	log["track"] = t
	log["session"] = s
	return log

func test_staging_and_invariants(sk) -> void:
	var solid := 0
	var pit := 0
	var goal := 0
	var kos_ok := true
	var clears_ok := true
	var kos = 0
	var clears = 0
	var late := 0
	for seed_value in range(1, 81):
		var r = feed(seed_value, 260)
		solid += r.solid
		pit += r.pit
		goal += r.goal
		var t = r.track
		if r.ko_tick >= 0 and (r.clear_tick < 0 or r.ko_tick < r.clear_tick):
			kos += 1
			if t.phase != T.Phase.KO or not t.ko_overlay or not t.frame.ko_overlay or t.frame.valid == false:
				kos_ok = false
			if t.sim_t - r.ko_tick > 6.0:
				late += 1
		elif r.clear_tick >= 0:
			clears += 1
			if t.phase != T.Phase.DONE or t.frame.valid:
				clears_ok = false
	check(kos > 10 and clears > 10, "the 80 seeds cover many KOs (%d) and clears (%d)" % [kos, clears])
	check(solid == 0, "Mario's visual path never overlaps solid terrain (%d violations)" % solid)
	check(pit == 0, "Mario is never standing or walking over a pit; only leaping or dying (%d violations)" % pit)
	check(goal == 0, "Mario never passes the flagpole before the LEVEL_CLEAR (%d violations)" % goal)
	check(kos_ok, "every authoritative KO ends in the KO phase with the overlay shown")
	check(clears_ok, "every authoritative LEVEL_CLEAR plays out and ends the live preview")
	check(late == 0, "KO animations finish within 6 s of the authoritative KO")

	# a clear shows the flagpole slide: the frame passes through FLAG with the flag cloth moving
	var r19 = feed(19, 200, 6)
	var t19 = r19.track
	check(t19.phase == T.Phase.DONE and t19.power == 1, "seed 19 clears 1-1, grows at the castle (power %d) and hands back to the placeholder" % t19.power)
	var saw_flag := false
	var saw_cloth_move := false
	var first_flag := ""
	for f in r19.frames:
		if f.contains("|Climb|"):
			saw_flag = true
	check(saw_flag, "a Climb pose (flagpole slide) appears in a clear")

# ------------------------------------------------------------------ synthetic HIT / KO / power

func synth(power: int):
	var sk = K.load_for(LEVEL)
	var tr = T.new(1, sk, A.build(sk), 11, 117.0, 0)
	tr.push(0, 0, 0.0, power, true, [])
	return tr

func test_synthetic_hit_and_ko(sk) -> void:
	# Big Mario, authoritative HIT at tick 6 (power 2 -> 1), KO at tick 14 (power 1 -> dead).
	var tr = synth(2)
	var progress := 0.0
	var saw_blink := false
	var saw_transition := false
	var saw_lethal := false
	var power_after_hit := -1
	for tick in range(1, 30):
		progress += 0.012
		var ev := []
		var pw := 2 if tick < 6 else 1
		if tick == 6:
			ev.append({"tick": 6, "id": 1, "type": S.EventType.HIT, "a": 1, "b": 0})
		if tick == 14:
			ev.append({"tick": 14, "id": 1, "type": S.EventType.KO, "a": S.KoCause.HAZARD, "b": 0})
		tr.push(tick, 0, progress, pw, tick < 14, ev)
		for k in 30:
			tr.advance_to(float(tick - 2) + float(k) / 30.0)
			if tr.blink_t > 0.0:
				saw_blink = true
			if tr.pose == "Transition":
				saw_transition = true
			if tr.enemies.any(func(e): return e.lethal):
				saw_lethal = true
		if tick == 11:
			power_after_hit = tr.power
	check(saw_lethal, "a HIT / hazard KO is staged by a scripted enemy walking in")
	check(saw_transition and saw_blink, "a HIT plays the shrink (time stop) and then blinks")
	check(power_after_hit == 1, "the displayed power follows the authoritative HIT (%d)" % power_after_hit)
	check(tr.phase == T.Phase.KO and tr.ko_overlay and tr.mario_hidden, "the following KO plays the death and ends in the KO phase")
	var tr2 = synth(0)
	tr2.push(1, 0, 0.01, 0, false, [{"tick": 1, "id": 1, "type": S.EventType.KO, "a": S.KoCause.TIME, "b": 0}])
	for k in 400:
		tr2.advance_to(float(k) / 30.0)
	check(tr2.phase == T.Phase.KO, "a time-out KO dies in place and reaches the KO phase")
	var tr3 = synth(0)
	tr3.push(0, 0, 0.0, 0, true, [])
	tr3.push(4, 0, 0.0, 1, true, [{"tick": 4, "id": 1, "type": S.EventType.POWER_UP, "a": 1, "b": 0}])
	var saw_grow := false
	for k in 200:
		tr3.advance_to(float(k) / 30.0)
		if tr3.pose == "Transition":
			saw_grow = true
	check(saw_grow and tr3.power == 1, "a POWER_UP grows Mario (power %d)" % tr3.power)

# Fast sim speeds / hitches: the preview is updated far less often than the session ticks.
func test_coarse_updates() -> void:
	var solid := 0
	var pit := 0
	var goal := 0
	var finished := 0
	var total := 0
	for chunk in [5, 25]:
		for seed_value in range(1, 16):
			var s = S.new(seed_value)
			var d = D.create(s, [1], 188.0)
			var t = d.tracks[1]
			total += 1
			for round in range(0, 300 / chunk):
				for i in chunk:
					s.step()
				for k in 4:
					d.update(float(k) / 4.0)
					var h: float = 28.0 if t.power > 0 else 14.0
					if t.phase in [T.Phase.RUN, T.Phase.FLAG, T.Phase.WALK_OUT]:
						if d.sketch.box_hits(t.x, t.y, h):
							solid += 1
						if t.phase == T.Phase.RUN and d.sketch.is_pit_at(t.x) and t.jump.is_empty() and t.grounded:
							pit += 1
						if t.phase == T.Phase.RUN and t.x > d.sketch.goal_x - 7.0 + 0.01:
							goal += 1
				if t.phase == T.Phase.KO or t.phase == T.Phase.DONE:
					finished += 1
					break
	check(solid == 0 and pit == 0 and goal == 0, "invariants also hold when the preview is updated every 5 or 25 session seconds (snapping/resync)")
	check(finished == total, "and every run still ends in KO or a clear (%d/%d)" % [finished, total])

# ------------------------------------------------------------------ determinism of previews

func test_determinism() -> void:
	var a = feed(19, 200, 4)
	var b = feed(19, 200, 4)
	check(a.frames.size() > 100 and a.frames == b.frames, "two identical runs give identical preview frames (%d frames)" % a.frames.size())
	var c = feed(2, 200, 4)
	check(c.frames != a.frames, "different matches give different pictures")
	# 34 tracks diverge (not lockstep) but each is reproducible
	var s1 = S.new(8)
	var d1 = D.create(s1, range(1, 35), 188.0)
	var s2 = S.new(8)
	var d2 = D.create(s2, range(1, 35), 188.0)
	var same := true
	var xs := {}
	for i in 60:
		s1.step()
		s2.step()
		d1.update(0.0)
		d2.update(0.0)
		for id in d1.tracks:
			if d1.tracks[id].frame.signature() != d2.tracks[id].frame.signature():
				same = false
	for id in d1.tracks:
		xs[snappedf(d1.tracks[id].x, 1.0)] = true
	check(same, "all 34 tracks are reproducible")
	check(xs.size() > 12, "the 34 Marios are not in lockstep (%d distinct positions)" % xs.size())

# ------------------------------------------------------------------ fallback + HUD

func test_fallback_and_hud() -> void:
	var s = S.new(3)
	var d = D.create(s, [1], 188.0)
	check(d.tracks.size() == 1 and not d.tracks.has(2), "only the requested opponent gets a track")
	check(D.LIVE_COURSE == 0, "only course 0 (World 1-1) has a live preview in milestone 1")
	var r19 = feed(19, 200, 3)
	check(not r19.track.frame.valid, "after the preview's level ends its frame is invalid, so the surface falls back")

func test_hud_integration() -> void:
	var G = root.get_node("Global")
	var Hud = load("res://Scripts/Classes/Battle/BattleHud.gd")
	G.current_game_mode = G.GameMode.BATTLE
	var s = S.begin(19)
	var hud = Hud.ensure(self)
	await frames(4)
	check(hud.driver != null and hud.driver.tracks.size() == 1, "the HUD runs one preview track by default")
	var live = hud.surfaces.filter(func(x): return x.is_live())
	check(live.size() == 1 and hud.surfaces[0].is_live(), "only opponent #1 uses the live renderer")
	var PH = load("res://Scripts/Classes/Battle/BattlePlaceholderRenderer.gd")
	var placeholders = hud.surfaces.filter(func(x): return not x.is_live() and x.renderer.get_script() == PH)
	check(placeholders.size() == 33, "the other 33 opponents keep the placeholder renderer")
	check(hud.debug_surface == null, "no debug full-size view in normal play")
	# authoritative HUD state is never delayed by the preview lag
	s.report_ko(1, S.KoCause.HAZARD)
	await frames(2)
	check(hud.surfaces[0].ko and hud._alive_label.text.contains("34"), "a KO shows in the HUD state at once while the picture is still running")
	check(hud.surfaces[0].is_live() and not hud.surfaces[0].frame.ko_overlay, "...and the picture's own KO marking waits for the death animation")
	hud.queue_free()
	S.clear()
	await frames(3)
	# debug stress mode: every window live
	OS.set_environment("SMB1R_BATTLE_PREVIEW_ALL", "1")
	OS.set_environment("SMB1R_BATTLE_PREVIEW_DEBUG", "1")
	D._flag_cache.clear()
	if OS.is_debug_build():
		var s2 = S.begin(4)
		var hud2 = Hud.ensure(self)
		await frames(4)
		check(hud2.driver != null and hud2.driver.tracks.size() == 34, "debug_all puts all 34 windows on the live renderer")
		check(hud2.debug_surface != null and hud2.debug_surface.size == Vector2(256, 240), "debug view draws opponent #1 at 256x240")
		hud2.queue_free()
		S.clear()
		await frames(3)
	OS.set_environment("SMB1R_BATTLE_PREVIEW_ALL", "")
	OS.set_environment("SMB1R_BATTLE_PREVIEW_DEBUG", "")
	D._flag_cache.clear()
	G.current_game_mode = G.GameMode.CAMPAIGN
