class_name BattleIncomingStrip
extends Control
## The real player's incoming enemies, in the bar under the game window (doc 47 B35-INCOMING-001, the reference's
## strip A). The bar is three zones, gold on the left third, orange, then darker orange, split by jagged (three-tooth)
## boundaries. The player's own icon, in its current power state, stands at the left end of the gold zone. Enemy
## icons enter at the RIGHT end and travel LEFT to the gold boundary, which is where an enemy is released into the
## level; the ones the real game has released sit in the gold zone:
##   QUEUED (line in the air)  a hollow dotted placeholder at the right end: sent, not landed yet
##   QUEUED (landed)           travels left from the right end; it reaches the boundary after the attack system's own
##                             ACTIVATION_DELAY (counted from the send), a yellow outline pulses once as it lands
##   ARRIVING                  waits at the boundary (amber pulsing outline): ACTIVE, its enemy is not in the level yet;
##                             the icon flashes white as it becomes ACTIVE
##   IN_LEVEL                  crosses the boundary into the gold zone (white flash at the boundary) and stays there with a
##                             solid red outline: its one real enemy is in the player's level
##   RESOLVED                  the icon stays where it was and fades: green if the player defeated it, grey otherwise
## An icon's phase is BattleAttackPresentation.Phase, derived from the session's own state (never stored here), and its
## place is a pure function of the phase and the row's ages (`place_all`), so the bar always matches the authoritative
## queue. `rows` and `counts` are exactly the session's unresolved attacks; the fading icons are drawn in addition and
## are never in them. There are no words and no counts on the bar (the reference has none); the old legend is kept for
## the debug-label mode (`show_legend`).
##
## One deliberate difference from the reference, kept from M6b: the reference removes an icon when its enemy is
## released; here it stays in the gold zone as a marker for as long as that enemy is in the level, because that is how the
## player sees which incoming enemies are still alive.
##
## Nothing here reaches the game: the strip never spawns, resolves or times anything.

const Phase := BattleAttackPresentation.Phase

# ---- colours ------------------------------------------------------------------------------------------------------
const ZONE_GOLD := Color8(255, 208, 48)
const ZONE_ORANGE := Color8(255, 150, 28)
const ZONE_DARK := Color8(226, 104, 18)
const LABEL := Color(1.0, 0.9, 0.6, 1)
const QUEUED_FILL := Color(0.42, 0.28, 0.2, 0.9)
const ARRIVING_FILL := Color(0.86, 0.5, 0.08, 0.95)
const IN_LEVEL_FILL := Color(0.95, 0.2, 0.1, 0.95)
const DEFEATED_FILL := Color(0.2, 0.72, 0.3, 1)
const ENDED_FILL := Color(0.5, 0.55, 0.65, 1)
const FLASH := Color(1, 1, 1, 1)
const NEW_EDGE := Color(1.0, 0.95, 0.35, 1)
const IN_LEVEL_EDGE := Color(1.0, 0.85, 0.7, 1)
const ARRIVING_EDGE := Color(1.0, 0.8, 0.35, 1)
const TRANSIT_EDGE := Color(0.85, 0.7, 0.55, 1)
const TEXT_QUEUED := Color(0.85, 0.7, 0.55, 1)
const TEXT_ARRIVING := Color(1.0, 0.78, 0.3, 1)
const TEXT_IN_LEVEL := Color(1.0, 0.45, 0.35, 1)

# ---- geometry (strip-local, 257 x 12) --------------------------------------------------------------------------------
const GOLD_FRACTION := 1.0 / 3.0 ## where the gold zone ends
const ORANGE_FRACTION := 2.0 / 3.0 ## where the orange zone ends
const TEETH := 3 ## teeth of a jagged boundary over the bar's height
const TOOTH_DEPTH := 2.0
const ICON_W := 9.0
const PITCH := 10.0 ## between neighbouring icons
const PLAYER_X := 2.0 ## the player's icon's left edge
const IN_LEVEL_X0 := 20.0 ## centre of the first in-level marker
const WAIT_OFFSET := 8.0 ## from the boundary to the centre of the first waiting icon
const ENTRY_INSET := 7.0 ## the right end's icon centre, from the strip's right edge
const MAX_IN_LEVEL := 6
const MAX_WAITING := 14
const TRAVEL_SECONDS := BattleAttackSystem.ACTIVATION_DELAY - BattleAttackFlight.DURATION ## landing to the boundary
const CATCH_UP_SECONDS := 0.3 ## an ACTIVE icon that is not at the boundary yet (the sim ran ahead of the clock) gets there in this long
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
var ghosts: Array[Dictionary] = [] ## attacks that just ended, fading where their icon was (not in `rows`)
var items: Array[Dictionary] = [] ## what is drawn, in send order: `rows` and `ghosts` merged (a ghost has `ghost` = true)

