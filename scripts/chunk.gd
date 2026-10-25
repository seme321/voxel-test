class_name Chunk extends Node3D

const SUB_CHUNK_SIZE: int = 32

@export var mat: Material
@export var biome_noise: Noise = FastNoiseLite.new()

var meshing_algorithm: MeshingAlgorithm
var chunk_data: ChunkData = ChunkData.new()

# sub_coord Vector3i -> StaticBody3D
var sub_chunks: Dictionary = {}

# 在后台线程准备完毕的网格与物理数据字典
# sub_coord -> { "mesh": ArrayMesh, "shape": Shape3D, "origin": Vector3i }
var prepared_sub_chunks: Dictionary = {}


func _ready() -> void:
	pass


func generate_data(terrain_algorithm: TerrainAlgorithm) -> void:
	terrain_algorithm.generate_data(position, biome_noise, chunk_data)


## 在后台工作线程执行：计算所有子区块的贪心网格并构建物理碰撞体
func prepare_sub_chunks_background() -> void:
	prepared_sub_chunks.clear()
	if chunk_data.IsEmpty():
		return

	var size = chunk_data.GetSize()
	var num_sub = size / SUB_CHUNK_SIZE

	for sz in range(num_sub):
		for sy in range(num_sub):
			for sx in range(num_sub):
				var sub_coord = Vector3i(sx, sy, sz)
				var sub_origin = sub_coord * SUB_CHUNK_SIZE

				# 粗粒度快速测试：全空子区块 0 耗时跳过
				if chunk_data.IsSubChunkEmpty(sub_origin, SUB_CHUNK_SIZE):
					continue

				var sub_mesh_data = MeshData.new()
				meshing_algorithm.GenerateSubMesh(chunk_data, sub_origin, SUB_CHUNK_SIZE, sub_mesh_data)
				if sub_mesh_data.IsEmpty():
					continue

				sub_mesh_data.Commit()
				var arr_mesh = ArrayMesh.new()
				arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub_mesh_data.GetSurfaceArray())
				if mat != null:
					arr_mesh.surface_set_material(0, mat)

				var shape = arr_mesh.create_trimesh_shape()

				prepared_sub_chunks[sub_coord] = {
					"mesh": arr_mesh,
					"shape": shape,
					"origin": sub_origin
				}


## 在主线程执行：挂载已在后台准备好的子区块节点（< 1ms）
func apply_prepared_sub_chunks() -> void:
	clear_sub_chunks()
	for sub_coord in prepared_sub_chunks.keys():
		var data = prepared_sub_chunks[sub_coord]
		var sub_body = StaticBody3D.new()
		sub_body.name = "Sub_%d_%d_%d" % [sub_coord.x, sub_coord.y, sub_coord.z]
		sub_body.position = Vector3(data["origin"])

		var mesh_inst = MeshInstance3D.new()
		mesh_inst.mesh = data["mesh"]
		sub_body.add_child(mesh_inst)

		var col_shape = CollisionShape3D.new()
		col_shape.shape = data["shape"]
		sub_body.add_child(col_shape)

		add_child(sub_body)
		sub_chunks[sub_coord] = sub_body

	prepared_sub_chunks.clear()


## 同步创建完整区块（出生点即时同步或回退）
func create_mesh() -> void:
	prepare_sub_chunks_background()
	apply_prepared_sub_chunks()


## 单个子区块的高速即时重构（方块挖掘/放置时触发，耗时 ~0.5ms）
func remesh_sub_chunk(sub_coord: Vector3i) -> void:
	if sub_chunks.has(sub_coord):
		var old_body = sub_chunks[sub_coord]
		if is_instance_valid(old_body):
			old_body.queue_free()
		sub_chunks.erase(sub_coord)

	var sub_origin = sub_coord * SUB_CHUNK_SIZE
	if chunk_data.IsSubChunkEmpty(sub_origin, SUB_CHUNK_SIZE):
		return

	var sub_mesh_data = MeshData.new()
	meshing_algorithm.GenerateSubMesh(chunk_data, sub_origin, SUB_CHUNK_SIZE, sub_mesh_data)
	if sub_mesh_data.IsEmpty():
		return

	sub_mesh_data.Commit()
	var arr_mesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub_mesh_data.GetSurfaceArray())
	if mat != null:
		arr_mesh.surface_set_material(0, mat)

	var sub_body = StaticBody3D.new()
	sub_body.name = "Sub_%d_%d_%d" % [sub_coord.x, sub_coord.y, sub_coord.z]
	sub_body.position = Vector3(sub_origin)

	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	sub_body.add_child(mesh_inst)

	var col_shape = CollisionShape3D.new()
	col_shape.shape = arr_mesh.create_trimesh_shape()
	sub_body.add_child(col_shape)

	add_child(sub_body)
	sub_chunks[sub_coord] = sub_body


## 标记面对特定相邻 Sector 方向的 16 个边界子区块为脏
func mark_boundary_dirty(direction: int) -> void:
	chunk_data.MarkBoundaryDirty(direction)


## 消费 64-bit Dirty Flags，合批重构所有脏子区块（彻底合并多次修改）
func flush_dirty() -> void:
	var mask: int = chunk_data.PopDirtySubChunksMask()
	if mask == 0:
		return

	for sub_idx in range(64):
		if (mask & (1 << sub_idx)) != 0:
			var sx = sub_idx & 3
			var sy = (sub_idx >> 2) & 3
			var sz = (sub_idx >> 4) & 3
			remesh_sub_chunk(Vector3i(sx, sy, sz))


func remesh() -> void:
	create_mesh()


func remove_voxel(pos: Vector3i) -> void:
	chunk_data.RemoveVoxel(pos.x, pos.y, pos.z)
	flush_dirty()


func add_voxel(pos: Vector3i, voxel: int) -> void:
	chunk_data.AddVoxel(pos.x, pos.y, pos.z, voxel)
	flush_dirty()


func clear_sub_chunks() -> void:
	for sub_body in sub_chunks.values():
		if is_instance_valid(sub_body):
			sub_body.queue_free()
	sub_chunks.clear()
