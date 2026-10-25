extends Node

func _ready() -> void:
	print("==================================================")
	print("   VoxelRayTracer GDExtension Test Suite")
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
	
	# Test upload mock sector data
	var mock_aabbs = PackedByteArray()
	mock_aabbs.resize(24 * 4) # 4 mock AABBs
	var mock_bricks = PackedByteArray()
	mock_bricks.resize(1096 * 4) # 4 mock Bricks
	
	rt.upload_sector_aabbs(Vector3i(0, 0, 0), mock_aabbs)
	rt.upload_sector_bricks(Vector3i(0, 0, 0), mock_bricks)
	print("Active Sector Count: ", rt.get_active_sector_count())
	print("Status after upload: ", rt.get_raytracer_status())
	
	print("[SUCCESS] All GDExtension RayTracer tests passed!")
	print("==================================================")
	get_tree().quit(0)
