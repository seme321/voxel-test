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

# -----------------------------------------------------------------------------
# 路线 A：交互品质体系 (准星高亮线框、放置幽灵预览、挖掘硬度与破碎粒子)
# -----------------------------------------------------------------------------
var selection_box: MeshInstance3D = null
var ghost_box: MeshInstance3D = null
var ghost_material: StandardMaterial3D = null

var mining_progress_bar: ProgressBar = null
var current_mining_target: Vector3i = Vector3i(999999, 999999, 999999)
var mining_progress: float = 0.0
var current_hit: Dictionary = {"hit": false}


func _ready() -> void:
	add_to_group("player")
	if get_parent() != null and get_parent().has_node("ChunckManager"):
		chunk_manager = get_parent().get_node("ChunckManager") as ChunkManager

	_setup_interaction_visuals()
	_setup_mining_hud()


## 构建准星高亮线框与放置幽灵预览网格
func _setup_interaction_visuals() -> void:
	# 1. 准星选中体素高亮 3D 线框
	selection_box = MeshInstance3D.new()
	selection_box.name = "TargetSelectionBox"
	selection_box.top_level = true
	selection_box.mesh = _create_wireframe_cube_mesh(1.006)
	
	var wire_mat = StandardMaterial3D.new()
	wire_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	wire_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.95)
	wire_mat.render_priority = 3
	selection_box.material_override = wire_mat
	selection_box.visible = false
	add_child(selection_box)

	# 2. 即将依附放置的目标方块半透明幽灵预览
	ghost_box = MeshInstance3D.new()
	ghost_box.name = "PlacementGhostBox"
	ghost_box.top_level = true
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.002, 1.002, 1.002)
	ghost_box.mesh = box_mesh
	
	ghost_material = StandardMaterial3D.new()
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.cull_mode = BaseMaterial3D.CULL_BACK
	ghost_material.albedo_color = Color(1.0, 1.0, 1.0, 0.50)
	ghost_material.render_priority = 2
	ghost_box.material_override = ghost_material
	ghost_box.visible = false
	add_child(ghost_box)


## 构建挖掘进度 UI 进度条（置于准星正下方）
func _setup_mining_hud() -> void:
	var hud_layer = CanvasLayer.new()
	hud_layer.layer = 12
	
	mining_progress_bar = ProgressBar.new()
	mining_progress_bar.name = "MiningProgressBar"
	mining_progress_bar.anchor_left = 0.5
	mining_progress_bar.anchor_right = 0.5
	mining_progress_bar.anchor_top = 0.5
	mining_progress_bar.anchor_bottom = 0.5
	mining_progress_bar.offset_left = -24
	mining_progress_bar.offset_right = 24
	mining_progress_bar.offset_top = 20
	mining_progress_bar.offset_bottom = 26
	mining_progress_bar.show_percentage = false
	mining_progress_bar.min_value = 0.0
	mining_progress_bar.max_value = 1.0
	mining_progress_bar.value = 0.0
	mining_progress_bar.visible = false

	# 简约现代风格底板与填充色
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	bg_style.corner_radius_top_left = 3
	bg_style.corner_radius_top_right = 3
	bg_style.corner_radius_bottom_left = 3
	bg_style.corner_radius_bottom_right = 3
	mining_progress_bar.add_theme_stylebox_override("background", bg_style)

	var fill_style = StyleBoxFlat.new()
	fill_style.bg_color = Color(0.25, 0.9, 0.5, 0.95)
	fill_style.corner_radius_top_left = 3
	fill_style.corner_radius_top_right = 3
	fill_style.corner_radius_bottom_left = 3
	fill_style.corner_radius_bottom_right = 3
	mining_progress_bar.add_theme_stylebox_override("fill", fill_style)

	hud_layer.add_child(mining_progress_bar)
	add_child(hud_layer)


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
	
	# 动力学推力交互 (Kinetic Impulse on Colliding RigidBodies / VoxelEntity)
	for i in range(get_slide_collision_count()):
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		if collider is RigidBody3D:
			var push_dir = -collision.get_normal()
			push_dir.y = 0.0
			if not push_dir.is_zero_approx():
				push_dir = push_dir.normalized()
			var push_force = 140.0
			collider.apply_impulse(push_dir * push_force * delta, collision.get_position() - collider.global_position)
	
	if is_on_floor() and not floor_logged:
		floor_logged = true
		print("[PHYSICS SUCCESS] Player landed on ground! Pos: ", global_position, " IsOnFloor: ", is_on_floor())


func _process(delta: float) -> void:
	_update_raycast_and_visuals(delta)