var _signature := -1

func _init(font_: Font = null) -> void:
	name = "IncomingStrip"
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func bind(view_: BattleAttackPresentation, assets_: BattlePreviewAssets) -> void:
	view = view_
	assets = assets_
	_signature = -2
	sync()

## The player's power state, for the icon at the left end (0 small, 1 big, 2 fire).
func set_power(power_: int) -> void:
	if power_ != power:
		power = power_
		queue_redraw()

## Reads the presentation (every frame). Redraws when the list changed, and every frame while anything animates.
func sync() -> void:
	if view == null:
		rows.clear()
		ghosts.clear()
		counts = Vector2i.ZERO
		phases = Vector3i.ZERO
	else:
		rows = view.player_incoming()
		ghosts = view.player_resolved()
		counts = view.counts(BattleSession.PLAYER_ID)
		phases = view.player_phase_counts()
	items = merged(rows, ghosts)
	var sig := rows.size() * 7 + counts.x * 131 + counts.y * 1031 + ghosts.size() * 8191 + power * 65537
	for r in rows:
		sig = sig * 31 + int(r.seq) * 3 + int(r.phase)
	if view != null and (view.is_animating() or _travelling()):
		sig = -3 - Engine.get_process_frames() # animating: redraw every frame
	if sig != _signature:
		_signature = sig
		queue_redraw()

## Whether any icon is still travelling to the boundary (it moves every frame).
func _travelling() -> bool:
	for r in rows:
		if int(r.phase) == Phase.QUEUED and not r.in_transit and float(r.age) < TRAVEL_SECONDS + 0.1:
			return true
		if int(r.phase) != Phase.QUEUED and float(r.waited) >= 0.0 and float(r.waited) < CATCH_UP_SECONDS + 0.1:
			return true
	return false

