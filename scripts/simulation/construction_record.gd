class_name ConstructionRecord
extends RefCounted

var id: String
var type: String
var target_cell: Vector2i
var required_items: Dictionary = {}
var reserved_item_ids: Array[String] = []
var build_job_id: String = ""
var priority: int = 1
var status: String = "planned"
var completed_building_id: String = ""

func _init(pid: String = "", ptype: String = "", ptarget_cell: Vector2i = Vector2i.ZERO, prequired_items: Dictionary = {}, ppriority: int = 1, pstatus: String = "planned", pcompleted_building_id: String = "") -> void:
    id = pid
    type = ptype
    target_cell = ptarget_cell
    required_items = _sorted_dictionary(prequired_items.duplicate(true))
    reserved_item_ids = []
    build_job_id = ""
    priority = ppriority
    status = pstatus
    completed_building_id = pcompleted_building_id

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "type": type,
        "target_cell": [target_cell.x, target_cell.y],
        "required_items": _sorted_dictionary(required_items),
        "reserved_item_ids": _sorted_array(reserved_item_ids),
        "build_job_id": build_job_id,
        "priority": priority,
        "status": status,
        "completed_building_id": completed_building_id,
    }

static func _sorted_dictionary(input: Dictionary) -> Dictionary:
    var output: Dictionary = {}
    var keys: Array = input.keys()
    keys.sort()
    for key in keys:
        var value: Variant = input[key]
        if value is Dictionary:
            output[key] = _sorted_dictionary(value)
        elif value is Array:
            output[key] = _sorted_array(value)
        else:
            output[key] = value
    return output

static func _sorted_array(input: Array) -> Array:
    var output: Array = []
    for value in input:
        if value is Dictionary:
            output.append(_sorted_dictionary(value))
        elif value is Array:
            output.append(_sorted_array(value))
        else:
            output.append(value)
    return output
