class_name ChunkManager extends Node

@export var color_array: Dictionary[int, Color] = {}
@export var chunk_size: int = 128
@export var meshing_algorithm: MeshingAlgorithm
@export var terrain_algorithm: TerrainAlgorithm

@export_group("Caelix Hardware Raytracing (Route 3B)")
@export var use_hardware_raytracer: bool = true
@export var rt_render_width: int = 1280
@export var rt_render_height: int = 720
@export var enable_upscaling_filter: bool = true
@export var show_rt_hud: bool = true

@export_group("Raytracing Visuals (Route A)")
@export var sun_direction: Vector3 = Vector3(0.55, 0.75, 0.35).normalized()
@export var sun_color: Color = Color(1.0, 0.96, 0.88, 1.0)
@export var sun_intensity: float = 1.0
@export var ambient_intensity: float = 0.28
@export var rtao_strength: float = 0.65
@export var rtao_radius: float = 2.5
@export var soft_shadow_angle: float = 0.035
@export var enable_rtao: bool = true
@export var enable_shadows: bool = true
@export var sun_cycle_speed: float = 0.0

@export_group("Dynamic Streaming")
@export var player: Node3D
@export var view_distance: int = 2 # 水平视距半径（以 128^3 Sector 为单位，2 表示 5x5 区域，覆盖 640x640 米）
@export var unload_distance: int = 3 # 卸载距离（3 表示 7x7 之外卸载，覆盖近 1 公里）
@export var max_ms_per_frame: float = 6.0 # 每帧最多耗时（毫秒）
@export var max_chunks_per_frame: int = 1 # 单帧上限保护
@export var initial_immediate_radius: int = 0 # 启动时立即同步生成玩家脚下 1 个核心 Sector
@export var max_height: int = 128 # 世界垂直高度上限 (128^3)

const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(-1, 0, 0), # 0: -X
	Vector3i(1, 0, 0),  # 1: +X
	Vector3i(0, -1, 0), # 2: -Y
	Vector3i(0, 1, 0),  # 3: +Y
	Vector3i(0, 0, -1), # 4: -Z
	Vector3i(0, 0, 1)   # 5: +Z
]
const OPPOSITE_DIRECTIONS: Array[int] = [1, 0, 3, 2, 5, 4]

var chunk_class = preload("uid://dh84jil6lln54")
var chunks: Dictionary[Vector3i, Chunk] = {} # world_pos -> Chunk 实例 (保留用于数据与碰撞查询)
var empty_chunks: Dictionary[Vector3i, bool] = {} # world_pos -> true（标记无体素的纯空气区块）
var load_queue: Array[Vector3i] = [] # 待生成的区块网格坐标队列
var queue_set: Dictionary[Vector3i, bool] = {} # chunk_coord -> true（快速查重）
var in_progress_set: Dictionary[Vector3i, bool] = {} # chunk_coord -> true（正在后台异步生成的区块）
var last_player_chunk: Vector3i = Vector3i(999999, 999999, 999999)

# Caelix 硬件光追组件
var raytracer = null
var rt_canvas_layer: CanvasLayer = null
var rt_texture_rect: TextureRect = null
var rt_hud_label: Label = null

# 动态局部物理探针（Local Voxel Collider：为硬件光追管线提供零卡顿的角色物理碰撞）
var local_collider: StaticBody3D = null
var local_collision_shape: CollisionShape3D = null
var local_concave_shape: ConcavePolygonShape3D = null
var last_collider_center: Vector3i = Vector3i(999999, 999999, 999999)
var local_collider_dirty: bool = false
var dirty_rt_sectors: Dictionary[Vector3i, Chunk] = {}
var voxel_physics: VoxelPhysicsEngine = null


