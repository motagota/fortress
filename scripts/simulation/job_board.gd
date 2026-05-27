class_name JobBoard
extends RefCounted

const SimJobScript := preload("res://scripts/simulation/job.gd")

var jobs: Dictionary = {}

func add_job(job) -> void:
    jobs[job.id] = job

func has_open_job_at(job_type: String, cell: Vector2i) -> bool:
    for id in sorted_job_ids():
        var job = jobs[id]
        if job.type == job_type and job.target_cell == cell and job.status in ["open", "claimed", "in_progress"]:
            return true
    return false

func sorted_job_ids() -> Array:
    var ids: Array = jobs.keys()
    ids.sort()
    return ids

func get_best_open_job_for_unit(unit) -> SimJobScript:
    var best = null
    for id in sorted_job_ids():
        var job = jobs[id]
        if not _is_claimable(job):
            continue
        if not unit.allowed_jobs.has(job.type):
            continue
        if best == null or _is_better_job(job, best, unit):
            best = job
    return best

func _is_better_job(a, b, unit) -> bool:
    var type_priority_a: int = unit.get_job_type_priority(a.type)
    var type_priority_b: int = unit.get_job_type_priority(b.type)
    if type_priority_a != type_priority_b:
        return type_priority_a > type_priority_b
    if a.priority != b.priority:
        return a.priority > b.priority
    var dist_a: int = unit.distance_to_cell(a.target_cell)
    var dist_b: int = unit.distance_to_cell(b.target_cell)
    if dist_a != dist_b:
        return dist_a < dist_b
    return a.id < b.id

func _is_claimable(job) -> bool:
    return job.status == "open" and job.claimed_by_unit_id == ""

func claim_next_open_job_for_unit(unit) -> SimJobScript:
    var job = get_best_open_job_for_unit(unit)
    if job == null:
        return null
    if not claim_job(job.id, unit.id):
        return null
    return job

func claim_job(job_id: String, unit_id: String) -> bool:
    if not jobs.has(job_id):
        return false
    var job = jobs[job_id]
    if not _is_claimable(job):
        return false
    job.status = "claimed"
    job.claimed_by_unit_id = unit_id
    return true

func release_job(job_id: String, unit_id: String = "") -> bool:
    if not jobs.has(job_id):
        return false
    var job = jobs[job_id]
    if unit_id != "" and job.claimed_by_unit_id != unit_id:
        return false
    if not (job.status in ["claimed", "in_progress"]):
        return false
    job.status = "open"
    job.claimed_by_unit_id = ""
    return true

func to_canonical_array() -> Array:
    var arr: Array = []
    for id in sorted_job_ids():
        arr.append(jobs[id].to_canonical_dict())
    return arr
