extends RefCounted

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const MainScript := preload("res://scripts/main.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _place_surface_rock(sim, resource_id: String, pos: Vector2i) -> void:
    for id in sim.resources.keys():
        var resource: Dictionary = sim.resources[id]
        var existing_pos: Array = resource.get("position", [])
        if existing_pos.size() >= 2 and Vector2i(int(existing_pos[0]), int(existing_pos[1])) == pos:
            sim.resources.erase(id)
    sim.resources[resource_id] = {"id": resource_id, "type": "stone", "position": [pos.x, pos.y], "yield": {"stone": 1}, "surface": true}
    sim.world.set_resource(pos, resource_id)

func _count_items_of_type(sim, item_type: String) -> int:
    var total: int = 0
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type:
            total += int(item.quantity)
    return total

func _step_until_idle(sim, steps: int = 64) -> void:
    for i in range(steps):
        sim.step_tick()

func _excavate_access_column(sim, target: Vector2i) -> void:
    var target_cell = sim.world.get_cell(target)
    if target_cell == null:
        return
    var target_depth: int = int(target_cell.depth)
    if target_depth >= 0:
        return
    var display_z: int = _render_z_for_sim_cell(sim, target)
    for depth in range(0, target_depth, -1):
        var shaft_cell: Vector2i = _cell_at_display_depth(sim, Vector2i(target.x, display_z), depth)
        if shaft_cell == Vector2i(-1, -1):
            continue
        var cell = sim.world.get_cell(shaft_cell)
        cell.terrain = "excavated"
        cell.resource_id = ""
        cell.walkable = true

func _cell_at_display_depth(sim, display_cell: Vector2i, depth: int) -> Vector2i:
    for z in range(sim.world.height):
        var candidate := Vector2i(display_cell.x, z)
        var cell = sim.world.get_cell(candidate)
        if cell == null or int(cell.depth) != depth:
            continue
        if _render_z_for_sim_cell(sim, candidate) == display_cell.y:
            return candidate
    return Vector2i(-1, -1)

func _render_z_for_sim_cell(sim, cell: Vector2i) -> int:
    var sim_cell = sim.world.get_cell(cell)
    if sim_cell == null:
        return cell.y
    var first_row: int = cell.y
    for z in range(sim.world.height):
        var layer_cell = sim.world.get_cell(Vector2i(cell.x, z))
        if layer_cell != null and int(layer_cell.depth) == int(sim_cell.depth):
            first_row = z
            break
    return cell.y - first_row

func _test_level_one_workers_can_mine_dirt() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(701)
    var target := Vector2i(4, 8)
    var cell = sim.world.get_cell(target)
    cell.terrain = "dirt"
    cell.depth = -2
    cell.resource_id = ""
    _excavate_access_column(sim, target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim)

    var ok := true
    ok = _assert(cell.terrain == "excavated", "completed mine job should excavate dirt cells") and ok
    ok = _assert(cell.walkable, "mined dirt above collapse depth should stay walkable") and ok
    ok = _assert(_count_items_of_type(sim, "dirt") == 1, "mining plain dirt should create one loose dirt item") and ok
    ok = _assert(_count_items_of_type(sim, "stone") == 0, "mining plain dirt should not create stone") and ok
    return ok

func _test_workers_mine_underground_target_from_reachable_work_cell() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(710)
    var target := Vector2i(4, 4)
    var cell = sim.world.get_cell(target)
    cell.terrain = "dirt"
    cell.resource_id = ""
    _excavate_access_column(sim, target)

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim)

    var ok := true
    ok = _assert(bool(validation.get("valid", false)), "underground mine target should validate when a reachable work cell exists") and ok
    ok = _assert(validation.get("work_cell", []) == [4, 0], "underground mine target should use the excavated cell above as its work cell") and ok
    ok = _assert(cell.terrain == "excavated", "worker should mine the underground target from the reachable work cell") and ok
    for unit_id in sim.units.keys():
        ok = _assert(sim.units[unit_id].position != target, "workers should not need to stand inside the underground block being mined") and ok
    return ok

