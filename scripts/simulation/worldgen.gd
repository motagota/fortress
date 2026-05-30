class_name WorldGen
extends RefCounted

# Deterministic, seeded worldgen for the layered floor/wall world.
#
# Floor/wall model (Convention A): a solid underground cell carries BOTH a wall
# (blocks movement) and a floor of the same material (revealed when the wall is
# mined). The walkable ground is the OPEN cell at y = ground_y, whose floor is
# grass and which is exposed to the sky; everything above it is open air.
#
# Passes: surface elevation -> column fill -> cavern carve -> liquids -> ore ->
# flora. All passes use pure hash noise so output depends only on the seed.

const C := preload("res://scripts/simulation/world_constants.gd")

const WORLDGEN_PROFILE := "layered_floorwall_v1"

# Absolute-Y band thresholds (tunable; jittered per column by the passes).
const BEDROCK_TOP := 2          # y <= 2 is solid bedrock floor
const MAGMA_TOP := 12           # 3..12 is the magma sea (open + magma liquid)
const HARDROCK_TOP := 40        # 13..~40 is hard rock
const SOFTROCK_TOP := 58        # ~41..58 is soft rock (above is soil)
const SOIL_DEPTH_MIN := 4
const SOIL_DEPTH_MAX := 9

# Spawn clearing (kept flat and free of plants for the starting units).
const SPAWN_MIN := Vector2i(20, 20)
const SPAWN_MAX := Vector2i(27, 27)

# Writes the whole world into `world` and fills `resources`.
static func generate(world, resources: Dictionary, world_seed: int) -> void:
    resources.clear()
    _generate_surface(world, world_seed)
    _fill_columns(world, world_seed)
    _carve_caverns(world, world_seed)
    _fill_liquids(world, world_seed)
    _seed_ore(world, world_seed)
    _seed_flora(world, resources, world_seed)
    _ensure_starter_resources(world, resources, world_seed)

# --- Surface elevation --------------------------------------------------------

static func _generate_surface(world, world_seed: int) -> void:
    var raw: Dictionary = {}
    for z in range(world.depth):
        for x in range(world.width):
            raw[_key(x, z)] = _elevation_for_column(x, z, world_seed)
    # One smoothing pass to terrace adjacent columns.
    for z in range(world.depth):
        for x in range(world.width):
            var total: int = 0
            var count: int = 0
            for dz in range(-1, 2):
                for dx in range(-1, 2):
                    var nx: int = x + dx
                    var nz: int = z + dz
                    if nx < 0 or nx >= world.width or nz < 0 or nz >= world.depth:
                        continue
                    total += int(raw[_key(nx, nz)])
                    count += 1
            var smoothed: int = int(round(float(total) / float(maxi(count, 1))))
            if _in_spawn(x, z):
                smoothed = C.SURFACE_Y_MEAN
            world.set_surface_y(x, z, clampi(smoothed, C.SURFACE_Y_MIN, C.SURFACE_Y_MAX))
    _enforce_surface_continuity(world)

# Lower peaks until no surface column sits more than one layer above its lowest
# neighbour. This guarantees the whole surface is traversable by ±1 slope steps.
static func _enforce_surface_continuity(world) -> void:
    for _pass in range(C.SURFACE_Y_MAX - C.SURFACE_Y_MIN + 2):
        var changed: bool = false
        for z in range(world.depth):
            for x in range(world.width):
                if _in_spawn(x, z):
                    continue
                var here: int = world.surface_y(x, z)
                var lowest: int = here
                for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
                    var nx: int = x + offset.x
                    var nz: int = z + offset.y
                    if nx < 0 or nx >= world.width or nz < 0 or nz >= world.depth:
                        continue
                    lowest = mini(lowest, world.surface_y(nx, nz))
                if here > lowest + 1:
                    world.set_surface_y(x, z, lowest + 1)
                    changed = true
        if not changed:
            break

