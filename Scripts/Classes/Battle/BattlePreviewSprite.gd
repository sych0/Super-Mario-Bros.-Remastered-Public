class_name BattlePreviewSprite
extends RefCounted
## One preview sprite frame: a cropped texture plus where its top-left corner sits
## relative to the anchor (the feet, bottom-centre of the original cell).

var texture: Texture2D = null
var offset := Vector2.ZERO
var size := Vector2.ZERO