func _ready() -> void:
	voxel_physics = VoxelPhysicsEngine.new()
	voxel_physics.name = "VoxelPhysicsEngine"
	add_child(voxel_physics)

	terrain_algorithm.max_height = max_height

	# 同步并补全 VoxelTypes 全局模块提供的色盘，确保全方块光栅化与光追色彩一致
	var registry_palette = VoxelTypes.get_palette()
	for k in registry_palette.keys():
		if not color_array.has(k):
			color_array[k] = registry_palette[k]
	meshing_algorithm.SetColors(color_array)
	
	find_player()
	var start_coord = Vector3i.ZERO
	if player != null:
		start_coord = world_to_chunk_coord(player.global_position)
	last_player_chunk = start_coord

	# 1. 初始化 Caelix Vulkan 硬件光追模块与全屏呈现
	if use_hardware_raytracer and ClassDB.class_exists("VoxelRayTracer"):
		raytracer = ClassDB.instantiate("VoxelRayTracer")
		add_child(raytracer)
		var ok = raytracer.init_raytracer(rt_render_width, rt_render_height)
		if ok:
			raytracer.set_sun_direction(sun_direction)
			raytracer.set_sun_color(sun_color)
			raytracer.set_sun_intensity(sun_intensity)
			raytracer.set_ambient_intensity(ambient_intensity)
			raytracer.set_rtao_strength(rtao_strength)
			raytracer.set_rtao_radius(rtao_radius)
			raytracer.set_soft_shadow_angle(soft_shadow_angle)
			raytracer.set_enable_rtao(enable_rtao)
			raytracer.set_enable_shadows(enable_shadows)
			setup_raytracer_display()
			setup_local_collider()
			print("[ChunkManager] Caelix Hardware Raytracing Pipeline Activated on: ", raytracer.get_gpu_name())
		else:
			printerr("[ChunkManager] Failed to init VoxelRayTracer! Falling back to rasterization.")
			use_hardware_raytracer = false

	# 2. 生成角色脚下核心区块
	init_immediate_chunks(start_coord)
	if use_hardware_raytracer:
		update_local_collider(true)

	# 3. 将周围 view_distance 内的其余区块加入后台平滑流式加载队列
	update_chunks_around_player(start_coord)


func setup_raytracer_display() -> void:
	rt_canvas_layer = CanvasLayer.new()
	rt_canvas_layer.layer = -10 # 置于最底层，不遮挡任何后续 UI
	
	rt_texture_rect = TextureRect.new()
	rt_texture_rect.name = "RaytracedViewport"
	rt_texture_rect.texture = raytracer.get_output_texture()
	rt_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rt_texture_rect.anchor_right = 1.0
	rt_texture_rect.anchor_bottom = 1.0
	if enable_upscaling_filter:
		rt_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	rt_canvas_layer.add_child(rt_texture_rect)
	apply_bg_canvas_environment()

	# 准星与状态 HUD
	if show_rt_hud:
		var hud_layer = CanvasLayer.new()
		hud_layer.layer = 10
		
		# 准星 Crosshair
		var crosshair = Label.new()
		crosshair.text = "+"
		crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		crosshair.anchor_left = 0.5
		crosshair.anchor_top = 0.5
		crosshair.anchor_right = 0.5
		crosshair.anchor_bottom = 0.5
		crosshair.offset_left = -20
		crosshair.offset_top = -20
		crosshair.offset_right = 20
		crosshair.offset_bottom = 20
		crosshair.add_theme_font_size_override("font_size", 24)
		crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		hud_layer.add_child(crosshair)

		# 状态信息
		rt_hud_label = Label.new()
		rt_hud_label.name = "RTHud"
		rt_hud_label.offset_left = 16
		rt_hud_label.offset_top = 16
		rt_hud_label.offset_right = 800
		rt_hud_label.offset_bottom = 120
		rt_hud_label.add_theme_font_size_override("font_size", 14)
		rt_hud_label.add_theme_color_override("font_color", Color(0.2, 0.9, 0.5, 0.95))
		hud_layer.add_child(rt_hud_label)
		
		add_child(hud_layer)

	add_child(rt_canvas_layer)


func setup_local_collider() -> void:
	local_collider = StaticBody3D.new()
	local_collider.name = "LocalVoxelCollider"
	local_collision_shape = CollisionShape3D.new()
	local_collision_shape.name = "CollisionShape3D"
	local_concave_shape = ConcavePolygonShape3D.new()
	local_concave_shape.backface_collision = true
	local_collision_shape.shape = local_concave_shape
	local_collider.add_child(local_collision_shape)
	add_child(local_collider)


func _physics_process(_delta: float) -> void:
	if use_hardware_raytracer and player != null:
		update_local_collider()


func is_voxel_solid(gx: int, gy: int, gz: int) -> bool:
	if gy < 0 or gy >= max_height:
		return false
	var chunk_origin = Vector3i(
		floori(float(gx) / chunk_size) * chunk_size,
		floori(float(gy) / chunk_size) * chunk_size,
		floori(float(gz) / chunk_size) * chunk_size
	)
	if not chunks.has(chunk_origin):
		return false
	var chunk = chunks[chunk_origin]
	if chunk == null or chunk.chunk_data == null:
		return false
	var lx = gx - chunk_origin.x
	var ly = gy - chunk_origin.y
	var lz = gz - chunk_origin.z
	return chunk.chunk_data.IsSolid(lx, ly, lz)


