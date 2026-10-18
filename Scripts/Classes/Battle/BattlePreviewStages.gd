class_name BattlePreviewStages
extends RefCounted
## The level behind each course of the opponent previews: for a course number, the level sketch and the baked art that its previews
## walk through (doc 55). A preview that clears its course moves on to the next one, so the previews are not tied to World 1-1: a course
## whose level the previews can walk is shown as itself.
##
## The sketch builder reads a level's tiles, blocks, enemies and flagpole from the saved scene, and the track walks Mario along a planned
## line over it. Not every one of the game's 32 courses can be shown that way yet: the underground, underwater and castle levels end without
## a flagpole, a few levels are inherited scenes, and on the treetop and several ground levels the planned walk crosses gaps or walls
## (measured by the walk audit in tests/battle_preview_course_test.gd). A course that cannot be shown is shown by a STAND-IN: one of the
## courses that can, the next in a fixed cycle after the one this preview has just left, and never the one the next course will show itself
## (`geometry_for`, pure), so a clear always looks like a different level. The label a preview carries
## (`BattlePreviewFrame.displayed_course`) is always the real course.
##
## `SKETCHED` is the set of courses whose level the previews can walk cleanly: a cache of that audit, so choosing a stand-in costs
## nothing at run time. The test fails when a listed course does not pass the audit, and a listed course whose sketch or art fails to
## build at run time is dropped for the rest of this object's life (the choice is made again), so a missing level degrades, never breaks.
## Courses join the list as the walk plan learns more levels.

const SKETCHED := [0, 9, 12, 17, 24] ## 1-1, 3-2, 4-1, 5-2, 7-1
const PREFETCH_PROGRESS := 0.5 ## a bot this far through its course gets the next course's art baked (no hitch at the clear)

var _stages := {} ## course -> {course, geometry, sketch, assets, stand_in}, or null if nothing could be built for it
var _failed := {} ## geometry courses whose sketch or art did not build
## Contestant ids the stages are never asked for: the world-driven opponents (doc 57), whose real BattleBotWorld shows its real
## course. Asking for one is refused ({}) and reported (BattleBotDirector.violation); it never gets a sketch or a stand-in.
var forbidden := {}
## Every stage request with the contestant it was for: [id, course] (0 = not said). Tests read it.
var queries: Array[Vector2i] = []

## The course whose level is drawn for `course`: `course` itself if it can be shown, else the next course of `sketched` (ascending, wrapping)
## after the one drawn for the course before it, skipping the one the next course shows itself. -1 if no course at all can be shown.
## Pure in `course`, `sketched` and `failed` (a dictionary of courses that did not build).
static func geometry_for(course: int, sketched: Array, failed := {}) -> int:
	if course < 0 or course >= BattleCourse.COURSE_COUNT:
		return -1
	if _usable(course, sketched, failed):
		return course
	var usable: Array[int] = []
	for c in sketched:
		if _usable(c, sketched, failed):
			usable.append(c)
	usable.sort()
	if usable.is_empty():
		return -1
	var previous := geometry_for(course - 1, sketched, failed) if course > 0 else -1
	var next := course + 1 if _usable(course + 1, sketched, failed) else -1
	var start := 0
	for i in usable.size():
		if usable[i] > previous:
			start = i
			break
	for off in usable.size():
		var c := usable[(start + off) % usable.size()]
		if c != previous and c != next:
			return c
	return usable[start]

static func _usable(course: int, sketched: Array, failed: Dictionary) -> bool:
	return course >= 0 and course < BattleCourse.COURSE_COUNT and sketched.has(course) and not failed.has(course)

## The stage of `course` ({course, geometry, sketch, assets, stand_in}), built on first use; {} if none can be built. Baking art takes
## about 0.1 s per level, so `prefetch` is called ahead of time. `for_id` is the contestant whose preview asks (0: none in particular).
func stage(course: int, for_id := 0) -> Dictionary:
	queries.append(Vector2i(for_id, course))
	if forbidden.has(for_id):
		BattleBotDirector.violation(for_id, "had BattlePreviewStages asked for course %d: refused" % course)
		return {}
	if _stages.has(course):
		var cached: Variant = _stages[course]
		if cached != null and not _failed.has(cached.geometry):
			return cached
	if course < 0 or course >= BattleCourse.COURSE_COUNT:
		return {}
	for _attempt in SKETCHED.size() + 1:
		var g := geometry_for(course, SKETCHED, _failed)
		if g < 0:
			_stages[course] = null
			return {}
		var sk := BattleLevelSketch.load_for(BattleCourse.scene_path(g))
		var art := BattlePreviewAssets.build(sk) if sk != null else null
		if sk == null or art == null:
			_failed[g] = true
			continue
		var s := {"course": course, "geometry": g, "sketch": sk, "assets": art, "stand_in": g != course}
		_stages[course] = s
		return s
	_stages[course] = null
	return {}

## Builds the stage of `course` now if it is not built yet (a no-op for a course out of range or already built).
func prefetch(course: int, for_id := 0) -> void:
	if course >= 0 and course < BattleCourse.COURSE_COUNT and not _stages.has(course):
		stage(course, for_id)

## Whether a stage was ever asked for on behalf of contestant `id`.
func queried_for(id: int) -> bool:
	for q in queries:
		if q.x == id:
			return true
	return false

func is_built(course: int) -> bool:
	return _stages.get(course) != null
