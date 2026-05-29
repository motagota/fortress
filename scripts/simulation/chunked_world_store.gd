class_name ChunkedWorldStore
extends RefCounted

const ChunkAddressingScript := preload("res://scripts/simulation/chunk_addressing.gd")
const PackedCellCodecScript := preload("res://scripts/simulation/packed_cell_codec.gd")

const STORAGE_MODEL := "chunked_3d_v1"
const CELL_PAYLOAD_SCHEMA := "ironveil_cell_payload_v1"
const CELL_PAYLOAD_ENCODING := "dictionary_payload_v1"
const PACKED_CELL_SCHEMA := "ironveil_packed_cell_v1"
const PROJECTED_IMPORT_MODEL := "projected_world_import_v1"
const AUTHORITATIVE_PROJECTED_IMPORT_MODEL := "authoritative_projected_world_v1"
const ACTUAL_CHUNK_IMPORT_MODEL := "actual_chunk_volume_v1"
const PLAYABLE_CHUNK_IMPORT_MODEL := "playable_chunk_volume_v1"

var chunk_size: int = ChunkAddressingScript.DEFAULT_CHUNK_SIZE
var chunks: Dictionary = {}
var cell_count: int = 0
var source_storage_model: String = ""
var import_model: String = ""
var authoritative: bool = false

func _init(pchunk_size: int = ChunkAddressingScript.DEFAULT_CHUNK_SIZE) -> void:
    chunk_size = pchunk_size

func clear() -> void:
    chunks = {}
    cell_count = 0
    source_storage_model = ""
    import_model = ""
    authoritative = false

func import_projected_world(projected_world) -> Dictionary:
    clear()
    import_model = PROJECTED_IMPORT_MODEL
    if projected_world == null:
        return {
            "valid": false,
            "reason": "projected_world_missing",
            "imported_cells": 0,
            "error_count": 1,
        }
    var metadata: Dictionary = projected_world.get_storage_metadata()
    source_storage_model = str(metadata.get("storage_model", ""))
    var errors: Array = []
    for z in range(int(projected_world.height)):
        for x in range(int(projected_world.width)):
            var view: Dictionary = projected_world.get_projected_cell_storage_view(Vector2i(x, z))
            var result: Dictionary = set_cell_from_storage_view(view)
            if not bool(result.get("valid", false)):
                errors.append(result)
    return {
        "valid": errors.is_empty(),
        "storage_model": STORAGE_MODEL,
        "import_model": import_model,
        "source_storage_model": source_storage_model,
        "cell_payload_schema": CELL_PAYLOAD_SCHEMA,
        "cell_payload_encoding": CELL_PAYLOAD_ENCODING,
        "packed_cell_schema": PACKED_CELL_SCHEMA,
        "chunk_size": chunk_size,
        "chunk_count": chunks.size(),
        "imported_cells": cell_count,
        "error_count": errors.size(),
        "errors": errors,
    }

func import_authoritative_projected_world(projected_world) -> Dictionary:
    var report: Dictionary = import_projected_world(projected_world)
    import_model = AUTHORITATIVE_PROJECTED_IMPORT_MODEL
    authoritative = true
    report["import_model"] = import_model
    report["authoritative"] = authoritative
    return report

func import_actual_chunk_volume(projected_world, chunk_cell: Vector3i = Vector3i(0, -1, 0)) -> Dictionary:
    clear()
    import_model = ACTUAL_CHUNK_IMPORT_MODEL
    if projected_world == null:
        return {
            "valid": false,
            "reason": "projected_world_missing",
            "import_model": import_model,
            "generated_cells": 0,
            "error_count": 1,
        }
    var metadata: Dictionary = projected_world.get_storage_metadata()
    source_storage_model = str(metadata.get("storage_model", ""))
    if not _chunk_fits_projected_bounds(projected_world, chunk_cell):
        return {
            "valid": false,
            "reason": "chunk_outside_projected_xz_bounds",
            "storage_model": STORAGE_MODEL,
            "import_model": import_model,
            "source_storage_model": source_storage_model,
            "chunk_cell": ChunkAddressingScript.vector3i_to_array(chunk_cell),
            "chunk_size": chunk_size,
            "generated_cells": 0,
            "error_count": 1,
        }
    var errors: Array = []
    for local_z in range(chunk_size):
        for local_y in range(chunk_size):
            for local_x in range(chunk_size):
                var local_cell := Vector3i(local_x, local_y, local_z)
                var world_address: Dictionary = ChunkAddressingScript.chunk_local_to_world(chunk_cell, local_cell, chunk_size)
                if not bool(world_address.get("valid", false)):
                    errors.append(world_address)
                    continue
                var world_cell := ChunkAddressingScript.array_to_vector3i(world_address.get("world_cell", []))
                var payload: Dictionary = _payload_for_actual_volume_cell(projected_world, world_cell)
                var source: Dictionary = _source_for_actual_volume_cell(projected_world, world_cell, chunk_cell)
                var result: Dictionary = set_cell(world_cell, payload, source)
                if not bool(result.get("valid", false)):
                    errors.append(result)
    return {
        "valid": errors.is_empty(),
        "storage_model": STORAGE_MODEL,
        "import_model": import_model,
        "source_storage_model": source_storage_model,
        "cell_payload_schema": CELL_PAYLOAD_SCHEMA,
        "cell_payload_encoding": CELL_PAYLOAD_ENCODING,
        "packed_cell_schema": PACKED_CELL_SCHEMA,
        "chunk_size": chunk_size,
        "chunk_cell": ChunkAddressingScript.vector3i_to_array(chunk_cell),
        "chunk_count": chunks.size(),
        "generated_cells": cell_count,
        "expected_cells": chunk_size * chunk_size * chunk_size,
        "error_count": errors.size(),
        "errors": errors,
    }