func get_voxel(gx: int, gy: int, gz: int) -> int:
	if gy < 0 or gy >= max_height:
		return VoxelTypes.Type.AIR
	var chunk_origin = Vector3i(
		floori(float(gx) / chunk_size) * chunk_size,
		floori(float(gy) / chunk_size) * chunk_size,
		floori(float(gz) / chunk_size) * chunk_size
	)
	if not chunks.has(chunk_origin):
		return VoxelTypes.Type.AIR
	var chunk = chunks[chunk_origin]
	if chunk == null or chunk.chunk_data == null:
		return VoxelTypes.Type.AIR
	var lx = gx - chunk_origin.x
	var ly = gy - chunk_origin.y
	var lz = gz - chunk_origin.z
	return int(chunk.chunk_data.GetVoxel(lx, ly, lz))


## 动态局部物理探针：仅在玩家周围 5x6x5 体素内构建物理碰撞网格（耗时 < 0.05ms，彻底根治全图烘焙卡顿）
func update_local_collider(force_rebuild: bool = false) -> void:
	if local_collider == null or player == null or local_concave_shape == null:
		return
	var center = Vector3i(
		floori(player.global_position.x),
		floori(player.global_position.y),
		floori(player.global_position.z)
	)
	if not force_rebuild and center == last_collider_center:
		return
	last_collider_center = center

	var rx = 2
	var rz = 2
	var r_down = 3
	var r_up = 2

	var faces = PackedVector3Array()
	
	for y in range(center.y - r_down, center.y + r_up + 1):
		for z in range(center.z - rz, center.z + rz + 1):
			for x in range(center.x - rx, center.x + rx + 1):
				if not is_voxel_solid(x, y, z):
					continue
				
				var fx = float(x)
				var fy = float(y)
				var fz = float(z)

				# 6 面消面测试：仅向空气暴露的面添加碰撞双三角形
				# 1. +Y 顶面 (Normal: (0, 1, 0))
				if not is_voxel_solid(x, y + 1, z):
					faces.append(Vector3(fx, fy + 1.0, fz))
					faces.append(Vector3(fx, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx, fy + 1.0, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz))
				
				# 2. -Y 底面 (Normal: (0, -1, 0))
				if not is_voxel_solid(x, y - 1, z):
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx + 1.0, fy, fz))
					faces.append(Vector3(fx + 1.0, fy, fz + 1.0))
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx + 1.0, fy, fz + 1.0))
					faces.append(Vector3(fx, fy, fz + 1.0))

				# 3. +X 东表面 (Normal: (1, 0, 0))
				if not is_voxel_solid(x + 1, y, z):
					faces.append(Vector3(fx + 1.0, fy, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy, fz + 1.0))

				# 4. -X 西表面 (Normal: (-1, 0, 0))
				if not is_voxel_solid(x - 1, y, z):
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx, fy, fz + 1.0))
					faces.append(Vector3(fx, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx, fy + 1.0, fz))

				# 5. +Z 南表面 (Normal: (0, 0, 1))
				if not is_voxel_solid(x, y, z + 1):
					faces.append(Vector3(fx, fy, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx, fy, fz + 1.0))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz + 1.0))
					faces.append(Vector3(fx, fy + 1.0, fz + 1.0))

				# 6. -Z 北表面 (Normal: (0, 0, -1))
				if not is_voxel_solid(x, y, z - 1):
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx, fy + 1.0, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz))
					faces.append(Vector3(fx, fy, fz))
					faces.append(Vector3(fx + 1.0, fy + 1.0, fz))
					faces.append(Vector3(fx + 1.0, fy, fz))

	local_concave_shape.set_faces(faces)


