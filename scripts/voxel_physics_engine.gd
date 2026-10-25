class_name VoxelPhysicsEngine extends Node

## Caelix 风格的稀疏动态体素物理引擎 (VoxelPhysicsEngine)
## 采用每方块独立计时器与自然阻尼，实现柔和舒缓的落沙重力、45°自然休止角滑坡与连锁坍塌
## 无活跃动态体素时 CPU 耗时为严格的 0.00ms

@export_group("Falling Sand Timings")
@export var vertical_fall_delay: float = 0.10 # 垂直自由下落间隔（秒/格，0.10s 即 10格/秒，舒缓自然）
@export var slope_slide_delay: float = 0.18   # 45° 斜坡侧滑间隔（秒/格，具有真实地面摩擦阻力感）
@export var initial_wake_delay: float = 0.06  # 挖掘悬空后的启动停滞延时（产生逐级连锁雪崩波纹）
@export var max_active_steps_per_frame: int = 48 # 单帧物理步进上限保护

var chunk_manager: ChunkManager = null

# Vector3i -> Dictionary { "type": int, "timer": float }
var active_falling_voxels: Dictionary = {}

const HORIZONTAL_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]


func _ready() -> void:
	if get_parent() is ChunkManager:
		chunk_manager = get_parent() as ChunkManager


## 唤醒指定坐标的体重体素参与物理模拟
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


## 挖掘/破坏方块时的连锁物理波纹传递
func notify_voxel_removed(pos: Vector3i) -> void:
	# 唤醒正上方的受重力方块
	activate_voxel(pos + Vector3i(0, 1, 0), initial_wake_delay)

	# 唤醒 4 个斜上方可能失去侧向支撑的重力方块（陡坡坍塌）
	for dir in HORIZONTAL_DIRECTIONS:
		activate_voxel(pos + dir + Vector3i(0, 1, 0), initial_wake_delay * 1.5)


## 放置方块时的物理感知
func notify_voxel_placed(pos: Vector3i, type: int) -> void:
	if VoxelTypes.has_gravity(type):
		active_falling_voxels[pos] = {
			"type": type,
			"timer": initial_wake_delay
		}


func _physics_process(delta: float) -> void:
	if active_falling_voxels.is_empty() or chunk_manager == null:
		return

	# 按 Y 坐标由小到大排序（最下方的沙子先移动，避免同一垂直列方块互撞）
	var positions: Array = active_falling_voxels.keys()
	positions.sort_custom(func(a: Vector3i, b: Vector3i): return a.y < b.y)

	var next_active: Dictionary = {}
	var steps_count = 0

	for pos in positions:
		if not active_falling_voxels.has(pos):
			continue

		var data = active_falling_voxels[pos]
		var v_type = data["type"]
		var timer = data["timer"] - delta

		# 验证当前位置是否仍然是该重力方块
		if chunk_manager.get_voxel(pos.x, pos.y, pos.z) != v_type:
			continue

		# 世界底边界保护
		if pos.y <= 0:
			continue

		# 倒计时未结束，保留并等待下一帧
		if timer > 0.0:
			data["timer"] = timer
			next_active[pos] = data
			continue

		# 单帧步数保护
		if steps_count >= max_active_steps_per_frame:
			data["timer"] = 0.0
			next_active[pos] = data
			continue

		var below_pos = pos + Vector3i(0, -1, 0)
		var below_voxel = chunk_manager.get_voxel(below_pos.x, below_pos.y, below_pos.z)

		# 1. 垂直自由下落（正下方为空气或流体）
		if below_voxel == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(below_voxel):
			move_voxel(pos, below_pos, v_type)
			next_active[below_pos] = {
				"type": v_type,
				"timer": vertical_fall_delay
			}
			# 传递唤醒正上方可能悬空的方块
			activate_voxel(pos + Vector3i(0, 1, 0), vertical_fall_delay * 0.8)
			steps_count += 1
			continue

		# 2. 自然休止角滑坡 (45° Diagonal Slide)
		# 正下方受阻，检查 4 个水平对角斜坡
		var slid: bool = false
		var shuffled_dirs = HORIZONTAL_DIRECTIONS.duplicate()
		shuffled_dirs.shuffle()

		for dir in shuffled_dirs:
			var side_pos = pos + dir
			var diag_pos = pos + dir + Vector3i(0, -1, 0)

			var side_v = chunk_manager.get_voxel(side_pos.x, side_pos.y, side_pos.z)
			var diag_v = chunk_manager.get_voxel(diag_pos.x, diag_pos.y, diag_pos.z)

			# 斜向滑坡条件：侧面为空 且 斜下方为空（防止穿透邻近实体墙壁）
			if (side_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(side_v)) and \
			   (diag_v == VoxelTypes.Type.AIR or VoxelTypes.is_fluid(diag_v)):
				move_voxel(pos, diag_pos, v_type)
				next_active[diag_pos] = {
					"type": v_type,
					"timer": slope_slide_delay
				}
				activate_voxel(pos + Vector3i(0, 1, 0), slope_slide_delay * 0.8)
				slid = true
				steps_count += 1
				break

		# 3. 既无法垂直下落也无法滑坡，沙块稳定落定（Settled），移出活跃队列
		if not slid:
			pass

	active_falling_voxels = next_active


func move_voxel(from_pos: Vector3i, to_pos: Vector3i, v_type: int) -> void:
	chunk_manager.remove_voxel(from_pos)
	chunk_manager.add_voxel(to_pos, v_type)
