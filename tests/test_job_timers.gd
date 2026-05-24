extends RefCounted

const SimJobScript = preload("res://scripts/simulation/job.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var ok: bool = true
    ok = _test_claimed_job_advances_tick_by_tick_until_work_reaches_zero() and ok
    return ok

func _test_claimed_job_advances_tick_by_tick_until_work_reaches_zero() -> bool:
    var job = SimJobScript.new("job_001", "GATHER_FOOD", Vector2i.ZERO, 1)
    job.status = "claimed"
    job.claimed_by_unit_id = "unit_001"

    var ok: bool = true
    ok = _assert(job.work_remaining_ticks == 2, "GATHER_FOOD jobs should start with a two tick work timer") and ok
    ok = _assert(job.has_method("advance_work_tick"), "jobs should expose a per-tick work advancement method") and ok
    if not ok:
        return false

    var completed_after_one_tick: bool = job.advance_work_tick()
    ok = _assert(not completed_after_one_tick, "job should not complete after fewer than the required work ticks") and ok
    ok = _assert(job.status == "in_progress", "claimed jobs should transition to in_progress when work begins") and ok
    ok = _assert(job.work_remaining_ticks == 1, "first work tick should decrement remaining work by exactly one") and ok

    var completed_after_two_ticks: bool = job.advance_work_tick()
    ok = _assert(completed_after_two_ticks, "job should report completion exactly when remaining work reaches zero") and ok
    ok = _assert(job.status == "complete", "job should use the existing complete terminal lifecycle status") and ok
    ok = _assert(job.work_remaining_ticks == 0, "completed jobs should have zero remaining work") and ok

    var completed_after_extra_tick: bool = job.advance_work_tick()
    ok = _assert(completed_after_extra_tick, "completed jobs should remain complete on later ticks") and ok
    ok = _assert(job.work_remaining_ticks == 0, "work timers should never decrement below zero") and ok
    return ok