func import_playable_chunk_volume(projected_world, origin_world_cell: Vector3i = Vector3i(0, -15, 0)) -> Dictionary:
    clear()
    import_model = PLAYABLE_CHUNK_IMPORT_MODEL
    if projected_world == null:
        return {
            "valid": false,
            "reason": "projected_world_missing",
            "import_model": import_model,
            "generated_cells": 0,
            "error_count": 1,
        }
    var metadata: Dictionary = projected_world.get_storage_metadata()
    source_storage_model = str(metadata.get("storage_model", ""))
    if not _volume_fits_projected_xz_bounds(projected_world, origin_world_cell):
        return {
            "valid": false,
            "reason": "volume_outside_projected_xz_bounds",
            "storage_model": STORAGE_MODEL,
            "import_model": import_model,
            "source_storage_model": source_storage_model,
            "origin_world_cell": ChunkAddressingScript.vector3i_to_array(origin_world_cell),
            "chunk_size": chunk_size,
            "generated_cells": 0,
            "error_count": 1,
        }
    var errors: Array = []
    for local_z in range(chunk_size):
        for local_y in range(chunk_size):
            for local_x in range(chunk_size):
                var volume_local_cell := Vector3i(local_x, local_y, local_z)
                var world_cell := origin_world_cell + volume_local_cell
                var payload: Dictionary = _payload_for_playable_volume_cell(projected_world, world_cell, volume_local_cell)
                var source: Dictionary = _source_for_actual_volume_cell(projected_world, world_cell, Vector3i.ZERO)
                source["import_model"] = PLAYABLE_CHUNK_IMPORT_MODEL
                source["volume_local_cell"] = ChunkAddressingScript.vector3i_to_array(volume_local_cell)
                source["origin_world_cell"] = ChunkAddressingScript.vector3i_to_array(origin_world_cell)
                var result: Dictionary = set_cell(world_cell, payload, source)
                if not bool(result.get("valid", false)):
                    errors.append(result)
    return {
        "valid": errors.is_empty(),
        "storage_model": STORAGE_MODEL,
        "import_model": import_model,
        "source_storage_model": source_storage_model,
        "cell_payload_schema": CELL_PAYLOAD_SCHEMA,
        "cell_payload_encoding": CELL_PAYLOAD_ENCODING,
        "packed_cell_schema": PACKED_CELL_SCHEMA,
        "chunk_size": chunk_size,
        "origin_world_cell": ChunkAddressingScript.vector3i_to_array(origin_world_cell),
        "chunk_count": chunks.size(),
        "generated_cells": cell_count,
        "expected_cells": chunk_size * chunk_size * chunk_size,
        "error_count": errors.size(),
        "errors": errors,
    }

func set_cell_from_storage_view(view: Dictionary) -> Dictionary:
    if not bool(view.get("valid", false)):
        return {
            "valid": false,
            "reason": str(view.get("reason", "invalid_storage_view")),
            "view": view.duplicate(true),
        }
    var world_cell := ChunkAddressingScript.array_to_vector3i(view.get("world_cell", []))
    var payload: Dictionary = _payload_from_storage_view(view)
    var source: Dictionary = {
        "projected_cell": view.get("projected_cell", []),
        "display_cell": view.get("display_cell", []),
        "projection_depth": int(view.get("projection_depth", 0)),
        "source_storage_model": str(view.get("storage_model", "")),
    }
    return set_cell(world_cell, payload, source)

