extends RefCounted

const JobBoard = preload("res://scripts/simulation/job_board.gd")
const SimJob = preload("res://scripts/simulation/job.gd")
const SimUnit = preload("res://scripts/simulation/unit.gd")
const SimulationScript = preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_unit_only_claims_allowed_job_types() and ok
    ok = _test_unit_job_type_priorities_override_distance_for_allowed_jobs() and ok
    ok = _test_unit_job_priorities_are_canonical_and_configurable() and ok
    ok = _test_simulation_command_sets_unit_job_type_priority() and ok
    ok = _test_distance_tiebreaking_two_units_two_jobs() and ok
    ok = _test_duplicate_designation_same_tree_creates_one_job() and ok
    ok = _test_duplicate_designation_same_stone_creates_one_job() and ok
    ok = _test_re_designation_after_completion_creates_new_job() and ok
    return ok

func _test_unit_only_claims_allowed_job_types() -> bool:
    var board = JobBoard.new()
    board.add_job(SimJob.new("job_chop", "CHOP_TREE", Vector2i(3, 3), 1))
    board.add_job(SimJob.new("job_stone", "GATHER_STONE", Vector2i(5, 5), 1))

    var unit = SimUnit.new("unit_001", "Lumberjack", Vector2i.ZERO)
    unit.allowed_jobs = Array(["CHOP_TREE"], TYPE_STRING, "", null)

    var ok: bool = true
    var first: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(first != null, "restricted unit should find at least one claimable job") and ok
    ok = _assert(first.id == "job_chop", "unit with allowed_jobs=[CHOP_TREE] should claim CHOP_TREE, not GATHER_STONE") and ok
    ok = _assert(first.type == "CHOP_TREE", "claimed job type should be CHOP_TREE") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_001", "claimed_by_unit_id should be set to the claiming unit") and ok

    var second: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(second == null, "unit restricted to CHOP_TREE should not claim GATHER_STONE job") and ok

    var stone_job: SimJob = board.jobs["job_stone"]
    ok = _assert(stone_job.status == "open", "GATHER_STONE job should remain open after restricted unit claimed") and ok
    ok = _assert(stone_job.claimed_by_unit_id == "", "GATHER_STONE job should have no claimant") and ok
    return ok

func _test_unit_job_type_priorities_override_distance_for_allowed_jobs() -> bool:
    var board = JobBoard.new()
    board.add_job(SimJob.new("job_close_chop", "CHOP_TREE", Vector2i(1, 0), 1))
    board.add_job(SimJob.new("job_far_haul", "HAUL_ITEM", Vector2i(10, 0), 1))
    var unit = SimUnit.new("unit_hauler", "Hauler", Vector2i.ZERO)
    unit.set_job_type_priority("CHOP_TREE", 1)
    unit.set_job_type_priority("HAUL_ITEM", 8)

    var ok: bool = true
    var first: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(first != null, "unit should claim one of the available allowed jobs") and ok
    ok = _assert(first.id == "job_far_haul", "unit job-type priority should choose HAUL_ITEM over a closer CHOP_TREE at the same job priority") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_hauler", "prioritized job should be claimed by the unit") and ok
    return ok

func _test_unit_job_priorities_are_canonical_and_configurable() -> bool:
    var unit = SimUnit.new("unit_001", "Worker", Vector2i.ZERO)
    var ok: bool = true
    ok = _assert(unit.get_job_type_priority("CHOP_TREE") == 1, "default CHOP_TREE type priority should be 1") and ok
    unit.set_job_type_priority("HAUL_ITEM", 9)
    unit.set_job_type_priority("CHOP_TREE", 3)
    unit.set_job_type_priority("GATHER_FOOD", 0)
    var snapshot: Dictionary = unit.to_canonical_dict()
    ok = _assert(snapshot.has("job_type_priorities"), "unit canonical snapshot should include configurable job-type priorities") and ok
    ok = _assert(snapshot["job_type_priorities"].get("CHOP_TREE", -1) == 3, "canonical snapshot should store CHOP_TREE priority") and ok
    ok = _assert(snapshot["job_type_priorities"].get("HAUL_ITEM", -1) == 9, "canonical snapshot should store HAUL_ITEM priority") and ok
    ok = _assert(not snapshot["job_type_priorities"].has("GATHER_FOOD"), "setting priority <= 0 should remove/disable the custom priority entry") and ok
    return ok

func _test_simulation_command_sets_unit_job_type_priority() -> bool:
    var sim = SimulationScript.new()
    sim.initialize_new_game(1234)
    sim.queue_command(1, "player_001", "SET_UNIT_JOB_PRIORITY", Vector2i.ZERO, {"unit_id": "unit_000001", "job_type": "HAUL_ITEM", "priority": 10})
    sim.step_tick()

    var unit = sim.units["unit_000001"]
    var ok: bool = true
    ok = _assert(unit.get_job_type_priority("HAUL_ITEM") == 10, "SET_UNIT_JOB_PRIORITY command should update the target unit's job-type priority") and ok
    ok = _assert(sim.canonical_snapshot()["units"][0]["job_type_priorities"].get("HAUL_ITEM", -1) == 10, "unit priority command should affect canonical simulation state") and ok
    return ok

