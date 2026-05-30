extends GutTest

# Integration tests for the gameplay systems on the new world model.
# Scenarios are staged in the flat spawn clearing (y = SURFACE_Y_MEAN) so units
# can always reach the work.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")

const GY := 75  # C.SURFACE_Y_MEAN

func _new_sim(seed_value := 42):
	var sim = SimulationScript.new()
	sim.initialize_new_game(seed_value)
	return sim

func _step(sim, n: int) -> void:
	for i in range(n):
		sim.step_tick()

func _place_plant(sim, addr: Vector3i, plant: String, rtype: String, produced: Dictionary, rid: String) -> void:
	var cell = sim.world.get_cell(addr)
	cell.plant = plant
	cell.resource_id = rid
	sim.resources[rid] = {"id": rid, "type": rtype, "material_key": plant,
		"world_cell": [addr.x, addr.y, addr.z], "yield": produced}

func _count_items(sim, item_type: String) -> int:
	var total := 0
	for id in sim.items.keys():
		if sim.items[id].item_type == item_type:
			total += int(sim.items[id].quantity)
	return total

func test_chop_tree_yields_wood_and_removes_resource():
	var sim = _new_sim()
	var t := Vector3i(26, GY, 26)
	_place_plant(sim, t, C.PLANT_TREE_OAK, "tree", {"wood": 1}, "r_tree")
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CHOP", t, {"priority": 9})
	_step(sim, 40)
	assert_gt(_count_items(sim, "wood"), 0, "chopping a tree should drop wood")
	assert_false(sim.resources.has("r_tree"), "the tree resource should be consumed")
	assert_false(sim.world.peek_cell(t).has_plant(), "the plant should be cleared from the cell")

func test_gather_food_yields_food():
	var sim = _new_sim()
	var b := Vector3i(25, GY, 26)
	_place_plant(sim, b, C.PLANT_BERRY_BUSH, "berry", {"food": 1}, "r_berry")
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_GATHER_FOOD", b, {"priority": 9})
	_step(sim, 40)
	assert_gt(_count_items(sim, "food"), 0, "gathering a berry bush should drop food")

func test_loose_item_is_hauled_into_a_stockpile():
	var sim = _new_sim()
	var item = sim._spawn_item("wood", 1, Vector3i(26, GY, 22))
	var sp_id: String = sim.create_stockpile([[22, GY, 22]], ["wood"], "both")
	assert_ne(sp_id, "", "stockpile should be created on walkable ground")
	_step(sim, 40)
	assert_eq(item.stockpile_id, sp_id, "the loose wood should be stored in the stockpile")
	assert_eq(item.position, Vector3i(22, GY, 22), "the wood should end up on the stockpile cell")

func test_build_wall_construction_completes():
	var sim = _new_sim()
	# Two stone in a supply stockpile.
	var sp_id: String = sim.create_stockpile([[22, GY, 22], [22, GY, 23]], ["stone"], "both")
	var s1 = sim._spawn_item("stone", 1, Vector3i(22, GY, 22))
	var s2 = sim._spawn_item("stone", 1, Vector3i(22, GY, 23))
	sim.assign_item_to_stockpile(s1.id, sp_id)
	sim.assign_item_to_stockpile(s2.id, sp_id)
	var w := Vector3i(25, GY, 24)
	var result: Dictionary = sim.create_construction("wall_block", w)
	assert_true(bool(result.get("ok", false)), "wall blueprint should be accepted: %s" % str(result.get("warning", "")))
	_step(sim, 80)
	var construction = sim.constructions[result["construction_id"]]
	assert_eq(construction.status, "complete", "the wall should finish building")
	assert_ne(sim.world.peek_cell(w).building_id, "", "the built cell should carry a building id")
	assert_true(sim.world.peek_cell(w).has_wall(), "a wall_block should place a blocking wall")

func test_channel_floor_opens_a_shaft():
	var sim = _new_sim()
	var c := Vector3i(24, GY, 26)
	assert_true(sim.world.is_walkable(c), "precondition: target floor is walkable")
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_CHANNEL", c, {"priority": 9})
	_step(sim, 30)
	assert_false(sim.world.peek_cell(c).has_floor(), "channeling should remove the floor")
	assert_false(sim.world.is_walkable(c), "an open shaft is not walkable")

func test_build_stair_sets_connector():
	var sim = _new_sim()
	var s := Vector3i(23, GY, 26)
	sim.queue_command(sim.tick + 1, "p", "DESIGNATE_BUILD_STAIR", s, {"priority": 9})
	_step(sim, 30)
	assert_true(sim.world.peek_cell(s).has_stair(), "a stair should be built on the cell")

func test_hungry_unit_eats_stored_food():
	var sim = _new_sim()
	var sp_id: String = sim.create_stockpile([[22, GY, 22]], ["food"], "both")
	var food = sim._spawn_item("food", 1, Vector3i(22, GY, 22))
	sim.assign_item_to_stockpile(food.id, sp_id)
	var unit = sim.units[sim._sorted_ids(sim.units)[0]]
	unit.needs["hunger"] = 30
	sim.step_tick()
	assert_eq(int(unit.needs["hunger"]), C.MINING_TIER_NONE, "a fed unit's hunger resets to 0")
	assert_eq(_count_items(sim, "food"), 0, "the eaten food should be consumed")

func test_cook_meal_in_kitchen():
	var sim = _new_sim()
	# Supply 3 wood to build the kitchen.
	var sp_id: String = sim.create_stockpile([[20, GY, 20], [20, GY, 21], [20, GY, 22], [21, GY, 20], [21, GY, 21]], ["wood", "food"], "both")
	for i in range(3):
		var wood = sim._spawn_item("wood", 1, Vector3i(20, GY, 20 + i))
		sim.assign_item_to_stockpile(wood.id, sp_id)
	var center := Vector3i(25, GY, 25)
	var build: Dictionary = sim.create_construction("kitchen", center)
	assert_true(bool(build.get("ok", false)), "kitchen blueprint should be accepted: %s" % str(build.get("warning", "")))
	_step(sim, 80)
	var construction = sim.constructions[build["construction_id"]]
	assert_eq(construction.status, "complete", "kitchen should finish building")
	# Stage food and reset hunger so the colonists don't eat it before cooking.
	for i in range(2):
		var food = sim._spawn_item("food", 1, Vector3i(20, GY, 20 + i))
		sim.assign_item_to_stockpile(food.id, sp_id)
	for id in sim.units.keys():
		sim.units[id].needs["hunger"] = 0
	var order: Dictionary = sim.create_workshop_order(construction.completed_building_id, "cook_meal", 5)
	assert_true(bool(order.get("ok", false)), "cook order should be accepted: %s" % str(order.get("warning", "")))
	_step(sim, 18)
	assert_gt(_count_items(sim, "meal"), 0, "the kitchen should cook a meal from stored food")
