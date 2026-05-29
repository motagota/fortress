extends RefCounted

const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const WorldRendererScript := preload("res://scripts/presentation/world_renderer.gd")
const MainScript := preload("res://scripts/main.gd")
const GameHudScene := preload("res://scenes/ui/GameHud.tscn")
const ItemScript := preload("res://scripts/simulation/item.gd")
const LAYER_VERTICAL_SPACING := 1.0
const TERRAIN_THICKNESS := 1.0

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _place_resource(sim, resource_id: String, resource_type: String, pos: Vector2i) -> void:
    sim.resources[resource_id] = {"id": resource_id, "type": resource_type, "position": [pos.x, pos.y]}
    sim.world.set_resource(pos, resource_id)

func _surface_height_bounds(sim) -> Vector2i:
    var min_height: int = 0
    var max_height: int = 0
    var found: bool = false
    for z in range(sim.world.height):
        for x in range(sim.world.width):
            var height: int = sim.world.get_surface_height(Vector2i(x, z))
            if not found:
                min_height = height
                max_height = height
                found = true
            else:
                min_height = mini(min_height, height)
                max_height = maxi(max_height, height)
    return Vector2i(min_height, max_height)

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

func _test_renderer_draws_depth_layers_at_different_heights() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(140)
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)

    var chunk_volume: Node = renderer.get_node_or_null("ChunkVolume")
    var height_bounds := _surface_height_bounds(sim)
    var mesh_count: int = 0
    var bounds := AABB()
    var found_bounds: bool = false
    if chunk_volume != null:
        for child in chunk_volume.get_children():
            if child is MeshInstance3D:
                mesh_count += 1
                var child_bounds: AABB = (child as MeshInstance3D).get_aabb()
                bounds = child_bounds if not found_bounds else bounds.merge(child_bounds)
                found_bounds = true

    var ok := true
    ok = _assert(renderer.get_node_or_null("Terrain") == null, "renderer should not draw the legacy projected Terrain root") and ok
    ok = _assert(chunk_volume != null and mesh_count > 0 and mesh_count <= 16, "renderer should draw the 16x16x16 chunk as a small set of greedy material meshes") and ok
    ok = _assert(renderer.get_node_or_null("ChunkVolume/ChunkCell_00_00_00") == null, "renderer should not create one node per chunk cell") and ok
    if found_bounds:
        ok = _assert(_approxf(bounds.position.y, float(height_bounds.x - 16)) and _approxf(bounds.position.y + bounds.size.y, float(height_bounds.y)), "greedy chunk mesh bounds should use whole-cell elevation offsets") and ok
    renderer.free()
    return ok

func _test_renderer_draws_cells_and_stone_as_full_blocks() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(142)
    var stone_cell := Vector2i(6, 1)
    _place_resource(sim, "resource_full_cell_stone", "stone", stone_cell)
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)

    var chunk_volume: Node = renderer.get_node_or_null("ChunkVolume")
    var stone_node := renderer.get_node_or_null("Resources/StoneScatter_resource_full_cell_stone") as Node3D

    var ok := true
    ok = _assert(chunk_volume != null and chunk_volume.get_child_count() <= 16, "chunk volume should render through greedy material meshes") and ok
    ok = _assert(renderer.get_node_or_null("ChunkVolume/ChunkCell_00_15_00") == null, "chunk volume should not render per-cell box meshes") and ok
    ok = _assert(stone_node != null, "stone resources should render as elevated scatter groups") and ok
    if stone_node != null:
        var boulder := stone_node.get_node_or_null("BoulderA") as MeshInstance3D
        var expected_surface_y: float = float(sim.world.get_surface_height(stone_cell))
        ok = _assert(boulder != null and boulder.mesh is BoxMesh, "surface stone should render as low boulder parts instead of the old full cube") and ok
        ok = _assert(absf(stone_node.position.x - 6.0) < 0.15 and absf(stone_node.position.z - 1.0) < 0.15, "surface stone should stay inside the elevated source cell") and ok
        ok = _assert(absf(stone_node.position.y - expected_surface_y) < 0.001, "surface stone scatter should sit on the elevated cell surface") and ok
    renderer.free()
    return ok

