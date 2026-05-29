class_name PackedCellCodec
extends RefCounted

const PACKED_SCHEMA := "ironveil_packed_cell_v1"
const UNKNOWN_ID := 255
const UNKNOWN_SMALL_ID := 15

const MATERIAL_TABLE := [
    "", "AIR", "DIRT", "CLAY", "GRAVEL", "WATER_FLOW", "SOFT_ROCK", "HARD_ROCK",
    "BEDROCK", "LAVA", "GRASS", "LOOSE_STONE", "TREE_OAK", "TREE_PINE",
    "BERRY_BUSH", "WILD_WHEAT", "ORE_COAL", "ORE_COPPER", "ORE_IRON",
    "ORE_SILVER", "ORE_GOLD", "OIL"
]
const TERRAIN_TABLE := ["", "dirt", "excavated", "grass", "rock", "solid_rock", "collapsed"]
const STRATA_TABLE := ["", "surface", "soil", "soft_rock", "deep_soil", "hard_rock"]
const EXPOSURE_TABLE := ["", "covered", "sky", "cave"]
const WATER_FEATURE_TABLE := ["", "riverbed", "riverbank"]

static func pack_payload(payload: Dictionary) -> Dictionary:
    var material_key: String = str(payload.get("material_key", ""))
    var terrain: String = str(payload.get("terrain", ""))
    var strata_key: String = str(payload.get("strata_key", ""))
    var exposure: String = str(payload.get("exposure", ""))
    var water_feature: String = str(payload.get("water_feature", ""))

    var material_id: int = _table_id(MATERIAL_TABLE, material_key, UNKNOWN_ID)
    var terrain_id: int = _table_id(TERRAIN_TABLE, terrain, UNKNOWN_ID)
    var strata_id: int = _table_id(STRATA_TABLE, strata_key, UNKNOWN_ID)
    var exposure_id: int = _table_id(EXPOSURE_TABLE, exposure, UNKNOWN_SMALL_ID)
    var water_feature_id: int = _table_id(WATER_FEATURE_TABLE, water_feature, UNKNOWN_SMALL_ID)
    var mining_tier: int = clampi(int(payload.get("mining_tier_required", 0)), 0, 15)
    var surface_height: int = clampi(int(payload.get("surface_height", 0)) + 2048, 0, 4095)
    var slope_degrees: int = clampi(int(payload.get("slope_degrees", 0)), 0, 255)
    var flags: int = 0
    if bool(payload.get("is_river", false)):
        flags |= 1
    if bool(payload.get("is_cave", false)):
        flags |= 2
    if str(payload.get("resource_id", "")) != "":
        flags |= 4
    if not payload.get("hidden_mine_yield", {}).is_empty():
        flags |= 8

    var word0: int = material_id \
        | (terrain_id << 8) \
        | (strata_id << 16) \
        | (mining_tier << 24) \
        | (flags << 28)
    var word1: int = surface_height \
        | (slope_degrees << 12) \
        | (exposure_id << 20) \
        | (water_feature_id << 24)

    var refs: Dictionary = {
        "resource_id": str(payload.get("resource_id", "")),
        "cave_id": str(payload.get("cave_id", "")),
        "hidden_mine_yield": payload.get("hidden_mine_yield", {}).duplicate(true),
    }
    if payload.has("walkable"):
        refs["walkable"] = bool(payload.get("walkable", true))
    if payload.has("building_id"):
        refs["building_id"] = str(payload.get("building_id", ""))
    if payload.has("river_id"):
        refs["river_id"] = str(payload.get("river_id", ""))
    if payload.has("distance_to_river"):
        refs["distance_to_river"] = int(payload.get("distance_to_river", 999))
    if material_id == UNKNOWN_ID:
        refs["material_key"] = material_key
    if terrain_id == UNKNOWN_ID:
        refs["terrain"] = terrain
    if strata_id == UNKNOWN_ID:
        refs["strata_key"] = strata_key
    if exposure_id == UNKNOWN_SMALL_ID:
        refs["exposure"] = exposure
    if water_feature_id == UNKNOWN_SMALL_ID:
        refs["water_feature"] = water_feature

    return {
        "schema": PACKED_SCHEMA,
        "word0": word0,
        "word1": word1,
        "refs": _sorted_dictionary(refs),
    }

