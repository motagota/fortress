class_name Simulation
extends RefCounted

# Authoritative colony simulation over the layered floor/wall world.
# Everything is addressed in Vector3i(x, y, z); there are no 2D projections.

const C := preload("res://scripts/simulation/world_constants.gd")
const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const WorldScript := preload("res://scripts/simulation/world.gd")
const WorldgenScript := preload("res://scripts/simulation/worldgen.gd")
const UnitScript := preload("res://scripts/simulation/unit.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")
const ZoneScript := preload("res://scripts/simulation/zone.gd")
const StockpileScript := preload("res://scripts/simulation/stockpile.gd")
const BuildingDefinitionScript := preload("res://scripts/simulation/building_definition.gd")
const ConstructionRecordScript := preload("res://scripts/simulation/construction_record.gd")
const JobScript := preload("res://scripts/simulation/job.gd")
const JobBoardScript := preload("res://scripts/simulation/job_board.gd")

const INITIAL_UNIT_COUNT := 3
const HUNGER_EAT_THRESHOLD := 20
const HUNGER_AFTER_EATING := 0
const RECIPE_COOK_MEAL := "cook_meal"
const DEEP_MINING_COLLAPSE_DEPTH := 20      # mining at/below this y can collapse
const DEEP_MINING_COLLAPSE_CHANCE := 25
const UNREACHABLE_JOB_RELEASE_TICKS := 4
const PATHFIND_MAX_NODES := 8000
const INVALID_CELL := Vector3i(-2147483648, -2147483648, -2147483648)

const TOOL_MINE := "mine"
const TOOL_CHANNEL := "channel"
const TOOL_BUILD_STAIR := "build_stair"
const TOOL_CHOP := "chop"
const TOOL_GATHER := "gather"

var tick: int = 0
var world_seed: int = 1
var rng_streams: Dictionary = {}
var world
var units: Dictionary = {}
var items: Dictionary = {}
var stockpiles: Dictionary = {}
var constructions: Dictionary = {}
var workshop_orders: Dictionary = {}
var resources: Dictionary = {}
var job_board
var command_queue: Array[Dictionary] = []
var id_counters: Dictionary = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0, "stockpile": 0, "construction": 0, "workshop_order": 0}

# --- Lifecycle ----------------------------------------------------------------

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
    world = WorldScript.new()
    WorldgenScript.generate(world, resources, world_seed)
    _spawn_initial_units()

func allocate_id(prefix: String) -> String:
    id_counters[prefix] = int(id_counters.get(prefix, 0)) + 1
    return "%s_%06d" % [prefix, id_counters[prefix]]

func _spawn_initial_units() -> void:
    var names: Array[String] = ["Ari", "Bo", "Cy"]
    var spots: Array[Vector3i] = _spawn_cells(INITIAL_UNIT_COUNT)
    for i in range(min(INITIAL_UNIT_COUNT, spots.size())):
        var id: String = allocate_id("unit")
        units[id] = UnitScript.new(id, names[i % names.size()], spots[i])

func _spawn_cells(count: int) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    var gy: int = C.SURFACE_Y_MEAN
    for z in range(20, 28):
        for x in range(20, 28):
            var addr := Vector3i(x, world.surface_y(x, z), z)
            if world.is_walkable(addr):
                output.append(addr)
                if output.size() >= count:
                    return output
    if output.is_empty():
        output.append(Vector3i(24, gy, 24))
    return output

# --- Tick ---------------------------------------------------------------------

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

# --- Commands -----------------------------------------------------------------

func make_command(command_tick: int, player_id: String, command_type: String, target_cell: Vector3i, payload: Dictionary = {}, command_id: String = "") -> Dictionary:
    var id: String = command_id
    if id == "":
        id = allocate_id("command")
    return {
        "tick": command_tick,
        "player_id": player_id,
        "command_type": command_type,
        "target_cell": [target_cell.x, target_cell.y, target_cell.z],
        "payload": _sorted_dictionary(payload),
        "command_id": id,
    }

func queue_command(command_tick: int, player_id: String, command_type: String, target_cell: Vector3i, payload: Dictionary = {}) -> Dictionary:
    var command: Dictionary = make_command(command_tick, player_id, command_type, target_cell, payload)
    queue_existing_command(command)
    return command

func queue_existing_command(command: Dictionary) -> void:
    command_queue.append(_normalize_command(command))
    command_queue.sort_custom(_compare_commands)

func _normalize_command(command: Dictionary) -> Dictionary:
    var target: Array = command.get("target_cell", [0, 0, 0])
    return {
        "tick": int(command.get("tick", 0)),
        "player_id": str(command.get("player_id", "player_001")),
        "command_type": str(command.get("command_type", "")),
        "target_cell": [int(target[0]), int(target[1]), int(target[2])],
        "payload": _sorted_dictionary(command.get("payload", {})),
        "command_id": str(command.get("command_id", "cmd_000000")),
    }

func _compare_commands(a: Dictionary, b: Dictionary) -> bool:
    return _command_sort_key(a) < _command_sort_key(b)

