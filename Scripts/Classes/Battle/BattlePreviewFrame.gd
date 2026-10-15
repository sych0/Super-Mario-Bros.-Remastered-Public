class_name BattlePreviewFrame
extends RefCounted
## Plain data describing one preview picture. Written by a BattlePreviewTrack, read by
## BattleMiniGameRenderer. Holds no logic and is never read back by the Battle session.

var valid := false ## false: the renderer should not draw this (surface falls back to the placeholder)
var sketch: BattleLevelSketch = null
var assets: BattlePreviewAssets = null

var camera_x := 0.0 ## left edge of the view in world px, for a view `view_w` wide
var view_w := 117.0
var cam_min := 0.0
var cam_max := 0.0
var displayed_course := 0
var time := 0.0 ## preview time in session seconds (also drives the background drift)

var mario_sprite: BattlePreviewSprite = null
var mario_x := 0.0
var mario_y := 0.0
var mario_visible := true
var pose := ""
var pose_index := 0

## Each entry: [BattlePreviewSprite, world x, world y, flip(bool)]
var actors: Array = []
var flag_y := -151.0
var flag_visible := false
var fade := 0.0 ## 0..1 black
var ko_overlay := false ## the death animation has finished: show the KO marking

## Compact text form for determinism checks.
func signature() -> String:
	var parts := PackedStringArray()
	parts.append("%s|%.2f|%.2f|%.2f|%s|%d|%d|%.2f|%.2f|%d|%d" % [valid, camera_x, mario_x, mario_y, pose, pose_index,
		int(mario_visible), flag_y, fade, int(ko_overlay), displayed_course])
	for a in actors:
		parts.append("%.2f,%.2f,%d" % [a[1], a[2], int(a[3])])
	return ";".join(parts)
