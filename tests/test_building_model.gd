extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")
const ItemScript = preload("res://scripts/simulation/item.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_wall_block_definition_exposes_required_resources() and ok
    ok = _test_construction_records_serialize_canonically() and ok
    ok = _test_unknown_building_type_is_rejected_without_mutation() and ok
    ok = _test_place_blueprint_command_creates_one_construction() and ok
    ok = _test_duplicate_blueprint_command_does_not_duplicate() and ok
    ok = _test_invalid_blueprint_target_is_rejected_without_mutation() and ok
    ok = _test_blueprint_replay_has_same_ids_and_hash() and ok
    ok = _test_build_job_waits_when_required_stone_is_unavailable() and ok
    ok = _test_stockpiled_stone_is_reserved_for_build_job() and ok
    ok = _test_same_stockpiled_item_cannot_satisfy_two_blueprints() and ok
    ok = _test_cancelled_construction_clears_reserved_stone() and ok
    ok = _test_worker_completes_reserved_wall_construction() and ok
    ok = _test_completed_wall_consumes_stockpiled_stone_once() and ok
    ok = _test_completed_wall_blocks_target_cell() and ok
    ok = _test_completed_blueprint_cannot_complete_twice() and ok
    ok = _test_kitchen_requires_clear_3x3_area() and ok
    ok = _test_kitchen_build_job_waits_for_three_wood() and ok
    ok = _test_completed_kitchen_occupies_3x3_workshop_area() and ok
    ok = _test_kitchen_cook_order_consumes_two_food_and_produces_meal() and ok
    return ok

func _add_stockpiled_item(sim, item_id: String, item_type: String, quantity: int, cell: Vector2i, stockpile_id: String) -> void:
    var item = ItemScript.new(item_id, item_type, quantity, cell)
    item.stockpile_id = stockpile_id
    sim.items[item_id] = item

func _build_jobs(sim) -> Array:
    var jobs: Array = []
    for job_id in sim.job_board.sorted_job_ids():
        var job = sim.job_board.jobs[job_id]
        if job.type == "BUILD_CONSTRUCTION":
            jobs.append(job)
    return jobs

func _jobs_of_type(sim, job_type: String) -> Array:
    var jobs: Array = []
    for job_id in sim.job_board.sorted_job_ids():
        var job = sim.job_board.jobs[job_id]
        if job.type == job_type:
            jobs.append(job)
    return jobs

func _count_items_of_type(sim, item_type: String) -> int:
    var total: int = 0
    for item_id in sim.items.keys():
        if sim.items[item_id].item_type == item_type:
            total += int(sim.items[item_id].quantity)
    return total

func _run_ticks(sim, count: int) -> void:
    for i in range(count):
        sim.step_tick()

func _test_wall_block_definition_exposes_required_resources() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(41)

    var definition: Dictionary = sim.get_building_definition("wall_block")

    var ok: bool = true
    ok = _assert(not definition.is_empty(), "wall_block building definition should exist") and ok
    ok = _assert(definition.get("id", "") == "wall_block", "wall_block definition should expose its deterministic type id") and ok
    ok = _assert(definition.get("display_name", "") == "Wall Block", "wall_block definition should expose a readable name") and ok
    ok = _assert(definition.get("required_items", {}).get("stone", 0) == 2, "wall_block should require two stone") and ok
    return ok

func _test_construction_records_serialize_canonically() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    a.initialize_new_game(42)
    b.initialize_new_game(42)

    var b_result: Dictionary = b.create_construction("wall_block", Vector2i(5, 2), 4)
    var a_result: Dictionary = a.create_construction("wall_block", Vector2i(5, 2), 4)

    var ok: bool = true
    ok = _assert(bool(a_result.get("ok", false)), "valid wall_block construction should be accepted") and ok
    ok = _assert(str(a_result.get("construction_id", "")) == "construction_000001", "construction ids should be deterministic and monotonic") and ok
    ok = _assert(JSON.stringify(a.canonical_snapshot()["constructions"]) == JSON.stringify(b.canonical_snapshot()["constructions"]), "construction state should serialize canonically independent of insertion timing") and ok
    ok = _assert(a.state_hash() == b.state_hash(), "state_hash should include canonical construction state") and ok
    var construction = a.constructions[str(a_result["construction_id"])]
    var snapshot: Dictionary = construction.to_canonical_dict()
    ok = _assert(snapshot["type"] == "wall_block", "construction snapshot should include building type") and ok
    ok = _assert(JSON.stringify(snapshot["target_cell"]) == JSON.stringify([5, 2]), "construction snapshot should include target cell") and ok
    ok = _assert(snapshot["required_items"].get("stone", 0) == 2, "construction snapshot should copy required items from definition") and ok
    ok = _assert(snapshot["status"] == "planned", "new construction should start planned") and ok
    ok = _assert(snapshot["completed_building_id"] == "", "new construction should not reference a completed building") and ok
    return ok

func _test_unknown_building_type_is_rejected_without_mutation() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(43)
    var before_hash: String = sim.state_hash()
    var before_counter: int = int(sim.id_counters.get("construction", 0))

    var result: Dictionary = sim.create_construction("unknown_tower", Vector2i(2, 2), 1)

    var ok: bool = true
    ok = _assert(not bool(result.get("ok", true)), "unknown building types must be rejected") and ok
    ok = _assert(str(result.get("warning", "")).contains("Unknown building type"), "unknown building rejection should report a useful warning") and ok
    ok = _assert(sim.constructions.size() == 0, "unknown building type must not add construction state") and ok
    ok = _assert(int(sim.id_counters.get("construction", 0)) == before_counter, "unknown building type must not allocate deterministic ids") and ok
    ok = _assert(sim.state_hash() == before_hash, "unknown building type must not mutate canonical simulation state") and ok
    return ok

func _test_place_blueprint_command_creates_one_construction() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(44)

    sim.queue_command(1, "player_001", "PLACE_BLUEPRINT", Vector2i(1, 1), {"building_type": "wall_block", "priority": 7})
    sim.step_tick()

    var ok: bool = true
    ok = _assert(sim.constructions.size() == 1, "PLACE_BLUEPRINT should create exactly one construction record") and ok
    ok = _assert(sim.constructions.has("construction_000001"), "PLACE_BLUEPRINT should allocate deterministic construction id") and ok
    if sim.constructions.has("construction_000001"):
        var record = sim.constructions["construction_000001"]
        ok = _assert(record.type == "wall_block", "blueprint should store requested wall_block type") and ok
        ok = _assert(record.target_cell == Vector2i(1, 1), "blueprint should store requested target cell") and ok
        ok = _assert(record.priority == 7, "blueprint should copy command priority") and ok
        ok = _assert(record.status == "planned", "blueprint should start planned") and ok
    return ok

func _test_duplicate_blueprint_command_does_not_duplicate() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(45)

    sim.queue_command(1, "player_001", "PLACE_BLUEPRINT", Vector2i(1, 1), {"building_type": "wall_block"})
    sim.queue_command(1, "player_001", "PLACE_BLUEPRINT", Vector2i(1, 1), {"building_type": "wall_block"})
    sim.step_tick()

    var ok: bool = true
    ok = _assert(sim.constructions.size() == 1, "duplicate PLACE_BLUEPRINT for same type/cell should not create duplicates") and ok
    ok = _assert(int(sim.id_counters.get("construction", 0)) == 1, "duplicate PLACE_BLUEPRINT should not consume deterministic construction ids") and ok
    return ok

func _test_invalid_blueprint_target_is_rejected_without_mutation() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(46)
    var before_hash: String = sim.state_hash()
    var before_counter: int = int(sim.id_counters.get("command", 0))

    var result: Dictionary = sim.queue_blueprint_command(1, "player_001", "wall_block", Vector2i(-1, 0), {"priority": 2})

    var ok: bool = true
    ok = _assert(not bool(result.get("valid", true)), "out-of-bounds blueprint target should be rejected") and ok
    ok = _assert(str(result.get("warning", "")).contains("out of bounds"), "invalid blueprint target should report useful warning") and ok
    ok = _assert(sim.constructions.size() == 0, "invalid blueprint target should not create construction state") and ok
    ok = _assert(sim.command_queue.size() == 0, "invalid blueprint target should not queue a command") and ok
    ok = _assert(int(sim.id_counters.get("command", 0)) == before_counter, "invalid blueprint target should not allocate command ids") and ok
    ok = _assert(sim.state_hash() == before_hash, "invalid blueprint target should leave canonical state unchanged") and ok
    return ok

func _test_blueprint_replay_has_same_ids_and_hash() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    a.initialize_new_game(47)
    b.initialize_new_game(47)

    a.queue_command(1, "player_001", "PLACE_BLUEPRINT", Vector2i(1, 1), {"building_type": "wall_block", "priority": 3})
    b.queue_command(1, "player_001", "PLACE_BLUEPRINT", Vector2i(1, 1), {"priority": 3, "building_type": "wall_block"})
    a.step_tick()
    b.step_tick()

    var ok: bool = true
    ok = _assert(JSON.stringify(a.canonical_snapshot()["constructions"]) == JSON.stringify(b.canonical_snapshot()["constructions"]), "replayed PLACE_BLUEPRINT should create same construction ids and canonical records") and ok
    ok = _assert(a.state_hash() == b.state_hash(), "replayed PLACE_BLUEPRINT commands should produce same state hash") and ok
    return ok

func _test_build_job_waits_when_required_stone_is_unavailable() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(48)

    var result: Dictionary = sim.create_construction("wall_block", Vector2i(5, 2), 4)

    var ok: bool = true
    ok = _assert(bool(result.get("ok", false)), "valid construction should still create a planned blueprint when stone is missing") and ok
    ok = _assert(_build_jobs(sim).size() == 0, "wall_block build job must wait until required stockpiled stone is available") and ok
    ok = _assert(sim.constructions[str(result.get("construction_id", ""))].status == "planned", "construction without reserved resources should remain planned") and ok
    return ok

func _test_stockpiled_stone_is_reserved_for_build_job() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(49)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)

    var result: Dictionary = sim.create_construction("wall_block", Vector2i(5, 2), 6)

    var jobs: Array = _build_jobs(sim)
    var construction_id: String = str(result.get("construction_id", ""))
    var ok: bool = true
    ok = _assert(jobs.size() == 1, "available stockpiled stone should create one build job") and ok
    if jobs.size() == 1:
        ok = _assert(jobs[0].required_items.get("construction_id", "") == construction_id, "build job should reference the construction id") and ok
        ok = _assert(jobs[0].required_items.get("reserved_item_ids", []) == ["item_stone_stack"], "build job should record the reserved stockpiled stone item") and ok
        ok = _assert(sim.items["item_stone_stack"].reserved_by_job_id == jobs[0].id, "stockpiled stone should be reserved by the build job") and ok
        ok = _assert(sim.constructions[construction_id].status == "reserved", "construction with resources reserved should be marked reserved") and ok
    return ok

