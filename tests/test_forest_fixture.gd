extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _first_tree_position(sim) -> Vector2i:
    var ids: Array = sim.resources.keys()
    ids.sort()
    for id in ids:
        var resource: Dictionary = sim.resources[id]
        if resource.get("type", "") == "tree":
            var pos: Array = resource["position"]
            return Vector2i(int(pos[0]), int(pos[1]))
    return Vector2i(-1, -1)

func _first_berry_position(sim) -> Vector2i:
    var ids: Array = sim.resources.keys()
    ids.sort()
    for id in ids:
        var resource: Dictionary = sim.resources[id]
        if resource.get("type", "") == "berry":
            var pos: Array = resource["position"]
            return Vector2i(int(pos[0]), int(pos[1]))
    return Vector2i(-1, -1)

func _first_stone_position(sim) -> Vector2i:
    var ids: Array = sim.resources.keys()
    ids.sort()
    for id in ids:
        var resource: Dictionary = sim.resources[id]
        if resource.get("type", "") == "stone":
            var pos: Array = resource["position"]
            return Vector2i(int(pos[0]), int(pos[1]))
    return Vector2i(-1, -1)

func _layer_for_depth(depth: int) -> int:
    return 1 - depth

func _count_items_of_type(sim, item_type: String) -> int:
    var total = 0
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type:
            total += item.quantity
    return total

func test_initial_forest_fixture_shape() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)

    if not _assert(sim.world.width == 16 and sim.world.height == 16, "forest fixture must use a 16x16 grid"):
        return false
    if not _assert(sim.units.size() == 3, "forest fixture must spawn exactly 3 units"):
        return false
    if not _assert(_first_tree_position(sim) != Vector2i(-1, -1), "forest fixture must include tree resource nodes"):
        return false
    if not _assert(_first_berry_position(sim) != Vector2i(-1, -1), "forest fixture must include berry resource nodes"):
        return false
    if not _assert(_first_stone_position(sim) != Vector2i(-1, -1), "forest fixture must include surface rock resource nodes"):
        return false
    if not _assert(sim.world.get_cell(Vector2i(0, 12)).depth == -3, "forest fixture must include generated layer 4 at depth -3"):
        return false
    if not _assert(sim.world.get_cell(Vector2i(0, 12)).terrain == "dirt", "layer 4 should still generate as dirt before mining"):
        return false
    if not _assert(sim.world.get_cell(Vector2i(0, 13)).depth == -4, "forest fixture must include generated layer 5 at depth -4"):
        return false
    if not _assert(sim.world.get_cell(Vector2i(0, 13)).terrain == "solid_rock", "layer 5 should generate as solid rock"):
        return false

    for id in sim.resources.keys():
        var resource: Dictionary = sim.resources[id]
        if not _assert(resource.get("type", "") in ["tree", "berry", "stone"], "forest fixture resources must be tree, berry, or surface rock nodes"):
            return false
        var pos: Array = resource["position"]
        var cell = sim.world.get_cell(Vector2i(int(pos[0]), int(pos[1])))
        if not _assert(cell != null and cell.resource_id == id, "resource index must match grid cell resource_id"):
            return false
        var layer: int = _layer_for_depth(int(cell.depth))
        if resource.get("type", "") in ["tree", "berry"]:
            if not _assert(layer == 1, "trees and berries must only generate on the surface layer"):
                return false
        if resource.get("type", "") == "stone":
            if not _assert(layer >= 1 and layer <= 3, "surface rocks must only generate in layers 1 through 3"):
                return false
    return true

func test_gather_berries_creates_food() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var berry_pos = _first_berry_position(sim)
    if not _assert(berry_pos != Vector2i(-1, -1), "seeded forest must provide at least one berry target"):
        return false

    sim.queue_command(1, "player_001", "DESIGNATE_GATHER_FOOD", berry_pos, {"priority": 5})
    for i in range(32):
        sim.step_tick()

    if not _assert(sim.world.get_cell(berry_pos).resource_id == "", "completed gather-food job must remove berry resource from cell"):
        return false
    if not _assert(_count_items_of_type(sim, "food") == 1, "completed berry gather must produce one food item"):
        return false
    if not _assert(not sim.job_board.jobs.has("job_000001"), "completed gather-food job must be removed from the live job board"):
        return false
    return true

func test_chop_designation_creates_job_and_produces_wood() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(4242)
    var tree_pos = _first_tree_position(sim)
    if not _assert(tree_pos != Vector2i(-1, -1), "seeded forest must provide at least one tree target"):
        return false

    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 5})
    sim.step_tick()

    if not _assert(sim.job_board.jobs.size() == 1, "chop designation must create one job record"):
        return false
    var job = sim.job_board.jobs["job_000001"]
    if not _assert(job.type == "CHOP_TREE" and job.target_cell == tree_pos and job.priority == 5, "chop job must preserve type, target, and priority"):
        return false

    for i in range(32):
        sim.step_tick()

    if not _assert(sim.world.get_cell(tree_pos).resource_id == "", "completed chop job must remove tree resource from cell"):
        return false
    if not _assert(_count_items_of_type(sim, "wood") == 1, "completed chop job must produce one wood item"):
        return false
    if not _assert(not sim.job_board.jobs.has("job_000001"), "completed chop job must be removed from the live job board"):
        return false
    return true

func test_seeded_chop_replay_is_deterministic() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    a.initialize_new_game(4242)
    b.initialize_new_game(4242)

    var tree_pos = _first_tree_position(a)
    var cmd: Dictionary = a.make_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 3}, "cmd_chop_tree")
    a.queue_existing_command(cmd)
    b.queue_existing_command(cmd.duplicate(true))
    for i in range(40):
        a.step_tick()
        b.step_tick()

    return _assert(a.state_hash() == b.state_hash(), "seeded forest plus chop designation must replay deterministically")

func run() -> bool:
    return test_initial_forest_fixture_shape() \
        and test_gather_berries_creates_food() \
        and test_chop_designation_creates_job_and_produces_wood() \
        and test_seeded_chop_replay_is_deterministic()
