class_name VoxelExplosion extends RefCounted

## Caelix 风格体素物理爆炸与动量冲量场 (VoxelExplosion / ApplyBodyForceCommands)
## 遵循 Caelix 严格体素球形规则与高性能批量处理：
## 1. 严格以 epicenter 为球心，采用 Caelix CellCenter 欧氏几何采样，杜绝形变与偏移
## 2. 批量原子化移除与集中物理感知，杜绝逐格 BFS 造成的严重掉帧卡顿
## 3. 核心区瞬间气化，边缘区依硬度剥离飞溅，同时对刚体与玩家施加真实径向冲量

static func trigger_explosion(epicenter: Vector3, radius: float, blast_power: float, chunk_manager: ChunkManager) -> void:
	if chunk_manager == null:
		return

	var scene_root = chunk_manager.get_tree().current_scene if chunk_manager.get_tree() != null else chunk_manager.get_parent()
	if scene_root == null:
		scene_root = chunk_manager

	# 1. 生成爆炸火球与冲击波视觉表现
	_spawn_explosion_visuals(scene_root, epicenter, radius)

	# 2. Caelix 规范：严格对称球形包围盒边界采样
	# 每个体素单元 cell [x, x+1) 的几何中心精确位于 cell + (0.5, 0.5, 0.5)
	var min_cell = Vector3i(
		floori(epicenter.x - radius - 0.5),
		floori(epicenter.y - radius - 0.5),
		floori(epicenter.z - radius - 0.5)
	)
	var max_cell = Vector3i(
		ceili(epicenter.x + radius - 0.5),
		ceili(epicenter.y + radius - 0.5),
		ceili(epicenter.z + radius - 0.5)
	)
	var rad_sq = radius * radius + 0.0001

	var blocks_to_remove: Array[Vector3i] = []
	var blocks_to_launch: Array[Dictionary] = []

	for z in range(min_cell.z, max_cell.z + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				var cell_center = Vector3(float(x) + 0.5, float(y) + 0.5, float(z) + 0.5)
				var dist_sq = (cell_center - epicenter).length_squared()
				if dist_sq > rad_sq:
					continue

				var v_type = chunk_manager.get_voxel(x, y, z)
				if not VoxelTypes.is_solid(v_type):
					continue

				var dist = sqrt(dist_sq)
				var falloff = 1.0 - (dist / radius) # 0.0 ~ 1.0 距离线性衰减
				var damage = blast_power * falloff
				var hardness = VoxelTypes.get_hardness(v_type)

				# 核心区 (< 0.5R) 瞬间粉碎；外圈受硬度阻抗减免
				if dist <= radius * 0.48 or damage >= hardness * 1.2:
					var v_pos = Vector3i(x, y, z)
					blocks_to_remove.append(v_pos)

					# 边缘剥离方块作为动力学落体弹射（上限 6 块，兼顾震撼表现与绝对流畅度）
					if dist >= radius * 0.45 and blocks_to_launch.size() < 6:
						var dir = (cell_center - epicenter).normalized()
						if dir.is_zero_approx():
							dir = Vector3.UP
						var launch_speed = blast_power * falloff * 0.8
						var launch_vel = dir * launch_speed + Vector3(0, 3.2 * falloff, 0)
						blocks_to_launch.append({
							"type": v_type,
							"pos": Vector3(v_pos),
							"vel": launch_vel
						})

	# 3. 批量原子化从大地图移除（调用 ChunkManager 批处理，彻底消除逐格 BFS 卡顿）
	chunk_manager.remove_voxels_batch(blocks_to_remove)

	# 4. 生成少量飞溅动力学落体
	for item in blocks_to_launch:
		var f_block = FallingBlockEntity.new()
		scene_root.add_child(f_block)
		f_block.setup(item["type"], item["pos"], item["vel"], chunk_manager)

	# 5. 对周围物理刚体（VoxelEntity 等）施加真实径向冲量
	var world_3d: World3D = null
	if chunk_manager.get_parent() is Node3D:
		world_3d = (chunk_manager.get_parent() as Node3D).get_world_3d()
	elif scene_root is Node3D:
		world_3d = (scene_root as Node3D).get_world_3d()
	elif chunk_manager.get_viewport() != null:
		world_3d = chunk_manager.get_viewport().find_world_3d()

	if world_3d != null and world_3d.direct_space_state != null:
		var space_state = world_3d.direct_space_state
		var query = PhysicsShapeQueryParameters3D.new()
		var sphere = SphereShape3D.new()
		sphere.radius = radius * 1.5
		query.shape = sphere
		query.transform = Transform3D(Basis(), epicenter)

		var results = space_state.intersect_shape(query, 32)
		for res in results:
			var col = res.get("collider", null)
			if col is RigidBody3D:
				var rb = col as RigidBody3D
				var to_body = rb.global_position - epicenter
				var dist = to_body.length()
				if dist > 0.001:
					var norm = to_body / dist
					var impulse_mag = blast_power * (1.0 - clampf(dist / (radius * 1.5), 0.0, 1.0)) * 1.4 * rb.mass
					rb.apply_central_impulse(norm * impulse_mag + Vector3.UP * (impulse_mag * 0.25))
					rb.apply_torque_impulse(Vector3(
						randf_range(-1, 1),
						randf_range(-1, 1),
						randf_range(-1, 1)
					) * impulse_mag * 0.3)

	# 6. 对玩家施加平滑爆炸击退速度
	var players = chunk_manager.get_tree().get_nodes_in_group("player")
	for p in players:
		if p is CharacterBody3D:
			var to_player = p.global_position - epicenter
			var dist = to_player.length()
			if dist < radius * 1.6 and dist > 0.01:
				var norm = to_player.normalized()
				var player_knockback = blast_power * (1.0 - dist / (radius * 1.6)) * 0.9
				p.velocity += norm * player_knockback + Vector3.UP * (player_knockback * 0.4)


## 爆炸火焰光芒与冲击波粒子
static func _spawn_explosion_visuals(parent: Node, pos: Vector3, radius: float) -> void:
	var particles = CPUParticles3D.new()
	particles.top_level = true
	particles.position = pos
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.lifetime = 0.55
	particles.amount = 24

	var p_mesh = BoxMesh.new()
	p_mesh.size = Vector3(0.20, 0.20, 0.20)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.12, 1.0)
	p_mesh.material = mat
	particles.mesh = p_mesh

	particles.spread = 180.0
	particles.initial_velocity_min = 3.5
	particles.initial_velocity_max = radius * 3.0
	particles.gravity = Vector3(0, -6.0, 0)

	parent.add_child(particles)
	var t = parent.get_tree().create_timer(0.7)
	t.timeout.connect(particles.queue_free)