func _command_sort_key(command: Dictionary) -> String:
    return "%012d|%s|%s|%s|%012d|%012d|%012d|%s" % [
        int(command["tick"]),
        str(command["command_id"]),
        str(command["player_id"]),
        str(command["command_type"]),
        int(command["target_cell"][0]),
        int(command["target_cell"][1]),
        int(command["target_cell"][2]),
        JSON.stringify(command["payload"]),
    ]

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
    var target := _array_to_vector3i(command.get("target_cell", []))
    var payload: Dictionary = command.get("payload", {})
    var priority: int = int(payload.get("priority", 1))
    match command["command_type"]:
        "DESIGNATE_CHOP":
            _create_resource_job(target, "tree", "CHOP_TREE", priority)
        "DESIGNATE_GATHER_STONE":
            _create_resource_job(target, "stone", "GATHER_STONE", priority)
        "DESIGNATE_GATHER_FOOD":
            _create_gather_food_job(target, priority)
        "DESIGNATE_MINE":
            _create_mine_job(target, priority)
        "DESIGNATE_CHANNEL":
            _create_channel_job(target, priority)
        "DESIGNATE_BUILD_STAIR":
            _create_stair_job(target, priority)
        "DESIGNATE_STOCKPILE":
            designate_stockpile(target, payload)
        "RESIZE_STOCKPILE":
            resize_stockpile(str(payload.get("stockpile_id", "")), str(payload.get("side", "")), int(payload.get("delta", 0)))
        "SET_STOCKPILE_MODE":
            set_stockpile_mode(str(payload.get("stockpile_id", "")), str(payload.get("storage_mode", "")))
        "PLACE_BLUEPRINT":
            create_construction(str(payload.get("building_type", "")), target, priority, payload.get("cells", []))
        "QUEUE_WORKSHOP_RECIPE":
            create_workshop_order(str(payload.get("building_id", "")), str(payload.get("recipe_id", "")), priority)
        "SET_UNIT_JOB_PRIORITY":
            set_unit_job_type_priority(str(payload.get("unit_id", "")), str(payload.get("job_type", "")), int(payload.get("priority", 1)))

# --- Job creation -------------------------------------------------------------

func _create_resource_job(target: Vector3i, resource_type: String, job_type: String, priority: int) -> void:
    var resource_id: String = _resource_id_at(target, resource_type)
    if resource_id == "":
        return
    if job_board.has_open_job_at(job_type, target):
        return
    var job = JobScript.new(allocate_id("job"), job_type, target, priority)
    job_board.add_job(job)

func _create_gather_food_job(target: Vector3i, priority: int) -> void:
    var resource_id: String = _resource_id_at(target, "")
    if resource_id == "":
        return
    var rtype: String = str(resources.get(resource_id, {}).get("type", ""))
    if not (rtype in ["berry", "wheat"]):
        return
    if job_board.has_open_job_at("GATHER_FOOD", target):
        return
    job_board.add_job(JobScript.new(allocate_id("job"), "GATHER_FOOD", target, priority))

func _create_mine_job(target: Vector3i, priority: int) -> void:
    if not _is_mineable(target):
        return
    if job_board.has_open_job_at("MINE_WALL", target):
        return
    var work_cell := _find_reachable_work_cell(_mine_work_candidates(target))
    if work_cell == INVALID_CELL:
        return
    var job = JobScript.new(allocate_id("job"), "MINE_WALL", target, priority)
    job.required_items["work_cell"] = [work_cell.x, work_cell.y, work_cell.z]
    job_board.add_job(job)

func _create_channel_job(target: Vector3i, priority: int) -> void:
    var cell = world.get_cell(target)
    if cell == null or not cell.has_floor() or cell.has_wall():
        return
    if job_board.has_open_job_at("CHANNEL_FLOOR", target):
        return
    var work_cell := _find_reachable_work_cell(_adjacent_walkable_cells(target))
    if work_cell == INVALID_CELL:
        return
    var job = JobScript.new(allocate_id("job"), "CHANNEL_FLOOR", target, priority)
    job.required_items["work_cell"] = [work_cell.x, work_cell.y, work_cell.z]
    job_board.add_job(job)

func _adjacent_walkable_cells(target: Vector3i) -> Array:
    var candidates: Array = []
    for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
        var n: Vector3i = target + offset
        if world.is_walkable(n):
            candidates.append(n)
    return candidates

func _create_stair_job(target: Vector3i, priority: int) -> void:
    var cell = world.get_cell(target)
    if cell == null or not cell.has_floor() or cell.has_wall() or cell.has_stair():
        return
    if job_board.has_open_job_at("BUILD_STAIR", target):
        return
    job_board.add_job(JobScript.new(allocate_id("job"), "BUILD_STAIR", target, priority))

func set_unit_job_type_priority(unit_id: String, job_type: String, priority: int) -> bool:
    if not units.has(unit_id):
        return false
    units[unit_id].set_job_type_priority(job_type, priority)
    return true

