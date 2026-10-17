class_name BattleIncomingStrip
extends Control
## The real player's incoming enemies, in the bar under the game window (doc 47 B35-INCOMING-001, the reference's strip A), as measured on
## the reference at 60 fps (doc 54). The bar is three zones, gold on the left, orange, then darker orange, split by two jagged boundaries (a
## zig-zag of two teeth, 3 units deep) at x 202.6 and 288.0 on the canvas. The player's own icon, in its current power state, stands at the
## left end of the gold zone. An enemy icon is a bare sprite about 8 units wide (no plate, no outline, no text):
##   it appears at the bar's RIGHT end the moment the enemy is sent (its attack's `sent` time), and travels LEFT at a constant speed
##   (the reference's is 47 units/s, tied here to the attack system's own ACTIVATION_DELAY so it gets to the boundary as the attack
##   becomes ACTIVE), a queue of icons keeping one PITCH apart;
##   it waits at the gold boundary while it is ACTIVE and its enemy is not in the level yet (ARRIVING);
##   when its enemy appears in the level (IN_LEVEL) it crosses the boundary and is GONE: the reference removes an icon at that moment,
##   with no flash and nothing left behind. (M6b kept a marker in the gold zone for as long as the enemy lived; doc 54 removes it:
##   `place_all` and `_draw` are the only places that would bring it back.)
## An icon's phase is BattleAttackPresentation.Phase, derived from the session's own state (never stored here), and its place is a pure
## function of the phase and the row's ages (`place_all`), so the bar always matches the authoritative queue. `rows` and `counts` are
## exactly the session's unresolved attacks. There are no words and no counts on the bar (the reference has none); the old legend is kept
## for the debug-label mode (`show_legend`).
##
## Nothing here reaches the game: the strip never spawns, resolves or times anything.

const Phase := BattleAttackPresentation.Phase

# ---- colours (measured: the three zones' flat fills) ----------------------------------------------------------------
const ZONE_GOLD := Color8(255, 189, 9)
const ZONE_ORANGE := Color8(255, 118, 0)
const ZONE_DARK := Color8(245, 85, 17)
const LABEL := Color(1.0, 0.9, 0.6, 1)
const FLASH := Color(1, 1, 1, 1)
const TEXT_QUEUED := Color(0.85, 0.7, 0.55, 1)
const TEXT_ARRIVING := Color(1.0, 0.78, 0.3, 1)
const TEXT_IN_LEVEL := Color(1.0, 0.45, 0.35, 1)

# ---- geometry (strip-local, 257 x 12) --------------------------------------------------------------------------------
const GOLD_FRACTION := 0.3545 ## where the gold zone ends: x 202.6 on the canvas, measured (the zig-zag runs 201.0-204.25)
const ORANGE_FRACTION := 0.6868 ## where the orange zone ends: x 288.0 (286.5-289.6)
const TOOTH_DEPTH := 3.2 ## how far the zig-zag swings across a boundary
const ICON_W := 8.0 ## an enemy icon's width: a 16 x 16 sprite at half size
const PITCH := 10.8 ## between neighbouring waiting icons
const PLAYER_X := 2.0 ## the player's icon's left edge
const WAIT_OFFSET := 8.0 ## from the boundary to the centre of the first waiting icon
const ENTRY_INSET := 4.5 ## the right end's icon centre, from the strip's right edge
const MAX_WAITING := 14
const TRAVEL_SECONDS := float(BattleAttackSystem.ACTIVATION_DELAY) ## from the send to the boundary: the attack's own activation delay
const CATCH_UP_SECONDS := 0.3 ## an ACTIVE icon that is not at the boundary yet (the sim ran ahead of the clock) gets there in this long
const CROSS_SPEED := 47.0 ## units/s an icon runs across the boundary when its enemy appears (the reference's travel speed, measured)
const FOLLOW := 1.5 ## the drawn icon may move this many times the travel speed to catch its place (a queue closing up)
const TEXT_SCALE := 0.6
const TEXT_GAP := 6.0
const RIGHT_PAD := 3.0