func _test_same_stockpiled_item_cannot_satisfy_two_blueprints() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(50)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)

    var first: Dictionary = sim.create_construction("wall_block", Vector2i(5, 2), 6)
    var second: Dictionary = sim.create_construction("wall_block", Vector2i(1, 1), 6)

    var ok: bool = true
    ok = _assert(bool(first.get("ok", false)) and bool(second.get("ok", false)), "both blueprint records should be accepted") and ok
    ok = _assert(_build_jobs(sim).size() == 1, "one stockpiled stone stack cannot satisfy two blueprints at once") and ok
    ok = _assert(sim.constructions[str(second.get("construction_id", ""))].status == "planned", "second construction should remain planned while stone is reserved elsewhere") and ok
    ok = _assert(sim.items["item_stone_stack"].reserved_by_job_id == "job_000001", "stone stack should remain reserved by the first build job only") and ok
    return ok

func _test_cancelled_construction_clears_reserved_stone() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(51)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)
    var result: Dictionary = sim.create_construction("wall_block", Vector2i(5, 2), 6)

    sim.cancel_construction(str(result.get("construction_id", "")))

    var ok: bool = true
    ok = _assert(sim.items["item_stone_stack"].reserved_by_job_id == "", "cancelling construction should clear reserved stockpiled stone") and ok
    ok = _assert(sim.constructions[str(result.get("construction_id", ""))].status == "cancelled", "cancelled construction should be marked cancelled") and ok
    ok = _assert(_build_jobs(sim)[0].status == "cancelled", "cancelling construction should mark its build job cancelled") and ok
    return ok

