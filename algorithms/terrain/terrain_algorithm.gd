@abstract
class_name TerrainAlgorithm extends Resource

@export var max_height: int
@export var noise: TerrainNoise

@abstract func generate_data(position: Vector3, biome_noise: Noise, chunk_data) -> void