func set_cell(world_cell: Vector3i, payload: Dictionary, source: Dictionary = {}) -> Dictionary:
    var address: Dictionary = ChunkAddressingScript.world_to_chunk(world_cell, chunk_size)
    if not bool(address.get("valid", false)):
        return address
    var chunk_cell := ChunkAddressingScript.array_to_vector3i(address.get("chunk_cell", []))
    var local_cell := ChunkAddressingScript.array_to_vector3i(address.get("local_cell", []))
    var chunk_key: String = _coord_key(chunk_cell)
    var local_key: String = _coord_key(local_cell)
    if not chunks.has(chunk_key):
        chunks[chunk_key] = {
            "chunk_cell": address.get("chunk_cell", []),
            "cells": {},
        }
    var chunk: Dictionary = chunks[chunk_key]
    var cells: Dictionary = chunk["cells"]
    if not cells.has(local_key):
        cell_count += 1
    cells[local_key] = {
        "schema": CELL_PAYLOAD_SCHEMA,
        "encoding": CELL_PAYLOAD_ENCODING,
        "world_cell": address.get("world_cell", []),
        "chunk_cell": address.get("chunk_cell", []),
        "local_cell": address.get("local_cell", []),
        "payload": _sorted_dictionary(payload.duplicate(true)),
        "packed_payload": PackedCellCodecScript.pack_payload(payload),
        "source": _sorted_dictionary(source.duplicate(true)),
    }
    return {
        "valid": true,
        "world_cell": address.get("world_cell", []),
        "chunk_cell": address.get("chunk_cell", []),
        "local_cell": address.get("local_cell", []),
    }

func has_cell(world_cell: Vector3i) -> bool:
    return bool(get_cell(world_cell).get("valid", false))

func get_cell(world_cell: Vector3i) -> Dictionary:
    var address: Dictionary = ChunkAddressingScript.world_to_chunk(world_cell, chunk_size)
    if not bool(address.get("valid", false)):
        return address
    var chunk_key: String = _coord_key(ChunkAddressingScript.array_to_vector3i(address.get("chunk_cell", [])))
    var local_key: String = _coord_key(ChunkAddressingScript.array_to_vector3i(address.get("local_cell", [])))
    if not chunks.has(chunk_key):
        return {
            "valid": false,
            "reason": "chunk_not_stored",
            "world_cell": address.get("world_cell", []),
            "chunk_cell": address.get("chunk_cell", []),
            "local_cell": address.get("local_cell", []),
        }
    var cells: Dictionary = chunks[chunk_key]["cells"]
    if not cells.has(local_key):
        return {
            "valid": false,
            "reason": "cell_not_stored",
            "world_cell": address.get("world_cell", []),
            "chunk_cell": address.get("chunk_cell", []),
            "local_cell": address.get("local_cell", []),
        }
    var stored: Dictionary = cells[local_key].duplicate(true)
    stored["valid"] = true
    return stored

func get_chunk(chunk_cell: Vector3i) -> Dictionary:
    var chunk_key: String = _coord_key(chunk_cell)
    if not chunks.has(chunk_key):
        return {
            "valid": false,
            "reason": "chunk_not_stored",
            "chunk_cell": ChunkAddressingScript.vector3i_to_array(chunk_cell),
        }
    var chunk: Dictionary = chunks[chunk_key].duplicate(true)
    chunk["valid"] = true
    return chunk

func get_metadata() -> Dictionary:
    return {
        "storage_model": STORAGE_MODEL,
        "import_model": import_model,
        "source_storage_model": source_storage_model,
        "cell_payload_schema": CELL_PAYLOAD_SCHEMA,
        "cell_payload_encoding": CELL_PAYLOAD_ENCODING,
        "packed_cell_schema": PACKED_CELL_SCHEMA,
        "packed_cell_active": true,
        "authoritative": authoritative,
        "actual_chunk_volume_active": import_model == ACTUAL_CHUNK_IMPORT_MODEL,
        "playable_chunk_volume_active": import_model == PLAYABLE_CHUNK_IMPORT_MODEL,
        "chunk_size": chunk_size,
        "chunk_shape": [chunk_size, chunk_size, chunk_size],
        "chunk_count": chunks.size(),
        "cell_count": cell_count,
    }

