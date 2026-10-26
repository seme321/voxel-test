class_name VoxelExplosion extends RefCounted

## Caelix 风格体素物理爆炸与动量冲量场 (VoxelExplosion / ApplyBodyForceCommands)
## 整合三大物理冲击表现：
## 1. 核心区瞬间气化粉碎
## 2. 边缘受力方块解构并以真实动量向外炸飞（成为动态 FallingBlockEntity / VoxelEntity）
## 3. 径向冲击力推动周围所有物理刚体与角色产生强烈冲量反弹

static func trigger_explosion(epicenter: Vector3, radius: float, blast_power: float, chunk_manager: ChunkManager) -> void:
	if chunk_manager == null:
		return

	var scene_root = chunk_manager.get_tree().current_scene if chunk_manager.get_tree() != null else chunk_manager.get_parent()
	if scene_root == null:
		scene_root = chunk_manager

	# 1. 生成爆炸火球与冲击波视觉
	_spawn_explosion_visuals(scene_root, epicenter, radius)

	# 2. 体素网格破坏与动量剥离
	var i_rad = ceili(radius)
	var center_i = Vector3i(floori(epicenter.x), floori(epicenter.y), floori(epicenter.z))
	var rad_sq = radius * radius

	var blocks_to_remove: Array[Vector3i] = []
	var blocks_to_launch: Array[Dictionary] = []

	for dx in range(-i_rad, i_rad + 1):
		for dy in range(-i_rad, i_rad + 1):
			for dz in range(-i_rad, i_rad + 1):
				var offset = Vector3(float(dx), float(dy), float(dz))
				var dist_sq = offset.length_squared()
				if dist_sq > rad_sq:
					continue

				var v_pos = center_i + Vector3i(dx, dy, dz)
				var v_type = chunk_manager.get_voxel(v_pos.x, v_pos.y, v_pos.z)
				if not VoxelTypes.is_solid(v_type):
					continue

				var dist = sqrt(dist_sq)
				var falloff = 1.0 - (dist / radius)
				var damage = blast_power * falloff
				var hardness = VoxelTypes.get_hardness(v_type)

				if damage >= hardness * 0.4:
					blocks_to_remove.append(v_pos)

					# 内圈完全气化，外圈剥离转化为飞溅的动力学落体
					if dist >= radius * 0.40 and blocks_to_launch.size() < 40:
						var dir = (Vector3(v_pos) + Vector3(0.5, 0.5, 0.5) - epicenter).normalized()
						if dir.is_zero_approx():
							dir = Vector3.UP
						var launch_speed = blast_power * falloff * 0.75
						var launch_vel = dir * launch_speed + Vector3(0, 3.5 * falloff, 0)
						blocks_to_launch.append({
							"type": v_type,
							"pos": Vector3(v_pos),
							"vel": launch_vel
						})

	# 从大地图移除
	for pos in blocks_to_remove:
		chunk_manager.remove_voxel(pos)

	# 抛射动力学体素
	for item in blocks_to_launch:
		var f_block = FallingBlockEntity.new()
		scene_root.add_child(f_block)
		f_block.setup(item["type"], item["pos"], item["vel"], chunk_manager)

	# 3. 对物理刚体（VoxelEntity 等）施加真实径向冲量
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
		sphere.radius = radius * 1.6
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
					var impulse_mag = blast_power * (1.0 - clampf(dist / (radius * 1.6), 0.0, 1.0)) * 1.5 * rb.mass
					rb.apply_central_impulse(norm * impulse_mag + Vector3.UP * (impulse_mag * 0.3))
					rb.apply_torque_impulse(Vector3(
						randf_range(-1, 1),
						randf_range(-1, 1),
						randf_range(-1, 1)
					) * impulse_mag * 0.4)

	# 4. 对玩家施加爆炸击退速度
	var players = chunk_manager.get_tree().get_nodes_in_group("player")
	for p in players:
		if p is CharacterBody3D:
			var to_player = p.global_position - epicenter
			var dist = to_player.length()
			if dist < radius * 1.8:
				var norm = to_player.normalized()
				var player_knockback = blast_power * (1.0 - dist / (radius * 1.8)) * 1.2
				p.velocity += norm * player_knockback + Vector3.UP * (player_knockback * 0.5)


## 爆炸火焰光芒与黑烟粒子
static func _spawn_explosion_visuals(parent: Node, pos: Vector3, radius: float) -> void:
	var particles = CPUParticles3D.new()
	particles.top_level = true
	particles.position = pos
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.lifetime = 0.6
	particles.amount = 28

	var p_mesh = BoxMesh.new()
	p_mesh.size = Vector3(0.22, 0.22, 0.22)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.5, 0.1, 1.0)
	p_mesh.material = mat
	particles.mesh = p_mesh

	particles.spread = 180.0
	particles.initial_velocity_min = 4.0
	particles.initial_velocity_max = radius * 3.5
	particles.gravity = Vector3(0, -6.0, 0)

	parent.add_child(particles)
	var t = parent.get_tree().create_timer(0.8)
	t.timeout.connect(particles.queue_free)