func _process(_delta: float) -> void:
	if player == null:
		find_player()
		if player == null:
			return

	var current_chunk = world_to_chunk_coord(player.global_position)
	if current_chunk.x != last_player_chunk.x or current_chunk.z != last_player_chunk.z:
		last_player_chunk = current_chunk
		update_chunks_around_player(current_chunk)
		unload_distant_chunks(current_chunk)

	# 后台线程池平滑消费加载队列
	process_load_queue()

	# 硬件光追逐帧渲染调度
	if use_hardware_raytracer and raytracer != null and player != null:
		flush_dirty_rt_sectors()

		# 动态太阳光与光追参数更新
		if sun_cycle_speed > 0.001:
			var t_rad = Time.get_ticks_msec() * 0.001 * sun_cycle_speed
			sun_direction = Vector3(cos(t_rad) * 0.75, max(sin(t_rad), 0.08), sin(t_rad) * 0.45).normalized()
			raytracer.set_sun_direction(sun_direction)
		else:
			var dir_light = get_node_or_null("../DirectionalLight3D")
			if dir_light != null and is_instance_valid(dir_light):
				var light_sun_dir = dir_light.global_transform.basis.z.normalized()
				raytracer.set_sun_direction(light_sun_dir)
				raytracer.set_sun_color(dir_light.light_color)

		var cam = player.eye_camera
		if cam != null:
			raytracer.render_frame(cam.global_transform, cam.fov)
			if rt_hud_label != null:
				var fps = Engine.get_frames_per_second()
				var cur_sdir = raytracer.get_sun_direction()
				rt_hud_label.text = "[Caelix RT Mode] FPS: %d | RTAO: %s | Soft Shadows: %s\nGPU: %s\nActive Sectors: %d | Resolution: %dx%d\nCam Pos: (%.1f, %.1f, %.1f) | Flying: %s\nSun Dir: (%.2f, %.2f, %.2f) (F6: AO, F7: Shadows, [/]: Sun Angle)" % [
					fps,
					"ON" if raytracer.is_rtao_enabled() else "OFF",
					"ON" if raytracer.is_shadows_enabled() else "OFF",
					raytracer.get_gpu_name(),
					raytracer.get_active_sector_count(),
					rt_render_width,
					rt_render_height,
					player.global_position.x, player.global_position.y, player.global_position.z,
					str(player.flying),
					cur_sdir.x, cur_sdir.y, cur_sdir.z
				]


func _unhandled_input(event: InputEvent) -> void:
	if not use_hardware_raytracer or raytracer == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F6:
			enable_rtao = not enable_rtao
			raytracer.set_enable_rtao(enable_rtao)
			print("[Raytracer] RTAO toggled: ", enable_rtao)
		elif event.keycode == KEY_F7:
			enable_shadows = not enable_shadows
			raytracer.set_enable_shadows(enable_shadows)
			print("[Raytracer] Shadows toggled: ", enable_shadows)
		elif event.keycode == KEY_BRACKETLEFT:
			var cur_dir = raytracer.get_sun_direction()
			var rotated = cur_dir.rotated(Vector3.UP, deg_to_rad(-10.0))
			raytracer.set_sun_direction(rotated)
			var dir_light = get_node_or_null("../DirectionalLight3D")
			if dir_light != null and is_instance_valid(dir_light):
				dir_light.look_at(dir_light.global_position - rotated, Vector3.UP)
		elif event.keycode == KEY_BRACKETRIGHT:
			var cur_dir = raytracer.get_sun_direction()
			var rotated = cur_dir.rotated(Vector3.UP, deg_to_rad(10.0))
			raytracer.set_sun_direction(rotated)
			var dir_light = get_node_or_null("../DirectionalLight3D")
			if dir_light != null and is_instance_valid(dir_light):
				dir_light.look_at(dir_light.global_position - rotated, Vector3.UP)


## 延迟扇区批量刷新：将单帧内上百个微小体素变更（落沙、水流）合并为单次 BLAS 重建与物理更新，彻底杜绝 GC 暴涨与 GPU 管线等待
func flush_dirty_rt_sectors() -> void:
	if not dirty_rt_sectors.is_empty():
		for coord in dirty_rt_sectors.keys():
			var chunk = dirty_rt_sectors[coord]
			if chunk != null and is_instance_valid(chunk) and chunk.chunk_data != null:
				var rt_data = chunk.chunk_data.GetRayTracingData()
				raytracer.upload_sector_aabbs(coord, rt_data[0])
				raytracer.upload_sector_bricks(coord, rt_data[1])
		dirty_rt_sectors.clear()

	if local_collider_dirty:
		local_collider_dirty = false
		update_local_collider(true)



func find_player() -> void:
	if player != null:
		return
	if get_parent() != null and get_parent().has_node("Player"):
		player = get_parent().get_node("Player") as Node3D
		return
	var players = get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		player = players[0] as Node3D
	apply_bg_canvas_environment()