var view: BattleAttackPresentation = null
var assets: BattlePreviewAssets = null
var font: Font = null
var power := 0 ## the real player's power state (0 small, 1 big, 2 fire), for the icon at the left end
var show_legend := false ## debug-label mode: the old "IN LEVEL 1 / ARRIVING 2 / QUEUED 3" counts at the right end
var rows: Array[Dictionary] = [] ## what the strip counts: the real player's unresolved attacks at the last sync
var counts := Vector2i.ZERO ## (queued, active) at the last sync
var phases := Vector3i.ZERO ## (queued, arriving, in level) at the last sync: `counts.y` split in two
var ghosts: Array[Dictionary] = [] ## attacks that just ended (data for the HUD's readers; the reference draws nothing for them)
var items: Array[Dictionary] = [] ## what is drawn, in send order: the `rows`

var _signature := -1
var _shown := {} ## seq -> the x its icon is drawn at (it follows `place_all`'s place at a bounded speed)
var _last_clock := -1.0

func _init(font_: Font = null) -> void:
	name = "IncomingStrip"
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func bind(view_: BattleAttackPresentation, assets_: BattlePreviewAssets) -> void:
	view = view_
	assets = assets_
	_signature = -2
	_shown.clear()
	_last_clock = -1.0
	sync()

## The player's power state, for the icon at the left end (0 small, 1 big, 2 fire).
func set_power(power_: int) -> void:
	if power_ != power:
		power = power_
		queue_redraw()

## Reads the presentation (every frame). Redraws when the list changed, and every frame while anything moves.
func sync() -> void:
	if view == null:
		rows.clear()
		ghosts.clear()
		counts = Vector2i.ZERO
		phases = Vector3i.ZERO
		_shown.clear()
	else:
		rows = view.player_incoming()
		ghosts = view.player_resolved()
		counts = view.counts(BattleSession.PLAYER_ID)
		phases = view.player_phase_counts()
	items = rows.duplicate()
	var moving := _follow()
	var sig := rows.size() * 7 + counts.x * 131 + counts.y * 1031 + power * 65537
	for r in rows:
		sig = sig * 31 + int(r.seq) * 3 + int(r.phase)
	if moving:
		sig = -3 - Engine.get_process_frames() # something is moving: redraw every frame
	if sig != _signature:
		_signature = sig
		queue_redraw()

## Moves every drawn icon towards its place (`place_all`) by at most FOLLOW * the travel speed per second of presentation time.
## Returns whether any icon is still on its way (or about to leave).
func _follow() -> bool:
	var dt := 0.0
	if view != null:
		dt = clampf(view.clock - _last_clock, 0.0, 0.25) if _last_clock >= 0.0 else 0.0
		_last_clock = view.clock
	var xs := place_all(items, size.x)
	var keep := {}
	var moving := false
	var step := FOLLOW * travel_speed(size.x) * dt
	for i in items.size():
		var seq := int(items[i].seq)
		keep[seq] = true
		var target := xs[i]
		var cur: float = _shown.get(seq, entry_x(size.x))
		if dt <= 0.0 and not _shown.has(seq):
			cur = target # a presentation made mid-round: the icons are where they belong
		var nxt := target if absf(target - cur) <= step else cur + signf(target - cur) * step
		_shown[seq] = nxt
		var leaving := int(items[i].phase) == Phase.IN_LEVEL
		# (an icon that has caught up with a target that is itself still travelling is moving: it must be redrawn next frame too)
		if absf(target - nxt) > 0.01 or (leaving and crossed(items[i]) < 1.0) or (not leaving and progress_of(items[i]) < 1.0):
			moving = true
	for seq in _shown.keys():
		if not keep.has(seq):
			_shown.erase(seq)
	return moving

## `rows` as the list the strip draws (an ended attack leaves with no fade: the reference has none). Kept for the readers that merge both.
static func merged(rows_: Array[Dictionary], _ghosts: Array[Dictionary] = []) -> Array[Dictionary]:
	return rows_.duplicate()

