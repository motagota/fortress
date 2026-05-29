class_name GridWorld
extends RefCounted

const SimCellScript := preload("res://scripts/simulation/cell.gd")
const DeterministicRngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const ChunkAddressingScript := preload("res://scripts/simulation/chunk_addressing.gd")

const TERRAIN_DIRT := "dirt"
const TERRAIN_EXCAVATED := "excavated"
const TERRAIN_GRASS := "grass"
const TERRAIN_ROCK := "rock"
const TERRAIN_SOLID_ROCK := "solid_rock"
const TERRAIN_COLLAPSED := "collapsed"

const MATERIAL_AIR := "AIR"
const MATERIAL_DIRT := "DIRT"
const MATERIAL_CLAY := "CLAY"
const MATERIAL_GRAVEL := "GRAVEL"
const MATERIAL_WATER_FLOW := "WATER_FLOW"
const MATERIAL_SOFT_ROCK := "SOFT_ROCK"
const MATERIAL_HARD_ROCK := "HARD_ROCK"
const MATERIAL_BEDROCK := "BEDROCK"
const MATERIAL_LAVA := "LAVA"
const MATERIAL_GRASS := "GRASS"
const MATERIAL_LOOSE_STONE := "LOOSE_STONE"
const MATERIAL_TREE_OAK := "TREE_OAK"
const MATERIAL_TREE_PINE := "TREE_PINE"
const MATERIAL_BERRY_BUSH := "BERRY_BUSH"
const MATERIAL_WILD_WHEAT := "WILD_WHEAT"
const MATERIAL_ORE_COAL := "ORE_COAL"
const MATERIAL_ORE_COPPER := "ORE_COPPER"
const MATERIAL_ORE_IRON := "ORE_IRON"
const MATERIAL_ORE_SILVER := "ORE_SILVER"
const MATERIAL_ORE_GOLD := "ORE_GOLD"
const MATERIAL_OIL := "OIL"

const STRATA_SURFACE := "surface"
const STRATA_SOIL := "soil"
const STRATA_SOFT_ROCK := "soft_rock"
const STRATA_DEEP_SOIL := "deep_soil"
const STRATA_HARD_ROCK := "hard_rock"

const MINING_TIER_NONE := 0
const MINING_TIER_BASIC := 1
const MINING_TIER_HARD_ROCK := 2
const MINING_TIER_RARE_ORE := 3

const WORLDGEN_PROFILE := "ironveil_layered_v1"
const STORAGE_MODEL := "stacked_projection_v1"
const TARGET_STORAGE_MODEL := "chunked_3d_v1"
const TARGET_CHUNK_SIZE := 16
const TARGET_CHUNK_SHAPE := [16, 16, 16]
const DEEP_HAZARDS_ENABLED := false
const DEEP_HAZARDS_REQUIRE_STORAGE_MODEL := "chunked_3d_v1"
const SURFACE_LAYER := 1
const SOFT_STONE_LAYER := 3
const DEEP_SOIL_LAYER := 4
const INITIAL_DIRT_CLEAR_X := 2
const INITIAL_DIRT_CLEAR_Z := 2
const STARTING_WORKYARD_CLEAR_X := 5
const STARTING_WORKYARD_CLEAR_Z := 3
const HEIGHT_MIN := -2
const HEIGHT_MAX := 6

var width: int
var height: int
var cells: Dictionary = {}
var generation_profile: String = ""
var height_map: Dictionary = {}
var slope_map: Dictionary = {}
var river_map: Dictionary = {}
var cave_map: Dictionary = {}

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

func get_surface_height(pos: Vector2i) -> int:
    if not in_bounds(pos):
        return 0
    return int(height_map.get(_key(pos), 0))

func get_slope_degrees(pos: Vector2i) -> int:
    if not in_bounds(pos):
        return 0
    return int(slope_map.get(_key(pos), 0))

func is_river_cell(pos: Vector2i) -> bool:
    if not in_bounds(pos):
        return false
    return river_map.has(_key(pos))

func get_river_data(pos: Vector2i) -> Dictionary:
    if not in_bounds(pos):
        return {}
    return river_map.get(_key(pos), {}).duplicate(true)

func get_river_cells() -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for key in river_map.keys():
        var parts: PackedStringArray = str(key).split(",")
        if parts.size() >= 2:
            output.append(Vector2i(int(parts[0]), int(parts[1])))
    output.sort()
    return output

