class_name BattleCourse
extends RefCounted
## Pure course numbering shared by the Battle session, the HUD and the opponent previews.
## Course `i` (0-based, = levels cleared) is the SMB1 level world 1 + i / 4, level 1 + i % 4.

const LEVELS_PER_WORLD := 4
const COURSE_COUNT := 32

static func world_of(course: int) -> int:
	return 1 + course / LEVELS_PER_WORLD

static func level_of(course: int) -> int:
	return 1 + course % LEVELS_PER_WORLD

static func text(course: int) -> String:
	return "%d-%d" % [world_of(course), level_of(course)]

## Scene path of the SMB1 level for `course`, or "" past 8-4.
static func scene_path(course: int) -> String:
	if course < 0 or course >= COURSE_COUNT:
		return ""
	return "res://Scenes/Levels/SMB1/World%d/%d-%d.tscn" % [world_of(course), world_of(course), level_of(course)]

## The node scripts that mark where a level ends. The real player's live progress and the
## bots' progress share this one definition of "the goal".
static func is_goal_script(script: Script) -> bool:
	return script != null and (script.resource_path.ends_with("EndFlagpole.gd") or script.resource_path.ends_with("CastleBridge.gd"))