## 确保场景包含 WorldEnvironment 并设置 background_mode = BG_CANVAS (3) 和 background_canvas_max_layer = 0
## 使得 CanvasLayer -10 的硬件光追纹理作为 3D 渲染背景，
## 允许所有原生 3D 节点（准星高亮线框、放置幽灵预览、刚体碎片、破碎粒子）在前景以原生 3D 准确呈现！
func apply_bg_canvas_environment() -> void:
	var we: WorldEnvironment = null
	if get_parent() != null and get_parent().has_node("WorldEnvironment"):
		we = get_parent().get_node("WorldEnvironment") as WorldEnvironment
	elif has_node("WorldEnvironment"):
		we = get_node("WorldEnvironment") as WorldEnvironment
	
	if we == null:
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		add_child(we)
	
	if we.environment == null:
		we.environment = Environment.new()
		
	we.environment.background_mode = Environment.BG_CANVAS
	we.environment.background_canvas_max_layer = 0

	# 同步摄像机环境
	if player != null and player.has_node("Head/EyeCamera"):
		var cam = player.get_node("Head/EyeCamera") as Camera3D
		if cam != null:
			if cam.environment == null:
				cam.environment = Environment.new()
			cam.environment.background_mode = Environment.BG_CANVAS
			cam.environment.background_canvas_max_layer = 0



## 启动时立即同步生成近处核心区块（毫秒级秒进）
func init_immediate_chunks(center_coord: Vector3i) -> void:
	var vertical_chunks = maxi(1, ceili(float(max_height) / float(chunk_size)))
	for dx in range(-initial_immediate_radius, initial_immediate_radius + 1):
		for dz in range(-initial_immediate_radius, initial_immediate_radius + 1):
			for y in range(vertical_chunks):
				var coord = Vector3i(center_coord.x + dx, y, center_coord.z + dz)
				generate_chunk_at_sync(coord)


## 将角色周围 view_distance 内未生成的区块推入加载队列
func update_chunks_around_player(center_coord: Vector3i) -> void:
	var vertical_chunks = maxi(1, ceili(float(max_height) / float(chunk_size)))
	var new_coords: Array[Vector3i] = []
	var view_dist_sq = view_distance * view_distance
	
	for dx in range(-view_distance, view_distance + 1):
		for dz in range(-view_distance, view_distance + 1):
			if dx * dx + dz * dz > view_dist_sq:
				continue
				
			for y in range(vertical_chunks):
				var coord = Vector3i(center_coord.x + dx, y, center_coord.z + dz)
				var world_pos = coord * chunk_size
				if not chunks.has(world_pos) and not empty_chunks.has(world_pos) and not queue_set.has(coord) and not in_progress_set.has(coord):
					new_coords.append(coord)
					queue_set[coord] = true

	load_queue.append_array(new_coords)
	load_queue.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var da = (a.x - center_coord.x) * (a.x - center_coord.x) + (a.z - center_coord.z) * (a.z - center_coord.z)
		var db = (b.x - center_coord.x) * (b.x - center_coord.x) + (b.z - center_coord.z) * (b.z - center_coord.z)
		return da < db
	)


## 在后台线程池并行消费生成任务
func process_load_queue() -> void:
	if load_queue.is_empty():
		return

	var max_concurrent = 2
	while not load_queue.is_empty() and in_progress_set.size() < max_concurrent:
		var coord = load_queue.pop_front()
		queue_set.erase(coord)

		var world_pos = coord * chunk_size
		if chunks.has(world_pos) or empty_chunks.has(world_pos) or in_progress_set.has(coord):
			continue

		in_progress_set[coord] = true
		dispatch_chunk_task(coord)


func dispatch_chunk_task(coord: Vector3i) -> void:
	var world_pos = coord * chunk_size
	var chunk = create_chunk(world_pos)

	WorkerThreadPool.add_task(func():
		var t0 = Time.get_ticks_msec()
		chunk.generate_data(terrain_algorithm)
		var t1 = Time.get_ticks_msec()

		if use_hardware_raytracer:
			# 【Caelix 硬件光追路线】：极速无 GC 导出 AABB 与 Brick SSBO（~12ms 单次遍历）
			if not chunk.chunk_data.IsEmpty():
				var rt_data = chunk.chunk_data.GetRayTracingData()
				var aabb_bytes = rt_data[0]
				var brick_bytes = rt_data[1]
				call_deferred("_on_rt_chunk_task_completed", coord, chunk, aabb_bytes, brick_bytes, t1 - t0)
			else:
				call_deferred("_on_rt_chunk_task_completed", coord, chunk, PackedByteArray(), PackedByteArray(), t1 - t0)
		else:
			# 【传统光栅化网格路线】
			if not chunk.chunk_data.IsEmpty():
				chunk.prepare_sub_chunks_background()
			var t2 = Time.get_ticks_msec()
			call_deferred("_on_chunk_task_completed", coord, chunk, t1 - t0, t2 - t1)
	)