func create_haul_jobs_for_loose_items() -> void:
    var reserved_cells: Dictionary = _active_haul_destination_cells()
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.holder_unit_id != "" or item.stockpile_id != "" or item.reserved_by_job_id != "":
            continue
        var destination: Dictionary = _find_stockpile_destination(item.item_type, reserved_cells)
        if str(destination.get("stockpile_id", "")) == "":
            continue
        var dest_cell: Vector3i = destination["cell"]
        var job_id: String = allocate_id("job")
        if not reserve_item_for_job(item_id, job_id):
            continue
        reserved_cells[_cell_key(dest_cell)] = true
        var job = JobScript.new(job_id, "HAUL_ITEM", item.position, 1)
        job.required_items = {
            "item_id": item_id,
            "stockpile_id": str(destination["stockpile_id"]),
            "destination_cell": [dest_cell.x, dest_cell.y, dest_cell.z],
            "phase": "pickup",
        }
        job_board.add_job(job)

func create_build_jobs_for_ready_constructions() -> void:
    for construction_id in _sorted_ids(constructions):
        _try_reserve_construction_resources(construction_id)

func create_workshop_jobs_for_ready_orders() -> void:
    for order_id in _sorted_ids(workshop_orders):
        _try_reserve_workshop_order(order_id)

# --- Needs --------------------------------------------------------------------

func _advance_needs() -> void:
    for id in _sorted_ids(units):
        var unit = units[id]
        unit.needs["hunger"] = int(unit.needs.get("hunger", 0)) + 1
        if unit.state in ["working", "walking", "carrying"]:
            unit.needs["energy"] = max(0, int(unit.needs.get("energy", 100)) - 1)

func _feed_hungry_units() -> void:
    for unit_id in _sorted_ids(units):
        var unit = units[unit_id]
        if int(unit.needs.get("hunger", 0)) < HUNGER_EAT_THRESHOLD:
            continue
        var food_item_id: String = _find_available_stored_food()
        if food_item_id == "":
            continue
        _consume_food_item(food_item_id)
        unit.needs["hunger"] = HUNGER_AFTER_EATING

func _find_available_stored_food() -> String:
    var meal: String = _find_stored_food_of_type("meal")
    if meal != "":
        return meal
    return _find_stored_food_of_type("food")

func _find_stored_food_of_type(food_type: String) -> String:
    for item_id in _sorted_ids(items):
        var item = items[item_id]
        if item.item_type != food_type:
            continue
        if item.stockpile_id == "" or item.holder_unit_id != "" or item.reserved_by_job_id != "":
            continue
        if not stockpiles.has(item.stockpile_id) or not stockpiles[item.stockpile_id].can_store_items():
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

# --- Job assignment & unit movement ------------------------------------------

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
            unit.state = "idle"
            continue
        if job.type == "HAUL_ITEM":
            _advance_haul_job(unit, job)
            continue
        var dest: Vector3i = _job_destination(job)
        if unit.position != dest:
            var next_cell: Vector3i = _step_towards(unit.position, dest)
            if next_cell == unit.position:
                if _release_job_if_unreachable(unit, job):
                    continue
            else:
                unit.unreachable_job_ticks = 0
                unit.position = next_cell
            unit.state = "walking"
        else:
            unit.unreachable_job_ticks = 0
            unit.state = "working"
            if job.advance_work_tick():
                _complete_job(unit, job)

func _job_destination(job) -> Vector3i:
    if job.type == "MINE_WALL" or job.type == "CHANNEL_FLOOR":
        var raw: Array = job.required_items.get("work_cell", [])
        if raw.size() >= 3:
            return _array_to_vector3i(raw)
    return job.target_cell

func _release_job_if_unreachable(unit, job) -> bool:
    unit.unreachable_job_ticks += 1
    unit.state = "walking"
    if unit.unreachable_job_ticks < UNREACHABLE_JOB_RELEASE_TICKS:
        return false
    if job.type == "HAUL_ITEM":
        _return_carried_item(unit, job)
        job.required_items["phase"] = "pickup"
    job_board.release_job(job.id, unit.id)
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"
    return true

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
    var dest: Vector3i = _array_to_vector3i(job.required_items.get("destination_cell", []))
    var phase: String = str(job.required_items.get("phase", "pickup"))
    if phase == "pickup":
        if unit.position != item.position:
            var next_cell: Vector3i = _step_towards(unit.position, item.position)
            if next_cell == unit.position:
                _release_job_if_unreachable(unit, job)
                return
            unit.unreachable_job_ticks = 0
            unit.position = next_cell
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
    if unit.position != dest:
        var next_cell: Vector3i = _step_towards(unit.position, dest)
        if next_cell == unit.position:
            _release_job_if_unreachable(unit, job)
            return
        unit.unreachable_job_ticks = 0
        unit.position = next_cell
        item.position = unit.position
        unit.state = "carrying"
        return
    unit.unreachable_job_ticks = 0
    item.position = dest
    if not assign_item_to_stockpile(item_id, stockpile_id):
        _fail_haul_job(unit, job, item_id)
        return
    release_item_reservation(item_id, job.id)
    unit.inventory.erase(item_id)
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.state = "idle"

func _return_carried_item(unit, job) -> void:
    var item_id: String = str(job.required_items.get("item_id", ""))
    if items.has(item_id):
        var item = items[item_id]
        if item.holder_unit_id == unit.id:
            item.holder_unit_id = ""
            item.position = unit.position
        unit.inventory.erase(item_id)

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

