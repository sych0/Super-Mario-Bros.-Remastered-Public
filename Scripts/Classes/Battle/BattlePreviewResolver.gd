class_name BattlePreviewResolver
extends RefCounted
## Deliberately small art resolver for the opponent previews.
##
## ResourceSetterNew is a Node that reads Global.level_theme / theme_time / current_campaign /
## world_num / level_num / the real player's character, and mutates global overrides, so it
## cannot say "give me the Underground goomba" while another level is being played. Its
## pure part is the resource-pack precedence and the walk down a JSON's "variations" tree.
## This class repeats only those two rules with the theme passed in explicitly.
##
## LIMITATION (documented in docs/37): config: / flag: / Metadata / choices / sequence
## variation keys are not interpreted. A JSON that needs them fails to resolve, and the
## preview falls back to the placeholder instead of guessing.

const MAX_DEPTH := 32

## Resource packs, highest priority first, exactly as the game stores them.
static func default_packs() -> Array:
	var packs: Array = []
	for p in Settings.file.visuals.resource_packs:
		packs.append(p)
	return packs

## First pack that provides `res_path` (res://Assets/... mirrored under user://resource_packs/<pack>/...).
static func pack_file(res_path: String, packs: Array, config_path: String) -> String:
	for pack in packs:
		var user_path := res_path.replace("res://Assets", config_path.path_join("resource_packs/" + str(pack)))
		if FileAccess.file_exists(user_path):
			return user_path
	return res_path

## Returns {ok, source (image path), rect (Rect2i, size 0 = whole image), animations, json}.
static func resolve(json_path: String, theme: String, time: String, campaign: String, packs: Array = [], config_path := "") -> Dictionary:
	if packs.is_empty():
		packs = default_packs()
	if config_path == "":
		config_path = Global.config_path
	var fail := {"ok": false}
	var real_json := pack_file(json_path, packs, config_path)
	if not FileAccess.file_exists(real_json):
		return fail
	var root := JSONParser.parse_to_dict(real_json)
	if root.is_empty():
		return fail
	var leaf: Dictionary = root
	if root.has("variations"):
		leaf = walk(root.variations, theme, time, campaign)
	if not leaf.has("source") or not leaf.source is String:
		return fail
	var anims: Dictionary = {}
	if leaf.has("animations"):
		anims = leaf.animations.duplicate(true)
	elif root.has("animations"):
		anims = root.animations.duplicate(true)
	if leaf.has("animation_overrides"):
		for k in leaf.animation_overrides:
			anims[k] = leaf.animation_overrides[k]
	var rect := Rect2i()
	if leaf.has("rect") and leaf.rect is Array and leaf.rect.size() == 4:
		rect = Rect2i(int(leaf.rect[0]), int(leaf.rect[1]), int(leaf.rect[2]), int(leaf.rect[3]))
	var source := json_path.get_base_dir().path_join(leaf.source)
	source = pack_file(source, packs, config_path)
	return {"ok": true, "source": source, "rect": rect, "animations": anims, "json": json_path}

## Mirrors ResourceSetterNew.get_variation_json's descent, minus its global lookups.
static func walk(node: Dictionary, theme: String, time: String, campaign: String) -> Dictionary:
	for _depth in MAX_DEPTH:
		var next: Variant = null
		for key in _candidate_keys(node, theme, time, campaign):
			if node.has(key) and node[key] is Dictionary:
				next = node[key]
				if next.has("link") and node.has(next.link) and node[next.link] is Dictionary:
					next = node[next.link]
				break
		if next == null:
			return node
		node = next
	return node

# The order the game applies its selectors in; the first one the node has wins this round.
static func _candidate_keys(node: Dictionary, theme: String, time: String, campaign: String) -> Array:
	var keys: Array = []
	keys.append(theme if node.has(theme) else "default")
	keys.append(time)
	keys.append(campaign if node.has(campaign) else "SMB1")
	keys.append_array(["World1", "Level1", "Quest:1", "RoomType:MainRoom", "RoomType:Default",
		"GameMode:Campaign", "Character:Mario", "Character:default"])
	return keys
