class_name BattleTargetSelector
extends Control
## The targeting selector (doc 47 B35-TARGET-005): a cross of four rounded pills around a centre button, Lowest
## Time on top, Random left, Most Coins right, Attackers below, inside the game window's top middle. Replaces the
## provisional text readout of M-T1. A view only: BattleScreen tells it the session's mode (`set_mode`), which modes
## can be chosen (`set_available`), that a refused one was tried (`refuse`) and how much time passed (`advance`).
##
## Look, from the reference:
##   at rest     the whole cross is translucent (white outlines and text); the chosen pill is filled gold
##   on a change the cross goes opaque, the new pill's label swells, the glow settles, and the cross fades back to
##               translucent by about 1.75 s (`opacity_at`, `label_scale_at`, `glow_at`: pure functions of the age)
##   unavailable a mode that cannot be chosen yet (Most Coins) is drawn grey; trying it shakes the pill and lights
##               the cross but changes nothing (`refuse`)
## The pills keep the reference's rows and centres; their widths grow just enough to hold the project's 8x8 bitmap
## font at a readable size (the reference's own typeface is condensed). The centre button carries no letter: the
## reference's "R" names a controller stick, and the controller mapping is still open (doc 47 Q5).
##
## Time is the caller's: `advance` is not called while the game is paused, so a pause holds the animation too.

const Mode := BattleTargeting.Mode

const REST_ALPHA := 0.5
const HOLD := 0.6 ## seconds the cross stays opaque
const FADE_END := 1.75 ## the age at which the cross is back at rest
const SWELL_PEAK := 0.2 ## the age at which a new label is largest
const SWELL_END := 0.55
const SWELL := 0.3 ## the label's extra scale at the peak
const REFUSE_SECONDS := 0.5
const TEXT_SCALE := 0.6
const PAD := 3.0 ## each side of a label inside its pill
const MIN_UNAVAILABLE_ALPHA := 0.55

const GOLD := Color(1.0, 0.85, 0.22, 1)
const GOLD_DARK := Color(0.82, 0.55, 0.0, 1)
const INK := Color(0.23, 0.2, 0.13, 1) ## the reference's dark outline colour (59,51,33)
const WHITE := Color(1, 1, 1, 1)
const GREY := Color(0.7, 0.7, 0.72, 1)
const REFUSE_RED := Color(1.0, 0.25, 0.2, 1)

const LABELS := {Mode.LOWEST_TIME: "LOWEST TIME", Mode.RANDOM: "RANDOM", Mode.MOST_COINS: "MOST COINS", Mode.ATTACKERS: "ATTACKERS"}
const RECT_KEYS := {Mode.LOWEST_TIME: "lowest_time", Mode.RANDOM: "random", Mode.MOST_COINS: "most_coins", Mode.ATTACKERS: "attackers"}

var layout := {} ## hud.selector of BattleHudLayout.compute()
var font: Font = null
var mode: int = Mode.RANDOM ## the chosen mode
var available := {Mode.RANDOM: true, Mode.LOWEST_TIME: true, Mode.MOST_COINS: false, Mode.ATTACKERS: true}
var age := 0.0 ## seconds since the last change (or refusal): 0 = just changed
var refused_mode := -1 ## the unavailable mode last tried (-1: none)
var refuse_age := 1.0e9


func _init(layout_: Dictionary = {}, font_: Font = null) -> void:
	name = "TargetSelector"
	layout = layout_
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	age = FADE_END # a selector nobody touched is at rest

# ---- the timeline (pure) -----------------------------------------------------------------------------------

## The whole cross's opacity `age` seconds after a change: opaque at once (the change is felt on the frame it happens),
## for HOLD, then back to rest by FADE_END.
static func opacity_at(age_: float) -> float:
	if age_ < HOLD:
		return 1.0
	if age_ < FADE_END:
		return lerpf(1.0, REST_ALPHA, (age_ - HOLD) / (FADE_END - HOLD))
	return REST_ALPHA

## The new pill's label scale factor: 1 -> 1 + SWELL at SWELL_PEAK -> 1 at SWELL_END.
static func label_scale_at(age_: float) -> float:
	if age_ <= 0.0 or age_ >= SWELL_END:
		return 1.0
	if age_ < SWELL_PEAK:
		return 1.0 + SWELL * sin(age_ / SWELL_PEAK * PI * 0.5)
	return 1.0 + SWELL * (0.5 + 0.5 * cos((age_ - SWELL_PEAK) / (SWELL_END - SWELL_PEAK) * PI))

## The chosen pill's glow strength: full as it changes, settling to a steady glow by SWELL_END.
static func glow_at(age_: float) -> float:
	if age_ >= SWELL_END:
		return 0.45
	return lerpf(1.0, 0.45, clampf(age_ / SWELL_END, 0.0, 1.0))