# --- Job completion -----------------------------------------------------------

func _complete_job(unit, job) -> void:
    match job.type:
        "BUILD_CONSTRUCTION":
            _complete_build_job(unit, job)
        "COOK_MEAL":
            _complete_workshop_job(unit, job)
        "MINE_WALL":
            _complete_mine_job(unit, job)
        "CHANNEL_FLOOR":
            _complete_channel_job(unit, job)
        "BUILD_STAIR":
            _complete_stair_job(unit, job)
        _:
            _complete_resource_job(unit, job)

func _complete_resource_job(unit, job) -> void:
    var resource_type: String = _resource_type_for_job(job.type)
    var resource_id: String = _resource_id_at(job.target_cell, resource_type)
    if resource_id != "":
        var resource: Dictionary = resources.get(resource_id, {})
        if str(resource.get("type", "")) == resource_type or (job.type == "GATHER_FOOD" and str(resource.get("type", "")) in ["berry", "wheat"]):
            for item_type in _sorted_ids(job.produced_items):
                _spawn_item(item_type, int(job.produced_items[item_type]), job.target_cell)
            resources.erase(resource_id)
            _clear_plant(job.target_cell)
    _finish_job(unit, job)

func _complete_mine_job(unit, job) -> void:
    var cell = world.get_cell(job.target_cell)
    if cell == null or not _is_mineable(job.target_cell):
        _fail_job(unit, job)
        return
    var wall: String = cell.wall_material
    if not cell.hidden_ore.is_empty():
        var ore: Dictionary = cell.hidden_ore
        _spawn_item(str(ore.get("item_type", "stone")), int(ore.get("quantity", 1)), job.target_cell)
    else:
        _spawn_item(C.mined_item_type_for_material(wall), 1, job.target_cell)
    # Remove the wall; the floor remains -> the cell becomes walkable.
    cell.wall_material = C.MATERIAL_NONE
    cell.hidden_ore = {}
    cell.mining_tier_required = C.MINING_TIER_NONE
    cell.exposure = "dark"
    if _mine_collapses(job.target_cell):
        cell.wall_material = C.MATERIAL_HARD_ROCK
        cell.floor_material = C.MATERIAL_HARD_ROCK
        cell.mining_tier_required = C.MINING_TIER_HARD_ROCK
    _finish_job(unit, job)

func _complete_channel_job(unit, job) -> void:
    var cell = world.get_cell(job.target_cell)
    if cell == null or not cell.has_floor() or cell.has_wall():
        _fail_job(unit, job)
        return
    _spawn_item(C.mined_item_type_for_material(cell.floor_material), 1, job.target_cell)
    cell.floor_material = C.MATERIAL_NONE  # open shaft downward
    cell.stair = C.STAIR_NONE
    _finish_job(unit, job)

func _complete_stair_job(unit, job) -> void:
    var cell = world.get_cell(job.target_cell)
    if cell == null or not cell.has_floor() or cell.has_wall():
        _fail_job(unit, job)
        return
    cell.stair = C.STAIR_UP_DOWN
    _finish_job(unit, job)

func _mine_collapses(addr: Vector3i) -> bool:
    if addr.y > DEEP_MINING_COLLAPSE_DEPTH:
        return false
    return rng_streams["event_rng"].range_i(0, 99) < DEEP_MINING_COLLAPSE_CHANCE

# --- Resources & items --------------------------------------------------------

func _spawn_item(item_type: String, quantity: int, addr: Vector3i):
    var item_id: String = allocate_id("item")
    items[item_id] = ItemScript.new(item_id, item_type, quantity, addr)
    return items[item_id]

func _clear_plant(addr: Vector3i) -> void:
    var cell = world.get_cell(addr)
    if cell != null:
        cell.plant = C.PLANT_NONE
        cell.resource_id = ""

func _resource_type_for_job(job_type: String) -> String:
    match job_type:
        "CHOP_TREE":
            return "tree"
        "GATHER_STONE":
            return "stone"
        "GATHER_FOOD":
            return "berry"
    return ""

func _resource_id_at(addr: Vector3i, resource_type: String = "") -> String:
    var cell = world.peek_cell(addr)
    if cell.resource_id != "":
        var res: Dictionary = resources.get(cell.resource_id, {})
        if resource_type == "" or str(res.get("type", "")) == resource_type \
                or (resource_type == "berry" and str(res.get("type", "")) in ["berry", "wheat"]):
            return cell.resource_id
    for id in _sorted_ids(resources):
        var resource: Dictionary = resources[id]
        if resource_type != "" and str(resource.get("type", "")) != resource_type:
            if not (resource_type == "berry" and str(resource.get("type", "")) in ["berry", "wheat"]):
                continue
        if _array_to_vector3i(resource.get("world_cell", [])) == addr:
            return str(id)
    return ""

func _is_mineable(addr: Vector3i) -> bool:
    var cell = world.peek_cell(addr)
    if not cell.has_wall():
        return false
    return cell.mining_tier_required > C.MINING_TIER_NONE and cell.mining_tier_required <= C.MINING_TIER_BASIC \
        or _is_basic_mineable(cell.wall_material)

