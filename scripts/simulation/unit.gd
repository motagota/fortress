class_name SimUnit
extends RefCounted

var id: String
var display_name: String
var position: Vector2i
var inventory: Array[String] = []
var allowed_jobs: Array[String] = ["CHOP_TREE", "GATHER_STONE", "GATHER_FOOD", "HAUL_ITEM", "BUILD_CONSTRUCTION"]
var job_type_priorities: Dictionary = {}
var skills: Dictionary = {"labor": 1}
var current_job_id: String = ""
var needs: Dictionary = {"hunger": 0, "energy": 100, "morale": 50}
var state: String = "idle"

func _init(pid: String = "", pname: String = "Unit", pposition: Vector2i = Vector2i.ZERO) -> void:
    id = pid
    display_name = pname
    position = pposition

func distance_to_cell(cell: Vector2i) -> int:
    return abs(position.x - cell.x) + abs(position.y - cell.y)

func set_job_type_priority(job_type: String, priority: int) -> void:
    var normalized_type: String = str(job_type).strip_edges().to_upper()
    if normalized_type == "":
        return
    if priority <= 0:
        job_type_priorities.erase(normalized_type)
        return
    job_type_priorities[normalized_type] = priority

func get_job_type_priority(job_type: String) -> int:
    var normalized_type: String = str(job_type).strip_edges().to_upper()
    return int(job_type_priorities.get(normalized_type, 1))

func _canonical_job_type_priorities() -> Dictionary:
    var result: Dictionary = {}
    var keys: Array = job_type_priorities.keys()
    keys.sort()
    for key in keys:
        result[str(key)] = int(job_type_priorities[key])
    return result

func to_canonical_dict() -> Dictionary:
    var inv: Array = inventory.duplicate()
    inv.sort()
    var allowed: Array = allowed_jobs.duplicate()
    allowed.sort()
    return {
        "id": id,
        "display_name": display_name,
        "position": [position.x, position.y],
        "inventory": inv,
        "allowed_jobs": allowed,
        "job_type_priorities": _canonical_job_type_priorities(),
        "skills": {"labor": skills.get("labor", 0)},
        "current_job_id": current_job_id,
        "needs": {"energy": needs.get("energy", 0), "hunger": needs.get("hunger", 0), "morale": needs.get("morale", 0)},
        "state": state,
    }
