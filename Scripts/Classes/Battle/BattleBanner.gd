class_name BattleBanner
extends Control
## The big words over the game window while a round starts (doc 47 B35-RESULT-001): HERE WE GO..., READY, 3, 2, 1,
## GO! Large outlined letters, centred in the window. A view only: BattleScreen sets `text` from
## BattleRound.banner_text() each frame; a new word pops in (a short overshoot), the same word just stays.
## Colours: the numerals and READY are red/orange with a white outline, GO! and HERE WE GO... likewise (the reference
## shows the countdown that way); the pop is the same for all of them.
##
## `age` is real time since the word changed and only advances while the screen's clock runs (the pause holds it).

const POP_SECONDS := 0.22
const POP_OVERSHOOT := 0.35
const FACE := Color(1.0, 0.27, 0.1, 1)
const FACE_LIGHT := Color(1.0, 0.55, 0.2, 1)
const OUTLINE := Color(1, 1, 1, 1)
const SHADOW := Color(0.25, 0.08, 0.02, 0.85)
const SCALE_BY_LENGTH := [6.0, 5.0, 5.0, 4.0, 3.5] ## text scale for 1, 2, 3.. characters; longer words are fitted to the window

var font: Font = null
var text := "":
	set(value):
		if value != text:
			text = value
			age = 0.0
			queue_redraw()
		visible = text != ""
var age := 0.0

func _init(font_: Font = null) -> void:
	name = "Banner"
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false

func advance(delta: float) -> void:
	if delta > 0.0 and visible and age < POP_SECONDS:
		age += delta
		queue_redraw()

## The scale factor `age_` seconds after the word appeared: 0.4 -> a little past 1 -> 1 (an ease-out-back).
static func pop_scale(age_: float) -> float:
	if age_ >= POP_SECONDS:
		return 1.0
	var t := clampf(age_ / POP_SECONDS, 0.0, 1.0)
	var c1 := 1.0 + POP_OVERSHOOT * 2.0
	var u := t - 1.0
	var back := 1.0 + (c1 + 1.0) * u * u * u + c1 * u * u
	return lerpf(0.4, 1.0, back)

## The text scale that `word` is drawn at when `width` is the room.
static func word_scale(word: String, width: float) -> float:
	var base: float = SCALE_BY_LENGTH[mini(word.length(), SCALE_BY_LENGTH.size()) - 1] if word != "" else 1.0
	return BattleHudText.fit_scale(word, width, base)

func _draw() -> void:
	if text == "":
		return
	var s := word_scale(text, size.x - 16.0) * pop_scale(age)
	var box := Vector2(BattleHudText.ink_width(text, s), BattleHudText.ink_height(s))
	var top_left := (size - box) / 2.0
	BattleHudText.draw(self, font, text, top_left + Vector2(0, 1.5 * s / 4.0 + 1.0), s, SHADOW)
	BattleHudText.draw(self, font, text, top_left, s, FACE, OUTLINE, maxf(1.0, s / 3.0))