func _test_worker_completes_reserved_wall_construction() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(52)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)
    var result: Dictionary = sim.create_construction("wall_block", Vector2i(2, 2), 6)
    var construction_id: String = str(result.get("construction_id", ""))

    _run_ticks(sim, 20)

    var construction = sim.constructions[construction_id]
    var ok: bool = true
    ok = _assert(construction.status == "complete", "worker should complete reserved wall construction") and ok
    ok = _assert(construction.completed_building_id == "building_000001", "completed construction should allocate deterministic building id") and ok
    ok = _assert(not sim.job_board.jobs.has(construction.build_job_id), "completed build job should be removed from the live job board") and ok
    ok = _assert(sim.world.get_cell(Vector2i(2, 2)).building_id == construction.completed_building_id, "completed wall should exist on the target cell") and ok
    return ok

func _test_completed_wall_consumes_stockpiled_stone_once() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(53)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)
    var result: Dictionary = sim.create_construction("wall_block", Vector2i(2, 2), 6)
    var construction_id: String = str(result.get("construction_id", ""))

    _run_ticks(sim, 20)

    var ok: bool = true
    ok = _assert(sim.constructions[construction_id].status == "complete", "construction should complete before checking consumed resources") and ok
    ok = _assert(not sim.items.has("item_stone_stack"), "reserved stockpiled stone should be consumed when wall completes") and ok
    ok = _assert(sim.canonical_snapshot()["items"].size() == 0, "resource counts should be conserved with no duplicate leftover stone items") and ok
    return ok

