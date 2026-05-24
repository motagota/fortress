extends RefCounted

const Simulation := preload("res://scripts/simulation/simulation.gd")
const SimJob := preload("res://scripts/simulation/job.gd")
const SimUnit := preload("res://scripts/simulation/unit.gd")

# ---------------------------------------------------------------------------
# M2: Integration test — full autonomous job lifecycle
#
# Proves that units autonomously:
#   1. claim open jobs from the job board
#   2. walk to the target resource cell
#   3. work the job until it completes
#   4. drop produced items on the ground
#   5. return to idle
#   6. deplete the source resource node
#
# Uses the real Simulation class end-to-end (no mocking).
# ---------------------------------------------------------------------------

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true


# -- helpers ---------------------------------------------------------------

func _place_resource(sim:, resource_id: String, resource_type: String, pos: Vector2i, yield_override: Dictionary = {}) -> void:
    sim.resources[resource_id] = {"id": resource_id, "type": resource_type, "position": [pos.x, pos.y]}
    if not yield_override.is_empty():
        sim.resources[resource_id]["yield"] = yield_override
    sim.world.set_resource(pos, resource_id)


func _count_items_of_type(sim:, item_type: String) -> int:
    var total := 0
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type:
            total += item.quantity
    return total


func _item_exists_at(sim:, item_type: String, pos: Vector2i) -> bool:
    for id in sim.items.keys():
        var item = sim.items[id]
        if item.item_type == item_type and item.position == pos:
            return true
    return false


func _step_until_all_complete(sim:, job_ids: Array, max_steps: int = 80) -> int:
    var steps := 0
    for _i in range(max_steps):
        steps += 1
        sim.step_tick()
        var all_done := true
        for jid in job_ids:
            var job: SimJob = sim.job_board.jobs.get(jid)
            if job == null or job.status != "complete":
                all_done = false
                break
        if all_done:
            break
    return steps


# -- tests ------------------------------------------------------------------

func _test_unit_claims_and_completes_chop_tree() -> bool:
    # Setup: fresh sim, known tree at (5, 1) — close to unit starting area
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var tree_pos := Vector2i(5, 1)
    _place_resource(sim, "res_tree_int", "tree", tree_pos)

    # Designate the tree for chopping on tick 1
    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 5})

    # Step at least once so the command is applied
    sim.step_tick()

    # There should be exactly one job after designation
    var ok := true
    ok = _assert(sim.job_board.jobs.size() == 1, "CHOP_TREE designation must create exactly one job") and ok

    # Resolve the job id (it is job_000001 because id_counters reset on new game)
    var job_id: String = "job_000001"
    ok = _assert(sim.job_board.jobs.has(job_id), "job_000001 must exist after single chop designation") and ok

    # Step until the chop job completes
    var steps := _step_until_all_complete(sim, [job_id], 80)
    ok = _assert(steps < 80, "chop job must complete within 80 ticks (took %d)" % steps) and ok

    # Assert: job is complete
    var job: SimJob = sim.job_board.jobs[job_id]
    ok = _assert(job.status == "complete", "chop job status must be 'complete', got '%s'" % job.status) and ok

    # Assert: wood item exists on the ground at the tree cell
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "chop must produce exactly one wood item") and ok
    ok = _assert(_item_exists_at(sim, "wood", tree_pos), "wood item must be on the ground at the tree cell") and ok

    # Assert: resource node depleted
    ok = _assert(not sim.resources.has("res_tree_int"), "tree resource must be removed from the global index") and ok
    ok = _assert(sim.world.get_cell(tree_pos).resource_id == "", "tree cell must have empty resource_id after depletion") and ok

    # Assert: the unit that worked the job returned to idle
    var any_idle_with_no_job := false
    for uid in sim.units.keys():
        var unit: SimUnit = sim.units[uid]
        if unit.state == "idle" and unit.current_job_id == "":
            any_idle_with_no_job = true
            break
    ok = _assert(any_idle_with_no_job, "at least one unit must return to idle after job completion") and ok

    return ok