func _test_excavated_cells_hide_and_expose_next_layer_for_picking() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(141)
    sim.world.get_cell(Vector2i(0, 0)).terrain = "excavated"
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)

    var picked_from_position: Vector2i = renderer.world_position_to_cell(Vector3(0.2, 0.0, 0.2), sim.world)
    var picked_from_ray: Vector2i = renderer.ray_to_grid_cell(Vector3(0.2, 10.0, 0.2), Vector3(0.0, -1.0, 0.0), sim.world)

    var ok := true
    ok = _assert(renderer.get_node_or_null("Terrain") == null, "excavated picking should not recreate legacy projected terrain") and ok
    ok = _assert(picked_from_position == Vector2i(0, 4), "display picking should select the next visible layer below an excavated surface cell, got %s" % picked_from_position) and ok
    ok = _assert(picked_from_ray == Vector2i(0, 4), "ray picking should select the next visible layer below an excavated surface cell, got %s" % picked_from_ray) and ok
    renderer.free()
    return ok

func _test_cutaway_layer_hides_surface_and_targets_underground_cell() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(143)
    var renderer = WorldRendererScript.new()
    renderer.set_layer_cutaway_depth(-1)
    renderer.sync_from_simulation(sim)

    var picked_from_position: Vector2i = renderer.world_position_to_cell(Vector3(0.2, 0.0, 0.2), sim.world)
    var picked_from_ray: Vector2i = renderer.ray_to_grid_cell(Vector3(0.2, 10.0, 0.2), Vector3(0.0, -1.0, 0.0), sim.world)

    var ok := true
    ok = _assert(renderer.get_node_or_null("Terrain") == null, "cutaway picking should not recreate legacy projected terrain") and ok
    ok = _assert(picked_from_position == Vector2i(0, 4), "cutaway picking should target the exposed underground cell, got %s" % picked_from_position) and ok
    ok = _assert(picked_from_ray == Vector2i(0, 4), "cutaway ray picking should target the exposed underground cell, got %s" % picked_from_ray) and ok
    renderer.free()
    return ok

func _test_hover_highlights_target_cell_edges() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(144)
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    renderer.set_hover_cell(Vector2i(2, 1))

    var hover_root := renderer.get_node_or_null("Hover") as Node3D
    var ok := true
    ok = _assert(hover_root != null and hover_root.visible, "hovering a visible cell should show the hover edge root") and ok
    if hover_root != null:
        ok = _assert(hover_root.get_child_count() == 12, "hover outline should draw all 12 cell edges") and ok
        ok = _assert(_approx_vec3(hover_root.position, Vector3(2.0, -0.5, 1.0)), "hover outline should be centered on the targeted full cell") and ok
    renderer.set_hover_cell(Vector2i(2, 1), false)
    var first_edge: MeshInstance3D = null
    if hover_root != null:
        first_edge = hover_root.get_node_or_null("Edge_00") as MeshInstance3D
    if first_edge != null and first_edge.material_override is StandardMaterial3D:
        var material := first_edge.material_override as StandardMaterial3D
        ok = _assert(material.albedo_color.r > 0.9 and material.albedo_color.g < 0.2, "invalid hover targets should use a red edge material") and ok
    renderer.set_hover_cell(Vector2i(-1, -1))
    ok = _assert(hover_root != null and not hover_root.visible, "invalid hover targets should hide the edge outline") and ok
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

