class_name BattleSendGhostLayer
extends Control
## Draws the ghosts of enemy sends (BattleSendGhost, doc 55) over the opponent panes: for each send a translucent copy of the sent enemy flies
## from the middle of the sender to the middle of the recipient's pane in 0.5 s, and bursts there. It is drawn only inside its sender's own
## window and the panes' rectangles (BattleSendGhost.clip_rects: a ghost is seen leaving the sender's pane, or the game window for the real
## player, crossing the panes on its way and arriving on the recipient's; never over the gaps), under the target reticle and the red lines.
## The real player's sends and a bot's are drawn by the same code from the same SENT event (doc 57). A view only: it reads the presentation
## and the layout, owns no state of its own, and draws nothing for a send at the real player.

## Dev measurements: microseconds spent in _draw() and how many draws ran.
static var stat_draw_us := 0
static var stat_draws := 0

var view: BattleAttackPresentation = null
var layout := {}
var assets: BattlePreviewAssets = null
var panes: Array = [] ## the screen's BattleOpponentPanes: one showing its KO card gets no burst (the card has its own)

var _signature := -1

func _init(layout_: Dictionary = {}) -> void:
	name = "SendGhostLayer"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR # the ghost is soft
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS

func bind(view_: BattleAttackPresentation, assets_: BattlePreviewAssets = null) -> void:
	view = view_
	assets = assets_
	_signature = -2
	queue_redraw()

## Called every frame: redraws while any ghost or burst is on screen, and once more when the last one ends.
func sync() -> void:
	var sig := 0
	if view != null:
		var ghosts := view.send_ghosts()
		if not ghosts.is_empty():
			sig = -3 - Engine.get_process_frames() # something moves: every frame
			for g in ghosts:
				sig += int(g.seq)
	if sig != _signature:
		_signature = sig
		queue_redraw()

## The ghosts that are on screen (what `_draw` draws), from the presentation. (Pure: tests read what is drawn.)
func drawn() -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	return view.send_ghosts() if view != null else none

## The sprite a ghost of Battle enemy `kind` is drawn from, or null (then a plain shape is drawn instead).
func ghost_art(kind: int) -> BattlePreviewSprite:
	if assets == null:
		return null
	return BattleSendGhost.ghost_of(assets.enemy_frame(BattleEnemyIcon.preview_kind(kind), 0.0))

func _draw() -> void:
	if view == null or layout.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	for g in drawn():
		var age: float = g.age
		if BattleSendGhost.in_flight(age):
			_draw_ghost(g)
		var k := BattleSendGhost.flash_frame(age)
		if k >= 0:
			_draw_flash(int(g.target), k)
	stat_draw_us += Time.get_ticks_usec() - t0
	stat_draws += 1

## How ghost `g` (one of `drawn()`) is drawn: {art (its picture; null: a plain shape), rect (its whole body, centred on its point of
## the path), pieces (each [canvas rect, texture rect]: the parts of the body inside its sender's own window and the panes)}. One rule
## for every sender (doc 57); who sent it only moves the path's start and the window it leaves. (Pure: tests read what is drawn.)
func ghost_look(g: Dictionary) -> Dictionary:
	var centre := BattleSendGhost.point(layout, int(g.sender), int(g.target), BattleSendGhost.progress(float(g.age)))
	var art := ghost_art(int(g.kind))
	var rect: Rect2
	var tex_size := Vector2.ONE
	if art != null:
		rect = BattleSendGhost.body_rect(art.size, centre)
		tex_size = art.texture.get_size()
	else:
		rect = BattleSendGhost.body_rect(Vector2(16, 16 if int(g.kind) == BattleEnemyType.Kind.GOOMBA else 24), centre)
	var pieces: Array = []
	for clip in BattleSendGhost.clip_rects(layout, int(g.sender)):
		var cut := BattleSendGhost.clipped(rect, clip, tex_size)
		if cut[0].size.x > 0.0:
			pieces.append(cut)
	return {"art": art, "rect": rect, "pieces": pieces}

func _draw_ghost(g: Dictionary) -> void:
	var look := ghost_look(g)
	var art: BattlePreviewSprite = look.art
	for cut in look.pieces:
		if art != null:
			draw_texture_rect_region(art.texture, cut[0], cut[1], Color(1, 1, 1, 1))
		else:
			var c := BattleEnemyIcon.body_color(int(g.kind)).lerp(Color(0.75, 0.9, 0.9), 0.6)
			c.a = BattleSendGhost.ALPHA * 0.7
			draw_rect(cut[0], c)

## Whether a burst is drawn on `target`'s pane: not when the pane is showing its KO card (the card has its own burst). Defensive: a send's
## recipient is alive when it is sent and a card shows two seconds after the session's KO, so this never happens in a match.
func shows_burst(target: int) -> bool:
	if target < 1 or target > (layout.slots as Array).size():
		return false
	return not (target - 1 < panes.size() and panes[target - 1] != null and panes[target - 1].marked)

func _draw_flash(target: int, k: int) -> void:
	if not shows_burst(target):
		return
	var look := BattleSendGhost.flash_look(k, layout.slots[target - 1])
	var fill: Color = look.fill
	if fill.a > 0.0:
		BattleHudShapes.box(self, look.rect, fill, fill, 3.0, 0.5)
	if float(look.rim) > 0.0:
		var rim_color: Color = look.rim_color
		BattleHudShapes.box(self, look.rim_rect, Color(0, 0, 0, 0), rim_color, 4.0, float(look.rim))
