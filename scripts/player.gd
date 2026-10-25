class_name Player extends CharacterBody3D

@export var mouse_sensitivity: float = 0.005
@export var speed: int = 50
@export var jump_velocity: float = 20

@onready var head: Node3D = $Head
@onready var eye_camera: Camera3D = $Head/EyeCamera

var flying: bool = false
var floor_logged: bool = false
var chunk_manager: ChunkManager = null

# 快捷物品栏（10 个可用方块槽位，支持数字键 1~0 与鼠标滚轮切换）
const HOTBAR_ITEMS: Array[int] = [
	1,  # [1] 草方块 (GRASS)
	5,  # [2] 泥土 (DIRT)
	2,  # [3] 岩石 (MOUNTAIN/STONE)
	0,  # [4] 沙子 (SAND, HasGravity 掉落)
	6,  # [5] 原木 (WOOD, Flammable 易燃)
	7,  # [6] 树叶 (LEAVES, Flammable/Transparent)
	10, # [7] 玻璃 (GLASS, Transparent 透光)
	11, # [8] 荧石 (GLOWSTONE, Emissive 自发光光源)
	3,  # [9] 雪块 (SNOW)
	8,  # [0] 水体 (WATER, Fluid 动态流体)
]

var hotbar_index: int = 0 # 0 ~ 9
var hotbar_canvas: CanvasLayer = null
var hotbar_slots: Array[PanelContainer] = []
var hotbar_info_label: Label = null


func _ready() -> void:
	add_to_group("player")
	if get_parent() != null and get_parent().has_node("ChunckManager"):
		chunk_manager = get_parent().get_node("ChunckManager") as ChunkManager

	setup_hotbar_hud()


func setup_hotbar_hud() -> void:
	hotbar_canvas = CanvasLayer.new()
	hotbar_canvas.name = "PlayerHotbarHUD"
	hotbar_canvas.layer = 5 # 位于底层光追视图之上，顶层菜单之下
	add_child(hotbar_canvas)

	var root_container = Control.new()
	root_container.name = "HotbarRoot"
	root_container.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	root_container.custom_minimum_size = Vector2(0, 100)
	root_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hotbar_canvas.add_child(root_container)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	vbox.position = Vector2(-280, -96)
	vbox.custom_minimum_size = Vector2(560, 80)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_container.add_child(vbox)

	# 顶部状态标签：显示当前手持方块名称、材质与 Caelix 动态体素特性描述
	hotbar_info_label = Label.new()
	hotbar_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hotbar_info_label.add_theme_font_size_override("font_size", 15)
	hotbar_info_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hotbar_info_label.add_theme_constant_override("outline_size", 3)
	vbox.add_child(hotbar_info_label)

	# 底部快捷栏槽位横条
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 6)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hbox)

	var palette = VoxelTypeRegistry.GetColorPalette()

	for i in range(HOTBAR_ITEMS.size()):
		var v_id = HOTBAR_ITEMS[i]
		var slot_panel = PanelContainer.new()
		slot_panel.custom_minimum_size = Vector2(46, 46)
		slot_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var slot_color_rect = ColorRect.new()
		slot_color_rect.custom_minimum_size = Vector2(36, 36)
		var c = palette[v_id] if palette.has(v_id) else Color.WHITE
		slot_color_rect.color = Color(c.r, c.g, c.b, 1.0)
		slot_color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var margin = MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 4)
		margin.add_theme_constant_override("margin_right", 4)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		margin.add_child(slot_color_rect)
		slot_panel.add_child(margin)

		var num_label = Label.new()
		num_label.text = str((i + 1) % 10)
		num_label.add_theme_font_size_override("font_size", 11)
		num_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		num_label.add_theme_color_override("font_outline_color", Color.BLACK)
		num_label.add_theme_constant_override("outline_size", 2)
		slot_panel.add_child(num_label)

		hbox.add_child(slot_panel)
		hotbar_slots.append(slot_panel)

	update_hotbar_ui()


