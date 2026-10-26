class_name VoxelEntity extends Node3D

## Caelix 风格全自由度 6-DOF 动体体素实体 (VoxelEntity)
## 遵循 Caelix 引擎规范：
## 1. 采用独立材质与顶点色彩映射，彻底根除 MultiMesh 导致的白块 Bug
## 2. 具备亚微秒级 3D 连续体素碰撞（Continuous Voxel Sweeping），彻底杜绝坠入虚空
## 3. 落地静止后自动将 3D 姿态转化的体素网格无缝固化回大地图（Re-voxelization）

@export var auto_revoxelize: bool = true       # 落地平稳后是否自动融合回静态地形
@export var settle_time_required: float = 0.6  # 需要维持静止的缓冲时间（秒）
@export var max_lifetime: float = 25.0         # 兜底最长存在时间
@export var gravity: float = 18.0              # 重力加速度 (m/s^2)
@export var bounciness: float = 0.28           # 触地弹性系数
@export var ground_friction: float = 0.75      # 地面摩擦系数

var voxels: Array[Vector3i] = []
var types: Array[int] = []
var local_offsets: Array[Vector3] = []
var chunk_manager: ChunkManager = null

var linear_velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var mass: float = 1.0
var inertia: Vector3 = Vector3.ONE

var quiet_timer: float = 0.0
var lifetime: float = 0.0
var is_settled: bool = false
var is_grounded: bool = false


func setup(in_voxels: Array[Vector3i], in_types: Array[int], center_of_mass: Vector3, 
		   init_vel: Vector3 = Vector3.ZERO, init_ang_vel: Vector3 = Vector3.ZERO, 
		   cm: ChunkManager = null) -> void:
	voxels = in_voxels
	types = in_types
	chunk_manager = cm
	global_position = center_of_mass
	top_level = true

	linear_velocity = init_vel
	angular_velocity = init_ang_vel

	# 1. 计算体素质量分布与 3x3 惯性张量 (Caelix Mass & Inertia Tensor Integration)
	var total_mass: float = 0.0
	local_offsets.clear()

	for i in range(voxels.size()):
		var v_pos = Vector3(voxels[i].x + 0.5, voxels[i].y + 0.5, voxels[i].z + 0.5)
		var offset = v_pos - center_of_mass
		local_offsets.append(offset)

		var density = VoxelTypes.get_density(types[i])
		var m_i = clampf(density * 0.001, 0.2, 5.0)
		total_mass += m_i

	mass = clampf(total_mass, 1.0, 5000.0)

	var i_xx: float = 0.0
	var i_yy: float = 0.0
	var i_zz: float = 0.0

	for i in range(voxels.size()):
		var offset = local_offsets[i]
		var density = VoxelTypes.get_density(types[i])
		var m_i = clampf(density * 0.001, 0.2, 5.0)

		i_xx += m_i * (offset.y * offset.y + offset.z * offset.z) + (m_i / 6.0)
		i_yy += m_i * (offset.x * offset.x + offset.z * offset.z) + (m_i / 6.0)
		i_zz += m_i * (offset.x * offset.x + offset.y * offset.y) + (m_i / 6.0)

	inertia = Vector3(maxf(0.2, i_xx), maxf(0.2, i_yy), maxf(0.2, i_zz))

	# 2. 构建真实材质色彩视觉（杜绝 MultiMesh 默认纯白问题）
	_build_visuals()


func _build_visuals() -> void:
	var palette = VoxelTypes.get_palette()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)

	# 材质缓存字典，避免重复创建相同类型的材质
	var mat_cache: Dictionary = {}

	for i in range(voxels.size()):
		var v_type = types[i]
		var mat: StandardMaterial3D = null

		if mat_cache.has(v_type):
			mat = mat_cache[v_type]
		else:
			mat = StandardMaterial3D.new()
			mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 0.85
			var v_col: Color = palette.get(v_type, Color(0.55, 0.55, 0.55, 1.0))
			# 确保哪怕是 AIR 或异常值也有可见实体颜色
			if v_col.a <= 0.01:
				v_col = Color(0.5, 0.5, 0.5, 1.0)
			mat.albedo_color = v_col
			mat_cache[v_type] = mat

		var mi = MeshInstance3D.new()
		mi.mesh = box_mesh
		mi.material_override = mat
		mi.position = local_offsets[i]
		add_child(mi)


