extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")
const SimJobScript = preload("res://scripts/simulation/job.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _place_resource(sim, resource_id: String, resource_type: String, pos: Vector2i, yield_override: Dictionary = {}) -> void:
    sim.resources[resource_id] = {"id": resource_id, "type": resource_type, "position": [pos.x, pos.y]}
    if not yield_override.is_empty():
        sim.resources[resource_id]["yield"] = yield_override
    sim.world.set_resource(pos, resource_id)

func _count_items_of_type(sim, item_type: String) -> int:
    var total: int = 0
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type:
            total += item.quantity
    return total

func _step_until_jobs_complete(sim, steps: int = 40) -> void:
    for i in range(steps):
        sim.step_tick()

func _test_gather_stone_completion_creates_stone_item() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(7)
    var target = Vector2i(3, 1)
    _place_resource(sim, "resource_stone_test", "stone", target, {"ore": 3})

    sim.queue_command(1, "player_001", "DESIGNATE_GATHER_STONE", target, {"priority": 4})
    _step_until_jobs_complete(sim)

    var ok: bool = true
    ok = _assert(_count_items_of_type(sim, "stone") == 1, "completed gather-stone job must produce one stone item from the job type") and ok
    ok = _assert(_count_items_of_type(sim, "ore") == 0, "gather-stone completion should not use arbitrary resource yield data instead of the job output") and ok
    ok = _assert(not sim.resources.has("resource_stone_test"), "completed gather-stone job must deplete its source resource") and ok
    ok = _assert(sim.world.get_cell(target).resource_id == "", "completed gather-stone job must clear depleted resource from its cell") and ok
    ok = _assert(not sim.job_board.jobs.has("job_000001"), "completed gather-stone job must be removed from the live job board") and ok
    return ok

func _test_gather_food_completion_creates_food_item() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(8)
    var target = Vector2i(3, 2)
    _place_resource(sim, "resource_berry_test", "berry", target, {"seed": 2})

    sim.queue_command(1, "player_001", "DESIGNATE_GATHER_FOOD", target, {"priority": 4})
    _step_until_jobs_complete(sim)

    var ok: bool = true
    ok = _assert(_count_items_of_type(sim, "food") == 1, "completed gather-food job must produce one food item from the job type") and ok
    ok = _assert(_count_items_of_type(sim, "seed") == 0, "gather-food completion should not use arbitrary resource yield data instead of the job output") and ok
    ok = _assert(not sim.resources.has("resource_berry_test"), "completed gather-food job must deplete its source resource") and ok
    ok = _assert(sim.world.get_cell(target).resource_id == "", "completed gather-food job must clear depleted resource from its cell") and ok
    ok = _assert(not sim.job_board.jobs.has("job_000001"), "completed gather-food job must be removed from the live job board") and ok
    return ok

func _test_repeated_chop_completion_cannot_create_wood_from_depleted_tree() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(9)
    var target = Vector2i(3, 3)
    _place_resource(sim, "resource_tree_test", "tree", target)
    sim.job_board.add_job(SimJobScript.new("job_repeat_a", "CHOP_TREE", target, 10))
    sim.job_board.add_job(SimJobScript.new("job_repeat_b", "CHOP_TREE", target, 9))

    _step_until_jobs_complete(sim)

    var ok: bool = true
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "only the first chop completion should produce wood from a tree") and ok
    ok = _assert(not sim.resources.has("resource_tree_test"), "completed chop job must remove depleted tree from resource index") and ok
    ok = _assert(sim.world.get_cell(target).resource_id == "", "completed chop job must clear depleted tree from its cell") and ok
    ok = _assert(not sim.job_board.jobs.has("job_repeat_a"), "first repeated chop job should be removed after completion") and ok
    ok = _assert(not sim.job_board.jobs.has("job_repeat_b"), "second repeated chop job should be removed after completion without producing duplicate wood") and ok
    return ok

func run() -> bool:
    return _test_gather_stone_completion_creates_stone_item() \
        and _test_gather_food_completion_creates_food_item() \
        and _test_repeated_chop_completion_cannot_create_wood_from_depleted_tree()