func update_hotbar_ui() -> void:
	for i in range(hotbar_slots.size()):
		var slot = hotbar_slots[i]
		var is_selected = (i == hotbar_index)
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(4)
		if is_selected:
			style.bg_color = Color(0.2, 0.35, 0.5, 0.85)
			style.set_border_width_all(2)
			style.border_color = Color(0.4, 0.9, 1.0, 1.0) # 高亮青色边框
		else:
			style.bg_color = Color(0.1, 0.12, 0.16, 0.7)
			style.set_border_width_all(1)
			style.border_color = Color(0.3, 0.35, 0.4, 0.6)
		slot.add_theme_stylebox_override("panel", style)

	var cur_id = HOTBAR_ITEMS[hotbar_index]
	var v_name = VoxelTypeRegistry.GetVoxelName(cur_id)
	var v_flags = VoxelTypeRegistry.GetVoxelFlagsDescription(cur_id)
	if hotbar_info_label != null:
		hotbar_info_label.text = "[槽位 %d] %s  %s  (滚轮 / 键盘 1~0 切换)" % [
			(hotbar_index + 1) % 10,
			v_name,
			v_flags
		]


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		if flying:
			velocity = Vector3.ZERO
		else:
			velocity += get_gravity() * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
	if Input.is_action_pressed("jump") and flying:
		velocity.y = jump_velocity
	if Input.is_action_just_pressed("flying"):
		flying = !flying
		
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (eye_camera.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		if flying:
			velocity = direction * speed
		else:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()
	
	if is_on_floor() and not floor_logged:
		floor_logged = true
		print("[PHYSICS SUCCESS] Player landed on ground! Pos: ", global_position, " IsOnFloor: ", is_on_floor())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var relative = event.relative * mouse_sensitivity
			head.rotate_y(-relative.x)
			eye_camera.rotate_x(-relative.y)
			eye_camera.rotation.x = clamp(eye_camera.rotation.x, deg_to_rad(-65), deg_to_rad(65))

	# 键盘数字键 1~0 快速选择快捷槽位
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			hotbar_index = event.keycode - KEY_1
			update_hotbar_ui()
		elif event.keycode == KEY_0:
			hotbar_index = 9
			update_hotbar_ui()

	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return

		# 鼠标滚轮循环切换当前手持方块
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			hotbar_index = (hotbar_index - 1 + HOTBAR_ITEMS.size()) % HOTBAR_ITEMS.size()
			update_hotbar_ui()
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			hotbar_index = (hotbar_index + 1) % HOTBAR_ITEMS.size()
			update_hotbar_ui()
			return

		var cam_forward = -eye_camera.global_transform.basis.z.normalized()
		var hit = raycast_voxel(eye_camera.global_position, cam_forward, 8.0)
		if hit.get("hit", false):
			var hit_pos: Vector3i = hit["position"]
			var hit_norm: Vector3i = hit["normal"]
			if event.button_index == MOUSE_BUTTON_LEFT:
				# 鼠标左键：挖掘/破坏选中的体素
				if chunk_manager != null:
					chunk_manager.remove_voxel(hit_pos)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				# 鼠标右键：在选中体素的表面依附放置当前手持选中的体素
				var place_pos = hit_pos + hit_norm
				var place_voxel_id = HOTBAR_ITEMS[hotbar_index]
				if chunk_manager != null:
					chunk_manager.add_voxel(place_pos, place_voxel_id)


## 3D DDA (Amanatides-Woo) 极速射线检测（亚微秒级命中判定）
func raycast_voxel(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
	if chunk_manager == null:
		return {"hit": false}

	var cur_x = floori(origin.x)
	var cur_y = floori(origin.y)
	var cur_z = floori(origin.z)

	var step_x = 1 if dir.x > 0 else (-1 if dir.x < 0 else 0)
	var step_y = 1 if dir.y > 0 else (-1 if dir.y < 0 else 0)
	var step_z = 1 if dir.z > 0 else (-1 if dir.z < 0 else 0)

	var inv_x = 1.0 / dir.x if absf(dir.x) > 1e-7 else 1e9
	var inv_y = 1.0 / dir.y if absf(dir.y) > 1e-7 else 1e9
	var inv_z = 1.0 / dir.z if absf(dir.z) > 1e-7 else 1e9

	var next_x = float(cur_x + 1) if dir.x > 0 else float(cur_x)
	var next_y = float(cur_y + 1) if dir.y > 0 else float(cur_y)
	var next_z = float(cur_z + 1) if dir.z > 0 else float(cur_z)

	var t_max_x = (next_x - origin.x) * inv_x if dir.x != 0 else 1e9
	var t_max_y = (next_y - origin.y) * inv_y if dir.y != 0 else 1e9
	var t_max_z = (next_z - origin.z) * inv_z if dir.z != 0 else 1e9

	var t_delta_x = absf(inv_x)
	var t_delta_y = absf(inv_y)
	var t_delta_z = absf(inv_z)

	var normal = Vector3i.ZERO
	var dist = 0.0

	while dist <= max_dist:
		if chunk_manager.is_voxel_solid(cur_x, cur_y, cur_z):
			return {
				"hit": true,
				"position": Vector3i(cur_x, cur_y, cur_z),
				"normal": normal,
				"distance": dist
			}

		if t_max_x < t_max_y:
			if t_max_x < t_max_z:
				cur_x += step_x
				dist = t_max_x
				t_max_x += t_delta_x
				normal = Vector3i(-step_x, 0, 0)
			else:
				cur_z += step_z
				dist = t_max_z
				t_max_z += t_delta_z
				normal = Vector3i(0, 0, -step_z)
		else:
			if t_max_y < t_max_z:
				cur_y += step_y
				dist = t_max_y
				t_max_y += t_delta_y
				normal = Vector3i(0, -step_y, 0)
			else:
				cur_z += step_z
				dist = t_max_z
				t_max_z += t_delta_z
				normal = Vector3i(0, 0, -step_z)

	return {"hit": false}
