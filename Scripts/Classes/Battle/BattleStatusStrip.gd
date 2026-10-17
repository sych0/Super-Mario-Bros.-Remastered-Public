class_name BattleStatusStrip
extends Control
## The status strip under the incoming bar (doc 47 B35-LAYOUT-003 strip B). What the reference puts in it, measured at 60 fps (doc 54):
##   WATCH OUT!     a pill, on exactly while at least one opponent's red line is on screen (B35-INCOMING-005): a black plate with
##                  yellow letters inside a red ring, and at each end three stripes (orange, crimson) like a lit sign. It appears as a
##                  white flash of its whole outline that fades to the pill over 8 frames, and that same flash repeats every 59 frames
##                  while it stays (that is the "pulse" of the reference).
##   bonus box      ABSENT: the reference's chest bonus (B35-COIN-006) has an unknown formula and needs the coin economy
## There is NO eye counter. Doc 47 (B35-INCOMING-006) inferred an eye and a number at the left end as "how many opponents are aiming at
## you"; the frames refute that: at t=905 two lines (two attackers) show no eye, at t=918 one line shows an eye and "1", and at t=600, 745,
## 870, 892 lines show none. The eye only appears in the last minutes (t=915-927, 951-1047, 1050-1068) and means something else
## (perhaps spectators); nothing in the session drives it, so it is not drawn.
## A view only: BattleScreen tells it how long WATCH OUT! has been showing (BattleAttackPresentation.watch_out_age, -1 for not showing).
## It draws no background: the strip's gold and borders belong to the screen. Coordinates are local to the strip (its rect on the canvas).

const FLASH_PERIOD := 59.0 / 60.0 ## the white flash comes round every 59 frames
const CRIMSON := Color8(225, 48, 55) ## the outermost stripe at each end of the pill
const ORANGE := Color8(255, 95, 0)
const RED := Color8(255, 0, 0) ## the ring round the black plate
const BLACK := Color8(0, 0, 0)
const YELLOW := Color8(255, 248, 0)
const WHITE := Color(1, 1, 1, 1)
const LABEL := "WATCH OUT!"
const TEXT_WIDTH := 76.5 ## the letters' ink, measured (x 202..278.5)

var font: Font = null
var pill_age := -1.0 ## seconds since WATCH OUT! appeared; negative = not showing

func _init(font_: Font = null) -> void:
	name = "StatusStrip"
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## How long WATCH OUT! has been showing (negative: it is not). Cheap to call every frame; it redraws while the flash is moving.
func set_pill(age: float) -> void:
	var was := pill_age
	pill_age = age if age >= 0.0 else -1.0
	if was < 0.0 and pill_age < 0.0:
		return
	if (was < 0.0) != (pill_age < 0.0) or flash_alpha(pill_age) > 0.0 or flash_alpha(was) > 0.0:
		queue_redraw()

func is_showing() -> bool:
	return pill_age >= 0.0

## The white overlay's opacity `age_` seconds after WATCH OUT! appeared: 1 on the first frame, then a straight fall to 0 over the next 7
## (the pill's fill, black at rest, read 255, 248, 210, 174, 138, 103, 62, 20, 0 on nine consecutive frames), and again every
## FLASH_PERIOD.
static func flash_alpha(age_: float) -> float:
	if age_ < 0.0:
		return 0.0
	var k := fposmod(age_, FLASH_PERIOD) * 60.0 # frames into this flash
	if k < 1.0:
		return 1.0
	return clampf(0.97 - 0.145 * (k - 1.0), 0.0, 1.0)

## The pill's rectangles, outermost first, for the layout's pill rect (any space: pass the strip-local one): the crimson stripe, the
## orange, the red ring, the black plate.
static func pill_layers(pill: Rect2) -> Array[Rect2]:
	return [pill, pill.grow_individual(-3.0, 0.0, -3.0, 0.0), pill.grow_individual(-6.0, 0.0, -6.0, 0.0),
		pill.grow_individual(-8.5, -1.25, -8.5, -1.25)]

func _draw() -> void:
	if pill_age >= 0.0:
		_pill()

func _local_pill() -> Rect2:
	return Rect2(BattleHudLayout.PILL.position - position, BattleHudLayout.PILL.size)

func _pill() -> void:
	var layers := pill_layers(_local_pill())
	BattleHudShapes.pill(self, layers[0], CRIMSON, CRIMSON, 0.5)
	BattleHudShapes.pill(self, layers[1], ORANGE, ORANGE, 0.5)
	BattleHudShapes.pill(self, layers[2], RED, RED, 0.5)
	var plate: Rect2 = layers[3]
	BattleHudShapes.box(self, plate, BLACK, BLACK, 2.0, 0.5)
	var ts := BattleHudText.fit_scale(LABEL, TEXT_WIDTH, 1.0)
	var w := BattleHudText.ink_width(LABEL, ts)
	var tl := plate.get_center() - Vector2(w, BattleHudText.ink_height(ts)) / 2.0
	BattleHudText.draw(self, font, LABEL, tl, ts, YELLOW)
	BattleHudText.draw(self, font, LABEL, tl + Vector2(0.4, 0), ts, YELLOW) # a second pass makes the letters bold
	var a := flash_alpha(pill_age)
	if a > 0.0:
		var white := WHITE
		white.a = a
		BattleHudShapes.pill(self, layers[0], white, white, 0.5)