func _test_completed_wall_blocks_target_cell() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(54)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)
    sim.create_construction("wall_block", Vector2i(2, 2), 6)

    _run_ticks(sim, 20)

    var cell = sim.world.get_cell(Vector2i(2, 2))
    var ok: bool = true
    ok = _assert(cell.building_id == "building_000001", "completed wall should occupy the target cell") and ok
    ok = _assert(not cell.walkable, "completed wall should update target cell walkability") and ok
    ok = _assert(not bool(sim.validate_blueprint_target("wall_block", Vector2i(2, 2)).get("valid", true)), "occupied wall cell should reject future blueprints") and ok
    return ok

func _test_completed_blueprint_cannot_complete_twice() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(55)
    var stockpile_id: String = sim.create_stockpile([Vector2i(3, 3)], ["stone"])
    _add_stockpiled_item(sim, "item_stone_stack", "stone", 2, Vector2i(3, 3), stockpile_id)
    var result: Dictionary = sim.create_construction("wall_block", Vector2i(2, 2), 6)
    var construction_id: String = str(result.get("construction_id", ""))

    _run_ticks(sim, 20)
    var construction = sim.constructions[construction_id]
    var first_building_id: String = construction.completed_building_id
    var item_count_after_first_completion: int = sim.items.size()
    _run_ticks(sim, 5)

    var ok: bool = true
    ok = _assert(construction.status == "complete", "construction should remain complete after duplicate completion attempt") and ok
    ok = _assert(construction.completed_building_id == first_building_id, "duplicate completion must not allocate a second building id") and ok
    ok = _assert(int(sim.id_counters.get("building", 0)) == 1, "duplicate completion must not advance building id counter") and ok
    ok = _assert(sim.items.size() == item_count_after_first_completion, "duplicate completion must not consume resources twice") and ok
    ok = _assert(_build_jobs(sim).size() == 0, "completed construction should not leave a live build job") and ok
    return ok

func _test_kitchen_requires_clear_3x3_area() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(56)

    var definition: Dictionary = sim.get_building_definition("kitchen")
    var valid: Dictionary = sim.validate_blueprint_target("kitchen", Vector2i(1, 1))
    sim.resources["resource_blocking_berry"] = {"id": "resource_blocking_berry", "type": "berry", "position": [0, 0], "yield": {"food": 1}}
    sim.world.set_resource(Vector2i(0, 0), "resource_blocking_berry")
    var blocked: Dictionary = sim.validate_blueprint_target("kitchen", Vector2i(1, 1))
    var edge: Dictionary = sim.validate_blueprint_target("kitchen", Vector2i(0, 0))

    var ok: bool = true
    ok = _assert(definition.get("footprint", []) == [3, 3], "kitchen should declare a 3x3 workshop footprint") and ok
    ok = _assert(definition.get("required_items", {}).get("wood", 0) == 3, "kitchen should require three wood to build") and ok
    ok = _assert(bool(definition.get("workshop", false)), "kitchen should be marked as a workshop") and ok
    ok = _assert(bool(valid.get("valid", false)), "kitchen should be placeable when all 3x3 cells are clear") and ok
    ok = _assert(not bool(blocked.get("valid", true)) and str(blocked.get("warning", "")).contains("resource"), "kitchen should reject resources anywhere in the 3x3 area") and ok
    ok = _assert(not bool(edge.get("valid", true)) and str(edge.get("warning", "")).contains("out of bounds"), "kitchen footprint should reject out-of-bounds 3x3 placement") and ok
    return ok

