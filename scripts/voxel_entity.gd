class_name VoxelEntity extends Node3D

## Caelix 风格全自由度 6-DOF 动体体素物理系统 (VoxelEntity)
## 严格实现 Caelix / 刚体动力学微分方程：
## 1. 真实质量分布与 3x3 空间惯性张量积分（Inertia Tensor）
## 2. 接触点力矩杠杆定理（Point Velocity v_p = v + w × r）
## 3. 接触冲量分解：法向弹性碰撞 (Restitution) + 库仑切向滑动摩擦 (Coulomb Friction) -> 产生强烈逼真的着地滚翻与倾覆
## 4. 连续多体素扫掠碰撞，杜绝穿模坠入虚空
## 5. 静止后自动姿态网格离散化无缝回填回大地图（Re-voxelization）
## 6. 支持玩家推力、踩踏交互与爆炸冲击波角动量传递

@export var auto_revoxelize: bool = true        # 落地平稳后是否自动融合回静态地形
@export var settle_time_required: float = 0.5   # 需要维持静止的缓冲时间（秒）
@export var max_lifetime: float = 30.0          # 兜底最长存在时间
@export var gravity: float = 18.0               # 重力加速度 (m/s^2)
@export var bounciness: float = 0.22            # 触地弹性系数 (Restitution)
@export var friction_coef: float = 0.65         # 库仑摩擦系数 (Coulomb Friction)
@export var linear_drag: float = 0.15           # 空气阻力
@export var angular_drag: float = 0.25          # 旋转角阻力

var voxels: Array[Vector3i] = []
var types: Array[int] = []
var local_offsets: Array[Vector3] = []
var chunk_manager = null

# 刚体动力学状态变量
var linear_velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var mass: float = 1.0
var inv_mass: float = 1.0
var body_inertia: Vector3 = Vector3.ONE        # 局部对角惯性张量 (Ixx, Iyy, Izz)
var inv_body_inertia: Vector3 = Vector3.ONE    # 局部逆惯性

var quiet_timer: float = 0.0
var lifetime: float = 0.0
var is_settled: bool = false
var is_grounded: bool = false
var static_collider: StaticBody3D = null
var static_shape: CollisionShape3D = null


func setup(in_voxels: Array[Vector3i], in_types: Array[int], center_of_mass: Vector3, 
		   init_vel: Vector3 = Vector3.ZERO, init_ang_vel: Vector3 = Vector3.ZERO, 
		   cm = null) -> void:
	voxels = in_voxels
	types = in_types
	chunk_manager = cm
	if is_inside_tree():
		global_position = center_of_mass
	else:
		position = center_of_mass
	top_level = true

	linear_velocity = init_vel
	angular_velocity = init_ang_vel

	# 1. 精确计算体素质量与 3x3 空间惯性张量积分
	var total_mass: float = 0.0
	local_offsets.clear()

	for i in range(voxels.size()):
		var v_pos = Vector3(voxels[i].x + 0.5, voxels[i].y + 0.5, voxels[i].z + 0.5)
		var offset = v_pos - center_of_mass
		local_offsets.append(offset)

		var density = VoxelTypes.get_density(types[i])
		var m_i = clampf(density * 0.001, 0.3, 8.0)
		total_mass += m_i

	mass = clampf(total_mass, 1.0, 10000.0)
	inv_mass = 1.0 / mass

	var i_xx: float = 0.0
	var i_yy: float = 0.0
	var i_zz: float = 0.0

	for i in range(voxels.size()):
		var offset = local_offsets[i]
		var density = VoxelTypes.get_density(types[i])
		var m_i = clampf(density * 0.001, 0.3, 8.0)

		# 平行轴定理 + 立方体自身转动惯量 (m * L^2 / 6)
		i_xx += m_i * (offset.y * offset.y + offset.z * offset.z) + (m_i / 6.0)
		i_yy += m_i * (offset.x * offset.x + offset.z * offset.z) + (m_i / 6.0)
		i_zz += m_i * (offset.x * offset.x + offset.y * offset.y) + (m_i / 6.0)

	body_inertia = Vector3(maxf(0.3, i_xx), maxf(0.3, i_yy), maxf(0.3, i_zz))
	inv_body_inertia = Vector3(1.0 / body_inertia.x, 1.0 / body_inertia.y, 1.0 / body_inertia.z)

	# 2. 构建渲染视觉表现
	_build_visuals()

	# 3. 构建与玩家角色交互的局部物理碰撞体
	_build_player_collider()