func _test_surface_picking_targets_full_chunk_surface_tools() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(181)
    var target := Vector2i(11, 12)
    _place_resource(sim, "resource_full_surface_tree", "tree", target)
    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var ray_origin := Vector3(11.2, 20.0, 12.2)
    var picked: Vector2i = renderer.ray_to_grid_cell(ray_origin, Vector3(0.0, -1.0, 0.0), sim.world)

    var main := MainScript.new()
    main.simulation = sim
    main.set_active_tool_mode("gather_wood")
    var gather_result: Dictionary = main._handle_grid_cell_designation(picked)
    main.set_active_tool_mode("designate_stockpile")
    var stockpile_result: Dictionary = main._handle_stockpile_cells_designation(target, [target])

    var ok := true
    ok = _assert(picked == target, "default mouse picking should target the full elevated 16x16 surface cell") and ok
    ok = _assert(bool(gather_result.get("valid", false)), "gather tools should accept resources on the full surface, not only old surface rows") and ok
    ok = _assert(bool(stockpile_result.get("valid", false)), "stockpile placement should accept full-surface cells in the lower half of the chunk") and ok
    renderer.free()
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
    var target := Vector2i(8, 3)
    _place_resource(sim, "resource_overlay_tree", "tree", target)
    sim.queue_designation_command(1, "player_001", "gather_wood", target, {"priority": 99})
    sim.step_tick()

    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var ok := true
    var designations_root: Node = renderer.get_node_or_null("Designations")
    ok = _assert(designations_root != null, "renderer sync must create a Designations container when missing") and ok
    ok = _assert(designations_root.get_child_count() == 1, "active resource job must create one batched designation mesh") and ok
    var marker: Node = designations_root.get_node_or_null("JobDesignationMesh")
    ok = _assert(marker != null and marker is MeshInstance3D, "designation markers must use the stable JobDesignationMesh batch") and ok

    var guard := 0
    while sim.resources.has("resource_overlay_tree") and guard < 128:
        sim.step_tick()
        guard += 1
    renderer.sync_from_simulation(sim)
    ok = _assert(not sim.resources.has("resource_overlay_tree"), "precondition: designated resource should complete in direct renderer overlay test") and ok
    ok = _assert(designations_root.get_child_count() == 0, "completed jobs must clear designation markers on the next render sync") and ok
    renderer.free()
    return ok

func _test_main_stockpile_drag_queues_rectangular_zone() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(21)
    var main := MainScript.new()
    main.simulation = sim
    main.set_active_tool_mode("designate_stockpile")

    main._begin_stockpile_drag(Vector2i(2, 2))
    main._update_stockpile_drag(Vector2i(4, 3))
    var result: Dictionary = main._finish_stockpile_drag(Vector2i(4, 3))
    sim.step_tick()

    var ok := true
    ok = _assert(result["valid"], "stockpile drag over walkable cells should queue") and ok
    ok = _assert(sim.stockpiles.size() == 1, "stockpile drag should create one stockpile zone after command application") and ok
    if sim.stockpiles.size() == 1:
        var stockpile = sim.stockpiles[sim.stockpiles.keys()[0]]
        ok = _assert(JSON.stringify(stockpile.to_canonical_dict()["cells"]) == JSON.stringify([[2, 2], [2, 3], [3, 2], [3, 3], [4, 2], [4, 3]]), "stockpile drag should designate the full rectangular cell zone") and ok
    main.free()
    return ok

func _test_renderer_draws_stockpile_overlay_cells() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(22)
    sim.create_stockpile([Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3)], ["wood"])

    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var root: Node = renderer.get_node_or_null("Stockpiles")
    var ok := true
    ok = _assert(root != null, "renderer sync must create a Stockpiles overlay container when missing") and ok
    ok = _assert(root.get_child_count() == 1 and root.get_node_or_null("StockpileZoneMesh") is MeshInstance3D, "stockpile overlay must draw through one batched zone mesh") and ok

    renderer.set_stockpile_preview_cells([Vector2i(5, 5), Vector2i(6, 5)])
    var preview_root: Node = renderer.get_node_or_null("StockpilePreview")
    ok = _assert(preview_root != null and preview_root.get_child_count() == 1 and preview_root.get_node_or_null("StockpilePreviewMesh") is MeshInstance3D, "drag preview overlay must draw the current stockpile cells through a preview mesh") and ok
    renderer.set_stockpile_preview_cells([])
    ok = _assert(preview_root.get_child_count() == 0, "clearing stockpile preview must remove preview markers") and ok
    renderer.free()
    return ok

