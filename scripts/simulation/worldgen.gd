class_name WorldGen
extends RefCounted

const WorldConstantsScript := preload("res://scripts/simulation/world_constants.gd")
const ChunkAddressingScript := preload("res://scripts/simulation/chunk_addressing.gd")

const WORLDGEN_PROFILE := "ironveil_layered_v1"
const WORLD_WIDTH := 16
const SURFACE_LAYER := 1
const SOFT_STONE_LAYER := 3
const INITIAL_DIRT_CLEAR_X := 2
const INITIAL_DIRT_CLEAR_Z := 2
const STARTING_WORKYARD_CLEAR_X := 5
const STARTING_WORKYARD_CLEAR_Z := 3
const HEIGHT_MIN := -2
const HEIGHT_MAX := 6

# Layer index → (depth_y, display_row_count)
const LAYER_DEPTHS := {1: 0, 2: -1, 3: -2, 4: -3, 5: -4}
const LAYER_ROW_COUNTS := {1: 4, 2: 3, 3: 3, 4: 3, 5: 3}

# Writes all world cells into store and populates resource_index.
# store must be a freshly created ChunkedWorldStore.
static func generate(store, resource_index: Dictionary, world_seed: int) -> void:
    resource_index.clear()
    var height_map: Dictionary = {}
    var slope_map: Dictionary = {}
    var river_map: Dictionary = {}
    var cave_map: Dictionary = {}
    _generate_height_map(height_map, slope_map, world_seed)
    _generate_river_map(river_map, world_seed)
    _generate_cave_map(cave_map, world_seed)
    var resource_count: int = 0
    var tree_count: int = 0
    var berry_count: int = 0
    var stone_count: int = 0
    for layer in LAYER_DEPTHS.keys():
        var depth_y: int = LAYER_DEPTHS[layer]
        var row_count: int = LAYER_ROW_COUNTS[layer]
        for display_z in range(row_count):
            for x in range(WORLD_WIDTH):
                var world_cell := Vector3i(x, depth_y, display_z)
                var surface_height: int = _map_get(height_map, x, display_z)
                var slope_deg: int = _map_get(slope_map, x, display_z)
                var is_river_c: bool = river_map.has(_key(x, display_z))
                var river_data: Dictionary = river_map.get(_key(x, display_z), {})
                var is_cave_c: bool = cave_map.has(_key3(x, layer, display_z))
                var cave_data: Dictionary = cave_map.get(_key3(x, layer, display_z), {})
                var exposure: String = "sky" if layer == SURFACE_LAYER else "covered"
                var payload: Dictionary = _base_payload_for_layer(layer, surface_height, slope_deg, exposure)
                _apply_initial_clear(payload, x, display_z, layer)
                if _is_starting_workyard_cell(x, display_z):
                    payload["resource_id"] = ""
                    store.set_cell(world_cell, payload, {"source": "worldgen_v2"})
                    continue
                _apply_cave_rule(payload, is_cave_c, cave_data)
                if bool(payload.get("is_cave", false)):
                    payload["resource_id"] = ""
                    store.set_cell(world_cell, payload, {"source": "worldgen_v2"})
                    continue
                _apply_hydrology_rule(payload, x, display_z, is_river_c, river_data, river_map)
                if bool(payload.get("is_river", false)) or str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_CLAY:
                    payload["resource_id"] = ""
                    store.set_cell(world_cell, payload, {"source": "worldgen_v2"})
                    continue
                payload["resource_id"] = ""
                if layer == SURFACE_LAYER:
                    var resource_roll: int = _noise_percent(x, display_z, world_seed, 0x51f00d)
                    var forest_density: int = _noise_percent(x, display_z, world_seed, 0x0f0e57)
                    var stone_density: int = _noise_percent(x, display_z, world_seed, 0x5700e5)
                    var slope: int = slope_deg
                    if stone_density >= 82 and slope < 45:
                        resource_count += 1
                        stone_count += 1
                        var rid: String = "resource_%06d" % resource_count
                        resource_index[rid] = {
                            "id": rid, "type": "stone",
                            "material_key": WorldConstantsScript.MATERIAL_LOOSE_STONE,
                            "position": [x, display_z],
                            "world_cell": [world_cell.x, world_cell.y, world_cell.z],
                            "yield": {"stone": 1}, "surface": true,
                            "layer": SURFACE_LAYER, "worldgen_profile": WORLDGEN_PROFILE,
                        }
                        payload["material_key"] = WorldConstantsScript.MATERIAL_LOOSE_STONE
                        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_BASIC
                        payload["resource_id"] = rid
                    elif forest_density >= 58 and slope < 35:
                        resource_count += 1
                        tree_count += 1
                        var rid: String = "resource_%06d" % resource_count
                        var tree_key: String = WorldConstantsScript.MATERIAL_TREE_PINE if _noise_percent(x, display_z, world_seed, 0x91a7e5) >= 72 else WorldConstantsScript.MATERIAL_TREE_OAK
                        resource_index[rid] = {
                            "id": rid, "type": "tree",
                            "material_key": tree_key,
                            "position": [x, display_z],
                            "world_cell": [world_cell.x, world_cell.y, world_cell.z],
                            "yield": {"wood": 1}, "surface": true,
                            "layer": SURFACE_LAYER, "worldgen_profile": WORLDGEN_PROFILE,
                        }
                        payload["material_key"] = tree_key
                        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_NONE
                        payload["resource_id"] = rid
                    elif forest_density >= 34 and forest_density < 58 and resource_roll >= 48 and slope < 20:
                        resource_count += 1
                        berry_count += 1
                        var rid: String = "resource_%06d" % resource_count
                        resource_index[rid] = {
                            "id": rid, "type": "berry",
                            "material_key": WorldConstantsScript.MATERIAL_BERRY_BUSH,
                            "position": [x, display_z],
                            "world_cell": [world_cell.x, world_cell.y, world_cell.z],
                            "yield": {"food": 1}, "surface": true,
                            "layer": SURFACE_LAYER, "worldgen_profile": WORLDGEN_PROFILE,
                        }
                        payload["material_key"] = WorldConstantsScript.MATERIAL_BERRY_BUSH
                        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_NONE
                        payload["resource_id"] = rid
                store.set_cell(world_cell, payload, {"source": "worldgen_v2"})
    if tree_count == 0:
        resource_count = _place_fallback_resource(store, resource_index, resource_count, "tree")
    if berry_count == 0:
        resource_count = _place_fallback_resource(store, resource_index, resource_count, "berry")
    if stone_count == 0:
        _place_fallback_resource(store, resource_index, resource_count, "stone")
    _apply_hidden_ore_pass(store, world_seed)
    store.authoritative = true
    store.import_model = "worldgen_direct_v1"

