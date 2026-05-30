class_name Simulation
extends RefCounted

const WORLD_WIDTH := 16
const WORLD_HEIGHT := 16
const INITIAL_UNIT_COUNT := 3
const HUNGER_EAT_THRESHOLD := 20
const HUNGER_AFTER_EATING := 0
const RECIPE_COOK_MEAL := "cook_meal"
const DEEP_MINING_COLLAPSE_DEPTH := -3
const DEEP_MINING_COLLAPSE_CHANCE_PERCENT := 25
const UNREACHABLE_JOB_RELEASE_TICKS := 4
const INVALID_WORLD_CELL := Vector3i(-2147483648, -2147483648, -2147483648)

const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"
const TOOL_MODE_MINE := "mine"

const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const WorldConstantsScript := preload("res://scripts/simulation/world_constants.gd")
const WorldgenScript := preload("res://scripts/simulation/worldgen.gd")
const UnitScript := preload("res://scripts/simulation/unit.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")
const ZoneScript := preload("res://scripts/simulation/zone.gd")
const StockpileScript := preload("res://scripts/simulation/stockpile.gd")
const BuildingDefinitionScript := preload("res://scripts/simulation/building_definition.gd")
const ConstructionRecordScript := preload("res://scripts/simulation/construction_record.gd")
const JobScript := preload("res://scripts/simulation/job.gd")
const JobBoardScript := preload("res://scripts/simulation/job_board.gd")
const ChunkedWorldStoreScript := preload("res://scripts/simulation/chunked_world_store.gd")
const WorldgenDiagnosticsScript := preload("res://scripts/simulation/worldgen_diagnostics.gd")

var tick: int = 0
var world_seed: int = 1
var rng_streams: Dictionary = {}
var units: Dictionary = {}
var items: Dictionary = {}
var stockpiles: Dictionary = {}
var constructions: Dictionary = {}
var workshop_orders: Dictionary = {}
var resources: Dictionary = {}
var job_board
var chunk_world_store
var command_queue: Array[Dictionary] = []
var id_counters: Dictionary = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0, "stockpile": 0, "construction": 0, "workshop_order": 0}

func initialize_new_game(seed_value: int = 1) -> void:
    tick = 0
    world_seed = seed_value
    rng_streams = {
        "world_rng": RngScript.new(seed_value),
        "unit_rng": RngScript.new(seed_value ^ 0x00c0ffee),
        "event_rng": RngScript.new(seed_value ^ 0x005eeded),
    }
    command_queue = []
    id_counters = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0, "stockpile": 0, "construction": 0, "workshop_order": 0}
    resources = {}
    items = {}
    stockpiles = {}
    constructions = {}
    workshop_orders = {}
    units = {}
    job_board = JobBoardScript.new()
    chunk_world_store = ChunkedWorldStoreScript.new(16)
    WorldgenScript.generate(chunk_world_store, resources, world_seed)
    _spawn_initial_units()

func get_worldgen_storage_diagnostics() -> Dictionary:
    return WorldgenDiagnosticsScript.build_storage_report_for_store(chunk_world_store, {})

func log_worldgen_storage_diagnostics() -> Dictionary:
    var report: Dictionary = get_worldgen_storage_diagnostics()
    WorldgenDiagnosticsScript.log_report(report)
    return report

func _array_to_vector3i(value: Array) -> Vector3i:
    if value.size() < 3:
        return Vector3i.ZERO
    return Vector3i(int(value[0]), int(value[1]), int(value[2]))

# Transitional public API used by main.gd. Will be removed in Phase 5.
func world_cell_for_projected_cell(pos: Vector2i) -> Vector3i:
    return Vector3i(pos.x, 0, pos.y)

func projected_cell_for_world_cell(world_cell: Vector3i) -> Vector2i:
    return Vector2i(world_cell.x, world_cell.z)

func _payload_for_world_cell(world_cell: Vector3i) -> Dictionary:
    if chunk_world_store == null:
        return {}
    var stored: Dictionary = chunk_world_store.get_cell(world_cell)
    if bool(stored.get("valid", false)):
        return stored.get("payload", {}).duplicate(true)
    return {}

func _set_cell_payload(world_cell: Vector3i, payload: Dictionary) -> bool:
    if chunk_world_store == null:
        return false
    return bool(chunk_world_store.set_cell(world_cell, payload, {"source": "simulation_mutation"}).get("valid", false))

func _base_material_for_payload(payload: Dictionary) -> String:
    if bool(payload.get("is_river", false)):
        return WorldConstantsScript.MATERIAL_GRAVEL
    if str(payload.get("water_feature", "")) == "riverbank":
        return WorldConstantsScript.MATERIAL_CLAY
    match str(payload.get("strata_key", "")):
        WorldConstantsScript.STRATA_SURFACE:
            return WorldConstantsScript.MATERIAL_GRASS
        WorldConstantsScript.STRATA_SOFT_ROCK:
            return WorldConstantsScript.MATERIAL_SOFT_ROCK
        WorldConstantsScript.STRATA_HARD_ROCK:
            return WorldConstantsScript.MATERIAL_HARD_ROCK
    match str(payload.get("terrain", "")):
        WorldConstantsScript.TERRAIN_EXCAVATED:
            return WorldConstantsScript.MATERIAL_AIR
        WorldConstantsScript.TERRAIN_DIRT:
            return WorldConstantsScript.MATERIAL_DIRT
        WorldConstantsScript.TERRAIN_ROCK:
            return WorldConstantsScript.MATERIAL_SOFT_ROCK
        WorldConstantsScript.TERRAIN_SOLID_ROCK:
            return WorldConstantsScript.MATERIAL_HARD_ROCK
        WorldConstantsScript.TERRAIN_COLLAPSED:
            return WorldConstantsScript.MATERIAL_HARD_ROCK
    return WorldConstantsScript.MATERIAL_GRASS

func _clear_resource_authoritative(world_cell: Vector3i, resource_id: String = "") -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty():
        return false
    if resource_id != "" and str(payload.get("resource_id", "")) != resource_id:
        return false
    payload["resource_id"] = ""
    payload["material_key"] = _base_material_for_payload(payload)
    payload["mining_tier_required"] = WorldgenScript._required_mining_tier_for_material(str(payload["material_key"]))
    return _set_cell_payload(world_cell, payload)

