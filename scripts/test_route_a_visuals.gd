extends SceneTree

func _init() -> void:
	print("==================================================")
	print("   Route A: Hardware Ray Tracing Visuals Test")
	print("==================================================")
	
	if not ClassDB.class_exists("VoxelRayTracer"):
		printerr("[FAIL] Class 'VoxelRayTracer' not found in ClassDB!")
		quit(1)
		return
		
	var rt = ClassDB.instantiate("VoxelRayTracer")
	print("[PASS] VoxelRayTracer instantiated!")
	print("GPU: ", rt.get_gpu_name())
	
	var ok = rt.init_raytracer(1280, 720)
	print("Init 1280x720: ", ok)
	if not ok:
		printerr("[FAIL] Failed to init raytracer")
		quit(1)
		return

	# Test new API bindings
	rt.set_sun_direction(Vector3(0.55, 0.75, 0.35))
	rt.set_sun_color(Color(1.0, 0.95, 0.85, 1.0))
	rt.set_sun_intensity(1.0)
	rt.set_ambient_intensity(0.28)
	rt.set_rtao_strength(0.70)
	rt.set_rtao_radius(2.5)
	rt.set_soft_shadow_angle(0.035)
	rt.set_enable_rtao(true)
	rt.set_enable_shadows(true)
	print("[PASS] Route A API methods called successfully!")

	# Generate Terrain Sector
	var chunk = ChunkData.new()
	var terrain_noise = FastNoiseLite.new()
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.frequency = 0.02
	
	var biome_noise = FastNoiseLite.new()
	biome_noise.frequency = 0.005
	
	chunk.GenerateTerrainCaelix(Vector3.ZERO, terrain_noise, biome_noise, 0.8, 0.0, 128)
	var aabb_bytes = chunk.GetRayTracingAabbBytes()
	var brick_bytes = chunk.GetRayTracingBrickBytes()
	rt.upload_sector_aabbs(Vector3i(0, 0, 0), aabb_bytes)
	rt.upload_sector_bricks(Vector3i(0, 0, 0), brick_bytes)
	print("[PASS] Uploaded sector to Vulkan RT pipeline. Active sectors: ", rt.get_active_sector_count())

	var cam_pos = Vector3(64.0, 80.0, 120.0)
	var look_target = Vector3(64.0, 30.0, 64.0)
	var cam_transform = Transform3D(Basis(), cam_pos).looking_at(look_target, Vector3.UP)

	# Frame 1: RTAO ON
	rt.set_enable_rtao(true)
	rt.render_frame(cam_transform, 60.0)
	# Second frame for double buffering staging download
	rt.render_frame(cam_transform, 60.0)
	var img_rtao_on: Image = rt.get_output_image().duplicate()
	img_rtao_on.save_png("res://test_rtao_on.png")
	print("[PASS] Frame 1 (RTAO ON) rendered and saved to res://test_rtao_on.png")

	# Frame 2: RTAO OFF
	rt.set_enable_rtao(false)
	rt.render_frame(cam_transform, 60.0)
	rt.render_frame(cam_transform, 60.0)
	var img_rtao_off: Image = rt.get_output_image().duplicate()
	img_rtao_off.save_png("res://test_rtao_off.png")
	print("[PASS] Frame 2 (RTAO OFF) rendered and saved to res://test_rtao_off.png")

	# Compare RTAO ON vs OFF
	var diff_pixels = 0
	var total_darkening = 0.0
	for y in range(100, 620, 10):
		for x in range(100, 1180, 10):
			var p_on = img_rtao_on.get_pixel(x, y)
			var p_off = img_rtao_off.get_pixel(x, y)
			var lum_on = p_on.r * 0.299 + p_on.g * 0.587 + p_on.b * 0.114
			var lum_off = p_off.r * 0.299 + p_off.g * 0.587 + p_off.b * 0.114
			if abs(lum_on - lum_off) > 0.01:
				diff_pixels += 1
				if lum_on < lum_off:
					total_darkening += (lum_off - lum_on)

	print("Sampling grid comparison: %d sample points changed with RTAO enabled!" % diff_pixels)
	print("Accumulated contact darkening metric: %.3f" % total_darkening)
	if diff_pixels > 0 and total_darkening > 0:
		print("[PASS] Verified Hardware RTAO cavity contact darkening is working effectively on GPU!")
	else:
		printerr("[FAIL] RTAO did not produce visual darkening difference")
		quit(1)
		return

	# Frame 3: Sunset Atmosphere Test
	rt.set_enable_rtao(true)
	rt.set_sun_direction(Vector3(0.95, 0.12, 0.25).normalized())
	rt.set_sun_color(Color(1.0, 0.65, 0.35, 1.0))
	rt.render_frame(cam_transform, 60.0)
	rt.render_frame(cam_transform, 60.0)
	var img_sunset: Image = rt.get_output_image().duplicate()
	img_sunset.save_png("res://test_sunset.png")
	print("[PASS] Frame 3 (Sunset Atmosphere) rendered and saved to res://test_sunset.png")

	print("\n==================================================")
	print("   [ALL TESTS PASSED] Route A Hardware RT Visuals Verified!")
	print("==================================================")
	quit(0)