static func _base_payload_for_layer(layer: int, surface_height: int, slope_deg: int, exposure: String) -> Dictionary:
    var strata_rule: Dictionary = _strata_rule_for_layer(layer)
    return {
        "terrain": strata_rule["terrain"],
        "material_key": strata_rule["material_key"],
        "walkable": true,
        "strata_key": strata_rule["strata_key"],
        "mining_tier_required": strata_rule["mining_tier_required"],
        "resource_id": "",
        "building_id": "",
        "hidden_mine_yield": {},
        "is_river": false,
        "river_id": "",
        "distance_to_river": 999,
        "water_feature": "",
        "is_cave": false,
        "cave_id": "",
        "exposure": exposure,
        "surface_height": surface_height,
        "slope_degrees": slope_deg,
    }

static func _apply_initial_clear(payload: Dictionary, x: int, display_z: int, layer: int) -> void:
    if _is_initial_dirt_cell(x, display_z) and layer == SURFACE_LAYER:
        payload["terrain"] = WorldConstantsScript.TERRAIN_DIRT
        payload["material_key"] = WorldConstantsScript.MATERIAL_DIRT
        payload["strata_key"] = WorldConstantsScript.STRATA_SOIL
        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_BASIC
        payload["resource_id"] = ""

static func _apply_cave_rule(payload: Dictionary, is_cave_c: bool, cave_data: Dictionary) -> void:
    if not is_cave_c:
        return
    var strata_key: String = str(payload.get("strata_key", ""))
    if not (strata_key in [WorldConstantsScript.STRATA_SOFT_ROCK, WorldConstantsScript.STRATA_HARD_ROCK]):
        return
    payload["is_cave"] = true
    payload["cave_id"] = str(cave_data.get("cave_id", "cave_000001"))
    payload["exposure"] = "cave"
    payload["terrain"] = WorldConstantsScript.TERRAIN_EXCAVATED
    payload["material_key"] = WorldConstantsScript.MATERIAL_AIR
    payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_NONE
    payload["walkable"] = true
    payload["resource_id"] = ""
    payload["hidden_mine_yield"] = {}

