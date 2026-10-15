class_name BattlePreviewRenderer
extends RefCounted
## Draws the inside of one opponent preview at 1:1 gameplay scale into a BattlePreviewCell
## (187x240 texels of the shared atlas); the pane scales the picture down. So a future
## renderer can show simplified real gameplay (sprites, enemies, attacks) by overriding
## draw() without any change to the screen layout.

## `_frame` is only set by renderers that reenact a run (see BattlePreviewTrack); the
## placeholder ignores it.
func draw(_canvas: CanvasItem, _contestant: BattleContestant, _logical_size: Vector2, _frame: BattlePreviewFrame = null) -> void:
	pass
