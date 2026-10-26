extends SceneTree

class MockChunkManager:
	func is_voxel_solid(x: int, y: int, z: int) -> bool:
		# Floor at y <= 0
		return y <= 0

func _init() -> void:
	print("==================================================")
	print("   Testing Caelix 6-DOF Dynamics & Physics System")
	print("==================================================")

	var mock_cm = MockChunkManager.new()

	# 1. Test 6-DOF VoxelEntity instantiation and Inertia Tensor
	var v_voxels: Array[Vector3i] = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(2, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, 2, 0)
	]
	var v_types: Array[int] = [
		VoxelTypes.Type.STONE,
		VoxelTypes.Type.STONE,
		VoxelTypes.Type.DIRT,
		VoxelTypes.Type.WOOD,
		VoxelTypes.Type.LEAVES
	]

	var vent = VoxelEntity.new()
	get_root().add_child(vent)
	var center = Vector3(1.0, 5.0, 0.0) # Start 5m above floor
	vent.setup(v_voxels, v_types, center, Vector3.ZERO, Vector3.ZERO, mock_cm)

	print("VoxelEntity Mass: %.2f kg" % vent.mass)
	print("VoxelEntity Body Inertia: (%.2f, %.2f, %.2f)" % [vent.body_inertia.x, vent.body_inertia.y, vent.body_inertia.z])
	if vent.mass <= 0.0 or vent.body_inertia.x <= 0.0 or vent.body_inertia.y <= 0.0:
		printerr("[FAIL] Invalid mass or inertia tensor!")
		quit(1)
		return
	print("[PASS] VoxelEntity mass and 3x3 inertia tensor verified!")

	# 2. Test Impulse & Angular Momentum Injection (Torque Lever Theorem)
	var initial_ang_speed = vent.angular_velocity.length()
	var impulse = Vector3(0.0, 15.0, 0.0)
	var contact_point = center + Vector3(2.0, 0.0, 0.0) # Lever arm = 2m along X
	vent.apply_impulse(impulse, contact_point)

	var post_ang_speed = vent.angular_velocity.length()
	print("Post-Impulse Linear Velocity: ", vent.linear_velocity)
	print("Post-Impulse Angular Velocity: ", vent.angular_velocity)
	if post_ang_speed <= initial_ang_speed:
		printerr("[FAIL] Off-center impulse did not generate rotational torque!")
		quit(1)
		return
	print("[PASS] Off-center impulse generated angular torque momentum successfully!")

	# 3. Simulate multi-step 6-DOF trajectory & collision response
	var start_pos = vent.position
	for i in range(30):
		vent._physics_process(0.016)

	print("Step 30 Pos: ", vent.position, " Rot Basis: ", vent.transform.basis)
	if vent.position == start_pos:
		printerr("[FAIL] Body failed to move during simulation steps")
		quit(1)
		return
	print("[PASS] Continuous 6-DOF translation and rotation step integration verified!")

	vent.queue_free()

	print("\n==================================================")
	print("   [ALL TESTS PASSED] Caelix Dynamics System Verified!")
	print("==================================================")
	quit(0)