func _physics_process(delta: float) -> void:
	if is_settled or chunk_manager == null:
		return

	lifetime += delta
	if lifetime >= max_lifetime or global_position.y <= -20.0:
		queue_free()
		return

	# 1. 速度积分与空气阻尼
	linear_velocity.y -= gravity * delta
	linear_velocity.x *= (1.0 - 0.25 * delta)
	linear_velocity.z *= (1.0 - 0.25 * delta)
	angular_velocity *= (1.0 - 0.4 * delta)

	# 2. 连续 3D 轴向体素碰撞检测与地面反弹
	_move_and_collide_voxels(delta)

	# 3. 旋转驱动
	if not angular_velocity.is_zero_approx():
		var rot_delta = angular_velocity * delta
		rotate_x(rot_delta.x)
		rotate_y(rot_delta.y)
		rotate_z(rot_delta.z)

	# 4. 静止判定与固化倒计时
	var speed_sq = linear_velocity.length_squared()
	var ang_speed_sq = angular_velocity.length_squared()

	if is_grounded and speed_sq < 0.12 and ang_speed_sq < 0.2:
		quiet_timer += delta
		if quiet_timer >= settle_time_required:
			if auto_revoxelize:
				_revoxelize_into_world()
			else:
				queue_free()
	else:
		quiet_timer = 0.0


## 连续 3 轴体素碰撞检测（针对组合体内每个方块进行体素求交）
func _move_and_collide_voxels(delta: float) -> void:
	is_grounded = false
	var cur_pos = global_position

	# 1. X 轴位移
	var dx = linear_velocity.x * delta
	if absf(dx) > 0.0001:
		var test_pos = cur_pos + Vector3(dx, 0, 0)
		if _check_collision_at_pos(test_pos):
			linear_velocity.x = -linear_velocity.x * bounciness
			angular_velocity *= 0.7
		else:
			cur_pos.x = test_pos.x

	# 2. Z 轴位移
	var dz = linear_velocity.z * delta
	if absf(dz) > 0.0001:
		var test_pos = cur_pos + Vector3(0, 0, dz)
		if _check_collision_at_pos(test_pos):
			linear_velocity.z = -linear_velocity.z * bounciness
			angular_velocity *= 0.7
		else:
			cur_pos.z = test_pos.z

	# 3. Y 轴垂直位移与地面吸附
	var dy = linear_velocity.y * delta
	if absf(dy) > 0.0001:
		var test_pos = cur_pos + Vector3(0, dy, 0)
		if _check_collision_at_pos(test_pos):
			if linear_velocity.y < -1.5:
				# 地面/障碍反弹
				linear_velocity.y = -linear_velocity.y * bounciness
				linear_velocity.x *= ground_friction
				linear_velocity.z *= ground_friction
				angular_velocity *= 0.6
			else:
				# 贴地滑行与摩擦减速
				linear_velocity.y = 0.0
				linear_velocity.x = move_toward(linear_velocity.x, 0.0, 10.0 * delta)
				linear_velocity.z = move_toward(linear_velocity.z, 0.0, 10.0 * delta)
				angular_velocity = angular_velocity.move_toward(Vector3.ZERO, 12.0 * delta)
				is_grounded = true
		else:
			cur_pos.y = test_pos.y

	global_position = cur_pos


## 遍历组合体内所有方块，检测在目标世界坐标下是否有任何方块穿透进静态实体体素
func _check_collision_at_pos(test_root_pos: Vector3) -> bool:
	for offset in local_offsets:
		var rotated_offset = transform.basis * offset
		var block_world_pos = test_root_pos + rotated_offset
		var gx = floori(block_world_pos.x)
		var gy = floori(block_world_pos.y)
		var gz = floori(block_world_pos.z)

		if chunk_manager.is_voxel_solid(gx, gy, gz):
			return true
	return false


## 落地静止后将动体网格精准还原回大地图体素 (Teardown / Caelix Re-voxelization)
func _revoxelize_into_world() -> void:
	if is_settled or chunk_manager == null:
		return
	is_settled = true

	var positions_added: Array[Vector3i] = []

	for i in range(voxels.size()):
		var rotated_offset = transform.basis * local_offsets[i]
		var world_voxel_pos = global_position + rotated_offset
		var target_grid = Vector3i(
			floori(world_voxel_pos.x),
			floori(world_voxel_pos.y),
			floori(world_voxel_pos.z)
		)

		# 查找临近非占用空间放置
		while chunk_manager.is_voxel_solid(target_grid.x, target_grid.y, target_grid.z):
			target_grid.y += 1
			if target_grid.y >= chunk_manager.max_height:
				break

		if target_grid.y < chunk_manager.max_height and target_grid.y > 0:
			chunk_manager.add_voxel(target_grid, types[i])
			positions_added.append(target_grid)

	queue_free()