## Caelix 硬件光追专属回调：O(1) 瞬间提交 GPU，0 场景树节点膨胀，0 物理死锁！
func _on_rt_chunk_task_completed(coord: Vector3i, chunk: Chunk, aabb_bytes: PackedByteArray, brick_bytes: PackedByteArray, terrain_ms: int) -> void:
	in_progress_set.erase(coord)
	var world_pos = coord * chunk_size

	if aabb_bytes.is_empty() or brick_bytes.is_empty():
		remove_chunk(chunk.position)
		empty_chunks[world_pos] = true
		return

	# 保留 chunk 实例供体素数据快速查询与修改
	chunks[world_pos] = chunk
	
	# 向 RTX 4070 硬件提交 AABBs 构建 BLAS
	raytracer.upload_sector_aabbs(coord, aabb_bytes)
	raytracer.upload_sector_bricks(coord, brick_bytes)
	print("[Sector %s] Done RT Stream: Terrain %d ms | Uploaded %d Bricks to BLAS (Active Sectors: %d)" % [
		coord, terrain_ms, aabb_bytes.size() / 24, raytracer.get_active_sector_count()
	])
	
	if player != null:
		var p_coord = world_to_chunk_coord(player.global_position)
		if coord == p_coord:
			update_local_collider(true)


## 传统光栅化回调（兼容回退模式）
func _on_chunk_task_completed(coord: Vector3i, chunk: Chunk, terrain_ms: int, mesh_ms: int) -> void:
	in_progress_set.erase(coord)
	var world_pos = coord * chunk_size
	if not chunks.has(world_pos) or chunks[world_pos] != chunk:
		chunk.queue_free()
		return

	if chunk.chunk_data.IsEmpty():
		remove_chunk(chunk.position)
		empty_chunks[world_pos] = true
		return

	chunk.apply_prepared_sub_chunks()
	add_child(chunk)
	link_neighbors(coord, chunk)
	print("[Sector %s] Done Async: Terrain %d ms | Meshing %d ms (Active SubChunks: %d/64)" % [coord, terrain_ms, mesh_ms, chunk.sub_chunks.size()])


## 同步生成单个核心区块
func generate_chunk_at_sync(coord: Vector3i) -> void:
	var world_pos = coord * chunk_size
	var chunk = create_chunk(world_pos)
	chunk.generate_data(terrain_algorithm)

	if chunk.chunk_data.IsEmpty():
		remove_chunk(chunk.position)
		empty_chunks[world_pos] = true
		return

	if use_hardware_raytracer and raytracer != null:
		var rt_data = chunk.chunk_data.GetRayTracingData()
		var aabb_bytes = rt_data[0]
		var brick_bytes = rt_data[1]
		if not aabb_bytes.is_empty():
			chunks[world_pos] = chunk
			raytracer.upload_sector_aabbs(coord, aabb_bytes)
			raytracer.upload_sector_bricks(coord, brick_bytes)
	else:
		chunk.create_mesh()
		add_child(chunk)
		link_neighbors(coord, chunk)


## 建立 6 向跨 Sector 拓扑关联（传统光栅化模式消面使用）
func link_neighbors(coord: Vector3i, chunk: Chunk) -> void:
	for dir in range(6):
		var n_coord = coord + NEIGHBOR_OFFSETS[dir]
		var n_pos = n_coord * chunk_size
		if chunks.has(n_pos):
			var n_chunk = chunks[n_pos]
			var opp_dir = OPPOSITE_DIRECTIONS[dir]
			chunk.chunk_data.SetNeighbor(dir, n_chunk.chunk_data)
			n_chunk.chunk_data.SetNeighbor(opp_dir, chunk.chunk_data)
			n_chunk.mark_boundary_dirty(opp_dir)
			n_chunk.flush_dirty()


func unlink_neighbors(coord: Vector3i, chunk: Chunk) -> void:
	for dir in range(6):
		var n_coord = coord + NEIGHBOR_OFFSETS[dir]
		var n_pos = n_coord * chunk_size
		if chunks.has(n_pos):
			var n_chunk = chunks[n_pos]
			var opp_dir = OPPOSITE_DIRECTIONS[dir]
			n_chunk.chunk_data.SetNeighbor(opp_dir, null)
			n_chunk.mark_boundary_dirty(opp_dir)
			n_chunk.flush_dirty()