func compare_projected_world(projected_world, max_mismatches: int = 50) -> Dictionary:
    if projected_world == null:
        return {
            "valid": false,
            "reason": "projected_world_missing",
            "inspected_cells": 0,
            "expected_cells": 0,
            "stored_cells": cell_count,
            "mismatch_count": 1,
            "missing_count": 0,
            "extra_count": 0,
            "mismatches": [{"type": "projected_world_missing"}],
            "truncated": false,
        }
    var mismatches: Array = []
    var expected_world_keys: Dictionary = {}
    var inspected_cells: int = 0
    var missing_count: int = 0
    for z in range(int(projected_world.height)):
        for x in range(int(projected_world.width)):
            var pos := Vector2i(x, z)
            var view: Dictionary = projected_world.get_projected_cell_storage_view(pos)
            if not bool(view.get("valid", false)):
                _record_mismatch(mismatches, max_mismatches, {
                    "type": "invalid_projected_view",
                    "projected_cell": [pos.x, pos.y],
                    "reason": str(view.get("reason", "")),
                })
                continue
            inspected_cells += 1
            var world_cell: Array = view.get("world_cell", [])
            expected_world_keys[_world_key_from_array(world_cell)] = true
            var stored: Dictionary = get_cell(ChunkAddressingScript.array_to_vector3i(world_cell))
            if not bool(stored.get("valid", false)):
                missing_count += 1
                _record_mismatch(mismatches, max_mismatches, {
                    "type": "missing_cell",
                    "projected_cell": [pos.x, pos.y],
                    "world_cell": world_cell,
                    "reason": str(stored.get("reason", "")),
                })
                continue
            _compare_storage_view_to_stored_cell(view, stored, mismatches, max_mismatches)
    var extra_count: int = 0
    for stored in to_canonical_array():
        var stored_world_cell: Array = stored.get("world_cell", [])
        if not expected_world_keys.has(_world_key_from_array(stored_world_cell)):
            extra_count += 1
            _record_mismatch(mismatches, max_mismatches, {
                "type": "extra_cell",
                "world_cell": stored_world_cell,
                "chunk_cell": stored.get("chunk_cell", []),
                "local_cell": stored.get("local_cell", []),
            })
    var mismatch_count: int = missing_count + extra_count + _count_non_presence_mismatches(mismatches)
    return {
        "valid": mismatch_count == 0,
        "storage_model": STORAGE_MODEL,
        "source_storage_model": source_storage_model,
        "inspected_cells": inspected_cells,
        "expected_cells": int(projected_world.width) * int(projected_world.height),
        "stored_cells": cell_count,
        "mismatch_count": mismatch_count,
        "missing_count": missing_count,
        "extra_count": extra_count,
        "mismatches": mismatches,
        "truncated": mismatches.size() >= max_mismatches and mismatch_count > mismatches.size(),
    }

func compare_projected_cell(projected_world, pos: Vector2i) -> Dictionary:
    if projected_world == null:
        return {
            "valid": false,
            "reason": "projected_world_missing",
            "projected_cell": [pos.x, pos.y],
            "mismatches": [{"type": "projected_world_missing"}],
        }
    var view: Dictionary = projected_world.get_projected_cell_storage_view(pos)
    if not bool(view.get("valid", false)):
        return {
            "valid": false,
            "reason": str(view.get("reason", "")),
            "projected_cell": [pos.x, pos.y],
            "mismatches": [{"type": "invalid_projected_view", "reason": str(view.get("reason", ""))}],
        }
    var stored: Dictionary = get_cell(ChunkAddressingScript.array_to_vector3i(view.get("world_cell", [])))
    var mismatches: Array = []
    if not bool(stored.get("valid", false)):
        _record_mismatch(mismatches, 50, {
            "type": "missing_cell",
            "projected_cell": [pos.x, pos.y],
            "world_cell": view.get("world_cell", []),
            "reason": str(stored.get("reason", "")),
        })
    else:
        _compare_storage_view_to_stored_cell(view, stored, mismatches, 50)
    return {
        "valid": mismatches.is_empty(),
        "projected_cell": [pos.x, pos.y],
        "world_cell": view.get("world_cell", []),
        "mismatch_count": mismatches.size(),
        "mismatches": mismatches,
    }

func validate_packed_payloads(max_mismatches: int = 50) -> Dictionary:
    var mismatches: Array = []
    var inspected_cells: int = 0
    for stored in to_canonical_array():
        inspected_cells += 1
        _compare_payload_to_packed_payload(stored.get("payload", {}), stored.get("packed_payload", {}), stored.get("world_cell", []), [], mismatches, max_mismatches)
    return {
        "valid": mismatches.is_empty(),
        "storage_model": STORAGE_MODEL,
        "packed_cell_schema": PACKED_CELL_SCHEMA,
        "inspected_cells": inspected_cells,
        "mismatch_count": mismatches.size(),
        "mismatches": mismatches,
        "truncated": mismatches.size() >= max_mismatches,
    }

