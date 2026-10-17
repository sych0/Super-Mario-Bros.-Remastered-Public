extends Node2D

const FLAG_POINTS := [100, 400, 800, 2000, 5000]

const FLAG_POINTS_MODERN := [100, 200, 800, 4000, 8000]

signal player_reached

signal sequence_begin

var flag_direction := -1

func on_area_entered(area: Area2D) -> void:
	if area.owner is Player:
		player_touch(area.owner)

func player_touch(player: Player) -> void:
	if ConditionalClear.valid == false:
		return
	player_reached.emit()
	var main := GameWorld.owns_globals(self) # a Battle opponent's flag (doc 56) is its own game's
	if main and Global.current_game_mode == Global.GameMode.MARATHON_PRACTICE:
		SpeedrunHandler.is_warp_run = false
		SpeedrunHandler.run_finished()
	if main:
		Global.can_pause = false
	if get_node_or_null("Top") != null:
		$Top.queue_free()
	$Hitbox.queue_free()
	GameWorld.call_group(self, "Enemies", "flag_die")
	give_points(player)
	if main:
		Global.can_time_tick = false
	if player.can_pose_anim == false:
		player.z_index = -2
	player.global_position.x = global_position.x - 5
	$Animation.play("FlagDown")
	player.state_machine.transition_to("FlagPole")
	if not player.physics_params("FLAG_SKIP_GRAB", player.ENDING_PARAMETERS):
		GameWorld.music_override(self, AudioManager.MUSIC_OVERRIDES.SILENCE, 99, false)
		GameWorld.global_sfx(self, "flag_slide")
		if player.physics_params("FLAG_HANG_TIMER", player.ENDING_PARAMETERS) > 0:
			await get_tree().create_timer(player.physics_params("FLAG_HANG_TIMER", player.ENDING_PARAMETERS), false).timeout
	else:
		GameWorld.global_sfx(self, "flag_slide")
	if not is_inside_tree():
		return # (a Battle opponent's game may have moved on to its next course already)
	sequence_begin.emit()
	if Global.current_game_mode == Global.GameMode.BOO_RACE:
		GameWorld.music_override(self, AudioManager.MUSIC_OVERRIDES.RACE_WIN, 99, false)
	else:
		GameWorld.music_override(self, AudioManager.MUSIC_OVERRIDES.LEVEL_COMPLETE, 99, false)
	GameWorld.emit_level_complete(self)
	deactivate_all_generators()
	await get_tree().create_timer(1, false).timeout
	if main and [Global.GameMode.BOO_RACE].has(Global.current_game_mode) == false:
		Global.tally_time()

func deactivate_all_generators() -> void:
	for i in GameWorld.group(self, "EntityGenerators"):
		i.active = false
		i.deactivate()
	GameWorld.call_group(self, "Enemies", "start_retreat") # Lakitus

func _ready() -> void:
	$FlagJoint/Flag.position.x = 8 * flag_direction
	$FlagJoint/Flag.scale.x = -flag_direction

func _physics_process(_delta: float) -> void:
	$Hollow.visible = not ConditionalClear.valid
	$Pole.visible = ConditionalClear.valid
	$FlagJoint.visible = $Pole.visible

func give_points(player: Player) -> void:
	var value = clamp(int(lerp(0, 4, (player.global_position.y / -144))), 0, 4)
	var nearest_value = FLAG_POINTS[value]
	if Settings.file.difficulty.flagpole_lives:
		nearest_value = FLAG_POINTS_MODERN[value]
	$Score.text = str(nearest_value)
	if nearest_value == 8000 and not [Global.GameMode.CHALLENGE, Global.GameMode.BOO_RACE].has(Global.current_game_mode) and not Settings.file.difficulty.inf_lives:
		GameWorld.sfx(self, "1_up", global_position)
		GameWorld.add_lives(self, 1)
		$ScoreNoteSpawner.spawn_one_up_note()
	else:
		GameWorld.add_score(self, nearest_value)
		$Score/Animation2.play("ScoreRise")