## 卸载远距离区块
func unload_distant_chunks(center_coord: Vector3i) -> void:
	var unload_dist_sq = unload_distance * unload_distance
	var chunks_to_remove: Array[Vector3i] = []
	for world_pos in chunks.keys():
		var cx = floori(float(world_pos.x) / chunk_size)
		var cz = floori(float(world_pos.z) / chunk_size)
		var dx = cx - center_coord.x
		var dz = cz - center_coord.z
		if dx * dx + dz * dz > unload_dist_sq:
			chunks_to_remove.append(world_pos)
			
	for world_pos in chunks_to_remove:
		remove_chunk(world_pos)
		
	var empty_to_remove: Array[Vector3i] = []
	for world_pos in empty_chunks.keys():
		var cx = floori(float(world_pos.x) / chunk_size)
		var cz = floori(float(world_pos.z) / chunk_size)
		var dx = cx - center_coord.x
		var dz = cz - center_coord.z
		if dx * dx + dz * dz > unload_dist_sq * 2:
			empty_to_remove.append(world_pos)
			
	for world_pos in empty_to_remove:
		empty_chunks.erase(world_pos)
		
	var filtered_queue: Array[Vector3i] = []
	for coord in load_queue:
		var dx = coord.x - center_coord.x
		var dz = coord.z - center_coord.z
		if dx * dx + dz * dz <= unload_dist_sq:
			filtered_queue.append(coord)
		else:
			queue_set.erase(coord)
	load_queue = filtered_queue


func create_chunk(chunk_position: Vector3i) -> Chunk:
	remove_chunk(chunk_position)
	var chunk = chunk_class.instantiate() as Chunk
	chunk.chunk_data.SetSize(chunk_size)
	chunk.meshing_algorithm = meshing_algorithm
	chunk.position = chunk_position
	chunk.is_raytracing_mode = use_hardware_raytracer
	chunks[chunk.position] = chunk
	return chunk


func remove_chunk(chunk_position: Vector3i) -> void:
	if !chunks.has(chunk_position): return
	var chunk = chunks[chunk_position]
	var coord = world_to_chunk_coord(chunk_position)
	
	if use_hardware_raytracer and raytracer != null:
		raytracer.remove_sector(coord)
	else:
		unlink_neighbors(coord, chunk)
		
	chunks.erase(chunk_position)
	chunk.queue_free()


func add_voxel(pos: Vector3i, voxel: int = 1) -> void:
	var chunk = get_chunk(pos)
	if !chunk:
		var chunk_origin = voxel_to_chunk_position(pos)
		chunk = create_chunk(chunk_origin)
		empty_chunks.erase(chunk_origin)
	
	var local_position = global_to_local(pos)
	var b_idx = chunk.chunk_data.GetBrickIndex(local_position.x, local_position.y, local_position.z)
	var solid_before = chunk.chunk_data.IsBrickSolid(b_idx)

	chunk.add_voxel(local_position, voxel)
	
	var solid_after = chunk.chunk_data.IsBrickSolid(b_idx)

	if use_hardware_raytracer and raytracer != null:
		var coord = world_to_chunk_coord(chunk.position)
		var patched = false
		if solid_before and solid_after:
			var b_bytes = chunk.chunk_data.SerializeSingleBrick(b_idx)
			patched = raytracer.patch_sector_brick(coord, b_idx, b_bytes)

		if not patched:
			dirty_rt_sectors[coord] = chunk

		if VoxelTypes.is_solid(voxel):
			local_collider_dirty = true
	else:
		check_and_notify_neighbors(chunk)

	if voxel_physics != null:
		voxel_physics.notify_voxel_placed(pos, voxel)


func remove_voxel(pos: Vector3i) -> void:
	var chunk = get_chunk(pos)
	if !chunk: return
	
	var local_position = global_to_local(pos)	
	var b_idx = chunk.chunk_data.GetBrickIndex(local_position.x, local_position.y, local_position.z)
	var solid_before = chunk.chunk_data.IsBrickSolid(b_idx)

	chunk.remove_voxel(local_position)
	
	if voxel_physics != null:
		voxel_physics.notify_voxel_removed(pos)
	
	if chunk.chunk_data.IsEmpty():
		empty_chunks[chunk.position] = true
		remove_chunk(chunk.position)
		if use_hardware_raytracer:
			local_collider_dirty = true
		return

	var solid_after = chunk.chunk_data.IsBrickSolid(b_idx)

	if use_hardware_raytracer and raytracer != null:
		var coord = world_to_chunk_coord(chunk.position)
		var patched = false
		if solid_before and solid_after:
			var b_bytes = chunk.chunk_data.SerializeSingleBrick(b_idx)
			patched = raytracer.patch_sector_brick(coord, b_idx, b_bytes)

		if not patched:
			dirty_rt_sectors[coord] = chunk

		local_collider_dirty = true
	else:
		check_and_notify_neighbors(chunk)


