class_name GridWorld
extends RefCounted

const SimCellScript := preload("res://scripts/simulation/cell.gd")
const DeterministicRngScript := preload("res://scripts/simulation/deterministic_rng.gd")

const TERRAIN_DIRT := "dirt"
const TERRAIN_EXCAVATED := "excavated"
const TERRAIN_GRASS := "grass"
const TERRAIN_ROCK := "rock"
const TERRAIN_SOLID_ROCK := "solid_rock"
const TERRAIN_COLLAPSED := "collapsed"

const WORLDGEN_PROFILE := "ironveil_layered_v1"
const SURFACE_LAYER := 1
const SOFT_STONE_LAYER := 3
const DEEP_SOIL_LAYER := 4
const INITIAL_DIRT_CLEAR_X := 2
const INITIAL_DIRT_CLEAR_Z := 2
const STARTING_WORKYARD_CLEAR_X := 5
const STARTING_WORKYARD_CLEAR_Z := 3

var width: int
var height: int
var cells: Dictionary = {}
var generation_profile: String = ""

func _init(pwidth: int = 16, pheight: int = 16) -> void:
    width = pwidth
    height = pheight
    for z in range(height):
        for x in range(width):
            var cell = SimCellScript.new(x, z, "grass", true)
            cells[_key(Vector2i(x, z))] = cell

func _key(pos: Vector2i) -> String:
    return str(pos.x) + "," + str(pos.y)

func in_bounds(pos: Vector2i) -> bool:
    return pos.x >= 0 and pos.y >= 0 and pos.x < width and pos.y < height

func get_cell(pos: Vector2i) :
    if not in_bounds(pos):
        return null
    return cells[_key(pos)]

func set_resource(pos: Vector2i, resource_id: String) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    cell.resource_id = resource_id
    return true

func clear_resource(pos: Vector2i, resource_id: String = "") -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    if resource_id != "" and cell.resource_id != resource_id:
        return false
    cell.resource_id = ""
    return true

func is_mineable_cell(pos: Vector2i) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    if not bool(cell.walkable):
        return false
    if str(cell.building_id) != "":
        return false
    if str(cell.resource_id) != "":
        return true
    return str(cell.terrain) in [TERRAIN_GRASS, TERRAIN_DIRT, TERRAIN_ROCK]

func mine_cell(pos: Vector2i) -> bool:
    var cell = get_cell(pos)
    if cell == null or not is_mineable_cell(pos):
        return false
    cell.terrain = TERRAIN_EXCAVATED
    return true

func collapse_cell(pos: Vector2i) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    cell.terrain = TERRAIN_COLLAPSED
    cell.walkable = false
    cell.resource_id = ""
    return true

func create_forest(rng, resource_index: Dictionary) -> void:
    generate_ironveil_region(rng, resource_index)

