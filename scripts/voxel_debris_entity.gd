class_name VoxelDebrisEntity extends Node3D

## Caelix 风格体素物理飞溅碎屑 (Voxel Debris / Blast Rubble)
## 爆炸碎裂的方块化为具有真实质量、阻尼与碰撞弹跳的高性能体素碎屑。
## 落地弹跳翻滚，自然衰减淡出消失，绝不原地固化产生畸形方块堆。

@export var gravity: float = 18.0
var velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var chunk_manager: ChunkManager = null
var mesh_instance: MeshInstance3D = null

var lifetime: float = 2.0
var max_lifetime: float = 2.0
var base_scale: float = 0.30
var bounce_count: int = 0


func setup(v_type: int, start_pos: Vector3, init_vel: Vector3, cm: ChunkManager = null) -> void:
	chunk_manager = cm
	if is_inside_tree():
		global_position = start_pos
	else:
		position = start_pos
	velocity = init_vel
	angular_velocity = Vector3(
		randf_range(-8.0, 8.0),
		randf_range(-8.0, 8.0),
		randf_range(-8.0, 8.0)
	)
	top_level = true
	base_scale = randf_range(0.24, 0.36)

	mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(base_scale, base_scale, base_scale)
	mesh_instance.mesh = box

	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 0.85

	var palette = VoxelTypes.get_palette()
	var col: Color = palette.get(v_type, Color(0.55, 0.40, 0.25, 1.0))
	if col.a <= 0.05:
		col = Color(0.55, 0.40, 0.25, 1.0)
	mat.albedo_color = col
	mesh_instance.material_override = mat
	add_child(mesh_instance)


func _physics_process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0 or global_position.y <= -20.0:
		queue_free()
		return

	# 末期平滑缩小淡出
	if lifetime < 0.5 and mesh_instance != null:
		var s = (lifetime / 0.5)
		mesh_instance.scale = Vector3(s, s, s)

	# 空间翻滚旋转
	rotate_x(angular_velocity.x * delta)
	rotate_y(angular_velocity.y * delta)
	rotate_z(angular_velocity.z * delta)

	# 重力积分
	velocity.y -= gravity * delta

	# 连续体素碰撞检测与弹跳
	_step_physics(delta)


func _step_physics(delta: float) -> void:
	var cur = global_position
	var next_pos = cur + velocity * delta

	if chunk_manager != null:
		var check_x = floori(next_pos.x)
		var check_y = floori(next_pos.y)
		var check_z = floori(next_pos.z)

		if chunk_manager.is_voxel_solid(check_x, check_y, check_z):
			# 发生地面或坑壁碰撞
			bounce_count += 1
			velocity.y = -velocity.y * 0.32
			velocity.x *= 0.55
			velocity.z *= 0.55
			angular_velocity *= 0.65

			# 速度微弱时停靠地面
			if absf(velocity.y) < 0.5:
				velocity = Vector3.ZERO
				angular_velocity = Vector3.ZERO
			return

	global_position = next_pos
