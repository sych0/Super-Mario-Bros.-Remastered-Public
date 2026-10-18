class_name BattleSendGhost
extends RefCounted
## What an enemy SEND looks like on the opponents' panes (doc 55, measured on the reference video at 60 fps; the video is public:
## https://www.youtube.com/watch?v=AUcFTEfFp58). Doc 54 listed "grey enemies dropping into panes" as seen and not built, and doc 51
## said a bot's send at another bot is not drawn at all; both were wrong. Every send, the real player's and a bot's, is a GHOST of the sent
## enemy: a translucent grey-teal copy of it, about 2.5 times the size it has in a level, that flies in a straight line at constant speed
## from the middle of the sender (the sender's pane; the game window for the real player) to the middle of the recipient's pane in
## FRAMES (30) frames, 0.5 s. It is drawn only inside its sender's own window and the panes (`clip_rects`), so it is seen leave its sender
## (a bot's pane; the game window for the real player, doc 57), cross any pane on the way and arrive on the recipient's; it is never drawn
## over the gaps between them. Who sent it changes only where it starts and the window it leaves; everything else is the same for every
## sender: one path, one picture, one timeline, one burst. When it reaches the middle
## of the recipient's pane it bursts: a white rounded square grows from 11 to 23 units over four frames, goes translucent and fades as a
## rim round the pane's edge (FLASH_FRAMES, 11 frames, 0.18 s). A send at the real player has no ghost on any pane (its red line and
## its icon in the incoming bar are its picture).
##
## Measured on the reference (tools/reference/measure_reference.py, extract_frames.py and local frame analysis; doc 55 lists the timestamps):
##   * 40 of the real player's sends (t=509-619): the recipient's flash starts 0.483-0.500 s after the send began (29 of 40; a few
##     0.42-0.47), centred on the pane (median 0.50, 0.50 of its width and height). The ghost is on the recipient's pane for the 2-3 frames
##     before it, coming from the side that faces the game window: from the right edge for a pane in the left panel, the left edge for one
##     in the right panel, from the top or bottom for the ones above or below the window's line. That is the straight path from the window's
##     middle; 226 units in 30 frames is 7.5 units per frame, which is what 2-3 frames in a 33-unit pane need.
##   * a bot's send at a bot (t=515.50-516.00): the ghost appears at the centre of the sender's pane (393.4, 73.8: pane 20's centre) and
##     moves straight down at 1.43 units per frame, 43.8 units in 30 frames to pane 23's centre, where the flash starts on the frame after
##     it arrives (516.000); a second ghost leaves the same pane 13 frames later at 2.9 units per frame, passes through pane 23's centre on
##     frame 15 without a flash and goes on to the pane two below (86 units in 30 frames). A third ghost crosses panes 25, 24 and 23 of the
##     right panel at 13.9 units per frame (t=655.95-656.03) and arrives on pane 4 of the left panel at 656.4, 0.45 s later, with its flash.
##   * the ghost is a Goomba's or a Koopa's own picture (a Goomba is a head with a white face and white feet), drawn in translucent
##     grey-teal (head about 130, 150, 140), white where the sprite is light, 10 x 9.5 units for a Goomba and taller for a Koopa.
##   * the flash's frames (pane 33, t=527.172-527.34): white rounded square 11.6, 13.5 x 15, 16, 21 x 23 units, then a light-cyan
##     (about 202, 255, 255) square 26 x 28 at 70 %, a gap frame, 28 x 30 at 40 %, then a rim 3, 2.2, 1.5, 1.0 units thick at 30, 22, 15,
##     10 % hugging the pane's edge; gone on the 12th frame.
## Presentation only: it reads the authoritative SENT event (sender, recipient, kind) and nothing else.

const FPS := 60.0
const FRAMES := 30 ## from the sender's middle to the recipient's middle
const SECONDS := FRAMES / FPS ## 0.5 s
const WIDTH := 10.0 ## canvas units a 16-pixel-wide sprite is drawn as
const ALPHA := 0.85

