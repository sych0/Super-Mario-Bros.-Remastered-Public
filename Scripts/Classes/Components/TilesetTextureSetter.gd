class_name TilesetTextureSetter
extends Node

@export var tile_map: TileMapLayer
@export var texture: Texture = null:
	set(value):
		texture = value
		texture_changed.emit()

signal texture_changed

@export var atlas_id := 0

func _ready() -> void:
	update()
	texture_changed.connect(update)

func update() -> void:
	if GameWorld.is_bot(self):
		# A Battle opponent's level (doc 56) never retextures the TileSet every level shares: it uses a themed copy.
		tile_map.tile_set = BattleBotWorld.tileset_with(tile_map.tile_set, atlas_id, texture)
		return
	var source = tile_map.tile_set.get_source(atlas_id)
	if source != null and source.texture != texture:
		source.texture = texture # (unchanged: no "changed" for every TileMapLayer sharing this TileSet to rebuild on)
