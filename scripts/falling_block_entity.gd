class_name FallingBlockEntity extends Node3D

## Caelix 风格连续物理落体体素实体 (FallingBlockEntity)
## 区别于传统元胞自动机网格跳格，提供具有平滑重力加速度、空气阻力与 45° 休止角侧滑的真实物理动态落体。
## 落地静止后自动无缝固化回大地图体素（Re-voxelization）。

@export var gravity: float = 20.0          # 重力加速度 (m/s^2)
@export var terminal_velocity: float = 30.0 # 终端极限下落速度 (m/s)
@export var bounce_damping: float = 0.28    # 触地弹性阻尼系数

var voxel_type: int = VoxelTypes.Type.SAND
var velocity: Vector3 = Vector3.ZERO
var chunk_manager: ChunkManager = null
var mesh_instance: MeshInstance3D = null

var is_settled: bool = false
var lifetime: float = 0.0
var max_lifetime: float = 18.0 # 超时兜底销毁，防止掉出虚空无限循环

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

	# 1. 构建独立视觉立方体（严格赋予真实材质色彩，杜绝纯白）
	mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	mesh_instance.mesh = box

	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 0.85
	var palette = VoxelTypes.get_palette()
	var v_col: Color = palette.get(voxel_type, Color(0.85, 0.75, 0.45, 1.0))
	if v_col.a <= 0.05:
		v_col = Color(0.85, 0.75, 0.45, 1.0)
	mat.albedo_color = v_col
	mesh_instance.material_override = mat

	# 居中对齐 (+0.5 偏移使得坐标为立方体中心)
	mesh_instance.position = Vector3(0.5, 0.5, 0.5)
	add_child(mesh_instance)


func _physics_process(delta: float) -> void:
	if is_settled or chunk_manager == null:
		return

	lifetime += delta
	if lifetime >= max_lifetime or global_position.y <= -20.0:
		queue_free()
		return

	# 1. 连续加速度物理积分
	velocity.y -= gravity * delta
	velocity.y = maxf(velocity.y, -terminal_velocity)
	
	# 水平微弱空气阻力
	velocity.x = move_toward(velocity.x, 0.0, 3.5 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 3.5 * delta)

	# 2. 连续 3D 轴向体素碰撞检测与斜坡滑动判定
	_move_and_collide_voxels(delta)


func _move_and_collide_voxels(delta: float) -> void:
	var cur = global_position

	# 1. X 轴位移与碰撞
	var dx = velocity.x * delta
	if absf(dx) > 0.0001:
		var next_x = cur.x + dx
		var check_x = floori(next_x + 0.5)
		if chunk_manager.is_voxel_solid(check_x, floori(cur.y + 0.5), floori(cur.z + 0.5)):
			velocity.x = -velocity.x * bounce_damping
		else:
			cur.x = next_x

	# 2. Z 轴位移与碰撞
	var dz = velocity.z * delta
	if absf(dz) > 0.0001:
		var next_z = cur.z + dz
		var check_z = floori(next_z + 0.5)
		if chunk_manager.is_voxel_solid(floori(cur.x + 0.5), floori(cur.y + 0.5), check_z):
			velocity.z = -velocity.z * bounce_damping
		else:
			cur.z = next_z

	# 3. Y 轴位移与地面检测
	var dy = velocity.y * delta
	if absf(dy) > 0.0001:
		var next_y = cur.y + dy
		var check_y = floori(next_y)
		var cx = floori(cur.x + 0.5)
		var cz = floori(cur.z + 0.5)
		
		# 检测下落触地
		if chunk_manager.is_voxel_solid(cx, check_y, cz):
			if velocity.y < -2.2:
				velocity.y = -velocity.y * bounce_damping
				velocity.x *= 0.65
				velocity.z *= 0.65
			else:
				velocity.y = 0.0
				cur.y = float(check_y + 1)
				
				# 45° 自然休止角侧滑判定 (Angle of Repose Roll)
				var cur_grid = Vector3i(cx, check_y + 1, cz)
				var slide_dir = _find_slide_direction(cur_grid)
				if slide_dir != Vector3i.ZERO:
					velocity.x = float(slide_dir.x) * 2.6
					velocity.z = float(slide_dir.z) * 2.6
					velocity.y = -1.2
				else:
					# 无处可滑，完全稳定，原地固化回大地图！
					_snap_and_solidify(cur_grid)
		else:
			cur.y = next_y

	global_position = cur


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

	if final_pos.y < chunk_manager.max_height and final_pos.y > 0:
		chunk_manager.add_voxel(final_pos, voxel_type)

	queue_free()