## `rows` and `ghosts` (both in send order) as one list in send order. A ghost keeps the slot its attack had.
static func merged(rows_: Array[Dictionary], ghosts_: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i := 0
	var j := 0
	while i < rows_.size() or j < ghosts_.size():
		if j >= ghosts_.size() or (i < rows_.size() and int(rows_[i].seq) < int(ghosts_[j].seq)):
			out.append(rows_[i])
			i += 1
		else:
			var g: Dictionary = ghosts_[j].duplicate()
			g["ghost"] = true
			g["phase"] = Phase.RESOLVED
			out.append(g)
			j += 1
	return out

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

## Where the right end's icons come in.
static func entry_x(width: float) -> float:
	return width - ENTRY_INSET

## The centre x of each item of `items_` (a merged list, in send order) in a strip `width` wide, at this instant: by phase,
## in send order. In-level icons (and fading ghosts that were in the level) take the gold zone's slots in order; the
## rest take the slots right of the boundary in order; one still in the air waits at the right end; a landed one
## is on its way from the right end to its slot; one that became ACTIVE is there at the latest CATCH_UP_SECONDS later.
static func place_all(items_: Array, width: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var boundary := gold_end(width)
	var entry := entry_x(width)
	var in_level := 0
	var waiting := 0
	for it in items_:
		var in_gold := bool(it.get("spawned", false)) if it.get("ghost", false) else int(it.phase) == Phase.IN_LEVEL
		if in_gold:
			var slot := IN_LEVEL_X0 + mini(in_level, MAX_IN_LEVEL - 1) * PITCH
			in_level += 1
			var crossed: float = 1.0 - float(it.get("arrive", 0.0)) # 0 at the moment the enemy appears, 1 once it has settled
			out.append(lerpf(boundary, slot, 1.0 - (1.0 - crossed) * (1.0 - crossed)) if not it.get("ghost", false) else slot)
			continue
		var target := boundary + WAIT_OFFSET + mini(waiting, MAX_WAITING - 1) * PITCH
		waiting += 1
		if it.get("ghost", false):
			out.append(target)
			continue
		out.append(lerpf(entry, target, progress_of(it)))
	return out

## 0..1: how far an icon that is not in the level has travelled from the right end to its slot.
static func progress_of(it: Dictionary) -> float:
	if bool(it.get("in_transit", false)):
		return 0.0
	var p := clampf(float(it.get("age", 0.0)) / TRAVEL_SECONDS, 0.0, 1.0)
	var waited := float(it.get("waited", -1.0))
	if waited >= 0.0:
		p = maxf(p, clampf(waited / CATCH_UP_SECONDS, 0.0, 1.0))
	return p

# ---- drawing ------------------------------------------------------------------------------------------------------

func _draw() -> void:
	_zones()
	_player_icon()
	var xs := place_all(items, size.x)
	var end_x := 0.0
	for i in items.size():
		_icon(items[i], xs[i])
		end_x = maxf(end_x, xs[i] + ICON_W)
	_boundary_flash()
	if show_legend:
		_draw_legend(end_x + 3.0)

## A jagged vertical boundary at `x`: the polygon points from the top to the bottom edge.
static func jagged(x: float, height: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := TEETH * 2
	for i in n + 1:
		pts.append(Vector2(x + (TOOTH_DEPTH if i % 2 == 1 else 0.0), height * i / n))
	return pts

func _zones() -> void:
	var h := size.y
	var b1 := gold_end(size.x)
	var b2 := size.x * ORANGE_FRACTION
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

func _icon(item: Dictionary, cx: float) -> void:
	var r := Rect2(cx - ICON_W / 2.0, 1.0, ICON_W, size.y - 2.0)
	var t := view.clock * 5.0 if view != null else 0.0
	var feet := Vector2(cx, r.end.y - 0.5)
	if item.get("ghost", false):
		_ghost(item, r, feet, t)
		return
	match int(item.phase):
		Phase.QUEUED:
			if item.in_transit: # sent, the line has not landed: a hollow place-holder at the right end
				_dotted(r, _alpha(TRANSIT_EDGE, 0.8))
				BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.3, r.size.y - 1.0)
			else:
				draw_rect(r, QUEUED_FILL)
				BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.9, r.size.y - 1.0)
		Phase.ARRIVING:
			draw_rect(r, ARRIVING_FILL)
			BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 1.0, r.size.y - 1.0)
			draw_rect(r.grow(0.5), _alpha(ARRIVING_EDGE, 0.35 + 0.65 * (0.5 + 0.5 * sin(_time() * 7.0))), false, 0.75)
		_: # IN_LEVEL
			draw_rect(r, IN_LEVEL_FILL)
			BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 1.0, r.size.y - 1.0)
			draw_rect(r.grow(0.5), IN_LEVEL_EDGE, false, 0.75)
	if item.fresh > 0.0: # its line just landed
		draw_rect(r.grow(0.5), _alpha(NEW_EDGE, item.fresh), false, 0.75)
	if item.flash > 0.0: # QUEUED -> ACTIVE just happened
		draw_rect(r, Color(1, 1, 1, 0.45 * item.flash))
		draw_rect(r.grow(1.0), _alpha(FLASH, item.flash), false, 0.75)
	if item.arrive > 0.0: # its enemy just appeared in the level
		draw_rect(r, Color(1, 1, 1, 0.55 * item.arrive))
		draw_rect(r.grow(1.0), _alpha(FLASH, item.arrive), false, 0.75)

## The release: when an enemy appears in the level, a white flash runs down the gold boundary.
func _boundary_flash() -> void:
	var a := 0.0
	for r in rows:
		if int(r.phase) == Phase.IN_LEVEL:
			a = maxf(a, float(r.arrive))
	if a <= 0.0:
		return
	var b := gold_end(size.x)
	draw_colored_polygon(PackedVector2Array([Vector2(b - 2.0, 0), Vector2(b + 4.0, 0), Vector2(b + 4.0, size.y), Vector2(b - 2.0, size.y)]),
		Color(1, 1, 1, 0.7 * a))

## A just-resolved attack: its icon stays in its slot and fades; green when the player defeated it.
func _ghost(item: Dictionary, r: Rect2, feet: Vector2, t: float) -> void:
	var f: float = item.fade
	var defeated: bool = int(item.cause) == BattleAttack.Resolution.DEFEATED_BY_PLAYER
	draw_rect(r, _alpha(DEFEATED_FILL if defeated else ENDED_FILL, (0.9 if defeated else 0.55) * f))
	BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.6 * f, r.size.y - 1.0)
	if defeated:
		draw_rect(r.grow(0.5 + (1.0 - f)), _alpha(FLASH, 0.8 * f), false, 0.75)

func _dotted(r: Rect2, color: Color) -> void:
	var step := 2.0
	var px := r.position.x
	while px < r.end.x:
		draw_rect(Rect2(px, r.position.y, 1.0, 1.0), color)
		draw_rect(Rect2(px, r.end.y - 1.0, 1.0, 1.0), color)
		px += step
	var py := r.position.y
	while py < r.end.y:
		draw_rect(Rect2(r.position.x, py, 1.0, 1.0), color)
		draw_rect(Rect2(r.end.x - 1.0, py, 1.0, 1.0), color)
		py += step

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
