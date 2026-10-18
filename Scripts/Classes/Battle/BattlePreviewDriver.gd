class_name BattlePreviewDriver
extends RefCounted
## Feeds the BattleSession's authoritative state and events to the preview tracks and steps
## them. One-way: it only reads the session. The pictures run LAG session-seconds behind the
## session (so a track always knows the next outcome before it has to show it); the session's
## own state, and everything the HUD shows from it, is never delayed.

const LAG := 2.0
const FIRST_COURSE := 0 ## the course every preview starts on (World 1-1); a preview that clears its course moves on to the next (doc 55)
const DEBUG_VIEW_ARG := "--battle-preview-debug"
const DEBUG_VIEW_ENV := "SMB1R_BATTLE_PREVIEW_DEBUG"

static var _flag_cache := {}

## DEVELOPMENT ONLY (debug builds): `--battle-preview-debug` (after `--`) also shows opponent
## #1's atlas cell at its native 187x240 over the centre (the same image, not a second render).
static func debug_full_view() -> bool:
	return _flag(DEBUG_VIEW_ARG, DEBUG_VIEW_ENV)

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
var sketch: BattleLevelSketch = null ## the first course's level (every preview starts there)
var assets: BattlePreviewAssets = null
var stages: BattlePreviewStages = null ## the level and art of every course a preview may move on to, built when first needed
var update_us := 0 ## cost of the last update(), for measurements

var _event_cursor := 0
var _pushed_tick := -1

## Null if the first course's level or art cannot be built (everything then stays on the placeholder). A later course whose level
## cannot be built is shown by a stand-in (BattlePreviewStages), so a preview never ends in the placeholder.
## `ids` are the opponents the previews may draw: never a world-driven one (doc 57). One is refused (BattleBotDirector.violation),
## and the stages refuse its courses too.
static func create(session_: BattleSession, ids: Array, logical_w: float) -> BattlePreviewDriver:
	var st := BattlePreviewStages.new()
	for c in session_.contestants:
		if c.world_driven:
			st.forbidden[c.id] = true
	var first := st.stage(FIRST_COURSE)
	if first.is_empty():
		return null
	var d := BattlePreviewDriver.new()
	d.session = session_
	d.sketch = first.sketch
	d.assets = first.assets
	d.stages = st
	var view_w := BattleMiniGameRenderer.world_width(logical_w)
	for id in ids:
		if session_.contestants[id].world_driven:
			BattleBotDirector.violation(id, "was given to the legacy previews (BattlePreviewDriver): refused")
			continue
		var course := session_.contestants[id].levels_cleared # (0 at the start of a match; a driver made mid-match starts where each opponent is)
		var stage := st.stage(course, id)
		if stage.is_empty():
			stage = first
			course = FIRST_COURSE
		d.tracks[id] = BattlePreviewTrack.new(id, stage.sketch, stage.assets, session_.seed_value, view_w, course, st)
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
		if c.alive and c.progress >= BattlePreviewStages.PREFETCH_PROGRESS and not stages.is_built(c.levels_cleared + 1):
			stages.prefetch(c.levels_cleared + 1, id) # the next course's art is baked well before the picture needs it

## Holds every picture at a state that can be shown at rest (the round is over): a pane caught in the dark between two courses is on the
## next one. Nothing else changes, and the tracks are not stepped again.
func settle() -> void:
	for id in tracks:
		tracks[id].settle()