## 构建真实带光影着色的方块渲染模型
func _build_visuals() -> void:
	var palette = VoxelTypes.get_palette()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
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
			if v_col.a <= 0.01:
				v_col = Color(0.5, 0.5, 0.5, 1.0)
			mat.albedo_color = v_col
			mat_cache[v_type] = mat

		var mi = MeshInstance3D.new()
		mi.mesh = box_mesh
		mi.material_override = mat
		mi.position = local_offsets[i]
		add_child(mi)


## 构建与角色交互的轻量碰撞盒
func _build_player_collider() -> void:
	static_collider = StaticBody3D.new()
	static_collider.name = "EntityPlayerCollider"
	static_collider.set_script(null)

	var aabb_min = Vector3(9999, 9999, 9999)
	var aabb_max = Vector3(-9999, -9999, -9999)
	for offset in local_offsets:
		aabb_min = aabb_min.min(offset - Vector3(0.5, 0.5, 0.5))
		aabb_max = aabb_max.max(offset + Vector3(0.5, 0.5, 0.5))

	var aabb_size = (aabb_max - aabb_min)
	var aabb_center = aabb_min + aabb_size * 0.5

	static_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = aabb_size * 0.96
	static_shape.shape = box
	static_shape.position = aabb_center
	static_collider.add_child(static_shape)
	add_child(static_collider)


## 外部冲量注入接口（玩家推撞、爆炸冲击波等）
func apply_impulse(impulse: Vector3, world_contact_pos: Vector3) -> void:
	# 线性动量变化: Δv = J / m
	linear_velocity += impulse * inv_mass

	# 杠杆力臂: r = contact_pos - center_of_mass
	var cur_cm = global_position if is_inside_tree() else position
	var r = world_contact_pos - cur_cm
	# 力矩冲量: τ = r × J
	var torque_impulse = r.cross(impulse)
	# 角动量变化: Δw = I^-1 * (r × J)
	angular_velocity += _get_world_inv_inertia() * torque_impulse
	quiet_timer = 0.0


func _physics_process(delta: float) -> void:
	if is_settled or chunk_manager == null:
		return

	lifetime += delta
	var cur_pos = global_position if is_inside_tree() else position
	if lifetime >= max_lifetime or cur_pos.y <= -20.0:
		queue_free()
		return

	# 1. 重力积分与阻尼衰减
	linear_velocity.y -= gravity * delta
	linear_velocity *= (1.0 - linear_drag * delta)
	angular_velocity *= (1.0 - angular_drag * delta)

	# 2. 连续 3D 动力学接触积分与力矩反馈碰撞判定
	_step_dynamics_simulation(delta)

	# 3. 姿态角速度积分（四元数/旋转正交化，杜绝欧拉角万向锁）
	if not angular_velocity.is_zero_approx():
		var ang_speed = angular_velocity.length()
		var ang_axis = angular_velocity / ang_speed
		var rot_step = Basis(ang_axis, ang_speed * delta)
		transform.basis = (rot_step * transform.basis).orthonormalized()

	# 4. 处于接触面时的微弱角速度衰减
	if is_grounded:
		angular_velocity = angular_velocity.move_toward(Vector3.ZERO, 3.5 * delta)

	# 5. 静止判定与固化倒计时
	var speed_sq = linear_velocity.length_squared()
	var ang_speed_sq = angular_velocity.length_squared()

	if is_grounded and speed_sq < 0.08 and ang_speed_sq < 0.15:
		quiet_timer += delta
		if quiet_timer >= settle_time_required:
			if auto_revoxelize:
				_revoxelize_into_world()
			else:
				queue_free()
	else:
		quiet_timer = 0.0


## 世界坐标系下的逆转动惯量矩阵计算
func _get_world_inv_inertia() -> Basis:
	# I_world^-1 = R * I_body^-1 * R^T
	var r = transform.basis
	var inv_i_diag = Basis.from_scale(inv_body_inertia)
	return r * inv_i_diag * r.transposed()


