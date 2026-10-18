extends SceneTree
## The real player's stomps and a real opponent's stomps make the same send ghost (doc 57), in the full Battle screen. The real
## player's Mario stomps a real Goomba and a real Koopa of the real 1-1 in the game window; a real opponent's Mario (a BattleBotWorld)
## stomps a real Goomba and a real Koopa of its own 1-1. Each stomp goes the game's own way to the session (Enemy.report_battle_defeat,
## BattleSession.report_enemy_kill, one SENT event), and from that event the screen draws its ghost with the same code:
##   - one ghost per SENT, whoever sent it, from the session's event (sender, recipient, enemy type);
##   - the same picture (the enemy's own ghost sprite), the same body size, the same straight constant-speed path of 30 frames, the
##     same burst on the recipient's pane on frame 30, for 11 frames; only the start differs: the middle of the game window for the
##     real player, the middle of the sender's pane for a bot;
##   - each is seen leaving its sender: the real player's in the game window, the bot's in its pane; both arrive on the recipient's;
##   - rapid sends overlap, each on its own clock; the pause holds them; the round's end clears them.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_send_ghost_game_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled before the autoloads exist).

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const GOOMBA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"
const RECIPIENT := 9
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 9
func choose(session, sender, _draw) -> int:
	if sender != target:
		return target
	for c in session.contestants:
		if c.alive and c.id != sender:
			return c.id
	return -1