func _is_basic_mineable(material: String) -> bool:
    return material in [C.MATERIAL_GRASS, C.MATERIAL_DIRT, C.MATERIAL_CLAY, C.MATERIAL_SAND,
        C.MATERIAL_GRAVEL, C.MATERIAL_LOOSE_STONE, C.MATERIAL_SOFT_ROCK]

func _mine_work_candidates(target: Vector3i) -> Array:
    var candidates: Array = []
    for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
        var n: Vector3i = target + offset
        if world.is_walkable(n):
            candidates.append(n)
    var above: Vector3i = target + Vector3i(0, 1, 0)
    if world.is_walkable(above):
        candidates.append(above)
    return candidates

func _find_reachable_work_cell(candidates: Array) -> Vector3i:
    for unit_id in _sorted_ids(units):
        var unit = units[unit_id]
        for candidate in candidates:
            if unit.position == candidate or _path_between(unit.position, candidate).size() >= 2:
                return candidate
    if not candidates.is_empty():
        return candidates[0]
    return INVALID_CELL

# --- Pathfinding (BFS over walkable neighbours incl. stairs) -------------------

func _step_towards(from_cell: Vector3i, to_cell: Vector3i) -> Vector3i:
    if from_cell == to_cell:
        return from_cell
    var path: Array = _path_between(from_cell, to_cell)
    if path.size() < 2:
        return from_cell
    return path[1]

func _path_between(from_cell: Vector3i, to_cell: Vector3i) -> Array:
    if from_cell == to_cell:
        return [from_cell]
    if not world.is_walkable(from_cell) or not world.is_walkable(to_cell):
        return []
    var frontier: Array = [from_cell]
    var came_from: Dictionary = {_cell_key(from_cell): from_cell}
    var cursor: int = 0
    var expanded: int = 0
    while cursor < frontier.size():
        var current: Vector3i = frontier[cursor]
        cursor += 1
        if current == to_cell:
            break
        expanded += 1
        if expanded > PATHFIND_MAX_NODES:
            break
        for neighbor in world.neighbors_for_movement(current):
            var key: String = _cell_key(neighbor)
            if came_from.has(key):
                continue
            came_from[key] = current
            frontier.append(neighbor)
    if not came_from.has(_cell_key(to_cell)):
        return []
    var path: Array = [to_cell]
    var step: Vector3i = to_cell
    while step != from_cell:
        step = came_from[_cell_key(step)]
        path.push_front(step)
    return path

# --- Stockpiles ---------------------------------------------------------------

func designate_stockpile(target: Vector3i, payload: Dictionary) -> String:
    var accepted: Array = payload.get("accepted_item_types", ["wood", "stone", "dirt", "food", "meal"])
    var cells: Array = payload.get("cells", [[target.x, target.y, target.z]])
    return create_stockpile(cells, accepted, str(payload.get("storage_mode", "both")))

func create_stockpile(cells: Array, accepted_item_types: Array, storage_mode: String = "both") -> String:
    var valid: Array[Vector3i] = _valid_stockpile_cells(cells)
    if valid.is_empty() or _cells_overlap_stockpiles(valid):
        return ""
    var id: String = allocate_id("stockpile")
    stockpiles[id] = StockpileScript.new(id, accepted_item_types, valid, storage_mode)
    return id

func find_stockpile_at_cell(target: Vector3i) -> String:
    for stockpile_id in _sorted_ids(stockpiles):
        if stockpiles[stockpile_id].contains_cell(target):
            return stockpile_id
    return ""

func set_stockpile_mode(stockpile_id: String, storage_mode: String) -> bool:
    if not stockpiles.has(stockpile_id):
        return false
    return stockpiles[stockpile_id].set_storage_mode(storage_mode)

func resize_stockpile(stockpile_id: String, side: String, delta: int) -> bool:
    if not stockpiles.has(stockpile_id) or not (side in ["north", "south", "west", "east"]) or (delta != -1 and delta != 1):
        return false
    var resized: Array[Vector3i] = _resized_stockpile_cells(stockpile_id, side, delta)
    var valid: Array[Vector3i] = _valid_stockpile_cells(resized)
    if valid.size() != resized.size() or _cells_overlap_stockpiles(valid, stockpile_id):
        return false
    stockpiles[stockpile_id].cells = ZoneScript.canonical_cells(valid)
    return true

func _valid_stockpile_cells(cells: Array) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    for raw in cells:
        var cell: Vector3i
        if raw is Vector3i:
            cell = raw
        elif raw is Array and raw.size() >= 3:
            cell = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
        else:
            continue
        if world.is_walkable(cell):
            output.append(cell)
    return ZoneScript.canonical_cells(output)

func _cells_overlap_stockpiles(cells: Array, ignored: String = "") -> bool:
    var requested: Dictionary = {}
    for cell in cells:
        requested[_cell_key(cell)] = true
    for stockpile_id in _sorted_ids(stockpiles):
        if stockpile_id == ignored:
            continue
        for cell in stockpiles[stockpile_id].cells:
            if requested.has(_cell_key(cell)):
                return true
    return false

