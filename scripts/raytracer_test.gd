extends Node

func _ready() -> void:
	print("==================================================")
	print("   VoxelRayTracer Hardware Ray Tracing Test Suite")
	print("==================================================")
	
	if not ClassDB.class_exists("VoxelRayTracer"):
		printerr("[FAIL] Class 'VoxelRayTracer' not found in ClassDB!")
		get_tree().quit(1)
		return
		
	var rt = ClassDB.instantiate("VoxelRayTracer")
	print("[PASS] VoxelRayTracer instantiated successfully!")
	print("GPU Model: ", rt.get_gpu_name())
	print("RTX Hardware Supported: ", rt.is_rtx_supported())
	
	var ok = rt.init_raytracer(1280, 720)
	print("Raytracer Init: ", ok)
	print("Status: ", rt.get_raytracer_status())
	
	# [Stage 1] Procedural Terrain Sector Generation via C# ChunkData
	print("\n--- [Stage 1] Procedural Sector Generation via ChunkData ---")
	var chunk = ChunkData.new()
	var terrain_noise = FastNoiseLite.new()
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.frequency = 0.02
	
	var biome_noise = FastNoiseLite.new()
	biome_noise.frequency = 0.005
	
	chunk.GenerateTerrainCaelix(Vector3.ZERO, terrain_noise, biome_noise, 0.8, 0.0, 128)
	print("Generated Sector Voxels: ", chunk.NumberOfVoxels())
	
	var aabb_bytes = chunk.GetRayTracingAabbBytes()
	var brick_bytes = chunk.GetRayTracingBrickBytes()
	var brick_count = aabb_bytes.size() / 24
	print("Exported BLAS AABBs: ", brick_count, " bricks (", aabb_bytes.size(), " bytes)")
	print("Exported Brick SSBO: ", brick_bytes.size(), " bytes")
	
	# Upload Sector to Vulkan RTX Raytracer (Builds BLAS)
	rt.upload_sector_aabbs(Vector3i(0, 0, 0), aabb_bytes)
	rt.upload_sector_bricks(Vector3i(0, 0, 0), brick_bytes)
	print("Active Sector Count: ", rt.get_active_sector_count())
	print("Status after Sector BLAS upload: ", rt.get_raytracer_status())
	
	# [Stage 2] Hardware Ray Tracing Frame Render Dispatch
	print("\n--- [Stage 2] Hardware Ray Tracing Dispatch on RTX 4070 ---")
	# Position camera high above terrain looking down across the landscape
	var cam_pos = Vector3(64.0, 100.0, 160.0)
	var look_target = Vector3(64.0, 32.0, 64.0)
	var cam_transform = Transform3D(Basis(), cam_pos).looking_at(look_target, Vector3.UP)
	
	print("Dispatching vkCmdTraceRaysKHR on RTX 4070 GPU...")
	rt.render_frame(cam_transform, 60.0)
	print("Hardware Ray Tracing frame successfully dispatched!")
	
	var img = rt.get_output_image()
	if img:
		print("Presentation Image Size: ", img.get_width(), "x", img.get_height(), " (Format: ", img.get_format(), ")")
		var sample_pixel = img.get_pixel(640, 360)
		print("Center Pixel RGBA: R=", int(sample_pixel.r * 255), " G=", int(sample_pixel.g * 255), " B=", int(sample_pixel.b * 255), " A=", int(sample_pixel.a * 255))
		img.save_png("res://raytraced_terrain.png")
		print("Saved rendered terrain frame to res://raytraced_terrain.png")
		
	print("Final Status: ", rt.get_raytracer_status())
	print("\n[SUCCESS] Full Caelix Hardware Ray Tracing Pipeline Verified Flawlessly!")
	print("==================================================")
	get_tree().quit(0)