func to_canonical_array() -> Array:
    var keyed_cells: Dictionary = {}
    for chunk_key in chunks.keys():
        var cells: Dictionary = chunks[chunk_key]["cells"]
        for local_key in cells.keys():
            var stored: Dictionary = cells[local_key]
            var world_cell: Array = stored.get("world_cell", [0, 0, 0])
            keyed_cells[_sort_key_for_world_cell(world_cell)] = stored.duplicate(true)
    var keys: Array = keyed_cells.keys()
    keys.sort()
    var output: Array = []
    for key in keys:
        output.append(keyed_cells[key])
    return output

func _payload_from_storage_view(view: Dictionary) -> Dictionary:
    var cell: Dictionary = view.get("cell", {})
    return {
        "terrain": str(cell.get("terrain", "")),
        "material_key": str(cell.get("material_key", "")),
        "walkable": bool(cell.get("walkable", true)),
        "strata_key": str(cell.get("strata_key", "")),
        "mining_tier_required": int(cell.get("mining_tier_required", 0)),
        "resource_id": str(cell.get("resource_id", "")),
        "building_id": str(cell.get("building_id", "")),
        "hidden_mine_yield": cell.get("hidden_mine_yield", {}).duplicate(true),
        "is_river": bool(cell.get("is_river", false)),
        "river_id": str(cell.get("river_id", "")),
        "distance_to_river": int(cell.get("distance_to_river", 999)),
        "water_feature": str(cell.get("water_feature", "")),
        "is_cave": bool(cell.get("is_cave", false)),
        "cave_id": str(cell.get("cave_id", "")),
        "exposure": str(cell.get("exposure", "")),
        "surface_height": int(cell.get("surface_height", 0)),
        "slope_degrees": int(cell.get("slope_degrees", 0)),
    }

func _payload_for_actual_volume_cell(projected_world, world_cell: Vector3i) -> Dictionary:
    if projected_world.has_method("get_projected_cell_for_world_cell"):
        var projected_match: Dictionary = projected_world.get_projected_cell_for_world_cell(world_cell)
        if bool(projected_match.get("valid", false)):
            var projected_cell := Vector2i(int(projected_match.get("projected_cell", [0, 0])[0]), int(projected_match.get("projected_cell", [0, 0])[1]))
            var view: Dictionary = projected_world.get_projected_cell_storage_view(projected_cell)
            if bool(view.get("valid", false)):
                return _payload_from_storage_view(view)
    var xz := Vector2i(world_cell.x, world_cell.z)
    var terrain: String = "solid_rock"
    var material_key: String = "HARD_ROCK"
    var strata_key: String = "hard_rock"
    var mining_tier_required: int = 2
    var exposure: String = "covered"
    if world_cell.y > 0:
        terrain = "excavated"
        material_key = "AIR"
        strata_key = "surface"
        mining_tier_required = 0
        exposure = "sky"
    elif world_cell.y == 0:
        terrain = "grass"
        material_key = "GRASS"
        strata_key = "surface"
        mining_tier_required = 1
        exposure = "sky"
    elif world_cell.y >= -2:
        terrain = "dirt"
        material_key = "DIRT"
        strata_key = "soil"
        mining_tier_required = 1
    elif world_cell.y >= -5:
        terrain = "rock"
        material_key = "SOFT_ROCK"
        strata_key = "soft_rock"
        mining_tier_required = 1
    var surface_height: int = projected_world.get_surface_height(xz) if projected_world.has_method("get_surface_height") else 0
    var slope_degrees: int = projected_world.get_slope_degrees(xz) if projected_world.has_method("get_slope_degrees") else 0
    return {
        "terrain": terrain,
        "material_key": material_key,
        "walkable": material_key != "LAVA" and material_key != "BEDROCK",
        "strata_key": strata_key,
        "mining_tier_required": mining_tier_required,
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
        "slope_degrees": slope_degrees,
    }

func _payload_for_playable_volume_cell(projected_world, world_cell: Vector3i, volume_local_cell: Vector3i) -> Dictionary:
    if volume_local_cell.y == chunk_size - 1:
        return _payload_for_cross_section_surface_cell(projected_world, world_cell, volume_local_cell)
    return _payload_for_cross_section_depth_cell(projected_world, world_cell, volume_local_cell)

