extends RefCounted

const Simulation := preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var packed_scene: PackedScene = load("res://scenes/Main.tscn")
    var scene: Node = packed_scene.instantiate()
    var ok: bool = true
    ok = _assert(scene is Node3D, "Main scene root must be Node3D") and ok
    ok = _assert(scene.get_node_or_null("WorldRoot") != null, "Main scene must include WorldRoot") and ok
    ok = _assert(scene.get_node_or_null("Camera3D") != null, "Main scene must include Camera3D") and ok
    ok = _assert(scene.get_node_or_null("DirectionalLight3D") != null, "Main scene must include DirectionalLight3D") and ok
    ok = _assert(scene.get_node_or_null("GameHud") != null, "Main scene must include GameHud") and ok
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var snapshot_before: Dictionary = sim.canonical_snapshot()
    scene.sync_from_simulation(sim)
    var world_root: Node = scene.get_node("WorldRoot")
    var terrain: Node = scene.get_node("WorldRoot/Terrain")
    var resources: Node = scene.get_node("WorldRoot/Resources")
    var units: Node = scene.get_node("WorldRoot/Units")
    var labels: Node = scene.get_node("WorldRoot/DebugLabels")
    ok = _assert(terrain.get_child_count() == 256, "visual shell must draw a flat 16x16 terrain grid from sim world cells") and ok
    ok = _assert(resources.get_child_count() == sim.canonical_snapshot()["resources"].size(), "visual shell must draw one blockout resource per sim resource") and ok
    var tree_resource_id: String = ""
    for resource in sim.canonical_snapshot()["resources"]:
        if resource["type"] == "tree":
            tree_resource_id = resource["id"]
            break
    ok = _assert(tree_resource_id != "", "seeded fixture should include at least one tree resource") and ok
    ok = _assert(world_root.get_node_or_null("Resources/TreeCube_" + tree_resource_id) != null, "tree resources must be named TreeCube_<resource id> blockouts (for example TreeCube_resource_000001 when that id is a tree)") and ok
    ok = _assert(units.get_child_count() == 3, "visual shell must spawn one UnitView per sim unit") and ok
    ok = _assert(units.get_child(0).get_node_or_null("Label3D") != null, "unit blockouts may expose debug Label3D nodes") and ok
    ok = _assert(labels != null, "WorldRoot must provide a DebugLabels container for optional presentation-only labels") and ok
    ok = _assert(JSON.stringify(snapshot_before) == JSON.stringify(sim.canonical_snapshot()), "sync_from_simulation must only read sim state and never mutate it") and ok
    ok = _test_resource_visuals_update_after_depletion(scene, sim, tree_resource_id) and ok
    ok = _test_new_items_are_rendered(scene, sim) and ok
    ok = _test_units_stay_synced_after_ticks(scene, sim) and ok
    ok = _test_rendering_does_not_mutate_after_dynamic_state(scene, sim) and ok
    scene.free()
    return ok

func _test_resource_visuals_update_after_depletion(scene: Node, sim: Simulation, resource_id: String) -> bool:
    var ok: bool = true
    var resource_block_name: String = _resource_node_name(sim.resources[resource_id])
    var resource_position: Array = sim.resources[resource_id]["position"]
    ok = _assert(scene.get_node_or_null("WorldRoot/Resources/" + resource_block_name) != null, "precondition: resource block must exist before the sim resource is depleted") and ok
    _deplete_resource(sim, resource_id)
    scene.sync_from_simulation(sim)
    var resources_root: Node = scene.get_node("WorldRoot/Resources")
    ok = _assert(not sim.resources.has(resource_id), "precondition: sim resource should be depleted and removed by the completed job") and ok
    ok = _assert(resources_root.get_node_or_null(resource_block_name) == null, "depleted resources must no longer keep their old block visual: " + resource_block_name) and ok
    ok = _assert(_find_resource_visual_at(resources_root, resource_position) == null, "resource visuals must clear or update the previous occupied cell after depletion") and ok
    return ok

