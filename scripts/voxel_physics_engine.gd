class_name VoxelPhysicsEngine extends Node

## Caelix 风格高并发稀疏动态体素物理引擎 (VoxelPhysicsEngine)
## 整合三大物理体系：
## 1. 稀疏重力落沙与 45° 休止角滑坡（自然下落计时与雪崩连锁）
## 2. 水体流体元胞自动机（瀑布倾泻、悬崖优先溢流、平地受控水压漫延与静止沉睡）
## 3. 悬空结构连通分量承重分析与原生 3D 刚体碎片崩塌（Teardown 风格断柱断桥粉碎坠落）
## 无活跃动态体素时 CPU 耗时为严格的 0.00ms

@export_group("Falling Sand Timings")
@export var vertical_fall_delay: float = 0.10 # 垂直自由下落间隔（秒/格，0.10s 即 10格/秒）
@export var slope_slide_delay: float = 0.18   # 45° 斜坡侧滑间隔（秒/格，具有真实地面摩擦阻力感）
@export var initial_wake_delay: float = 0.06  # 挖掘悬空后的启动停滞延时（产生逐级连锁雪崩波纹）

@export_group("Fluid Dynamics (Water)")
@export var fluid_fall_delay: float = 0.08    # 水体垂直跌落间隔（秒/格，瀑布疾速倾泻）
@export var fluid_flow_delay: float = 0.14    # 水体横向扩散与溢流间隔（秒/格，水波平缓漫延）

@export_group("Structural Integrity & Debris")
@export var enable_structural_integrity: bool = true # 启用浮空悬崖与被截断建筑的连通分量承重断裂检测
@export var ground_anchor_y: int = 2                 # 地基基岩判定高度
@export var max_debris_size: int = 100               # 刚体碎片最大体素量（超过则判定为连通主大陆，不崩塌）

@export_group("Performance Limits")
@export var max_active_steps_per_frame: int = 48     # 单帧物理步进上限保护

var chunk_manager: ChunkManager = null

# Vector3i -> Dictionary { "type": int, "timer": float }
var active_falling_voxels: Dictionary = {}

# Vector3i -> Dictionary { "type": int, "timer": float, "energy": int, "from_dir": Vector3i }
var active_fluids: Dictionary = {}

var _is_internal_op: bool = false

const HORIZONTAL_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]

const ALL_6_DIRECTIONS: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]


func _ready() -> void:
	if get_parent() is ChunkManager:
		chunk_manager = get_parent() as ChunkManager


# -----------------------------------------------------------------------------
# 唤醒与感知接口
# -----------------------------------------------------------------------------

## 唤醒重力方块（沙、砾石等）
func activate_voxel(pos: Vector3i, delay: float = -1.0) -> void:
	if chunk_manager == null or pos.y <= 0 or pos.y >= chunk_manager.max_height:
		return
	if active_falling_voxels.has(pos):
		return
	var v_type = chunk_manager.get_voxel(pos.x, pos.y, pos.z)
	if VoxelTypes.has_gravity(v_type):
		var actual_delay = delay if delay >= 0.0 else initial_wake_delay
		active_falling_voxels[pos] = {
			"type": v_type,
			"timer": actual_delay
		}


## 唤醒流体方块（水体等）
func activate_fluid(pos: Vector3i, delay: float = -1.0, energy: int = 3) -> void:
	if chunk_manager == null or pos.y <= 0 or pos.y >= chunk_manager.max_height:
		return
	var v_type = chunk_manager.get_voxel(pos.x, pos.y, pos.z)
	if not VoxelTypes.is_fluid(v_type):
		return
	if active_fluids.has(pos):
		active_fluids[pos]["energy"] = maxi(active_fluids[pos].get("energy", 0), energy)
		return
	var actual_delay = delay if delay >= 0.0 else initial_wake_delay
	active_fluids[pos] = {
		"type": v_type,
		"timer": actual_delay,
		"energy": energy,
		"from_dir": Vector3i.ZERO
	}