const FLASH_FRAMES := 11
const FLASH_SECONDS := FLASH_FRAMES / FPS
const WHITE := Color(1, 1, 1, 1)
const CYAN := Color8(202, 255, 255)
## One row per flash frame: [width, height, fill alpha, colour (0 white, 1 light cyan), rim thickness, rim alpha] in canvas units.
const FLASH := [
	[11.6, 11.6, 1.0, 0, 0.0, 0.0],
	[13.5, 15.0, 1.0, 0, 0.0, 0.0],
	[16.0, 16.0, 1.0, 0, 0.0, 0.0],
	[21.0, 23.0, 1.0, 0, 0.0, 0.0],
	[26.0, 28.0, 0.70, 1, 0.0, 0.0],
	[26.0, 28.0, 0.06, 1, 0.0, 0.0],
	[28.0, 30.0, 0.40, 1, 0.0, 0.0],
	[0.0, 0.0, 0.0, 1, 3.0, 0.30],
	[0.0, 0.0, 0.0, 1, 2.2, 0.22],
	[0.0, 0.0, 0.0, 1, 1.5, 0.15],
	[0.0, 0.0, 0.0, 1, 1.0, 0.10],
]
const RIM_INSET := 1.5 ## the rim's outer edge is this far inside the pane's own edge
const PAD := 3 ## source pixels of glow round the sprite
const SCALE := 3 ## the ghost's texture is the sprite enlarged this many times, then softened

static var _cache := {}

# ---- time -----------------------------------------------------------------------------------------------

## How far along its path a ghost `age` seconds after its send is (0 at the sender, 1 at the recipient), linear in time.
static func progress(age: float) -> float:
	return clampf(age / SECONDS, 0.0, 1.0)

static func in_flight(age: float) -> bool:
	return age >= 0.0 and age < SECONDS

## The flash frame (0..FLASH_FRAMES-1) `age` is in, or -1: the burst starts on the frame after the ghost arrives.
static func flash_frame(age: float) -> int:
	var k := floori((age - SECONDS) * FPS + 1.0e-6)
	return k if k >= 0 and k < FLASH_FRAMES else -1

static func finished(age: float) -> bool:
	return age >= SECONDS + FLASH_SECONDS

# ---- where -----------------------------------------------------------------------------------------------

## Where a send from `sender` to `target` starts: the middle of the sender's pane, or of the game window for the real player.
static func start_point(layout: Dictionary, sender: int) -> Vector2:
	return BattleAttackGeometry.center_of(layout, sender)

## Where it ends: the middle of the recipient's pane.
static func end_point(layout: Dictionary, target: int) -> Vector2:
	return BattleAttackGeometry.center_of(layout, target)

## The ghost's middle `progress` (0..1) of the way: a straight line at constant speed.
static func point(layout: Dictionary, sender: int, target: int, progress_: float) -> Vector2:
	return start_point(layout, sender).lerp(end_point(layout, target), clampf(progress_, 0.0, 1.0))

## The rectangles a ghost from `sender` is drawn in: the sender's own window (BattleAttackGeometry.rect_of: its pane, or the game
## window for the real player), then every pane. The same rule for every sender (doc 57): the ghost is seen leaving the window it was
## sent from. For a bot that window is its own pane, already one of the panes, so its ghost is drawn exactly as before; for the real
## player it is the game window, which the panes-only rule of doc 55 left out, so their ghost was only seen for its last 2-3 frames.
static func clip_rects(layout: Dictionary, sender: int) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var own := BattleAttackGeometry.rect_of(layout, sender)
	var slots: Array = layout.slots
	if not slots.has(own):
		out.append(own)
	for r in slots:
		out.append(r)
	return out

## The rectangle a ghost of the `size`-pixel sprite is drawn in, centred on `centre`, in canvas units.
static func body_rect(size: Vector2, centre: Vector2) -> Rect2:
	var k := WIDTH / 16.0
	var s := (size + Vector2(PAD, PAD) * 2.0) * k
	return Rect2(centre - s / 2.0, s)

## The part of `rect` inside `clip` and the matching part of a texture `tex_size` pixels big that was drawn into `rect`. Empty
## rectangles when they do not overlap. Pure.
static func clipped(rect: Rect2, clip: Rect2, tex_size: Vector2) -> Array[Rect2]:
	var inter := rect.intersection(clip)
	if inter.size.x <= 0.0 or inter.size.y <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return [Rect2(), Rect2()]
	var src := Rect2((inter.position - rect.position) / rect.size * tex_size, inter.size / rect.size * tex_size)
	return [inter, src]

# ---- the flash --------------------------------------------------------------------------------------------