func _test_unit_claims_and_completes_gather_stone() -> bool:
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var stone_pos := Vector2i(1, 5)
    _place_resource(sim, "res_stone_int", "stone", stone_pos)

    sim.queue_command(1, "player_001", "DESIGNATE_GATHER_STONE", stone_pos, {"priority": 3})
    sim.step_tick()

    var ok := true
    ok = _assert(sim.job_board.jobs.size() == 1, "GATHER_STONE designation must create exactly one job") and ok

    var job_id: String = "job_000001"
    _step_until_all_complete(sim, [job_id], 80)

    var job: SimJob = sim.job_board.jobs[job_id]
    ok = _assert(job.status == "complete", "gather-stone job status must be 'complete', got '%s'" % job.status) and ok

    # Assert: stone item on ground
    ok = _assert(_count_items_of_type(sim, "stone") == 1, "gather-stone must produce exactly one stone item") and ok
    ok = _assert(_item_exists_at(sim, "stone", stone_pos), "stone item must be on the ground at the stone cell") and ok

    # Assert: resource depleted
    ok = _assert(not sim.resources.has("res_stone_int"), "stone resource must be removed from the global index") and ok
    ok = _assert(sim.world.get_cell(stone_pos).resource_id == "", "stone cell must have empty resource_id after depletion") and ok

    # Assert: unit back to idle
    var all_idle := true
    for uid in sim.units.keys():
        var unit: SimUnit = sim.units[uid]
        if unit.current_job_id != "":
            all_idle = false
            break
    ok = _assert(all_idle, "no unit should hold a job reference after gather-stone completes") and ok

    return ok


func _test_two_units_claim_two_jobs_and_both_complete() -> bool:
    # Core integration: 2 units, 2 designations (CHOP_TREE + GATHER_STONE)
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(7)

    # Place a tree near unit start and a stone nearby
    var tree_pos := Vector2i(4, 1)
    var stone_pos := Vector2i(1, 4)
    _place_resource(sim, "res_tree_dual", "tree", tree_pos)
    _place_resource(sim, "res_stone_dual", "stone", stone_pos)

    # Queue both designations for tick 1
    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 2})
    sim.queue_command(1, "player_001", "DESIGNATE_GATHER_STONE", stone_pos, {"priority": 1})

    sim.step_tick()

    var ok := true
    ok = _assert(sim.job_board.jobs.size() == 2, "two designations must create two jobs, got %d" % sim.job_board.jobs.size()) and ok

    # Resolve job ids (job_000001 = first designation, job_000002 = second)
    var chop_id: String = "job_000001"
    var stone_id: String = "job_000002"
    ok = _assert(sim.job_board.jobs.has(chop_id), "chop job_000001 must exist") and ok
    ok = _assert(sim.job_board.jobs.has(stone_id), "stone job_000002 must exist") and ok

    # Step until both jobs are complete
    var steps := _step_until_all_complete(sim, [chop_id, stone_id], 120)
    ok = _assert(steps < 120, "both jobs must complete within 120 ticks (took %d)" % steps) and ok

    # -- Both jobs complete --
    var chop_job: SimJob = sim.job_board.jobs[chop_id]
    var stone_job: SimJob = sim.job_board.jobs[stone_id]
    ok = _assert(chop_job.status == "complete", "chop job status must be 'complete', got '%s'" % chop_job.status) and ok
    ok = _assert(stone_job.status == "complete", "stone job status must be 'complete', got '%s'" % stone_job.status) and ok

    # -- Items on ground --
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "exactly one wood item must exist after chop") and ok
    ok = _assert(_count_items_of_type(sim, "stone") == 1, "exactly one stone item must exist after gather") and ok
    ok = _assert(_item_exists_at(sim, "wood", tree_pos), "wood must be on the ground at the tree cell") and ok
    ok = _assert(_item_exists_at(sim, "stone", stone_pos), "stone must be on the ground at the stone cell") and ok

    # -- Resource nodes depleted --
    ok = _assert(not sim.resources.has("res_tree_dual"), "tree resource must be removed from index") and ok
    ok = _assert(not sim.resources.has("res_stone_dual"), "stone resource must be removed from index") and ok
    ok = _assert(sim.world.get_cell(tree_pos).resource_id == "", "tree cell resource_id must be empty") and ok
    ok = _assert(sim.world.get_cell(stone_pos).resource_id == "", "stone cell resource_id must be empty") and ok

    # -- All units idle (no current_job_id) --
    for uid in sim.units.keys():
        var unit: SimUnit = sim.units[uid]
        ok = _assert(unit.current_job_id == "", "unit %s must have empty current_job_id after completion, got '%s'" % [uid, unit.current_job_id]) and ok
        ok = _assert(unit.state == "idle", "unit %s must be idle after completion, got '%s'" % [uid, unit.state]) and ok

    # -- Resource conservation: items produced == resources consumed --
    # We started with 2 placed resources (1 tree, 1 stone) and the forest seed
    # may have placed more. We only check the items we know about.
    var total_wood := _count_items_of_type(sim, "wood")
    var total_stone := _count_items_of_type(sim, "stone")
    ok = _assert(total_wood == 1, "resource conservation: exactly 1 wood from 1 tree, got %d" % total_wood) and ok
    ok = _assert(total_stone == 1, "resource conservation: exactly 1 stone from 1 stone node, got %d" % total_stone) and ok

    return ok


