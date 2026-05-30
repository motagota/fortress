extends GutTest

# Layered worldgen: determinism + band/flora/ore/liquid structure.

const C := preload("res://scripts/simulation/world_constants.gd")
const WorldScript := preload("res://scripts/simulation/world.gd")
const WorldGenScript := preload("res://scripts/simulation/worldgen.gd")

func _generate(seed_value: int) -> Dictionary:
	var world = WorldScript.new()
	var resources: Dictionary = {}
	WorldGenScript.generate(world, resources, seed_value)
	return {"world": world, "resources": resources}

# A cheap deterministic signature over a sampled set of cells.
func _signature(world) -> String:
	var parts: Array[String] = []
	for x in [0, 7, 19, 24, 33, 47]:
		for z in [0, 11, 24, 38, 47]:
			var gy: int = world.surface_y(x, z)
			parts.append("%d,%d:%d" % [x, z, gy])
			for y in [0, 8, 15, 30, gy - 1, gy]:
				if not world.in_bounds(Vector3i(x, y, z)):
					continue
				parts.append(JSON.stringify(world.peek_cell(Vector3i(x, y, z)).to_canonical_dict()))
	return "|".join(parts)

func test_same_seed_is_deterministic():
	var a = _generate(4242)
	var b = _generate(4242)
	assert_eq(_signature(a["world"]), _signature(b["world"]), "same seed must produce an identical world sample")
	assert_eq(JSON.stringify(a["resources"]), JSON.stringify(b["resources"]), "same seed must produce identical resources")

func test_different_seed_differs():
	var a = _generate(4242)
	var c = _generate(9001)
	assert_ne(_signature(a["world"]), _signature(c["world"]), "different seeds should vary the world")

func test_surface_is_walkable_grass_exposed_to_sky():
	var world = _generate(4242)["world"]
	var found_surface := false
	for x in range(0, world.width, 5):
		for z in range(0, world.depth, 5):
			if x >= 20 and x <= 27 and z >= 20 and z <= 27:
				continue
			var gy: int = world.surface_y(x, z)
			var cell = world.peek_cell(Vector3i(x, gy, z))
			assert_eq(cell.band, C.BAND_SURFACE, "ground cell at (%d,%d) should be surface band" % [x, z])
			assert_eq(cell.floor_material, C.MATERIAL_GRASS, "ground cell should have grass floor")
			assert_false(cell.has_wall(), "ground cell should be open (no wall)")
			assert_eq(cell.exposure, "sky", "ground cell should be exposed to the sky")
			assert_true(cell.is_walkable(), "ground cell should be walkable")
			found_surface = true
	assert_true(found_surface, "should have sampled surface cells")

func test_column_strata_dirt_rock_bedrock():
	var world = _generate(4242)["world"]
	var x := 33
	var z := 38
	var gy: int = world.surface_y(x, z)
	assert_eq(world.peek_cell(Vector3i(x, gy - 1, z)).wall_material, C.MATERIAL_DIRT, "just below the surface should be dirt")
	var deep = world.peek_cell(Vector3i(x, 15, z))
	assert_eq(deep.wall_material, C.MATERIAL_HARD_ROCK, "deep rock should be hard rock")
	assert_eq(deep.mining_tier_required, C.MINING_TIER_HARD_ROCK, "hard rock should be tier 2")
	var bedrock = world.peek_cell(Vector3i(x, 0, z))
	assert_eq(bedrock.wall_material, C.MATERIAL_BEDROCK, "bottom layer should be bedrock")
	assert_false(C.is_material_mineable_with_tier(bedrock.wall_material, 99), "bedrock is unmineable")

func test_magma_sea_holds_magma():
	var world = _generate(4242)["world"]
	var cell = world.peek_cell(Vector3i(24, 8, 24))
	assert_eq(cell.band, C.BAND_MAGMA_SEA, "mid-bottom should be magma sea")
	assert_eq(cell.liquid_type, C.LIQUID_MAGMA, "magma sea cells should hold magma")
	assert_eq(cell.liquid_level, C.LIQUID_LEVEL_MAX, "magma should be at max level")
	assert_false(cell.is_walkable(), "deep magma should block walking")

func test_caverns_are_carved():
	var world = _generate(4242)["world"]
	var cavern_cells := 0
	for y in range(C.CAVERN_Y_MIN, C.CAVERN_Y_MAX + 1):
		if not world.has_layer(y):
			continue
		for cell in world.cells_on_layer(y):
			if cell.band == C.BAND_CAVERN and not cell.has_wall():
				cavern_cells += 1
	assert_gt(cavern_cells, 0, "worldgen should carve open cavern cells")

func test_hidden_ore_present_and_not_visible_resources():
	var generated = _generate(4242)
	var world = generated["world"]
	var resources: Dictionary = generated["resources"]
	var coal := 0
	var iron := 0
	for y in range(3, C.SURFACE_Y_MAX):
		if not world.has_layer(y):
			continue
		for cell in world.cells_on_layer(y):
			if cell.hidden_ore.is_empty():
				continue
			match str(cell.hidden_ore.get("item_type", "")):
				"coal": coal += 1
				"iron_ore": iron += 1
	assert_gt(coal, 0, "soft rock should host hidden coal")
	assert_gt(iron, 0, "hard rock should host hidden iron")
	for id in resources.keys():
		assert_false(str(resources[id].get("type", "")) in ["coal", "iron_ore", "copper_ore"], "ore should be hidden, not a visible resource")

func test_flora_seeded_on_surface():
	var generated = _generate(4242)
	var resources: Dictionary = generated["resources"]
	var trees := 0
	var berries := 0
	for id in resources.keys():
		match str(resources[id].get("type", "")):
			"tree": trees += 1
			"berry": berries += 1
	assert_gt(trees, 0, "surface should grow trees")
	assert_gt(berries, 0, "surface should grow berry bushes")

func test_spawn_clearing_is_flat_and_clear():
	var world = _generate(4242)["world"]
	for x in range(20, 28):
		for z in range(20, 28):
			assert_eq(world.surface_y(x, z), C.SURFACE_Y_MEAN, "spawn clearing should be flat")
			var gy: int = world.surface_y(x, z)
			assert_false(world.peek_cell(Vector3i(x, gy, z)).has_plant(), "spawn clearing should have no plants")
