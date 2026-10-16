class_name BattleIncomingStrip
extends Control
## The real player's incoming enemies, in the strip under the game window (the reference's strip A).
## One icon per attack that is aimed at the real player and not yet resolved, in the order they were
## sent: a QUEUED one is dim, an ACTIVE one is lit, and the moment an attack goes QUEUED -> ACTIVE its
## icon flashes. On the right, the plain counts. Everything comes from the BattleAttackPresentation,
## which comes from the session's events, so it always matches the authoritative queue.
##
## Nothing here reaches the game: no enemy is spawned into the real player's level, and the player takes
## no damage or penalty from what the strip shows (those are later milestones).

const BG := Color(0.2, 0.09, 0.04, 0.92)
const LABEL := Color(1.0, 0.9, 0.6, 1)
const ACTIVE_FILL := Color(0.95, 0.2, 0.1, 1)
const QUEUED_FILL := Color(0.42, 0.28, 0.2, 1)
const FLASH := Color(1, 1, 1, 1)
const NEW_EDGE := Color(1.0, 0.95, 0.35, 1)
const FIRST_ICON_X := 46.0
const ICON_W := 11.0
const MAX_ICONS := 9
const COUNTS_W := 96.0

var view: BattleAttackPresentation = null
var assets: BattlePreviewAssets = null
var font: Font = null
var rows: Array[Dictionary] = [] ## what the strip shows: the real player's unresolved attacks at the last sync
var counts := Vector2i.ZERO ## (queued, active) at the last sync

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

## Reads the presentation (every frame). Redraws when the list changed, and every frame while a flash runs.
func sync() -> void:
	if view == null:
		rows.clear()
		counts = Vector2i.ZERO
	else:
		rows = view.player_incoming()
		counts = view.counts(BattleSession.PLAYER_ID)
	var sig := rows.size() * 7 + counts.x * 131 + counts.y * 1031
	for r in rows:
		sig = sig * 31 + int(r.seq) * 3 + int(r.state)
	if view != null and view.is_animating():
		sig = -3 - Engine.get_process_frames() # animating: redraw every frame
	if sig != _signature:
		_signature = sig
		queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var x := FIRST_ICON_X
	var shown := mini(rows.size(), MAX_ICONS)
	for i in shown:
		_icon(rows[i], x)
		x += ICON_W
	if rows.size() > shown:
		_text("+%d" % (rows.size() - shown), Vector2(x + 1.0, 3.0), LABEL)
	_text("INCOMING", Vector2(3.0, 3.0), LABEL)
	_text("ACTIVE %d  QUEUED %d" % [counts.y, counts.x], Vector2(size.x - COUNTS_W, 3.0), LABEL if view == null or view.last_activation().get("flash", 0.0) <= 0.0 else FLASH)

func _icon(row: Dictionary, x: float) -> void:
	var active: bool = row.state == BattleAttack.State.ACTIVE
	var r := Rect2(x, 1.0, ICON_W - 1.0, size.y - 2.0)
	draw_rect(r, ACTIVE_FILL if active else QUEUED_FILL)
	var t := view.clock * 5.0 if view != null else 0.0
	BattleEnemyIcon.draw(self, row.kind, Vector2(r.position.x + r.size.x / 2.0, r.end.y - 0.5), 0.5, assets, t, 1.0 if active else 0.5, r.size.y - 1.0)
	if row.fresh > 0.0:
		var e := NEW_EDGE
		e.a = row.fresh
		draw_rect(r.grow(0.5), e, false, 1.0)
	if row.flash > 0.0: # QUEUED -> ACTIVE just happened
		var f := FLASH
		f.a = row.flash
		draw_rect(r, Color(1, 1, 1, 0.45 * row.flash))
		draw_rect(r.grow(1.0), f, false, 1.0)

# The bitmap font draws its glyph box ~15px above the baseline we give it (at scale 1).
func _text(text: String, top_left: Vector2, color: Color) -> void:
	if font == null:
		return
	draw_set_transform(top_left, 0.0, Vector2(0.6, 0.6))
	draw_string(font, Vector2(0, 15), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
