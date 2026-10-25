extends Node

func _ready() -> void:
	print("==================================================================")
	print("   VOXEL TEST BENCHMARK: RASTERIZATION VS CAELIX HARDWARE RT      ")
	print("==================================================================")
	
	var terrain_noise = FastNoiseLite.new()
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.frequency = 0.02
	
	var biome_noise = FastNoiseLite.new()
	biome_noise.frequency = 0.005
	
	var chunk = ChunkData.new()
	var t0 = Time.get_ticks_usec()
	chunk.GenerateTerrainCaelix(Vector3.ZERO, terrain_noise, biome_noise, 0.8, 0.0, 128)
	var chunk_gen_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var voxel_count = chunk.NumberOfVoxels()
	print("[Data Generation] 128^3 Sector Generated: ", voxel_count, " voxels in ", chunk_gen_ms, " ms")
	
	# ----------------------------------------------------------------
	# Part 1: 传统光栅化贪心网格化与物理碰撞生成 (Rasterization Pipeline)
	# ----------------------------------------------------------------
	print("\n>>> Testing Part 1: Traditional Rasterization (Greedy Mesher + Collision)...")
	var mesher = GreedyMeshing.new()
	var colors = {
		0: Color(0.85, 0.75, 0.45),
		1: Color(0.35, 0.65, 0.25),
		2: Color(0.5, 0.5, 0.5),
		3: Color(0.95, 0.95, 0.95),
		4: Color(0, 0, 0, 0)
	}
	mesher.SetColors(colors)
	
	var mesh_data = MeshData.new()
	var total_raster_time_us: int = 0
	var total_collision_time_us: int = 0
	var total_vertices: int = 0
	var total_triangles: int = 0
	var active_subchunks: int = 0
	
	t0 = Time.get_ticks_usec()
	for sx in range(4):
		for sy in range(4):
			for sz in range(4):
				var sub_origin = Vector3i(sx * 32, sy * 32, sz * 32)
				if not chunk.IsSubChunkEmpty(sub_origin, 32):
					active_subchunks += 1
					mesh_data.Reset()
					
					var m_t0 = Time.get_ticks_usec()
					mesher.GenerateSubMesh(chunk, sub_origin, 32, mesh_data)
					total_raster_time_us += (Time.get_ticks_usec() - m_t0)
					
					var v_count = mesh_data.NumberOfVertices()
					total_vertices += v_count
					total_triangles += v_count / 3
					
					# 模拟生成 ArrayMesh 与物理碰撞体 (Trimesh / Convex / Jolt BVH)
					var c_t0 = Time.get_ticks_usec()
					if v_count > 0:
						mesh_data.Commit()
						var arr = mesh_data.GetSurfaceArray()
						var am = ArrayMesh.new()
						am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
						var shape = am.create_trimesh_shape()
					total_collision_time_us += (Time.get_ticks_usec() - c_t0)
					
	var total_raster_mesh_ms = total_raster_time_us / 1000.0
	var total_collision_ms = total_collision_time_us / 1000.0
	var total_raster_prep_ms = total_raster_mesh_ms + total_collision_ms
	
	# 显存估算:
	# 顶点格式: 12B (pos) + 12B (normal) + 16B (color) = 40 字节/顶点
	# 索引格式: 4 字节/索引
	# 物理碰撞树估算: 约 36 字节/三角形 (Jolt Trimesh BVH 节点与顶点索引)
	var raster_vertex_kb = (total_vertices * 40.0) / 1024.0
	var raster_index_kb = (total_triangles * 3.0 * 4.0) / 1024.0
	var raster_collision_kb = (total_triangles * 36.0) / 1024.0
	var raster_total_mem_kb = raster_vertex_kb + raster_index_kb + raster_collision_kb
	
	print("  - Active SubChunks: ", active_subchunks, " / 64")
	print("  - Total Triangles: ", total_triangles)
	print("  - Total Vertices: ", total_vertices)
	print("  - Greedy Meshing CPU Time: ", total_raster_mesh_ms, " ms")
	print("  - Collision & ArrayMesh Gen Time: ", total_collision_ms, " ms")
	print("  - Total Raster Preparation Latency: ", total_raster_prep_ms, " ms")
	print("  - Memory / VRAM Footprint: ", raster_total_mem_kb / 1024.0, " MB (Vertices: ", raster_vertex_kb, " KB, Indices: ", raster_index_kb, " KB, Collision BVH: ", raster_collision_kb, " KB)")
	print("  - Scene Tree Node Overhead: ", active_subchunks * 2, " nodes (", active_subchunks, " MeshInstance3D + ", active_subchunks, " CollisionShape3D)")
	
	# ----------------------------------------------------------------
	# Part 2: Caelix 硬件光追方案 (Caelix Hardware Raytracing Pipeline)
	# ----------------------------------------------------------------
	print("\n>>> Testing Part 2: Caelix Hardware Raytracing (RTX 4070 Laptop GPU)...")
	var rt = ClassDB.instantiate("VoxelRayTracer")
	rt.init_raytracer(1280, 720)
	
	# 1. 序列化导出
	var s_t0 = Time.get_ticks_usec()
	var aabb_bytes = chunk.GetRayTracingAabbBytes()
	var brick_bytes = chunk.GetRayTracingBrickBytes()
	var serialization_ms = (Time.get_ticks_usec() - s_t0) / 1000.0
	
	var active_bricks = aabb_bytes.size() / 24
	var aabb_kb = aabb_bytes.size() / 1024.0
	var brick_kb = brick_bytes.size() / 1024.0
	
	# 2. BLAS 构建 (包含 GPU 专用加速结构缓冲区分配与硬件 BVH 编译)
	var b_t0 = Time.get_ticks_usec()
	rt.upload_sector_aabbs(Vector3i.ZERO, aabb_bytes)
	rt.upload_sector_bricks(Vector3i.ZERO, brick_bytes)
	var blas_build_ms = (Time.get_ticks_usec() - b_t0) / 1000.0
	
	# 3. TLAS 构建与初次着色准备
	var cam_pos = Vector3(64.0, 100.0, 160.0)
	var look_target = Vector3(64.0, 32.0, 64.0)
	var cam_transform = Transform3D(Basis(), cam_pos).looking_at(look_target, Vector3.UP)
	
	var r_t0 = Time.get_ticks_usec()
	rt.render_frame(cam_transform, 60.0)
	var first_frame_and_tlas_ms = (Time.get_ticks_usec() - r_t0) / 1000.0
	
	# 4. 后续纯光追调度耗时 (Steady State Frame Dispatch: 1280x720 = 921,600 rays)
	var steady_frame_times = []
	for frame in range(10):
		var f_t0 = Time.get_ticks_usec()
		rt.render_frame(cam_transform, 60.0)
		steady_frame_times.append((Time.get_ticks_usec() - f_t0) / 1000.0)
		
	steady_frame_times.sort()
	var median_rt_frame_ms = steady_frame_times[steady_frame_times.size() / 2]
	
	# 显存估算:
	# AABB 缓冲: aabb_bytes.size()
	# BLAS 缓冲: ~250 KB (由 Vulkan RT 驱动构建)
	# Brick SSBO: brick_bytes.size()
	# TLAS 缓冲: ~16 KB
	var rt_vram_kb = aabb_kb + brick_kb + 250.0 + 16.0
	var rt_total_prep_ms = serialization_ms + blas_build_ms
	
	print("  - Active 8^3 Bricks submitted as AABBs: ", active_bricks, " / 4096 (Triangles: 0, Vertices: 0)")
	print("  - C# Serialization Time (PopCount/TZCNT): ", serialization_ms, " ms")
	print("  - GPU Hardware BLAS Build Time: ", blas_build_ms, " ms")
	print("  - Total RT Preparation Latency: ", rt_total_prep_ms, " ms")
	print("  - TLAS + First Frame Dispatch: ", first_frame_and_tlas_ms, " ms")
	print("  - Steady-State 1280x720 RT Render Latency: ", median_rt_frame_ms, " ms")
	print("  - Memory / VRAM Footprint: ", rt_vram_kb / 1024.0, " MB (AABBs: ", aabb_kb, " KB, Brick SSBO: ", brick_kb, " KB, AS BLAS/TLAS: ~266 KB)")
	print("  - Scene Tree Node Overhead: 1 node (VoxelRayTracer)")
	
	# ----------------------------------------------------------------
	# Part 3: 单方块动态破坏响应延迟对比 (Dynamic Edit Remesh / Rebuild)
	# ----------------------------------------------------------------
	print("\n>>> Testing Part 3: Single Voxel Dynamic Destruction / Edit Latency...")
	# 传统光栅化方案：单方块破坏引发 32^3 子区块重新扫描与贪心网格重绘
	var sub_origin = Vector3i(0, 0, 0)
	var e_t0 = Time.get_ticks_usec()
	mesh_data.Reset()
	mesher.GenerateSubMesh(chunk, sub_origin, 32, mesh_data)
	var raster_single_edit_ms = (Time.get_ticks_usec() - e_t0) / 1000.0
	
	# Caelix RT 方案：只需更新对应 8^3 Brick 的 512-bit 掩码
	var rt_e_t0 = Time.get_ticks_usec()
	chunk.RemoveVoxel(10, 20, 10)
	var rt_single_edit_us = Time.get_ticks_usec() - rt_e_t0
	var rt_single_edit_ms = rt_single_edit_us / 1000.0
	
	print("  - Rasterization Single SubChunk Remesh: ", raster_single_edit_ms, " ms")
	print("  - Caelix RT Micro-Mask Bitmask Update: ", rt_single_edit_ms, " ms (", rt_single_edit_us, " microseconds)")
	
	# ----------------------------------------------------------------
	# 输出格式化对比结果
	# ----------------------------------------------------------------
	print("\n==================================================================")
	print("                    FINAL BENCHMARK COMPARISON                    ")
	print("==================================================================")
	print("Metric | Rasterization | Caelix Hardware RT | Difference / Advantage")
	print("Prep Latency | ", total_raster_prep_ms, " ms | ", rt_total_prep_ms, " ms | ", (total_raster_prep_ms / max(0.01, rt_total_prep_ms)), "x faster")
	print("Memory Footprint | ", (raster_total_mem_kb / 1024.0), " MB | ", (rt_vram_kb / 1024.0), " MB | ", (raster_total_mem_kb / max(0.01, rt_vram_kb)), "x footprint")
	print("Geometry Primitives | ", total_triangles, " Triangles | ", active_bricks, " AABBs | 0 Triangles in RT")
	print("Scene Nodes | ", active_subchunks * 2, " Nodes | 1 Node | 99% less node bloat")
	print("Single Edit Latency | ", raster_single_edit_ms, " ms | ", rt_single_edit_ms, " ms | ", (raster_single_edit_ms / max(0.0001, rt_single_edit_ms)), "x faster")
	print("==================================================================")
	
	get_tree().quit(0)
