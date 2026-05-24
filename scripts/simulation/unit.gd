class_name SimUnit
extends RefCounted

var id: String
var display_name: String
var position: Vector2i
var inventory: Array[String] = []
var allowed_jobs: Array[String] = ["CHOP_TREE", "GATHER_STONE", "GATHER_FOOD"]
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
        "skills": {"labor": skills.get("labor", 0)},
        "current_job_id": current_job_id,
        "needs": {"energy": needs.get("energy", 0), "hunger": needs.get("hunger", 0), "morale": needs.get("morale", 0)},
        "state": state,
    }
