class_name SimUnit
extends RefCounted

# A colonist. Lives at a single cell address (Vector3i) in the layered world.

var id: String
var display_name: String
var position: Vector3i
var inventory: Array[String] = []
var allowed_jobs: Array[String] = [
    "CHOP_TREE", "GATHER_STONE", "GATHER_FOOD",
    "MINE_WALL", "CHANNEL_FLOOR", "BUILD_STAIR",
    "HAUL_ITEM", "BUILD_CONSTRUCTION", "COOK_MEAL", "CRAFT_ITEM",
    "CATCH_ANIMAL",
]
var job_type_priorities: Dictionary = {}
var skills: Dictionary = {"labor": 1, "mining": 1}
var current_job_id: String = ""
var unreachable_job_ticks: int = 0
var needs: Dictionary = {"hunger": 0, "energy": 100, "morale": 50}
var state: String = "idle"

func _init(pid: String = "", pname: String = "Unit", pposition: Vector3i = Vector3i.ZERO) -> void:
    id = pid
    display_name = pname
    position = pposition

func distance_to(cell: Vector3i) -> int:
    return abs(position.x - cell.x) + abs(position.y - cell.y) + abs(position.z - cell.z)

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
        "position": [position.x, position.y, position.z],
        "inventory": inv,
        "allowed_jobs": allowed,
        "job_type_priorities": _canonical_job_type_priorities(),
        "skills": _canonical_skills(),
        "current_job_id": current_job_id,
        "unreachable_job_ticks": unreachable_job_ticks,
        "needs": {"energy": needs.get("energy", 0), "hunger": needs.get("hunger", 0), "morale": needs.get("morale", 0)},
        "state": state,
    }

func _canonical_skills() -> Dictionary:
    var result: Dictionary = {}
    var keys: Array = skills.keys()
    keys.sort()
    for key in keys:
        result[str(key)] = int(skills[key])
    return result
