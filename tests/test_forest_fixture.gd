extends RefCounted

const Simulation := preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _first_tree_position(sim: Simulation) -> Vector2i:
    var ids: Array = sim.resources.keys()
    ids.sort()
    for id in ids:
        var resource: Dictionary = sim.resources[id]
        if resource.get("type", "") == "tree":
            var pos: Array = resource["position"]
            return Vector2i(int(pos[0]), int(pos[1]))
    return Vector2i(-1, -1)

func _count_items_of_type(sim: Simulation, item_type: String) -> int:
    var total := 0
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type:
            total += item.quantity
    return total

func test_initial_forest_fixture_shape() -> bool:
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(4242)

    if not _assert(sim.world.width == 16 and sim.world.height == 16, "forest fixture must use a 16x16 grid"):
        return false
    if not _assert(sim.units.size() == 3, "forest fixture must spawn exactly 3 units"):
        return false
    if not _assert(sim.resources.size() > 0, "forest fixture must include tree resource nodes"):
        return false

    for id in sim.resources.keys():
        var resource: Dictionary = sim.resources[id]
        if not _assert(resource.get("type", "") == "tree", "forest fixture resources must be tree nodes only"):
            return false
        var pos: Array = resource["position"]
        var cell = sim.world.get_cell(Vector2i(int(pos[0]), int(pos[1])))
        if not _assert(cell != null and cell.resource_id == id, "tree resource index must match grid cell resource_id"):
            return false
    return true

func test_chop_designation_creates_job_and_produces_wood() -> bool:
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(4242)
    var tree_pos := _first_tree_position(sim)
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
    if not _assert(sim.job_board.jobs["job_000001"].status == "complete", "completed chop job must remain auditable as complete"):
        return false
    return true

func test_seeded_chop_replay_is_deterministic() -> bool:
    var a: Simulation = Simulation.new()
    var b: Simulation = Simulation.new()
    a.initialize_new_game(4242)
    b.initialize_new_game(4242)

    var tree_pos := _first_tree_position(a)
    var cmd := a.make_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 3}, "cmd_chop_tree")
    a.queue_existing_command(cmd)
    b.queue_existing_command(cmd.duplicate(true))
    for i in range(40):
        a.step_tick()
        b.step_tick()

    return _assert(a.state_hash() == b.state_hash(), "seeded forest plus chop designation must replay deterministically")

func run() -> bool:
    return test_initial_forest_fixture_shape() \
        and test_chop_designation_creates_job_and_produces_wood() \
        and test_seeded_chop_replay_is_deterministic()