func _test_unreachable_underground_mine_designation_is_rejected() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(711)
    var target := Vector2i(4, 4)
    var cell = sim.world.get_cell(target)
    cell.terrain = "dirt"
    cell.resource_id = ""

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    var queued: Dictionary = sim.queue_designation_command(1, "player_001", "mine", target, {"priority": 5})
    sim.step_tick()

    var ok := true
    ok = _assert(not bool(validation.get("valid", true)), "underground mine target should be invalid without a reachable work cell") and ok
    ok = _assert(str(validation.get("warning", "")).contains("reach"), "invalid underground mine target should explain reachability") and ok
    ok = _assert(not bool(queued.get("valid", true)), "unreachable underground mine target should not queue a command") and ok
    ok = _assert(sim.job_board.jobs.size() == 0, "unreachable underground mine target should not create a job") and ok
    return ok

func _test_level_one_workers_can_mine_grass() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(707)
    var target := Vector2i(4, 1)
    var cell = sim.world.get_cell(target)
    cell.terrain = "grass"
    cell.depth = 0
    cell.resource_id = ""

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim)

    var ok := true
    ok = _assert(bool(validation.get("valid", false)), "mine tool should accept grass cells") and ok
    ok = _assert(cell.terrain == "excavated", "mining grass should remove the ground") and ok
    ok = _assert(_count_items_of_type(sim, "dirt") == 1, "mining grass should create one loose dirt item") and ok
    return ok

func _test_level_one_workers_can_mine_surface_rocks() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(702)
    var target := Vector2i(4, 1)
    _place_surface_rock(sim, "resource_surface_rock", target)

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim)

    var ok := true
    ok = _assert(bool(validation.get("valid", false)), "mine tool should accept surface rock cells") and ok
    ok = _assert(not sim.resources.has("resource_surface_rock"), "mined surface rock should be depleted from the resource index") and ok
    ok = _assert(sim.world.get_cell(target).resource_id == "", "mined surface rock should clear the cell resource id") and ok
    ok = _assert(sim.world.get_cell(target).terrain == "excavated", "mining a surface rock should remove the ground under it") and ok
    ok = _assert(_count_items_of_type(sim, "stone") == 1, "mined surface rock should create one stone item") and ok
    return ok

func _test_duplicate_mine_designations_do_not_create_duplicate_jobs() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(703)
    var target := Vector2i(5, 1)
    sim.world.get_cell(target).terrain = "dirt"
    sim.queue_designation_command(1, "player_001", "mine", target, {"priority": 5})
    sim.queue_designation_command(1, "player_001", "mine", target, {"priority": 5})
    sim.step_tick()
    return _assert(sim.job_board.jobs.size() == 1 and sim.job_board.has_open_job_at("MINE_CELL", target), "duplicate mine designations should create one active MINE_CELL job")

func _test_deep_mining_can_collapse_deterministically() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(704)
    sim.rng_streams["event_rng"].set_state(4)
    var target := Vector2i(6, 12)
    var cell = sim.world.get_cell(target)
    cell.terrain = "dirt"
    cell.depth = -3
    cell.walkable = true
    cell.resource_id = ""
    _excavate_access_column(sim, target)
    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim)

    var ok := true
    ok = _assert(cell.terrain == "collapsed", "mining at depth -3 should be able to collapse using the event RNG") and ok
    ok = _assert(not cell.walkable, "collapsed mined cells should block walking") and ok
    return ok

func _test_layer_five_solid_rock_is_not_level_one_mineable() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(706)
    var target := Vector2i(6, 13)
    var cell = sim.world.get_cell(target)

    var validation: Dictionary = sim.validate_designation_target("mine", target)
    var queued: Dictionary = sim.queue_designation_command(1, "player_001", "mine", target, {"priority": 5})
    sim.step_tick()

    var ok := true
    ok = _assert(cell.depth == -4 and cell.terrain == "solid_rock", "layer five should generate as solid rock at depth -4") and ok
    ok = _assert(not bool(validation.get("valid", true)), "level one mine tool should reject solid rock") and ok
    ok = _assert(not bool(queued.get("valid", true)), "solid rock mine designations should not queue") and ok
    ok = _assert(sim.job_board.jobs.size() == 0, "solid rock should not create level one mining jobs") and ok
    return ok

