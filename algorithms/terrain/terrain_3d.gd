class_name Terrain3D extends TerrainAlgorithm


func _init() -> void:
	
	if noise == null:
		noise = Noise3D.new()


func generate_data(position: Vector3, biome_noise: Noise, chunk_data) -> void:
	var safe_max_height: float = float(max_height if max_height > 0 else 128)
	var is_noise_3d = noise is Noise3D
	var fast_noise: FastNoiseLite = noise.noise if (noise and "noise" in noise) else null
	var noise_weight: float = noise.noise_weight if is_noise_3d else 0.8
	var surface_threshold: float = noise.surface_threshold if is_noise_3d else 0.0

	# 核心优化：直接调用 C# Caelix 引擎的双层 Brick 剪枝生成（全速 JIT 编译，耗时仅 ~3ms）
	if fast_noise != null and biome_noise is FastNoiseLite:
		chunk_data.GenerateTerrainCaelix(
			position,
			fast_noise,
			biome_noise as FastNoiseLite,
			noise_weight,
			surface_threshold,
			int(safe_max_height)
		)
		return

	# 常规逐点回退路径
	var chunk_size: int = chunk_data.size
	var inv_max_height: float = 1.0 / safe_max_height

	for x in range(chunk_size):
		var gx: float = position.x + x
		for z in range(chunk_size):
			var gz: float = position.z + z
			
			var biome_n: float = 0.5
			if biome_noise != null:
				biome_n = ((biome_noise.get_noise_2d(gx, gz) + 0.5 * biome_noise.get_noise_2d(2.0 * gx, 2.0 * gz) + 0.25 * biome_noise.get_noise_2d(4.0 * gx, 4.0 * gz)) / 1.75 + 1.0) * 0.5
			
			var base_biome = VoxelTypes.Type.GRASS if biome_n > 0.55 else VoxelTypes.Type.SAND
			var is_snow_candidate = biome_n > 0.5
			
			for y in range(chunk_size):
				var gy: float = position.y + y
				var has_voxel: bool = false
				
				if is_noise_3d and fast_noise != null:
					if gy <= 0.0:
						has_voxel = true
					elif gy >= safe_max_height:
						has_voxel = false
					else:
						var gradient: float = 1.0 - (gy * inv_max_height) * 2.0
						var n: float = fast_noise.get_noise_3d(gx, gy, gz)
						has_voxel = (gradient + n * noise_weight) > surface_threshold
				else:
					has_voxel = noise.has_voxel(Vector3(gx, gy, gz), int(safe_max_height))
				
				if not has_voxel:
					continue
				
				var height_factor: float = gy * inv_max_height
				var biome = base_biome
				if height_factor >= 0.22:
					biome = VoxelTypes.Type.STONE
					if is_snow_candidate and height_factor > 0.4:
						biome = VoxelTypes.Type.SNOW
				
				chunk_data.AddVoxel(x, y, z, biome)
