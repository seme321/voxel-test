class_name Noise3D extends TerrainNoise

@export var frequency: float = 0.02:
	set(value):
		frequency = value
		if noise:
			noise.frequency = value

@export var noise_weight: float = 0.8
@export var surface_threshold: float = 0.0


func _init() -> void:
	name = "Noise3D"
	if not noise:
		noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5


func has_voxel(position: Vector3, max_height: int = 64) -> bool:
	# 底部 Y <= 0 保持实心，防止穿底
	if position.y <= 0:
		return true
	# 顶部超过 max_height 为纯空气
	if position.y >= max_height:
		return false

	# 高度渐变：从底部 y=0 (+1.0) 到顶部 y=max_height (-1.0)
	var height_ratio: float = float(position.y) / float(max_height)
	var gradient: float = 1.0 - height_ratio * 2.0

	# 3D 噪声采样 [-1.0, 1.0]
	var n: float = noise.get_noise_3d(position.x, position.y, position.z)

	# 密度判定：梯度主导宏观高度分布，3D 噪声雕刻出悬崖、起伏与悬空地形
	var density: float = gradient + n * noise_weight
	return density > surface_threshold