func generate_ironveil_region(rng, resource_index: Dictionary) -> void:
    # Deterministic Ironveil-compatible starter projection. Rows are grouped
    # into depth bands until the sim owns true 3D chunks.
    generation_profile = WORLDGEN_PROFILE
    resource_index.clear()
    var seed: int = 1
    if rng != null and rng.has_method("get_state"):
        seed = int(rng.get_state())
    var resource_count: int = 0
    var tree_count: int = 0
    var berry_count: int = 0
    var stone_count: int = 0
    for z in range(height):
        for x in range(width):
            var cell = get_cell(Vector2i(x, z))
            cell.depth = _depth_for_row(z)
            var layer: int = _layer_for_row(z)
            cell.walkable = true
            cell.building_id = ""
            if _is_initial_dirt_cell(x, z):
                cell.terrain = TERRAIN_DIRT
                cell.resource_id = ""
                continue
            if _is_starting_workyard_cell(x, z):
                cell.terrain = _base_terrain_for_layer(layer)
                cell.resource_id = ""
                continue
            cell.terrain = _base_terrain_for_layer(layer)
            cell.resource_id = ""
            var resource_roll: int = _noise_percent(x, z, seed, 0x51f00d)
            var forest_density: int = _noise_percent(x, z, seed, 0x0f0e57)
            var stone_density: int = _noise_percent(x, z, seed, 0x5700e5)
            if layer <= SOFT_STONE_LAYER and stone_density >= 82:
                resource_count += 1
                stone_count += 1
                var rid: String = "resource_%06d" % resource_count
                resource_index[rid] = {
                    "id": rid,
                    "type": "stone",
                    "material_key": "LOOSE_STONE",
                    "position": [x, z],
                    "yield": {"stone": 1},
                    "surface": layer == SURFACE_LAYER,
                    "layer": layer,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                cell.resource_id = rid
            elif layer == SURFACE_LAYER and forest_density >= 58:
                resource_count += 1
                tree_count += 1
                var rid: String = "resource_%06d" % resource_count
                var tree_key: String = "TREE_PINE" if _noise_percent(x, z, seed, 0x91a7e5) >= 72 else "TREE_OAK"
                resource_index[rid] = {
                    "id": rid,
                    "type": "tree",
                    "material_key": tree_key,
                    "position": [x, z],
                    "yield": {"wood": 1},
                    "layer": layer,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                cell.resource_id = rid
            elif layer == SURFACE_LAYER and forest_density >= 34 and forest_density < 58 and resource_roll >= 48:
                resource_count += 1
                berry_count += 1
                var rid: String = "resource_%06d" % resource_count
                resource_index[rid] = {
                    "id": rid,
                    "type": "berry",
                    "material_key": "BERRY_BUSH",
                    "position": [x, z],
                    "yield": {"food": 1},
                    "layer": layer,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                cell.resource_id = rid
    if tree_count == 0:
        resource_count = _place_fallback_resource(resource_index, resource_count, "tree")
    if berry_count == 0:
        resource_count = _place_fallback_resource(resource_index, resource_count, "berry")
    if stone_count == 0:
        _place_fallback_resource(resource_index, resource_count, "stone")

func _place_fallback_resource(resource_index: Dictionary, resource_count: int, resource_type: String) -> int:
    for z in range(height):
        for x in range(width):
            var layer: int = _layer_for_row(z)
            if resource_type in ["tree", "berry"] and layer != SURFACE_LAYER:
                continue
            if resource_type == "stone" and layer > SOFT_STONE_LAYER:
                continue
            if _is_starting_workyard_cell(x, z):
                continue
            var cell = get_cell(Vector2i(x, z))
            if cell == null or cell.resource_id != "":
                continue
            resource_count += 1
            var rid: String = "resource_%06d" % resource_count
            var material_key: String = "TREE_OAK"
            var produced: Dictionary = {"wood": 1}
            if resource_type == "berry":
                material_key = "BERRY_BUSH"
                produced = {"food": 1}
            elif resource_type == "stone":
                material_key = "LOOSE_STONE"
                produced = {"stone": 1}
            resource_index[rid] = {
                "id": rid,
                "type": resource_type,
                "material_key": material_key,
                "position": [x, z],
                "yield": produced,
                "surface": layer == SURFACE_LAYER,
                "layer": layer,
                "worldgen_profile": WORLDGEN_PROFILE,
            }
            cell.resource_id = rid
            return resource_count
    return resource_count

func _noise_percent(x: int, z: int, seed: int, salt: int) -> int:
    var n: int = int(seed) ^ int(salt) ^ int(x * 374761393) ^ int(z * 668265263)
    n = int((n ^ (n >> 13)) * 1274126177)
    n = int(n ^ (n >> 16))
    return int(abs(n) % 100)

func _is_initial_dirt_cell(x: int, z: int) -> bool:
    return x <= INITIAL_DIRT_CLEAR_X and z <= INITIAL_DIRT_CLEAR_Z

func _is_starting_workyard_cell(x: int, z: int) -> bool:
    return x <= STARTING_WORKYARD_CLEAR_X and z <= STARTING_WORKYARD_CLEAR_Z

func _base_terrain_for_layer(layer: int) -> String:
    if layer == SURFACE_LAYER:
        return TERRAIN_GRASS
    if layer == SOFT_STONE_LAYER:
        return TERRAIN_ROCK
    if layer <= DEEP_SOIL_LAYER:
        return TERRAIN_DIRT
    return TERRAIN_SOLID_ROCK

func _layer_for_row(row: int) -> int:
    if height <= 0:
        return 1
    return clampi(int(floor(float(row * 5) / float(height))) + 1, 1, 5)

func _depth_for_row(row: int) -> int:
    return 1 - _layer_for_row(row)

func to_canonical_array() -> Array:
    var arr: Array = []
    for z in range(height):
        for x in range(width):
            arr.append(get_cell(Vector2i(x, z)).to_canonical_dict())
    return arr