## The flash's look on `k` (a flash_frame): {rect (centred on `centre`, clipped to `pane`), fill (Color, alpha 0 = none), rim_rect, rim
## (thickness, 0 = none), rim_color}. Pure.
static func flash_look(k: int, pane: Rect2) -> Dictionary:
	var out := {"rect": Rect2(), "fill": Color(0, 0, 0, 0), "rim": 0.0, "rim_rect": Rect2(), "rim_color": Color(0, 0, 0, 0)}
	if k < 0 or k >= FLASH_FRAMES:
		return out
	var row: Array = FLASH[k]
	var colour: Color = WHITE if int(row[3]) == 0 else CYAN
	if float(row[2]) > 0.0:
		var r := Rect2(pane.get_center() - Vector2(row[0], row[1]) / 2.0, Vector2(row[0], row[1])).intersection(pane)
		out.rect = r
		out.fill = Color(colour.r, colour.g, colour.b, float(row[2]))
	if float(row[4]) > 0.0:
		out.rim = float(row[4])
		out.rim_rect = pane.grow(-RIM_INSET)
		out.rim_color = Color(colour.r, colour.g, colour.b, float(row[5]))
	return out

# ---- the ghost's picture ------------------------------------------------------------------------------------

## The ghost of the sprite `spr` (a BattlePreviewSprite of a level enemy): its light and dark areas mapped to white and grey-teal, a
## little translucent, enlarged and softened, with a faint halo. Built once per sprite. Null if the sprite has no readable picture.
static func ghost_of(spr: BattlePreviewSprite) -> BattlePreviewSprite:
	if spr == null or spr.texture == null:
		return null
	var key := spr.texture.get_instance_id()
	if _cache.has(key):
		return _cache[key]
	var src := spr.texture.get_image()
	if src == null:
		return null
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var ow := (w + PAD * 2) * SCALE
	var oh := (h + PAD * 2) * SCALE
	var body := PackedFloat32Array() # alpha of the body at the output's resolution
	body.resize(ow * oh)
	var lum := PackedFloat32Array()
	lum.resize(ow * oh)
	for y in h:
		for x in w:
			var c := src.get_pixel(x, y)
			if c.a <= 0.01:
				continue
			var l := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			for dy in SCALE:
				for dx in SCALE:
					var i := ((y + PAD) * SCALE + dy) * ow + (x + PAD) * SCALE + dx
					body[i] = c.a
					lum[i] = l
	var soft := _blur(body, ow, oh, 1) # the body's own edge, softened
	var halo := _blur(body, ow, oh, SCALE * 2)
	var img := Image.create(ow, oh, false, Image.FORMAT_RGBA8)
	for y in oh:
		for x in ow:
			var i := y * ow + x
			var a := soft[i] * ALPHA
			var halo_a := halo[i] * 0.32
			if a <= 0.01 and halo_a <= 0.01:
				continue
			var l := lum[i]
			var col := Color8(40, 85, 100).lerp(Color8(135, 160, 150), smoothstep(0.0, 0.45, l)).lerp(WHITE, smoothstep(0.5, 0.85, l))
			var halo_col := Color8(200, 235, 235)
			var out_a := minf(a + halo_a * (1.0 - a), ALPHA)
			var out_col := (col * a + halo_col * halo_a * (1.0 - a)) / maxf(out_a, 0.001)
			img.set_pixel(x, y, Color(out_col.r, out_col.g, out_col.b, out_a))
	var g := BattlePreviewSprite.new()
	g.texture = ImageTexture.create_from_image(img)
	g.size = Vector2(w, h)
	g.offset = Vector2.ZERO
	_cache[key] = g
	return g

static func clear_cache() -> void:
	_cache.clear()

## A box blur of `a` (w x h) with the given radius, two passes (horizontal, vertical).
static func _blur(a: PackedFloat32Array, w: int, h: int, radius: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(w * h)
	var out := PackedFloat32Array()
	out.resize(w * h)
	var n := float(radius * 2 + 1)
	for y in h:
		var sum := 0.0
		for x in range(-radius, radius + 1):
			sum += a[y * w + clampi(x, 0, w - 1)] if x >= 0 and x < w else 0.0
		for x in w:
			tmp[y * w + x] = sum / n
			var add := x + radius + 1
			var sub := x - radius
			sum += (a[y * w + add] if add < w else 0.0) - (a[y * w + sub] if sub >= 0 else 0.0)
	for x in w:
		var sum := 0.0
		for y in range(-radius, radius + 1):
			sum += tmp[y * w + x] if y >= 0 and y < h else 0.0
		for y in h:
			out[y * w + x] = sum / n
			var add := y + radius + 1
			var sub := y - radius
			sum += (tmp[add * w + x] if add < h else 0.0) - (tmp[sub * w + x] if sub >= 0 else 0.0)
	return out
