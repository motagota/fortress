class_name SimItem
extends RefCounted

var id: String
var item_type: String
var quantity: int
var position: Vector2i
var holder_unit_id: String = ""
var stockpile_id: String = ""
var reserved_by_job_id: String = ""

func _init(pid: String = "", ptype: String = "wood", pquantity: int = 1, pposition: Vector2i = Vector2i.ZERO) -> void:
    id = pid
    item_type = ptype
    quantity = pquantity
    position = pposition

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "item_type": item_type,
        "quantity": quantity,
        "position": [position.x, position.y],
        "holder_unit_id": holder_unit_id,
        "stockpile_id": stockpile_id,
        "reserved_by_job_id": reserved_by_job_id,
    }