func is_cave_cell(pos: Vector2i) -> bool:
    if not in_bounds(pos):
        return false
    return cave_map.has(_key(pos))

func get_cave_data(pos: Vector2i) -> Dictionary:
    if not in_bounds(pos):
        return {}
    return cave_map.get(_key(pos), {}).duplicate(true)

func get_cave_cells() -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for key in cave_map.keys():
        var parts: PackedStringArray = str(key).split(",")
        if parts.size() >= 2:
            output.append(Vector2i(int(parts[0]), int(parts[1])))
    output.sort()
    return output

func get_storage_metadata() -> Dictionary:
    return {
        "storage_model": STORAGE_MODEL,
        "target_storage_model": TARGET_STORAGE_MODEL,
        "chunk_storage_active": false,
        "projected_width": width,
        "projected_height": height,
        "projected_depth_layers": 5,
        "target_chunk_size": TARGET_CHUNK_SIZE,
        "target_chunk_shape": TARGET_CHUNK_SHAPE.duplicate(),
        "deep_hazards_enabled": DEEP_HAZARDS_ENABLED,
    }

func get_storage_address_for_projected_cell(pos: Vector2i) -> Dictionary:
    if not in_bounds(pos):
        return {
            "valid": false,
            "reason": "projected_cell_out_of_bounds",
            "projected_cell": [pos.x, pos.y],
            "storage_model": STORAGE_MODEL,
            "target_storage_model": TARGET_STORAGE_MODEL,
        }
    var cell = get_cell(pos)
    var display_cell := Vector2i(pos.x, _display_row_for_row(pos.y))
    var world_cell := Vector3i(pos.x, int(cell.depth), display_cell.y)
    var address: Dictionary = ChunkAddressingScript.world_to_chunk(world_cell, TARGET_CHUNK_SIZE)
    address["projected_cell"] = [pos.x, pos.y]
    address["display_cell"] = [display_cell.x, display_cell.y]
    address["storage_model"] = STORAGE_MODEL
    address["target_storage_model"] = TARGET_STORAGE_MODEL
    address["projection_depth"] = int(cell.depth)
    return address

func get_projected_cell_for_world_cell(world_cell: Vector3i) -> Dictionary:
    if world_cell.x < 0 or world_cell.x >= width:
        return {
            "valid": false,
            "reason": "world_cell_out_of_bounds",
            "world_cell": ChunkAddressingScript.vector3i_to_array(world_cell),
            "storage_model": STORAGE_MODEL,
            "target_storage_model": TARGET_STORAGE_MODEL,
        }
    if world_cell.z < 0:
        return {
            "valid": false,
            "reason": "world_cell_out_of_projection",
            "world_cell": ChunkAddressingScript.vector3i_to_array(world_cell),
            "storage_model": STORAGE_MODEL,
            "target_storage_model": TARGET_STORAGE_MODEL,
        }
    for row in range(height):
        var candidate := Vector2i(world_cell.x, row)
        var cell = get_cell(candidate)
        if cell == null:
            continue
        if int(cell.depth) == world_cell.y and _display_row_for_row(row) == world_cell.z:
            return {
                "valid": true,
                "projected_cell": [candidate.x, candidate.y],
                "display_cell": [candidate.x, world_cell.z],
                "world_cell": ChunkAddressingScript.vector3i_to_array(world_cell),
                "storage_model": STORAGE_MODEL,
                "target_storage_model": TARGET_STORAGE_MODEL,
            }
    return {
        "valid": false,
        "reason": "world_cell_out_of_projection",
        "world_cell": ChunkAddressingScript.vector3i_to_array(world_cell),
        "storage_model": STORAGE_MODEL,
        "target_storage_model": TARGET_STORAGE_MODEL,
    }

func get_projected_cell_storage_view(pos: Vector2i) -> Dictionary:
    var view: Dictionary = get_storage_address_for_projected_cell(pos)
    if not bool(view.get("valid", false)):
        return view
    var cell = get_cell(pos)
    view["cell"] = {
        "terrain": str(cell.terrain),
        "material_key": str(cell.material_key),
        "walkable": bool(cell.walkable),
        "strata_key": str(cell.strata_key),
        "mining_tier_required": int(cell.mining_tier_required),
        "resource_id": str(cell.resource_id),
        "building_id": str(cell.building_id),
        "hidden_mine_yield": cell.hidden_mine_yield.duplicate(true),
        "is_river": bool(cell.is_river),
        "river_id": str(cell.river_id),
        "distance_to_river": int(cell.distance_to_river),
        "water_feature": str(cell.water_feature),
        "is_cave": bool(cell.is_cave),
        "cave_id": str(cell.cave_id),
        "exposure": str(cell.exposure),
        "surface_height": int(cell.surface_height),
        "slope_degrees": int(cell.slope_degrees),
    }
    return view