func _test_unit_walks_to_distant_resource_and_completes() -> bool:
    # Verifies pathfinding: place a resource far from the units' start positions
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(99)
    var far_pos := Vector2i(10, 10)
    _place_resource(sim, "res_tree_far", "tree", far_pos)

    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", far_pos, {"priority": 1})
    sim.step_tick()

    var ok := true
    ok = _assert(sim.job_board.jobs.size() == 1, "distant chop designation must create one job") and ok

    var job_id: String = "job_000001"
    var steps := _step_until_all_complete(sim, [job_id], 200)
    ok = _assert(steps < 200, "distant chop must complete within 200 ticks (took %d)" % steps) and ok

    var job: SimJob = sim.job_board.jobs[job_id]
    ok = _assert(job.status == "complete", "distant chop job must be complete") and ok
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "distant chop must produce one wood item") and ok
    ok = _assert(_item_exists_at(sim, "wood", far_pos), "wood must appear at the distant cell") and ok
    ok = _assert(sim.world.get_cell(far_pos).resource_id == "", "distant tree cell must be cleared") and ok

    return ok


func _test_job_claim_is_atomic_no_double_claim() -> bool:
    # Two units, one job -- only one unit should claim it
    var sim: Simulation = Simulation.new()
    sim.initialize_new_game(42)
    var tree_pos := Vector2i(3, 1)
    _place_resource(sim, "res_tree_single", "tree", tree_pos)

    sim.queue_command(1, "player_001", "DESIGNATE_CHOP", tree_pos, {"priority": 1})
    sim.step_tick()

    var ok := true
    ok = _assert(sim.job_board.jobs.size() == 1, "single designation = single job") and ok

    var job_id: String = "job_000001"
    _step_until_all_complete(sim, [job_id], 80)

    var job: SimJob = sim.job_board.jobs[job_id]
    ok = _assert(job.status == "complete", "single job must complete") and ok
    ok = _assert(job.claimed_by_unit_id != "", "completed job must have a claimant") and ok

    # Only one unit should have claimed this job
    var claimants := 0
    for uid in sim.units.keys():
        var unit: SimUnit = sim.units[uid]
        if unit.id == job.claimed_by_unit_id:
            claimants += 1
    ok = _assert(claimants == 1, "exactly one unit must be the claimant, found %d" % claimants) and ok

    # Only one wood item produced (no double-claim means no double-produce)
    ok = _assert(_count_items_of_type(sim, "wood") == 1, "single claim must produce exactly one wood") and ok

    return ok


# -- runner -----------------------------------------------------------------

func run() -> bool:
    var ok: bool = true
    ok = _test_unit_claims_and_completes_chop_tree() and ok
    ok = _test_unit_claims_and_completes_gather_stone() and ok
    ok = _test_two_units_claim_two_jobs_and_both_complete() and ok
    ok = _test_unit_walks_to_distant_resource_and_completes() and ok
    ok = _test_job_claim_is_atomic_no_double_claim() and ok
    return ok
