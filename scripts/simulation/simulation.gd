class_name Simulation
extends RefCounted

const WORLD_WIDTH := 16
const WORLD_HEIGHT := 16
const INITIAL_UNIT_COUNT := 3

const TOOL_MODE_GATHER_WOOD := "gather_wood"
const TOOL_MODE_GATHER_STONE := "gather_stone"
const TOOL_MODE_GATHER_FOOD := "gather_food"

const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const GridWorldScript := preload("res://scripts/simulation/grid_world.gd")
const UnitScript := preload("res://scripts/simulation/unit.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")
const StockpileScript := preload("res://scripts/simulation/stockpile.gd")
const BuildingDefinitionScript := preload("res://scripts/simulation/building_definition.gd")
const ConstructionRecordScript := preload("res://scripts/simulation/construction_record.gd")
const JobScript := preload("res://scripts/simulation/job.gd")
const JobBoardScript := preload("res://scripts/simulation/job_board.gd")

var tick: int = 0
var world_seed: int = 1
var rng_streams: Dictionary = {}
var world
var units: Dictionary = {}
var items: Dictionary = {}
var stockpiles: Dictionary = {}
var constructions: Dictionary = {}
var resources: Dictionary = {}
var job_board
var command_queue: Array[Dictionary] = []
var id_counters: Dictionary = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0, "stockpile": 0, "construction": 0}

func initialize_new_game(seed_value: int = 1) -> void:
    tick = 0
    world_seed = seed_value
    rng_streams = {
        "world_rng": RngScript.new(seed_value),
        "unit_rng": RngScript.new(seed_value ^ 0x00c0ffee),
        "event_rng": RngScript.new(seed_value ^ 0x005eeded),
    }
    command_queue = []
    id_counters = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0, "stockpile": 0, "construction": 0}
    resources = {}
    items = {}
    stockpiles = {}
    constructions = {}
    units = {}
    job_board = JobBoardScript.new()
    world = GridWorldScript.new(WORLD_WIDTH, WORLD_HEIGHT)
    world.create_forest(rng_streams["world_rng"], resources)
    _spawn_initial_units()

func _spawn_initial_units() -> void:
    var starts: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
    var names: Array[String] = ["Ari", "Bo", "Cy"]
    for i in range(INITIAL_UNIT_COUNT):
        var id: String = allocate_id("unit")
        units[id] = UnitScript.new(id, names[i], starts[i])

func allocate_id(prefix: String) -> String:
    id_counters[prefix] = int(id_counters.get(prefix, 0)) + 1
    return "%s_%06d" % [prefix, id_counters[prefix]]

func create_stockpile(cells: Array, accepted_item_types: Array) -> String:
    var id: String = allocate_id("stockpile")
    stockpiles[id] = StockpileScript.new(id, accepted_item_types, cells)
    return id

func designate_stockpile(start_cell: Vector2i, payload: Dictionary) -> String:
    # Create a stockpile from a single seed cell, expanding to adjacent walkable cells
    if not world.in_bounds(start_cell):
        return ""
    var cell = world.get_cell(start_cell)
    if cell == null or not cell.walkable:
        return ""
    
    var accepted_types: Array = payload.get("accepted_item_types", ["wood", "stone", "food"])
    var cells: Array[Vector2i] = [start_cell]
    
    # Simple 3x3 expansion: add adjacent walkable cells
    var directions: Array[Vector2i] = [
        Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
        Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)
    ]
    for dir in directions:
        var neighbor: Vector2i = start_cell + dir
        if world.in_bounds(neighbor):
            var neighbor_cell = world.get_cell(neighbor)
            if neighbor_cell != null and neighbor_cell.walkable:
                cells.append(neighbor)
    
    return create_stockpile(cells, accepted_types)

func get_building_definition(building_type: String) -> Dictionary:
    return BuildingDefinitionScript.get_definition(building_type)