func _payload_for_cross_section_surface_cell(projected_world, world_cell: Vector3i, volume_local_cell: Vector3i) -> Dictionary:
    var xz := Vector2i(volume_local_cell.x, volume_local_cell.z)
    var material_key: String = "GRASS"
    var terrain: String = "grass"
    var water_feature: String = ""
    var is_river: bool = false
    if projected_world != null and projected_world.has_method("in_bounds") and projected_world.in_bounds(xz):
        if projected_world.has_method("is_river_cell") and projected_world.is_river_cell(xz):
            material_key = "WATER_FLOW"
            terrain = "dirt"
            water_feature = "riverbed"
            is_river = true
        else:
            var surface_cell = projected_world.get_cell(xz) if projected_world.has_method("get_cell") else null
            if surface_cell != null and str(surface_cell.water_feature) == "riverbank":
                material_key = "CLAY"
                terrain = "dirt"
                water_feature = "riverbank"
    return _cross_section_payload(projected_world, xz, terrain, material_key, "surface", 1, "sky", is_river, water_feature)

func _payload_for_cross_section_depth_cell(projected_world, world_cell: Vector3i, volume_local_cell: Vector3i) -> Dictionary:
    var xz := Vector2i(volume_local_cell.x, volume_local_cell.z)
    var local_y: int = volume_local_cell.y
    var material_key: String = "HARD_ROCK"
    var terrain: String = "solid_rock"
    var strata_key: String = "hard_rock"
    var mining_tier_required: int = 2
    if local_y >= 10:
        terrain = "dirt"
        material_key = _soil_material_for_cross_section(projected_world, xz)
        strata_key = "soil"
        mining_tier_required = 1
    elif local_y == 9:
        terrain = "rock"
        material_key = "ORE_COAL" if _cross_section_ore_present(volume_local_cell, 0x0c0a1, 70) else "SOFT_ROCK"
        strata_key = "soft_rock"
        mining_tier_required = 2 if material_key == "ORE_COAL" else 1
    elif local_y == 8:
        terrain = "rock"
        material_key = "ORE_COPPER" if _cross_section_ore_present(volume_local_cell, 0x0c0f2, 74) else "SOFT_ROCK"
        strata_key = "soft_rock"
        mining_tier_required = 2 if material_key == "ORE_COPPER" else 1
    elif local_y >= 4:
        terrain = "solid_rock"
        material_key = "ORE_IRON" if _cross_section_ore_present(volume_local_cell, 0x1f0e, 78) else "HARD_ROCK"
        strata_key = "hard_rock"
        mining_tier_required = 2
    elif local_y == 3:
        terrain = "solid_rock"
        material_key = "OIL" if _cross_section_ore_present(volume_local_cell, 0x0110, 82) else "ORE_SILVER" if _cross_section_ore_present(volume_local_cell, 0x5176, 78) else "HARD_ROCK"
        strata_key = "hard_rock"
        mining_tier_required = 3 if material_key == "ORE_SILVER" else 2
    elif local_y == 2:
        terrain = "solid_rock"
        material_key = "ORE_GOLD" if _cross_section_ore_present(volume_local_cell, 0x901d, 78) else "HARD_ROCK"
        strata_key = "hard_rock"
        mining_tier_required = 3 if material_key == "ORE_GOLD" else 2
    elif local_y == 1:
        terrain = "solid_rock"
        material_key = "BEDROCK"
        strata_key = "hard_rock"
        mining_tier_required = 0
    else:
        terrain = "collapsed"
        material_key = "LAVA"
        strata_key = "hard_rock"
        mining_tier_required = 0
    return _cross_section_payload(projected_world, xz, terrain, material_key, strata_key, mining_tier_required, "covered", false, "")

func _cross_section_payload(projected_world, xz: Vector2i, terrain: String, material_key: String, strata_key: String, mining_tier_required: int, exposure: String, is_river: bool, water_feature: String) -> Dictionary:
    var surface_height: int = projected_world.get_surface_height(xz) if projected_world != null and projected_world.has_method("get_surface_height") else 0
    var slope_degrees: int = projected_world.get_slope_degrees(xz) if projected_world != null and projected_world.has_method("get_slope_degrees") else 0
    return {
        "terrain": terrain,
        "material_key": material_key,
        "walkable": material_key != "LAVA" and material_key != "BEDROCK",
        "strata_key": strata_key,
        "mining_tier_required": mining_tier_required,
        "resource_id": "",
        "building_id": "",
        "hidden_mine_yield": {},
        "is_river": is_river,
        "river_id": "river_000001" if is_river else "",
        "distance_to_river": projected_world.get_distance_to_river(xz) if projected_world != null and projected_world.has_method("get_distance_to_river") else 999,
        "water_feature": water_feature,
        "is_cave": false,
        "cave_id": "",
        "exposure": exposure,
        "surface_height": surface_height,
        "slope_degrees": slope_degrees,
    }

