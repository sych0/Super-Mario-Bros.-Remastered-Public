class_name BattleAttribution
extends RefCounted
## Who an enemy kill counts as, for Battle. The real game's kill paths hand this class the thing that
## killed the enemy (the Player that stomped it, the Projectile that hit it, the Block that bounced it,
## the Shell that ran into it...) and get back one plain Source. Only Source.PLAYER sends an enemy.
##
## The classification is deliberately conservative: a kill is PLAYER only when a path PROVES it was
## the real player's doing, and anything that cannot be traced to a cause is UNKNOWN (which sends
## nothing). It is a single pure function over plain game nodes, called from the one place the game
## reports a kill (Enemy.report_battle_defeat), so no enemy subclass carries any Battle logic.
##
## Nodes are recognised by group, metadata and the script they run, never by a class reference:
## this file must stay free of references to Enemy, Shell, Projectile, Block or Player so that
## Enemy (which reports through here) and those classes can never form a dependency cycle.
##
## Provable PLAYER paths:
##   - a Player: stomped it (Goomba / Koopa stomp), hit it with the hammer, or touched it with a star
##   - a Projectile the player threw (carries the "IsPlayerProjectile" meta Player.throw_projectile sets)
##   - a Shell that a Player has kicked (`Shell.player` is that player) running into it
##   - a Block the player bumped from below within the last BUMP_FRAMES physics frames (the player tags
##     the block as it bumps it, in Battle only: `tag_block_bump`), bouncing an enemy off it
## ENEMY: another enemy killed it (an enemy that is not a player-kicked shell).
## ENVIRONMENT: a level hazard killed it (a spike ball, a falling icicle).
## UNKNOWN: everything else, by design: no cause given (`Enemy.die()`, Crate-spawned kills), a shell
##   nobody has kicked, an explosion, a block no player was seen bumping, an object this file does not know.
## (An enemy that falls into a pit or leaves the screen is despawned, not killed: it never reaches a
##  kill path at all, so there is nothing to attribute and nothing is sent.)
##
## The class also holds the ORIGIN of an enemy (doc 46): whether it is one of the level's own enemies
## (native) or a Battle-incoming enemy, the physical form of an attack another contestant sent to the
## real player. Who killed an enemy (`of`) and where it came from (`origin_of`) are separate facts:
## the session sends only for native kills by the player, and an incoming enemy's kill resolves its
## own attack instead.

enum Source {UNKNOWN, PLAYER, ENEMY, ENVIRONMENT}

const BUMP_META := "battle_bumped_by"
const BUMP_FRAMES := 30 ## physics frames a block bump stays attributable to the player who made it (about half a second)
const PLAYERS_GROUP := "Players"
const PLAYER_PROJECTILE_META := "IsPlayerProjectile"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const ENVIRONMENT_SCRIPTS := [
	"res://Scripts/Classes/Entities/Objects/SpikeBall.gd",
	"res://Scripts/Classes/Entities/Enemies/Icicle.gd",
]

## The Battle-incoming identity, as node metadata: PackedInt64Array [session uid, seq, sender, kind].
## A value type, so the copy `Node.duplicate()` makes (the Koopa that wakes from a shell) can never
## share or change the original's. Absent on every native enemy.
const ORIGIN_META := "battle_incoming"
const ORIGIN_SIZE := 4

static func name_of(source: int) -> String:
	return Source.keys()[source] if source >= 0 and source < Source.size() else "UNKNOWN"

## The Source of a kill caused by `cause` (null / a freed object / anything unrecognised -> UNKNOWN).
static func of(cause: Variant) -> int:
	if cause == null or not is_instance_valid(cause) or not cause is Node:
		return Source.UNKNOWN
	var node := cause as Node
	if node.is_in_group(PLAYERS_GROUP):
		return Source.PLAYER
	if node.has_meta(PLAYER_PROJECTILE_META):
		return Source.PLAYER
	if _runs_script(node, SHELL_SCRIPT):
		return Source.PLAYER if _is_live_player(node.get("player")) else Source.UNKNOWN
	if _bumped_by_player(node):
		return Source.PLAYER
	for path in ENVIRONMENT_SCRIPTS:
		if _runs_script(node, path):
			return Source.ENVIRONMENT
	if node.is_in_group("Enemies"):
		return Source.ENEMY
	return Source.UNKNOWN

## Marks `node` as the physical enemy of attack `seq` of session `session_uid`, sent by contestant
## `sender`, of BattleEnemyType.Kind `kind`. Only BattleIncomingSpawner calls this.
static func tag_incoming(node: Node, session_uid: int, seq: int, sender: int, kind: int) -> void:
	node.set_meta(ORIGIN_META, PackedInt64Array([session_uid, seq, sender, kind]))

## `node`'s Battle-incoming identity [session uid, seq, sender, kind], or an empty array for a native
## enemy (or anything malformed).
static func origin_of(node: Node) -> PackedInt64Array:
	if node == null or not node.has_meta(ORIGIN_META):
		return PackedInt64Array()
	var tag: Variant = node.get_meta(ORIGIN_META)
	if not tag is PackedInt64Array or (tag as PackedInt64Array).size() != ORIGIN_SIZE:
		return PackedInt64Array()
	return (tag as PackedInt64Array).duplicate() # a copy: nobody can change the enemy's identity through it

static func is_incoming(node: Node) -> bool:
	return not origin_of(node).is_empty()

## Called by the player at the moment it bumps `block` from below, in Battle only (the caller checks
## the mode, so this file never needs the Global singleton): remembers who, and when, so a bouncing
## block that kills an enemy can be attributed.
static func tag_block_bump(block: Node, player: Node) -> void:
	if block == null or player == null:
		return
	block.set_meta(BUMP_META, [player, Engine.get_physics_frames()])

static func _bumped_by_player(node: Node) -> bool:
	if not node.has_meta(BUMP_META):
		return false
	var tag: Array = node.get_meta(BUMP_META)
	return tag.size() == 2 and _is_live_player(tag[0]) and Engine.get_physics_frames() - int(tag[1]) <= BUMP_FRAMES

static func _is_live_player(obj: Variant) -> bool:
	return is_instance_valid(obj) and obj is Node and (obj as Node).is_in_group(PLAYERS_GROUP)

## Whether `node` runs `path` or a script that extends it.
static func _runs_script(node: Node, path: String) -> bool:
	var script := node.get_script() as Script
	while script != null:
		if script.resource_path == path:
			return true
		script = script.get_base_script()
	return false
