extends SceneTree
## TRACE (doc 57, which found the "winter" panes' cause with it): what happens to the real opponents' worlds and panes across
## the 1-1 -> 1-2 transition, in the full Battle screen, exactly as a build runs it (the title's Battle entry, the real player's game, the HUD, the atlas, the
## panes, the legacy previews for the other opponents). For each real opponent it logs, every frame its state changes and
## around its cut: the world object, its course and requested next course, the scene path loaded, the old level freed or
## not, the new level and Mario, the viewport and its texture (identity and RID), what its atlas cell draws (the world's
## screen or a preview frame), whether a legacy preview track exists for it, and which stage courses BattlePreviewStages
## was asked for. Saves the cells and the worlds' screens as PNGs before the flag, in the fade and after the cut.
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility \
##     --resolution 1920x1080 --fixed-fps 60 -s tests/tools/battle_bot_transition_trace.gd -- --battle-real-bots=4 out=/tmp/trace
## Given `--battle-real-bots=4` BEFORE the `--`, the build of b4305e3 read 0 and every opponent was a legacy preview (the trace then
## follows the legacy tracks of 1-4 and shows the stand-in each is drawn with after its clear: 3-2 in World 3's snow theme).
## Options (after `--`): `--battle-real-bots=N` (as the game reads it), `out=DIR` (PNGs, never into the repository),
## `natural=1` (let the brains reach the flag themselves; default: each bot's Mario is put on the ground just before the
## pole once it has played 2 s, and runs and jumps at it), `seconds=S` (how long to run, default 40).

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"

var G
var S
var BS
var ROUND
var DIRECTOR
var ATLAS
var WORLD
var STAGES
var HANDLER
var out_dir := ""
var natural := false
var seconds := 40.0
var log_lines: PackedStringArray = []

func frames(n: int) -> void:
	for i in n:
		await process_frame