static func _apply_hydrology_rule(payload: Dictionary, x: int, display_z: int, is_river_c: bool, river_data: Dictionary, river_map: Dictionary) -> void:
    var dist: int = _distance_to_river(x, display_z, river_map)
    payload["distance_to_river"] = dist
    if is_river_c:
        payload["is_river"] = true
        payload["river_id"] = str(river_data.get("river_id", "river_000001"))
        payload["water_feature"] = "riverbed"
        payload["terrain"] = WorldConstantsScript.TERRAIN_DIRT
        payload["material_key"] = WorldConstantsScript.MATERIAL_GRAVEL
        payload["strata_key"] = WorldConstantsScript.STRATA_SURFACE
        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_BASIC
        payload["hidden_mine_yield"] = {}
        return
    if dist <= 1 and str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_DIRT:
        payload["water_feature"] = "riverbank"
        payload["material_key"] = WorldConstantsScript.MATERIAL_CLAY
        payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_BASIC

static func _distance_to_river(x: int, display_z: int, river_map: Dictionary) -> int:
    if river_map.is_empty():
        return 999
    var best: int = 999
    for key in river_map.keys():
        var raw: Dictionary = river_map[key]
        var rpos: Array = raw.get("position", [0, 0])
        var d: int = absi(x - int(rpos[0])) + absi(display_z - int(raw.get("display_row", 0)))
        best = mini(best, d)
    return best

static func _place_fallback_resource(store, resource_index: Dictionary, resource_count: int, resource_type: String) -> int:
    for display_z in range(LAYER_ROW_COUNTS[SURFACE_LAYER]):
        for x in range(WORLD_WIDTH):
            if _is_starting_workyard_cell(x, display_z):
                continue
            var world_cell := Vector3i(x, LAYER_DEPTHS[SURFACE_LAYER], display_z)
            var stored: Dictionary = store.get_cell(world_cell)
            if not bool(stored.get("valid", false)):
                continue
            var payload: Dictionary = stored.get("payload", {}).duplicate(true)
            var slope: int = int(payload.get("slope_degrees", 0))
            if resource_type == "tree" and slope >= 35:
                continue
            if resource_type == "berry" and slope >= 20:
                continue
            if resource_type == "stone" and slope >= 45:
                continue
            if str(payload.get("resource_id", "")) != "":
                continue
            resource_count += 1
            var rid: String = "resource_%06d" % resource_count
            var material_key: String = WorldConstantsScript.MATERIAL_TREE_OAK
            var produced: Dictionary = {"wood": 1}
            if resource_type == "berry":
                material_key = WorldConstantsScript.MATERIAL_BERRY_BUSH
                produced = {"food": 1}
            elif resource_type == "stone":
                material_key = WorldConstantsScript.MATERIAL_LOOSE_STONE
                produced = {"stone": 1}
            resource_index[rid] = {
                "id": rid, "type": resource_type,
                "material_key": material_key,
                "position": [x, display_z],
                "world_cell": [world_cell.x, world_cell.y, world_cell.z],
                "yield": produced, "surface": true,
                "layer": SURFACE_LAYER, "worldgen_profile": WORLDGEN_PROFILE,
            }
            payload["material_key"] = material_key
            payload["mining_tier_required"] = _required_mining_tier_for_material(material_key)
            payload["resource_id"] = rid
            store.set_cell(world_cell, payload, {"source": "worldgen_fallback"})
            return resource_count
    return resource_count