func _soil_material_for_cross_section(projected_world, xz: Vector2i) -> String:
    if projected_world != null and projected_world.has_method("in_bounds") and projected_world.in_bounds(xz):
        if projected_world.has_method("is_river_cell") and projected_world.is_river_cell(xz):
            return "GRAVEL"
        var surface_cell = projected_world.get_cell(xz) if projected_world.has_method("get_cell") else null
        if surface_cell != null and str(surface_cell.water_feature) == "riverbank":
            return "CLAY"
    return "DIRT"

func _cross_section_ore_present(volume_local_cell: Vector3i, salt: int, threshold: int) -> bool:
    var value: int = abs((volume_local_cell.x * 73856093) ^ (volume_local_cell.y * 19349663) ^ (volume_local_cell.z * 83492791) ^ salt)
    return value % 100 >= threshold

func _source_for_actual_volume_cell(projected_world, world_cell: Vector3i, requested_chunk_cell: Vector3i) -> Dictionary:
    var source: Dictionary = {
        "import_model": ACTUAL_CHUNK_IMPORT_MODEL,
        "requested_chunk_cell": ChunkAddressingScript.vector3i_to_array(requested_chunk_cell),
        "source_storage_model": source_storage_model,
    }
    if projected_world != null and projected_world.has_method("get_projected_cell_for_world_cell"):
        var projected_match: Dictionary = projected_world.get_projected_cell_for_world_cell(world_cell)
        if bool(projected_match.get("valid", false)):
            source["projected_cell"] = projected_match.get("projected_cell", [])
            source["display_cell"] = projected_match.get("display_cell", [])
            source["projection_depth"] = world_cell.y
            source["projection_match"] = true
        else:
            source["projected_cell"] = [world_cell.x, world_cell.z]
            source["display_cell"] = [world_cell.x, world_cell.z]
            source["projection_depth"] = world_cell.y
            source["projection_match"] = false
            source["projection_reason"] = str(projected_match.get("reason", ""))
    return source

func _chunk_fits_projected_bounds(projected_world, chunk_cell: Vector3i) -> bool:
    if projected_world == null:
        return false
    var min_x: int = chunk_cell.x * chunk_size
    var min_z: int = chunk_cell.z * chunk_size
    var max_x: int = min_x + chunk_size - 1
    var max_z: int = min_z + chunk_size - 1
    return min_x >= 0 and min_z >= 0 \
        and max_x < int(projected_world.width) \
        and max_z < int(projected_world.height)

func _volume_fits_projected_xz_bounds(projected_world, origin_world_cell: Vector3i) -> bool:
    if projected_world == null:
        return false
    var min_x: int = origin_world_cell.x
    var min_z: int = origin_world_cell.z
    var max_x: int = min_x + chunk_size - 1
    var max_z: int = min_z + chunk_size - 1
    return min_x >= 0 and min_z >= 0 \
        and max_x < int(projected_world.width) \
        and max_z < int(projected_world.height)