func get_deep_hazard_policy() -> Dictionary:
    return {
        "enabled": DEEP_HAZARDS_ENABLED,
        "deferred_until_storage_model": DEEP_HAZARDS_REQUIRE_STORAGE_MODEL,
        "current_projection_min_depth": _depth_for_row(maxi(height - 1, 0)),
        "future_materials": [MATERIAL_BEDROCK, MATERIAL_LAVA],
        "blocked_by": ["deep_vertical_ranges", "pathing_support", "mining_support", "fluid_rules"],
    }

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
    cell.material_key = _base_material_for_cell(cell)
    cell.mining_tier_required = get_required_mining_tier_for_material(cell.material_key)
    return true

func get_required_mining_tier(pos: Vector2i) -> int:
    var cell = get_cell(pos)
    if cell == null:
        return 999
    return int(cell.mining_tier_required)

func is_mineable_cell(pos: Vector2i, mining_tier: int = MINING_TIER_BASIC) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    if not bool(cell.walkable):
        return false
    if str(cell.building_id) != "":
        return false
    return is_material_mineable_with_tier(str(cell.material_key), mining_tier)

func is_material_mineable_with_tier(material_key: String, mining_tier: int) -> bool:
    if material_key in [MATERIAL_BEDROCK, MATERIAL_LAVA]:
        return false
    if not _material_can_be_mined(material_key):
        return false
    return mining_tier >= get_required_mining_tier_for_material(material_key)

func get_required_mining_tier_for_material(material_key: String) -> int:
    match material_key:
        MATERIAL_GRASS, MATERIAL_DIRT, MATERIAL_CLAY, MATERIAL_GRAVEL, MATERIAL_LOOSE_STONE, MATERIAL_SOFT_ROCK:
            return MINING_TIER_BASIC
        MATERIAL_HARD_ROCK, MATERIAL_ORE_COAL, MATERIAL_ORE_COPPER, MATERIAL_ORE_IRON:
            return MINING_TIER_HARD_ROCK
        MATERIAL_ORE_SILVER, MATERIAL_ORE_GOLD:
            return MINING_TIER_RARE_ORE
    return MINING_TIER_NONE

func mine_cell(pos: Vector2i, mining_tier: int = MINING_TIER_BASIC) -> bool:
    var cell = get_cell(pos)
    if cell == null or not is_mineable_cell(pos, mining_tier):
        return false
    cell.terrain = TERRAIN_EXCAVATED
    cell.material_key = MATERIAL_AIR
    cell.strata_key = STRATA_SURFACE
    cell.mining_tier_required = MINING_TIER_NONE
    cell.hidden_mine_yield = {}
    return true

