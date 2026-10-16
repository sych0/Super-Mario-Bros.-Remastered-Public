class_name BattleStatusStrip
extends Control
## The status strip under the incoming bar (doc 47 B35-LAYOUT-003 strip B), left to right:
##   eye counter    an eye and how many opponents are aiming at the real player right now (B35-INCOMING-006:
##                  `BattleSession.attackers_of(PLAYER_ID).size()`; the meaning is strongly inferred from the reference)
##   WATCH OUT!     a red pill with yellow letters while an enemy is on its way to the real player (B35-INCOMING-005:
##                  from the moment a bot sends one at the player until about a second after its line lands; the
##                  trigger is strongly inferred, doc 47 Q8), appearing with a small pop
##   bonus box      ABSENT: the reference's chest bonus (B35-COIN-006) has an unknown formula and needs the coin economy
## A view only: BattleScreen sets what it shows from the session and the attack presentation. It draws no background:
## the strip's gold and borders belong to the screen. Coordinates are local to the strip (its rect on the canvas).

const POP_SECONDS := 0.18
const PILL_LOCAL := Rect2(74.0, 1.0, 104.0, 11.0) ## canvas x 185..290 minus the strip's x
const EYE_LOCAL := Vector2(3.0, 1.5)
const RED := Color(0.9, 0.08, 0.08, 1)
const RED_DARK := Color(0.55, 0.02, 0.02, 1)
const BLACK := Color(0.05, 0.03, 0.02, 1)
const YELLOW := Color(1.0, 0.95, 0.3, 1)
const WHITE := Color(1, 1, 1, 1)
const OUTLINE := Color(0.23, 0.2, 0.13, 1)
const LABEL := "WATCH OUT!"

var font: Font = null
var eye := -1 ## opponents aiming at the player; negative = not shown (no attack loop)
var watch_out := false
var age := 0.0 ## seconds since WATCH OUT! appeared

func _init(font_: Font = null) -> void:
	name = "StatusStrip"
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func set_eye(count: int) -> void:
	if count != eye:
		eye = count
		queue_redraw()

func set_watch_out(on: bool) -> void:
	if on == watch_out:
		return
	watch_out = on
	age = 0.0
	queue_redraw()

func advance(delta: float) -> void:
	if watch_out and delta > 0.0 and age < POP_SECONDS:
		age += delta
		queue_redraw()

## The pill's scale `age_` seconds after it appeared: a pop that overshoots a little and settles.
static func pop_scale(age_: float) -> float:
	if age_ >= POP_SECONDS:
		return 1.0
	var t := age_ / POP_SECONDS
	return 0.6 + 0.4 * (t + 0.6 * sin(t * PI))

func _draw() -> void:
	if eye >= 0:
		_eye(EYE_LOCAL)
		BattleHudText.draw(self, font, str(eye), Vector2(EYE_LOCAL.x + 13.0, EYE_LOCAL.y + 1.5), 1.0, WHITE, OUTLINE, 0.5)
	if watch_out:
		_pill()

## An eye: a white almond with a dark pupil.
func _eye(at: Vector2) -> void:
	var c := at + Vector2(5.0, 5.0)
	var pts := PackedVector2Array()
	for i in 17:
		var t := i / 16.0
		pts.append(c + Vector2(lerpf(-5.0, 5.0, t), -sin(t * PI) * 3.4))
	for i in range(15, 0, -1):
		var t := i / 16.0
		pts.append(c + Vector2(lerpf(-5.0, 5.0, t), sin(t * PI) * 3.4))
	var outer := PackedVector2Array()
	for p in pts:
		outer.append(c + (p - c) * 1.18)
	draw_colored_polygon(outer, OUTLINE)
	draw_colored_polygon(pts, WHITE)
	draw_circle(c, 2.0, BLACK)
	draw_circle(c + Vector2(-0.6, -0.6), 0.6, WHITE)

func _pill() -> void:
	var s := pop_scale(age)
	var r := PILL_LOCAL
	var c := r.get_center()
	r = Rect2(c - r.size * s / 2.0, r.size * s)
	BattleHudShapes.pill(self, r.grow(0.5), BLACK, BLACK, 0.5)
	BattleHudShapes.pill(self, r, RED, RED_DARK, 0.5)
	var ts := BattleHudText.fit_scale(LABEL, r.size.x - 8.0, 1.0 * s)
	var w := BattleHudText.ink_width(LABEL, ts)
	var tl := c - Vector2(w, BattleHudText.ink_height(ts)) / 2.0
	BattleHudText.draw(self, font, LABEL, tl + Vector2(0.5, 0.5), ts, BLACK) # a second pass makes the letters bold
	BattleHudText.draw(self, font, LABEL, tl, ts, YELLOW)
	BattleHudText.draw(self, font, LABEL, tl + Vector2(0.4, 0), ts, YELLOW)