static func _elevation_for_column(x: int, z: int, world_seed: int) -> int:
    var continental: int = _noise_percent(int(floor(float(x) / 24.0)), int(floor(float(z) / 24.0)), world_seed, 0x1a11d)
    var broad: int = _noise_percent(int(floor(float(x) / 8.0)), int(floor(float(z) / 8.0)), world_seed, 0x2b22d)
    var regional: int = _noise_percent(int(floor(float(x) / 3.0)), int(floor(float(z) / 3.0)), world_seed, 0x3c33d)
    var blended: int = int(round(float(continental * 6 + broad * 3 + regional) / 10.0))
    return C.SURFACE_Y_MIN + int(round(float(blended) * float(C.SURFACE_Y_MAX - C.SURFACE_Y_MIN) / 99.0))

# --- Base column fill ---------------------------------------------------------

static func _fill_columns(world, world_seed: int) -> void:
    for z in range(world.depth):
        for x in range(world.width):
            var ground_y: int = world.surface_y(x, z)
            var soil_depth: int = SOIL_DEPTH_MIN + _noise_percent(x, z, world_seed, 0x501) % (SOIL_DEPTH_MAX - SOIL_DEPTH_MIN + 1)
            var soil_bottom: int = ground_y - soil_depth
            var hardrock_top: int = HARDROCK_TOP + (_noise_percent(x, z, world_seed, 0x4a4) % 7) - 3
            var softrock_top: int = SOFTROCK_TOP + (_noise_percent(x, z, world_seed, 0x5b5) % 7) - 3
            # Surface (open, walkable, exposed to sky).
            var surface = world.get_cell(Vector3i(x, ground_y, z))
            surface.floor_material = C.MATERIAL_GRASS
            surface.wall_material = C.MATERIAL_NONE
            surface.band = C.BAND_SURFACE
            surface.exposure = "sky"
            # Solid column below the surface.
            for y in range(0, ground_y):
                var cell = world.get_cell(Vector3i(x, y, z))
                _apply_solid_material(cell, x, y, z, ground_y, soil_bottom, hardrock_top, softrock_top)

static func _apply_solid_material(cell, x: int, y: int, z: int, ground_y: int, soil_bottom: int, hardrock_top: int, softrock_top: int) -> void:
    cell.exposure = "dark"
    if y <= BEDROCK_TOP:
        cell.floor_material = C.MATERIAL_BEDROCK
        cell.wall_material = C.MATERIAL_BEDROCK
        cell.band = C.BAND_BEDROCK
    elif y <= MAGMA_TOP:
        # Open magma sea cell (liquid added in the liquid pass).
        cell.floor_material = C.MATERIAL_HARD_ROCK
        cell.wall_material = C.MATERIAL_NONE
        cell.band = C.BAND_MAGMA_SEA
    elif y <= hardrock_top:
        cell.floor_material = C.MATERIAL_HARD_ROCK
        cell.wall_material = C.MATERIAL_HARD_ROCK
        cell.band = C.BAND_STONE
    elif y <= softrock_top and y < soil_bottom:
        cell.floor_material = C.MATERIAL_SOFT_ROCK
        cell.wall_material = C.MATERIAL_SOFT_ROCK
        cell.band = C.BAND_STONE
    else:
        cell.floor_material = C.MATERIAL_DIRT
        cell.wall_material = C.MATERIAL_DIRT
        cell.band = C.BAND_UPPER_EARTH
    cell.mining_tier_required = C.required_mining_tier_for_material(cell.wall_material)

# --- Cavern carving -----------------------------------------------------------

