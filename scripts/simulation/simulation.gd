class_name Simulation
extends RefCounted

const WORLD_WIDTH := 16
const WORLD_HEIGHT := 16
const INITIAL_UNIT_COUNT := 3

const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")
const GridWorldScript := preload("res://scripts/simulation/grid_world.gd")
const UnitScript := preload("res://scripts/simulation/unit.gd")
const ItemScript := preload("res://scripts/simulation/item.gd")
const JobScript := preload("res://scripts/simulation/job.gd")
const JobBoardScript := preload("res://scripts/simulation/job_board.gd")

var tick: int = 0
var world_seed: int = 1
var rng_streams: Dictionary = {}
var world: GridWorld
var units: Dictionary = {}
var items: Dictionary = {}
var resources: Dictionary = {}
var job_board: JobBoard
var command_queue: Array[Dictionary] = []
var id_counters: Dictionary = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0}

func initialize_new_game(seed_value: int = 1) -> void:
    tick = 0
    world_seed = seed_value
    rng_streams = {
        "world_rng": DeterministicRng.new(seed_value),
        "unit_rng": DeterministicRng.new(seed_value ^ 0x00c0ffee),
        "event_rng": DeterministicRng.new(seed_value ^ 0x005eeded),
    }
    command_queue = []
    id_counters = {"unit": 0, "job": 0, "item": 0, "command": 0, "building": 0}
    resources = {}
    items = {}
    units = {}
    job_board = JobBoard.new()
    world = GridWorld.new(WORLD_WIDTH, WORLD_HEIGHT)
    world.create_forest(rng_streams["world_rng"], resources)
    _spawn_initial_units()

func _spawn_initial_units() -> void:
    var starts: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
    var names: Array[String] = ["Ari", "Bo", "Cy"]
    for i in range(INITIAL_UNIT_COUNT):
        var id: String = allocate_id("unit")
        units[id] = SimUnit.new(id, names[i], starts[i])

func allocate_id(prefix: String) -> String:
    id_counters[prefix] = int(id_counters.get(prefix, 0)) + 1
    return "%s_%06d" % [prefix, id_counters[prefix]]

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
    _advance_needs()
    _assign_jobs()
    _advance_units()
    _cleanup_completed_jobs()

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

func _create_job_for_resource(target: Vector2i, resource_type: String, job_type: String, priority: int) -> void:
    var cell: SimCell = world.get_cell(target)
    if cell == null or cell.resource_id == "":
        return
    var resource: Dictionary = resources.get(cell.resource_id, {})
    if resource.get("type", "") != resource_type:
        return
    if job_board.has_open_job_at(job_type, target):
        return
    var job: SimJob = SimJob.new(allocate_id("job"), job_type, target, priority)
    job_board.add_job(job)

func _advance_needs() -> void:
    for id in _sorted_ids(units):
        var unit: SimUnit = units[id]
        unit.needs["hunger"] = int(unit.needs.get("hunger", 0)) + 1
        if unit.state in ["working", "walking"]:
            unit.needs["energy"] = max(0, int(unit.needs.get("energy", 100)) - 1)

func _assign_jobs() -> void:
    for id in _sorted_ids(units):
        var unit: SimUnit = units[id]
        if unit.current_job_id != "":
            continue
        var job: SimJob = job_board.claim_next_open_job_for_unit(unit)
        if job != null:
            unit.current_job_id = job.id
            unit.state = "walking"

func _advance_units() -> void:
    for id in _sorted_ids(units):
        var unit: SimUnit = units[id]
        if unit.current_job_id == "":
            unit.state = "idle"
            continue
        var job: SimJob = job_board.jobs.get(unit.current_job_id)
        if job == null:
            unit.current_job_id = ""
            unit.state = "idle"
            continue
        if unit.position != job.target_cell:
            unit.position = _step_towards(unit.position, job.target_cell)
            unit.state = "walking"
        else:
            unit.state = "working"
            if job.advance_work_tick():
                _complete_job(unit, job)

func _step_towards(from_cell: Vector2i, to_cell: Vector2i) -> Vector2i:
    var result: Vector2i = from_cell
    if result.x != to_cell.x:
        result.x += 1 if to_cell.x > result.x else -1
    elif result.y != to_cell.y:
        result.y += 1 if to_cell.y > result.y else -1
    return result

func _complete_job(unit: SimUnit, job: SimJob) -> void:
    var cell: SimCell = world.get_cell(job.target_cell)
    var resource_id: String = cell.resource_id if cell != null else ""
    if cell != null and resource_id != "":
        var resource: Dictionary = resources.get(resource_id, {})
        if resource.get("type", "") == _resource_type_for_job(job.type):
            for item_type in _sorted_ids(job.produced_items):
                var item_id: String = allocate_id("item")
                items[item_id] = SimItem.new(item_id, item_type, int(job.produced_items[item_type]), job.target_cell)
            resources.erase(resource_id)
            world.clear_resource(job.target_cell, resource_id)
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