func _stockpile_bounds(cells: Array) -> Dictionary:
    if cells.is_empty():
        return {}
    var min_x: int = cells[0].x
    var max_x: int = cells[0].x
    var min_z: int = cells[0].z
    var max_z: int = cells[0].z
    var y: int = cells[0].y
    for cell in cells:
        min_x = mini(min_x, cell.x)
        max_x = maxi(max_x, cell.x)
        min_z = mini(min_z, cell.z)
        max_z = maxi(max_z, cell.z)
    return {"min_x": min_x, "max_x": max_x, "min_z": min_z, "max_z": max_z, "y": y}

func _resized_stockpile_cells(stockpile_id: String, side: String, delta: int) -> Array[Vector3i]:
    var bounds: Dictionary = _stockpile_bounds(stockpiles[stockpile_id].cells)
    if bounds.is_empty():
        return []
    var min_x: int = int(bounds["min_x"])
    var max_x: int = int(bounds["max_x"])
    var min_z: int = int(bounds["min_z"])
    var max_z: int = int(bounds["max_z"])
    var y: int = int(bounds["y"])
    match side:
        "north": min_z -= delta
        "south": max_z += delta
        "west": min_x -= delta
        "east": max_x += delta
    if min_x > max_x or min_z > max_z:
        return []
    var cells: Array[Vector3i] = []
    for x in range(min_x, max_x + 1):
        for z in range(min_z, max_z + 1):
            cells.append(Vector3i(x, y, z))
    return cells

func assign_item_to_stockpile(item_id: String, stockpile_id: String) -> bool:
    if not items.has(item_id) or not stockpiles.has(stockpile_id):
        return false
    var item = items[item_id]
    var stockpile = stockpiles[stockpile_id]
    if not stockpile.accepts_item_type(item.item_type) or not stockpile.can_store_items():
        return false
    if not stockpile.contains_cell(item.position):
        return false
    if _cell_has_visible_item(item.position, item_id):
        return false
    item.stockpile_id = stockpile_id
    item.holder_unit_id = ""
    return true

func _find_stockpile_destination(item_type: String, reserved_cells: Dictionary) -> Dictionary:
    for stockpile_id in _sorted_ids(stockpiles):
        var stockpile = stockpiles[stockpile_id]
        if not stockpile.can_store_items() or not stockpile.accepts_item_type(item_type):
            continue
        var cell: Vector3i = _first_available_stockpile_cell(stockpile_id, reserved_cells)
        if cell != INVALID_CELL:
            return {"stockpile_id": stockpile_id, "cell": cell}
    return {"stockpile_id": "", "cell": INVALID_CELL}

func _first_available_stockpile_cell(stockpile_id: String, reserved_cells: Dictionary) -> Vector3i:
    if not stockpiles.has(stockpile_id):
        return INVALID_CELL
    for cell in stockpiles[stockpile_id].cells:
        if reserved_cells.has(_cell_key(cell)):
            continue
        if _cell_has_visible_item(cell):
            continue
        return cell
    return INVALID_CELL

func _active_haul_destination_cells() -> Dictionary:
    var output: Dictionary = {}
    for job_id in job_board.sorted_job_ids():
        var job = job_board.jobs[job_id]
        if job.type != "HAUL_ITEM" or not (job.status in ["open", "claimed", "in_progress"]):
            continue
        var dest: Vector3i = _array_to_vector3i(job.required_items.get("destination_cell", []))
        if dest != INVALID_CELL:
            output[_cell_key(dest)] = true
    return output

func _cell_has_visible_item(cell: Vector3i, except_item_id: String = "") -> bool:
    for item_id in _sorted_ids(items):
        if item_id == except_item_id:
            continue
        var item = items[item_id]
        if item.holder_unit_id == "" and item.position == cell:
            return true
    return false

# --- Item reservations --------------------------------------------------------

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

# --- Construction & buildings -------------------------------------------------

func get_building_definition(building_type: String) -> Dictionary:
    return BuildingDefinitionScript.get_definition(building_type)

func create_construction(building_type: String, target: Vector3i, priority: int = 1, cells: Array = []) -> Dictionary:
    var definition: Dictionary = get_building_definition(building_type)
    if definition.is_empty():
        return {"ok": false, "warning": "Unknown building type", "construction_id": ""}
    var footprint: Array[Vector3i] = _building_footprint(building_type, target) if cells.is_empty() else _to_cells(cells)
    if footprint.is_empty():
        return {"ok": false, "warning": "Invalid footprint", "construction_id": ""}
    for cell in footprint:
        var c = world.peek_cell(cell)
        if not world.is_walkable(cell) or c.building_id != "" or c.resource_id != "" or c.has_plant():
            return {"ok": false, "warning": "Build area is blocked", "construction_id": ""}
    var id: String = allocate_id("construction")
    constructions[id] = ConstructionRecordScript.new(id, building_type, target, definition.get("required_items", {}), priority, "planned", "", footprint)
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