## 逐帧高频射线检测、线框吸附与连续挖掘进度驱动
func _update_raycast_and_visuals(delta: float) -> void:
	if eye_camera == null or chunk_manager == null:
		return

	var cam_forward = -eye_camera.global_transform.basis.z.normalized()
	current_hit = raycast_voxel(eye_camera.global_position, cam_forward, 8.0)

	if current_hit.get("hit", false):
		var hit_pos: Vector3i = current_hit["position"]
		var hit_norm: Vector3i = current_hit["normal"]
		var base_center = Vector3(hit_pos) + Vector3(0.5, 0.5, 0.5)

		# 1. 更新准星高亮线框
		if selection_box != null:
			selection_box.visible = true
			selection_box.global_position = base_center

		# 2. 更新即将放置位置的幽灵半透明预览
		var place_pos = hit_pos + hit_norm
		if ghost_box != null:
			if can_place_at(place_pos):
				ghost_box.visible = true
				ghost_box.global_position = Vector3(place_pos) + Vector3(0.5, 0.5, 0.5)
				
				# 材质色彩与当前快捷栏手持方块同步
				var cur_v = hotbar.get_selected_voxel() if hotbar != null else VoxelTypes.Type.GRASS
				var palette_col: Color = VoxelTypes.get_palette().get(cur_v, Color(0.8, 0.8, 0.8, 1.0))
				if ghost_material != null:
					ghost_material.albedo_color = Color(palette_col.r, palette_col.g, palette_col.b, 0.45)
			else:
				ghost_box.visible = false

		# 3. 按住鼠标左键持续挖掘与硬度判定
		var is_mining = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		if is_mining:
			if hit_pos == current_mining_target:
				if flying:
					# 飞行/上帝创造模式：瞬破
					break_target_voxel(hit_pos)
				else:
					var target_v = chunk_manager.get_voxel(hit_pos.x, hit_pos.y, hit_pos.z)
					var hardness = VoxelTypes.get_hardness(target_v)
					if hardness <= 0.05:
						break_target_voxel(hit_pos, target_v)
					else:
						mining_progress += delta
						if mining_progress_bar != null:
							mining_progress_bar.visible = true
							mining_progress_bar.value = clampf(mining_progress / hardness, 0.0, 1.0)
						
						# 挖掘受力微抖动震颤视觉反馈
						var shake_factor = (mining_progress / hardness) * 0.035
						var shake = Vector3(
							randf_range(-1, 1),
							randf_range(-1, 1),
							randf_range(-1, 1)
						) * shake_factor
						if selection_box != null:
							selection_box.global_position = base_center + shake

						# 达到方块硬度时间，彻底破坏！
						if mining_progress >= hardness:
							break_target_voxel(hit_pos, target_v)
							_reset_mining_state()
			else:
				# 切换了挖掘目标方块，重置进度
				current_mining_target = hit_pos
				mining_progress = 0.0
				if mining_progress_bar != null:
					mining_progress_bar.visible = false
		else:
			_reset_mining_state()

	else:
		# 准星看向天空或超出 8 米射程，隐藏一切高亮视觉并清空挖掘状态
		if selection_box != null:
			selection_box.visible = false
		if ghost_box != null:
			ghost_box.visible = false
		_reset_mining_state()


func _reset_mining_state() -> void:
	mining_progress = 0.0
	current_mining_target = Vector3i(999999, 999999, 999999)
	if mining_progress_bar != null:
		mining_progress_bar.visible = false


## 破坏目标方块并生成微型体素破碎粒子溅射
func break_target_voxel(pos: Vector3i, v_type: int = -1) -> void:
	if chunk_manager == null:
		return
	if v_type < 0:
		v_type = chunk_manager.get_voxel(pos.x, pos.y, pos.z)
	
	spawn_break_particles(Vector3(pos), v_type)
	chunk_manager.remove_voxel(pos)


## 溅射方块碎裂粒子特效 (Voxel Shatter Dust)
func spawn_break_particles(pos: Vector3, v_type: int) -> void:
	if not is_inside_tree() or get_parent() == null:
		return

	var particles = CPUParticles3D.new()
	particles.name = "BreakParticles_%d" % Time.get_ticks_msec()
	particles.position = pos + Vector3(0.5, 0.5, 0.5)
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.lifetime = 0.45
	particles.amount = 12

	# 0.12m 迷你方块碎块
	var p_mesh = BoxMesh.new()
	p_mesh.size = Vector3(0.14, 0.14, 0.14)
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	var v_col = VoxelTypes.get_palette().get(v_type, Color(0.65, 0.65, 0.65, 1.0))
	mat.albedo_color = v_col
	p_mesh.material = mat
	particles.mesh = p_mesh

	# 物理初速度与重力加速度
	particles.direction = Vector3.UP
	particles.spread = 180.0
	particles.initial_velocity_min = 2.0
	particles.initial_velocity_max = 4.2
	particles.gravity = Vector3(0, -12.0, 0)

	get_parent().add_child(particles)
	var timer = get_tree().create_timer(0.5)
	timer.timeout.connect(particles.queue_free)


