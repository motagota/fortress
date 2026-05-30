extends GutTest

# Floor/wall/extras semantics of a single cell.

const C := preload("res://scripts/simulation/world_constants.gd")
const SimCellScript := preload("res://scripts/simulation/cell.gd")

func test_new_cell_is_default_and_not_walkable():
	var cell = SimCellScript.new()
	assert_true(cell.is_default(), "a fresh cell should be at default values")
	assert_false(cell.has_floor(), "default cell has no floor")
	assert_false(cell.has_wall(), "default cell has no wall")
	assert_false(cell.is_walkable(), "an open cell with no floor is not walkable")

func test_floor_without_wall_is_walkable():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_GRASS
	assert_true(cell.has_floor(), "floor material should register a floor")
	assert_true(cell.is_walkable(), "a floored, wall-free cell should be walkable")
	assert_false(cell.is_default(), "a floored cell is not default")

func test_wall_blocks_walking_even_with_floor():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_DIRT
	cell.wall_material = C.MATERIAL_SOFT_ROCK
	assert_true(cell.has_wall(), "wall material should register a wall")
	assert_false(cell.is_walkable(), "a walled cell blocks movement")

func test_deep_liquid_blocks_walking():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_DIRT
	cell.liquid_type = C.LIQUID_WATER
	cell.liquid_level = C.LIQUID_BLOCK_LEVEL
	assert_false(cell.is_walkable(), "deep liquid should block walking")
	cell.liquid_level = C.LIQUID_BLOCK_LEVEL - 1
	assert_true(cell.is_walkable(), "shallow liquid should still allow walking")

func test_stairs_connect_vertically():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_DIRT
	cell.stair = C.STAIR_UP
	assert_true(cell.connects_up(), "an up-stair connects upward")
	assert_false(cell.connects_down(), "an up-stair does not connect downward")
	cell.stair = C.STAIR_UP_DOWN
	assert_true(cell.connects_up() and cell.connects_down(), "an up/down stair connects both ways")

func test_stair_only_cell_is_walkable():
	var cell = SimCellScript.new()
	cell.stair = C.STAIR_DOWN
	assert_true(cell.is_walkable(), "a stair gives something to stand on")

func test_canonical_dict_is_stable_and_complete():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_GRASS
	cell.band = C.BAND_SURFACE
	var d = cell.to_canonical_dict()
	for key in ["band", "building_id", "designation", "exposure", "floor_material",
			"hidden_ore", "liquid_level", "liquid_type", "mining_tier_required",
			"plant", "plant_growth", "resource_id", "stair", "wall_material"]:
		assert_true(d.has(key), "canonical dict should include '%s'" % key)
	assert_eq(d["floor_material"], C.MATERIAL_GRASS, "canonical dict should reflect floor material")

func test_duplicate_is_independent():
	var cell = SimCellScript.new()
	cell.floor_material = C.MATERIAL_DIRT
	cell.hidden_ore = {"material": C.MATERIAL_ORE_IRON, "item_type": "iron_ore", "quantity": 1}
	var copy = cell.duplicate_cell()
	copy.floor_material = C.MATERIAL_GRASS
	copy.hidden_ore["quantity"] = 5
	assert_eq(cell.floor_material, C.MATERIAL_DIRT, "mutating a copy must not affect the original")
	assert_eq(int(cell.hidden_ore["quantity"]), 1, "nested dict should be deep-copied")