func _building_footprint(building_type: String, target: Vector3i) -> Array[Vector3i]:
    var definition: Dictionary = get_building_definition(building_type)
    var footprint: Array = definition.get("footprint", [1, 1])
    var w: int = int(footprint[0]) if footprint.size() > 0 else 1
    var h: int = int(footprint[1]) if footprint.size() > 1 else 1
    var min_x: int = target.x - int(floor(float(w) * 0.5))
    var min_z: int = target.z - int(floor(float(h) * 0.5))
    var cells: Array[Vector3i] = []
    for x in range(min_x, min_x + w):
        for z in range(min_z, min_z + h):
            var cell := Vector3i(x, target.y, z)
            if not world.in_bounds(cell):
                return []
            cells.append(cell)
    return cells

func _try_reserve_construction_resources(construction_id: String) -> bool:
    if not constructions.has(construction_id):
        return false
    var construction = constructions[construction_id]
    if construction.status != "planned" or construction.build_job_id != "":
        return false
    var reserved: Array[String] = []
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
            reserved.append(item_id)
            found += int(item.quantity)
            if found >= needed:
                break
        if found < needed:
            return false
    var job_id: String = allocate_id("job")
    for item_id in reserved:
        if not reserve_item_for_job(item_id, job_id):
            for released in reserved:
                release_item_reservation(released, job_id)
            return false
    reserved.sort()
    construction.reserved_item_ids = reserved
    construction.build_job_id = job_id
    construction.status = "reserved"
    var job = JobScript.new(job_id, "BUILD_CONSTRUCTION", construction.target_cell, construction.priority)
    var definition: Dictionary = get_building_definition(construction.type)
    job.work_remaining_ticks = int(definition.get("work_ticks", job.work_remaining_ticks))
    job.required_items = {"construction_id": construction.id, "reserved_item_ids": reserved.duplicate()}
    job_board.add_job(job)
    return true

func _release_construction_reservations(construction) -> void:
    for item_id in construction.reserved_item_ids:
        release_item_reservation(item_id, construction.build_job_id)
    construction.reserved_item_ids.clear()

func _complete_build_job(unit, job) -> void:
    var construction_id: String = str(job.required_items.get("construction_id", ""))
    if not constructions.has(construction_id):
        _fail_job(unit, job)
        return
    var construction = constructions[construction_id]
    if construction.status != "reserved" or construction.build_job_id != job.id:
        _fail_job(unit, job)
        return
    for item_id in construction.reserved_item_ids:
        if not items.has(item_id) or items[item_id].reserved_by_job_id != job.id:
            _fail_job(unit, job)
            return
    for item_id in construction.reserved_item_ids.duplicate():
        items.erase(item_id)
    construction.reserved_item_ids.clear()
    var building_id: String = allocate_id("building")
    construction.completed_building_id = building_id
    construction.status = "complete"
    var definition: Dictionary = get_building_definition(construction.type)
    var blocks: bool = bool(definition.get("blocks_movement", false))
    for cell_addr in construction.cells:
        var cell = world.get_cell(cell_addr)
        if cell != null:
            cell.building_id = building_id
            if blocks:
                cell.wall_material = C.MATERIAL_LOOSE_STONE
    _finish_job(unit, job)

# --- Workshops ----------------------------------------------------------------

func create_workshop_order(building_id: String, recipe_id: String, priority: int = 1) -> Dictionary:
    var construction = _completed_construction_for_building(building_id)
    if construction == null:
        return {"ok": false, "warning": "Select a workshop first", "workshop_order_id": ""}
    var definition: Dictionary = get_building_definition(construction.type)
    if not bool(definition.get("workshop", false)) or not definition.get("recipes", []).has(recipe_id):
        return {"ok": false, "warning": "Workshop cannot make that", "workshop_order_id": ""}
    if _recipe_definition(recipe_id).is_empty():
        return {"ok": false, "warning": "Unknown recipe", "workshop_order_id": ""}
    var order_id: String = allocate_id("workshop_order")
    workshop_orders[order_id] = {
        "id": order_id, "building_id": building_id, "building_type": construction.type,
        "recipe_id": recipe_id, "target_cell": [construction.target_cell.x, construction.target_cell.y, construction.target_cell.z],
        "priority": priority, "status": "queued", "reserved_item_ids": [], "job_id": "",
    }
    _try_reserve_workshop_order(order_id)
    return {"ok": true, "warning": "", "workshop_order_id": order_id}

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
    var reserved: Array[String] = _reserve_recipe_ingredients(recipe.get("required_items", {}))
    if reserved.is_empty():
        return false
    var job_id: String = allocate_id("job")
    for item_id in reserved:
        if not reserve_item_for_job(item_id, job_id):
            for released in reserved:
                release_item_reservation(released, job_id)
            return false
    var target := _array_to_vector3i(order.get("target_cell", []))
    var job = JobScript.new(job_id, str(recipe.get("job_type", "COOK_MEAL")), target, int(order.get("priority", 1)))
    job.work_remaining_ticks = int(recipe.get("work_ticks", job.work_remaining_ticks))
    job.produced_items = recipe.get("produced_items", {}).duplicate(true)
    job.required_items = {"workshop_order_id": order_id, "reserved_item_ids": reserved.duplicate()}
    order["reserved_item_ids"] = reserved.duplicate()
    order["job_id"] = job_id
    order["status"] = "reserved"
    job_board.add_job(job)
    return true

