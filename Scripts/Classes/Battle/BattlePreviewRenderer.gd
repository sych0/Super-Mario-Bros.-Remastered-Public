class_name BattlePreviewRenderer
extends RefCounted
## Draws the inside of one opponent preview in a fixed logical 256x240 space (the classic
## gameplay area). A BattlePreviewSurface scales that space into its slot, so a future
## renderer can show simplified real gameplay (sprites, enemies, attacks) by overriding
## draw() without any change to the screen layout.

## `_frame` is only set by renderers that reenact a run (see BattlePreviewTrack); the
## placeholder ignores it.
func draw(_canvas: CanvasItem, _contestant: BattleContestant, _logical_size: Vector2, _frame: BattlePreviewFrame = null) -> void:
	pass