func collapse_cell(pos: Vector2i) -> bool:
    var cell = get_cell(pos)
    if cell == null:
        return false
    cell.terrain = TERRAIN_COLLAPSED
    cell.material_key = MATERIAL_HARD_ROCK
    cell.strata_key = STRATA_HARD_ROCK
    cell.mining_tier_required = MINING_TIER_HARD_ROCK
    cell.walkable = false
    cell.resource_id = ""
    cell.hidden_mine_yield = {}
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
    _generate_height_map(seed)
    _generate_river_map(seed)
    _generate_cave_map(seed)
    var resource_count: int = 0
    var tree_count: int = 0
    var berry_count: int = 0
    var stone_count: int = 0
    for z in range(height):
        for x in range(width):
            var cell = get_cell(Vector2i(x, z))
            cell.depth = _depth_for_row(z)
            cell.surface_height = get_surface_height(Vector2i(x, z))
            cell.slope_degrees = get_slope_degrees(Vector2i(x, z))
            var layer: int = _layer_for_row(z)
            cell.walkable = true
            cell.building_id = ""
            cell.hidden_mine_yield = {}
            cell.is_river = false
            cell.river_id = ""
            cell.distance_to_river = get_distance_to_river(Vector2i(x, z))
            cell.water_feature = ""
            cell.is_cave = false
            cell.cave_id = ""
            cell.exposure = "sky" if layer == SURFACE_LAYER else "covered"
            _apply_strata_rule(cell, layer)
            if _is_initial_dirt_cell(x, z):
                cell.terrain = TERRAIN_DIRT
                cell.material_key = MATERIAL_DIRT
                cell.strata_key = STRATA_SOIL
                cell.mining_tier_required = MINING_TIER_BASIC
                cell.resource_id = ""
                continue
            if _is_starting_workyard_cell(x, z):
                cell.resource_id = ""
                continue
            _apply_cave_rule(cell, Vector2i(x, z))
            if cell.is_cave:
                cell.resource_id = ""
                continue
            _apply_hydrology_rule(cell, Vector2i(x, z))
            if cell.is_river or cell.material_key == MATERIAL_CLAY:
                cell.resource_id = ""
                continue
            cell.resource_id = ""
            var resource_roll: int = _noise_percent(x, z, seed, 0x51f00d)
            var forest_density: int = _noise_percent(x, z, seed, 0x0f0e57)
            var stone_density: int = _noise_percent(x, z, seed, 0x5700e5)
            var slope: int = get_slope_degrees(Vector2i(x, z))
            if stone_density >= 82 and slope < 45:
                resource_count += 1
                stone_count += 1
                var rid: String = "resource_%06d" % resource_count
                resource_index[rid] = {
                    "id": rid,
                    "type": "stone",
                    "material_key": MATERIAL_LOOSE_STONE,
                    "position": [x, z],
                    "yield": {"stone": 1},
                    "surface": true,
                    "layer": SURFACE_LAYER,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                if layer == SURFACE_LAYER:
                    cell.material_key = MATERIAL_LOOSE_STONE
                    cell.mining_tier_required = MINING_TIER_BASIC
                    cell.resource_id = rid
            elif forest_density >= 58 and slope < 35:
                resource_count += 1
                tree_count += 1
                var rid: String = "resource_%06d" % resource_count
                var tree_key: String = MATERIAL_TREE_PINE if _noise_percent(x, z, seed, 0x91a7e5) >= 72 else MATERIAL_TREE_OAK
                resource_index[rid] = {
                    "id": rid,
                    "type": "tree",
                    "material_key": tree_key,
                    "position": [x, z],
                    "yield": {"wood": 1},
                    "surface": true,
                    "layer": SURFACE_LAYER,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                if layer == SURFACE_LAYER:
                    cell.material_key = tree_key
                    cell.mining_tier_required = MINING_TIER_NONE
                    cell.resource_id = rid
            elif forest_density >= 34 and forest_density < 58 and resource_roll >= 48 and slope < 20:
                resource_count += 1
                berry_count += 1
                var rid: String = "resource_%06d" % resource_count
                resource_index[rid] = {
                    "id": rid,
                    "type": "berry",
                    "material_key": MATERIAL_BERRY_BUSH,
                    "position": [x, z],
                    "yield": {"food": 1},
                    "surface": true,
                    "layer": SURFACE_LAYER,
                    "worldgen_profile": WORLDGEN_PROFILE,
                }
                if layer == SURFACE_LAYER:
                    cell.material_key = MATERIAL_BERRY_BUSH
                    cell.mining_tier_required = MINING_TIER_NONE
                    cell.resource_id = rid
    if tree_count == 0:
        resource_count = _place_fallback_resource(resource_index, resource_count, "tree")
    if berry_count == 0:
        resource_count = _place_fallback_resource(resource_index, resource_count, "berry")
    if stone_count == 0:
        _place_fallback_resource(resource_index, resource_count, "stone")
    _apply_hidden_ore_pass(seed)

func get_hidden_mine_yield(pos: Vector2i) -> Dictionary:
    var cell = get_cell(pos)
    if cell == null:
        return {}
    return cell.hidden_mine_yield.duplicate(true)

func get_distance_to_river(pos: Vector2i) -> int:
    if river_map.is_empty() or not in_bounds(pos):
        return 999
    var best_distance: int = 999
    var display_row: int = _display_row_for_row(pos.y)
    for key in river_map.keys():
        var raw: Dictionary = river_map[key]
        var river_pos: Array = raw.get("position", [0, 0])
        var river_display_row: int = int(raw.get("display_row", 0))
        var distance: int = absi(pos.x - int(river_pos[0])) + absi(display_row - river_display_row)
        best_distance = mini(best_distance, distance)
    return best_distance

func get_distance_to_cave(pos: Vector2i) -> int:
    if cave_map.is_empty() or not in_bounds(pos):
        return 999
    var best_distance: int = 999
    var display_row: int = _display_row_for_row(pos.y)
    for key in cave_map.keys():
        var raw: Dictionary = cave_map[key]
        var cave_pos: Array = raw.get("position", [0, 0])
        var cave_display_row: int = int(raw.get("display_row", 0))
        var distance: int = absi(pos.x - int(cave_pos[0])) + absi(display_row - cave_display_row) + absi(pos.y - int(cave_pos[1]))
        best_distance = mini(best_distance, distance)
    return best_distance

func _place_fallback_resource(resource_index: Dictionary, resource_count: int, resource_type: String) -> int:
    for z in range(height):
        for x in range(width):
            var layer: int = _layer_for_row(z)
            if _is_starting_workyard_cell(x, z):
                continue
            var slope: int = get_slope_degrees(Vector2i(x, z))
            if resource_type == "tree" and slope >= 35:
                continue
            if resource_type == "berry" and slope >= 20:
                continue
            if resource_type == "stone" and slope >= 45:
                continue
            var cell = get_cell(Vector2i(x, z))
            if cell == null or cell.resource_id != "":
                continue
            resource_count += 1
            var rid: String = "resource_%06d" % resource_count
            var material_key: String = MATERIAL_TREE_OAK
            var produced: Dictionary = {"wood": 1}
            if resource_type == "berry":
                material_key = MATERIAL_BERRY_BUSH
                produced = {"food": 1}
            elif resource_type == "stone":
                material_key = MATERIAL_LOOSE_STONE
                produced = {"stone": 1}
            resource_index[rid] = {
                "id": rid,
                "type": resource_type,
                "material_key": material_key,
                "position": [x, z],
                "yield": produced,
                "surface": true,
                "layer": SURFACE_LAYER,
                "worldgen_profile": WORLDGEN_PROFILE,
            }
            if layer == SURFACE_LAYER:
                cell.material_key = material_key
                cell.mining_tier_required = get_required_mining_tier_for_material(material_key)
                cell.resource_id = rid
            return resource_count
    return resource_count

func _noise_percent(x: int, z: int, seed: int, salt: int) -> int:
    var n: int = int(seed) ^ int(salt) ^ int(x * 374761393) ^ int(z * 668265263)
    n = int((n ^ (n >> 13)) * 1274126177)
    n = int(n ^ (n >> 16))
    return int(abs(n) % 100)

func _generate_height_map(seed: int) -> void:
    height_map = {}
    slope_map = {}
    for z in range(height):
        for x in range(width):
            var pos := Vector2i(x, z)
            height_map[_key(pos)] = _height_for_column(x, z, seed)
    _smooth_height_map(2)
    for z in range(height):
        for x in range(width):
            var pos := Vector2i(x, z)
            slope_map[_key(pos)] = _slope_for_column(x, z)

func _height_for_column(x: int, z: int, seed: int) -> int:
    var continental: int = _noise_percent(int(floor(float(x) / 16.0)), int(floor(float(z) / 16.0)), seed, 0x1a11d)
    var broad: int = _noise_percent(int(floor(float(x) / 8.0)), int(floor(float(z) / 8.0)), seed, 0x2b22d)
    var regional: int = _noise_percent(int(floor(float(x) / 4.0)), int(floor(float(z) / 4.0)), seed, 0x3c33d)
    var blended: int = int(round(float(continental * 6 + broad * 3 + regional) / 10.0))
    return HEIGHT_MIN + int(round(float(blended) * float(HEIGHT_MAX - HEIGHT_MIN) / 99.0))

func _smooth_height_map(passes: int) -> void:
    for pass_index in range(passes):
        var smoothed: Dictionary = {}
        for z in range(height):
            for x in range(width):
                var total: int = 0
                var weight_total: int = 0
                for dz in range(-1, 2):
                    for dx in range(-1, 2):
                        var neighbor := Vector2i(x + dx, z + dz)
                        if not in_bounds(neighbor):
                            continue
                        var weight: int = 4 if dx == 0 and dz == 0 else 2 if dx == 0 or dz == 0 else 1
                        total += int(height_map.get(_key(neighbor), 0)) * weight
                        weight_total += weight
                smoothed[_key(Vector2i(x, z))] = clampi(int(round(float(total) / float(maxi(weight_total, 1)))), HEIGHT_MIN, HEIGHT_MAX)
        height_map = smoothed

func _slope_for_column(x: int, z: int) -> int:
    var here: int = int(height_map.get(_key(Vector2i(x, z)), 0))
    var max_delta: int = 0
    for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
        var neighbor := Vector2i(x + offset.x, z + offset.y)
        if not in_bounds(neighbor):
            continue
        var neighbor_height: int = int(height_map.get(_key(neighbor), here))
        max_delta = maxi(max_delta, absi(neighbor_height - here))
    return clampi(max_delta * 12, 0, 89)

func _generate_river_map(seed: int) -> void:
    river_map = {}
    var surface_rows: Array[int] = _rows_for_layer(SURFACE_LAYER)
    if surface_rows.is_empty():
        return
    var display_row: int = int(_noise_percent(seed, 0, seed, 0x41ee) % surface_rows.size())
    var river_id: String = "river_000001"
    for x in range(STARTING_WORKYARD_CLEAR_X + 1, width):
        var row: int = surface_rows[display_row]
        var pos := Vector2i(x, row)
        var next_display_row: int = display_row
        var meander: int = _noise_percent(x, row, seed, 0x71d3)
        if meander < 28:
            next_display_row -= 1
        elif meander > 72:
            next_display_row += 1
        next_display_row = clampi(next_display_row, 0, surface_rows.size() - 1)
        river_map[_key(pos)] = {
            "river_id": river_id,
            "position": [pos.x, pos.y],
            "display_row": display_row,
            "flow_dir": [1, next_display_row - display_row],
            "order": x - (STARTING_WORKYARD_CLEAR_X + 1),
            "feature": "river",
        }
        display_row = next_display_row

func _generate_cave_map(seed: int) -> void:
    cave_map = {}
    var cave_id: String = "cave_000001"
    for layer in [SOFT_STONE_LAYER, 5]:
        var rows: Array[int] = _rows_for_layer(layer)
        if rows.is_empty():
            continue
        var display_row: int = int(_noise_percent(seed, layer, seed, 0xca2e) % rows.size())
        var start_x: int = STARTING_WORKYARD_CLEAR_X + 2
        var end_x: int = max(start_x + 1, width - 2)
        for x in range(start_x, end_x):
            var row: int = rows[display_row]
            var pos := Vector2i(x, row)
            var cave_noise: int = _noise_percent(x, row, seed, 0xca7e + layer)
            if cave_noise >= 38:
                cave_map[_key(pos)] = {
                    "cave_id": cave_id,
                    "position": [pos.x, pos.y],
                    "layer": layer,
                    "display_row": display_row,
                    "feature": "cave_void",
                }
            var meander: int = _noise_percent(x, row, seed, 0xca9e + layer)
            if meander < 30:
                display_row -= 1
            elif meander > 70:
                display_row += 1
            display_row = clampi(display_row, 0, rows.size() - 1)
    if cave_map.is_empty():
        _place_cave_fallback(seed)

func _place_cave_fallback(seed: int) -> void:
    var rows: Array[int] = _rows_for_layer(SOFT_STONE_LAYER)
    if rows.is_empty():
        return
    var best_pos := Vector2i(-1, -1)
    var best_score: int = -1
    for row in rows:
        for x in range(STARTING_WORKYARD_CLEAR_X + 2, width):
            var score: int = _noise_percent(x, row, seed, 0xca4e)
            if score > best_score:
                best_score = score
                best_pos = Vector2i(x, row)
    if best_pos != Vector2i(-1, -1):
        cave_map[_key(best_pos)] = {
            "cave_id": "cave_000001",
            "position": [best_pos.x, best_pos.y],
            "layer": SOFT_STONE_LAYER,
            "display_row": _display_row_for_row(best_pos.y),
            "feature": "cave_void",
        }

func _apply_hidden_ore_pass(seed: int) -> void:
    var coal_count: int = 0
    var copper_count: int = 0
    var iron_count: int = 0
    for z in range(height):
        for x in range(width):
            var cell = get_cell(Vector2i(x, z))
            if cell == null or str(cell.resource_id) != "":
                continue
            if bool(cell.is_cave) or str(cell.material_key) == MATERIAL_AIR:
                continue
            var layer: int = _layer_for_row(z)
            if str(cell.strata_key) == STRATA_SOFT_ROCK:
                var coal_noise: int = _noise_percent(x, z, seed, 0x0c0a1)
                var copper_noise: int = _noise_percent(x, z, seed, 0x0c0f2)
                if coal_noise >= 90:
                    _set_hidden_mine_yield(cell, MATERIAL_ORE_COAL, "coal", 2)
                    coal_count += 1
                elif copper_noise >= 93:
                    _set_hidden_mine_yield(cell, MATERIAL_ORE_COPPER, "copper_ore", 1)
                    copper_count += 1
            elif str(cell.strata_key) == STRATA_HARD_ROCK:
                var iron_noise: int = _noise_percent(x, z, seed, 0x1f0e)
                if iron_noise >= 88:
                    _set_hidden_mine_yield(cell, MATERIAL_ORE_IRON, "iron_ore", 1)
                    iron_count += 1
    if coal_count == 0:
        _place_hidden_ore_fallback(seed, STRATA_SOFT_ROCK, MATERIAL_ORE_COAL, "coal", 2)
    if copper_count == 0:
        _place_hidden_ore_fallback(seed ^ 0x2211, STRATA_SOFT_ROCK, MATERIAL_ORE_COPPER, "copper_ore", 1)
    if iron_count == 0:
        _place_hidden_ore_fallback(seed ^ 0x4433, STRATA_HARD_ROCK, MATERIAL_ORE_IRON, "iron_ore", 1)

func _set_hidden_mine_yield(cell, ore_material_key: String, item_type: String, quantity: int) -> void:
    cell.hidden_mine_yield = {
        "material_key": ore_material_key,
        "item_type": item_type,
        "quantity": quantity,
    }

func _place_hidden_ore_fallback(seed: int, strata_key: String, ore_material_key: String, item_type: String, quantity: int) -> void:
    var best_cell = null
    var best_score: int = -1
    for z in range(height):
        for x in range(width):
            var cell = get_cell(Vector2i(x, z))
            if cell == null or str(cell.resource_id) != "" or not cell.hidden_mine_yield.is_empty():
                continue
            if bool(cell.is_cave) or str(cell.material_key) == MATERIAL_AIR:
                continue
            if str(cell.strata_key) != strata_key:
                continue
            var score: int = _noise_percent(x, z, seed, 0x0ade)
            if score > best_score:
                best_score = score
                best_cell = cell
    if best_cell != null:
        _set_hidden_mine_yield(best_cell, ore_material_key, item_type, quantity)

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

func _apply_hydrology_rule(cell, pos: Vector2i) -> void:
    if is_river_cell(pos):
        var data: Dictionary = get_river_data(pos)
        cell.is_river = true
        cell.river_id = str(data.get("river_id", "river_000001"))
        cell.water_feature = "riverbed"
        cell.terrain = TERRAIN_DIRT
        cell.material_key = MATERIAL_GRAVEL
        cell.strata_key = STRATA_SURFACE
        cell.mining_tier_required = MINING_TIER_BASIC
        cell.hidden_mine_yield = {}
        return
    if int(cell.distance_to_river) <= 1 and str(cell.material_key) == MATERIAL_DIRT:
        cell.water_feature = "riverbank"
        cell.material_key = MATERIAL_CLAY
        cell.mining_tier_required = MINING_TIER_BASIC

func _apply_cave_rule(cell, pos: Vector2i) -> void:
    if not is_cave_cell(pos):
        return
    var data: Dictionary = get_cave_data(pos)
    if not (str(cell.strata_key) in [STRATA_SOFT_ROCK, STRATA_HARD_ROCK]):
        return
    cell.is_cave = true
    cell.cave_id = str(data.get("cave_id", "cave_000001"))
    cell.exposure = "cave"
    cell.terrain = TERRAIN_EXCAVATED
    cell.material_key = MATERIAL_AIR
    cell.mining_tier_required = MINING_TIER_NONE
    cell.walkable = true
    cell.resource_id = ""
    cell.hidden_mine_yield = {}

func _apply_strata_rule(cell, layer: int) -> void:
    var rule: Dictionary = _strata_rule_for_layer(layer)
    cell.strata_key = str(rule["strata_key"])
    cell.terrain = str(rule["terrain"])
    cell.material_key = str(rule["material_key"])
    cell.mining_tier_required = int(rule["mining_tier_required"])

func _strata_rule_for_layer(layer: int) -> Dictionary:
    if layer == SURFACE_LAYER:
        return {
            "strata_key": STRATA_SURFACE,
            "terrain": TERRAIN_GRASS,
            "material_key": MATERIAL_GRASS,
            "mining_tier_required": MINING_TIER_BASIC,
        }
    if layer == SOFT_STONE_LAYER:
        return {
            "strata_key": STRATA_SOFT_ROCK,
            "terrain": TERRAIN_ROCK,
            "material_key": MATERIAL_SOFT_ROCK,
            "mining_tier_required": MINING_TIER_BASIC,
        }
    if layer <= DEEP_SOIL_LAYER:
        return {
            "strata_key": STRATA_SOIL if layer == 2 else STRATA_DEEP_SOIL,
            "terrain": TERRAIN_DIRT,
            "material_key": MATERIAL_DIRT,
            "mining_tier_required": MINING_TIER_BASIC,
        }
    return {
        "strata_key": STRATA_HARD_ROCK,
        "terrain": TERRAIN_SOLID_ROCK,
        "material_key": MATERIAL_HARD_ROCK,
        "mining_tier_required": MINING_TIER_HARD_ROCK,
    }

func _base_material_for_layer(layer: int) -> String:
    if layer == SURFACE_LAYER:
        return MATERIAL_GRASS
    if layer == SOFT_STONE_LAYER:
        return MATERIAL_SOFT_ROCK
    if layer <= DEEP_SOIL_LAYER:
        return MATERIAL_DIRT
    return MATERIAL_HARD_ROCK

func _base_material_for_cell(cell) -> String:
    if bool(cell.is_river):
        return MATERIAL_GRAVEL
    if str(cell.water_feature) == "riverbank":
        return MATERIAL_CLAY
    match str(cell.strata_key):
        STRATA_SURFACE:
            return MATERIAL_GRASS
        STRATA_SOFT_ROCK:
            return MATERIAL_SOFT_ROCK
        STRATA_HARD_ROCK:
            return MATERIAL_HARD_ROCK
    return _base_material_for_terrain(str(cell.terrain))

func _base_material_for_terrain(terrain: String) -> String:
    match terrain:
        TERRAIN_EXCAVATED:
            return MATERIAL_AIR
        TERRAIN_DIRT:
            return MATERIAL_DIRT
        TERRAIN_ROCK:
            return MATERIAL_SOFT_ROCK
        TERRAIN_SOLID_ROCK:
            return MATERIAL_HARD_ROCK
        TERRAIN_COLLAPSED:
            return MATERIAL_HARD_ROCK
    return MATERIAL_GRASS

func _material_can_be_mined(material_key: String) -> bool:
    return material_key in [
        MATERIAL_GRASS,
        MATERIAL_DIRT,
        MATERIAL_CLAY,
        MATERIAL_GRAVEL,
        MATERIAL_LOOSE_STONE,
        MATERIAL_SOFT_ROCK,
        MATERIAL_HARD_ROCK,
        MATERIAL_ORE_COAL,
        MATERIAL_ORE_COPPER,
        MATERIAL_ORE_IRON,
        MATERIAL_ORE_SILVER,
        MATERIAL_ORE_GOLD,
    ]

func _layer_for_row(row: int) -> int:
    if height <= 0:
        return 1
    return clampi(int(floor(float(row * 5) / float(height))) + 1, 1, 5)

func _depth_for_row(row: int) -> int:
    return 1 - _layer_for_row(row)

func _rows_for_layer(layer: int) -> Array[int]:
    var output: Array[int] = []
    for row in range(height):
        if _layer_for_row(row) == layer:
            output.append(row)
    return output

func _display_row_for_row(row: int) -> int:
    var layer: int = _layer_for_row(row)
    for candidate in range(height):
        if _layer_for_row(candidate) == layer:
            return row - candidate
    return row

func to_canonical_array() -> Array:
    var arr: Array = []
    for z in range(height):
        for x in range(width):
            arr.append(get_cell(Vector2i(x, z)).to_canonical_dict())
    return arr
