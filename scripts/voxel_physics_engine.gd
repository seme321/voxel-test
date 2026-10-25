class_name VoxelPhysicsEngine extends Node

## Caelix 风格的稀疏动态体素物理引擎 (VoxelPhysicsEngine)
## 采用高效稀疏活跃队列 (Sparse Active Queue)，实现落沙重力、45°自然休止角滑坡与坍塌传递
## 无活跃动态体素时开销为 0ms，发生挖掘/落沙时以微秒级步进物理模拟

@export var tick_rate: float = 20.0 # 物理模拟刷新率 (TPS，默认 20Hz 自然落速)
@export var max_active_steps_per_tick: int = 128 # 单帧物理上限保护

var chunk_manager: ChunkManager = null
var active_falling_voxels: Dictionary = {} # Vector3i -> VoxelType (活跃下落体素)
var time_acc: float = 0.0

const HORIZONTAL_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]


func _ready() -> void:
	if get_parent() is ChunkManager:
		chunk_manager = get_parent() as ChunkManager


## 唤醒指定坐标的体素参与重力物理模拟
func activate_voxel(pos: Vector3i) -> void:
	if chunk_manager == null:
		return
	var v_type = chunk_manager.get_voxel(pos.x, pos.y, pos.z)
	if VoxelTypes.has_gravity(v_type):
		active_falling_voxels[pos] = v_type


## 挖掘/移除方块时的物理感知传递（Caelix Dirty Propagation）
func notify_voxel_removed(pos: Vector3i) -> void:
	# 1. 唤醒正上方的受重力方块
	activate_voxel(pos + Vector3i(0, 1, 0))

	# 2. 唤醒斜上方的受重力方块（陡坡坍塌）
	for dir in HORIZONTAL_DIRECTIONS:
		activate_voxel(pos + dir + Vector3i(0, 1, 0))


## 放置方块时的物理感知
func notify_voxel_placed(pos: Vector3i, type: int) -> void:
	if VoxelTypes.has_gravity(type):
		active_falling_voxels[pos] = type


func _physics_process(delta: float) -> void:
	if active_falling_voxels.is_empty() or chunk_manager == null:
		return

	time_acc += delta
	var step_interval = 1.0 / tick_rate
	while time_acc >= step_interval:
		time_acc -= step_interval
		step_simulation()


## 单步物理模拟：由下至上计算下落与 45° 侧滑
func step_simulation() -> void:
	if active_falling_voxels.is_empty():
		return

	# 按 Y 坐标由小到大排序（最底部的沙子先下落，避免同一垂直列方块互撞）
	var positions: Array = active_falling_voxels.keys()
	positions.sort_custom(func(a: Vector3i, b: Vector3i): return a.y < b.y)

	var next_active: Dictionary = {}
	var steps_count = 0

	for pos in positions:
		if steps_count >= max_active_steps_per_tick:
			next_active[pos] = active_falling_voxels[pos]
			continue

		var v_type = chunk_manager.get_voxel(pos.x, pos.y, pos.z)
		# 若原位置已不是重力体素，直接移出队列
		if not VoxelTypes.has_gravity(v_type):
			continue

		var below_pos = pos + Vector3i(0, -1, 0)
		var below_voxel = chunk_manager.get_voxel(below_pos.x, below_pos.y, below_pos.z)

		# 1. 垂直下落（正下方为空气或液体）
		if below_voxel == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(below_voxel):
			move_voxel(pos, below_pos, v_type)
			next_active[below_pos] = v_type
			# 唤醒正上方可能悬空的方块
			activate_voxel(pos + Vector3i(0, 1, 0))
			steps_count += 1
			continue

		# 2. 自然休止角滑坡 (45° Diagonal Slide)
		# 正下方受阻，检查 4 个水平对角斜坡
		var slid: bool = false
		# 随机打乱方向避免特定朝向堆叠偏斜
		var shuffled_dirs = HORIZONTAL_DIRECTIONS.duplicate()
		shuffled_dirs.shuffle()

		for dir in shuffled_dirs:
			var side_pos = pos + dir
			var diag_pos = pos + dir + Vector3i(0, -1, 0)

			var side_v = chunk_manager.get_voxel(side_pos.x, side_pos.y, side_pos.z)
			var diag_v = chunk_manager.get_voxel(diag_pos.x, diag_pos.y, diag_pos.z)

			# 斜向滑坡条件：侧面为空 且 斜下方为空（防止穿墙）
			if (side_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(side_v)) and \
			   (diag_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(diag_v)):
				move_voxel(pos, diag_pos, v_type)
				next_active[diag_pos] = v_type
				activate_voxel(pos + Vector3i(0, 1, 0))
				slid = true
				steps_count += 1
				break

		# 3. 既无法下落也无法滑坡，沙子静止落定，移出活跃队列
		if not slid:
			pass

	active_falling_voxels = next_active


func move_voxel(from_pos: Vector3i, to_pos: Vector3i, v_type: int) -> void:
	chunk_manager.remove_voxel(from_pos)
	chunk_manager.add_voxel(to_pos, v_type)
