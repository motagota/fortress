class_name SimJob
extends RefCounted

var id: String
var type: String
var target_cell: Vector2i
var required_skill: String = "labor"
var required_items: Dictionary = {}
var produced_items: Dictionary = {}
var priority: int = 1
var status: String = "open"
var claimed_by_unit_id: String = ""
var work_remaining_ticks: int = 3

func _init(pid: String = "", ptype: String = "CHOP_TREE", ptarget: Vector2i = Vector2i.ZERO, ppriority: int = 1) -> void:
    id = pid
    type = ptype
    target_cell = ptarget
    priority = ppriority
    match type:
        "CHOP_TREE":
            produced_items = {"wood": 1}
            work_remaining_ticks = 3
        "GATHER_STONE":
            produced_items = {"stone": 1}
            work_remaining_ticks = 4
        "GATHER_FOOD":
            produced_items = {"food": 1}
            work_remaining_ticks = 2

func advance_work_tick() -> bool:
    if status == "complete":
        work_remaining_ticks = max(0, work_remaining_ticks)
        return true
    if status == "claimed":
        status = "in_progress"
    if status != "in_progress":
        return false
    if work_remaining_ticks > 0:
        work_remaining_ticks -= 1
    work_remaining_ticks = max(0, work_remaining_ticks)
    if work_remaining_ticks == 0:
        status = "complete"
        return true
    return false

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "type": type,
        "target_cell": [target_cell.x, target_cell.y],
        "required_skill": required_skill,
        "required_items": required_items,
        "produced_items": produced_items,
        "priority": priority,
        "status": status,
        "claimed_by_unit_id": claimed_by_unit_id,
        "work_remaining_ticks": work_remaining_ticks,
    }
