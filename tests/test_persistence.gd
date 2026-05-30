extends GutTest

# Determinism, command replay, and save/load round-trips.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SaveGameScript := preload("res://scripts/simulation/save_game.gd")

const GY := 75
const SAVE_PATH := "user://test_saves/persistence.json"

func _new_sim(seed_value := 77):
	var sim = SimulationScript.new()
	sim.initialize_new_game(seed_value)
	return sim

func _step(sim, n: int) -> void:
	for i in range(n):
		sim.step_tick()

# A deterministic scenario applied identically to two fresh sims.
func _scenario(sim) -> void:
	var t := Vector3i(26, GY, 26)
	var cell = sim.world.get_cell(t)
	cell.plant = C.PLANT_TREE_OAK
	cell.resource_id = "r_tree"
	sim.resources["r_tree"] = {"id": "r_tree", "type": "tree", "material_key": C.PLANT_TREE_OAK,
		"world_cell": [t.x, t.y, t.z], "yield": {"wood": 1}}
	sim.create_stockpile([[22, GY, 22]], ["wood"], "both")
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CHOP", t, {"priority": 9})
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_MINE", Vector3i(23, GY - 1, 23), {"priority": 5})

func test_replay_same_commands_yields_same_hash():
	var a = _new_sim()
	var b = _new_sim()
	_scenario(a)
	_scenario(b)
	_step(a, 40)
	_step(b, 40)
	assert_eq(a.state_hash(), b.state_hash(), "replaying the same command stream must reproduce the state")

func test_save_load_roundtrip_preserves_state_hash():
	var sim = _new_sim()
	_scenario(sim)
	_step(sim, 40)
	var expected: String = sim.state_hash()
	assert_true(SaveGameScript.save_to_file(sim, SAVE_PATH), "save should succeed")
	var loaded = SaveGameScript.load_from_file(SAVE_PATH)
	assert_not_null(loaded, "load should return a simulation")
	assert_eq(loaded.state_hash(), expected, "a loaded game should have an identical state hash")

func test_loaded_game_continues_identically():
	var sim = _new_sim()
	_scenario(sim)
	_step(sim, 30)
	SaveGameScript.save_to_file(sim, SAVE_PATH)
	var loaded = SaveGameScript.load_from_file(SAVE_PATH)
	_step(sim, 15)
	_step(loaded, 15)
	assert_eq(loaded.state_hash(), sim.state_hash(), "a loaded game should tick forward identically to the original")

func test_save_is_seed_plus_small_diff():
	var sim = _new_sim()
	_scenario(sim)
	_step(sim, 40)
	var data: Dictionary = SaveGameScript.to_dict(sim)
	assert_eq(int(data["world_seed"]), 77, "save should record the world seed")
	# Only player-touched cells are stored, not the whole ~175k-cell world.
	assert_lt(int(data["cell_diffs"].size()), 2000, "cell diffs should be small relative to the full world")

func after_all():
	var path := ProjectSettings.globalize_path(SAVE_PATH)
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
