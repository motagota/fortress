extends RefCounted

const JobBoard := preload("res://scripts/simulation/job_board.gd")
const SimJob := preload("res://scripts/simulation/job.gd")
const SimUnit := preload("res://scripts/simulation/unit.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_claim_next_open_job_is_deterministic_and_marks_claimed_once() and ok
    ok = _test_preclaimed_open_jobs_are_not_selectable_or_claimable() and ok
    return ok

func _test_claim_next_open_job_is_deterministic_and_marks_claimed_once() -> bool:
    var board: JobBoard = JobBoard.new()
    board.add_job(SimJob.new("job_b", "CHOP_TREE", Vector2i(9, 9), 5))
    board.add_job(SimJob.new("job_a", "CHOP_TREE", Vector2i(1, 1), 5))
    board.add_job(SimJob.new("job_z", "CHOP_TREE", Vector2i(0, 0), 1))
    var unit: SimUnit = SimUnit.new("unit_001", "Worker", Vector2i.ZERO)

    var ok: bool = true
    ok = _assert(board.has_method("claim_next_open_job_for_unit"), "job board should expose an atomic select-and-claim method for idle units") and ok
    if not ok:
        return false

    var first: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(first != null, "claim_next_open_job_for_unit should return the selected job") and ok
    ok = _assert(first.id == "job_a", "highest priority ties should resolve by stable job id ascending") and ok
    ok = _assert(first.status == "claimed", "claiming should mark the returned job claimed") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_001", "claiming should set claimed_by_unit_id to the claiming unit exactly once") and ok

    var second: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(second != null and second.id == "job_b", "already-claimed jobs should no longer be selectable") and ok
    ok = _assert(first.claimed_by_unit_id == "unit_001", "a later claim should not mutate the previous job claimant") and ok
    return ok

func _test_preclaimed_open_jobs_are_not_selectable_or_claimable() -> bool:
    var board: JobBoard = JobBoard.new()
    var stale: SimJob = SimJob.new("job_a", "CHOP_TREE", Vector2i.ZERO, 10)
    stale.claimed_by_unit_id = "unit_previous"
    board.add_job(stale)
    board.add_job(SimJob.new("job_b", "CHOP_TREE", Vector2i.ZERO, 1))
    var unit: SimUnit = SimUnit.new("unit_002", "Worker", Vector2i.ZERO)

    var ok: bool = true
    ok = _assert(board.has_method("claim_next_open_job_for_unit"), "job board should expose an atomic select-and-claim method for idle units") and ok
    if not ok:
        return false

    var selected: SimJob = board.claim_next_open_job_for_unit(unit)
    ok = _assert(selected != null and selected.id == "job_b", "jobs with an existing claimant should not be selected even if their status is open") and ok
    ok = _assert(stale.claimed_by_unit_id == "unit_previous", "claiming must not overwrite an existing claimed_by_unit_id") and ok
    ok = _assert(not board.claim_job("job_a", "unit_002"), "claim_job should reject jobs with an existing claimant") and ok
    return ok