"""

var failures := 0
var G
var S
var BS
var ROUND
var DIRECTOR
var HANDLER
var SESSION
var GHOST
var GEOM
var TYPES
var FixedPolicy

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

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

func scr():
	return BS.instance

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	GHOST = load("res://Scripts/Classes/Battle/BattleSendGhost.gd")
	GEOM = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	ROUND.pre_round_override = 0.3
	HANDLER.seed_source = func() -> int: return 23
	DIRECTOR.count_override = 1
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return BS.is_active() and scr().bots != null and scr().attack_view != null \
		and scr().battle_round.state == ROUND.State.PLAYING and is_instance_valid(G.current_level), 1500)
	check(up, "Battle runs with the real player and one real opponent")
	if up:
		scr().session.attacks.bots_send = false # (only the stomps below send)
		scr().session.attacks.targeting = FixedPolicy.new() # every send goes to opponent 9
		G.current_level.get_node("Player").can_hurt = false
		await frames(5)
		await test_same_ghost(TYPES.Kind.GOOMBA, GOOMBA_SCRIPT, "Goomba")
		await test_same_ghost(TYPES.Kind.KOOPA, KOOPA_SCRIPT, "Koopa")
		await test_rapid_pause_and_end()
	DIRECTOR.count_override = -1
	ROUND.pre_round_override = -1.0
	HANDLER.seed_source = Callable()
	HANDLER.quit_battle()
	await wait_until(func(): return on_title(), 900)
	var out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	out.store_string(saved_settings_file)
	out.close()
	if failures > 0:
		printerr("%d Battle send ghost game test(s) failed" % failures)
	else:
		print("All Battle send ghost game tests passed")
	quit(1 if failures > 0 else 0)

# ---- helpers ------------------------------------------------------------------------------------------------------------------

func real_player():
	return G.current_level.get_node("Player")

## The first live enemy with `script_path` in `level` (a level's own, as authored).
func enemy_in(level: Node, script_path: String):
	for n in level.find_children("*", "CharacterBody2D", true, false):
		if n.get_script() != null and (n.get_script() as Script).resource_path == script_path and not n.is_queued_for_deletion() and not n.get("dead"):
			return n
	return null

## The SENT events logged since event index `from`, as [sender, seq, target, kind].
func sends_since(from: int) -> Array:
	var out := []
	var ev: Array = scr().session.events
	for i in range(from, ev.size()):
		if ev[i].type == SESSION.EventType.SENT:
			out.append([int(ev[i].id), int(ev[i].a), int(ev[i].b), int(ev[i].kind)])
	return out

func ghost_of_seq(seq: int) -> Dictionary:
	for g in scr().attack_view.send_ghosts():
		if int(g.seq) == seq:
			return g
	return {}

func inside(r: Rect2, box: Rect2) -> bool:
	return box.grow(0.01).encloses(r)

# ---- the same ghost for the real player's stomp and a bot's ---------------------------------------------------------------------

func test_same_ghost(kind: int, script_path: String, label: String) -> void:
	print("-- a %s stomped by the real player and one stomped by a real opponent: the same send ghost" % label)
	var w = scr().bots.world(1)
	var human_enemy = enemy_in(G.current_level, script_path)
	var bot_enemy = enemy_in(w.level, script_path)
	check(human_enemy != null and bot_enemy != null, "the real 1-1 in the window and the opponent's own 1-1 each have a real %s" % label)
	if human_enemy == null or bot_enemy == null:
		return
	var from: int = scr().session.events.size()
	# The game's own stomps: each enemy's stomp handler with the Mario of its own game.
	human_enemy.stomped_on(real_player())
	bot_enemy.stomped_on(w.player)
	await wait_until(func(): return sends_since(from).size() >= 2, 10)
	var sent: Array = sends_since(from)
	var human: Array = sent.filter(func(e): return e[0] == 0)
	var bot: Array = sent.filter(func(e): return e[0] == 1)
	check(human.size() == 1 and human[0][2] == RECIPIENT and human[0][3] == kind,
		"the real player's %s stomp is one authoritative SENT (0 -> #%d, %s)" % [label, RECIPIENT, label])
	check(bot.size() == 1 and bot[0][2] == RECIPIENT and bot[0][3] == kind,
		"the real opponent's %s stomp is one authoritative SENT (1 -> #%d, %s)" % [label, RECIPIENT, label])
	if human.size() != 1 or bot.size() != 1:
		return
	var hs: int = human[0][1]
	var bs: int = bot[0][1]
	var layout: Dictionary = scr().layout
	var layer = scr().ghost_layer
	var game: Rect2 = layout.game
	var own_pane: Rect2 = layout.slots[0]
	var target_pane: Rect2 = layout.slots[RECIPIENT - 1]
	# Follow both, frame by frame, through the screen's own presentation clock.
	var h_flight := {} ## the frames of its life it was in the air
	var b_flight := {}
	var h_flash := []
	var b_flash := []
	var same_look := true
	var on_path := true
	var h_leaves_window := false
	var b_leaves_pane := false
	var h_arrives := false
	var b_arrives := false
	var h_frame := -1
	var b_frame := -1
	for f in 50:
		var hg := ghost_of_seq(hs)
		var bg := ghost_of_seq(bs)
		if not hg.is_empty():
			var age: float = hg.age
			h_frame = roundi(age * GHOST.FPS) # the frame of its own life this is (0 = the frame it was sent)
			if GHOST.in_flight(age):
				h_flight[h_frame] = true
				var look: Dictionary = layer.ghost_look(hg)
				if not bg.is_empty() and GHOST.in_flight(float(bg.age)):
					var blook: Dictionary = layer.ghost_look(bg)
					same_look = same_look and look.art == blook.art and look.art != null and look.rect.size.is_equal_approx(blook.rect.size) \
						and is_equal_approx(float(hg.age), float(bg.age))
				var p: float = GHOST.progress(age)
				on_path = on_path and look.rect.get_center().is_equal_approx(GEOM.center_of(layout, 0).lerp(target_pane.get_center(), p))
				if h_frame <= 2 and not look.pieces.is_empty() and inside(look.pieces[0][0], game):
					h_leaves_window = true
				if h_frame >= 27 and look.pieces.any(func(c): return inside(c[0], target_pane)):
					h_arrives = true
			var k: int = GHOST.flash_frame(age)
			if k >= 0:
				h_flash.append([h_frame, k])
		if not bg.is_empty():
			var bage: float = bg.age
			b_frame = roundi(bage * GHOST.FPS)
			if GHOST.in_flight(bage):
				b_flight[b_frame] = true
				var blook2: Dictionary = layer.ghost_look(bg)
				var bp: float = GHOST.progress(bage)
				on_path = on_path and blook2.rect.get_center().is_equal_approx(GEOM.center_of(layout, 1).lerp(target_pane.get_center(), bp))
				if b_frame <= 2 and not blook2.pieces.is_empty() and inside(blook2.pieces[0][0], own_pane):
					b_leaves_pane = true
				if b_frame >= 27 and blook2.pieces.any(func(c): return inside(c[0], target_pane)):
					b_arrives = true
			var bk: int = GHOST.flash_frame(bage)
			if bk >= 0:
				b_flash.append([b_frame, bk])
		await process_frame
	# (Frame 30 is the arrival: the presentation clock's sum of 30 sixtieths is a hair under 0.5, so the ghost is drawn at the recipient's
	# middle under the burst's first frame. That is the established behaviour of every ghost, the bots' included; it is the same here.)
	var flew := range(30).all(func(i): return h_flight.has(i)) and h_flight.size() <= 31
	check(flew and h_flight.keys() == b_flight.keys(), "both fly the same frames of their lives, 0-29 and their arrival (real player %s, opponent %s)" % [
		h_flight.size(), b_flight.size()])
	check(same_look, "frame for frame the same picture (the %s's own ghost) at the same size and the same age" % label)
	check(on_path, "each on a straight constant-speed line from its sender's middle (the window's / the pane's) to the recipient's pane")
	check(h_leaves_window, "the real player's ghost is seen leaving the middle of the game window (drawn inside the window)")
	check(b_leaves_pane, "the opponent's ghost is seen leaving the middle of its pane")
	check(h_arrives and b_arrives, "both are seen arriving on the recipient's pane")
	var h_burst: Array = h_flash.map(func(x): return x[1])
	var b_burst: Array = b_flash.map(func(x): return x[1])
	check(h_burst == range(11) and b_burst == range(11), "the same 11-frame burst on the recipient's pane (%s / %s)" % [h_burst, b_burst])
	check(not h_flash.is_empty() and not b_flash.is_empty() and h_flash[0][0] == 30 and b_flash[0][0] == 30,
		"the burst starts on frame 30 for both (%s, %s)" % [h_flash[0][0] if not h_flash.is_empty() else -1, b_flash[0][0] if not b_flash.is_empty() else -1])
	check(layer.shows_burst(RECIPIENT), "the recipient's pane takes the burst")
	check(ghost_of_seq(hs).is_empty() and ghost_of_seq(bs).is_empty(), "and both are gone after it")

# ---- rapid sends, pause, round end ------------------------------------------------------------------------------------------

func spawn_goomba() -> Node:
	var n: Node2D = load(GOOMBA_PREFAB).instantiate()
	n.position = Vector2(9000 + randi() % 1000, -600)
	G.current_level.add_child(n)
	n.process_mode = Node.PROCESS_MODE_DISABLED
	return n

func test_rapid_pause_and_end() -> void:
	print("-- the real player's rapid stomps: a ghost each, on its own clock; the pause holds them; the round's end clears them")
	var from: int = scr().session.events.size()
	spawn_goomba().stomped_on(real_player())
	await frames(6)
	spawn_goomba().stomped_on(real_player())
	await frames(1)
	var sent: Array = sends_since(from)
	check(sent.size() == 2 and sent.all(func(e): return e[0] == 0), "two stomps 6 frames apart: two SENTs from the real player")
	if sent.size() != 2:
		return
	var g1 := ghost_of_seq(sent[0][1])
	var g2 := ghost_of_seq(sent[1][1])
	check(not g1.is_empty() and not g2.is_empty() and float(g1.age) - float(g2.age) > 0.08, "two ghosts in the air at once, each with its own age (%.3f, %.3f)" % [
		float(g1.get("age", -1.0)), float(g2.get("age", -1.0))])
	paused = true
	var held: float = ghost_of_seq(sent[0][1]).age
	await frames(30)
	check(is_equal_approx(float(ghost_of_seq(sent[0][1]).age), held), "the pause holds them where they are")
	paused = false
	await frames(2)
	check(float(ghost_of_seq(sent[0][1]).get("age", 0.0)) > held, "and they carry on after it")
	scr().session.report_ko(0, SESSION.KoCause.HAZARD)
	scr().round_over(ROUND.End.DEATH)
	await wait_until(func(): return scr().field_frozen, 120)
	check(scr().attack_view.send_ghosts().is_empty() and scr().ghost_layer.drawn().is_empty(), "the round's end clears every ghost at once")