## 挖掘/破坏方块时的级联物理波纹与承重断裂检测
func notify_voxel_removed(pos: Vector3i) -> void:
	if _is_internal_op or chunk_manager == null:
		return

	# 1. 唤醒正上方与斜上方的重力方块（沙砾雪崩波纹）
	activate_voxel(pos + Vector3i(0, 1, 0), initial_wake_delay)
	for dir in HORIZONTAL_DIRECTIONS:
		activate_voxel(pos + dir + Vector3i(0, 1, 0), initial_wake_delay * 1.5)

	# 2. 唤醒周围 6 向临近的流体（赋予能量，使其能够流向空缺）
	for dir in ALL_6_DIRECTIONS:
		var nb = pos + dir
		var nb_type = chunk_manager.get_voxel(nb.x, nb.y, nb.z)
		if VoxelTypes.is_fluid(nb_type):
			activate_fluid(nb, initial_wake_delay, 1)

	# 3. 结构力学连通分量承重分析（浮空悬崖/被截断桥梁转化为 3D 刚体碎片崩塌）
	if enable_structural_integrity:
		check_structural_integrity(pos)


## 爆炸结束后的集中批量物理感知（仅对外围一圈受影响方块做一次唤醒与连通性检测，单次 < 0.2ms，杜绝卡顿）
func notify_explosion_finished(removed_positions: Array[Vector3i]) -> void:
	if chunk_manager == null or removed_positions.is_empty():
		return

	var removed_set: Dictionary = {}
	for pos in removed_positions:
		removed_set[pos] = true

	var boundary_neighbors: Dictionary = {}
	for pos in removed_positions:
		# 唤醒上方悬空的重力方块
		var above = pos + Vector3i(0, 1, 0)
		if not removed_set.has(above):
			activate_voxel(above, 0.05)
		
		# 收集坑洞周围的外部实体邻居
		for dir in ALL_6_DIRECTIONS:
			var nb = pos + dir
			if not removed_set.has(nb):
				boundary_neighbors[nb] = true

	# 对外围邻居执行流体流动唤醒与结构连通性检测
	for nb in boundary_neighbors.keys():
		var v_type = chunk_manager.get_voxel(nb.x, nb.y, nb.z)
		if VoxelTypes.is_fluid(v_type):
			activate_fluid(nb, 0.05, 1)

	# 对外围邻居执行结构连通性检测（仅检测下方没有实体支撑的潜在悬空方块）
	if enable_structural_integrity and not boundary_neighbors.is_empty():
		var global_visited: Dictionary = {}
		for nb in boundary_neighbors.keys():
			# 如果该方块下方就是实体方块，直接属于地面，跳过！
			var below_v = chunk_manager.get_voxel(nb.x, nb.y - 1, nb.z)
			if VoxelTypes.is_solid(below_v) and not VoxelTypes.has_gravity(below_v) and not VoxelTypes.is_fluid(below_v):
				continue
			if global_visited.has(nb):
				continue
			var v = chunk_manager.get_voxel(nb.x, nb.y, nb.z)
			if VoxelTypes.is_solid(v) and not VoxelTypes.has_gravity(v) and not VoxelTypes.is_fluid(v):
				_check_single_component_integrity(nb, global_visited)



## 放置方块时的物理感知
func notify_voxel_placed(pos: Vector3i, type: int) -> void:
	if _is_internal_op or chunk_manager == null:
		return

	if VoxelTypes.has_gravity(type):
		active_falling_voxels[pos] = {
			"type": type,
			"timer": initial_wake_delay
		}
	elif VoxelTypes.is_fluid(type):
		active_fluids[pos] = {
			"type": type,
			"timer": initial_wake_delay,
			"energy": 1,
			"from_dir": Vector3i.ZERO
		}

	# 仅唤醒上方或侧向受重力影响的流体
	for dir in ALL_6_DIRECTIONS:
		var nb = pos + dir
		var nb_type = chunk_manager.get_voxel(nb.x, nb.y, nb.z)
		if VoxelTypes.is_fluid(nb_type):
			activate_fluid(nb, initial_wake_delay, 1)