static func _carve_caverns(world, world_seed: int) -> void:
    for y in range(C.CAVERN_Y_MIN, C.CAVERN_Y_MAX + 1):
        for z in range(world.depth):
            for x in range(world.width):
                var cell = world.peek_cell(Vector3i(x, y, z))
                if not cell.has_wall() or cell.band != C.BAND_STONE:
                    continue
                # Blobby 3D noise threshold for connected pockets.
                var n: int = _noise3_percent(x, y, z, world_seed, 0xca7e)
                if n >= 62:
                    var live = world.get_cell(Vector3i(x, y, z))
                    live.wall_material = C.MATERIAL_NONE  # floor stays -> walkable
                    live.band = C.BAND_CAVERN
                    live.mining_tier_required = C.MINING_TIER_NONE

# --- Liquids ------------------------------------------------------------------

static func _fill_liquids(world, world_seed: int) -> void:
    # Magma sea.
    for y in range(BEDROCK_TOP + 1, MAGMA_TOP + 1):
        for z in range(world.depth):
            for x in range(world.width):
                var cell = world.peek_cell(Vector3i(x, y, z))
                if cell.band != C.BAND_MAGMA_SEA:
                    continue
                var live = world.get_cell(Vector3i(x, y, z))
                live.liquid_type = C.LIQUID_MAGMA
                live.liquid_level = C.LIQUID_LEVEL_MAX
    # Cavern lakes: water pools in low cavern cells.
    for y in range(C.CAVERN_Y_MIN, C.CAVERN_Y_MAX + 1):
        for z in range(world.depth):
            for x in range(world.width):
                var cell = world.peek_cell(Vector3i(x, y, z))
                if cell.band != C.BAND_CAVERN or cell.has_wall():
                    continue
                if _noise3_percent(x, y, z, world_seed, 0x1a4e) >= 80:
                    var live = world.get_cell(Vector3i(x, y, z))
                    live.liquid_type = C.LIQUID_WATER
                    live.liquid_level = C.LIQUID_LEVEL_MAX

# --- Hidden ore ---------------------------------------------------------------

static func _seed_ore(world, world_seed: int) -> void:
    for y in range(BEDROCK_TOP + 1, C.SURFACE_Y_MAX):
        if not world.has_layer(y):
            continue
        for z in range(world.depth):
            for x in range(world.width):
                var cell = world.peek_cell(Vector3i(x, y, z))
                if not cell.has_wall():
                    continue
                var wall: String = cell.wall_material
                if wall == C.MATERIAL_SOFT_ROCK:
                    if _noise3_percent(x, y, z, world_seed, 0x0c0a1) >= 90:
                        _set_ore(world, Vector3i(x, y, z), C.MATERIAL_ORE_COAL, "coal", 2)
                    elif _noise3_percent(x, y, z, world_seed, 0x0c0f2) >= 94:
                        _set_ore(world, Vector3i(x, y, z), C.MATERIAL_ORE_COPPER, "copper_ore", 1)
                elif wall == C.MATERIAL_HARD_ROCK:
                    if _noise3_percent(x, y, z, world_seed, 0x1f0e) >= 88:
                        _set_ore(world, Vector3i(x, y, z), C.MATERIAL_ORE_IRON, "iron_ore", 1)
                    elif y <= 22 and _noise3_percent(x, y, z, world_seed, 0x5176) >= 95:
                        _set_ore(world, Vector3i(x, y, z), C.MATERIAL_ORE_SILVER, "silver_ore", 1)
                    elif y <= 18 and _noise3_percent(x, y, z, world_seed, 0x901d) >= 96:
                        _set_ore(world, Vector3i(x, y, z), C.MATERIAL_ORE_GOLD, "gold_ore", 1)

static func _set_ore(world, addr: Vector3i, material: String, item_type: String, quantity: int) -> void:
    var cell = world.get_cell(addr)
    cell.hidden_ore = {"material": material, "item_type": item_type, "quantity": quantity}

# --- Flora --------------------------------------------------------------------