func queue_blueprint_command(command_tick: int, player_id: String, building_type: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    var result: Dictionary = validate_blueprint_target(building_type, target_cell)
    if not bool(result["valid"]):
        return result
    var command_payload: Dictionary = payload.duplicate(true)
    command_payload["building_type"] = building_type
    result["command"] = queue_command(command_tick, player_id, "PLACE_BLUEPRINT", target_cell, command_payload)
    return result

func validate_blueprint_target(building_type: String, target_cell: Vector2i) -> Dictionary:
    var definition: Dictionary = get_building_definition(building_type)
    if definition.is_empty():
        return {"valid": false, "warning": "Unknown building type: " + building_type, "construction_id": ""}
    if world == null or not world.in_bounds(target_cell):
        return {"valid": false, "warning": "Blueprint target is out of bounds", "construction_id": ""}
    var cell = world.get_cell(target_cell)
    if cell == null:
        return {"valid": false, "warning": "Blueprint target is out of bounds", "construction_id": ""}
    if not bool(cell.walkable):
        return {"valid": false, "warning": "Blueprint target must be walkable", "construction_id": ""}
    if str(cell.building_id) != "":
        return {"valid": false, "warning": "Blueprint target already has a building", "construction_id": ""}
    if str(cell.resource_id) != "":
        return {"valid": false, "warning": "Blueprint target contains a resource", "construction_id": ""}
    if _has_loose_item_at(target_cell):
        return {"valid": false, "warning": "Blueprint target contains a loose item", "construction_id": ""}
    var existing_id: String = _find_construction_at(building_type, target_cell)
    if existing_id != "":
        return {"valid": true, "warning": "", "construction_id": existing_id}
    if _has_conflicting_construction_at(target_cell):
        return {"valid": false, "warning": "Blueprint target already has a blueprint", "construction_id": ""}
    return {"valid": true, "warning": "", "construction_id": ""}

func create_construction(building_type: String, target_cell: Vector2i, priority: int = 1) -> Dictionary:
    var validation: Dictionary = validate_blueprint_target(building_type, target_cell)
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
        ""
    )
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
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.target_cell == target_cell and construction.status != "cancelled":
            return true
    return false

func _has_loose_item_at(target_cell: Vector2i) -> bool:
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.position == target_cell and item.holder_unit_id == "":
            return true
    return false

func assign_item_to_stockpile(item_id: String, stockpile_id: String) -> bool:
    if not items.has(item_id) or not stockpiles.has(stockpile_id):
        return false
    var item = items[item_id]
    var stockpile = stockpiles[stockpile_id]
    if not stockpile.accepts_item_type(item.item_type):
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
    var id: String = command_id
    if id == "":
        id = allocate_id("command")
    return {
        "tick": command_tick,
        "player_id": player_id,
        "command_type": command_type,
        "target_cell": [target_cell.x, target_cell.y],
        "payload": _sorted_dictionary(payload),
        "command_id": id,
    }