func _reserve_recipe_ingredients(required_items: Dictionary) -> Array[String]:
    var reserved: Array[String] = []
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
            reserved.append(item_id)
            found += int(item.quantity)
            if found >= needed:
                break
        if found < needed:
            return []
    return reserved

func _complete_workshop_job(unit, job) -> void:
    var order_id: String = str(job.required_items.get("workshop_order_id", ""))
    if not workshop_orders.has(order_id):
        _fail_job(unit, job)
        return
    var order: Dictionary = workshop_orders[order_id]
    var recipe: Dictionary = _recipe_definition(str(order.get("recipe_id", "")))
    if recipe.is_empty() or str(order.get("job_id", "")) != job.id:
        _fail_job(unit, job)
        return
    for item_id in order.get("reserved_item_ids", []):
        if not items.has(item_id) or items[item_id].reserved_by_job_id != job.id:
            _fail_job(unit, job)
            return
    _consume_reserved_items(order.get("reserved_item_ids", []), recipe.get("required_items", {}), job.id)
    for item_type in _sorted_ids(recipe.get("produced_items", {})):
        _spawn_item(str(item_type), int(recipe["produced_items"][item_type]), job.target_cell)
    order["status"] = "complete"
    order["reserved_item_ids"] = []
    _finish_job(unit, job)

func _consume_reserved_items(reserved_item_ids: Array, required_items: Dictionary, job_id: String) -> void:
    var remaining: Dictionary = required_items.duplicate(true)
    for item_id in reserved_item_ids:
        if not items.has(item_id):
            continue
        var item = items[item_id]
        var needed: int = int(remaining.get(item.item_type, 0))
        if needed <= 0:
            release_item_reservation(item_id, job_id)
            continue
        var consumed: int = mini(int(item.quantity), needed)
        item.quantity = int(item.quantity) - consumed
        remaining[item.item_type] = needed - consumed
        if int(item.quantity) <= 0:
            items.erase(item_id)
        else:
            release_item_reservation(item_id, job_id)

func _completed_construction_for_building(building_id: String):
    if building_id == "":
        return null
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.status == "complete" and construction.completed_building_id == building_id:
            return construction
    return null

func find_workshop_at_cell(target: Vector3i) -> Dictionary:
    for construction_id in _sorted_ids(constructions):
        var construction = constructions[construction_id]
        if construction.status != "complete":
            continue
        var definition: Dictionary = get_building_definition(construction.type)
        if not bool(definition.get("workshop", false)):
            continue
        for cell in construction.cells:
            if cell == target:
                return _workshop_summary(construction)
    return {}

func _workshop_summary(construction) -> Dictionary:
    var definition: Dictionary = get_building_definition(construction.type)
    return {
        "building_id": construction.completed_building_id,
        "construction_id": construction.id,
        "type": construction.type,
        "display_name": str(definition.get("display_name", construction.type)),
        "recipes": definition.get("recipes", []).duplicate(),
    }

func _recipe_definition(recipe_id: String) -> Dictionary:
    match recipe_id:
        RECIPE_COOK_MEAL:
            return {"id": RECIPE_COOK_MEAL, "display_name": "Cook Meal", "job_type": "COOK_MEAL",
                "required_items": {"food": 2}, "produced_items": {"meal": 1}, "work_ticks": 4}
    return {}

# --- Job finalization ---------------------------------------------------------

func _finish_job(unit, job) -> void:
    job.status = "complete"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _fail_job(unit, job) -> void:
    job.status = "failed"
    job.claimed_by_unit_id = unit.id
    unit.current_job_id = ""
    unit.unreachable_job_ticks = 0
    unit.state = "idle"

func _cleanup_completed_jobs() -> void:
    for job_id in job_board.sorted_job_ids():
        if job_board.jobs[job_id].status == "complete":
            job_board.jobs.erase(job_id)

# --- Snapshot / determinism ---------------------------------------------------

func canonical_snapshot() -> Dictionary:
    return {
        "tick": tick,
        "world_seed": world_seed,
        "id_counters": _sorted_dictionary(id_counters),
        "rng_streams": _rng_snapshot(),
        "world_hash": world.content_hash(),
        "resources": _resources_snapshot(),
        "units": _object_snapshot(units),
        "items": _object_snapshot(items),
        "stockpiles": _object_snapshot(stockpiles),
        "constructions": _object_snapshot(constructions),
        "workshop_orders": _workshop_orders_snapshot(),
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
        arr.append(_sorted_dictionary(resources[id].duplicate(true)))
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

# --- Helpers ------------------------------------------------------------------

func _to_cells(raw_cells: Array) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    for raw in raw_cells:
        if raw is Vector3i:
            output.append(raw)
        elif raw is Array and raw.size() >= 3:
            output.append(Vector3i(int(raw[0]), int(raw[1]), int(raw[2])))
    return ZoneScript.canonical_cells(output)

func _array_to_vector3i(value: Array) -> Vector3i:
    if value.size() < 3:
        return INVALID_CELL
    return Vector3i(int(value[0]), int(value[1]), int(value[2]))

func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]

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