func _test_stockpile_selection_draws_resize_handles_and_clicking_handle_resizes() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(23)
    var stockpile_id: String = sim.create_stockpile([Vector2i(2, 2), Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3)], ["wood"])
    var renderer = WorldRendererScript.new()

    var main := MainScript.new()
    main.simulation = sim
    main.world_root = renderer
    main.set_active_tool_mode("inspect")
    var select_result: Dictionary = main._handle_stockpile_selection_or_resize(Vector2i(2, 2))

    var handles_root: Node = renderer.get_node_or_null("StockpileResizeHandles")
    var ok := true
    ok = _assert(select_result["valid"], "clicking a stockpile cell in inspect mode should select that stockpile") and ok
    ok = _assert(main.selected_stockpile_id == stockpile_id, "main should remember the selected stockpile id") and ok
    ok = _assert(handles_root != null and handles_root.get_child_count() == 8, "selected stockpile should render expand and shrink handles around its bounds") and ok

    var resize_result: Dictionary = main._handle_stockpile_selection_or_resize(Vector2i(4, 2))
    sim.step_tick()
    ok = _assert(resize_result["valid"], "clicking the east expand handle should queue a stockpile resize command") and ok
    ok = _assert(sim.stockpiles[stockpile_id].contains_cell(Vector2i(4, 2)), "east expand handle should add the next column to the stockpile") and ok

    renderer.free()
    main.free()
    return ok

func _test_main_kitchen_tool_queues_blueprint_and_inspect_queues_cooking() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(24)
    var main := MainScript.new()
    main.simulation = sim
    main.set_active_tool_mode("place_kitchen")

    var place_result: Dictionary = main._handle_grid_cell_designation(Vector2i(1, 1))
    sim.step_tick()

    var ok := true
    ok = _assert(place_result["valid"], "kitchen tool should queue a valid kitchen blueprint over a clear 3x3 area") and ok
    ok = _assert(sim.constructions.size() == 1, "kitchen click should create one construction after command application") and ok
    if sim.constructions.size() == 1:
        ok = _assert(sim.constructions["construction_000001"].type == "kitchen", "kitchen tool should place a kitchen construction") and ok
        ok = _assert(sim.constructions["construction_000001"].status == "planned", "kitchen should remain a ghost blueprint until three wood are available") and ok

    var renderer = WorldRendererScript.new()
    renderer.sync_from_simulation(sim)
    var buildings_root: Node = renderer.get_node_or_null("Buildings")
    ok = _assert(buildings_root != null and buildings_root.get_node_or_null("BuildingGhost_construction_000001") != null, "planned kitchen construction should render as a ghost on the map") and ok

    var wood_stockpile_id: String = sim.create_stockpile([Vector2i(4, 4)], ["wood"])
    var wood = ItemScript.new("item_wood_stack", "wood", 3, Vector2i(4, 4))
    wood.stockpile_id = wood_stockpile_id
    sim.items[wood.id] = wood
    for i in range(20):
        sim.step_tick()
    renderer.sync_from_simulation(sim)
    ok = _assert(buildings_root.get_node_or_null("Building_building_000001") != null, "completed kitchen should render as a built workshop on the map") and ok
    main.set_active_tool_mode("inspect")
    var inspect_result: Dictionary = main._handle_inspect_click(Vector2i(2, 2))
    ok = _assert(bool(inspect_result.get("valid", false)), "inspect click on any completed kitchen footprint cell should select the kitchen") and ok
    ok = _assert(main.selected_workshop_id == "building_000001", "main should remember the selected kitchen workshop id") and ok

    var stockpile_id: String = sim.create_stockpile([Vector2i(5, 4), Vector2i(5, 5)], ["food", "meal"])
    var item_a = ItemScript.new("item_food_a", "food", 1, Vector2i(5, 4))
    item_a.stockpile_id = stockpile_id
    sim.items[item_a.id] = item_a
    var item_b = ItemScript.new("item_food_b", "food", 1, Vector2i(5, 5))
    item_b.stockpile_id = stockpile_id
    sim.items[item_b.id] = item_b
    main._on_workshop_recipe_requested("cook_meal")
    sim.step_tick()
    ok = _assert(sim.workshop_orders.size() == 1, "cook meal button path should queue one workshop order") and ok
    ok = _assert(sim.job_board.jobs.size() == 1, "queued kitchen order should create one cook job when ingredients are available") and ok
    renderer.free()
    main.free()
    return ok