func queue_command(command_tick: int, player_id: String, command_type: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    var command: Dictionary = make_command(command_tick, player_id, command_type, target_cell, payload)
    queue_existing_command(command)
    return command

func queue_designation_command(command_tick: int, player_id: String, tool_mode: String, target_cell: Vector2i, payload: Dictionary = {}) -> Dictionary:
    var result: Dictionary = validate_designation_target(tool_mode, target_cell)
    if not bool(result["valid"]):
        return result
    result["command"] = queue_command(command_tick, player_id, str(result["command_type"]), target_cell, payload)
    return result

func queue_stockpile_designation_command(command_tick: int, player_id: String, target_cell: Vector2i, accepted_item_types: Array = ["wood", "stone", "food"]) -> Dictionary:
    var result: Dictionary = validate_stockpile_designation_target(target_cell)
    if not bool(result["valid"]):
        return result
    var payload: Dictionary = {"accepted_item_types": accepted_item_types}
    result["command"] = queue_command(command_tick, player_id, "DESIGNATE_STOCKPILE", target_cell, payload)
    return result

func validate_stockpile_designation_target(target_cell: Vector2i) -> Dictionary:
    if world == null or not world.in_bounds(target_cell):
        return {"valid": false, "warning": "Stockpile target is out of bounds", "stockpile_id": ""}
    var cell = world.get_cell(target_cell)
    if cell == null or not cell.walkable:
        return {"valid": false, "warning": "Stockpile target must be walkable", "stockpile_id": ""}
    return {"valid": true, "warning": "", "stockpile_id": ""}

func validate_designation_target(tool_mode: String, target_cell: Vector2i) -> Dictionary:
    var spec: Dictionary = _designation_spec_for_tool_mode(tool_mode)
    if spec.is_empty():
        return {"valid": false, "warning": "Unknown designation tool: " + tool_mode, "command_type": ""}
    if world == null or not world.in_bounds(target_cell):
        return {"valid": false, "warning": "Designation target is out of bounds", "command_type": str(spec["command_type"])}
    var cell = world.get_cell(target_cell)
    if cell == null or cell.resource_id == "":
        return {"valid": false, "warning": "Select a cell with " + str(spec["resource_label"]), "command_type": str(spec["command_type"])}
    var resource: Dictionary = resources.get(cell.resource_id, {})
    if resource.get("type", "") != spec["resource_type"]:
        return {"valid": false, "warning": "Select a " + str(spec["resource_label"]) + " target", "command_type": str(spec["command_type"])}
    return {"valid": true, "warning": "", "command_type": str(spec["command_type"])}

func _designation_spec_for_tool_mode(tool_mode: String) -> Dictionary:
    match tool_mode:
        TOOL_MODE_GATHER_WOOD:
            return {"resource_type": "tree", "resource_label": "tree", "command_type": "DESIGNATE_CHOP"}
        TOOL_MODE_GATHER_STONE:
            return {"resource_type": "stone", "resource_label": "stone", "command_type": "DESIGNATE_GATHER_STONE"}
        TOOL_MODE_GATHER_FOOD:
            return {"resource_type": "berry", "resource_label": "berry", "command_type": "DESIGNATE_GATHER_FOOD"}
    return {}

func queue_existing_command(command: Dictionary) -> void:
    command_queue.append(_normalize_command(command))
    command_queue.sort_custom(_compare_commands)

func _normalize_command(command: Dictionary) -> Dictionary:
    var target: Array = command.get("target_cell", [0, 0])
    return {
        "tick": int(command.get("tick", 0)),
        "player_id": str(command.get("player_id", "player_001")),
        "command_type": str(command.get("command_type", "")),
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
    return "%012d|%s|%s|%s|%012d|%012d|%s" % [
        int(command["tick"]),
        str(command["command_id"]),
        str(command["player_id"]),
        str(command["command_type"]),
        int(command["target_cell"][0]),
        int(command["target_cell"][1]),
        JSON.stringify(command["payload"]),
    ]

func step_tick() -> void:
    tick += 1
    _apply_due_commands()
    create_haul_jobs_for_loose_items()
    create_build_jobs_for_ready_constructions()
    _advance_needs()
    _assign_jobs()
    _advance_units()
    _cleanup_completed_jobs()

func create_haul_jobs_for_loose_items() -> void:
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.holder_unit_id != "" or item.stockpile_id != "" or item.reserved_by_job_id != "":
            continue
        var stockpile_id: String = _find_stockpile_for_item_type(item.item_type)
        if stockpile_id == "":
            continue
        var destination_cell: Vector2i = _first_stockpile_cell(stockpile_id)
        if destination_cell == Vector2i(-1, -1):
            continue
        var job_id: String = allocate_id("job")
        if not reserve_item_for_job(item_id, job_id):
            continue
        var job = JobScript.new(job_id, "HAUL_ITEM", item.position, 1)
        job.required_items = {
            "item_id": item_id,
            "stockpile_id": stockpile_id,
            "destination_cell": [destination_cell.x, destination_cell.y],
            "phase": "pickup",
        }
        job_board.add_job(job)

func create_build_jobs_for_ready_constructions() -> void:
    for construction_id in _sorted_ids(constructions):
        _try_reserve_construction_resources(construction_id)

func _find_stockpile_for_item_type(item_type: String) -> String:
    for stockpile_id in _sorted_ids(stockpiles):
        var stockpile = stockpiles[stockpile_id]
        if stockpile.accepts_item_type(item_type) and stockpile.cells.size() > 0:
            return stockpile_id
    return ""

func _first_stockpile_cell(stockpile_id: String) -> Vector2i:
    if not stockpiles.has(stockpile_id):
        return Vector2i(-1, -1)
    var stockpile = stockpiles[stockpile_id]
    if stockpile.cells.size() == 0:
        return Vector2i(-1, -1)
    return stockpile.cells[0]

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
    var target: Vector2i = Vector2i(int(command["target_cell"][0]), int(command["target_cell"][1]))
    match command["command_type"]:
        "DESIGNATE_CHOP":
            _create_job_for_resource(target, "tree", "CHOP_TREE", int(command["payload"].get("priority", 1)))
        "DESIGNATE_GATHER_STONE":
            _create_job_for_resource(target, "stone", "GATHER_STONE", int(command["payload"].get("priority", 1)))
        "DESIGNATE_GATHER_FOOD":
            _create_job_for_resource(target, "berry", "GATHER_FOOD", int(command["payload"].get("priority", 1)))
        "DESIGNATE_STOCKPILE":
            designate_stockpile(target, command["payload"])
        "PLACE_BLUEPRINT":
            create_construction(str(command["payload"].get("building_type", "")), target, int(command["payload"].get("priority", 1)))
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
    var cell = world.get_cell(target)
    if cell == null or cell.resource_id == "":
        return
    var resource = resources.get(cell.resource_id, {})
    if resource.get("type", "") != resource_type:
        return
    if job_board.has_open_job_at(job_type, target):
        return
    var job = JobScript.new(allocate_id("job"), job_type, target, priority)
    job_board.add_job(job)

func _advance_needs() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        unit.needs["hunger"] = int(unit.needs.get("hunger", 0)) + 1
        if unit.state in ["working", "walking"]:
            unit.needs["energy"] = max(0, int(unit.needs.get("energy", 100)) - 1)

func _assign_jobs() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        if unit.current_job_id != "":
            continue
        var job = job_board.claim_next_open_job_for_unit(unit)
        if job != null:
            unit.current_job_id = job.id
            unit.state = "walking"

func _advance_units() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        if unit.current_job_id == "":
            unit.state = "idle"
            continue
        var job = job_board.jobs.get(unit.current_job_id)
        if job == null:
            unit.current_job_id = ""
            unit.state = "idle"
            continue
        if job.type == "HAUL_ITEM":
            _advance_haul_job(unit, job)
            continue
        if unit.position != job.target_cell:
            unit.position = _step_towards(unit.position, job.target_cell)
            unit.state = "walking"
        else:
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
    var destination: Vector2i = _haul_destination_cell(job)
    if destination == Vector2i(-1, -1):
        _fail_haul_job(unit, job, item_id)
        return
    var phase: String = str(job.required_items.get("phase", "pickup"))
    if phase == "pickup":
        if unit.position != item.position:
            unit.position = _step_towards(unit.position, item.position)
            unit.state = "walking"
            return
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
    if unit.position != destination:
        unit.position = _step_towards(unit.position, destination)
        item.position = unit.position
        unit.state = "carrying"
        return
    assign_item_to_stockpile(item_id, stockpile_id)
    item.position = destination
    item.holder_unit_id = ""
    release_item_reservation(item_id, job.id)
    unit.inventory.erase(item_id)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

func _haul_destination_cell(job) -> Vector2i:
    var raw: Array = job.required_items.get("destination_cell", [])
    if raw.size() < 2:
        return Vector2i(-1, -1)
    return Vector2i(int(raw[0]), int(raw[1]))

func _fail_haul_job(unit, job, item_id: String) -> void:
    release_item_reservation(item_id, job.id)
    if items.has(item_id):
        var item = items[item_id]
        if item.holder_unit_id == unit.id:
            item.holder_unit_id = ""
            item.position = unit.position
    unit.inventory.erase(item_id)
    job.status = "failed"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

func _step_towards(from_cell: Vector2i, to_cell: Vector2i) -> Vector2i:
    var result: Vector2i = from_cell
    if result.x != to_cell.x:
        result.x += 1 if to_cell.x > result.x else -1
    elif result.y != to_cell.y:
        result.y += 1 if to_cell.y > result.y else -1
    return result

func _complete_job(unit, job) -> void:
    if job.type == "BUILD_CONSTRUCTION" or job.type == "BUILD_STRUCTURE":
        _complete_build_construction_job(unit, job)
        return
    var cell = world.get_cell(job.target_cell)
    var resource_id: String = cell.resource_id if cell != null else ""
    if cell != null and resource_id != "":
        var resource: Dictionary = resources.get(resource_id, {})
        if resource.get("type", "") == _resource_type_for_job(job.type):
            for item_type in _sorted_ids(job.produced_items):
                var item_id: String = allocate_id("item")
                items[item_id] = ItemScript.new(item_id, item_type, int(job.produced_items[item_type]), job.target_cell)
            resources.erase(resource_id)
            world.clear_resource(job.target_cell, resource_id)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

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
    var cell = world.get_cell(construction.target_cell)
    if cell == null or str(cell.building_id) != "":
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
    cell.building_id = building_id
    var definition: Dictionary = get_building_definition(construction.type)
    if bool(definition.get("blocks_movement", false)):
        cell.walkable = false
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

func _cleanup_completed_jobs() -> void:
    # Keep completed jobs in the canonical snapshot for replay/debug auditing.
    pass

func canonical_snapshot() -> Dictionary:
    return {
        "tick": tick,
        "world_seed": world_seed,
        "id_counters": _sorted_dictionary(id_counters),
        "rng_streams": _rng_snapshot(),
        "world": {"width": world.width, "height": world.height, "cells": world.to_canonical_array()},
        "resources": _resources_snapshot(),
        "units": _object_snapshot(units),
        "items": _object_snapshot(items),
        "stockpiles": _object_snapshot(stockpiles),
        "constructions": _object_snapshot(constructions),
        "jobs": job_board.to_canonical_array(),
        "command_queue": _command_queue_snapshot(),
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
        var resource: Dictionary = resources[id]
        arr.append(_sorted_dictionary(resource))
    return arr

func _object_snapshot(source: Dictionary) -> Array:
    var arr: Array = []
    for id in _sorted_ids(source):
        arr.append(source[id].to_canonical_dict())
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
