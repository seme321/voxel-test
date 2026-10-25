class_name VoxelDebrisEntity extends RigidBody3D

## Caelix 风格离散浮空建筑/刚体碎片 (VoxelDebrisEntity)
## 当悬崖、立柱或建筑被挖断而失去地面物理支撑时，整块离散结构转换为由原生 3D 刚体驱动的掉落碎片

@export var max_lifetime: float = 12.0 # 最长存活时间（秒）
var lifetime: float = 12.0
var is_fading: bool = false
var fade_timer: float = 0.5

var multimesh_instance: MultiMeshInstance3D = null


func setup(voxels: Array[Vector3i], types: Array[int], center_of_mass: Vector3) -> void:
	position = center_of_mass
	lifetime = max_lifetime
	
	# 物理属性配置
	mass = clampf(float(voxels.size()) * 5.0, 1.0, 200.0)
	linear_damp = 0.1
	angular_damp = 0.2
	collision_layer = 1
	collision_mask = 1
	continuous_cd = true
	
	# 1. 构建物理碰撞体 (Collision Shape)
	if voxels.size() <= 16:
		# 精确复合体碰撞盒（小构件具备完美的边角翻滚触地碰撞）
		for p in voxels:
			var col = CollisionShape3D.new()
			var box = BoxShape3D.new()
			box.size = Vector3(0.98, 0.98, 0.98)
			col.shape = box
			col.position = Vector3(p.x + 0.5, p.y + 0.5, p.z + 0.5) - center_of_mass
			add_child(col)
	else:
		# 大中型碎片使用包围盒快速碰撞，杜绝物理计算死锁
		var min_p = Vector3(voxels[0])
		var max_p = Vector3(voxels[0])
		for p in voxels:
			min_p = min_p.min(Vector3(p))
			max_p = max_p.max(Vector3(p))
		var aabb_size = (max_p - min_p) + Vector3.ONE
		var aabb_center = min_p + aabb_size * 0.5
		var col = CollisionShape3D.new()
		var box = BoxShape3D.new()
		box.size = aabb_size * 0.98
		col.shape = box
		col.position = aabb_center - center_of_mass
		add_child(col)

	# 2. 构建高性能硬件实例化渲染视觉表现 (MultiMeshInstance3D)
	multimesh_instance = MultiMeshInstance3D.new()
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = voxels.size()
	
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.0, 1.0, 1.0)
	
	var mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.75
	box_mesh.material = mat
	mm.mesh = box_mesh
	
	var palette = VoxelTypes.get_palette()
	for i in range(voxels.size()):
		var local_offset = Vector3(voxels[i].x + 0.5, voxels[i].y + 0.5, voxels[i].z + 0.5) - center_of_mass
		mm.set_instance_transform(i, Transform3D(Basis(), local_offset))
		var v_col: Color = palette.get(types[i], Color(0.6, 0.6, 0.6, 1.0))
		mm.set_instance_color(i, v_col)
		
	multimesh_instance.multimesh = mm
	add_child(multimesh_instance)
	
	# 3. 初始翻滚角冲量与微弱横向分离力
	linear_velocity = Vector3(
		randf_range(-0.4, 0.4),
		randf_range(-0.2, 0.1),
		randf_range(-0.4, 0.4)
	)
	angular_velocity = Vector3(
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0)
	)


func _physics_process(delta: float) -> void:
	if is_fading:
		fade_timer -= delta
		var scale_factor = clampf(fade_timer / 0.5, 0.01, 1.0)
		scale = Vector3.ONE * scale_factor
		if fade_timer <= 0.0:
			queue_free()
		return
		
	lifetime -= delta
	
	# 静止落地或超时判定，启动平滑缩放淡出回收
	if lifetime <= 0.0 or (lifetime < (max_lifetime - 2.0) and sleeping):
		is_fading = true
		fade_timer = 0.5
