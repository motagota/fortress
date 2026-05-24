extends RefCounted

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const WorldRendererScript := preload("res://scripts/presentation/world_renderer.gd")
const MainScript := preload("res://scripts/main.gd")
const GameHudScene := preload("res://scenes/ui/GameHud.tscn")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _place_resource(sim, resource_id: String, resource_type: String, pos: Vector2i) -> void:
    sim.resources[resource_id] = {"id": resource_id, "type": resource_type, "position": [pos.x, pos.y]}
    sim.world.set_resource(pos, resource_id)

func _test_world_positions_map_to_grid_cells_using_tile_size() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(13)
    var renderer = WorldRendererScript.new()
    renderer.tile_size = 2.0

    var ok := true
    ok = _assert(renderer.world_position_to_cell(Vector3(0.0, 0.0, 0.0), sim.world) == Vector2i(0, 0), "world origin must map to grid cell 0,0") and ok
    ok = _assert(renderer.world_position_to_cell(Vector3(3.99, 0.0, 7.99), sim.world) == Vector2i(1, 3), "world positions must floor by tile_size into x/z grid cells") and ok
    ok = _assert(renderer.world_position_to_cell(Vector3(32.0, 0.0, 0.0), sim.world) == Vector2i(-1, -1), "positions outside grid bounds must return invalid sentinel") and ok
    renderer.free()
    return ok

func _test_mouse_ray_hits_grid_plane_and_rejects_parallel_or_out_of_bounds_rays() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(14)
    var renderer = WorldRendererScript.new()
    renderer.tile_size = 1.5

    var ok := true
    ok = _assert(renderer.ray_to_grid_cell(Vector3(3.2, 12.0, 4.7), Vector3(0.0, -1.0, 0.0), sim.world) == Vector2i(2, 3), "downward mouse ray must hit y=0 terrain plane and map by tile_size") and ok
    ok = _assert(renderer.ray_to_grid_cell(Vector3(3.2, 12.0, 4.7), Vector3(1.0, 0.0, 0.0), sim.world) == Vector2i(-1, -1), "ray parallel to terrain plane must return invalid sentinel") and ok
    ok = _assert(renderer.ray_to_grid_cell(Vector3(-1.0, 12.0, 4.7), Vector3(0.0, -1.0, 0.0), sim.world) == Vector2i(-1, -1), "ray hits outside grid must return invalid sentinel") and ok
    renderer.free()
    return ok

func _test_designation_validation_accepts_only_matching_resources() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(15)
    var tree := Vector2i(4, 4)
    var stone := Vector2i(5, 4)
    var berry := Vector2i(6, 4)
    var empty := Vector2i(1, 1)
    _place_resource(sim, "resource_tree_pick", "tree", tree)
    _place_resource(sim, "resource_stone_pick", "stone", stone)
    _place_resource(sim, "resource_berry_pick", "berry", berry)

    var ok := true
    var chop := sim.validate_designation_target("gather_wood", tree)
    ok = _assert(chop["valid"] and chop["command_type"] == "DESIGNATE_CHOP", "gather_wood must validate tree cells as DESIGNATE_CHOP") and ok
    var invalid_chop := sim.validate_designation_target("gather_wood", stone)
    ok = _assert(not invalid_chop["valid"] and str(invalid_chop["warning"]).contains("tree"), "gather_wood must reject non-tree resource cells with a warning") and ok
    var gather_stone := sim.validate_designation_target("gather_stone", stone)
    ok = _assert(gather_stone["valid"] and gather_stone["command_type"] == "DESIGNATE_GATHER_STONE", "gather_stone must validate stone cells") and ok
    var gather_food := sim.validate_designation_target("gather_food", berry)
    ok = _assert(gather_food["valid"] and gather_food["command_type"] == "DESIGNATE_GATHER_FOOD", "gather_food must validate berry cells") and ok
    var invalid_empty := sim.validate_designation_target("gather_food", empty)
    ok = _assert(not invalid_empty["valid"] and str(invalid_empty["warning"]).contains("berry"), "gather_food must reject empty cells with a warning") and ok
    var invalid_bounds := sim.validate_designation_target("gather_stone", Vector2i(-1, -1))
    ok = _assert(not invalid_bounds["valid"] and str(invalid_bounds["warning"]).contains("out of bounds"), "out-of-bounds designations must warn and no-op") and ok
    return ok

func _test_invalid_designation_noops_without_queueing_command() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(16)
    var empty := Vector2i(1, 1)
    var result: Dictionary = sim.queue_designation_command(1, "player_001", "gather_stone", empty, {"priority": 7})
    return _assert(not result["valid"] and sim.command_queue.size() == 0, "invalid designations must return warning and not enqueue commands")

func _test_duplicate_designations_do_not_create_duplicate_jobs_for_all_tools() -> bool:
    var ok := true
    ok = _assert(_duplicate_designation_guard_for_tool("tree", "gather_wood", "CHOP_TREE"), "duplicate gather_wood designations must not create duplicate CHOP_TREE jobs") and ok
    ok = _assert(_duplicate_designation_guard_for_tool("stone", "gather_stone", "GATHER_STONE"), "duplicate gather_stone designations must not create duplicate GATHER_STONE jobs") and ok
    ok = _assert(_duplicate_designation_guard_for_tool("berry", "gather_food", "GATHER_FOOD"), "duplicate gather_food designations must not create duplicate GATHER_FOOD jobs") and ok
    return ok

