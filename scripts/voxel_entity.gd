class_name VoxelEntity extends RigidBody3D

## Caelix 风格全自由度 6-DOF 动体体素实体 (VoxelEntity)
## 遵循 Caelix 引擎规范：
## 1. 质量与 3x3 惯性张量根据内部体素密度积分（RecomputeBodyMassProperties）
## 2. 支持线速度、翻滚角速度、外部冲量与角色推力
## 3. 落地静止后自动将 3D 姿态转化的体素网格无缝固化回大地图（Re-voxelization）

@export var auto_revoxelize: bool = true   # 落地平稳后是否自动融合回静态地形
@export var settle_time_required: float = 0.9 # 需要维持静止的缓冲时间（秒）
@export var max_lifetime: float = 30.0    # 兜底最长存在时间

var voxels: Array[Vector3i] = []
var types: Array[int] = []
var local_offsets: Array[Vector3] = []
var chunk_manager: ChunkManager = null

var multimesh_instance: MultiMeshInstance3D = null
var quiet_timer: float = 0.0
var lifetime: float = 0.0
var is_settled: bool = false


func setup(in_voxels: Array[Vector3i], in_types: Array[int], center_of_mass: Vector3, 
		   init_vel: Vector3 = Vector3.ZERO, init_ang_vel: Vector3 = Vector3.ZERO, 
		   cm: ChunkManager = null) -> void:
	voxels = in_voxels
	types = in_types
	chunk_manager = cm
	global_position = center_of_mass

	# 物理全局设置
	collision_layer = 1
	collision_mask = 1
	continuous_cd = true
	linear_damp = 0.15
	angular_damp = 0.25

	# 1. 计算体素质量分布与惯性张量 (Caelix Mass & Inertia Tensor Integration)
	var total_mass: float = 0.0
	local_offsets.clear()

	for i in range(voxels.size()):
		var v_pos = Vector3(voxels[i].x + 0.5, voxels[i].y + 0.5, voxels[i].z + 0.5)
		var offset = v_pos - center_of_mass
		local_offsets.append(offset)

		var density = VoxelTypes.get_density(types[i])
		var m_i = clampf(density * 0.001, 0.2, 5.0) # 归一化体素质量
		total_mass += m_i

	mass = clampf(total_mass, 1.0, 5000.0)

	# 积分惯性张量主对角线 (Ixx, Iyy, Izz)
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

	inertia = Vector3(maxf(0.1, i_xx), maxf(0.1, i_yy), maxf(0.1, i_zz))

	# 2. 构建复合碰撞体
	if voxels.size() <= 20:
		# 小构件：每个体素对应精确独立碰撞盒
		for offset in local_offsets:
			var col = CollisionShape3D.new()
			var box = BoxShape3D.new()
			box.size = Vector3(0.96, 0.96, 0.96)
			col.shape = box
			col.position = offset
			add_child(col)
	else:
		# 中大型构件：计算紧凑 AABB 复合包围盒
		var min_p = local_offsets[0]
		var max_p = local_offsets[0]
		for offset in local_offsets:
			min_p = min_p.min(offset)
			max_p = max_p.max(offset)
		var aabb_size = (max_p - min_p) + Vector3.ONE
		var col = CollisionShape3D.new()
		var box = BoxShape3D.new()
		box.size = aabb_size * 0.96
		col.shape = box
		col.position = (min_p + max_p) * 0.5
		add_child(col)

	# 3. 硬件实例化渲染视觉表现 (MultiMeshInstance3D)
	multimesh_instance = MultiMeshInstance3D.new()
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = voxels.size()

	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
	var mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	box_mesh.material = mat
	mm.mesh = box_mesh

	var palette = VoxelTypes.get_palette()
	for i in range(voxels.size()):
		mm.set_instance_transform(i, Transform3D(Basis(), local_offsets[i]))
		var v_col: Color = palette.get(types[i], Color(0.65, 0.65, 0.65, 1.0))
		mm.set_instance_color(i, v_col)

	multimesh_instance.multimesh = mm
	add_child(multimesh_instance)

	# 4. 赋予初始冲量
	linear_velocity = init_vel
	angular_velocity = init_ang_vel


func _physics_process(delta: float) -> void:
	if is_settled:
		return

	lifetime += delta
	if lifetime >= max_lifetime or global_position.y <= -20.0:
		queue_free()
		return

	# 静止与能量检测
	var speed_sq = linear_velocity.length_squared()
	var ang_speed_sq = angular_velocity.length_squared()

	if sleeping or (speed_sq < 0.08 and ang_speed_sq < 0.15):
		quiet_timer += delta
		if quiet_timer >= settle_time_required:
			if auto_revoxelize and chunk_manager != null:
				_revoxelize_into_world()
			else:
				# 若不开启固化则平滑淡出
				queue_free()
	else:
		quiet_timer = 0.0


## 落地静止后将动体网格精准还原回大地图体素 (Teardown / Caelix Re-voxelization)
func _revoxelize_into_world() -> void:
	if is_settled or chunk_manager == null:
		return
	is_settled = true

	for i in range(voxels.size()):
		var world_voxel_pos = global_transform * local_offsets[i]
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

	queue_free()