## The counts per phase as text pieces, in the order the icons run: [{text, phase}]. Only phases that have any.
## `short` uses the abbreviations for a crowded strip.
static func legend(phases_: Vector3i, short := false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if phases_.z > 0:
		out.append({"text": ("LVL %d" if short else "IN LEVEL %d") % phases_.z, "phase": Phase.IN_LEVEL})
	if phases_.y > 0:
		out.append({"text": ("ARR %d" if short else "ARRIVING %d") % phases_.y, "phase": Phase.ARRIVING})
	if phases_.x > 0:
		out.append({"text": ("Q %d" if short else "QUEUED %d") % phases_.x, "phase": Phase.QUEUED})
	return out

# ---- where icons are (pure) ---------------------------------------------------------------------------------------

## The x of the gold boundary's centre in a strip `width` wide.
static func gold_end(width: float) -> float:
	return width * GOLD_FRACTION

## The x of the orange / dark boundary's centre.
static func orange_end(width: float) -> float:
	return width * ORANGE_FRACTION

## Where the right end's icons come in.
static func entry_x(width: float) -> float:
	return width - ENTRY_INSET

## The speed icons travel at, units per second: from the entry to the first waiting place in TRAVEL_SECONDS (the reference's own is 47).
static func travel_speed(width: float) -> float:
	return (entry_x(width) - gold_end(width) - WAIT_OFFSET) / TRAVEL_SECONDS

## The centre x of each item of `items_` (in send order) in a strip `width` wide, at this instant, by phase: an icon travelling from the
## right end at a constant speed to its place in the queue right of the gold boundary (the front one waits WAIT_OFFSET past it, the
## others one PITCH behind each other); an ACTIVE icon is there at the latest CATCH_UP_SECONDS after it became ACTIVE; an icon whose
## enemy is in the level (IN_LEVEL) is crossing the boundary and leaves it (`crossed`).
static func place_all(items_: Array, width: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var boundary := gold_end(width)
	var entry := entry_x(width)
	var waiting := 0
	for it in items_:
		var slot := boundary + WAIT_OFFSET + mini(waiting, MAX_WAITING - 1) * PITCH
		if int(it.phase) == Phase.IN_LEVEL:
			out.append(lerpf(slot, boundary, crossed(it))) # the enemy appeared: the icon runs on across the boundary and is gone
			continue
		waiting += 1
		out.append(lerpf(entry, slot, progress_of(it)))
	return out

## 0..1: how far an icon that is not in the level has travelled from the right end to its place (linear in time: constant speed).
static func progress_of(it: Dictionary) -> float:
	var p := clampf(float(it.get("age", 0.0)) / TRAVEL_SECONDS, 0.0, 1.0)
	var waited := float(it.get("waited", -1.0))
	if waited >= 0.0:
		p = maxf(p, clampf(waited / CATCH_UP_SECONDS, 0.0, 1.0))
	return p

## 0..1: how far an IN_LEVEL icon has run across the boundary since its enemy appeared (at travel speed); 1 and it is not drawn.
static func crossed(it: Dictionary) -> float:
	var elapsed := (1.0 - float(it.get("arrive", 0.0))) * BattleAttackPresentation.SPAWN_FLASH
	return clampf(elapsed * CROSS_SPEED / WAIT_OFFSET, 0.0, 1.0)

# ---- drawing ------------------------------------------------------------------------------------------------------

func _draw() -> void:
	_zones()
	_player_icon()
	var end_x := 0.0
	for it in items:
		var cx: float = _shown.get(int(it.seq), place_all([it], size.x)[0])
		if int(it.phase) == Phase.IN_LEVEL and crossed(it) >= 1.0:
			continue # released: the reference removes the icon
		_icon(it, cx)
		end_x = maxf(end_x, cx + ICON_W)
	if show_legend:
		_draw_legend(end_x + 3.0)

## A jagged vertical boundary centred at `x`: the polygon points from the top to the bottom edge, a zig-zag of two teeth swinging
## TOOTH_DEPTH across (measured: leftmost at 29% and 84% of the height, rightmost at the top, at 58% and, half way, at the bottom).
static func jagged(x: float, height: float) -> PackedVector2Array:
	var left := x - TOOTH_DEPTH / 2.0
	return PackedVector2Array([Vector2(left + TOOTH_DEPTH * 0.92, 0.0), Vector2(left, height * 0.29),
		Vector2(left + TOOTH_DEPTH, height * 0.58), Vector2(left, height * 0.84), Vector2(left + TOOTH_DEPTH * 0.45, height)])

func _zones() -> void:
	var h := size.y
	var b1 := gold_end(size.x)
	var b2 := orange_end(size.x)
	draw_rect(Rect2(Vector2.ZERO, size), ZONE_DARK)
	var orange := jagged(b1, h)
	var back := jagged(b2, h)
	back.reverse()
	orange.append_array(back)
	draw_colored_polygon(orange, ZONE_ORANGE)
	var gold := PackedVector2Array([Vector2(0, 0)])
	gold.append_array(jagged(b1, h))
	gold.append(Vector2(0, h))
	draw_colored_polygon(gold, ZONE_GOLD)

## The player's icon at the left end, in its power state.
func _player_icon() -> void:
	var spr: BattlePreviewSprite = assets.mario_frame_at(power, "Idle", 0) if assets != null else null
	var feet := Vector2(PLAYER_X + 7.0, size.y - 0.5)
	if spr != null:
		var s := minf(0.7, (size.y - 1.0) / maxf(spr.size.y, 1.0))
		draw_texture_rect(spr.texture, Rect2(feet + spr.offset * s, spr.size * s), false)
		return
	draw_rect(Rect2(feet + Vector2(-4, -10.5), Vector2(8, 3)), Color(0.85, 0.15, 0.1))
	draw_rect(Rect2(feet + Vector2(-3, -7.5), Vector2(6, 3)), Color(0.98, 0.76, 0.52))
	draw_rect(Rect2(feet + Vector2(-4, -4.5), Vector2(8, 4)), Color(0.2, 0.3, 0.85) if power < 2 else Color(1.0, 0.95, 0.9))

## One enemy icon: the bare sprite, standing on the bar's bottom edge (the reference draws nothing round it).
func _icon(item: Dictionary, cx: float) -> void:
	var t := view.clock * 5.0 if view != null else 0.0
	BattleEnemyIcon.draw(self, item.kind, Vector2(cx, size.y - 0.6), 0.5, assets, t, 1.0, size.y - 1.0)

func _draw_legend(left_limit: float) -> void:
	if font == null:
		return
	var tokens := legend(phases)
	if _legend_width(tokens) > size.x - RIGHT_PAD - left_limit:
		tokens = legend(phases, true)
	var x := size.x - RIGHT_PAD - _legend_width(tokens)
	for tk in tokens:
		var c := _phase_text_color(int(tk.phase))
		var glow := _glow(int(tk.phase))
		if glow > 0.0:
			c = c.lerp(FLASH, glow)
		_text(String(tk.text), Vector2(x, 3.0), c)
		x += _text_width(String(tk.text)) + TEXT_GAP

func _legend_width(tokens: Array[Dictionary]) -> float:
	var w := 0.0
	for tk in tokens:
		w += _text_width(String(tk.text))
	return w + TEXT_GAP * maxf(tokens.size() - 1, 0)

## How lit a phase's count is: ARRIVING while an icon just became ACTIVE, IN LEVEL while one just appeared.
func _glow(phase: int) -> float:
	var g := 0.0
	for r in rows:
		if phase == Phase.ARRIVING and int(r.phase) == Phase.ARRIVING:
			g = maxf(g, r.flash)
		elif phase == Phase.IN_LEVEL and int(r.phase) == Phase.IN_LEVEL:
			g = maxf(g, r.arrive)
	return g

static func _phase_text_color(phase: int) -> Color:
	match phase:
		Phase.IN_LEVEL:
			return TEXT_IN_LEVEL
		Phase.ARRIVING:
			return TEXT_ARRIVING
	return TEXT_QUEUED

static func _alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * clampf(a, 0.0, 1.0))

func _time() -> float:
	return view.clock if view != null else 0.0

func _text_width(text: String) -> float:
	return BattleHudText.ink_width(text, TEXT_SCALE)

func _text(text: String, top_left: Vector2, color: Color) -> void:
	BattleHudText.draw(self, font, text, Vector2(top_left.x, (size.y - BattleHudText.ink_height(TEXT_SCALE)) / 2.0), TEXT_SCALE, color)