static func _apply_hidden_ore_pass(store, world_seed: int) -> void:
    var coal_count: int = 0
    var copper_count: int = 0
    var iron_count: int = 0
    for layer in LAYER_DEPTHS.keys():
        for display_z in range(LAYER_ROW_COUNTS[layer]):
            for x in range(WORLD_WIDTH):
                var world_cell := Vector3i(x, LAYER_DEPTHS[layer], display_z)
                var stored: Dictionary = store.get_cell(world_cell)
                if not bool(stored.get("valid", false)):
                    continue
                var payload: Dictionary = stored.get("payload", {}).duplicate(true)
                if str(payload.get("resource_id", "")) != "":
                    continue
                if bool(payload.get("is_cave", false)) or str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_AIR:
                    continue
                var strata: String = str(payload.get("strata_key", ""))
                if strata == WorldConstantsScript.STRATA_SOFT_ROCK:
                    var coal_noise: int = _noise_percent(x, display_z, world_seed, 0x0c0a1)
                    var copper_noise: int = _noise_percent(x, display_z, world_seed, 0x0c0f2)
                    if coal_noise >= 90:
                        payload["hidden_mine_yield"] = {"material_key": WorldConstantsScript.MATERIAL_ORE_COAL, "item_type": "coal", "quantity": 2}
                        store.set_cell(world_cell, payload, {"source": "worldgen_ore"})
                        coal_count += 1
                    elif copper_noise >= 93:
                        payload["hidden_mine_yield"] = {"material_key": WorldConstantsScript.MATERIAL_ORE_COPPER, "item_type": "copper_ore", "quantity": 1}
                        store.set_cell(world_cell, payload, {"source": "worldgen_ore"})
                        copper_count += 1
                elif strata == WorldConstantsScript.STRATA_HARD_ROCK:
                    var iron_noise: int = _noise_percent(x, display_z, world_seed, 0x1f0e)
                    if iron_noise >= 88:
                        payload["hidden_mine_yield"] = {"material_key": WorldConstantsScript.MATERIAL_ORE_IRON, "item_type": "iron_ore", "quantity": 1}
                        store.set_cell(world_cell, payload, {"source": "worldgen_ore"})
                        iron_count += 1
    if coal_count == 0:
        _place_hidden_ore_fallback(store, world_seed, WorldConstantsScript.STRATA_SOFT_ROCK, WorldConstantsScript.MATERIAL_ORE_COAL, "coal", 2)
    if copper_count == 0:
        _place_hidden_ore_fallback(store, world_seed ^ 0x2211, WorldConstantsScript.STRATA_SOFT_ROCK, WorldConstantsScript.MATERIAL_ORE_COPPER, "copper_ore", 1)
    if iron_count == 0:
        _place_hidden_ore_fallback(store, world_seed ^ 0x4433, WorldConstantsScript.STRATA_HARD_ROCK, WorldConstantsScript.MATERIAL_ORE_IRON, "iron_ore", 1)