func _test_main_grid_designation_queues_command_before_sim_creates_job() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(18)
    var target := Vector2i(9, 9)
    _place_resource(sim, "resource_click_tree", "tree", target)

    var main := MainScript.new()
    main.simulation = sim
    main.set_active_tool_mode("gather_wood")

    var result: Dictionary = main._handle_grid_cell_designation(target)
    var ok := true
    ok = _assert(result["valid"], "valid gather_wood click on a tree must be accepted") and ok
    ok = _assert(sim.command_queue.size() == 1, "valid tree click must queue exactly one simulation command before the tick runs") and ok
    if sim.command_queue.size() == 1:
        var command: Dictionary = sim.command_queue[0]
        ok = _assert(command["command_type"] == "DESIGNATE_CHOP", "tree click must queue canonical DESIGNATE_CHOP, got %s" % command["command_type"]) and ok
        ok = _assert(command["target_cell"] == [target.x, target.y], "queued designation command must target the clicked grid cell") and ok
    ok = _assert(sim.job_board.jobs.size() == 0, "presentation click handler must not create jobs directly before command application") and ok

    sim.step_tick()
    ok = _assert(sim.job_board.jobs.size() == 1, "queued DESIGNATE_CHOP must create exactly one job when the simulation applies commands") and ok
    if sim.job_board.jobs.size() == 1:
        var job = sim.job_board.jobs[sim.job_board.sorted_job_ids()[0]]
        ok = _assert(job.type == "CHOP_TREE", "DESIGNATE_CHOP must create a CHOP_TREE job") and ok
        ok = _assert(job.target_cell == target, "created CHOP_TREE job must target the clicked tree cell") and ok
    main.free()
    return ok

func _test_main_invalid_grid_designation_noops_and_warns() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(19)
    var empty := Vector2i(1, 1)

    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var main := MainScript.new()
    main.simulation = sim
    main.hud = hud
    main.set_active_tool_mode("gather_stone")

    var result: Dictionary = main._handle_grid_cell_designation(empty)
    var ok := true
    ok = _assert(not result["valid"], "invalid gather_stone click on empty terrain must be rejected") and ok
    ok = _assert(sim.command_queue.size() == 0, "invalid terrain click must not queue commands") and ok
    ok = _assert(sim.job_board.jobs.size() == 0, "invalid terrain click must not create jobs") and ok
    ok = _assert(hud.last_warning.contains("stone"), "invalid terrain click must surface a warning explaining the expected resource") and ok

    hud.get_parent().remove_child(hud)
    hud.free()
    main.free()
    return ok

func _test_renderer_creates_and_clears_designation_markers() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(20)
    var target := Vector2i(8, 8)
    _place_resource(sim, "resource_overlay_tree", "tree", target)
    sim.queue_designation_command(1, "player_001", "gather_wood", target, {"priority": 99})
    sim.step_tick()

    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var ok := true
    var designations_root: Node = renderer.get_node_or_null("Designations")
    ok = _assert(designations_root != null, "renderer sync must create a Designations container when missing") and ok
    ok = _assert(designations_root.get_child_count() == 1, "active resource job must create one designation marker") and ok
    var marker: Node = designations_root.get_child(0) if designations_root.get_child_count() > 0 else null
    ok = _assert(marker != null and marker.name.begins_with("Designation_job_"), "designation marker must use stable Designation_<job id> naming") and ok

    var guard := 0
    while sim.resources.has("resource_overlay_tree") and guard < 128:
        sim.step_tick()
        guard += 1
    renderer.sync_from_simulation(sim)
    ok = _assert(not sim.resources.has("resource_overlay_tree"), "precondition: designated resource should complete in direct renderer overlay test") and ok
    ok = _assert(designations_root.get_child_count() == 0, "completed jobs must clear designation markers on the next render sync") and ok
    renderer.free()
    return ok

func _duplicate_designation_guard_for_tool(resource_type: String, tool_mode: String, job_type: String) -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(17)
    var target := Vector2i(7, 7)
    _place_resource(sim, "resource_duplicate_" + resource_type, resource_type, target)
    sim.queue_designation_command(1, "player_001", tool_mode, target, {"priority": 5})
    sim.queue_designation_command(1, "player_001", tool_mode, target, {"priority": 5})
    sim.step_tick()
    return sim.job_board.jobs.size() == 1 and sim.job_board.has_open_job_at(job_type, target)

func run() -> bool:
    return _test_world_positions_map_to_grid_cells_using_tile_size() \
        and _test_mouse_ray_hits_grid_plane_and_rejects_parallel_or_out_of_bounds_rays() \
        and _test_designation_validation_accepts_only_matching_resources() \
        and _test_invalid_designation_noops_without_queueing_command() \
        and _test_duplicate_designations_do_not_create_duplicate_jobs_for_all_tools() \
        and _test_main_grid_designation_queues_command_before_sim_creates_job() \
        and _test_main_invalid_grid_designation_noops_and_warns() \
        and _test_renderer_creates_and_clears_designation_markers()