# -----------------------------------------------------------------------------
# 物理主循环 (Physics Tick)
# -----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if chunk_manager == null:
		return
	if active_falling_voxels.is_empty() and active_fluids.is_empty():
		return

	var steps_count = 0

	# 1. 模拟重力落沙与 45° 滑坡
	if not active_falling_voxels.is_empty():
		steps_count = _process_falling_sand(delta, steps_count)

	# 2. 模拟水体流体元胞自动机
	if not active_fluids.is_empty():
		_process_fluids(delta, steps_count)


# -----------------------------------------------------------------------------
# 体系 1：重力落沙与斜坡滑移 (Falling Sand & Angle of Repose)
# -----------------------------------------------------------------------------

func _process_falling_sand(delta: float, current_steps: int) -> int:
	var positions: Array = active_falling_voxels.keys()
	# 按 Y 坐标由小到大排序（最下方的沙子先移动，避免同列方块挤压互撞）
	positions.sort_custom(func(a: Vector3i, b: Vector3i): return a.y < b.y)

	var next_active: Dictionary = {}
	var steps = current_steps

	for pos in positions:
		if not active_falling_voxels.has(pos):
			continue

		var data = active_falling_voxels[pos]
		var v_type = data["type"]
		var timer = data["timer"] - delta

		if chunk_manager.get_voxel(pos.x, pos.y, pos.z) != v_type or pos.y <= 0:
			continue

		if timer > 0.0:
			data["timer"] = timer
			next_active[pos] = data
			continue

		if steps >= max_active_steps_per_frame:
			data["timer"] = 0.0
			next_active[pos] = data
			continue

		var below_pos = pos + Vector3i(0, -1, 0)
		var below_voxel = chunk_manager.get_voxel(below_pos.x, below_pos.y, below_pos.z)

		# 垂直落体：转化为具有平滑连续重力加速度的物理落体实体 (FallingBlockEntity)
		if below_voxel == VoxelTypes.Type.AIR:
			_is_internal_op = true
			chunk_manager.remove_voxel(pos)
			_is_internal_op = false
			
			var falling_block = FallingBlockEntity.new()
			var scene_root = chunk_manager.get_parent() if chunk_manager.get_parent() != null else chunk_manager
			scene_root.add_child(falling_block)
			falling_block.setup(v_type, Vector3(pos), Vector3(0, -1.8, 0), chunk_manager)
			
			activate_voxel(pos + Vector3i(0, 1, 0), 0.04)
			steps += 1
			continue
		elif VoxelTypes.is_fluid(below_voxel):
			move_voxel_swap(pos, below_pos, v_type, below_voxel)
			activate_fluid(pos, initial_wake_delay, 3) # 被推上去的水开始流动
			next_active[below_pos] = {"type": v_type, "timer": vertical_fall_delay * 1.5}
			activate_voxel(pos + Vector3i(0, 1, 0), vertical_fall_delay * 0.8)
			steps += 1
			continue

		# 45° 自然休止角侧向滑坡
		var slid: bool = false
		var shuffled_dirs = HORIZONTAL_DIRECTIONS.duplicate()
		shuffled_dirs.shuffle()

		for dir in shuffled_dirs:
			var side_pos = pos + dir
			var diag_pos = pos + dir + Vector3i(0, -1, 0)

			var side_v = chunk_manager.get_voxel(side_pos.x, side_pos.y, side_pos.z)
			var diag_v = chunk_manager.get_voxel(diag_pos.x, diag_pos.y, diag_pos.z)

			if (side_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(side_v)) and \
			   (diag_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(diag_v)):
				if VoxelTypes.is_fluid(diag_v):
					move_voxel_swap(pos, diag_pos, v_type, diag_v)
					activate_fluid(pos, initial_wake_delay, 3)
					next_active[diag_pos] = {"type": v_type, "timer": slope_slide_delay}
					activate_voxel(pos + Vector3i(0, 1, 0), slope_slide_delay * 0.8)
				else:
					_is_internal_op = true
					chunk_manager.remove_voxel(pos)
					_is_internal_op = false
					
					var falling_block = FallingBlockEntity.new()
					var scene_root = chunk_manager.get_parent() if chunk_manager.get_parent() != null else chunk_manager
					scene_root.add_child(falling_block)
					var slide_vel = Vector3(float(dir.x) * 2.8, -1.0, float(dir.z) * 2.8)
					falling_block.setup(v_type, Vector3(pos), slide_vel, chunk_manager)
					
					activate_voxel(pos + Vector3i(0, 1, 0), 0.04)
				slid = true
				steps += 1
				break

	active_falling_voxels = next_active
	return steps