func _compare_storage_view_to_stored_cell(view: Dictionary, stored: Dictionary, mismatches: Array, max_mismatches: int) -> void:
    var projected_cell: Array = view.get("projected_cell", [])
    var expected_payload: Dictionary = _payload_from_storage_view(view)
    var stored_payload: Dictionary = stored.get("payload", {})
    for key in expected_payload.keys():
        if not stored_payload.has(key) or JSON.stringify(_sorted_dictionary({"value": stored_payload.get(key)})) != JSON.stringify(_sorted_dictionary({"value": expected_payload[key]})):
            _record_mismatch(mismatches, max_mismatches, {
                "type": "payload_mismatch",
                "field": str(key),
                "projected_cell": projected_cell,
                "world_cell": view.get("world_cell", []),
                "expected": expected_payload[key],
                "actual": stored_payload.get(key),
            })
    _compare_payload_to_packed_payload(stored_payload, stored.get("packed_payload", {}), view.get("world_cell", []), projected_cell, mismatches, max_mismatches)
    _compare_array_field("world_cell", view.get("world_cell", []), stored.get("world_cell", []), projected_cell, mismatches, max_mismatches)
    _compare_array_field("chunk_cell", view.get("chunk_cell", []), stored.get("chunk_cell", []), projected_cell, mismatches, max_mismatches)
    _compare_array_field("local_cell", view.get("local_cell", []), stored.get("local_cell", []), projected_cell, mismatches, max_mismatches)
    var source: Dictionary = stored.get("source", {})
    _compare_array_field("source.projected_cell", projected_cell, source.get("projected_cell", []), projected_cell, mismatches, max_mismatches)
    _compare_array_field("source.display_cell", view.get("display_cell", []), source.get("display_cell", []), projected_cell, mismatches, max_mismatches)
    if int(view.get("projection_depth", 0)) != int(source.get("projection_depth", 999999)):
        _record_mismatch(mismatches, max_mismatches, {
            "type": "source_mismatch",
            "field": "projection_depth",
            "projected_cell": projected_cell,
            "world_cell": view.get("world_cell", []),
            "expected": int(view.get("projection_depth", 0)),
            "actual": int(source.get("projection_depth", 999999)),
        })
    if str(view.get("storage_model", "")) != str(source.get("source_storage_model", "")):
        _record_mismatch(mismatches, max_mismatches, {
            "type": "source_mismatch",
            "field": "source_storage_model",
            "projected_cell": projected_cell,
            "world_cell": view.get("world_cell", []),
            "expected": str(view.get("storage_model", "")),
            "actual": str(source.get("source_storage_model", "")),
        })

func _compare_payload_to_packed_payload(payload: Dictionary, packed_payload: Dictionary, world_cell: Array, projected_cell: Array, mismatches: Array, max_mismatches: int) -> void:
    if str(packed_payload.get("schema", "")) != PACKED_CELL_SCHEMA:
        _record_mismatch(mismatches, max_mismatches, {
            "type": "packed_payload_mismatch",
            "field": "schema",
            "projected_cell": projected_cell,
            "world_cell": world_cell,
            "expected": PACKED_CELL_SCHEMA,
            "actual": str(packed_payload.get("schema", "")),
        })
        return
    var unpacked: Dictionary = PackedCellCodecScript.unpack_payload(packed_payload)
    for key in payload.keys():
        if not unpacked.has(key) or JSON.stringify(_sorted_dictionary({"value": unpacked.get(key)})) != JSON.stringify(_sorted_dictionary({"value": payload[key]})):
            _record_mismatch(mismatches, max_mismatches, {
                "type": "packed_payload_mismatch",
                "field": str(key),
                "projected_cell": projected_cell,
                "world_cell": world_cell,
                "expected": payload[key],
                "actual": unpacked.get(key),
            })

func _compare_array_field(field: String, expected: Array, actual: Array, projected_cell: Array, mismatches: Array, max_mismatches: int) -> void:
    if expected == actual:
        return
    _record_mismatch(mismatches, max_mismatches, {
        "type": "address_mismatch" if not field.begins_with("source.") else "source_mismatch",
        "field": field,
        "projected_cell": projected_cell,
        "expected": expected,
        "actual": actual,
    })

func _record_mismatch(mismatches: Array, max_mismatches: int, mismatch: Dictionary) -> void:
    if max_mismatches <= 0:
        return
    if mismatches.size() < max_mismatches:
        mismatches.append(_sorted_dictionary(mismatch))

func _count_non_presence_mismatches(mismatches: Array) -> int:
    var total: int = 0
    for mismatch in mismatches:
        var mismatch_type: String = str(mismatch.get("type", ""))
        if mismatch_type in ["missing_cell", "extra_cell"]:
            continue
        total += 1
    return total

func _coord_key(coord: Vector3i) -> String:
    return str(coord.x) + "," + str(coord.y) + "," + str(coord.z)

func _world_key_from_array(world_cell: Array) -> String:
    return str(int(world_cell[0])) + "," + str(int(world_cell[1])) + "," + str(int(world_cell[2]))

func _sort_key_for_world_cell(world_cell: Array) -> String:
    var x: int = int(world_cell[0]) + 1000000
    var y: int = int(world_cell[1]) + 1000000
    var z: int = int(world_cell[2]) + 1000000
    return "%08d,%08d,%08d" % [x, y, z]

func _sorted_dictionary(input: Dictionary) -> Dictionary:
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

func _sorted_array(input: Array) -> Array:
    var output: Array = []
    for value in input:
        if value is Dictionary:
            output.append(_sorted_dictionary(value))
        elif value is Array:
            output.append(_sorted_array(value))
        else:
            output.append(value)
    return output