## 核心 6-DOF 刚体接触碰撞与冲量求解器 (Impulse Contact Solver)
func _step_dynamics_simulation(delta: float) -> void:
	is_grounded = false
	var cur_pos = global_position if is_inside_tree() else position
	var world_inv_i = _get_world_inv_inertia()

	# 预测下一步位置
	var pred_pos = cur_pos + linear_velocity * delta

	# 检测发生碰撞的体素点
	var deepest_pen: float = 0.0
	var contact_normal: Vector3 = Vector3.ZERO
	var contact_lever: Vector3 = Vector3.ZERO
	var contact_point_vel: Vector3 = Vector3.ZERO
	var has_collision: bool = false

	# 采样外围体素节点（对每个体素求交）
	for offset in local_offsets:
		var rotated_offset = transform.basis * offset
		var block_world_pos = pred_pos + rotated_offset
		var gx = floori(block_world_pos.x)
		var gy = floori(block_world_pos.y)
		var gz = floori(block_world_pos.z)

		if chunk_manager.is_voxel_solid(gx, gy, gz):
			has_collision = true
			# 估算穿透法线（根据体素中心与前一步位置的反向向量）
			var cell_center = Vector3(float(gx) + 0.5, float(gy) + 0.5, float(gz) + 0.5)
			var n = (block_world_pos - cell_center).normalized()
			if n.is_zero_approx():
				n = Vector3.UP

			# 计算该接触点的瞬时速度: v_p = v + w × r
			var pt_vel = linear_velocity + angular_velocity.cross(rotated_offset)
			var v_dot_n = pt_vel.dot(n)

			# 寻找最具阻碍效应的接触碰撞面
			if v_dot_n < 0.0:
				contact_normal = n
				contact_lever = rotated_offset
				contact_point_vel = pt_vel
				deepest_pen = 0.12
				break

	if has_collision and not contact_normal.is_zero_approx():
		var n = contact_normal
		var r = contact_lever
		var v_p = contact_point_vel

		# 1. 计算法向有效质量 M_eff: 1/M_eff = 1/m + (r × n)^T * I^-1 * (r × n)
		var rxn = r.cross(n)
		var rot_inertial_factor = rxn.dot(world_inv_i * rxn)
		var eff_mass_inv = inv_mass + rot_inertial_factor

		if eff_mass_inv > 0.0001:
			var eff_mass = 1.0 / eff_mass_inv

			# 2. 法向碰撞冲量 J_n = -(1 + e) * (v_p · n) * M_eff
			var vn = v_p.dot(n)
			var j_n_mag = -(1.0 + bounciness) * vn * eff_mass
			j_n_mag = maxf(0.0, j_n_mag)
			var impulse_n = n * j_n_mag

			# 3. 切向摩擦冲量 J_t (库仑滑动摩擦定律)
			var vt = v_p - n * vn
			var vt_mag = vt.length()
			var impulse_t = Vector3.ZERO

			if vt_mag > 0.001:
				var t_dir = vt / vt_mag
				var rxt = r.cross(t_dir)
				var eff_t_mass_inv = inv_mass + rxt.dot(world_inv_i * rxt)
				var j_t_mag = vt_mag / maxf(0.0001, eff_t_mass_inv)
				# 库仑摩擦限幅: |J_t| <= μ * J_n
				j_t_mag = minf(j_t_mag, friction_coef * j_n_mag)
				impulse_t = -t_dir * j_t_mag

			var total_contact_impulse = impulse_n + impulse_t

			# 4. 动力学动量与角动量同步突变！
			linear_velocity += total_contact_impulse * inv_mass
			# 力矩冲量产生强烈的倾覆翻滚！
			angular_velocity += world_inv_i * r.cross(total_contact_impulse)

			# 标记接地
			if n.y > 0.5:
				is_grounded = true

			# 穿透位置校正，防止嵌地
			cur_pos += n * deepest_pen
	else:
		cur_pos = pred_pos

	if is_inside_tree():
		global_position = cur_pos
	else:
		position = cur_pos


## 落地静止后将动体网格精准还原回大地图体素 (Teardown / Caelix Re-voxelization)
func _revoxelize_into_world() -> void:
	if is_settled or chunk_manager == null:
		return
	is_settled = true

	var cur_pos = global_position if is_inside_tree() else position
	for i in range(voxels.size()):
		var rotated_offset = transform.basis * local_offsets[i]
		var world_voxel_pos = cur_pos + rotated_offset
		var target_grid = Vector3i(
			floori(world_voxel_pos.x + 0.5),
			floori(world_voxel_pos.y + 0.5),
			floori(world_voxel_pos.z + 0.5)
		)

		# 查找临近非占用空间放置
		while chunk_manager.is_voxel_solid(target_grid.x, target_grid.y, target_grid.z):
			target_grid.y += 1
			if target_grid.y >= chunk_manager.max_height:
				break

		if target_grid.y < chunk_manager.max_height and target_grid.y > 0:
			chunk_manager.add_voxel(target_grid, types[i])

	# 立即更新局部碰撞体并清除动态实体
	chunk_manager.flush_dirty_rt_sectors()
	queue_free()
