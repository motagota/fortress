extends GutTest

# Wildlife + net hunting: a colonist stalks an animal, fires a net, the net
# lands on the animal, and the caught animal is collected as an item.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SaveGameScript := preload("res://scripts/simulation/save_game.gd")

const GY := 75  # C.SURFACE_Y_MEAN

func _new_sim(seed_value := 42):
	var sim = SimulationScript.new()
	sim.initialize_new_game(seed_value)
	return sim

func _step(sim, n: int) -> void:
	for i in range(n):
		sim.step_tick()

# A single, stationary rabbit in the spawn clearing so the test is predictable.
func _sim_with_rabbit(addr := Vector3i(27, GY, 21)):
	var sim = _new_sim()
	sim.animals.clear()
	var id: String = sim.spawn_animal("rabbit", addr)
	return {"sim": sim, "animal_id": id}

func _count_items(sim, item_type: String) -> int:
	var total := 0
	for id in sim.items.keys():
		if sim.items[id].item_type == item_type:
			total += int(sim.items[id].quantity)
	return total

func test_new_game_spawns_wild_animals_on_walkable_ground():
	var sim = _new_sim()
	assert_gt(sim.animals.size(), 0, "a new world should have wildlife")
	for id in sim.animals.keys():
		var animal = sim.animals[id]
		assert_true(animal.is_wild())
		assert_true(sim.world.is_walkable(animal.position), "animals should stand on walkable ground")

func test_wild_animals_wander():
	var sim = _new_sim()
	var start: Dictionary = {}
	for id in sim.animals.keys():
		start[id] = sim.animals[id].position
	_step(sim, 30)
	var moved := 0
	for id in sim.animals.keys():
		if sim.animals[id].position != start[id]:
			moved += 1
	assert_gt(moved, 0, "wild animals should roam")

func test_colonist_fires_net_that_catches_the_animal():
	var setup: Dictionary = _sim_with_rabbit()
	var sim = setup["sim"]
	var animal_id: String = setup["animal_id"]
	var animal = sim.animals[animal_id]
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CATCH_ANIMAL", animal.position, {"priority": 9})

	var saw_net_in_flight := false
	var saw_netted := false
	for i in range(80):
		sim.step_tick()
		for net_id in sim.nets.keys():
			if sim.nets[net_id].is_flying():
				saw_net_in_flight = true
		if sim.animals.has(animal_id) and sim.animals[animal_id].is_netted():
			saw_netted = true
		if not sim.animals.has(animal_id):
			break
	assert_true(saw_net_in_flight, "a colonist should fire a net that flies through the air")
	assert_true(saw_netted, "the net should land on and catch the animal")
	assert_false(sim.animals.has(animal_id), "the caught animal should be collected")
	assert_eq(_count_items(sim, "caught_rabbit"), 1, "collecting the animal yields a caught_rabbit item")
	assert_true(sim.nets.is_empty(), "the net is gathered up with the animal")

func test_netted_animal_stops_moving():
	var setup: Dictionary = _sim_with_rabbit()
	var sim = setup["sim"]
	var animal_id: String = setup["animal_id"]
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CATCH_ANIMAL", sim.animals[animal_id].position, {"priority": 9})
	for i in range(80):
		sim.step_tick()
		if sim.animals[animal_id].is_netted():
			break
	assert_true(sim.animals[animal_id].is_netted())
	# Freeze colonists so nobody collects it, then make sure it stays pinned.
	for unit_id in sim.units.keys():
		sim.units[unit_id].allowed_jobs.clear()
		sim.units[unit_id].current_job_id = ""
	var pinned_at: Vector3i = sim.animals[animal_id].position
	_step(sim, 30)
	assert_eq(sim.animals[animal_id].position, pinned_at, "a netted animal can't wander off")

func test_clicking_empty_ground_creates_no_catch_job():
	var setup: Dictionary = _sim_with_rabbit(Vector3i(27, GY, 21))
	var sim = setup["sim"]
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CATCH_ANIMAL", Vector3i(20, GY, 27), {"priority": 9})
	_step(sim, 1)
	var catch_jobs := 0
	for job_id in sim.job_board.jobs.keys():
		if sim.job_board.jobs[job_id].type == "CATCH_ANIMAL":
			catch_jobs += 1
	assert_eq(catch_jobs, 0, "no animal there, so no catch job")

func test_same_animal_is_not_designated_twice():
	var setup: Dictionary = _sim_with_rabbit()
	var sim = setup["sim"]
	var pos: Vector3i = sim.animals[setup["animal_id"]].position
	assert_ne(sim.designate_catch_animal(pos, 5), "")
	assert_eq(sim.designate_catch_animal(pos, 5), "", "a second designation on the same animal is ignored")

func test_hunt_is_deterministic_and_survives_save_load():
	var a = _sim_with_rabbit()["sim"]
	var b = _sim_with_rabbit()["sim"]
	for sim in [a, b]:
		sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CATCH_ANIMAL", Vector3i(27, GY, 21), {"priority": 9})
	_step(a, 12)
	_step(b, 12)
	assert_eq(a.state_hash(), b.state_hash(), "hunting must be deterministic")
	var loaded = SaveGameScript.from_dict(JSON.parse_string(JSON.stringify(SaveGameScript.to_dict(a))))
	assert_eq(loaded.state_hash(), a.state_hash(), "a mid-hunt save restores identically")
	_step(a, 40)
	_step(loaded, 40)
	assert_eq(loaded.state_hash(), a.state_hash(), "a loaded hunt plays out identically")
