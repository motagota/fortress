class_name Zone
extends RefCounted

# A set of cell addresses (Vector3i) on a single layer.

var id: String
var zone_type: String
var cells: Array[Vector3i] = []

func _init(pid: String = "", pzone_type: String = "zone", pcells: Array = []) -> void:
    id = pid
    zone_type = pzone_type
    cells = canonical_cells(pcells)

func contains_cell(cell: Vector3i) -> bool:
    return cells.has(cell)

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "zone_type": zone_type,
        "cells": serialized_cells(),
    }

func serialized_cells() -> Array:
    var output: Array = []
    for cell in cells:
        output.append([cell.x, cell.y, cell.z])
    return output

static func canonical_cells(input: Array) -> Array[Vector3i]:
    var unique: Dictionary = {}
    for value in input:
        var cell: Vector3i
        if value is Vector3i:
            cell = value
        elif value is Array and value.size() >= 3:
            cell = Vector3i(int(value[0]), int(value[1]), int(value[2]))
        else:
            continue
        unique["%012d|%012d|%012d" % [cell.x, cell.y, cell.z]] = cell
    var keys: Array = unique.keys()
    keys.sort()
    var output: Array[Vector3i] = []
    for key in keys:
        output.append(unique[key])
    return output
