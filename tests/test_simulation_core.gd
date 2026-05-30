extends GutTest

# Core simulation: spawning, ticks, command ordering, pathfinding, mining, determinism.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")

func _new_sim(seed_value := 42):
	var sim = SimulationScript.new()
	sim.initialize_new_game(seed_value)
	return sim

func _any_unit(sim):
	var ids = sim._sorted_ids(sim.units)
	return sim.units[ids[0]]

func _step(sim, n: int) -> void:
	for i in range(n):
		sim.step_tick()

func test_new_game_spawns_units_on_walkable_surface():
	var sim = _new_sim()
	assert_eq(sim.units.size(), 3, "should spawn three units")
	for id in sim.units.keys():
		var unit = sim.units[id]
		assert_true(sim.world.is_walkable(unit.position), "unit %s should stand on a walkable cell" % id)
		assert_eq(unit.position.y, C.SURFACE_Y_MEAN, "units spawn on the flat spawn clearing")

func test_step_tick_increments_and_is_stable():
	var sim = _new_sim()
	_step(sim, 5)
	assert_eq(sim.tick, 5, "tick should advance by the number of steps")

func test_command_queue_is_canonically_ordered_by_tick():
	var sim = _new_sim()
	# Insert with explicit, fixed ids in scrambled tick order.
	sim.queue_existing_command(sim.make_command(3, "p", "DESIGNATE_MINE", Vector3i(24, 74, 24), {"priority": 5}, "cmd_c"))
	sim.queue_existing_command(sim.make_command(1, "p", "DESIGNATE_MINE", Vector3i(25, 74, 24), {"priority": 5}, "cmd_a"))
	sim.queue_existing_command(sim.make_command(2, "p", "DESIGNATE_MINE", Vector3i(26, 74, 24), {"priority": 5}, "cmd_b"))
	var snapshot = sim._command_queue_snapshot()
	var ticks: Array = []
	for command in snapshot:
		ticks.append(int(command["tick"]))
	assert_eq(ticks, [1, 2, 3], "queue should be canonically ordered by tick regardless of insertion order")

func test_pathfinding_between_adjacent_surface_cells():
	var sim = _new_sim()
	var a := Vector3i(22, C.SURFACE_Y_MEAN, 22)
	var b := Vector3i(23, C.SURFACE_Y_MEAN, 22)
	assert_true(sim.world.is_walkable(a) and sim.world.is_walkable(b), "precondition: both cells walkable")
	var path = sim._path_between(a, b)
	assert_eq(path.size(), 2, "adjacent walkable cells are one step apart")
	assert_eq(sim._step_towards(a, b), b, "stepping should move onto the neighbour")

func test_pathfinding_returns_empty_to_unwalkable():
	var sim = _new_sim()
	var a := Vector3i(22, C.SURFACE_Y_MEAN, 22)
	var solid := Vector3i(22, C.SURFACE_Y_MEAN - 1, 22)  # dirt wall below the surface
	assert_false(sim.world.is_walkable(solid), "precondition: target is a wall")
	assert_eq(sim._path_between(a, solid).size(), 0, "no path to an unwalkable cell")

func test_mining_a_wall_clears_it_and_drops_material():
	var sim = _new_sim()
	var unit = _any_unit(sim)
	var target: Vector3i = unit.position + Vector3i(0, -1, 0)  # the wall directly under the worker
	assert_true(sim.world.peek_cell(target).has_wall(), "precondition: target is a wall")
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_MINE", target, {"priority": 9})
	_step(sim, 12)
	assert_false(sim.world.peek_cell(target).has_wall(), "mining should remove the wall")
	assert_true(sim.world.is_walkable(target), "the mined-out cell should become walkable (floor remains)")
	var dirt := 0
	for item_id in sim.items.keys():
		if sim.items[item_id].item_type == "dirt":
			dirt += 1
	assert_gt(dirt, 0, "mining dirt should drop a dirt item")

func test_same_seed_produces_same_state_hash():
	var a = _new_sim(1234)
	var b = _new_sim(1234)
	_step(a, 10)
	_step(b, 10)
	assert_eq(a.state_hash(), b.state_hash(), "identical seeds and steps must yield identical state hashes")

func test_different_seed_diverges():
	var a = _new_sim(1234)
	var b = _new_sim(5678)
	assert_ne(a.state_hash(), b.state_hash(), "different seeds should produce different state hashes")
