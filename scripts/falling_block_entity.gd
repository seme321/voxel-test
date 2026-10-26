class_name FallingBlockEntity extends Node3D

## Caelix 风格连续物理落体体素实体 (FallingBlockEntity)
## 区别于传统元胞自动机网格跳格，提供具有平滑重力加速度、空气阻力与 45° 休止角侧滑的真实物理动态落体。
## 落地静止后自动无缝固化回大地图体素（Re-voxelization）。

@export var gravity: float = 24.0          # 重力加速度 (m/s^2)
@export var terminal_velocity: float = 35.0 # 终端极限下落速度 (m/s)
@export var bounce_damping: float = 0.25    # 触地弹性阻尼系数

var voxel_type: int = VoxelTypes.Type.SAND
var velocity: Vector3 = Vector3.ZERO
var chunk_manager: ChunkManager = null
var mesh_instance: MeshInstance3D = null

var is_settled: bool = false
var lifetime: float = 0.0
var max_lifetime: float = 15.0 # 超时兜底销毁，防止掉出虚空无限循环

const HORIZONTAL_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]


func setup(type: int, start_world_pos: Vector3, init_vel: Vector3 = Vector3.ZERO, cm: ChunkManager = null) -> void:
	voxel_type = type
	global_position = start_world_pos
	velocity = init_vel
	chunk_manager = cm
	top_level = true

	# 1. 构建独立视觉立方体
	mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	mesh_instance.mesh = box

	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	var palette = VoxelTypes.get_palette()
	mat.albedo_color = palette.get(voxel_type, Color(0.8, 0.7, 0.4, 1.0))
	mesh_instance.material_override = mat

	# 居中对齐 (+0.5 偏移使得坐标为立方体中心)
	mesh_instance.position = Vector3(0.5, 0.5, 0.5)
	add_child(mesh_instance)


func _physics_process(delta: float) -> void:
	if is_settled or chunk_manager == null:
		return

	lifetime += delta
	if lifetime >= max_lifetime or global_position.y <= -10.0:
		queue_free()
		return

	# 1. 连续加速度物理积分
	velocity.y -= gravity * delta
	velocity.y = maxf(velocity.y, -terminal_velocity)
	
	# 水平微弱空气阻力
	velocity.x = move_toward(velocity.x, 0.0, 4.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 4.0 * delta)

	var delta_pos = velocity * delta
	var target_pos = global_position + delta_pos

	# 2. 亚体素极速下落碰撞检测 (Continuous Ground Collision)
	var check_x = floori(target_pos.x)
	var check_z = floori(target_pos.z)
	var bottom_y = target_pos.y

	var current_cell_y = floori(global_position.y)
	var target_cell_y = floori(bottom_y)

	var hit_solid = false
	var hit_y = target_cell_y

	# 逐格检测垂直穿透
	for test_y in range(current_cell_y, target_cell_y - 1, -1):
		if chunk_manager.is_voxel_solid(check_x, test_y, check_z):
			hit_solid = true
			hit_y = test_y
			break

	if hit_solid:
		# 触碰到实体地面
		var rest_y = float(hit_y + 1)
		global_position.y = rest_y
		velocity.y = 0.0

		# 3. 45° 自然休止角侧滑判定 (Angle of Repose Roll)
		var cur_grid = Vector3i(check_x, hit_y + 1, check_z)
		var slide_dir = _find_slide_direction(cur_grid)

		if slide_dir != Vector3i.ZERO:
			# 向斜下方产生侧滑动量
			velocity.x = float(slide_dir.x) * 3.2
			velocity.z = float(slide_dir.z) * 3.2
			velocity.y = -1.5
			global_position += Vector3(velocity.x, 0.0, velocity.z) * delta
		else:
			# 无处可滑，完全稳定，原地固化回大地图！
			_snap_and_solidify(cur_grid)
	else:
		global_position = target_pos


## 寻找可以顺势滚落的 45° 斜坡方向
func _find_slide_direction(grid_pos: Vector3i) -> Vector3i:
	var valid_dirs: Array[Vector3i] = []
	for dir in HORIZONTAL_DIRECTIONS:
		var side = grid_pos + dir
		var diag = side + Vector3i(0, -1, 0)
		if not chunk_manager.is_voxel_solid(side.x, side.y, side.z) and \
		   not chunk_manager.is_voxel_solid(diag.x, diag.y, diag.z):
			valid_dirs.append(dir)

	if valid_dirs.is_empty():
		return Vector3i.ZERO
	return valid_dirs.pick_random()


## 落地精准网格对齐并原子化固化回体素大地图 (Caelix Re-voxelization)
func _snap_and_solidify(grid_pos: Vector3i) -> void:
	if is_settled:
		return
	is_settled = true

	# 确保不覆盖已有实体方块（若目标已被占，则向上抬一格）
	var final_pos = grid_pos
	while chunk_manager.is_voxel_solid(final_pos.x, final_pos.y, final_pos.z):
		final_pos.y += 1
		if final_pos.y >= chunk_manager.max_height:
			queue_free()
			return

	chunk_manager.add_voxel(final_pos, voxel_type)
	_spawn_settle_particles(Vector3(final_pos))
	queue_free()


## 落地微尘粒子特效
func _spawn_settle_particles(pos: Vector3) -> void:
	if get_parent() == null:
		return
	var particles = CPUParticles3D.new()
	particles.top_level = true
	particles.position = pos + Vector3(0.5, 0.1, 0.5)
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.lifetime = 0.35
	particles.amount = 8

	var p_mesh = BoxMesh.new()
	p_mesh.size = Vector3(0.08, 0.08, 0.08)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = VoxelTypes.get_palette().get(voxel_type, Color(0.8, 0.7, 0.4, 1.0))
	p_mesh.material = mat
	particles.mesh = p_mesh

	particles.direction = Vector3.UP
	particles.spread = 75.0
	particles.initial_velocity_min = 1.0
	particles.initial_velocity_max = 2.2
	particles.gravity = Vector3(0, -9.8, 0)

	get_parent().add_child(particles)
	var t = get_tree().create_timer(0.4)
	t.timeout.connect(particles.queue_free)