## 检查放置位置是否与玩家自身物理胶囊体发生穿插（防止将方块放置在自己脚下导致卡死）
func can_place_at(place_pos: Vector3i) -> bool:
	if flying:
		return true
	var p_min = global_position - Vector3(0.45, 1.0, 0.45)
	var p_max = global_position + Vector3(0.45, 1.0, 0.45)
	var b_min = Vector3(place_pos)
	var b_max = Vector3(place_pos) + Vector3.ONE

	var overlap = (
		p_min.x < b_max.x and p_max.x > b_min.x and
		p_min.y < b_max.y and p_max.y > b_min.y and
		p_min.z < b_max.z and p_max.z > b_min.z
	)
	return not overlap


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

		# 鼠标右键：单次依附放置当前手持选中的体素
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if current_hit.get("hit", false):
				var hit_pos: Vector3i = current_hit["position"]
				var hit_norm: Vector3i = current_hit["normal"]
				var place_pos = hit_pos + hit_norm
				
				if can_place_at(place_pos) and chunk_manager != null:
					var place_voxel_id: int = hotbar.get_selected_voxel() if hotbar != null else VoxelTypes.Type.GRASS
					chunk_manager.add_voxel(place_pos, place_voxel_id)

		# 鼠标中键：在准星瞄准的方块处触发直接爆炸冲击波 (Caelix Blast)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if current_hit.get("hit", false) and chunk_manager != null:
				var hit_center = Vector3(current_hit["position"]) + Vector3(0.5, 0.5, 0.5)
				VoxelExplosion.trigger_explosion(hit_center, 3.6, 26.0, chunk_manager)

	# 键盘 'G' 键：投掷物理动态 TNT 炸药包
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			throw_dynamite()


## 投掷动态 TNT 炸药实体
func throw_dynamite() -> void:
	if chunk_manager == null or eye_camera == null:
		return

	var cam_forward = -eye_camera.global_transform.basis.z.normalized()
	var spawn_pos = eye_camera.global_position + cam_forward * 1.0

	var tnt = RigidBody3D.new()
	tnt.name = "DynamicTNT_%d" % Time.get_ticks_msec()
	tnt.position = spawn_pos
	tnt.mass = 3.0
	tnt.linear_damp = 0.1
	tnt.angular_damp = 0.2

	var col = CollisionShape3D.new()
	var box_col = BoxShape3D.new()
	box_col.size = Vector3(0.5, 0.5, 0.5)
	col.shape = box_col
	tnt.add_child(col)

	var mesh_inst = MeshInstance3D.new()
	var box_m = BoxMesh.new()
	box_m.size = Vector3(0.5, 0.5, 0.5)
	mesh_inst.mesh = box_m
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.2, 0.15, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2, 1.0)
	mat.emission_energy_multiplier = 1.2
	mesh_inst.material_override = mat
	tnt.add_child(mesh_inst)

	var scene_root = get_parent() if get_parent() != null else self
	scene_root.add_child(tnt)

	tnt.linear_velocity = cam_forward * 16.0 + Vector3.UP * 3.5
	tnt.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))

	# 1.8 秒后引爆
	var timer = get_tree().create_timer(1.8)
	timer.timeout.connect(func():
		if is_instance_valid(tnt):
			var blast_pos = tnt.global_position
			tnt.queue_free()
			VoxelExplosion.trigger_explosion(blast_pos, 3.8, 28.0, chunk_manager)
	)


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


## 构建标准 1x1x1 单位立方体 12 边 3D 细线框网格
static func _create_wireframe_cube_mesh(size: float = 1.004) -> ArrayMesh:
	var h = size * 0.5
	var vertices: PackedVector3Array = [
		# 底部 4 边
		Vector3(-h, -h, -h), Vector3(h, -h, -h),
		Vector3(h, -h, -h), Vector3(h, -h, h),
		Vector3(h, -h, h), Vector3(-h, -h, h),
		Vector3(-h, -h, h), Vector3(-h, -h, -h),
		# 顶部 4 边
		Vector3(-h, h, -h), Vector3(h, h, -h),
		Vector3(h, h, -h), Vector3(h, h, h),
		Vector3(h, h, h), Vector3(-h, h, h),
		Vector3(-h, h, h), Vector3(-h, h, -h),
		# 4 根垂直立柱边
		Vector3(-h, -h, -h), Vector3(-h, h, -h),
		Vector3(h, -h, -h), Vector3(h, h, -h),
		Vector3(h, -h, h), Vector3(h, h, h),
		Vector3(-h, -h, h), Vector3(-h, h, h)
	]
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