func wait_until(cond: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func say(s: String) -> void:
	print(s)
	log_lines.append(s)

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			out_dir = a.substr(4)
		elif a == "natural=1":
			natural = true
		elif a.begins_with("seconds="):
			seconds = a.substr(8).to_float()
	_run()

func cell_image(scr, id: int) -> Image:
	return scr.atlas.get_texture().get_image().get_region(ATLAS.cell_rect(id - 1))

## What the cell of `id` is drawing from, as plain facts.
func cell_source(scr, id: int) -> Dictionary:
	var cell = scr.cells[id - 1]
	var tracked: bool = scr.driver != null and scr.driver.tracks.has(id)
	return {"is_bot": cell.is_bot(), "is_live": cell.is_live(), "bot_iid": cell.bot.get_instance_id() if cell.is_bot() else 0,
		"track": tracked, "stage_query": scr.driver != null and scr.driver.stages.queried_for(id), "course_index": cell.course_index(),
		"drew": cell.last_source.get("kind", "")}

func world_facts(w) -> Dictionary:
	var vp = w.viewport
	var tex = vp.get_texture() if vp != null else null
	return {"world_iid": w.get_instance_id(), "course": w.course, "scene": w.scene_path.get_file(), "phase": WORLD.Phase.keys()[w.phase],
		"level_iid": w.level.get_instance_id() if is_instance_valid(w.level) else 0,
		"level_file": w.level.scene_file_path.get_file() if is_instance_valid(w.level) else "",
		"player_iid": w.player.get_instance_id() if is_instance_valid(w.player) else 0,
		"player_in_level": is_instance_valid(w.player) and w.player.get_parent() == w.level,
		"x": w.player.global_position.x if is_instance_valid(w.player) else 0.0,
		"vp_iid": vp.get_instance_id() if vp != null else 0, "vp_rid": vp.get_viewport_rid().get_id() if vp != null else 0,
		"tex_rid": tex.get_rid().get_id() if tex != null else 0, "theme": w.theme, "fade": w.fade, "ticks": w.ticks, "frozen": w.frozen,
		"world_mode": w.process_mode, "level_mode": w.level.process_mode if is_instance_valid(w.level) else -1,
		"state": w.player.state_machine.get_state() if is_instance_valid(w.player) else "", "vx": w.player.velocity.x if is_instance_valid(w.player) else 0.0,
		"tree_paused": paused, "can_process": w.can_process()}

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	ATLAS = load("res://Scripts/Classes/Battle/BattlePreviewAtlas.gd")
	WORLD = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	STAGES = load("res://Scripts/Classes/Battle/BattlePreviewStages.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	ROUND.pre_round_override = 0.3
	HANDLER.seed_source = func() -> int: return 11
	say("cmdline args %s | user args %s | BattleBotDirector.count() = %d, real_ids %s" % [OS.get_cmdline_args(), OS.get_cmdline_user_args(),
		DIRECTOR.count(), DIRECTOR.real_ids()])
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	await wait_until(func(): return BS.is_active() and BS.instance.driver != null and BS.instance.battle_round.state == ROUND.State.PLAYING, 1500)
	var scr = BS.instance
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
	var real: Array = DIRECTOR.real_ids()
	say("real ids %s | director %s | world-driven in session %s | legacy tracks %d (ids %s..%s)" % [real, scr.bots,
		scr.session.contestants.filter(func(c): return c.world_driven).map(func(c): return c.id), scr.driver.tracks.size(),
		scr.driver.tracks.keys().min(), scr.driver.tracks.keys().max()])
	# Keep the real player in the round (it stands still at the start; the round must not end while the bots play).
	var real_player = scr.game_scene.get_node_or_null("Player") if scr.game_scene != null else null
	if real_player != null:
		real_player.can_hurt = false
	var stage_log := {}
	var prev := {}
	var old_levels := {} ## id -> WeakRef of the level it left
	var cut_frame := {}
	var placed := {}
	for id in real:
		var w = scr.bots.world(id) if scr.bots != null else null
		if w == null:
			say("id %d: NO BattleBotWorld - its pane is %s" % [id, cell_source(scr, id)])
			continue
		prev[id] = world_facts(w)
		say("id %d start: %s | cell %s" % [id, prev[id], cell_source(scr, id)])
		if out_dir != "":
			cell_image(scr, id).save_png(out_dir.path_join("id%d_0_cell_start.png" % id))
	# Opponents 1-4 that have no world (the flag did not reach the game): what their legacy previews show.
	var legacy_prev := {}
	var legacy_shot := {}
	for id in [1, 2, 3, 4]:
		if not real.has(id) and scr.driver.tracks.has(id):
			var tr = scr.driver.tracks[id]
			legacy_prev[id] = [tr.course, tr.stage_geometry]
			say("id %d: LEGACY preview (BattlePreviewTrack on course %d, drawn from course %d's sketch) | cell %s" % [id, tr.course, tr.stage_geometry,
				cell_source(scr, id)])
	var total := int(seconds * 60.0)
	for f in total:
		await process_frame
		if scr.battle_round.state != ROUND.State.PLAYING:
			say("frame %d: the round left PLAYING (%s)" % [f, ROUND.State.keys()[scr.battle_round.state]])
			break
		for id in legacy_prev:
			var tr = scr.driver.tracks[id]
			if [tr.course, tr.stage_geometry] != legacy_prev[id]:
				legacy_prev[id] = [tr.course, tr.stage_geometry]
				var level_name := load("res://Scripts/Classes/Battle/BattleCourse.gd").text(tr.stage_geometry) as String
				say("frame %d id %d: legacy track entered course %d (session cleared %d); its picture is course %d's sketch (%s, world %d theme %s)%s | cell %s" % [
					f, id, tr.course, scr.session.contestants[id].levels_cleared, tr.stage_geometry, level_name,
					1 + tr.stage_geometry / 4, load("res://Scripts/Classes/LevelClass.gd").SMB1_THEMES.get(1 + tr.stage_geometry / 4, "?"),
					" = STAND-IN" if tr.stage_geometry != tr.course else "", cell_source(scr, id)])
				legacy_shot[id] = f + 30
			if legacy_shot.get(id, -1) == f and out_dir != "":
				cell_image(scr, id).save_png(out_dir.path_join("legacy_id%d_course%d.png" % [id, tr.course]))
		# Which stage courses the legacy previews have built so far (they are per course, shared by every track).
		if scr.driver != null:
			for c in scr.driver.stages._stages.keys():
				if not stage_log.has(c):
					stage_log[c] = f
					var st = scr.driver.stages._stages[c]
					say("frame %d: legacy BattlePreviewStages built course %d (geometry %s, stand-in %s)" % [f, c, st.geometry if st != null else -1,
						st.stand_in if st != null else "-"])
		for id in prev:
			var w = scr.bots.world(id)
			if not natural and not placed.has(id) and w.ticks > 120 and w.course == 0 and w.phase == WORLD.Phase.PLAYING and is_instance_valid(w.player):
				placed[id] = true
				var pole_x: float = w._goal_x
				w.player.global_position = Vector2(pole_x - 40.0 - id * 6.0, w.player.global_position.y)
				w.player.velocity = Vector2.ZERO
				w.script_buttons = func(ww) -> Dictionary: return {"move_right": true, "jump": ww.ticks % 40 < 25}
				say("frame %d id %d: Mario put on the ground at x %.0f, %.0f px before 1-1's pole, running and jumping at it" % [f, id, w.player.global_position.x,
					pole_x - w.player.global_position.x])
			var now := world_facts(w)
			var p: Dictionary = prev[id]
			if now.course != p.course or now.phase != p.phase or now.level_iid != p.level_iid or now.vp_rid != p.vp_rid or now.tex_rid != p.tex_rid:
				say("frame %d id %d: %s -> %s | cell %s" % [f, id, _diff(p, now), now.phase, cell_source(scr, id)])
				if now.phase == "FADING" and p.phase != "FADING" and out_dir != "":
					cell_image(scr, id).save_png(out_dir.path_join("id%d_1_cell_flag.png" % id))
				if now.level_iid != p.level_iid and p.level_iid != 0:
					old_levels[id] = w.transitions[-1].old_level # (the world's own record: a weak reference taken before the swap)
					cut_frame[id] = f
					say("    requested next course %d (%s) -> loaded %s | new level %s in viewport: %s | Mario %d (was %d) in level: %s" % [
						p.course + 1, load("res://Scripts/Classes/Battle/BattleCourse.gd").scene_path(p.course + 1).get_file(), now.level_file,
						now.level_iid, is_instance_valid(w.level) and w.level.get_parent() == w.viewport, now.player_iid, p.player_iid, now.player_in_level])
				if now.phase == "PLAYING" and is_instance_valid(w.player) and w.script_buttons.is_valid() and w.course > 0:
					w.script_buttons = Callable() # the brain plays the new course
			prev[id] = now
			if f % 120 == 0:
				say("frame %d id %d: %s" % [f, id, now])
			if cut_frame.has(id):
				var since: int = f - cut_frame[id]
				if since == 2:
					var o = old_levels.get(id)
					say("    id %d +2 frames: old level freed: %s" % [id, o == null or o.get_ref() == null])
				if since in [10, 60, 180] and out_dir != "":
					cell_image(scr, id).save_png(out_dir.path_join("id%d_2_cell_after_cut_%03d.png" % [id, since]))
					w.viewport.get_texture().get_image().save_png(out_dir.path_join("id%d_2_screen_after_cut_%03d.png" % [id, since]))
				if since == 180:
					say("    id %d +180 frames: %s | cell %s" % [id, world_facts(w), cell_source(scr, id)])
	for id in prev:
		var w = scr.bots.world(id)
		say("id %d end: %s | cell %s" % [id, world_facts(w), cell_source(scr, id)])
	if out_dir != "":
		var f2 := FileAccess.open(out_dir.path_join("trace.txt"), FileAccess.WRITE)
		f2.store_string("\n".join(log_lines))
		f2.close()
	HANDLER.seed_source = Callable()
	ROUND.pre_round_override = -1.0
	HANDLER.quit_battle()
	await wait_until(func(): return on_title(), 900)
	var out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	out.store_string(saved_settings_file)
	out.close()
	quit(0)

func _diff(a: Dictionary, b: Dictionary) -> String:
	var parts: PackedStringArray = []
	for k in ["course", "scene", "phase", "level_iid", "player_iid", "vp_rid", "tex_rid", "theme"]:
		if a[k] != b[k]:
			parts.append("%s %s->%s" % [k, a[k], b[k]])
	return ", ".join(parts)