## 批量原子化移除体素（专为爆炸、大规模开凿与断裂优化，单次批处理耗时 < 1ms，彻底消除卡顿）
func remove_voxels_batch(positions: Array[Vector3i]) -> void:
	if positions.is_empty():
		return

	# 1. 禁用物理引擎单格级联，防止对几百个体素重复触发 BFS
	if voxel_physics != null:
		voxel_physics._is_internal_op = true

	var affected_chunks: Dictionary = {}
	var affected_bricks: Dictionary = {}
	var modified_positions: Array[Vector3i] = []

	for pos in positions:
		var chunk = get_chunk(pos)
		if chunk == null or chunk.chunk_data == null:
			continue

		var local_pos = global_to_local(pos)
		# 仅在非空时执行移除 (4 is AIR)
		if chunk.chunk_data.GetVoxel(local_pos.x, local_pos.y, local_pos.z) != 4:
			var b_idx = chunk.chunk_data.GetBrickIndex(local_pos.x, local_pos.y, local_pos.z)
			chunk.chunk_data.RemoveVoxel(local_pos.x, local_pos.y, local_pos.z)
			affected_chunks[chunk] = true
			modified_positions.append(pos)
			
			var coord = world_to_chunk_coord(chunk.position)
			if not affected_bricks.has(coord):
				affected_bricks[coord] = {}
			affected_bricks[coord][b_idx] = true

	if voxel_physics != null:
		voxel_physics._is_internal_op = false

	if modified_positions.is_empty():
		return

	# 2. 批量提交光追 / 光栅化局部更新
	if use_hardware_raytracer and raytracer != null:
		for coord in affected_bricks.keys():
			var chunk_pos = coord * chunk_size
			if not chunks.has(chunk_pos):
				continue
			var chunk = chunks[chunk_pos]
			if chunk.chunk_data.IsEmpty():
				empty_chunks[chunk.position] = true
				remove_chunk(chunk.position)
				continue

			var brick_map = affected_bricks[coord]
			# 先极速热补丁更新显存中的体素记录
			for b_idx in brick_map.keys():
				var b_bytes = chunk.chunk_data.SerializeSingleBrick(b_idx)
				raytracer.patch_sector_brick(coord, b_idx, b_bytes)
			
			# 同时加入延迟刷新队列，确保在帧末刷新时精确重建 BLAS AABB 包围盒与 TLAS 实例
			dirty_rt_sectors[coord] = chunk
				
		local_collider_dirty = true
		flush_dirty_rt_sectors()
	else:
		# 光栅化模式：每个受影响区块仅 flush_dirty 一次
		for chunk in affected_chunks.keys():
			if not is_instance_valid(chunk):
				continue
			if chunk.chunk_data.IsEmpty():
				empty_chunks[chunk.position] = true
				remove_chunk(chunk.position)
			else:
				chunk.flush_dirty()
				check_and_notify_neighbors(chunk)

	# 3. 爆炸外圈物理唤醒与结构承重分析（仅在全部方块挖空后，对边缘集中分析一次）
	if voxel_physics != null:
		voxel_physics.notify_explosion_finished(modified_positions)


func check_and_notify_neighbors(chunk: Chunk) -> void:
	var neighbor_dirty_mask = chunk.chunk_data.PopDirtyNeighborMask()
	if neighbor_dirty_mask != 0:
		var coord = world_to_chunk_coord(chunk.position)
		for dir in range(6):
			if (neighbor_dirty_mask & (1 << dir)) != 0:
				var n_coord = coord + NEIGHBOR_OFFSETS[dir]
				var n_pos = n_coord * chunk_size
				if chunks.has(n_pos):
					chunks[n_pos].mark_boundary_dirty(OPPOSITE_DIRECTIONS[dir])
					chunks[n_pos].flush_dirty()


func get_chunk(pos: Vector3i) -> Chunk:
	var chunk_position = voxel_to_chunk_position(pos)
	if !chunks.has(chunk_position): return null
	return chunks[chunk_position]


func world_to_chunk_coord(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(world_pos.x / chunk_size),
		floori(world_pos.y / chunk_size),
		floori(world_pos.z / chunk_size)
	)


func voxel_to_chunk_position(pos: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(pos.x) / chunk_size) * chunk_size,
		floori(float(pos.y) / chunk_size) * chunk_size,
		floori(float(pos.z) / chunk_size) * chunk_size
	)


func global_to_local(pos: Vector3i) -> Vector3i:
	var chunk_origin = voxel_to_chunk_position(pos)
	return pos - chunk_origin
