extends GutTest

# Dense layered world store: addressing, lazy materialization, movement neighbors.

const C := preload("res://scripts/simulation/world_constants.gd")
const WorldScript := preload("res://scripts/simulation/world.gd")

func _floor_cell(world, cell: Vector3i, material := C.MATERIAL_GRASS) -> void:
	var c = world.get_cell(cell)
	c.floor_material = material

func test_dimensions_and_bounds():
	var world = WorldScript.new()
	assert_eq(world.width, C.WIDTH, "world width")
	assert_eq(world.depth, C.DEPTH, "world depth")
	assert_eq(world.layer_count, C.LAYER_COUNT, "world layer count")
	assert_true(world.in_bounds(Vector3i(0, 0, 0)), "origin is in bounds")
	assert_true(world.in_bounds(Vector3i(C.WIDTH - 1, C.LAYER_COUNT - 1, C.DEPTH - 1)), "far corner is in bounds")
	assert_false(world.in_bounds(Vector3i(C.WIDTH, 0, 0)), "x past width is out of bounds")
	assert_false(world.in_bounds(Vector3i(0, -1, 0)), "negative y is out of bounds")

func test_get_cell_is_mutable_and_persists():
	var world = WorldScript.new()
	var addr := Vector3i(3, 75, 4)
	var c = world.get_cell(addr)
	c.floor_material = C.MATERIAL_DIRT
	c.wall_material = C.MATERIAL_SOFT_ROCK
	var again = world.get_cell(addr)
	assert_eq(again.floor_material, C.MATERIAL_DIRT, "mutations should persist across get_cell")
	assert_eq(again.wall_material, C.MATERIAL_SOFT_ROCK, "wall mutation should persist")
	assert_null(world.get_cell(Vector3i(-1, 0, 0)), "out-of-bounds get_cell returns null")

func test_peek_does_not_materialize_layer():
	var world = WorldScript.new()
	assert_false(world.has_layer(50), "layer should start unmaterialized")
	var peeked = world.peek_cell(Vector3i(1, 50, 1))
	assert_true(peeked.is_default(), "peeking an unstored cell returns a default")
	assert_false(world.has_layer(50), "peek must not materialize the layer")
	world.get_cell(Vector3i(1, 50, 1))
	assert_true(world.has_layer(50), "get_cell materializes the layer")

func test_cells_on_layer_is_full():
	var world = WorldScript.new()
	var cells = world.cells_on_layer(75)
	assert_eq(cells.size(), C.WIDTH * C.DEPTH, "a materialized layer holds width*depth cells")

func test_surface_y_roundtrip():
	var world = WorldScript.new()
	world.set_surface_y(5, 6, 80)
	assert_eq(world.surface_y(5, 6), 80, "surface elevation should round-trip")

func test_horizontal_movement_neighbors():
	var world = WorldScript.new()
	var center := Vector3i(10, 75, 10)
	_floor_cell(world, center)
	_floor_cell(world, center + Vector3i(1, 0, 0))
	_floor_cell(world, center + Vector3i(-1, 0, 0))
	# leave +z open (no floor) and -z a wall
	_floor_cell(world, center + Vector3i(0, 0, -1))
	world.get_cell(center + Vector3i(0, 0, -1)).wall_material = C.MATERIAL_HARD_ROCK
	var neighbors = world.neighbors_for_movement(center)
	assert_true(neighbors.has(center + Vector3i(1, 0, 0)), "walkable +x is a neighbor")
	assert_true(neighbors.has(center + Vector3i(-1, 0, 0)), "walkable -x is a neighbor")
	assert_false(neighbors.has(center + Vector3i(0, 0, 1)), "open (no floor) +z is not walkable")
	assert_false(neighbors.has(center + Vector3i(0, 0, -1)), "walled -z is not walkable")

func test_vertical_movement_requires_stairs():
	var world = WorldScript.new()
	var lower := Vector3i(20, 70, 20)
	var upper := lower + Vector3i(0, 1, 0)
	_floor_cell(world, lower)
	_floor_cell(world, upper)
	# No stairs yet -> no vertical neighbor.
	assert_false(world.neighbors_for_movement(lower).has(upper), "no stair means no vertical move")
	world.get_cell(lower).stair = C.STAIR_UP
	assert_true(world.neighbors_for_movement(lower).has(upper), "an up-stair enables the upward move")

func test_canonical_array_lists_only_non_default_cells():
	var world = WorldScript.new()
	world.cells_on_layer(75)  # materialize a whole layer of defaults
	_floor_cell(world, Vector3i(2, 75, 2), C.MATERIAL_GRASS)
	var arr = world.to_canonical_array()
	assert_eq(arr.size(), 1, "only the single non-default cell should be emitted")
	assert_eq(arr[0]["cell"], [2, 75, 2], "emitted record should carry its address")
	assert_eq(arr[0]["floor_material"], C.MATERIAL_GRASS, "emitted record should carry cell fields")