# -----------------------------------------------------------------------------
# 体系 2：水体流体元胞自动机 (Water Fluid Cellular Automata - Optimized)
# -----------------------------------------------------------------------------

func _process_fluids(delta: float, current_steps: int) -> int:
	var positions: Array = active_fluids.keys()
	# 底层水先流动，避免悬空水流断裂
	positions.sort_custom(func(a: Vector3i, b: Vector3i): return a.y < b.y)

	var next_fluids: Dictionary = {}
	var steps = current_steps

	for pos in positions:
		if not active_fluids.has(pos):
			continue

		var data = active_fluids[pos]
		var v_type = data["type"]
		var timer = data["timer"] - delta
		var energy: int = data.get("energy", 3)
		var from_dir: Vector3i = data.get("from_dir", Vector3i.ZERO)

		if chunk_manager.get_voxel(pos.x, pos.y, pos.z) != v_type or pos.y <= 0:
			continue

		if timer > 0.0:
			data["timer"] = timer
			next_fluids[pos] = data
			continue

		if steps >= max_active_steps_per_frame:
			data["timer"] = 0.0
			next_fluids[pos] = data
			continue

		var below_pos = pos + Vector3i(0, -1, 0)
		var below_voxel = chunk_manager.get_voxel(below_pos.x, below_pos.y, below_pos.z)

		# 1. 垂直跌落 (Gravity Waterfall)
		if below_voxel == VoxelTypes.Type.AIR:
			move_voxel(pos, below_pos, v_type)
			next_fluids[below_pos] = {
				"type": v_type,
				"timer": fluid_fall_delay,
				"energy": 1,
				"from_dir": Vector3i.DOWN
			}
			# 仅当正上方确实是水体时才唤醒形成水柱
			var above_pos = pos + Vector3i(0, 1, 0)
			if chunk_manager.get_voxel(above_pos.x, above_pos.y, above_pos.z) == v_type:
				activate_fluid(above_pos, fluid_fall_delay * 0.8, 1)
			# 仅唤醒周围切实存在的水体方块涌向缺口
			for dir in HORIZONTAL_DIRECTIONS:
				var side = pos + dir
				if chunk_manager.get_voxel(side.x, side.y, side.z) == v_type:
					activate_fluid(side, fluid_fall_delay, 1)
			steps += 1
			continue

		# 2. 检查 4 个水平方向的悬崖边缘与平坦扩散空间
		var drop_dirs: Array[Vector3i] = []
		var flat_dirs: Array[Vector3i] = []

		for dir in HORIZONTAL_DIRECTIONS:
			# 防止反向震荡互挤
			if dir == -from_dir and from_dir != Vector3i.ZERO:
				continue
			var side_pos = pos + dir
			var side_v = chunk_manager.get_voxel(side_pos.x, side_pos.y, side_pos.z)
			if side_v == VoxelTypes.Type.AIR:
				var side_below = side_pos + Vector3i(0, -1, 0)
				var side_below_v = chunk_manager.get_voxel(side_below.x, side_below.y, side_below.z)
				if side_below_v == VoxelTypes.Type.AIR:
					drop_dirs.append(dir)
				else:
					flat_dirs.append(dir)

		# 优先级 A：向悬崖/深坑跌落边缘奔流（瀑布倾泻）
		if not drop_dirs.is_empty():
			drop_dirs.shuffle()
			var target_pos = pos + drop_dirs[0]
			move_voxel(pos, target_pos, v_type)
			next_fluids[target_pos] = {
				"type": v_type,
				"timer": fluid_fall_delay,
				"energy": 1,
				"from_dir": drop_dirs[0]
			}
			var above_pos = pos + Vector3i(0, 1, 0)
			if chunk_manager.get_voxel(above_pos.x, above_pos.y, above_pos.z) == v_type:
				activate_fluid(above_pos, fluid_fall_delay * 0.8, 1)
			for dir in HORIZONTAL_DIRECTIONS:
				var side = pos + dir
				if chunk_manager.get_voxel(side.x, side.y, side.z) == v_type:
					activate_fluid(side, fluid_flow_delay, 1)
			steps += 1
			continue

		# 优先级 B：平地向外舒缓扩散填平洼地（受水压或残余动能驱动，耗尽后稳定沉睡）
		var has_water_pressure = (chunk_manager.get_voxel(pos.x, pos.y + 1, pos.z) == v_type)
		if (has_water_pressure or energy > 0) and not flat_dirs.is_empty():
			flat_dirs.shuffle()
			var chosen_dir = flat_dirs[0]
			var target_pos = pos + chosen_dir
			move_voxel(pos, target_pos, v_type)
			var new_energy = 1 if has_water_pressure else (energy - 1)
			next_fluids[target_pos] = {
				"type": v_type,
				"timer": fluid_flow_delay,
				"energy": new_energy,
				"from_dir": chosen_dir
			}
			if has_water_pressure:
				activate_fluid(pos + Vector3i(0, 1, 0), fluid_fall_delay, 1)
			steps += 1
			continue

		# 3. 既无法跌落也无水压且动能耗尽，水体填平沉淀，进入沉睡状态 (Settled)
		# 不再加入 next_fluids，活跃流体数量归零，CPU 消耗归零！

	active_fluids = next_fluids
	return steps


