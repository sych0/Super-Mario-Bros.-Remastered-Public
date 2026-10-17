extends PowerUpItem

const MOVE_SPEED := 65

func _physics_process(delta: float) -> void:
	$BasicEnemyMovement.handle_movement(delta)

func on_area_entered(area: Area2D) -> void:
	if area.owner is Player:
		if has_meta("is_poison"):
			area.owner.damage()
			collected.emit()
			queue_free()
		elif has_meta("is_oneup"):
			give_life(area.owner)
			collected.emit()
		else:
			collect_item(area.owner)

func give_life(_player: Player) -> void:
	DiscoLevel.combo_amount += 1
	GameWorld.sfx(self, "1_up", global_position)
	if [Global.GameMode.CHALLENGE, Global.GameMode.BOO_RACE].has(Global.current_game_mode) or Settings.file.difficulty.inf_lives:
		GameWorld.add_score(self, 2000)
		$ScoreNoteSpawner.spawn_note(2000)
	else:
		GameWorld.add_lives(self, 1)
		$ScoreNoteSpawner.spawn_one_up_note()
	queue_free()
