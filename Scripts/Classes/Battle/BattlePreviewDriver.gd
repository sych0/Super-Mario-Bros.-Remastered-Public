class_name BattlePreviewDriver
extends RefCounted
## Feeds the BattleSession's authoritative state and events to the preview tracks and steps
## them. One-way: it only reads the session. The pictures run LAG session-seconds behind the
## session (so a track always knows the next outcome before it has to show it); the session's
## own state, and everything the HUD shows from it, is never delayed.

const LAG := 2.0
const LIVE_COURSE := 0 ## milestone 1: only the first course (World 1-1) has a live preview
const DEBUG_VIEW_ARG := "--battle-preview-debug"
const DEBUG_VIEW_ENV := "SMB1R_BATTLE_PREVIEW_DEBUG"
const DEBUG_ALL_ARG := "--battle-preview-all"
const DEBUG_ALL_ENV := "SMB1R_BATTLE_PREVIEW_ALL"

static var _flag_cache := {}

## DEVELOPMENT ONLY (debug builds): `--battle-preview-debug` (after `--`) also draws opponent
## #1 at full 256x240 over the centre.
static func debug_full_view() -> bool:
	return _flag(DEBUG_VIEW_ARG, DEBUG_VIEW_ENV)

## DEVELOPMENT ONLY (debug builds): `--battle-preview-all` puts all 34 windows on the live
## renderer, to measure its cost. Normal play uses it for opponent #1 only.
static func debug_all() -> bool:
	return _flag(DEBUG_ALL_ARG, DEBUG_ALL_ENV)

static func _flag(arg: String, env: String) -> bool:
	if _flag_cache.has(arg):
		return _flag_cache[arg]
	var on := false
	if OS.is_debug_build():
		on = OS.get_environment(env) == "1" or OS.get_cmdline_user_args().has(arg)
	_flag_cache[arg] = on
	return on

var session: BattleSession = null
var tracks := {} ## contestant id -> BattlePreviewTrack
var sketch: BattleLevelSketch = null
var assets: BattlePreviewAssets = null
var update_us := 0 ## cost of the last update(), for measurements

var _event_cursor := 0
var _pushed_tick := -1

## Null if the course's level or art cannot be built (everything then stays on the placeholder).
static func create(session_: BattleSession, ids: Array, logical_w: float) -> BattlePreviewDriver:
	var sk := BattleLevelSketch.load_for(BattleCourse.scene_path(LIVE_COURSE))
	if sk == null:
		return null
	var art := BattlePreviewAssets.build(sk)
	if art == null:
		return null
	var d := BattlePreviewDriver.new()
	d.session = session_
	d.sketch = sk
	d.assets = art
	var view_w := BattleMiniGameRenderer.world_width(logical_w)
	for id in ids:
		d.tracks[id] = BattlePreviewTrack.new(id, sk, art, session_.seed_value, view_w, LIVE_COURSE)
	d._event_cursor = session_.events.size()
	d._push()
	return d

## Preview time for the session's current moment (`alpha` = how far into the current second).
func visual_time(alpha: float) -> float:
	return maxf(float(session.tick_count) + alpha - LAG, 0.0)

## Advances every track to now. Returns the ids whose picture changed.
func update(alpha: float) -> Array:
	var t0 := Time.get_ticks_usec()
	if session.tick_count != _pushed_tick:
		_push()
	var vt := visual_time(alpha)
	var changed: Array = []
	for id in tracks:
		if tracks[id].advance_to(vt):
			changed.append(id)
	update_us = Time.get_ticks_usec() - t0
	return changed

func _push() -> void:
	_pushed_tick = session.tick_count
	var by_id := {}
	for i in range(_event_cursor, session.events.size()):
		var e: Dictionary = session.events[i]
		if tracks.has(e.id):
			if not by_id.has(e.id):
				by_id[e.id] = []
			by_id[e.id].append(e)
	_event_cursor = session.events.size()
	for id in tracks:
		var c := session.contestants[id]
		tracks[id].push(session.tick_count, c.levels_cleared, c.progress, c.power, c.alive, by_id.get(id, []))