static func _place_hidden_ore_fallback(store, world_seed: int, strata_key: String, ore_material_key: String, item_type: String, quantity: int) -> void:
    var best_cell := Vector3i(-1, -1, -1)
    var best_score: int = -1
    for layer in LAYER_DEPTHS.keys():
        for display_z in range(LAYER_ROW_COUNTS[layer]):
            for x in range(WORLD_WIDTH):
                var world_cell := Vector3i(x, LAYER_DEPTHS[layer], display_z)
                var stored: Dictionary = store.get_cell(world_cell)
                if not bool(stored.get("valid", false)):
                    continue
                var payload: Dictionary = stored.get("payload", {})
                if str(payload.get("resource_id", "")) != "" or not payload.get("hidden_mine_yield", {}).is_empty():
                    continue
                if bool(payload.get("is_cave", false)) or str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_AIR:
                    continue
                if str(payload.get("strata_key", "")) != strata_key:
                    continue
                var score: int = _noise_percent(x, display_z, world_seed, 0x0ade)
                if score > best_score:
                    best_score = score
                    best_cell = world_cell
    if best_cell != Vector3i(-1, -1, -1):
        var stored: Dictionary = store.get_cell(best_cell)
        if bool(stored.get("valid", false)):
            var payload: Dictionary = stored.get("payload", {}).duplicate(true)
            payload["hidden_mine_yield"] = {"material_key": ore_material_key, "item_type": item_type, "quantity": quantity}
            store.set_cell(best_cell, payload, {"source": "worldgen_ore_fallback"})

static func _generate_height_map(height_map: Dictionary, slope_map: Dictionary, world_seed: int) -> void:
    for display_z in range(LAYER_ROW_COUNTS[SURFACE_LAYER]):
        for x in range(WORLD_WIDTH):
            height_map[_key(x, display_z)] = _height_for_column(x, display_z, world_seed)
    _smooth_height_map(height_map, 2)
    for display_z in range(LAYER_ROW_COUNTS[SURFACE_LAYER]):
        for x in range(WORLD_WIDTH):
            slope_map[_key(x, display_z)] = _slope_for_column(x, display_z, height_map)

static func _height_for_column(x: int, display_z: int, world_seed: int) -> int:
    var continental: int = _noise_percent(int(floor(float(x) / 16.0)), int(floor(float(display_z) / 16.0)), world_seed, 0x1a11d)
    var broad: int = _noise_percent(int(floor(float(x) / 8.0)), int(floor(float(display_z) / 8.0)), world_seed, 0x2b22d)
    var regional: int = _noise_percent(int(floor(float(x) / 4.0)), int(floor(float(display_z) / 4.0)), world_seed, 0x3c33d)
    var blended: int = int(round(float(continental * 6 + broad * 3 + regional) / 10.0))
    return HEIGHT_MIN + int(round(float(blended) * float(HEIGHT_MAX - HEIGHT_MIN) / 99.0))

static func _smooth_height_map(height_map: Dictionary, passes: int) -> void:
    for _pass in range(passes):
        var smoothed: Dictionary = {}
        for display_z in range(LAYER_ROW_COUNTS[SURFACE_LAYER]):
            for x in range(WORLD_WIDTH):
                var total: int = 0
                var weight_total: int = 0
                for dz in range(-1, 2):
                    for dx in range(-1, 2):
                        var nx: int = x + dx
                        var nz: int = display_z + dz
                        if nx < 0 or nx >= WORLD_WIDTH or nz < 0 or nz >= LAYER_ROW_COUNTS[SURFACE_LAYER]:
                            continue
                        var weight: int = 4 if dx == 0 and dz == 0 else 2 if dx == 0 or dz == 0 else 1
                        total += int(height_map.get(_key(nx, nz), 0)) * weight
                        weight_total += weight
                smoothed[_key(x, display_z)] = clampi(int(round(float(total) / float(maxi(weight_total, 1)))), HEIGHT_MIN, HEIGHT_MAX)
        height_map.clear()
        for k in smoothed:
            height_map[k] = smoothed[k]

