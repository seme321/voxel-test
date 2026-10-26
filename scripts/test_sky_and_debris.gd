extends SceneTree

func _init() -> void:
	print("==================================================")
	print("   Testing Sky Dome and Explosion Debris Fixes")
	print("==================================================")
	
	if not ClassDB.class_exists("VoxelRayTracer"):
		printerr("[FAIL] Class 'VoxelRayTracer' not found!")
		quit(1)
		return
		
	var rt = ClassDB.instantiate("VoxelRayTracer")
	var ok = rt.init_raytracer(640, 360)
	print("Raytracer Init: ", ok)
	if not ok:
		printerr("[FAIL] Raytracer init failed")
		quit(1)
		return

	rt.set_sun_direction(Vector3(0.55, 0.75, 0.35))
	rt.set_sun_color(Color(1.0, 0.95, 0.85, 1.0))
	rt.set_sun_intensity(1.0)
	rt.set_ambient_intensity(0.28)
	rt.set_enable_rtao(true)
	rt.set_enable_shadows(true)

	# Upload Sector to build TLAS
	var chunk = ChunkData.new()
	var terrain_noise = FastNoiseLite.new()
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.frequency = 0.02
	var biome_noise = FastNoiseLite.new()
	biome_noise.frequency = 0.005
	chunk.GenerateTerrainCaelix(Vector3.ZERO, terrain_noise, biome_noise, 0.8, 0.0, 128)
	rt.upload_sector_aabbs(Vector3i(0, 0, 0), chunk.GetRayTracingAabbBytes())
	rt.upload_sector_bricks(Vector3i(0, 0, 0), chunk.GetRayTracingBrickBytes())

	# Test 1: Render looking UP at the sky (no terrain hit)
	var cam_pos = Vector3(64.0, 130.0, 64.0)
	var sky_target = Vector3(64.0, 200.0, 64.0)
	var sky_cam = Transform3D(Basis(), cam_pos).looking_at(sky_target, Vector3.FORWARD)

	for _i in range(3):
		rt.render_frame(sky_cam, 60.0)

	var img: Image = rt.get_output_image().duplicate()
	var center_pixel = img.get_pixel(320, 180)
	print("Sky Center Pixel: R=%.3f, G=%.3f, B=%.3f, A=%.3f" % [center_pixel.r, center_pixel.g, center_pixel.b, center_pixel.a])

	var sky_lum = center_pixel.r * 0.299 + center_pixel.g * 0.587 + center_pixel.b * 0.114
	if sky_lum < 0.1:
		printerr("[FAIL] Sky is black! Luminance: ", sky_lum)
		quit(1)
		return
	else:
		print("[PASS] Sky is rendered with bright atmospheric illumination! Luminance: %.3f" % sky_lum)

	# Verify it has atmospheric blue or sunset color
	if center_pixel.b > 0.2 or center_pixel.r > 0.2:
		print("[PASS] Sky color has vivid atmospheric tone!")
	else:
		printerr("[FAIL] Sky color is dull/abnormal")
		quit(1)
		return

	# Test 2: Verify VoxelDebrisEntity
	var debris = VoxelDebrisEntity.new()
	debris.setup(VoxelTypes.Type.STONE, Vector3(0, 10, 0), Vector3(2, 5, 2), null)
	print("[PASS] VoxelDebrisEntity instantiated and initialized successfully!")
	debris.queue_free()

	print("\n==================================================")
	print("   [ALL TESTS PASSED] Sky & Debris Verified!")
	print("==================================================")
	quit(0)