func _test_main_mine_drag_queues_each_mineable_cell() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(705)
    for x in range(4, 6):
        var cell = sim.world.get_cell(Vector2i(x, 8))
        cell.terrain = "dirt"
        cell.resource_id = ""
        _excavate_access_column(sim, Vector2i(x, 8))
    sim._sync_projected_direct_mutations_to_authoritative()

    var main := MainScript.new()
    main.simulation = sim
    main.set_active_tool_mode("mine")
    main._begin_stockpile_drag(sim.world_cell_for_projected_cell(Vector2i(4, 8)))
    main._update_stockpile_drag(sim.world_cell_for_projected_cell(Vector2i(5, 8)))
    var result: Dictionary = main._finish_stockpile_drag(sim.world_cell_for_projected_cell(Vector2i(5, 8)))

    var ok := true
    ok = _assert(bool(result.get("valid", false)), "mine drag should accept mineable cells") and ok
    ok = _assert(sim.command_queue.size() == 2, "mine drag should queue one command per mineable cell") and ok
    main.free()
    return ok

func _test_workers_do_not_cross_between_layers_without_an_excavated_column() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(709)
    var from_cell := Vector2i(1, 3)
    var blocked_layer_cell := Vector2i(1, 4)

    var blocked_step: Vector2i = sim._step_towards(from_cell, blocked_layer_cell)
    sim.world.get_cell(Vector2i(1, 0)).terrain = "excavated"
    sim._sync_projected_direct_mutations_to_authoritative()
    var allowed_step: Vector2i = sim._step_towards(Vector2i(1, 0), blocked_layer_cell)

    var ok := true
    ok = _assert(blocked_step != blocked_layer_cell, "workers must not step directly through the wall between stacked layers") and ok
    ok = _assert(allowed_step == blocked_layer_cell, "workers may move down only through an excavated same-column opening") and ok
    return ok

func _test_mined_dirt_can_be_hauled_to_dirt_stockpile() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(708)
    var target := Vector2i(4, 1)
    var cell = sim.world.get_cell(target)
    cell.terrain = "grass"
    cell.depth = 0
    cell.resource_id = ""
    var stockpile_id: String = sim.create_stockpile([Vector2i(1, 1)], ["dirt"])

    sim.queue_command(1, "player_001", "DESIGNATE_MINE", target, {"priority": 5})
    _step_until_idle(sim, 96)

    var dirt_item = null
    for item_id in sim.items.keys():
        if sim.items[item_id].item_type == "dirt":
            dirt_item = sim.items[item_id]
            break

    var ok := true
    ok = _assert(stockpile_id != "", "precondition: dirt stockpile should be created") and ok
    ok = _assert(dirt_item != null, "mining grass should leave a dirt item for hauling") and ok
    if dirt_item != null:
        ok = _assert(dirt_item.stockpile_id == stockpile_id, "hauled mined dirt should end in the dirt stockpile") and ok
        ok = _assert(dirt_item.position == Vector2i(1, 1), "hauled mined dirt should be moved to the stockpile cell") and ok
    return ok

func run() -> bool:
    return _test_level_one_workers_can_mine_dirt() \
        and _test_workers_mine_underground_target_from_reachable_work_cell() \
        and _test_unreachable_underground_mine_designation_is_rejected() \
        and _test_level_one_workers_can_mine_grass() \
        and _test_level_one_workers_can_mine_surface_rocks() \
        and _test_duplicate_mine_designations_do_not_create_duplicate_jobs() \
        and _test_deep_mining_can_collapse_deterministically() \
        and _test_layer_five_solid_rock_is_not_level_one_mineable() \
        and _test_main_mine_drag_queues_each_mineable_cell() \
        and _test_workers_do_not_cross_between_layers_without_an_excavated_column() \
        and _test_mined_dirt_can_be_hauled_to_dirt_stockpile()
