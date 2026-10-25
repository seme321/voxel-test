class_name Player extends CharacterBody3D

@export var mouse_sensitivity: float = 0.005
@export var speed: int = 50
@export var jump_velocity: float = 20

@onready var head: Node3D = $Head
@onready var eye_camera: Camera3D = $Head/EyeCamera
@onready var hotbar: HotbarUI = $Hotbar

var flying: bool = false
var floor_logged: bool = false
var chunk_manager: ChunkManager = null


func _ready() -> void:
	add_to_group("player")
	if get_parent() != null and get_parent().has_node("ChunckManager"):
		chunk_manager = get_parent().get_node("ChunckManager") as ChunkManager


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

	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return

		# 挖掘与放置判定
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
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
					var place_voxel_id: int = hotbar.get_selected_voxel() if hotbar != null else VoxelTypes.Type.GRASS
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
