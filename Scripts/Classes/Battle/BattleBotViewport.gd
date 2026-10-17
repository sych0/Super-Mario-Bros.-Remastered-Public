class_name BattleBotViewport
extends SubViewport
## The viewport a Battle opponent's game runs in (doc 56). Its own World2D gives the opponent its own physics space,
## so its Mario, enemies and blocks never meet another game's. It is the classic 256x240 screen, so the real camera,
## its walls and the enemy activation see exactly the screen they see in the player's game. It never renders by
## itself: the opponent's simulation never depends on rendering (its screen is worked out from the camera,
## BattleBotWorld), and the pane's picture is rendered from it on BattleBotDirector's schedule.

var world: BattleBotWorld = null

func _init(world_: BattleBotWorld = null) -> void:
	world = world_
	name = "BotViewport"
	size = Vector2i(BattleHudLayout.GAME_SIZE)
	disable_3d = true
	audio_listener_enable_2d = false
	snap_2d_transforms_to_pixel = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
