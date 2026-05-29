class_name SimItem
extends RefCounted

var id: String
var item_type: String
var quantity: int
var position: Vector2i
var world_cell: Vector3i
var holder_unit_id: String = ""
var stockpile_id: String = ""
var reserved_by_job_id: String = ""

func _init(pid: String = "", ptype: String = "wood", pquantity: int = 1, pposition: Vector2i = Vector2i.ZERO) -> void:
    id = pid
    item_type = ptype
    quantity = pquantity
    position = pposition
    world_cell = Vector3i(pposition.x, 0, pposition.y)

func set_projected_position(projected_cell: Vector2i, pworld_cell: Vector3i) -> void:
    position = projected_cell
    world_cell = pworld_cell

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "item_type": item_type,
        "quantity": quantity,
        "position": [position.x, position.y],
        "world_cell": [world_cell.x, world_cell.y, world_cell.z],
        "holder_unit_id": holder_unit_id,
        "stockpile_id": stockpile_id,
        "reserved_by_job_id": reserved_by_job_id,
    }