func _test_kitchen_build_job_waits_for_three_wood() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(59)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 4)], ["wood"])
    _add_stockpiled_item(sim, "item_wood_short", "wood", 2, Vector2i(4, 4), stockpile_id)

    var result: Dictionary = sim.create_construction("kitchen", Vector2i(1, 1), 5)

    var ok: bool = true
    ok = _assert(bool(result.get("ok", false)), "kitchen blueprint should be accepted even before enough wood exists") and ok
    ok = _assert(_build_jobs(sim).size() == 0, "kitchen build job should wait until three wood are available") and ok
    ok = _assert(sim.constructions[str(result.get("construction_id", ""))].status == "planned", "kitchen should remain planned until wood is reserved") and ok
    sim.items.erase("item_wood_short")
    _add_stockpiled_item(sim, "item_wood_stack", "wood", 3, Vector2i(4, 4), stockpile_id)
    sim.step_tick()
    ok = _assert(_build_jobs(sim).size() == 1, "three stored wood should create a kitchen build job") and ok
    ok = _assert(sim.items["item_wood_stack"].reserved_by_job_id == "job_000001", "kitchen build job should reserve the wood stack") and ok
    return ok

func _test_completed_kitchen_occupies_3x3_workshop_area() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(57)
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 4)], ["wood"])
    _add_stockpiled_item(sim, "item_wood_stack", "wood", 3, Vector2i(4, 4), stockpile_id)
    var result: Dictionary = sim.create_construction("kitchen", Vector2i(1, 1), 5)

    _run_ticks(sim, 20)

    var construction = sim.constructions[str(result.get("construction_id", ""))]
    var ok: bool = true
    ok = _assert(construction.status == "complete", "kitchen construction should complete as a workshop") and ok
    ok = _assert(construction.completed_building_id == "building_000001", "kitchen should allocate a completed building id") and ok
    for x in range(0, 3):
        for y in range(0, 3):
            var cell = sim.world.get_cell(Vector2i(x, y))
            ok = _assert(cell.building_id == construction.completed_building_id, "completed kitchen should occupy every cell in its 3x3 footprint") and ok
            ok = _assert(cell.walkable, "kitchen workshop cells should remain walkable") and ok
    var workshop: Dictionary = sim.find_workshop_at_cell(Vector2i(2, 2))
    ok = _assert(workshop.get("building_id", "") == construction.completed_building_id, "clicking any kitchen footprint cell should find the kitchen workshop") and ok
    return ok

func _test_kitchen_cook_order_consumes_two_food_and_produces_meal() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(58)
    var wood_stockpile_id: String = sim.create_stockpile([Vector2i(4, 4)], ["wood"])
    _add_stockpiled_item(sim, "item_wood_stack", "wood", 3, Vector2i(4, 4), wood_stockpile_id)
    var kitchen_result: Dictionary = sim.create_construction("kitchen", Vector2i(1, 1), 5)
    _run_ticks(sim, 20)
    var kitchen = sim.constructions[str(kitchen_result.get("construction_id", ""))]
    var stockpile_id: String = sim.create_stockpile([Vector2i(4, 5), Vector2i(4, 6)], ["food"])
    _add_stockpiled_item(sim, "item_food_a", "food", 1, Vector2i(4, 5), stockpile_id)
    _add_stockpiled_item(sim, "item_food_b", "food", 1, Vector2i(4, 6), stockpile_id)

    var order: Dictionary = sim.create_workshop_order(kitchen.completed_building_id, "cook_meal", 5)
    var ok: bool = true
    ok = _assert(bool(order.get("ok", false)), "completed kitchen should accept a cook meal order") and ok
    ok = _assert(_jobs_of_type(sim, "COOK_MEAL").size() == 1, "cook meal order with two stored food items should create one cooking job") and ok

    _run_ticks(sim, 40)

    ok = _assert(_count_items_of_type(sim, "food") == 0, "cooking a meal should consume two stored food items") and ok
    ok = _assert(_count_items_of_type(sim, "meal") == 1, "cooking a meal should produce one meal item") and ok
    ok = _assert(not sim.job_board.jobs.has("job_000002"), "completed cooking job should be removed from the live job board") and ok
    ok = _assert(sim.workshop_orders["workshop_order_000001"]["status"] == "complete", "workshop order should be marked complete after cooking finishes") and ok
    return ok
