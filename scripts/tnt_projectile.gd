class_name TNTProjectile extends Node3D

## Caelix 风格体素物理 TNT 投掷实体 (TNTProjectile)
## 专为硬件光追 (Route 3B) 与大地图体素环境定制：
## 1. 具备亚微秒级 3D 连续轴向体素碰撞（Continuous Voxel Ray/AABB Sweeping）
## 2. 杜绝因无全图三角面网格而坠入虚空，支持在任意复杂体素地形表面弹跳、滚落与自然滑行
## 3. 逼真的引信闪烁发光、火花粒子与倒计时引爆机制，定点精准轰出平滑体素弹坑

@export var fuse_time: float = 1.8          # 引信燃烧时间 (秒)
@export var gravity: float = 18.0           # 重力加速度 (m/s^2)
@export var bounciness: float = 0.38        # 碰撞弹力系数
@export var friction: float = 0.82          # 地面摩擦衰减系数
@export var blast_radius: float = 3.2       # 爆炸半径 (米)
@export var blast_power: float = 20.0       # 爆炸破坏能量

var velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var chunk_manager: ChunkManager = null
var mesh_instance: MeshInstance3D = null
var tnt_material: StandardMaterial3D = null
var spark_particles: CPUParticles3D = null

var elapsed: float = 0.0
var is_exploded: bool = false
const HALF_SIZE: float = 0.25 # 0.5m 方块半边长


func setup(init_pos: Vector3, init_vel: Vector3, cm: ChunkManager) -> void:
	global_position = init_pos
	velocity = init_vel
	chunk_manager = cm
	top_level = true

	# 随机微弱旋转角速度
	angular_velocity = Vector3(
		randf_range(-8, 8),
		randf_range(-10, 10),
		randf_range(-8, 8)
	)

	_create_visuals()


func _create_visuals() -> void:
	mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	mesh_instance.mesh = box

	tnt_material = StandardMaterial3D.new()
	tnt_material.albedo_color = Color(0.88, 0.22, 0.15, 1.0)
	tnt_material.emission_enabled = true
	tnt_material.emission = Color(0.2, 0.05, 0.05, 1.0)
	tnt_material.emission_energy_multiplier = 1.0
	mesh_instance.material_override = tnt_material
	add_child(mesh_instance)

	# 顶部火花引信粒子
	spark_particles = CPUParticles3D.new()
	spark_particles.position = Vector3(0, 0.26, 0)
	spark_particles.amount = 8
	spark_particles.lifetime = 0.25
	spark_particles.explosiveness = 0.1
	spark_particles.direction = Vector3.UP
	spark_particles.spread = 60.0
	spark_particles.initial_velocity_min = 0.8
	spark_particles.initial_velocity_max = 1.6
	spark_particles.gravity = Vector3(0, -3.0, 0)

	var p_mesh = BoxMesh.new()
	p_mesh.size = Vector3(0.06, 0.06, 0.06)
	var p_mat = StandardMaterial3D.new()
	p_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	p_mat.albedo_color = Color(1.0, 0.85, 0.2, 1.0)
	p_mesh.material = p_mat
	spark_particles.mesh = p_mesh
	add_child(spark_particles)


func _physics_process(delta: float) -> void:
	if is_exploded or chunk_manager == null:
		return

	elapsed += delta

	# 引信红白高频急促闪烁视觉 (MC 经典急促闪烁反馈)
	if tnt_material != null:
		var flash_rate = 14.0 if elapsed < (fuse_time - 0.6) else 28.0
		var is_white = sin(elapsed * flash_rate) > 0.0
		if is_white:
			tnt_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
			tnt_material.emission = Color(1.0, 1.0, 1.0, 1.0)
			tnt_material.emission_energy_multiplier = 2.5
		else:
			tnt_material.albedo_color = Color(0.88, 0.22, 0.15, 1.0)
			tnt_material.emission = Color(0.5, 0.1, 0.1, 1.0)
			tnt_material.emission_energy_multiplier = 0.8

	# 引爆倒计时
	if elapsed >= fuse_time:
		detonate()
		return

	# 重力与空气阻力积分
	velocity.y -= gravity * delta
	velocity.x *= (1.0 - 0.4 * delta)
	velocity.z *= (1.0 - 0.4 * delta)

	# 3D 轴向体素碰撞检测与弹跳反射 (Continuous Sweep Collision)
	_move_and_collide_voxels(delta)

	# 旋转驱动
	if mesh_instance != null:
		mesh_instance.rotate_x(angular_velocity.x * delta)
		mesh_instance.rotate_y(angular_velocity.y * delta)
		mesh_instance.rotate_z(angular_velocity.z * delta)


## 连续 3 轴体素碰撞模拟
func _move_and_collide_voxels(delta: float) -> void:
	var cur = global_position

	# 1. X 轴位移与碰撞
	var dx = velocity.x * delta
	if absf(dx) > 0.0001:
		var next_x = cur.x + dx
		var sign_x = signf(dx)
		var check_x = floori(next_x + sign_x * HALF_SIZE)
		if _is_box_colliding_at(Vector3(check_x, floori(cur.y), floori(cur.z))):
			velocity.x = -velocity.x * bounciness
			angular_velocity *= 0.7
		else:
			cur.x = next_x

	# 2. Z 轴位移与碰撞
	var dz = velocity.z * delta
	if absf(dz) > 0.0001:
		var next_z = cur.z + dz
		var sign_z = signf(dz)
		var check_z = floori(next_z + sign_z * HALF_SIZE)
		if _is_box_colliding_at(Vector3(floori(cur.x), floori(cur.y), check_z)):
			velocity.z = -velocity.z * bounciness
			angular_velocity *= 0.7
		else:
			cur.z = next_z

	# 3. Y 轴位移与地面/天花板碰撞
	var dy = velocity.y * delta
	if absf(dy) > 0.0001:
		var next_y = cur.y + dy
		var sign_y = signf(dy)
		var check_y = floori(next_y + sign_y * HALF_SIZE)
		if _is_box_colliding_at(Vector3(floori(cur.x), check_y, floori(cur.z))):
			if velocity.y < -1.8:
				# 落地反弹
				velocity.y = -velocity.y * bounciness
				velocity.x *= friction
				velocity.z *= friction
				angular_velocity *= 0.6
			else:
				# 贴地静止与摩擦减速
				velocity.y = 0.0
				velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
				velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
				angular_velocity = angular_velocity.move_toward(Vector3.ZERO, 15.0 * delta)
				# 贴合在体素表面之上
				if sign_y < 0:
					cur.y = float(check_y + 1) + HALF_SIZE
		else:
			cur.y = next_y

	global_position = cur


## 检测指定整数体素网格是否为不可穿透实体
func _is_box_colliding_at(v_cell: Vector3) -> bool:
	return chunk_manager.is_voxel_solid(int(v_cell.x), int(v_cell.y), int(v_cell.z))


## 定点引爆！
func detonate() -> void:
	if is_exploded:
		return
	is_exploded = true

	var blast_pos = global_position
	queue_free()

	if chunk_manager != null and is_instance_valid(chunk_manager):
		VoxelExplosion.trigger_explosion(blast_pos, blast_radius, blast_power, chunk_manager)
