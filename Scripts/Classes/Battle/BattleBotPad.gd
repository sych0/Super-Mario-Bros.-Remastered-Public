class_name BattleBotPad
extends RefCounted
## A Battle opponent's controller (doc 56): the buttons its Mario is pressing. The bot's brain
## (BattleBotController) writes it once per physics tick before Mario moves; Mario reads it through the same
## `Global.player_action_pressed / just_pressed / just_released (action, player_id)` calls that read a human's
## pad, so an opponent plays with exactly the inputs a person has: left, right, up, down, run, jump, action.
## Pads are found by player id; a bot's Mario has the id ID_BASE + its contestant id, which no human pad uses.

const ID_BASE := 100
const ACTIONS := ["move_left", "move_right", "move_up", "move_down", "run", "jump", "action"]

static var _pads := {} ## player id -> BattleBotPad

var player_id := 0
var _held := {} ## action -> bool
var _down_tick := {} ## action -> physics frame it went down
var _up_tick := {} ## action -> physics frame it came up

static func claims(player_id_) -> bool:
	return player_id_ is int and player_id_ >= ID_BASE and _pads.has(player_id_)

static func of(player_id_: int) -> BattleBotPad:
	return _pads.get(player_id_)

static func register(contestant_id: int) -> BattleBotPad:
	var pad := BattleBotPad.new()
	pad.player_id = ID_BASE + contestant_id
	_pads[pad.player_id] = pad
	return pad

static func release(pad: BattleBotPad) -> void:
	if pad != null and _pads.get(pad.player_id) == pad:
		_pads.erase(pad.player_id)

## Sets every button for this tick (`buttons`: action -> held). A button that goes down now is "just pressed" for
## this physics tick only, like a real press; one that comes up is "just released".
func set_buttons(buttons: Dictionary) -> void:
	var tick := Engine.get_physics_frames()
	for action in ACTIONS:
		var now: bool = buttons.get(action, false)
		var was: bool = _held.get(action, false)
		if now and not was:
			_down_tick[action] = tick
		elif was and not now:
			_up_tick[action] = tick
		_held[action] = now

func pressed(action: String) -> bool:
	return _held.get(action, false)

func just_pressed(action: String) -> bool:
	return _held.get(action, false) and _down_tick.get(action, -1) == Engine.get_physics_frames()

func just_released(action: String) -> bool:
	return not _held.get(action, false) and _up_tick.get(action, -1) == Engine.get_physics_frames()

## The held buttons as a bitmask in ACTIONS order (for traces and determinism checks).
func mask() -> int:
	var m := 0
	for i in ACTIONS.size():
		if _held.get(ACTIONS[i], false):
			m |= 1 << i
	return m