func _mine_cell_authoritative(world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty() or not _is_mineable_world_cell(world_cell):
        return false
    payload["terrain"] = WorldConstantsScript.TERRAIN_EXCAVATED
    payload["material_key"] = WorldConstantsScript.MATERIAL_AIR
    payload["strata_key"] = WorldConstantsScript.STRATA_SURFACE
    payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_NONE
    payload["resource_id"] = ""
    payload["hidden_mine_yield"] = {}
    return _set_cell_payload(world_cell, payload)

func _collapse_cell_authoritative(world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty():
        return false
    payload["terrain"] = WorldConstantsScript.TERRAIN_COLLAPSED
    payload["material_key"] = WorldConstantsScript.MATERIAL_HARD_ROCK
    payload["strata_key"] = WorldConstantsScript.STRATA_HARD_ROCK
    payload["mining_tier_required"] = WorldConstantsScript.MINING_TIER_HARD_ROCK
    payload["walkable"] = false
    payload["resource_id"] = ""
    payload["hidden_mine_yield"] = {}
    return _set_cell_payload(world_cell, payload)

func _set_building_on_cell_authoritative(world_cell: Vector3i, building_id: String, blocks_movement: bool) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty():
        return false
    payload["building_id"] = building_id
    if blocks_movement:
        payload["walkable"] = false
    return _set_cell_payload(world_cell, payload)

func _world_cell_key(world_cell: Vector3i) -> String:
    return "%012d|%012d|%012d" % [world_cell.x, world_cell.y, world_cell.z]

func _world_cells_from_cells(cells: Array) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    for raw_cell in cells:
        if raw_cell is Vector3i:
            output.append(raw_cell)
        elif raw_cell is Vector2i:
            output.append(Vector3i(raw_cell.x, 0, raw_cell.y))
        elif raw_cell is Array and raw_cell.size() >= 3:
            output.append(Vector3i(int(raw_cell[0]), int(raw_cell[1]), int(raw_cell[2])))
        elif raw_cell is Array and raw_cell.size() >= 2:
            output.append(Vector3i(int(raw_cell[0]), 0, int(raw_cell[1])))
    var unique: Dictionary = {}
    for world_cell in output:
        unique[_world_cell_key(world_cell)] = world_cell
    var keys: Array = unique.keys()
    keys.sort()
    var sorted: Array[Vector3i] = []
    for key in keys:
        sorted.append(unique[key])
    return sorted

func _projected_cells_from_world_cells(world_cells: Array) -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for world_cell in _world_cells_from_cells(world_cells):
        output.append(Vector2i(world_cell.x, world_cell.z))
    return ZoneScript.canonical_cells(output)

func _configure_unit_world_cell(unit) -> void:
    if unit != null and unit.has_method("set_projected_position"):
        unit.set_projected_position(unit.position, Vector3i(unit.position.x, 0, unit.position.y))

func _configure_item_world_cell(item) -> void:
    if item != null and item.has_method("set_projected_position"):
        item.set_projected_position(item.position, Vector3i(item.position.x, 0, item.position.y))

func _configure_job_world_cell(job) -> void:
    if job != null:
        job.target_world_cell = Vector3i(job.target_cell.x, 0, job.target_cell.y)

func _configure_stockpile_world_cells(stockpile) -> void:
    if stockpile == null or not stockpile.has_method("set_world_cells"):
        return
    var world_cells: Array[Vector3i] = []
    for cell in stockpile.cells:
        world_cells.append(Vector3i(cell.x, 0, cell.y))
    stockpile.set_world_cells(world_cells)

func _configure_construction_world_cells(construction) -> void:
    if construction == null:
        return
    construction.target_world_cell = Vector3i(construction.target_cell.x, 0, construction.target_cell.y)
    var world_cells: Array[Vector3i] = []
    for cell in construction.cells:
        world_cells.append(Vector3i(cell.x, 0, cell.y))
    construction.world_cells = world_cells

func _set_unit_world_cell(unit, world_cell: Vector3i) -> void:
    var projected_cell := Vector2i(world_cell.x, world_cell.z)
    if unit != null and unit.has_method("set_projected_position"):
        unit.set_projected_position(projected_cell, world_cell)
    elif unit != null:
        unit.position = projected_cell

func _set_item_world_cell(item, world_cell: Vector3i) -> void:
    var projected_cell := Vector2i(world_cell.x, world_cell.z)
    if item != null and item.has_method("set_projected_position"):
        item.set_projected_position(projected_cell, world_cell)
    elif item != null:
        item.position = projected_cell

func _create_item_at_projected_cell(item_id: String, item_type: String, quantity: int, projected_cell: Vector2i):
    return _create_item_at_world_cell(item_id, item_type, quantity, Vector3i(projected_cell.x, 0, projected_cell.y))

func _create_item_at_world_cell(item_id: String, item_type: String, quantity: int, world_cell: Vector3i):
    var projected_cell: Vector2i = projected_cell_for_world_cell(world_cell)
    var item = ItemScript.new(item_id, item_type, quantity, projected_cell)
    if item.has_method("set_projected_position"):
        item.set_projected_position(projected_cell, world_cell)
    return item

func _spawn_initial_units() -> void:
    var starts: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
    var names: Array[String] = ["Ari", "Bo", "Cy"]
    for i in range(INITIAL_UNIT_COUNT):
        var id: String = allocate_id("unit")
        var unit = UnitScript.new(id, names[i], starts[i])
        _configure_unit_world_cell(unit)
        units[id] = unit

func allocate_id(prefix: String) -> String:
    id_counters[prefix] = int(id_counters.get(prefix, 0)) + 1
    return "%s_%06d" % [prefix, id_counters[prefix]]

func create_stockpile(cells: Array, accepted_item_types: Array, storage_mode: String = "both") -> String:
    return create_stockpile_at_world_cells(_world_cells_from_cells(cells), accepted_item_types, storage_mode)

func create_stockpile_at_world_cells(world_cells: Array, accepted_item_types: Array, storage_mode: String = "both") -> String:
    var valid_cells: Array[Vector2i] = _valid_stockpile_cells(world_cells)
    if valid_cells.is_empty():
        return ""
    if _cells_overlap_stockpiles(valid_cells):
        return ""
    var id: String = allocate_id("stockpile")
    stockpiles[id] = StockpileScript.new(id, accepted_item_types, valid_cells, storage_mode)
    stockpiles[id].set_world_cells(_world_cells_from_cells(valid_cells))
    return id

func designate_stockpile(start_cell: Vector2i, payload: Dictionary) -> String:
    return designate_stockpile_at_world_cell(world_cell_for_projected_cell(start_cell), _with_world_cells_payload(payload))

func designate_stockpile_at_world_cell(start_world_cell: Vector3i, payload: Dictionary) -> String:
    var accepted_types: Array = payload.get("accepted_item_types", ["wood", "stone", "dirt", "food", "meal"])
    var cells: Array = payload.get("world_cells", [start_world_cell])
    if cells.is_empty():
        cells = [start_world_cell]
    return create_stockpile_at_world_cells(cells, accepted_types, str(payload.get("storage_mode", "both")))

func find_stockpile_at_cell(target_cell: Vector2i) -> String:
    return find_stockpile_at_world_cell(world_cell_for_projected_cell(target_cell))

func find_stockpile_at_world_cell(target_world_cell: Vector3i) -> String:
    for stockpile_id in _sorted_ids(stockpiles):
        if stockpiles[stockpile_id].contains_world_cell(target_world_cell):
            return stockpile_id
    return ""

func get_stockpile_resize_handles(stockpile_id: String) -> Array:
    if not stockpiles.has(stockpile_id):
        return []
    var bounds: Dictionary = _stockpile_bounds(stockpiles[stockpile_id].cells)
    if bounds.is_empty():
        return []
    var min_x: int = int(bounds["min_x"])
    var max_x: int = int(bounds["max_x"])
    var min_y: int = int(bounds["min_y"])
    var max_y: int = int(bounds["max_y"])
    var center_x: int = int(floor(float(min_x + max_x) * 0.5))
    var center_y: int = int(floor(float(min_y + max_y) * 0.5))
    var handles: Array = []
    _append_resize_handle(handles, Vector2i(center_x, min_y - 1), "north", 1, "^")
    _append_resize_handle(handles, Vector2i(center_x, max_y + 1), "south", 1, "v")
    _append_resize_handle(handles, Vector2i(min_x - 1, center_y), "west", 1, "<")
    _append_resize_handle(handles, Vector2i(max_x + 1, center_y), "east", 1, ">")
    if min_y < max_y:
        _append_resize_handle(handles, Vector2i(center_x, min_y), "north", -1, "v")
        _append_resize_handle(handles, Vector2i(center_x, max_y), "south", -1, "^")
    if min_x < max_x:
        _append_resize_handle(handles, Vector2i(min_x, center_y), "west", -1, ">")
        _append_resize_handle(handles, Vector2i(max_x, center_y), "east", -1, "<")
    return handles

func _append_resize_handle(handles: Array, cell: Vector2i, side: String, delta: int, label: String) -> void:
    var world_cell: Vector3i = world_cell_for_projected_cell(cell)
    if chunk_world_store == null or not chunk_world_store.has_cell(world_cell):
        return
    handles.append({
        "cell": [cell.x, cell.y],
        "world_cell": [world_cell.x, world_cell.y, world_cell.z],
        "side": side,
        "delta": delta,
        "label": label,
    })

func get_building_definition(building_type: String) -> Dictionary:
    return BuildingDefinitionScript.get_definition(building_type)

func find_workshop_at_cell(target_cell: Vector2i) -> Dictionary:
    return find_workshop_at_world_cell(world_cell_for_projected_cell(target_cell))

func find_workshop_at_world_cell(target_world_cell: Vector3i) -> Dictionary:
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.status != "complete":
            continue
        var definition: Dictionary = get_building_definition(construction.type)
        if not bool(definition.get("workshop", false)):
            continue
        for world_cell in _world_cells_from_cells(construction.world_cells):
            if world_cell == target_world_cell:
                return _workshop_summary(construction)
    return {}

func queue_workshop_recipe_command(command_tick: int, player_id: String, building_id: String, recipe_id: String, payload: Dictionary = {}) -> Dictionary:
    var validation: Dictionary = validate_workshop_recipe(building_id, recipe_id)
    if not bool(validation.get("valid", false)):
        return validation
    var command_payload: Dictionary = payload.duplicate(true)
    command_payload["building_id"] = building_id
    command_payload["recipe_id"] = recipe_id
    validation["command"] = queue_command(command_tick, player_id, "QUEUE_WORKSHOP_RECIPE", Vector2i.ZERO, command_payload)
    return validation

func validate_workshop_recipe(building_id: String, recipe_id: String) -> Dictionary:
    var construction = _completed_construction_for_building(building_id)
    if construction == null:
        return {"valid": false, "warning": "Select a workshop first", "building_id": building_id, "recipe_id": recipe_id}
    var definition: Dictionary = get_building_definition(construction.type)
    if not bool(definition.get("workshop", false)):
        return {"valid": false, "warning": "Selected building is not a workshop", "building_id": building_id, "recipe_id": recipe_id}
    if not definition.get("recipes", []).has(recipe_id):
        return {"valid": false, "warning": "Workshop cannot make that recipe", "building_id": building_id, "recipe_id": recipe_id}
    if _recipe_definition(recipe_id).is_empty():
        return {"valid": false, "warning": "Unknown recipe", "building_id": building_id, "recipe_id": recipe_id}
    return {"valid": true, "warning": "", "building_id": building_id, "recipe_id": recipe_id}

func queue_blueprint_command(command_tick: int, player_id: String, building_type: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    return queue_blueprint_world_command(command_tick, player_id, building_type, world_cell_for_projected_cell(target_cell), _with_world_cells_payload(payload))

func queue_blueprint_world_command(command_tick: int, player_id: String, building_type: String, target_world_cell: Vector3i, payload: Dictionary = {}) -> Dictionary:
    var result: Dictionary = validate_blueprint_world_target(building_type, target_world_cell, payload.get("world_cells", payload.get("cells", [])))
    if not bool(result["valid"]):
        return result
    var command_payload: Dictionary = payload.duplicate(true)
    command_payload["building_type"] = building_type
    command_payload["cells"] = _serialize_cells(result["cells"])
    command_payload["world_cells"] = _serialize_world_cells(result["world_cells"])
    result["command"] = queue_world_command(command_tick, player_id, "PLACE_BLUEPRINT", target_world_cell, command_payload)
    return result

func _legacy_queue_blueprint_command(command_tick: int, player_id: String, building_type: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    var result: Dictionary = validate_blueprint_target(building_type, target_cell, payload.get("cells", []))
    if not bool(result["valid"]):
        return result
    var command_payload: Dictionary = payload.duplicate(true)
    command_payload["building_type"] = building_type
    command_payload["cells"] = _serialize_cells(result["cells"])
    result["command"] = queue_command(command_tick, player_id, "PLACE_BLUEPRINT", target_cell, command_payload)
    return result

func validate_blueprint_target(building_type: String, target_cell: Vector2i, cells: Array = []) -> Dictionary:
    return validate_blueprint_world_target(building_type, world_cell_for_projected_cell(target_cell), _with_world_cells(cells))

func validate_blueprint_world_target(building_type: String, target_world_cell: Vector3i, world_cells: Array = []) -> Dictionary:
    var target_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
    if target_cell == Vector2i(-1, -1):
        return {"valid": false, "warning": "Blueprint target is out of bounds", "construction_id": "", "cells": [], "world_cells": []}
    var definition: Dictionary = get_building_definition(building_type)
    if definition.is_empty():
        return {"valid": false, "warning": "Unknown building type: " + building_type, "construction_id": "", "cells": [], "world_cells": []}
    var existing_id: String = _find_construction_at(building_type, target_cell)
    if existing_id != "":
        if constructions[existing_id].status == "complete":
            return {"valid": false, "warning": "Blueprint area already has a building", "construction_id": existing_id, "cells": _construction_cells(constructions[existing_id]), "world_cells": constructions[existing_id].world_cells}
        return {"valid": true, "warning": "", "construction_id": existing_id, "cells": _construction_cells(constructions[existing_id]), "world_cells": constructions[existing_id].world_cells}
    var footprint_cells: Array[Vector2i] = _building_footprint_cells(building_type, target_cell) if world_cells.is_empty() else _projected_cells_from_world_cells(world_cells)
    if footprint_cells.is_empty():
        return {"valid": false, "warning": "Blueprint target is out of bounds", "construction_id": "", "cells": [], "world_cells": []}
    var footprint_world_cells: Array[Vector3i] = _world_cells_from_cells(footprint_cells)
    if not _cells_match_building_footprint(building_type, footprint_cells):
        return {"valid": false, "warning": "Kitchen needs exactly a clear 3x3 zone", "construction_id": "", "cells": [], "world_cells": []}
    for footprint_world_cell in footprint_world_cells:
        var payload: Dictionary = _payload_for_world_cell(footprint_world_cell)
        if payload.is_empty():
            return {"valid": false, "warning": "Blueprint target is out of bounds", "construction_id": "", "cells": [], "world_cells": []}
        if not bool(payload.get("walkable", false)):
            return {"valid": false, "warning": "Blueprint area must be walkable", "construction_id": "", "cells": [], "world_cells": []}
        if str(payload.get("building_id", "")) != "":
            return {"valid": false, "warning": "Blueprint area already has a building", "construction_id": "", "cells": [], "world_cells": []}
        if str(payload.get("resource_id", "")) != "":
            return {"valid": false, "warning": "Blueprint area contains a resource", "construction_id": "", "cells": [], "world_cells": []}
        if _has_loose_item_at_world_cell(footprint_world_cell):
            return {"valid": false, "warning": "Blueprint area contains a loose item", "construction_id": "", "cells": [], "world_cells": []}
        if _world_cell_in_any_stockpile(footprint_world_cell):
            return {"valid": false, "warning": "Blueprint area contains a stockpile zone", "construction_id": "", "cells": [], "world_cells": []}
    if _has_conflicting_construction_in_cells(footprint_cells):
        return {"valid": false, "warning": "Blueprint area already has a blueprint", "construction_id": "", "cells": [], "world_cells": []}
    return {"valid": true, "warning": "", "construction_id": "", "cells": footprint_cells, "world_cells": footprint_world_cells}

func create_construction(building_type: String, target_cell: Vector2i, priority: int = 1, cells: Array = []) -> Dictionary:
    return create_construction_at_world_cell(building_type, world_cell_for_projected_cell(target_cell), priority, _with_world_cells(cells))

func create_construction_at_world_cell(building_type: String, target_world_cell: Vector3i, priority: int = 1, world_cells: Array = []) -> Dictionary:
    var target_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
    if target_cell == Vector2i(-1, -1):
        return {"ok": false, "warning": "Invalid construction target", "construction_id": ""}
    var validation: Dictionary = validate_blueprint_world_target(building_type, target_world_cell, world_cells)
    if not bool(validation.get("valid", false)):
        return {"ok": false, "warning": str(validation.get("warning", "Invalid construction target")), "construction_id": ""}
    var existing_id: String = str(validation.get("construction_id", ""))
    if existing_id != "":
        return {"ok": true, "warning": "", "construction_id": existing_id}
    var definition: Dictionary = get_building_definition(building_type)
    var id: String = allocate_id("construction")
    constructions[id] = ConstructionRecordScript.new(
        id,
        building_type,
        target_cell,
        definition.get("required_items", {}),
        priority,
        "planned",
        "",
        validation["cells"]
    )
    constructions[id].target_world_cell = target_world_cell
    constructions[id].world_cells = _world_cells_from_cells(validation["world_cells"])
    _try_reserve_construction_resources(id)
    return {"ok": true, "warning": "", "construction_id": id}

func cancel_construction(construction_id: String) -> bool:
    if not constructions.has(construction_id):
        return false
    var construction = constructions[construction_id]
    _release_construction_reservations(construction)
    if construction.build_job_id != "" and job_board.jobs.has(construction.build_job_id):
        var job = job_board.jobs[construction.build_job_id]
        if job.status != "complete":
            job.status = "cancelled"
            job.claimed_by_unit_id = ""
    construction.status = "cancelled"
    construction.build_job_id = ""
    return true

func _try_reserve_construction_resources(construction_id: String) -> bool:
    if not constructions.has(construction_id):
        return false
    var construction = constructions[construction_id]
    if construction.status != "planned" or construction.build_job_id != "":
        return false
    var reserved_item_ids: Array[String] = []
    for item_type in _sorted_ids(construction.required_items):
        var needed: int = int(construction.required_items[item_type])
        var found: int = 0
        for item_id in _sorted_ids(items):
            var item = items[item_id]
            if item.item_type != str(item_type):
                continue
            if item.stockpile_id == "" or item.holder_unit_id != "" or item.reserved_by_job_id != "":
                continue
            if not stockpiles.has(item.stockpile_id) or not stockpiles[item.stockpile_id].can_supply_items():
                continue
            reserved_item_ids.append(item_id)
            found += int(item.quantity)
            if found >= needed:
                break
        if found < needed:
            return false
    var job_id: String = allocate_id("job")
    for item_id in reserved_item_ids:
        if not reserve_item_for_job(item_id, job_id):
            for released_id in reserved_item_ids:
                release_item_reservation(released_id, job_id)
            return false
    reserved_item_ids.sort()
    construction.reserved_item_ids = reserved_item_ids
    construction.build_job_id = job_id
    construction.status = "reserved"
    var job = JobScript.new(job_id, "BUILD_CONSTRUCTION", construction.target_cell, construction.priority)
    _configure_job_world_cell(job)
    var definition: Dictionary = get_building_definition(construction.type)
    job.work_remaining_ticks = int(definition.get("work_ticks", job.work_remaining_ticks))
    job.required_items = {
        "construction_id": construction.id,
        "reserved_item_ids": reserved_item_ids.duplicate(),
        "required_items": construction.required_items.duplicate(true),
    }
    job_board.add_job(job)
    return true

func _release_construction_reservations(construction) -> void:
    var job_id: String = construction.build_job_id
    for item_id in construction.reserved_item_ids:
        release_item_reservation(item_id, job_id)
    construction.reserved_item_ids.clear()

func _find_construction_at(building_type: String, target_cell: Vector2i) -> String:
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.type == building_type and construction.target_cell == target_cell and construction.status != "cancelled":
            return construction_id
    return ""

func _has_conflicting_construction_at(target_cell: Vector2i) -> bool:
    return _has_conflicting_construction_in_cells([target_cell])

func _has_conflicting_construction_in_cells(cells: Array) -> bool:
    var requested: Dictionary = {}
    for cell in cells:
        requested[_cell_key(cell)] = true
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.status == "cancelled":
            continue
        for cell in _construction_cells(construction):
            if requested.has(_cell_key(cell)):
                return true
    return false

func _cell_in_any_stockpile(target_cell: Vector2i) -> bool:
    return _world_cell_in_any_stockpile(world_cell_for_projected_cell(target_cell))

func _world_cell_in_any_stockpile(target_world_cell: Vector3i) -> bool:
    for stockpile_id in _sorted_ids(stockpiles):
        if stockpiles[stockpile_id].contains_world_cell(target_world_cell):
            return true
    return false

func _has_loose_item_at(target_cell: Vector2i) -> bool:
    return _has_loose_item_at_world_cell(world_cell_for_projected_cell(target_cell))

func _has_loose_item_at_world_cell(target_world_cell: Vector3i) -> bool:
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.world_cell == target_world_cell and item.holder_unit_id == "":
            return true
    return false

func assign_item_to_stockpile(item_id: String, stockpile_id: String) -> bool:
    if not items.has(item_id) or not stockpiles.has(stockpile_id):
        return false
    var item = items[item_id]
    var stockpile = stockpiles[stockpile_id]
    if not stockpile.accepts_item_type(item.item_type):
        return false
    if not stockpile.can_store_items():
        return false
    if not stockpile.contains_world_cell(item.world_cell):
        return false
    if _world_cell_has_visible_item(item.world_cell, item_id):
        return false
    item.stockpile_id = stockpile_id
    item.holder_unit_id = ""
    return true

func reserve_item_for_job(item_id: String, job_id: String) -> bool:
    if not items.has(item_id) or job_id == "":
        return false
    var item = items[item_id]
    if item.reserved_by_job_id != "" and item.reserved_by_job_id != job_id:
        return false
    item.reserved_by_job_id = job_id
    return true

func release_item_reservation(item_id: String, job_id: String) -> void:
    if not items.has(item_id):
        return
    var item = items[item_id]
    if item.reserved_by_job_id == job_id:
        item.reserved_by_job_id = ""

func make_command(command_tick: int, player_id: String, command_type: String, target_cell: Vector2i, payload: Dictionary = {}, command_id: String = "") -> Dictionary:
    return make_world_command(command_tick, player_id, command_type, world_cell_for_projected_cell(target_cell), payload, command_id)

func make_world_command(command_tick: int, player_id: String, command_type: String, target_world_cell: Vector3i, payload: Dictionary = {}, command_id: String = "") -> Dictionary:
    var id: String = command_id
    if id == "":
        id = allocate_id("command")
    var target_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
    return {
        "tick": command_tick,
        "player_id": player_id,
        "command_type": command_type,
        "target_world_cell": [target_world_cell.x, target_world_cell.y, target_world_cell.z],
        "target_cell": [target_cell.x, target_cell.y],
        "payload": _sorted_dictionary(payload),
        "command_id": id,
    }

func queue_command(command_tick: int, player_id: String, command_type: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    return queue_world_command(command_tick, player_id, command_type, world_cell_for_projected_cell(target_cell), payload)

func queue_world_command(command_tick: int, player_id: String, command_type: String, target_world_cell: Vector3i, payload: Dictionary = {}) -> Dictionary:
    var command: Dictionary = make_world_command(command_tick, player_id, command_type, target_world_cell, payload)
    queue_existing_command(command)
    return command

func queue_designation_command(command_tick: int, player_id: String, tool_mode: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    return queue_designation_world_command(command_tick, player_id, tool_mode, world_cell_for_projected_cell(target_cell), payload)

func queue_designation_world_command(command_tick: int, player_id: String, tool_mode: String, target_world_cell: Vector3i, payload: Dictionary = {}) -> Dictionary:
    var result: Dictionary = validate_designation_world_target(tool_mode, target_world_cell)
    if not bool(result["valid"]):
        return result
    result["command"] = queue_world_command(command_tick, player_id, str(result["command_type"]), target_world_cell, payload)
    return result

func queue_stockpile_designation_command(command_tick: int, player_id: String, target_cell: Vector2i, accepted_item_types: Array = ["wood", "stone", "dirt", "food", "meal"], cells: Array = [], storage_mode: String = "both") -> Dictionary:
    return queue_stockpile_world_designation_command(command_tick, player_id, world_cell_for_projected_cell(target_cell), accepted_item_types, _with_world_cells(cells), storage_mode)

func queue_stockpile_world_designation_command(command_tick: int, player_id: String, target_world_cell: Vector3i, accepted_item_types: Array = ["wood", "stone", "dirt", "food", "meal"], world_cells: Array = [], storage_mode: String = "both") -> Dictionary:
    var designation_cells: Array = world_cells
    if designation_cells.is_empty():
        designation_cells = [target_world_cell]
    var result: Dictionary = validate_stockpile_world_designation_cells(designation_cells)
    if not bool(result["valid"]):
        return result
    var canonical_mode: String = StockpileScript.canonical_storage_mode(storage_mode)
    if canonical_mode == "":
        return {"valid": false, "warning": "Unknown stockpile storage mode", "stockpile_id": "", "cells": [], "world_cells": []}
    var payload: Dictionary = {"accepted_item_types": accepted_item_types, "cells": _serialize_cells(result["cells"]), "world_cells": _serialize_world_cells(result["world_cells"]), "storage_mode": canonical_mode}
    result["command"] = queue_world_command(command_tick, player_id, "DESIGNATE_STOCKPILE", target_world_cell, payload)
    return result

func queue_stockpile_mode_command(command_tick: int, player_id: String, stockpile_id: String, storage_mode: String) -> Dictionary:
    var result: Dictionary = validate_stockpile_mode(stockpile_id, storage_mode)
    if not bool(result["valid"]):
        return result
    result["command"] = queue_command(command_tick, player_id, "SET_STOCKPILE_MODE", _stockpile_center_cell(stockpile_id), {
        "stockpile_id": stockpile_id,
        "storage_mode": StockpileScript.canonical_storage_mode(storage_mode),
    })
    return result

func validate_stockpile_mode(stockpile_id: String, storage_mode: String) -> Dictionary:
    if not stockpiles.has(stockpile_id):
        return {"valid": false, "warning": "Select a stockpile zone first", "stockpile_id": stockpile_id}
    if StockpileScript.canonical_storage_mode(storage_mode) == "":
        return {"valid": false, "warning": "Unknown stockpile storage mode", "stockpile_id": stockpile_id}
    return {"valid": true, "warning": "", "stockpile_id": stockpile_id}

func set_stockpile_mode(stockpile_id: String, storage_mode: String) -> bool:
    if not stockpiles.has(stockpile_id):
        return false
    return stockpiles[stockpile_id].set_storage_mode(storage_mode)

func queue_stockpile_resize_command(command_tick: int, player_id: String, stockpile_id: String, side: String, delta: int) -> Dictionary:
    var result: Dictionary = validate_stockpile_resize(stockpile_id, side, delta)
    if not bool(result["valid"]):
        return result
    var payload: Dictionary = {
        "stockpile_id": stockpile_id,
        "side": side,
        "delta": delta,
    }
    var target_cell: Vector2i = _stockpile_center_cell(stockpile_id)
    result["command"] = queue_command(command_tick, player_id, "RESIZE_STOCKPILE", target_cell, payload)
    return result

func validate_stockpile_resize(stockpile_id: String, side: String, delta: int) -> Dictionary:
    if not stockpiles.has(stockpile_id):
        return {"valid": false, "warning": "Select a stockpile zone first", "stockpile_id": stockpile_id}
    if not (side in ["north", "south", "west", "east"]):
        return {"valid": false, "warning": "Unknown stockpile resize side", "stockpile_id": stockpile_id}
    if delta != -1 and delta != 1:
        return {"valid": false, "warning": "Unknown stockpile resize direction", "stockpile_id": stockpile_id}
    var resized_cells: Array[Vector2i] = _resized_stockpile_cells(stockpile_id, side, delta)
    if resized_cells.is_empty():
        return {"valid": false, "warning": "Stockpile cannot shrink any further", "stockpile_id": stockpile_id}
    var validation: Dictionary = validate_stockpile_designation_cells(resized_cells, stockpile_id)
    if not bool(validation["valid"]):
        return {"valid": false, "warning": str(validation.get("warning", "Invalid stockpile resize")), "stockpile_id": stockpile_id}
    if validation["cells"].size() != resized_cells.size():
        return {"valid": false, "warning": "Stockpile resize needs walkable cells", "stockpile_id": stockpile_id}
    if delta < 0 and _shrink_would_remove_stockpiled_items(stockpile_id, resized_cells):
        return {"valid": false, "warning": "Cannot shrink a stockpile edge that contains items", "stockpile_id": stockpile_id}
    return {"valid": true, "warning": "", "stockpile_id": stockpile_id, "cells": validation["cells"]}

func resize_stockpile(stockpile_id: String, side: String, delta: int) -> bool:
    var validation: Dictionary = validate_stockpile_resize(stockpile_id, side, delta)
    if not bool(validation["valid"]):
        return false
    var stockpile = stockpiles[stockpile_id]
    stockpile.cells = validation["cells"]
    stockpile.set_world_cells(_world_cells_from_cells(validation["cells"]))
    return true

func validate_stockpile_designation_target(target_cell: Vector2i) -> Dictionary:
    return validate_stockpile_designation_cells([target_cell])

func validate_stockpile_designation_cells(cells: Array, ignored_stockpile_id: String = "") -> Dictionary:
    return validate_stockpile_world_designation_cells(_with_world_cells(cells), ignored_stockpile_id)

func validate_stockpile_world_designation_target(target_world_cell: Vector3i) -> Dictionary:
    return validate_stockpile_world_designation_cells([target_world_cell])

func validate_stockpile_world_designation_cells(world_cells: Array, ignored_stockpile_id: String = "") -> Dictionary:
    var valid_cells: Array[Vector2i] = _valid_stockpile_cells(world_cells)
    if valid_cells.is_empty():
        return {"valid": false, "warning": "Stockpile zone needs at least one walkable cell", "stockpile_id": "", "cells": [], "world_cells": []}
    if _cells_overlap_stockpiles(valid_cells, ignored_stockpile_id):
        return {"valid": false, "warning": "Stockpile zones cannot overlap", "stockpile_id": "", "cells": [], "world_cells": []}
    return {"valid": true, "warning": "", "stockpile_id": "", "cells": valid_cells, "world_cells": _world_cells_from_cells(valid_cells)}

func _valid_stockpile_cells(cells: Array) -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for raw_cell in cells:
        var target_cell: Vector2i
        if raw_cell is Vector2i:
            target_cell = raw_cell
        elif raw_cell is Vector3i:
            target_cell = projected_cell_for_world_cell(raw_cell)
        elif raw_cell is Array and raw_cell.size() >= 3:
            target_cell = projected_cell_for_world_cell(Vector3i(int(raw_cell[0]), int(raw_cell[1]), int(raw_cell[2])))
        elif raw_cell is Array and raw_cell.size() >= 2:
            target_cell = Vector2i(int(raw_cell[0]), int(raw_cell[1]))
        else:
            continue
        if target_cell == Vector2i(-1, -1):
            continue
        if not _is_valid_stockpile_cell(target_cell):
            continue
        output.append(target_cell)
    return ZoneScript.canonical_cells(output)

func _is_valid_stockpile_cell(target_cell: Vector2i) -> bool:
    return _is_valid_stockpile_world_cell(world_cell_for_projected_cell(target_cell))

func _is_valid_stockpile_world_cell(target_world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(target_world_cell)
    return not payload.is_empty() and bool(payload.get("walkable", false))

func _cells_overlap_stockpiles(cells: Array, ignored_stockpile_id: String = "") -> bool:
    var requested: Dictionary = {}
    for cell in ZoneScript.canonical_cells(cells):
        requested[_cell_key(cell)] = true
    for stockpile_id in _sorted_ids(stockpiles):
        if stockpile_id == ignored_stockpile_id:
            continue
        var stockpile = stockpiles[stockpile_id]
        for cell in stockpile.cells:
            if requested.has(_cell_key(cell)):
                return true
    return false

func validate_designation_target(tool_mode: String, target_cell: Vector2i) -> Dictionary:
    return validate_designation_world_target(tool_mode, world_cell_for_projected_cell(target_cell))

func validate_designation_world_target(tool_mode: String, target_world_cell: Vector3i) -> Dictionary:
    var target_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
    var spec: Dictionary = _designation_spec_for_tool_mode(tool_mode)
    if spec.is_empty():
        return {"valid": false, "warning": "Unknown designation tool: " + tool_mode, "command_type": ""}
    if target_cell == Vector2i(-1, -1):
        return {"valid": false, "warning": "Designation target is out of bounds", "command_type": str(spec["command_type"])}
    if tool_mode == TOOL_MODE_MINE:
        return _validate_mine_designation_world_target(target_world_cell, spec)
    var payload: Dictionary = _payload_for_world_cell(target_world_cell)
    if payload.is_empty():
        return {"valid": false, "warning": "Select a cell with " + str(spec["resource_label"]), "command_type": str(spec["command_type"])}
    var resource_id: String = _resource_id_at_world_cell(target_world_cell, str(spec["resource_type"]))
    if resource_id == "":
        return {"valid": false, "warning": "Select a cell with " + str(spec["resource_label"]), "command_type": str(spec["command_type"])}
    var resource: Dictionary = resources.get(resource_id, {})
    if resource.get("type", "") != spec["resource_type"]:
        return {"valid": false, "warning": "Select a " + str(spec["resource_label"]) + " target", "command_type": str(spec["command_type"])}
    return {"valid": true, "warning": "", "command_type": str(spec["command_type"]), "target_world_cell": [target_world_cell.x, target_world_cell.y, target_world_cell.z]}

func _designation_spec_for_tool_mode(tool_mode: String) -> Dictionary:
    match tool_mode:
        TOOL_MODE_GATHER_WOOD:
            return {"resource_type": "tree", "resource_label": "tree", "command_type": "DESIGNATE_CHOP"}
        TOOL_MODE_GATHER_STONE:
            return {"resource_type": "stone", "resource_label": "stone", "command_type": "DESIGNATE_GATHER_STONE"}
        TOOL_MODE_GATHER_FOOD:
            return {"resource_type": "berry", "resource_label": "berry", "command_type": "DESIGNATE_GATHER_FOOD"}
        TOOL_MODE_MINE:
            return {"resource_label": "grass, dirt, or surface rock", "command_type": "DESIGNATE_MINE"}
    return {}

func _validate_mine_designation_target(target_cell: Vector2i, spec: Dictionary) -> Dictionary:
    return _validate_mine_designation_world_target(world_cell_for_projected_cell(target_cell), spec)

func _validate_mine_designation_world_target(target_world_cell: Vector3i, spec: Dictionary) -> Dictionary:
    var target_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
    var payload: Dictionary = _payload_for_world_cell(target_world_cell)
    if payload.is_empty() or target_cell == Vector2i(-1, -1):
        return {"valid": false, "warning": "Designation target is out of bounds", "command_type": str(spec["command_type"])}
    if str(payload.get("resource_id", "")) != "":
        var resource: Dictionary = resources.get(str(payload.get("resource_id", "")), {})
        if str(resource.get("type", "")) == "stone":
            var stone_work_cell: Vector3i = _find_reachable_mine_work_world_cell(target_world_cell)
            if stone_work_cell == INVALID_WORLD_CELL:
                return {"valid": false, "warning": "No worker can reach a cell to mine that target", "command_type": str(spec["command_type"])}
            var projected_mine_work_cell: Vector2i = projected_cell_for_world_cell(stone_work_cell)
            return {"valid": true, "warning": "", "command_type": str(spec["command_type"]), "work_cell": [projected_mine_work_cell.x, projected_mine_work_cell.y], "work_world_cell": [stone_work_cell.x, stone_work_cell.y, stone_work_cell.z]}
        return {"valid": false, "warning": "Select grass, dirt, or a surface rock to mine", "command_type": str(spec["command_type"])}
    if not _is_mineable_world_cell(target_world_cell):
        return {"valid": false, "warning": "Select grass, dirt, or a surface rock to mine", "command_type": str(spec["command_type"])}
    var work_cell: Vector3i = _find_reachable_mine_work_world_cell(target_world_cell)
    if work_cell == INVALID_WORLD_CELL:
        return {"valid": false, "warning": "No worker can reach a cell to mine that target", "command_type": str(spec["command_type"])}
    var projected_work_cell: Vector2i = projected_cell_for_world_cell(work_cell)
    return {"valid": true, "warning": "", "command_type": str(spec["command_type"]), "work_cell": [projected_work_cell.x, projected_work_cell.y], "work_world_cell": [work_cell.x, work_cell.y, work_cell.z]}

func queue_existing_command(command: Dictionary) -> void:
    command_queue.append(_normalize_command(command))
    command_queue.sort_custom(_compare_commands)

func _normalize_command(command: Dictionary) -> Dictionary:
    var target: Array = command.get("target_cell", [0, 0])
    var target_world: Array = command.get("target_world_cell", [])
    var target_world_cell: Vector3i
    if target_world.size() >= 3:
        target_world_cell = _array_to_vector3i(target_world)
        var projected_cell: Vector2i = projected_cell_for_world_cell(target_world_cell)
        if projected_cell != Vector2i(-1, -1):
            target = [projected_cell.x, projected_cell.y]
    else:
        target_world_cell = world_cell_for_projected_cell(Vector2i(int(target[0]), int(target[1])))
    return {
        "tick": int(command.get("tick", 0)),
        "player_id": str(command.get("player_id", "player_001")),
        "command_type": str(command.get("command_type", "")),
        "target_world_cell": [target_world_cell.x, target_world_cell.y, target_world_cell.z],
        "target_cell": [int(target[0]), int(target[1])],
        "payload": _sorted_dictionary(command.get("payload", {})),
        "command_id": str(command.get("command_id", "cmd_000000")),
    }

func _compare_commands(a: Dictionary, b: Dictionary) -> bool:
    # Deterministic total order for externally supplied commands. Command ids
    # should be unique, but the full tie-break keeps replay stable if malformed
    # or duplicated commands enter from a network/log source.
    return _command_sort_key(a) < _command_sort_key(b)

func _command_sort_key(command: Dictionary) -> String:
    return "%012d|%s|%s|%s|%012d|%012d|%012d|%s" % [
        int(command["tick"]),
        str(command["command_id"]),
        str(command["player_id"]),
        str(command["command_type"]),
        int(command["target_world_cell"][0]),
        int(command["target_world_cell"][1]),
        int(command["target_world_cell"][2]),
        JSON.stringify(command["payload"]),
    ]

func step_tick() -> void:
    tick += 1
    _apply_due_commands()
    create_haul_jobs_for_loose_items()
    create_build_jobs_for_ready_constructions()
    create_workshop_jobs_for_ready_orders()
    _advance_needs()
    _feed_hungry_units()
    _assign_jobs()
    _advance_units()
    _cleanup_completed_jobs()

func create_haul_jobs_for_loose_items() -> void:
    var reserved_destination_cells: Dictionary = _active_haul_destination_cells()
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.holder_unit_id != "" or item.stockpile_id != "" or item.reserved_by_job_id != "":
            continue
        var destination: Dictionary = _find_stockpile_destination_for_item(item.item_type, reserved_destination_cells)
        var stockpile_id: String = str(destination.get("stockpile_id", ""))
        if stockpile_id == "":
            continue
        var destination_cell: Vector2i = destination.get("cell", Vector2i(-1, -1))
        if destination_cell == Vector2i(-1, -1):
            continue
        var job_id: String = allocate_id("job")
        if not reserve_item_for_job(item_id, job_id):
            continue
        reserved_destination_cells[_cell_key(destination_cell)] = true
        var job = JobScript.new(job_id, "HAUL_ITEM", item.position, 1)
        job.target_world_cell = item.world_cell
        job.required_items = {
            "item_id": item_id,
            "stockpile_id": stockpile_id,
            "destination_cell": [destination_cell.x, destination_cell.y],
            "destination_world_cell": _serialize_single_world_cell(world_cell_for_projected_cell(destination_cell)),
            "phase": "pickup",
        }
        job_board.add_job(job)
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.holder_unit_id != "" or item.stockpile_id == "" or item.reserved_by_job_id != "":
            continue
        if not stockpiles.has(item.stockpile_id):
            continue
        var source_stockpile = stockpiles[item.stockpile_id]
        if source_stockpile.can_store_items() or not source_stockpile.can_supply_items():
            continue
        var destination: Dictionary = _find_stockpile_destination_for_item(item.item_type, reserved_destination_cells)
        var destination_stockpile_id: String = str(destination.get("stockpile_id", ""))
        if destination_stockpile_id == "" or destination_stockpile_id == item.stockpile_id:
            continue
        var destination_cell: Vector2i = destination.get("cell", Vector2i(-1, -1))
        if destination_cell == Vector2i(-1, -1):
            continue
        var job_id: String = allocate_id("job")
        if not reserve_item_for_job(item_id, job_id):
            continue
        reserved_destination_cells[_cell_key(destination_cell)] = true
        var job = JobScript.new(job_id, "HAUL_ITEM", item.position, 1)
        job.target_world_cell = item.world_cell
        job.required_items = {
            "item_id": item_id,
            "stockpile_id": destination_stockpile_id,
            "source_stockpile_id": item.stockpile_id,
            "destination_cell": [destination_cell.x, destination_cell.y],
            "destination_world_cell": _serialize_single_world_cell(world_cell_for_projected_cell(destination_cell)),
            "phase": "pickup",
        }
        job_board.add_job(job)

func create_build_jobs_for_ready_constructions() -> void:
    for construction_id in _sorted_ids(constructions):
        _try_reserve_construction_resources(construction_id)

func create_workshop_order(building_id: String, recipe_id: String, priority: int = 1) -> Dictionary:
    var validation: Dictionary = validate_workshop_recipe(building_id, recipe_id)
    if not bool(validation.get("valid", false)):
        return {"ok": false, "warning": str(validation.get("warning", "Invalid workshop order")), "workshop_order_id": ""}
    var order_id: String = allocate_id("workshop_order")
    var construction = _completed_construction_for_building(building_id)
    workshop_orders[order_id] = {
        "id": order_id,
        "building_id": building_id,
        "building_type": construction.type,
        "recipe_id": recipe_id,
        "target_cell": [construction.target_cell.x, construction.target_cell.y],
        "target_world_cell": [construction.target_world_cell.x, construction.target_world_cell.y, construction.target_world_cell.z],
        "priority": priority,
        "status": "queued",
        "reserved_item_ids": [],
        "job_id": "",
    }
    _try_reserve_workshop_order(order_id)
    return {"ok": true, "warning": "", "workshop_order_id": order_id}

func create_workshop_jobs_for_ready_orders() -> void:
    for order_id in _sorted_ids(workshop_orders):
        _try_reserve_workshop_order(order_id)

func _try_reserve_workshop_order(order_id: String) -> bool:
    if not workshop_orders.has(order_id):
        return false
    var order: Dictionary = workshop_orders[order_id]
    if str(order.get("status", "")) != "queued" or str(order.get("job_id", "")) != "":
        return false
    var recipe: Dictionary = _recipe_definition(str(order.get("recipe_id", "")))
    if recipe.is_empty():
        order["status"] = "failed"
        return false
    var reserved_item_ids: Array[String] = _reserve_recipe_ingredients(recipe.get("required_items", {}))
    if reserved_item_ids.is_empty():
        return false
    var job_id: String = allocate_id("job")
    for item_id in reserved_item_ids:
        if not reserve_item_for_job(item_id, job_id):
            for released_id in reserved_item_ids:
                release_item_reservation(released_id, job_id)
            return false
    var target_world: Array = order.get("target_world_cell", [])
    var target_world_cell: Vector3i = _array_to_vector3i(target_world) if target_world.size() >= 3 else world_cell_for_projected_cell(Vector2i(int(order.get("target_cell", [0, 0])[0]), int(order.get("target_cell", [0, 0])[1])))
    var target: Vector2i = projected_cell_for_world_cell(target_world_cell)
    var job = JobScript.new(job_id, str(recipe.get("job_type", "COOK_MEAL")), target, int(order.get("priority", 1)))
    job.target_world_cell = target_world_cell
    job.work_remaining_ticks = int(recipe.get("work_ticks", job.work_remaining_ticks))
    job.produced_items = recipe.get("produced_items", {}).duplicate(true)
    job.required_items = {
        "workshop_order_id": order_id,
        "building_id": str(order.get("building_id", "")),
        "recipe_id": str(order.get("recipe_id", "")),
        "reserved_item_ids": reserved_item_ids.duplicate(),
        "required_items": recipe.get("required_items", {}).duplicate(true),
    }
    order["reserved_item_ids"] = reserved_item_ids.duplicate()
    order["job_id"] = job_id
    order["status"] = "reserved"
    job_board.add_job(job)
    return true

func _reserve_recipe_ingredients(required_items: Dictionary) -> Array[String]:
    var reserved_item_ids: Array[String] = []
    for item_type in _sorted_ids(required_items):
        var needed: int = int(required_items[item_type])
        var found: int = 0
        for item_id in _sorted_ids(items):
            var item = items[item_id]
            if item.item_type != str(item_type):
                continue
            if item.stockpile_id == "" or item.holder_unit_id != "" or item.reserved_by_job_id != "":
                continue
            if not stockpiles.has(item.stockpile_id) or not stockpiles[item.stockpile_id].can_supply_items():
                continue
            reserved_item_ids.append(item_id)
            found += int(item.quantity)
            if found >= needed:
                break
        if found < needed:
            return []
    return reserved_item_ids

func _find_stockpile_for_item_type(item_type: String) -> String:
    for stockpile_id in _sorted_ids(stockpiles):
        var stockpile = stockpiles[stockpile_id]
        if stockpile.can_store_items() and stockpile.accepts_item_type(item_type) and _first_available_stockpile_cell(stockpile_id, {}) != Vector2i(-1, -1):
            return stockpile_id
    return ""

func _first_stockpile_cell(stockpile_id: String) -> Vector2i:
    return _first_available_stockpile_cell(stockpile_id, {})

func _find_stockpile_destination_for_item(item_type: String, reserved_destination_cells: Dictionary) -> Dictionary:
    for stockpile_id in _sorted_ids(stockpiles):
        var stockpile = stockpiles[stockpile_id]
        if not stockpile.can_store_items():
            continue
        if not stockpile.accepts_item_type(item_type):
            continue
        var cell: Vector2i = _first_available_stockpile_cell(stockpile_id, reserved_destination_cells)
        if cell != Vector2i(-1, -1):
            return {"stockpile_id": stockpile_id, "cell": cell}
    return {"stockpile_id": "", "cell": Vector2i(-1, -1)}

func _first_available_stockpile_cell(stockpile_id: String, reserved_destination_cells: Dictionary) -> Vector2i:
    if not stockpiles.has(stockpile_id):
        return Vector2i(-1, -1)
    var stockpile = stockpiles[stockpile_id]
    for cell in stockpile.cells:
        if reserved_destination_cells.has(_cell_key(cell)):
            continue
        if _cell_has_visible_item(cell):
            continue
        return cell
    return Vector2i(-1, -1)

func _active_haul_destination_cells() -> Dictionary:
    var output: Dictionary = {}
    for job_id in job_board.sorted_job_ids():
        var job = job_board.jobs[job_id]
        if job.type != "HAUL_ITEM" or not (job.status in ["open", "claimed", "in_progress"]):
            continue
        var dest_wc: Vector3i = _haul_destination_world_cell(job)
        if dest_wc != INVALID_WORLD_CELL:
            output[_cell_key(Vector2i(dest_wc.x, dest_wc.z))] = true
    return output

func _cell_has_visible_item(cell: Vector2i, except_item_id: String = "") -> bool:
    return _world_cell_has_visible_item(world_cell_for_projected_cell(cell), except_item_id)

func _world_cell_has_visible_item(world_cell: Vector3i, except_item_id: String = "") -> bool:
    for item_id in _sorted_ids(items):
        if item_id == except_item_id:
            continue
        var item = items[item_id]
        if item.holder_unit_id == "" and item.world_cell == world_cell:
            return true
    return false

func _cell_key(cell: Vector2i) -> String:
    return "%012d|%012d" % [cell.x, cell.y]

func _building_footprint_cells(building_type: String, target_cell: Vector2i) -> Array[Vector2i]:
    var definition: Dictionary = get_building_definition(building_type)
    if definition.is_empty():
        return []
    var footprint: Array = definition.get("footprint", [1, 1])
    var width: int = int(footprint[0]) if footprint.size() > 0 else 1
    var height: int = int(footprint[1]) if footprint.size() > 1 else 1
    var min_x: int = target_cell.x - int(floor(float(width) * 0.5))
    var min_y: int = target_cell.y - int(floor(float(height) * 0.5))
    var cells: Array[Vector2i] = []
    for x in range(min_x, min_x + width):
        for y in range(min_y, min_y + height):
            var cell := Vector2i(x, y)
            if chunk_world_store == null or not chunk_world_store.has_cell(world_cell_for_projected_cell(cell)):
                return []
            cells.append(cell)
    return cells

func _construction_cells(construction) -> Array[Vector2i]:
    if construction != null and construction.cells.size() > 0:
        return ZoneScript.canonical_cells(construction.cells)
    if construction == null:
        return []
    return _building_footprint_cells(construction.type, construction.target_cell)

func _cells_match_building_footprint(building_type: String, cells: Array) -> bool:
    var definition: Dictionary = get_building_definition(building_type)
    if definition.is_empty():
        return false
    var canonical: Array[Vector2i] = ZoneScript.canonical_cells(cells)
    var footprint: Array = definition.get("footprint", [1, 1])
    var expected_width: int = int(footprint[0]) if footprint.size() > 0 else 1
    var expected_height: int = int(footprint[1]) if footprint.size() > 1 else 1
    if canonical.size() != expected_width * expected_height:
        return false
    var bounds: Dictionary = _stockpile_bounds(canonical)
    if bounds.is_empty():
        return false
    if int(bounds["max_x"]) - int(bounds["min_x"]) + 1 != expected_width:
        return false
    if int(bounds["max_y"]) - int(bounds["min_y"]) + 1 != expected_height:
        return false
    return true

func _serialized_building_footprint(building_type: String, target_cell: Vector2i) -> Array:
    return _serialize_cells(_building_footprint_cells(building_type, target_cell))

func _completed_construction_for_building(building_id: String):
    if building_id == "":
        return null
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.status == "complete" and construction.completed_building_id == building_id:
            return construction
    return null

func _workshop_summary(construction) -> Dictionary:
    var definition: Dictionary = get_building_definition(construction.type)
    return {
        "building_id": construction.completed_building_id,
        "construction_id": construction.id,
        "type": construction.type,
        "display_name": str(definition.get("display_name", construction.type)),
        "target_cell": [construction.target_cell.x, construction.target_cell.y],
        "footprint": _serialize_cells(_construction_cells(construction)),
        "recipes": definition.get("recipes", []).duplicate(),
    }

func _recipe_definition(recipe_id: String) -> Dictionary:
    match recipe_id:
        RECIPE_COOK_MEAL:
            return {
                "id": RECIPE_COOK_MEAL,
                "display_name": "Cook Meal",
                "job_type": "COOK_MEAL",
                "required_items": {"food": 2},
                "produced_items": {"meal": 1},
                "work_ticks": 4,
            }
    return {}

func _stockpile_bounds(cells: Array) -> Dictionary:
    if cells.is_empty():
        return {}
    var min_x: int = cells[0].x
    var max_x: int = cells[0].x
    var min_y: int = cells[0].y
    var max_y: int = cells[0].y
    for cell in cells:
        min_x = mini(min_x, cell.x)
        max_x = maxi(max_x, cell.x)
        min_y = mini(min_y, cell.y)
        max_y = maxi(max_y, cell.y)
    return {"min_x": min_x, "max_x": max_x, "min_y": min_y, "max_y": max_y}

func _stockpile_center_cell(stockpile_id: String) -> Vector2i:
    if not stockpiles.has(stockpile_id):
        return Vector2i.ZERO
    var bounds: Dictionary = _stockpile_bounds(stockpiles[stockpile_id].cells)
    if bounds.is_empty():
        return Vector2i.ZERO
    return Vector2i(
        int(floor(float(int(bounds["min_x"]) + int(bounds["max_x"])) * 0.5)),
        int(floor(float(int(bounds["min_y"]) + int(bounds["max_y"])) * 0.5))
    )

func _resized_stockpile_cells(stockpile_id: String, side: String, delta: int) -> Array[Vector2i]:
    if not stockpiles.has(stockpile_id):
        return []
    var bounds: Dictionary = _stockpile_bounds(stockpiles[stockpile_id].cells)
    if bounds.is_empty():
        return []
    var min_x: int = int(bounds["min_x"])
    var max_x: int = int(bounds["max_x"])
    var min_y: int = int(bounds["min_y"])
    var max_y: int = int(bounds["max_y"])
    match side:
        "north":
            min_y -= delta
        "south":
            max_y += delta
        "west":
            min_x -= delta
        "east":
            max_x += delta
    if min_x > max_x or min_y > max_y:
        return []
    return _rect_cells(min_x, max_x, min_y, max_y)

func _rect_cells(min_x: int, max_x: int, min_y: int, max_y: int) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for x in range(min_x, max_x + 1):
        for y in range(min_y, max_y + 1):
            cells.append(Vector2i(x, y))
    return cells

func _shrink_would_remove_stockpiled_items(stockpile_id: String, resized_cells: Array[Vector2i]) -> bool:
    var kept: Dictionary = {}
    for cell in resized_cells:
        kept[_cell_key(cell)] = true
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.stockpile_id == stockpile_id and item.holder_unit_id == "" and not kept.has(_cell_key(item.position)):
            return true
    for job_id in job_board.sorted_job_ids():
        var job = job_board.jobs[job_id]
        if job.type != "HAUL_ITEM" or str(job.required_items.get("stockpile_id", "")) != stockpile_id:
            continue
        var shrink_dest_wc: Vector3i = _haul_destination_world_cell(job)
        if job.status in ["open", "claimed", "in_progress"] and not kept.has(_cell_key(Vector2i(shrink_dest_wc.x, shrink_dest_wc.z))):
            return true
    return false

func _apply_due_commands() -> void:
    command_queue.sort_custom(_compare_commands)
    var remaining: Array[Dictionary] = []
    for command in command_queue:
        if int(command["tick"]) <= tick:
            _apply_command(command)
        else:
            remaining.append(command)
    command_queue = remaining

func _apply_command(command: Dictionary) -> void:
    var target_world: Vector3i = _array_to_vector3i(command.get("target_world_cell", []))
    var target: Vector2i = projected_cell_for_world_cell(target_world)
    if target == Vector2i(-1, -1):
        return
    match command["command_type"]:
        "DESIGNATE_CHOP":
            _create_job_for_resource_world(target_world, "tree", "CHOP_TREE", int(command["payload"].get("priority", 1)))
        "DESIGNATE_GATHER_STONE":
            _create_job_for_resource_world(target_world, "stone", "GATHER_STONE", int(command["payload"].get("priority", 1)))
        "DESIGNATE_GATHER_FOOD":
            _create_job_for_resource_world(target_world, "berry", "GATHER_FOOD", int(command["payload"].get("priority", 1)))
        "DESIGNATE_MINE":
            _create_mine_world_job(target_world, int(command["payload"].get("priority", 1)))
        "DESIGNATE_STOCKPILE":
            designate_stockpile_at_world_cell(target_world, command["payload"])
        "RESIZE_STOCKPILE":
            resize_stockpile(
                str(command["payload"].get("stockpile_id", "")),
                str(command["payload"].get("side", "")),
                int(command["payload"].get("delta", 0))
            )
        "SET_STOCKPILE_MODE":
            set_stockpile_mode(
                str(command["payload"].get("stockpile_id", "")),
                str(command["payload"].get("storage_mode", ""))
            )
        "PLACE_BLUEPRINT":
            create_construction_at_world_cell(
                str(command["payload"].get("building_type", "")),
                target_world,
                int(command["payload"].get("priority", 1)),
                command["payload"].get("world_cells", command["payload"].get("cells", []))
            )
        "QUEUE_WORKSHOP_RECIPE":
            create_workshop_order(
                str(command["payload"].get("building_id", "")),
                str(command["payload"].get("recipe_id", "")),
                int(command["payload"].get("priority", 1))
            )
        "SET_UNIT_JOB_PRIORITY":
            set_unit_job_type_priority(
                str(command["payload"].get("unit_id", "")),
                str(command["payload"].get("job_type", "")),
                int(command["payload"].get("priority", 1))
            )

func set_unit_job_type_priority(unit_id: String, job_type: String, priority: int) -> bool:
    if not units.has(unit_id):
        return false
    var unit = units[unit_id]
    unit.set_job_type_priority(job_type, priority)
    return true

func _create_job_for_resource(target: Vector2i, resource_type: String, job_type: String, priority: int) -> void:
    _create_job_for_resource_world(world_cell_for_projected_cell(target), resource_type, job_type, priority)

func _create_job_for_resource_world(target_world_cell: Vector3i, resource_type: String, job_type: String, priority: int) -> void:
    var target: Vector2i = projected_cell_for_world_cell(target_world_cell)
    var payload: Dictionary = _payload_for_world_cell(target_world_cell)
    if target == Vector2i(-1, -1) or payload.is_empty():
        return
    var resource_id: String = _resource_id_at_world_cell(target_world_cell, resource_type)
    if resource_id == "":
        return
    var resource = resources.get(resource_id, {})
    if resource.get("type", "") != resource_type:
        return
    if job_board.has_open_job_at(job_type, target):
        return
    var job = JobScript.new(allocate_id("job"), job_type, target, priority)
    job.target_world_cell = target_world_cell
    job_board.add_job(job)

func _create_mine_job(target: Vector2i, priority: int) -> void:
    _create_mine_world_job(world_cell_for_projected_cell(target), priority)

func _create_mine_world_job(target_world_cell: Vector3i, priority: int) -> void:
    var target: Vector2i = projected_cell_for_world_cell(target_world_cell)
    var validation: Dictionary = validate_designation_world_target(TOOL_MODE_MINE, target_world_cell)
    if not bool(validation.get("valid", false)):
        return
    if job_board.has_open_job_at("MINE_CELL", target):
        return
    var job = JobScript.new(allocate_id("job"), "MINE_CELL", target, priority)
    job.target_world_cell = target_world_cell
    job.required_items["work_cell"] = validation.get("work_cell", [target.x, target.y])
    job.required_items["work_world_cell"] = validation.get("work_world_cell", [target_world_cell.x, target_world_cell.y, target_world_cell.z])
    job_board.add_job(job)

func _advance_needs() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        unit.needs["hunger"] = int(unit.needs.get("hunger", 0)) + 1
        if unit.state in ["working", "walking"]:
            unit.needs["energy"] = max(0, int(unit.needs.get("energy", 100)) - 1)

func _feed_hungry_units() -> void:
    for unit_id in _sorted_ids(units):
        var unit = units[unit_id]
        if int(unit.needs.get("hunger", 0)) < HUNGER_EAT_THRESHOLD:
            continue
        var food_item_id: String = _find_available_stored_food_item()
        if food_item_id == "":
            continue
        _consume_food_item(food_item_id)
        unit.needs["hunger"] = HUNGER_AFTER_EATING

func _find_available_stored_food_item() -> String:
    var meal_id: String = _find_available_stored_food_item_of_type("meal")
    if meal_id != "":
        return meal_id
    return _find_available_stored_food_item_of_type("food")

func _find_available_stored_food_item_of_type(food_type: String) -> String:
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.item_type != food_type:
            continue
        if item.stockpile_id == "" or item.holder_unit_id != "" or item.reserved_by_job_id != "":
            continue
        if not stockpiles.has(item.stockpile_id):
            continue
        var stockpile = stockpiles[item.stockpile_id]
        if not stockpile.can_store_items():
            continue
        if int(item.quantity) <= 0:
            continue
        return item_id
    return ""

func _consume_food_item(item_id: String) -> void:
    if not items.has(item_id):
        return
    var item = items[item_id]
    item.quantity = max(0, int(item.quantity) - 1)
    if int(item.quantity) <= 0:
        items.erase(item_id)

func _assign_jobs() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        if unit.current_job_id != "":
            continue
        var job = job_board.claim_next_open_job_for_unit(unit)
        if job != null:
            unit.current_job_id = job.id
            unit.unreachable_job_ticks = 0
            unit.state = "walking"

func _advance_units() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        if unit.current_job_id == "":
            unit.state = "idle"
            unit.unreachable_job_ticks = 0
            continue
        var job = job_board.jobs.get(unit.current_job_id)
        if job == null:
            unit.current_job_id = ""
            unit.unreachable_job_ticks = 0
            unit.state = "idle"
            continue
        if job.type == "HAUL_ITEM":
            _advance_haul_job(unit, job)
            continue
        var dest_world_cell: Vector3i = _job_destination_world_cell(job)
        if unit.world_cell != dest_world_cell:
            var next_world_cell: Vector3i = _step_towards_world_cell(unit.world_cell, dest_world_cell)
            if next_world_cell == unit.world_cell:
                if _release_job_if_unreachable(unit, job):
                    continue
            else:
                unit.unreachable_job_ticks = 0
            _set_unit_world_cell(unit, next_world_cell)
            unit.state = "walking"
        else:
            unit.unreachable_job_ticks = 0
            unit.state = "working"
            if job.advance_work_tick():
                _complete_job(unit, job)

func _advance_haul_job(unit, job) -> void:
    var item_id: String = str(job.required_items.get("item_id", ""))
    var stockpile_id: String = str(job.required_items.get("stockpile_id", ""))
    if not items.has(item_id) or not stockpiles.has(stockpile_id):
        _fail_haul_job(unit, job, item_id)
        return
    var item = items[item_id]
    if item.reserved_by_job_id != job.id:
        _fail_haul_job(unit, job, item_id)
        return
    var dest_world_cell: Vector3i = _haul_destination_world_cell(job)
    if dest_world_cell == INVALID_WORLD_CELL:
        _fail_haul_job(unit, job, item_id)
        return
    var phase: String = str(job.required_items.get("phase", "pickup"))
    if phase == "pickup":
        if unit.world_cell != item.world_cell:
            var next_wc: Vector3i = _step_towards_world_cell(unit.world_cell, item.world_cell)
            if next_wc == unit.world_cell:
                _release_job_if_unreachable(unit, job)
                return
            unit.unreachable_job_ticks = 0
            _set_unit_world_cell(unit, next_wc)
            unit.state = "walking"
            return
        unit.unreachable_job_ticks = 0
        item.holder_unit_id = unit.id
        if not unit.inventory.has(item_id):
            unit.inventory.append(item_id)
        job.required_items["phase"] = "deliver"
        job.status = "in_progress"
        unit.state = "carrying"
        return
    if item.holder_unit_id != unit.id:
        _fail_haul_job(unit, job, item_id)
        return
    if unit.world_cell != dest_world_cell:
        var next_wc: Vector3i = _step_towards_world_cell(unit.world_cell, dest_world_cell)
        if next_wc == unit.world_cell:
            _release_job_if_unreachable(unit, job)
            return
        unit.unreachable_job_ticks = 0
        _set_unit_world_cell(unit, next_wc)
        _set_item_world_cell(item, unit.world_cell)
        unit.state = "carrying"
        return
    unit.unreachable_job_ticks = 0
    _set_item_world_cell(item, dest_world_cell)
    if not assign_item_to_stockpile(item_id, stockpile_id):
        _fail_haul_job(unit, job, item_id)
        return
    release_item_reservation(item_id, job.id)
    unit.inventory.erase(item_id)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _release_job_if_unreachable(unit, job) -> bool:
    unit.unreachable_job_ticks += 1
    unit.state = "walking"
    if unit.unreachable_job_ticks < UNREACHABLE_JOB_RELEASE_TICKS:
        return false
    _release_unreachable_job(unit, job)
    return true

func _release_unreachable_job(unit, job) -> void:
    if job.type == "HAUL_ITEM":
        var item_id: String = str(job.required_items.get("item_id", ""))
        if items.has(item_id):
            var item = items[item_id]
            if item.holder_unit_id == unit.id:
                item.holder_unit_id = ""
                _set_item_world_cell(item, unit.world_cell)
            unit.inventory.erase(item_id)
        job.required_items["phase"] = "pickup"
    job_board.release_job(job.id, unit.id)
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _job_destination_world_cell(job) -> Vector3i:
    if job.type == "MINE_CELL":
        var world_raw: Array = job.required_items.get("work_world_cell", [])
        if world_raw.size() >= 3:
            return _array_to_vector3i(world_raw)
    return job.target_world_cell

func _haul_destination_world_cell(job) -> Vector3i:
    var world_raw: Array = job.required_items.get("destination_world_cell", [])
    if world_raw.size() >= 3:
        return _array_to_vector3i(world_raw)
    return INVALID_WORLD_CELL

func _fail_haul_job(unit, job, item_id: String) -> void:
    release_item_reservation(item_id, job.id)
    if items.has(item_id):
        var item = items[item_id]
        if item.holder_unit_id == unit.id:
            item.holder_unit_id = ""
            _set_item_world_cell(item, unit.world_cell)
    unit.inventory.erase(item_id)
    job.status = "failed"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _step_towards_world_cell(from_world_cell: Vector3i, to_world_cell: Vector3i) -> Vector3i:
    if from_world_cell == to_world_cell:
        return from_world_cell
    var path: Array[Vector3i] = _path_between_world_cells(from_world_cell, to_world_cell)
    if path.size() < 2:
        return from_world_cell
    return path[1]

func _path_between_world_cells(from_world_cell: Vector3i, to_world_cell: Vector3i) -> Array[Vector3i]:
    if from_world_cell == to_world_cell:
        return [from_world_cell]
    if chunk_world_store == null or not chunk_world_store.has_cell(from_world_cell) or not chunk_world_store.has_cell(to_world_cell):
        return []
    if not _can_stand_on_world_cell(from_world_cell) or not _can_stand_on_world_cell(to_world_cell):
        return []
    var frontier: Array[Vector3i] = [from_world_cell]
    var came_from: Dictionary = {_world_cell_key(from_world_cell): from_world_cell}
    var cursor: int = 0
    while cursor < frontier.size():
        var current: Vector3i = frontier[cursor]
        cursor += 1
        if current == to_world_cell:
            break
        for neighbor in _movement_world_neighbors(current):
            var key: String = _world_cell_key(neighbor)
            if came_from.has(key):
                continue
            came_from[key] = current
            frontier.append(neighbor)
    if not came_from.has(_world_cell_key(to_world_cell)):
        return []
    var path: Array[Vector3i] = [to_world_cell]
    var step: Vector3i = to_world_cell
    while step != from_world_cell:
        step = came_from[_world_cell_key(step)]
        path.push_front(step)
    return path

func _find_reachable_mine_work_cell(target_cell: Vector2i) -> Vector2i:
    var world_cell: Vector3i = _find_reachable_mine_work_world_cell(world_cell_for_projected_cell(target_cell))
    if world_cell == INVALID_WORLD_CELL:
        return Vector2i(-1, -1)
    return projected_cell_for_world_cell(world_cell)

func _find_reachable_mine_work_world_cell(target_world_cell: Vector3i) -> Vector3i:
    var candidates: Array[Vector3i] = _mine_work_world_cell_candidates(target_world_cell)
    if candidates.is_empty():
        return INVALID_WORLD_CELL
    for unit_id in _sorted_ids(units):
        var unit = units[unit_id]
        for candidate in candidates:
            if unit.world_cell == candidate or _path_between_world_cells(unit.world_cell, candidate).size() >= 2:
                return candidate
    return INVALID_WORLD_CELL

func _mine_work_cell_candidates(target_cell: Vector2i) -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for world_cell in _mine_work_world_cell_candidates(world_cell_for_projected_cell(target_cell)):
        var projected_cell: Vector2i = projected_cell_for_world_cell(world_cell)
        if projected_cell != Vector2i(-1, -1):
            output.append(projected_cell)
    return _dedupe_cells(output)

func _mine_work_world_cell_candidates(target_world_cell: Vector3i) -> Array[Vector3i]:
    if not _is_mineable_world_cell(target_world_cell):
        return []
    var candidates: Array[Vector3i] = []
    var above_world_cell := Vector3i(target_world_cell.x, target_world_cell.y + 1, target_world_cell.z)
    var above_payload: Dictionary = _payload_for_world_cell(above_world_cell)
    if not above_payload.is_empty() and str(above_payload.get("terrain", "")) == WorldConstantsScript.TERRAIN_EXCAVATED and _can_stand_on_world_cell(above_world_cell):
        candidates.append(above_world_cell)
    for offset in [Vector3i(0,0,-1), Vector3i(1,0,0), Vector3i(0,0,1), Vector3i(-1,0,0)]:
        var neighbor: Vector3i = target_world_cell + offset
        if _can_stand_on_world_cell(neighbor):
            candidates.append(neighbor)
    if target_world_cell.y >= 0 and _can_stand_on_world_cell(target_world_cell):
        candidates.append(target_world_cell)
    return _dedupe_world_cells(candidates)

func _is_mineable_world_cell(world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty():
        return false
    var material_key: String = str(payload.get("material_key", ""))
    var terrain: String = str(payload.get("terrain", ""))
    var required_tier: int = int(payload.get("mining_tier_required", WorldConstantsScript.MINING_TIER_NONE))
    if required_tier > WorldConstantsScript.MINING_TIER_BASIC:
        return false
    if terrain in [WorldConstantsScript.TERRAIN_GRASS, WorldConstantsScript.TERRAIN_DIRT, WorldConstantsScript.TERRAIN_ROCK]:
        return true
    return material_key in [
        WorldConstantsScript.MATERIAL_GRASS,
        WorldConstantsScript.MATERIAL_DIRT,
        WorldConstantsScript.MATERIAL_CLAY,
        WorldConstantsScript.MATERIAL_GRAVEL,
        WorldConstantsScript.MATERIAL_LOOSE_STONE,
        WorldConstantsScript.MATERIAL_SOFT_ROCK,
    ]

func _dedupe_cells(cells: Array[Vector2i]) -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    var seen: Dictionary = {}
    for cell in cells:
        var key: String = _cell_key(cell)
        if seen.has(key):
            continue
        seen[key] = true
        output.append(cell)
    return output

func _dedupe_world_cells(cells: Array[Vector3i]) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    var seen: Dictionary = {}
    for cell in cells:
        var key: String = _world_cell_key(cell)
        if seen.has(key):
            continue
        seen[key] = true
        output.append(cell)
    return output

func _movement_neighbors(cell: Vector2i) -> Array[Vector2i]:
    var output: Array[Vector2i] = []
    for world_cell in _movement_world_neighbors(world_cell_for_projected_cell(cell)):
        var projected_cell: Vector2i = projected_cell_for_world_cell(world_cell)
        if projected_cell != Vector2i(-1, -1):
            output.append(projected_cell)
    return output

func _movement_world_neighbors(world_cell: Vector3i) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    for offset in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
        var candidate_world_cell: Vector3i = world_cell + offset
        if chunk_world_store != null and chunk_world_store.has_cell(candidate_world_cell) and _can_step_between_world_cells(world_cell, candidate_world_cell):
            output.append(candidate_world_cell)
    for dy in [1, -1]:
        var vertical_world_cell := Vector3i(world_cell.x, world_cell.y + dy, world_cell.z)
        if chunk_world_store != null and chunk_world_store.has_cell(vertical_world_cell) and _can_step_between_world_cells(world_cell, vertical_world_cell):
            output.append(vertical_world_cell)
    return output

func _can_step_between_world_cells(from_world_cell: Vector3i, to_world_cell: Vector3i) -> bool:
    if not _can_stand_on_world_cell(to_world_cell):
        return false
    if from_world_cell.y == to_world_cell.y:
        return abs(from_world_cell.x - to_world_cell.x) + abs(from_world_cell.z - to_world_cell.z) == 1
    if from_world_cell.x == to_world_cell.x and from_world_cell.z == to_world_cell.z and abs(from_world_cell.y - to_world_cell.y) == 1:
        if to_world_cell.y > from_world_cell.y:
            return str(_payload_for_world_cell(from_world_cell).get("terrain", "")) == WorldConstantsScript.TERRAIN_EXCAVATED
        else:
            return str(_payload_for_world_cell(to_world_cell).get("terrain", "")) == WorldConstantsScript.TERRAIN_EXCAVATED
    return false

func _can_stand_on_cell(cell: Vector2i) -> bool:
    return _can_stand_on_world_cell(world_cell_for_projected_cell(cell))

func _can_stand_on_world_cell(world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty() or not bool(payload.get("walkable", false)):
        return false
    return _is_world_cell_exposed(world_cell)

func _is_cell_exposed(cell: Vector2i) -> bool:
    return _is_world_cell_exposed(world_cell_for_projected_cell(cell))

func _is_world_cell_exposed(world_cell: Vector3i) -> bool:
    var payload: Dictionary = _payload_for_world_cell(world_cell)
    if payload.is_empty():
        return false
    if bool(payload.get("is_cave", false)) or str(payload.get("exposure", "")) == "cave":
        return true
    if world_cell.y >= 0:
        return true
    var above_world_cell := Vector3i(world_cell.x, world_cell.y + 1, world_cell.z)
    var above_payload: Dictionary = _payload_for_world_cell(above_world_cell)
    return not above_payload.is_empty() and str(above_payload.get("terrain", "")) == WorldConstantsScript.TERRAIN_EXCAVATED

func _complete_job(unit, job) -> void:
    if job.type == "BUILD_CONSTRUCTION" or job.type == "BUILD_STRUCTURE":
        _complete_build_construction_job(unit, job)
        return
    if job.type == "COOK_MEAL":
        _complete_workshop_job(unit, job)
        return
    if job.type == "MINE_CELL":
        _complete_mine_job(unit, job)
        return
    var resource_id: String = _resource_id_at_world_cell(job.target_world_cell, _resource_type_for_job(job.type))
    if resource_id != "":
        var resource: Dictionary = resources.get(resource_id, {})
        if resource.get("type", "") == _resource_type_for_job(job.type):
            for item_type in _sorted_ids(job.produced_items):
                var item_id: String = allocate_id("item")
                items[item_id] = _create_item_at_world_cell(item_id, item_type, int(job.produced_items[item_type]), job.target_world_cell)
            resources.erase(resource_id)
            _clear_resource_authoritative(job.target_world_cell, resource_id)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _complete_mine_job(unit, job) -> void:
    var payload: Dictionary = _payload_for_world_cell(job.target_world_cell)
    if payload.is_empty() or not _is_mineable_world_cell(job.target_world_cell):
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.unreachable_job_ticks = 0
        unit.state = "idle"
        return
    var resource_id: String = str(payload.get("resource_id", ""))
    var original_terrain: String = str(payload.get("terrain", ""))
    if resource_id != "":
        var resource: Dictionary = resources.get(resource_id, {})
        if str(resource.get("type", "")) != "stone":
            job.status = "failed"
            job.claimed_by_unit_id = unit.id
            unit.current_job_id = ""
            unit.unreachable_job_ticks = 0
            unit.state = "idle"
            return
        var item_id: String = allocate_id("item")
        items[item_id] = _create_item_at_world_cell(item_id, "stone", 1, job.target_world_cell)
        resources.erase(resource_id)
        _clear_resource_authoritative(job.target_world_cell, resource_id)
    elif str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_GRAVEL:
        var gravel_item_id: String = allocate_id("item")
        items[gravel_item_id] = _create_item_at_world_cell(gravel_item_id, "gravel", 1, job.target_world_cell)
    elif str(payload.get("material_key", "")) == WorldConstantsScript.MATERIAL_CLAY:
        var clay_item_id: String = allocate_id("item")
        items[clay_item_id] = _create_item_at_world_cell(clay_item_id, "clay", 1, job.target_world_cell)
    elif not payload.get("hidden_mine_yield", {}).is_empty():
        var hidden_yield: Dictionary = payload.get("hidden_mine_yield", {})
        var hidden_item_id: String = allocate_id("item")
        items[hidden_item_id] = _create_item_at_world_cell(hidden_item_id, str(hidden_yield.get("item_type", "stone")), int(hidden_yield.get("quantity", 1)), job.target_world_cell)
    elif original_terrain == WorldConstantsScript.TERRAIN_ROCK:
        var rock_item_id: String = allocate_id("item")
        items[rock_item_id] = _create_item_at_world_cell(rock_item_id, "stone", 1, job.target_world_cell)
    elif original_terrain in [WorldConstantsScript.TERRAIN_GRASS, WorldConstantsScript.TERRAIN_DIRT]:
        var dirt_item_id: String = allocate_id("item")
        items[dirt_item_id] = _create_item_at_world_cell(dirt_item_id, "dirt", 1, job.target_world_cell)
    _mine_cell_authoritative(job.target_world_cell)
    if resource_id != "" and original_terrain == WorldConstantsScript.TERRAIN_ROCK:
        var mined_payload: Dictionary = _payload_for_world_cell(job.target_world_cell)
        mined_payload["terrain"] = WorldConstantsScript.TERRAIN_EXCAVATED
        _set_cell_payload(job.target_world_cell, mined_payload)
    if _mine_cell_collapses(job.target_world_cell):
        _collapse_cell_authoritative(job.target_world_cell)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _mine_cell_collapses(world_cell: Vector3i) -> bool:
    if world_cell.y > DEEP_MINING_COLLAPSE_DEPTH:
        return false
    return rng_streams["event_rng"].range_i(0, 99) < DEEP_MINING_COLLAPSE_CHANCE_PERCENT

func _complete_workshop_job(unit, job) -> void:
    var order_id: String = str(job.required_items.get("workshop_order_id", ""))
    if not workshop_orders.has(order_id):
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    var order: Dictionary = workshop_orders[order_id]
    var recipe: Dictionary = _recipe_definition(str(order.get("recipe_id", "")))
    if recipe.is_empty() or str(order.get("job_id", "")) != job.id:
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    for item_id in order.get("reserved_item_ids", []):
        if not items.has(item_id) or items[item_id].reserved_by_job_id != job.id:
            job.status = "failed"
            job.claimed_by_unit_id = unit.id
            unit.current_job_id = ""
            unit.state = "idle"
            return
    _consume_reserved_items_for_recipe(order.get("reserved_item_ids", []), recipe.get("required_items", {}), job.id)
    for item_type in _sorted_ids(recipe.get("produced_items", {})):
        var item_id: String = allocate_id("item")
        items[item_id] = _create_item_at_projected_cell(item_id, str(item_type), int(recipe["produced_items"][item_type]), job.target_cell)
    order["status"] = "complete"
    order["reserved_item_ids"] = []
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

func _consume_reserved_items_for_recipe(reserved_item_ids: Array, required_items: Dictionary, job_id: String) -> void:
    var remaining: Dictionary = required_items.duplicate(true)
    for item_id in reserved_item_ids:
        if not items.has(item_id):
            continue
        var item = items[item_id]
        var item_type: String = str(item.item_type)
        var needed: int = int(remaining.get(item_type, 0))
        if needed <= 0:
            release_item_reservation(item_id, job_id)
            continue
        var consumed: int = mini(int(item.quantity), needed)
        item.quantity = int(item.quantity) - consumed
        remaining[item_type] = needed - consumed
        if int(item.quantity) <= 0:
            items.erase(item_id)
        else:
            release_item_reservation(item_id, job_id)

func _complete_build_construction_job(unit, job) -> void:
    var construction_id: String = str(job.required_items.get("construction_id", ""))
    if not constructions.has(construction_id):
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    var construction = constructions[construction_id]
    if construction.status == "complete":
        job.status = "complete"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    if construction.status != "reserved" or construction.build_job_id != job.id:
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    var footprint_cells: Array[Vector2i] = _construction_cells(construction)
    if footprint_cells.is_empty():
        job.status = "failed"
        job.claimed_by_unit_id = unit.id
        unit.current_job_id = ""
        unit.state = "idle"
        return
    for footprint_world_cell in construction.world_cells:
        var fp_payload: Dictionary = _payload_for_world_cell(footprint_world_cell)
        if fp_payload.is_empty() or str(fp_payload.get("building_id", "")) != "":
            job.status = "failed"
            job.claimed_by_unit_id = unit.id
            unit.current_job_id = ""
            unit.state = "idle"
            return
    for item_id in construction.reserved_item_ids:
        if not items.has(item_id) or items[item_id].reserved_by_job_id != job.id:
            job.status = "failed"
            job.claimed_by_unit_id = unit.id
            unit.current_job_id = ""
            unit.state = "idle"
            return
    for item_id in construction.reserved_item_ids.duplicate():
        items.erase(item_id)
    construction.reserved_item_ids.clear()
    var building_id: String = allocate_id("building")
    construction.completed_building_id = building_id
    construction.status = "complete"
    var definition: Dictionary = get_building_definition(construction.type)
    for footprint_world_cell_b in construction.world_cells:
        _set_building_on_cell_authoritative(footprint_world_cell_b, building_id, bool(definition.get("blocks_movement", false)))
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

func _resource_type_for_job(job_type: String) -> String:
    match job_type:
        "CHOP_TREE":
            return "tree"
        "GATHER_STONE":
            return "stone"
        "GATHER_FOOD":
            return "berry"
    return ""

func _resource_id_at_cell(target_cell: Vector2i, resource_type: String = "") -> String:
    return _resource_id_at_world_cell(world_cell_for_projected_cell(target_cell), resource_type)

func _resource_id_at_world_cell(target_world_cell: Vector3i, resource_type: String = "") -> String:
    var payload: Dictionary = _payload_for_world_cell(target_world_cell)
    if not payload.is_empty() and str(payload.get("resource_id", "")) != "":
        var cell_resource: Dictionary = resources.get(str(payload.get("resource_id", "")), {})
        if resource_type == "" or str(cell_resource.get("type", "")) == resource_type:
            return str(payload.get("resource_id", ""))
    for id in _sorted_ids(resources):
        var resource: Dictionary = resources[id]
        if resource_type != "" and str(resource.get("type", "")) != resource_type:
            continue
        var resource_world_cell: Vector3i
        var raw_world_cell: Array = resource.get("world_cell", [])
        if raw_world_cell.size() >= 3:
            resource_world_cell = _array_to_vector3i(raw_world_cell)
        else:
            var pos: Array = resource.get("position", [])
            if pos.size() < 2:
                continue
            resource_world_cell = world_cell_for_projected_cell(Vector2i(int(pos[0]), int(pos[1])))
        if resource_world_cell == target_world_cell:
            return str(id)
    return ""

func _cleanup_completed_jobs() -> void:
    for job_id in job_board.sorted_job_ids():
        if job_board.jobs[job_id].status == "complete":
            job_board.jobs.erase(job_id)

func canonical_snapshot() -> Dictionary:
    return {
        "tick": tick,
        "world_seed": world_seed,
        "id_counters": _sorted_dictionary(id_counters),
        "rng_streams": _rng_snapshot(),
        "world": {"width": WorldgenScript.WORLD_WIDTH, "height": WorldgenScript.LAYER_ROW_COUNTS[WorldgenScript.SURFACE_LAYER], "cells": _world_cells_for_snapshot()},
        "chunk_world": _authoritative_chunk_snapshot(),
        "resources": _resources_snapshot(),
        "units": _object_snapshot(units),
        "items": _object_snapshot(items),
        "stockpiles": _object_snapshot(stockpiles),
        "constructions": _object_snapshot(constructions),
        "workshop_orders": _workshop_orders_snapshot(),
        "jobs": job_board.to_canonical_array(),
        "command_queue": _command_queue_snapshot(),
    }

func _world_cells_for_snapshot() -> Array:
    if chunk_world_store == null:
        return []
    var cells: Array = []
    for cell_data in chunk_world_store.to_canonical_array():
        var wc: Array = cell_data.get("world_cell", [])
        if wc.size() < 3:
            continue
        var payload: Dictionary = cell_data.get("payload", {})
        cells.append({
            "x": int(wc[0]),
            "z": int(wc[2]),
            "depth": int(wc[1]),
            "surface_height": int(payload.get("surface_height", 0)),
            "terrain": str(payload.get("terrain", "")),
            "material_key": str(payload.get("material_key", "")),
        })
    return cells

func _authoritative_chunk_snapshot() -> Dictionary:
    return {
        "metadata": _sorted_dictionary(chunk_world_store.get_metadata()),
        "cells": chunk_world_store.to_canonical_array(),
    }

func state_hash() -> String:
    return JSON.stringify(canonical_snapshot()).sha256_text()

func _rng_snapshot() -> Dictionary:
    return {
        "event_rng": rng_streams["event_rng"].to_canonical_dict(),
        "unit_rng": rng_streams["unit_rng"].to_canonical_dict(),
        "world_rng": rng_streams["world_rng"].to_canonical_dict(),
    }

func _resources_snapshot() -> Array:
    var arr: Array = []
    for id in _sorted_ids(resources):
        var resource: Dictionary = resources[id].duplicate(true)
        var position: Array = resource.get("position", [])
        if position.size() >= 2:
            var world_cell: Vector3i = world_cell_for_projected_cell(Vector2i(int(position[0]), int(position[1])))
            resource["world_cell"] = [world_cell.x, world_cell.y, world_cell.z]
        arr.append(_sorted_dictionary(resource))
    return arr

func _object_snapshot(source: Dictionary) -> Array:
    var arr: Array = []
    for id in _sorted_ids(source):
        arr.append(source[id].to_canonical_dict())
    return arr

func _workshop_orders_snapshot() -> Array:
    var arr: Array = []
    for id in _sorted_ids(workshop_orders):
        arr.append(_sorted_dictionary(workshop_orders[id].duplicate(true)))
    return arr

func _command_queue_snapshot() -> Array:
    var arr: Array = []
    command_queue.sort_custom(_compare_commands)
    for command in command_queue:
        arr.append(_sorted_dictionary(command))
    return arr

func _sorted_ids(source: Dictionary) -> Array:
    var ids: Array = source.keys()
    ids.sort()
    return ids

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

func _serialize_cells(cells: Array) -> Array:
    var output: Array = []
    for cell in ZoneScript.canonical_cells(cells):
        output.append([cell.x, cell.y])
    return output

func _serialize_world_cells(cells: Array) -> Array:
    var output: Array = []
    for cell in _world_cells_from_cells(cells):
        output.append([cell.x, cell.y, cell.z])
    return output

func _serialize_single_world_cell(cell: Vector3i) -> Array:
    return [cell.x, cell.y, cell.z]

func _with_world_cells(cells: Array) -> Array:
    if cells.is_empty():
        return []
    return _world_cells_from_cells(cells)

func _with_world_cells_payload(payload: Dictionary) -> Dictionary:
    var output: Dictionary = payload.duplicate(true)
    if not output.has("world_cells") and output.has("cells"):
        output["world_cells"] = _serialize_world_cells(output.get("cells", []))
    return output