## The sideways shake (px) of a refused pill `age_` seconds after the try.
static func shake_at(age_: float) -> float:
	if age_ < 0.0 or age_ >= REFUSE_SECONDS:
		return 0.0
	return sin(age_ * 60.0) * 1.5 * (1.0 - age_ / REFUSE_SECONDS)

## Whether anything is still moving (the selector redraws every frame only then).
func is_animating() -> bool:
	return age < FADE_END or refuse_age < REFUSE_SECONDS

## How opaque the cross is right now.
func opacity() -> float:
	return opacity_at(age)

# ---- state -------------------------------------------------------------------------------------------------

## The chosen mode. A different one starts the change animation; the same one only restarts it when `touch`.
func set_mode(mode_: int, touch := false) -> void:
	if mode_ == mode and not touch:
		return
	mode = mode_
	age = 0.0
	queue_redraw()

func set_available(mode_: int, yes: bool) -> void:
	if available.get(mode_, false) != yes:
		available[mode_] = yes
		queue_redraw()

## The player tried a mode that cannot be chosen: its pill shakes and the cross lights up. The mode stays.
func refuse(mode_: int) -> void:
	refused_mode = mode_
	refuse_age = 0.0
	age = minf(age, HOLD * 0.5) # opaque again, without replaying the chosen pill's swell
	queue_redraw()

func advance(delta: float) -> void:
	if delta <= 0.0:
		return
	var was := is_animating()
	age += delta
	refuse_age += delta
	if was or is_animating():
		queue_redraw()

# ---- drawing -----------------------------------------------------------------------------------------------

## The rect of `mode_`'s pill: the reference's row and centre, widened to hold its label.
func pill_rect(mode_: int, swell := 1.0) -> Rect2:
	var base: Rect2 = layout[RECT_KEYS[mode_]]
	var want := BattleHudText.ink_width(LABELS[mode_], TEXT_SCALE * swell) + PAD * 2.0
	var w := maxf(base.size.x, want)
	return Rect2(Vector2(base.get_center().x - w / 2.0, base.position.y), Vector2(w, base.size.y))

func _draw() -> void:
	if layout.is_empty():
		return
	var alpha := opacity_at(age)
	var c: Vector2 = layout.center
	_button(c, alpha)
	for m in LABELS:
		_pill(m, alpha)

func _button(c: Vector2, alpha: float) -> void:
	draw_circle(c, 5.0, Color(INK.r, INK.g, INK.b, 0.55 * alpha))
	draw_arc(c, 4.6, 0.0, TAU, 20, Color(1, 1, 1, 0.85 * alpha), 0.75)
	draw_circle(c, 1.6, Color(1, 1, 1, 0.8 * alpha))

func _pill(m: int, alpha: float) -> void:
	var chosen := m == mode
	var r := pill_rect(m, label_scale_at(age) if chosen else 1.0) # the chosen pill grows with its swelling label
	var can: bool = available.get(m, false)
	var shake := shake_at(refuse_age) if m == refused_mode else 0.0
	r.position.x += shake
	var scale_ := TEXT_SCALE
	if chosen:
		scale_ *= label_scale_at(age)
	var text: String = LABELS[m]
	var a := alpha if can else alpha * MIN_UNAVAILABLE_ALPHA
	if chosen:
		var glow := glow_at(age)
		var halo := Color(GOLD.r, GOLD.g, GOLD.b, 0.35 * glow * alpha)
		_box(r.grow(1.25 + 1.0 * glow), halo, halo)
		_box(r, Color(GOLD.r, GOLD.g, GOLD.b, a), Color(GOLD_DARK.r, GOLD_DARK.g, GOLD_DARK.b, a))
		BattleHudText.draw_in(self, font, text, r, scale_, Color(INK.r, INK.g, INK.b, a))
		return
	var edge := Color(1, 1, 1, 0.9 * a)
	var fill := Color(1, 1, 1, 0.12 * a)
	var ink := Color(1, 1, 1, a)
	if not can:
		edge = Color(GREY.r, GREY.g, GREY.b, 0.8 * a)
		fill = Color(0, 0, 0, 0.25 * a)
		ink = Color(GREY.r, GREY.g, GREY.b, a)
	if m == refused_mode and refuse_age < REFUSE_SECONDS:
		var flash := 1.0 - refuse_age / REFUSE_SECONDS
		edge = edge.lerp(REFUSE_RED, flash)
		ink = ink.lerp(REFUSE_RED, flash)
		fill = fill.lerp(Color(REFUSE_RED.r, REFUSE_RED.g, REFUSE_RED.b, 0.3), flash)
	var shadow := Color(INK.r, INK.g, INK.b, 0.35 * a)
	_box(r.grow(0.5), shadow, shadow)
	_box(r, fill, edge)
	BattleHudText.draw_in(self, font, text, r, scale_, ink)

func _box(rect: Rect2, fill: Color, edge: Color) -> void:
	BattleHudShapes.pill(self, rect, fill, edge)