# -----------------------------------------------------------------------------
# 体系 3：连通分量承重分析与原生 3D 刚体碎片崩塌 (Structural Integrity & Debris)
# -----------------------------------------------------------------------------

func check_structural_integrity(removed_pos: Vector3i) -> void:
	var global_visited: Dictionary = {}

	for dir in ALL_6_DIRECTIONS:
		var start_pos = removed_pos + dir
		if global_visited.has(start_pos):
			continue
		if start_pos.y <= ground_anchor_y or start_pos.y >= chunk_manager.max_height:
			continue

		var v_type = chunk_manager.get_voxel(start_pos.x, start_pos.y, start_pos.z)
		# 仅对非受重力、非流体的固态结构方块（石头、木头、泥土、砖石等）进行承重连通性分析
		if not VoxelTypes.is_solid(v_type) or VoxelTypes.has_gravity(v_type) or VoxelTypes.is_fluid(v_type):
			continue

		_check_single_component_integrity(start_pos, global_visited)


func _check_single_component_integrity(start_pos: Vector3i, global_visited: Dictionary) -> void:
	if global_visited.has(start_pos) or start_pos.y <= ground_anchor_y:
		return

	# 执行 BFS 连通性分析
	var component_voxels: Array[Vector3i] = []
	var component_types: Array[int] = []
	var queue: Array[Vector3i] = [start_pos]
	var visited: Dictionary = {start_pos: true}
	var is_anchored: bool = false

	while not queue.is_empty():
		var curr = queue.pop_front()
		component_voxels.append(curr)
		component_types.append(chunk_manager.get_voxel(curr.x, curr.y, curr.z))
		global_visited[curr] = true

		# 终止条件 1：触及基岩或地基高度，结构坚固扎根于大地
		if curr.y <= ground_anchor_y:
			is_anchored = true
			break

		# 终止条件 2：如果当前方块下方是实体支撑（非重力非流体），直接认定接地稳定！
		var below_v = chunk_manager.get_voxel(curr.x, curr.y - 1, curr.z)
		if VoxelTypes.is_solid(below_v) and not VoxelTypes.has_gravity(below_v) and not VoxelTypes.is_fluid(below_v):
			is_anchored = true
			break

		# 终止条件 3：体素量超过孤岛上限，说明是连绵大陆/大山的一部分，结构稳定
		if component_voxels.size() > max_debris_size:
			is_anchored = true
			break

		for n_dir in ALL_6_DIRECTIONS:
			var n_pos = curr + n_dir
			if visited.has(n_pos):
				continue
			if n_pos.y < 0 or n_pos.y >= chunk_manager.max_height:
				continue
			var n_type = chunk_manager.get_voxel(n_pos.x, n_pos.y, n_pos.z)
			if VoxelTypes.is_solid(n_type) and not VoxelTypes.has_gravity(n_type) and not VoxelTypes.is_fluid(n_type):
				visited[n_pos] = true
				queue.append(n_pos)

	# 如果连通组件穷尽后未触及地基，且体积在 max_debris_size 以内：
	# 说明这是一块完全悬空的断裂孤岛/建筑悬挑，整体崩塌转化为 3D 刚体碎片！
	if not is_anchored and component_voxels.size() <= max_debris_size and not component_voxels.is_empty():
		spawn_debris_entity(component_voxels, component_types)


