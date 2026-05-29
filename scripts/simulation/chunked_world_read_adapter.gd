class_name ChunkedWorldReadAdapter
extends RefCounted

const ChunkAddressingScript := preload("res://scripts/simulation/chunk_addressing.gd")
const ChunkedWorldStoreScript := preload("res://scripts/simulation/chunked_world_store.gd")

var store
var projected_width: int = 0
var projected_height: int = 0
var source_storage_model: String = ""
var import_report: Dictionary = {}

func _init(pstore = null, pprojected_width: int = 0, pprojected_height: int = 0, psource_storage_model: String = "") -> void:
    store = pstore
    projected_width = pprojected_width
    projected_height = pprojected_height
    source_storage_model = psource_storage_model

func import_projected_world(projected_world) -> Dictionary:
    var chunk_store = ChunkedWorldStoreScript.new(16)
    var report: Dictionary = chunk_store.import_projected_world(projected_world)
    var metadata: Dictionary = projected_world.get_storage_metadata() if projected_world != null else {}
    store = chunk_store
    projected_width = int(metadata.get("projected_width", 0))
    projected_height = int(metadata.get("projected_height", 0))
    source_storage_model = str(metadata.get("storage_model", ""))
    import_report = report.duplicate(true)
    return report

func use_authoritative_store(projected_world, authoritative_store, report: Dictionary = {}) -> Dictionary:
    store = authoritative_store
    var metadata: Dictionary = projected_world.get_storage_metadata() if projected_world != null else {}
    projected_width = int(metadata.get("projected_width", 0))
    projected_height = int(metadata.get("projected_height", 0))
    source_storage_model = str(metadata.get("storage_model", ""))
    if report.is_empty() and store != null:
        report = {
            "valid": true,
            "storage_model": str(store.get_metadata().get("storage_model", "")),
            "import_model": str(store.get_metadata().get("import_model", "")),
            "authoritative": bool(store.get_metadata().get("authoritative", false)),
            "imported_cells": int(store.get_metadata().get("cell_count", 0)),
            "error_count": 0,
        }
    import_report = report.duplicate(true)
    return import_report

func is_available() -> bool:
    return store != null and bool(import_report.get("valid", true))

func get_metadata() -> Dictionary:
    var store_metadata: Dictionary = store.get_metadata() if store != null else {}
    var is_authoritative: bool = bool(store_metadata.get("authoritative", false))
    return {
        "adapter_model": "chunked_world_read_adapter_v1",
        "read_only": true,
        "authoritative": is_authoritative,
        "projected_width": projected_width,
        "projected_height": projected_height,
        "source_storage_model": source_storage_model,
        "store_metadata": store_metadata.duplicate(true),
        "import": import_report.duplicate(true),
    }

func get_cell_by_projected_cell(projected_cell: Vector2i) -> Dictionary:
    if projected_cell.x < 0 or projected_cell.y < 0 or projected_cell.x >= projected_width or projected_cell.y >= projected_height:
        return {
            "valid": false,
            "reason": "projected_cell_out_of_bounds",
            "projected_cell": [projected_cell.x, projected_cell.y],
        }
    if store == null:
        return {
            "valid": false,
            "reason": "chunk_store_missing",
            "projected_cell": [projected_cell.x, projected_cell.y],
        }
    for stored in store.to_canonical_array():
        var source: Dictionary = stored.get("source", {})
        if source.get("projected_cell", []) == [projected_cell.x, projected_cell.y]:
            return _read_cell_from_stored(stored)
    return {
        "valid": false,
        "reason": "projected_cell_not_stored",
        "projected_cell": [projected_cell.x, projected_cell.y],
    }

func get_cell_by_world_cell(world_cell: Vector3i) -> Dictionary:
    if store == null:
        return {
            "valid": false,
            "reason": "chunk_store_missing",
            "world_cell": ChunkAddressingScript.vector3i_to_array(world_cell),
        }
    var stored: Dictionary = store.get_cell(world_cell)
    if not bool(stored.get("valid", false)):
        return stored
    return _read_cell_from_stored(stored)

func get_material_key(projected_cell: Vector2i) -> String:
    return str(get_cell_by_projected_cell(projected_cell).get("material_key", ""))

func get_terrain(projected_cell: Vector2i) -> String:
    return str(get_cell_by_projected_cell(projected_cell).get("terrain", ""))

func get_resource_id(projected_cell: Vector2i) -> String:
    return str(get_cell_by_projected_cell(projected_cell).get("resource_id", ""))

func get_projection_depth(projected_cell: Vector2i) -> int:
    return int(get_cell_by_projected_cell(projected_cell).get("projection_depth", 0))

func get_surface_height(projected_cell: Vector2i) -> int:
    return int(get_cell_by_projected_cell(projected_cell).get("surface_height", 0))

func get_slope_degrees(projected_cell: Vector2i) -> int:
    return int(get_cell_by_projected_cell(projected_cell).get("slope_degrees", 0))

func to_projection_payload_array() -> Array:
    var keyed: Dictionary = {}
    if store == null:
        return []
    for stored in store.to_canonical_array():
        var source: Dictionary = stored.get("source", {})
        var projected_cell: Array = source.get("projected_cell", [])
        if projected_cell.size() < 2:
            continue
        var key: String = "%08d,%08d" % [int(projected_cell[1]), int(projected_cell[0])]
        keyed[key] = _read_cell_from_stored(stored)
    var keys: Array = keyed.keys()
    keys.sort()
    var output: Array = []
    for key in keys:
        output.append(keyed[key])
    return output

func _read_cell_from_stored(stored: Dictionary) -> Dictionary:
    var payload: Dictionary = stored.get("payload", {})
    var source: Dictionary = stored.get("source", {})
    var is_authoritative: bool = store != null and bool(store.get_metadata().get("authoritative", false))
    return {
        "valid": true,
        "read_only": true,
        "authoritative": is_authoritative,
        "projected_cell": source.get("projected_cell", []),
        "display_cell": source.get("display_cell", []),
        "projection_depth": int(source.get("projection_depth", 0)),
        "world_cell": stored.get("world_cell", []),
        "chunk_cell": stored.get("chunk_cell", []),
        "local_cell": stored.get("local_cell", []),
        "terrain": str(payload.get("terrain", "")),
        "material_key": str(payload.get("material_key", "")),
        "walkable": bool(payload.get("walkable", true)),
        "strata_key": str(payload.get("strata_key", "")),
        "mining_tier_required": int(payload.get("mining_tier_required", 0)),
        "resource_id": str(payload.get("resource_id", "")),
        "building_id": str(payload.get("building_id", "")),
        "hidden_mine_yield": payload.get("hidden_mine_yield", {}).duplicate(true),
        "is_river": bool(payload.get("is_river", false)),
        "river_id": str(payload.get("river_id", "")),
        "distance_to_river": int(payload.get("distance_to_river", 999)),
        "water_feature": str(payload.get("water_feature", "")),
        "is_cave": bool(payload.get("is_cave", false)),
        "cave_id": str(payload.get("cave_id", "")),
        "exposure": str(payload.get("exposure", "")),
        "surface_height": int(payload.get("surface_height", 0)),
        "slope_degrees": int(payload.get("slope_degrees", 0)),
    }