static func _slope_for_column(x: int, display_z: int, height_map: Dictionary) -> int:
    var here: int = int(height_map.get(_key(x, display_z), 0))
    var max_delta: int = 0
    for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
        var nx: int = x + offset.x
        var nz: int = display_z + offset.y
        if nx < 0 or nx >= WORLD_WIDTH or nz < 0 or nz >= LAYER_ROW_COUNTS[SURFACE_LAYER]:
            continue
        var neighbor_height: int = int(height_map.get(_key(nx, nz), here))
        max_delta = maxi(max_delta, absi(neighbor_height - here))
    return clampi(max_delta * 12, 0, 89)

static func _generate_river_map(river_map: Dictionary, world_seed: int) -> void:
    var surface_row_count: int = LAYER_ROW_COUNTS[SURFACE_LAYER]
    if surface_row_count == 0:
        return
    var display_row: int = int(_noise_percent(world_seed, 0, world_seed, 0x41ee) % surface_row_count)
    var river_id: String = "river_000001"
    for x in range(STARTING_WORKYARD_CLEAR_X + 1, WORLD_WIDTH):
        var pos_key: String = _key(x, display_row)
        var next_display_row: int = display_row
        var meander: int = _noise_percent(x, display_row, world_seed, 0x71d3)
        if meander < 28:
            next_display_row -= 1
        elif meander > 72:
            next_display_row += 1
        next_display_row = clampi(next_display_row, 0, surface_row_count - 1)
        river_map[pos_key] = {
            "river_id": river_id,
            "position": [x, display_row],
            "display_row": display_row,
            "flow_dir": [1, next_display_row - display_row],
            "order": x - (STARTING_WORKYARD_CLEAR_X + 1),
            "feature": "river",
        }
        display_row = next_display_row

static func _generate_cave_map(cave_map: Dictionary, world_seed: int) -> void:
    var cave_id: String = "cave_000001"
    for layer in [SOFT_STONE_LAYER, 5]:
        var row_count: int = LAYER_ROW_COUNTS.get(layer, 0)
        if row_count == 0:
            continue
        var display_row: int = int(_noise_percent(world_seed, layer, world_seed, 0xca2e) % row_count)
        var start_x: int = STARTING_WORKYARD_CLEAR_X + 2
        var end_x: int = max(start_x + 1, WORLD_WIDTH - 2)
        for x in range(start_x, end_x):
            var cave_noise: int = _noise_percent(x, display_row, world_seed, 0xca7e + layer)
            if cave_noise >= 38:
                cave_map[_key3(x, layer, display_row)] = {
                    "cave_id": cave_id,
                    "position": [x, display_row],
                    "layer": layer,
                    "display_row": display_row,
                    "feature": "cave_void",
                }
            var meander: int = _noise_percent(x, display_row, world_seed, 0xca9e + layer)
            if meander < 30:
                display_row -= 1
            elif meander > 70:
                display_row += 1
            display_row = clampi(display_row, 0, row_count - 1)
    if cave_map.is_empty():
        _place_cave_fallback(cave_map, world_seed)

static func _place_cave_fallback(cave_map: Dictionary, world_seed: int) -> void:
    var layer: int = SOFT_STONE_LAYER
    var row_count: int = LAYER_ROW_COUNTS[layer]
    if row_count == 0:
        return
    var best_pos := Vector2i(-1, -1)
    var best_score: int = -1
    for display_row in range(row_count):
        for x in range(STARTING_WORKYARD_CLEAR_X + 2, WORLD_WIDTH):
            var score: int = _noise_percent(x, display_row, world_seed, 0xca4e)
            if score > best_score:
                best_score = score
                best_pos = Vector2i(x, display_row)
    if best_pos != Vector2i(-1, -1):
        cave_map[_key3(best_pos.x, layer, best_pos.y)] = {
            "cave_id": "cave_000001",
            "position": [best_pos.x, best_pos.y],
            "layer": layer,
            "display_row": best_pos.y,
            "feature": "cave_void",
        }