func _test_new_items_are_rendered(scene: Node, sim: Simulation) -> bool:
    var ok: bool = true
    ok = _assert(sim.canonical_snapshot()["items"].size() > 0, "precondition: completed resource job should create item state") and ok
    scene.sync_from_simulation(sim)
    var world_root: Node = scene.get_node("WorldRoot")
    var items_root: Node = world_root.get_node_or_null("Items")
    ok = _assert(items_root != null, "WorldRoot must expose an Items container for presentation-only item blockouts/icons") and ok
    if items_root == null:
        return ok
    ok = _assert(items_root.get_child_count() == sim.canonical_snapshot()["items"].size(), "world shell must draw one simple item visual per simulation item") and ok
    for item_data in sim.canonical_snapshot()["items"]:
        var item_node: Node = items_root.get_node_or_null("Item_" + item_data["id"])
        ok = _assert(item_node != null, "item visuals must use stable names Item_<item id>; missing Item_" + item_data["id"]) and ok
        if item_node is Node3D:
            var expected_position := Vector3(item_data["position"][0], 0.18, item_data["position"][1])
            ok = _assert(_approx_vec3((item_node as Node3D).position, expected_position), "item visual must be positioned at its simulation cell for " + item_data["id"]) and ok
    return ok

func _test_units_stay_synced_after_ticks(scene: Node, sim: Simulation) -> bool:
    var ok: bool = true
    _advance_until_any_unit_leaves_initial_state(sim)
    scene.sync_from_simulation(sim)
    var units_root: Node = scene.get_node("WorldRoot/Units")
    ok = _assert(units_root.get_child_count() == sim.canonical_snapshot()["units"].size(), "unit visual count must stay synced after simulation ticks") and ok
    for unit_data in sim.canonical_snapshot()["units"]:
        var unit_node: Node = units_root.get_node_or_null("UnitView_" + unit_data["id"])
        ok = _assert(unit_node != null, "unit visuals must keep stable names after ticks; missing UnitView_" + unit_data["id"]) and ok
        if unit_node is Node3D:
            var expected_position := Vector3(unit_data["position"][0], 0.42, unit_data["position"][1])
            ok = _assert(_approx_vec3((unit_node as Node3D).position, expected_position), "unit visual position must match simulation position for " + unit_data["id"]) and ok
            var label: Label3D = unit_node.get_node_or_null("Label3D") as Label3D
            ok = _assert(label != null, "unit visual must expose a Label3D for status text after ticks") and ok
            if label != null:
                ok = _assert(label.text.find(unit_data["display_name"]) != -1, "unit label must include the simulation display name for " + unit_data["id"]) and ok
                ok = _assert(label.text.find(unit_data["state"]) != -1, "unit label must include the current simulation state for " + unit_data["id"]) and ok
    return ok

func _test_rendering_does_not_mutate_after_dynamic_state(scene: Node, sim: Simulation) -> bool:
    var snapshot_before_render: String = JSON.stringify(sim.canonical_snapshot())
    scene.sync_from_simulation(sim)
    scene.sync_from_simulation(sim)
    return _assert(snapshot_before_render == JSON.stringify(sim.canonical_snapshot()), "repeated dynamic rendering must not mutate simulation resources, items, units, jobs, commands, or RNG streams")

func _deplete_resource(sim: Simulation, resource_id: String) -> void:
    var resource: Dictionary = sim.resources[resource_id]
    var command_type: String = "DESIGNATE_CHOP"
    match resource["type"]:
        "stone":
            command_type = "DESIGNATE_GATHER_STONE"
        "berry":
            command_type = "DESIGNATE_GATHER_FOOD"
    sim.queue_command(sim.tick + 1, "player_test", command_type, Vector2i(resource["position"][0], resource["position"][1]), {"priority": 99})
    var guard: int = 0
    while sim.resources.has(resource_id) and guard < 128:
        sim.step_tick()
        guard += 1

func _advance_until_any_unit_leaves_initial_state(sim: Simulation) -> void:
    var guard: int = 0
    while guard < 16:
        sim.step_tick()
        guard += 1
        for unit_data in sim.canonical_snapshot()["units"]:
            if unit_data["state"] != "idle" or unit_data["position"] != [1, 1]:
                return

func _resource_node_name(resource: Dictionary) -> String:
    match resource["type"]:
        "stone":
            return "StoneCube_" + resource["id"]
        "berry":
            return "BerryCube_" + resource["id"]
    return "TreeCube_" + resource["id"]

func _find_resource_visual_at(resources_root: Node, position: Array) -> Node:
    var expected_x: float = float(position[0])
    var expected_z: float = float(position[1])
    for child in resources_root.get_children():
        if child is Node3D:
            var child_position: Vector3 = (child as Node3D).position
            if absf(child_position.x - expected_x) < 0.001 and absf(child_position.z - expected_z) < 0.001:
                return child
    return null

func _approx_vec3(actual: Vector3, expected: Vector3) -> bool:
    return actual.distance_to(expected) < 0.001