static func _seed_flora(world, resources: Dictionary, world_seed: int) -> void:
    var count: int = 0
    for z in range(world.depth):
        for x in range(world.width):
            if _in_spawn(x, z):
                continue
            var ground_y: int = world.surface_y(x, z)
            var surface = world.peek_cell(Vector3i(x, ground_y, z))
            if surface.exposure != "sky" or surface.has_plant():
                continue
            var forest: int = _noise_percent(x, z, world_seed, 0x0f0e57)
            var roll: int = _noise_percent(x, z, world_seed, 0x51f00d)
            var plant_type: String = ""
            var resource_type: String = ""
            var produced: Dictionary = {}
            if forest >= 60:
                plant_type = C.PLANT_TREE_PINE if _noise_percent(x, z, world_seed, 0x91a7e5) >= 70 else C.PLANT_TREE_OAK
                resource_type = "tree"
                produced = {"wood": 1}
            elif forest >= 36 and roll >= 50:
                plant_type = C.PLANT_BERRY_BUSH
                resource_type = "berry"
                produced = {"food": 1}
            elif forest >= 20 and roll >= 72:
                plant_type = C.PLANT_WILD_WHEAT
                resource_type = "wheat"
                produced = {"food": 1}
            if plant_type == "":
                continue
            count += 1
            var rid: String = "resource_%06d" % count
            var addr := Vector3i(x, ground_y, z)
            _place_plant(world, resources, rid, addr, plant_type, resource_type, produced)

static func _place_plant(world, resources: Dictionary, rid: String, addr: Vector3i, plant_type: String, resource_type: String, produced: Dictionary) -> void:
    var cell = world.get_cell(addr)
    cell.plant = plant_type
    cell.resource_id = rid
    resources[rid] = {
        "id": rid,
        "type": resource_type,
        "material_key": plant_type,
        "world_cell": [addr.x, addr.y, addr.z],
        "yield": produced,
        "worldgen_profile": WORLDGEN_PROFILE,
    }

# Surface stone resources also live on the surface as loose boulders.
static func _ensure_starter_resources(world, resources: Dictionary, world_seed: int) -> void:
    _ensure_one(world, resources, "tree", C.PLANT_TREE_OAK, {"wood": 1})
    _ensure_one(world, resources, "berry", C.PLANT_BERRY_BUSH, {"food": 1})

static func _ensure_one(world, resources: Dictionary, resource_type: String, plant_type: String, produced: Dictionary) -> void:
    for id in resources.keys():
        if str(resources[id].get("type", "")) == resource_type:
            return
    # Place adjacent to the spawn clearing on exposed ground.
    for z in range(SPAWN_MAX.y + 1, world.depth):
        for x in range(SPAWN_MIN.x, SPAWN_MAX.x + 1):
            var ground_y: int = world.surface_y(x, z)
            var surface = world.peek_cell(Vector3i(x, ground_y, z))
            if surface.exposure == "sky" and not surface.has_plant():
                var rid: String = "resource_fallback_%s" % resource_type
                _place_plant(world, resources, rid, Vector3i(x, ground_y, z), plant_type, resource_type, produced)
                return

# --- Helpers ------------------------------------------------------------------

static func _in_spawn(x: int, z: int) -> bool:
    return x >= SPAWN_MIN.x and x <= SPAWN_MAX.x and z >= SPAWN_MIN.y and z <= SPAWN_MAX.y

static func _key(x: int, z: int) -> String:
    return "%d,%d" % [x, z]

static func _noise_percent(x: int, z: int, world_seed: int, salt: int) -> int:
    var n: int = int(world_seed) ^ int(salt) ^ int(x * 374761393) ^ int(z * 668265263)
    n = int((n ^ (n >> 13)) * 1274126177)
    n = int(n ^ (n >> 16))
    return int(abs(n) % 100)

static func _noise3_percent(x: int, y: int, z: int, world_seed: int, salt: int) -> int:
    var n: int = int(world_seed) ^ int(salt) ^ int(x * 374761393) ^ int(y * 1103515245) ^ int(z * 668265263)
    n = int((n ^ (n >> 13)) * 1274126177)
    n = int(n ^ (n >> 16))
    return int(abs(n) % 100)
