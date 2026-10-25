class_name MainMenu extends Control

@export_file("*.tscn") var world_scene_path: String = "res://scences/world.tscn"

@onready var start_button: Button = $CenterContainer/VBoxContainer/StartButton


func _ready() -> void:
	# 确保进入主菜单时显示鼠标指针并释放捕获
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if start_button != null:
		start_button.grab_focus()
		start_button.pressed.connect(_on_start_button_pressed)


func _on_start_button_pressed() -> void:
	print("[MainMenu] Starting game -> Transitioning to world scene: ", world_scene_path)
	get_tree().change_scene_to_file(world_scene_path)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_on_start_button_pressed()