func _test_distance_tiebreaking_two_units_two_jobs() -> bool:
    var board2 = JobBoard.new()
    board2.add_job(SimJob.new("job_alpha", "CHOP_TREE", Vector2i(10, 0), 1))
    board2.add_job(SimJob.new("job_beta", "CHOP_TREE", Vector2i(0, 20), 1))
    var unit_a = SimUnit.new("unit_a", "Worker A", Vector2i(0, 0))
    var unit_b = SimUnit.new("unit_b", "Worker B", Vector2i(0, 15))

    var ok: bool = true
    var claim_a: SimJob = board2.claim_next_open_job_for_unit(unit_a)
    ok = _assert(claim_a != null, "unit_a should find a claimable job") and ok
    ok = _assert(claim_a.id == "job_alpha", "unit_a at (0,0) should claim job_alpha at (10,0) [dist=10] over job_beta at (0,20) [dist=20]") and ok

    var claim_b: SimJob = board2.claim_next_open_job_for_unit(unit_b)
    ok = _assert(claim_b != null, "unit_b should find a claimable job") and ok
    ok = _assert(claim_b.id == "job_beta", "unit_b at (0,15) should claim job_beta at (0,20) [dist=5] over job_alpha at (10,0) [dist=25]") and ok

    ok = _assert(board2.jobs["job_alpha"].status == "claimed", "job_alpha should be claimed") and ok
    ok = _assert(board2.jobs["job_beta"].status == "claimed", "job_beta should be claimed") and ok
    ok = _assert(board2.jobs["job_alpha"].claimed_by_unit_id == "unit_a", "job_alpha should be claimed by unit_a") and ok
    ok = _assert(board2.jobs["job_beta"].claimed_by_unit_id == "unit_b", "job_beta should be claimed by unit_b") and ok
    return ok


func _test_duplicate_designation_same_tree_creates_one_job() -> bool:
    var board = JobBoard.new()
    var cell := Vector2i(3, 3)
    var unit = SimUnit.new("unit_001", "Lumberjack", Vector2i.ZERO)

    var ok: bool = true
    ok = _assert(not board.has_open_job_at("CHOP_TREE", cell), "no open job should exist before first designation") and ok
    board.add_job(SimJob.new("job_001", "CHOP_TREE", cell, 1))

    var dup_claim: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(dup_claim != null and dup_claim.id == "job_001", "first designation unit should claim the job") and ok
    ok = _assert(board.jobs.size() == 1, "board should have exactly 1 job after first designation") and ok

    if board.has_open_job_at("CHOP_TREE", cell):
        pass
    else:
        board.add_job(SimJob.new("job_002", "CHOP_TREE", cell, 1))

    ok = _assert(board.jobs.size() == 1, "second designation of same tree cell should not create a duplicate job") and ok
    ok = _assert(board.jobs["job_001"].status == "claimed", "original job remains claimed") and ok
    ok = _assert(not board.has_open_job_at("GATHER_STONE", cell), "no GATHER_STONE job exists yet") and ok
    board.add_job(SimJob.new("job_003", "GATHER_STONE", cell, 1))
    ok = _assert(board.jobs.size() == 2, "a different job type at same cell should be allowed") and ok
    return ok


func _test_duplicate_designation_same_stone_creates_one_job() -> bool:
    # Verify that designating an already-designated stone cell does not create
    # a duplicate GATHER_STONE job. The second designation is silently ignored.
    var board = JobBoard.new()
    var cell := Vector2i(5, 5)
    var unit = SimUnit.new("unit_001", "Miner", Vector2i.ZERO)
    var ok: bool = true
    ok = _assert(not board.has_open_job_at("GATHER_STONE", cell), "no open job should exist before first designation") and ok
    board.add_job(SimJob.new("job_001", "GATHER_STONE", cell, 1))
    var dup_claim: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(dup_claim != null and dup_claim.id == "job_001", "first designation unit should claim the job") and ok
    ok = _assert(board.jobs.size() == 1, "board should have exactly 1 job after first designation") and ok
    # Second designation of same cell -- simulating what the game loop does
    if board.has_open_job_at("GATHER_STONE", cell):
        pass  # Duplicate skipped by caller guard
    else:
        board.add_job(SimJob.new("job_002", "GATHER_STONE", cell, 1))
    ok = _assert(board.jobs.size() == 1, "second designation of same stone cell should not create a duplicate job") and ok
    ok = _assert(board.jobs["job_001"].status == "claimed", "original job remains claimed") and ok
    # CHOP_TREE at the same cell should still be allowed (different type)
    ok = _assert(not board.has_open_job_at("CHOP_TREE", cell), "no CHOP_TREE job exists yet") and ok
    board.add_job(SimJob.new("job_003", "CHOP_TREE", cell, 1))
    ok = _assert(board.jobs.size() == 2, "a different job type at same cell should be allowed") and ok
    return ok


func _test_re_designation_after_completion_creates_new_job() -> bool:
    var board = JobBoard.new()
    var cell := Vector2i(5, 5)
    var unit = SimUnit.new("unit_001", "Lumberjack", Vector2i.ZERO)
    var ok: bool = true

    board.add_job(SimJob.new("job_001", "CHOP_TREE", cell, 1))
    var red_claim: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(red_claim != null, "unit should claim the first job") and ok

    board.jobs["job_001"].status = "complete"
    board.jobs["job_001"].work_remaining_ticks = 0

    ok = _assert(not board.has_open_job_at("CHOP_TREE", cell), "completed job should not block re-designation") and ok
    board.add_job(SimJob.new("job_002", "CHOP_TREE", cell, 1))
    ok = _assert(board.jobs.size() == 2, "re-designation after completion should create a new job") and ok
    ok = _assert(board.has_open_job_at("CHOP_TREE", cell), "new open job should exist after re-designation") and ok
    ok = _assert(board.jobs["job_001"].status == "complete", "old job should remain complete") and ok
    ok = _assert(board.jobs["job_002"].status == "open", "newly added job should be open") and ok

    var unit2 = SimUnit.new("unit_002", "Lumberjack", Vector2i.ZERO)
    var red_claim2: SimJob = board.claim_next_open_job_for_unit(unit2)
    ok = _assert(red_claim2 != null and red_claim2.id == "job_002", "new unit should be able to claim the re-designated job") and ok

    return ok
