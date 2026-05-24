extends RefCounted

const JobBoard = preload("res://scripts/simulation/job_board.gd")
const SimJob = preload("res://scripts/simulation/job.gd")
const SimUnit = preload("res://scripts/simulation/unit.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_claim_next_open_job_is_deterministic_and_marks_claimed_once() and ok
    ok = _test_preclaimed_open_jobs_are_not_selectable_or_claimable() and ok
    ok = _test_has_open_job_at_prevents_duplicate_chop_tree() and ok
    ok = _test_has_open_job_at_prevents_duplicate_gather_stone() and ok
    ok = _test_re_designation_after_completion_creates_new_job() and ok
    ok = _test_duplicate_designation_via_simulation_for_chop_tree() and ok
    ok = _test_duplicate_designation_via_simulation_for_gather_stone() and ok
    return ok

func _test_claim_next_open_job_is_deterministic_and_marks_claimed_once() -> bool:
    var board = JobBoard.new()
    board.add_job(SimJob.new("job_b", "CHOP_TREE", Vector2i(9, 9), 5))
    board.add_job(SimJob.new("job_a", "CHOP_TREE", Vector2i(1, 1), 5))
    board.add_job(SimJob.new("job_z", "CHOP_TREE", Vector2i(0, 0), 1))
    var unit = SimUnit.new("unit_001", "Worker", Vector2i.ZERO)

    var ok: bool = true
    ok = _assert(board.has_method("claim_next_open_job_for_unit"), "job board should expose an atomic select-and-claim method for idle units") and ok
    if not ok:
        return false

    var first: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(first != null, "claim_next_open_job_for_unit should return the selected job") and ok
    ok = _assert(first.id == "job_a", "highest priority ties should resolve by stable job id ascending") and ok
    ok = _assert(first.status == "claimed", "claiming should mark the returned job claimed") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_001", "claiming should set claimed_by_unit_id to the claiming unit exactly once") and ok

    var second = board.claim_next_open_job_for_unit(unit)
    ok = _assert(second != null and second.id == "job_b", "already-claimed jobs should no longer be selectable") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_001", "a later claim should not mutate the previous job claimant") and ok
    return ok

func _test_preclaimed_open_jobs_are_not_selectable_or_claimable() -> bool:
    var board = JobBoard.new()
    var stale = SimJob.new("job_a", "CHOP_TREE", Vector2i.ZERO, 10)
    stale.claimed_by_unit_id = "unit_previous"
    board.add_job(stale)
    board.add_job(SimJob.new("job_b", "CHOP_TREE", Vector2i.ZERO, 1))
    var unit = SimUnit.new("unit_002", "Worker", Vector2i.ZERO)

    var ok: bool = true
    ok = _assert(board.has_method("claim_next_open_job_for_unit"), "job board should expose an atomic select-and-claim method for idle units") and ok
    if not ok:
        return false

    var selected = board.claim_next_open_job_for_unit(unit)
    ok = _assert(selected != null and selected.id == "job_b", "jobs with an existing claimant should not be selected even if their status is open") and ok
    ok = _assert(stale.claimed_by_unit_id == "unit_previous", "claiming must not overwrite an existing claimed_by_unit_id") and ok
    ok = _assert(not board.claim_job("job_a", "unit_002"), "claim_job should reject jobs with an existing claimant") and ok
    return ok


# ---------------------------------------------------------------------------
# Duplicate designation guard tests
# ---------------------------------------------------------------------------

func _test_has_open_job_at_prevents_duplicate_chop_tree() -> bool:
    var board = JobBoard.new()
    var cell = Vector2i(3, 3)

    var ok: bool = true
    ok = _assert(not board.has_open_job_at("CHOP_TREE", cell), "no open job should exist before designation") and ok

    var job1 = SimJob.new("job_001", "CHOP_TREE", cell, 1)
    board.add_job(job1)

    ok = _assert(board.has_open_job_at("CHOP_TREE", cell), "has_open_job_at should find the open CHOP_TREE job") and ok
    ok = _assert(board.jobs.size() == 1, "board should have exactly one job") and ok

    if board.has_open_job_at("CHOP_TREE", cell):
        pass
    else:
        board.add_job(SimJob.new("job_002", "CHOP_TREE", cell, 1))

    ok = _assert(board.jobs.size() == 1, "second designation of same tree cell should not create a duplicate job") and ok
    return ok


func _test_has_open_job_at_prevents_duplicate_gather_stone() -> bool:
    var board = JobBoard.new()
    var cell = Vector2i(5, 5)

    var ok: bool = true
    ok = _assert(not board.has_open_job_at("GATHER_STONE", cell), "no open job should exist before designation") and ok

    var job1 = SimJob.new("job_001", "GATHER_STONE", cell, 1)
    board.add_job(job1)

    ok = _assert(board.has_open_job_at("GATHER_STONE", cell), "has_open_job_at should find the open GATHER_STONE job") and ok

    if board.has_open_job_at("GATHER_STONE", cell):
        pass
    else:
        board.add_job(SimJob.new("job_002", "GATHER_STONE", cell, 1))

    ok = _assert(board.jobs.size() == 1, "second designation of same stone cell should not create a duplicate job") and ok

    if board.has_open_job_at("CHOP_TREE", cell):
        pass
    else:
        board.add_job(SimJob.new("job_003", "CHOP_TREE", cell, 1))

    ok = _assert(board.jobs.size() == 2, "a different job type at the same cell should be allowed") and ok
    return ok


func _test_re_designation_after_completion_creates_new_job() -> bool:
    var board = JobBoard.new()
    var cell = Vector2i(7, 7)

    var ok: bool = true

    var job1 = SimJob.new("job_001", "CHOP_TREE", cell, 1)
    board.add_job(job1)
    ok = _assert(board.has_open_job_at("CHOP_TREE", cell), "open job should exist before completion") and ok

    board.jobs["job_001"].status = "complete"
    board.jobs["job_001"].work_remaining_ticks = 0

    ok = _assert(not board.has_open_job_at("CHOP_TREE", cell), "completed job should not block re-designation") and ok

    var job2 = SimJob.new("job_002", "CHOP_TREE", cell, 1)
    board.add_job(job2)

    ok = _assert(board.jobs.size() == 2, "re-designation after completion should create a new job") and ok
    ok = _assert(board.has_open_job_at("CHOP_TREE", cell), "new open job should exist after re-designation") and ok
    ok = _assert(board.jobs["job_001"].status == "complete", "old job should remain complete") and ok
    ok = _assert(board.jobs["job_002"].status == "open", "new job should be open") and ok
    return ok


func _simulation_step_duplicate_guard(resource_type: String, designation_type: String, job_type: String) -> bool:
    const SimScript = preload("res://scripts/simulation/simulation.gd")
    var sim = SimScript.new()
    sim.initialize_new_game(4242)

    var target = Vector2i(3, 3)
    sim.resources["res_test"] = {"id": "res_test", "type": resource_type, "position": [target.x, target.y]}
    sim.world.set_resource(target, "res_test")

    sim.queue_command(1, "player_001", designation_type, target, {"priority": 5})
    sim.step_tick()

    var ok: bool = true
    ok = _assert(sim.job_board.jobs.size() == 1, "first designation should create exactly one %s job" % job_type) and ok

    sim.queue_command(2, "player_001", designation_type, target, {"priority": 5})
    sim.step_tick()

    ok = _assert(sim.job_board.jobs.size() == 1, "duplicate %s designation should not create a second job" % job_type) and ok
    ok = _assert(sim.job_board.has_open_job_at(job_type, target), "original %s job should still be open after duplicate attempt" % job_type) and ok

    return ok


func _test_duplicate_designation_via_simulation_for_chop_tree() -> bool:
    return _simulation_step_duplicate_guard("tree", "DESIGNATE_CHOP", "CHOP_TREE")


func _test_duplicate_designation_via_simulation_for_gather_stone() -> bool:
    return _simulation_step_duplicate_guard("stone", "DESIGNATE_GATHER_STONE", "GATHER_STONE")
