@abstract
class_name TerrainAlgorithm extends Resource

enum Voxel {
	SAND = 0,
	GRASS = 1,
	MOUNTAIN = 2,
	SNOW = 3,
	AIR = 4,
	DIRT = 5,
	WOOD = 6,
	LEAVES = 7,
	WATER = 8,
	GRAVEL = 9,
	GLASS = 10,
	GLOWSTONE = 11
}

@export var max_height: int
@export var noise: TerrainNoise

@abstract func generate_data(position: Vector3, biome_noise: Noise, chunk_data) -> void
