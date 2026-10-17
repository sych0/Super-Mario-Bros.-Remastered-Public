class_name CameraRightLimit
extends Node2D

@export var reset_on_delete := true
@export var lock_camera := false
@export var set_on_load := true

func _enter_tree() -> void:
	add_to_group("CameraLimits")
	if set_on_load or is_node_ready():
		GameWorld.set_camera_right_limit(self, int(global_position.x))

func _exit_tree() -> void:
	if reset_on_delete:
		GameWorld.set_camera_right_limit(self, int(99999999))

func return_camera_to_normal() -> void:
	for i in GameWorld.players(self):
		GameWorld.set_camera_right_limit(self, int(9999999))
		GameWorld.set_cam_locked(self, false)
		i.reset_camera_to_center()


func on_screen_entered() -> void:
	if lock_camera:
		GameWorld.set_cam_locked(self, true)