static func _strata_rule_for_layer(layer: int) -> Dictionary:
    match layer:
        1:
            return {"strata_key": WorldConstantsScript.STRATA_SURFACE, "terrain": WorldConstantsScript.TERRAIN_GRASS, "material_key": WorldConstantsScript.MATERIAL_GRASS, "mining_tier_required": WorldConstantsScript.MINING_TIER_BASIC}
        3:
            return {"strata_key": WorldConstantsScript.STRATA_SOFT_ROCK, "terrain": WorldConstantsScript.TERRAIN_ROCK, "material_key": WorldConstantsScript.MATERIAL_SOFT_ROCK, "mining_tier_required": WorldConstantsScript.MINING_TIER_BASIC}
        2:
            return {"strata_key": WorldConstantsScript.STRATA_SOIL, "terrain": WorldConstantsScript.TERRAIN_DIRT, "material_key": WorldConstantsScript.MATERIAL_DIRT, "mining_tier_required": WorldConstantsScript.MINING_TIER_BASIC}
        4:
            return {"strata_key": WorldConstantsScript.STRATA_DEEP_SOIL, "terrain": WorldConstantsScript.TERRAIN_DIRT, "material_key": WorldConstantsScript.MATERIAL_DIRT, "mining_tier_required": WorldConstantsScript.MINING_TIER_BASIC}
        _:
            return {"strata_key": WorldConstantsScript.STRATA_HARD_ROCK, "terrain": WorldConstantsScript.TERRAIN_SOLID_ROCK, "material_key": WorldConstantsScript.MATERIAL_HARD_ROCK, "mining_tier_required": WorldConstantsScript.MINING_TIER_HARD_ROCK}

static func _required_mining_tier_for_material(material_key: String) -> int:
    match material_key:
        WorldConstantsScript.MATERIAL_GRASS, WorldConstantsScript.MATERIAL_DIRT, WorldConstantsScript.MATERIAL_CLAY, WorldConstantsScript.MATERIAL_GRAVEL, WorldConstantsScript.MATERIAL_LOOSE_STONE, WorldConstantsScript.MATERIAL_SOFT_ROCK:
            return WorldConstantsScript.MINING_TIER_BASIC
        WorldConstantsScript.MATERIAL_HARD_ROCK, WorldConstantsScript.MATERIAL_ORE_COAL, WorldConstantsScript.MATERIAL_ORE_COPPER, WorldConstantsScript.MATERIAL_ORE_IRON:
            return WorldConstantsScript.MINING_TIER_HARD_ROCK
        WorldConstantsScript.MATERIAL_ORE_SILVER, WorldConstantsScript.MATERIAL_ORE_GOLD:
            return WorldConstantsScript.MINING_TIER_RARE_ORE
    return WorldConstantsScript.MINING_TIER_NONE

static func _is_initial_dirt_cell(x: int, display_z: int) -> bool:
    return x <= INITIAL_DIRT_CLEAR_X and display_z <= INITIAL_DIRT_CLEAR_Z

static func _is_starting_workyard_cell(x: int, display_z: int) -> bool:
    return x <= STARTING_WORKYARD_CLEAR_X and display_z <= STARTING_WORKYARD_CLEAR_Z

static func _noise_percent(x: int, z: int, world_seed: int, salt: int) -> int:
    var n: int = int(world_seed) ^ int(salt) ^ int(x * 374761393) ^ int(z * 668265263)
    n = int((n ^ (n >> 13)) * 1274126177)
    n = int(n ^ (n >> 16))
    return int(abs(n) % 100)

static func _key(x: int, display_z: int) -> String:
    return "%d,%d" % [x, display_z]

static func _key3(x: int, layer: int, display_z: int) -> String:
    return "%d,%d,%d" % [x, layer, display_z]

static func _map_get(map: Dictionary, x: int, display_z: int) -> int:
    return int(map.get(_key(x, display_z), 0))