func _test_kitchen_tool_hover_draws_3x3_preview() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(25)
    var renderer = WorldRendererScript.new()
    var main := MainScript.new()
    main.simulation = sim
    main.world_root = renderer
    main.set_active_tool_mode("place_kitchen")

    main._refresh_kitchen_hover_preview(Vector2i(1, 1))

    var preview_root: Node = renderer.get_node_or_null("StockpilePreview")
    var ok := true
    ok = _assert(preview_root != null, "kitchen hover preview should create the preview overlay root") and ok
    ok = _assert(preview_root.get_child_count() == 1, "kitchen hover preview should draw the full 3x3 ghost as one batched mesh before placement") and ok
    if preview_root != null and preview_root.get_child_count() > 0:
        ok = _assert(preview_root.get_node_or_null("KitchenPreviewMesh") is MeshInstance3D, "kitchen preview cells should use the kitchen-specific preview mesh") and ok

    sim.resources["resource_blocking_berry"] = {"id": "resource_blocking_berry", "type": "berry", "position": [1, 1], "yield": {"food": 1}}
    sim.world.set_resource(Vector2i(1, 1), "resource_blocking_berry")
    main._refresh_kitchen_hover_preview(Vector2i(1, 1))
    ok = _assert(preview_root.get_child_count() == 1, "blocked kitchen hover preview should still show the 3x3 ghost footprint as one mesh") and ok

    renderer.free()
    main.free()
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
        and _test_renderer_draws_depth_layers_at_different_heights() \
        and _test_renderer_draws_cells_and_stone_as_full_blocks() \
        and _test_excavated_cells_hide_and_expose_next_layer_for_picking() \
        and _test_cutaway_layer_hides_surface_and_targets_underground_cell() \
        and _test_hover_highlights_target_cell_edges() \
        and _test_designation_validation_accepts_only_matching_resources() \
        and _test_invalid_designation_noops_without_queueing_command() \
        and _test_duplicate_designations_do_not_create_duplicate_jobs_for_all_tools() \
        and _test_main_grid_designation_queues_command_before_sim_creates_job() \
        and _test_surface_picking_targets_full_chunk_surface_tools() \
        and _test_main_invalid_grid_designation_noops_and_warns() \
        and _test_renderer_creates_and_clears_designation_markers() \
        and _test_main_stockpile_drag_queues_rectangular_zone() \
        and _test_renderer_draws_stockpile_overlay_cells() \
        and _test_stockpile_selection_draws_resize_handles_and_clicking_handle_resizes() \
        and _test_main_kitchen_tool_queues_blueprint_and_inspect_queues_cooking() \
        and _test_kitchen_tool_hover_draws_3x3_preview()

func _approxf(actual: float, expected: float) -> bool:
    return absf(actual - expected) < 0.001

func _approx_vec3(actual: Vector3, expected: Vector3) -> bool:
    return actual.distance_to(expected) < 0.001