func spawn_debris_entity(voxels: Array[Vector3i], types: Array[int]) -> void:
	if voxels.is_empty() or chunk_manager == null:
		return

	# 1. 计算离散结构的物理质心
	var sum_pos = Vector3.ZERO
	for p in voxels:
		sum_pos += Vector3(p.x + 0.5, p.y + 0.5, p.z + 0.5)
	var center_of_mass = sum_pos / float(voxels.size())

	# 2. 从静态体素世界中抹除（内部原子操作，杜绝递归循环）
	_is_internal_op = true
	for p in voxels:
		chunk_manager.remove_voxel(p)
	_is_internal_op = false

	# 3. 实例化 Caelix 风格 6-DOF 动体体素实体 (VoxelEntity)
	var entity = VoxelEntity.new()
	entity.name = "VoxelEntity_%d" % Time.get_ticks_msec()
	var scene_root = chunk_manager.get_parent() if chunk_manager.get_parent() != null else chunk_manager
	scene_root.add_child(entity)

	var init_vel = Vector3(
		randf_range(-0.4, 0.4),
		randf_range(-0.1, 0.1),
		randf_range(-0.4, 0.4)
	)
	var init_ang_vel = Vector3(
		randf_range(-1.2, 1.2),
		randf_range(-1.2, 1.2),
		randf_range(-1.2, 1.2)
	)
	entity.setup(voxels, types, center_of_mass, init_vel, init_ang_vel, chunk_manager)


# -----------------------------------------------------------------------------
# 底层体素位置变更辅助接口
# -----------------------------------------------------------------------------

func move_voxel(from_pos: Vector3i, to_pos: Vector3i, v_type: int) -> void:
	_is_internal_op = true
	chunk_manager.remove_voxel(from_pos)
	chunk_manager.add_voxel(to_pos, v_type)
	_is_internal_op = false


func move_voxel_swap(from_pos: Vector3i, to_pos: Vector3i, falling_type: int, fluid_type: int) -> void:
	_is_internal_op = true
	chunk_manager.add_voxel(to_pos, falling_type)
	chunk_manager.add_voxel(from_pos, fluid_type)
	_is_internal_op = false
