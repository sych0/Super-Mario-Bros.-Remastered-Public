class_name BattleIncomingStrip
extends Control
## The real player's incoming enemies, in the strip under the game window (the reference's strip A).
## One icon per attack that is aimed at the real player and not yet resolved, in the order they were
## sent, which is also the order they go through the phases, so the strip reads left to right as
## "in the level now", then "arriving", then "queued". The look of an icon is its attack's phase
## (BattleAttackPresentation.Phase, derived from the session's own state, never stored here):
##   QUEUED (line in the air)  a hollow dotted outline: sent, not landed yet
##   QUEUED (landed)           dim: waiting its turn (a yellow outline pulses once as the line lands)
##   ARRIVING                  amber with a pulsing outline: ACTIVE, its enemy is not in the level yet
##   IN_LEVEL                  red with a solid bright outline: its one real enemy is in the player's level
##                             (the moment it appears, the icon flashes white once, with the enemy's arrival pulse)
##   RESOLVED                  the icon stays where it was and fades: green if the player defeated it, grey if
##                             anything else ended it (level change, left behind, a pit)
## On the right, the counts per phase in the phase's colour (only the phases that have any).
## Everything comes from the BattleAttackPresentation, which comes from the session's events, so it always
## matches the authoritative queue. `rows` and `counts` are exactly the session's unresolved attacks: the
## fading icons are drawn in addition and are never in them.
##
## Nothing here reaches the game: the strip never spawns, resolves or times anything.

const Phase := BattleAttackPresentation.Phase

const BG := Color(0.2, 0.09, 0.04, 0.92)
const LABEL := Color(1.0, 0.9, 0.6, 1)
const QUEUED_FILL := Color(0.42, 0.28, 0.2, 1)
const ARRIVING_FILL := Color(0.86, 0.5, 0.08, 1)
const IN_LEVEL_FILL := Color(0.95, 0.2, 0.1, 1)
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
const FIRST_ICON_X := 46.0
const ICON_W := 11.0
const MAX_ICONS := 9
const TEXT_SCALE := 0.6
const TEXT_GAP := 6.0 ## between two counts
const RIGHT_PAD := 3.0

var view: BattleAttackPresentation = null
var assets: BattlePreviewAssets = null
var font: Font = null
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

func bind(view_: BattleAttackPresentation, assets_: BattlePreviewAssets) -> void:
	view = view_
	assets = assets_
	_signature = -2
	sync()

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
	var sig := rows.size() * 7 + counts.x * 131 + counts.y * 1031 + ghosts.size() * 8191
	for r in rows:
		sig = sig * 31 + int(r.seq) * 3 + int(r.phase)
	if view != null and view.is_animating():
		sig = -3 - Engine.get_process_frames() # animating: redraw every frame
	if sig != _signature:
		_signature = sig
		queue_redraw()

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

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var x := FIRST_ICON_X
	var shown := mini(items.size(), MAX_ICONS)
	for i in shown:
		_icon(items[i], x)
		x += ICON_W
	if items.size() > shown:
		_text("+%d" % (items.size() - shown), Vector2(x + 1.0, 3.0), LABEL)
		x += 14.0
	_text("INCOMING", Vector2(3.0, 3.0), LABEL)
	_draw_legend(x + 3.0)

func _icon(item: Dictionary, x: float) -> void:
	var r := Rect2(x, 1.0, ICON_W - 1.0, size.y - 2.0)
	var t := view.clock * 5.0 if view != null else 0.0
	var feet := Vector2(r.position.x + r.size.x / 2.0, r.end.y - 0.5)
	if item.get("ghost", false):
		_ghost(item, r, feet, t)
		return
	match int(item.phase):
		Phase.QUEUED:
			if item.in_transit: # sent, the line has not landed: a hollow place-holder
				_dotted(r, _alpha(TRANSIT_EDGE, 0.8))
				BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.3, r.size.y - 1.0)
			else:
				draw_rect(r, QUEUED_FILL)
				BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.5, r.size.y - 1.0)
		Phase.ARRIVING:
			draw_rect(r, ARRIVING_FILL)
			BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 1.0, r.size.y - 1.0)
			draw_rect(r.grow(0.5), _alpha(ARRIVING_EDGE, 0.35 + 0.65 * (0.5 + 0.5 * sin(_time() * 7.0))), false, 1.0)
		_: # IN_LEVEL
			draw_rect(r, IN_LEVEL_FILL)
			BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 1.0, r.size.y - 1.0)
			draw_rect(r.grow(0.5), IN_LEVEL_EDGE, false, 1.0)
	if item.fresh > 0.0: # its line just landed
		draw_rect(r.grow(0.5), _alpha(NEW_EDGE, item.fresh), false, 1.0)
	if item.flash > 0.0: # QUEUED -> ACTIVE just happened
		draw_rect(r, Color(1, 1, 1, 0.45 * item.flash))
		draw_rect(r.grow(1.0), _alpha(FLASH, item.flash), false, 1.0)
	if item.arrive > 0.0: # its enemy just appeared in the level
		draw_rect(r, Color(1, 1, 1, 0.55 * item.arrive))
		draw_rect(r.grow(1.0), _alpha(FLASH, item.arrive), false, 1.0)

## A just-resolved attack: its icon stays in its slot and fades; green when the player defeated it.
func _ghost(item: Dictionary, r: Rect2, feet: Vector2, t: float) -> void:
	var f: float = item.fade
	var defeated: bool = int(item.cause) == BattleAttack.Resolution.DEFEATED_BY_PLAYER
	draw_rect(r, _alpha(DEFEATED_FILL if defeated else ENDED_FILL, (0.9 if defeated else 0.55) * f))
	BattleEnemyIcon.draw(self, item.kind, feet, 0.5, assets, t, 0.6 * f, r.size.y - 1.0)
	if defeated:
		draw_rect(r.grow(0.5 + (1.0 - f)), _alpha(FLASH, 0.8 * f), false, 1.0)

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
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x * TEXT_SCALE if font != null else 0.0

# The bitmap font draws its glyph box ~15px above the baseline we give it (at scale 1).
func _text(text: String, top_left: Vector2, color: Color) -> void:
	if font == null:
		return
	draw_set_transform(top_left, 0.0, Vector2(TEXT_SCALE, TEXT_SCALE))
	draw_string(font, Vector2(0, 15), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