static func unpack_payload(packed: Dictionary) -> Dictionary:
    if str(packed.get("schema", "")) != PACKED_SCHEMA:
        return {}
    var word0: int = int(packed.get("word0", 0))
    var word1: int = int(packed.get("word1", 0))
    var refs: Dictionary = packed.get("refs", {})
    var material_id: int = word0 & 0xff
    var terrain_id: int = (word0 >> 8) & 0xff
    var strata_id: int = (word0 >> 16) & 0xff
    var mining_tier: int = (word0 >> 24) & 0x0f
    var flags: int = (word0 >> 28) & 0x0f
    var surface_height: int = (word1 & 0x0fff) - 2048
    var slope_degrees: int = (word1 >> 12) & 0xff
    var exposure_id: int = (word1 >> 20) & 0x0f
    var water_feature_id: int = (word1 >> 24) & 0x0f
    var output: Dictionary = {
        "terrain": _table_value(TERRAIN_TABLE, terrain_id, str(refs.get("terrain", ""))),
        "material_key": _table_value(MATERIAL_TABLE, material_id, str(refs.get("material_key", ""))),
        "strata_key": _table_value(STRATA_TABLE, strata_id, str(refs.get("strata_key", ""))),
        "mining_tier_required": mining_tier,
        "resource_id": str(refs.get("resource_id", "")),
        "hidden_mine_yield": refs.get("hidden_mine_yield", {}).duplicate(true),
        "is_river": (flags & 1) != 0,
        "water_feature": _table_value(WATER_FEATURE_TABLE, water_feature_id, str(refs.get("water_feature", ""))),
        "is_cave": (flags & 2) != 0,
        "cave_id": str(refs.get("cave_id", "")),
        "exposure": _table_value(EXPOSURE_TABLE, exposure_id, str(refs.get("exposure", ""))),
        "surface_height": surface_height,
        "slope_degrees": slope_degrees,
    }
    if refs.has("walkable"):
        output["walkable"] = bool(refs.get("walkable", true))
    if refs.has("building_id"):
        output["building_id"] = str(refs.get("building_id", ""))
    if refs.has("river_id"):
        output["river_id"] = str(refs.get("river_id", ""))
    if refs.has("distance_to_river"):
        output["distance_to_river"] = int(refs.get("distance_to_river", 999))
    return output

static func round_trips(payload: Dictionary) -> bool:
    return JSON.stringify(_sorted_dictionary(unpack_payload(pack_payload(payload)))) == JSON.stringify(_sorted_dictionary(payload.duplicate(true)))

static func _table_id(table: Array, value: String, unknown_id: int) -> int:
    var index: int = table.find(value)
    return index if index >= 0 else unknown_id

static func _table_value(table: Array, index: int, fallback: String) -> String:
    if index >= 0 and index < table.size():
        return str(table[index])
    return fallback

static func _sorted_dictionary(input: Dictionary) -> Dictionary:
    var output: Dictionary = {}
    var keys: Array = input.keys()
    keys.sort()
    for key in keys:
        var value: Variant = input[key]
        if value is Dictionary:
            output[key] = _sorted_dictionary(value)
        elif value is Array:
            output[key] = _sorted_array(value)
        else:
            output[key] = value
    return output

static func _sorted_array(input: Array) -> Array:
    var output: Array = []
    for value in input:
        if value is Dictionary:
            output.append(_sorted_dictionary(value))
        elif value is Array:
            output.append(_sorted_array(value))
        else:
            output.append(value)
    return output
