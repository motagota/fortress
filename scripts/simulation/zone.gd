class_name Zone
extends RefCounted

var id: String
var zone_type: String
var cells: Array[Vector2i] = []

func _init(pid: String = "", pzone_type: String = "zone", pcells: Array = []) -> void:
    id = pid
    zone_type = pzone_type
    cells = canonical_cells(pcells)

func contains_cell(cell: Vector2i) -> bool:
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
        output.append([cell.x, cell.y])
    return output

static func canonical_cells(input: Array) -> Array[Vector2i]:
    var unique: Dictionary = {}
    for value in input:
        var cell: Vector2i
        if value is Vector2i:
            cell = value
        elif value is Array and value.size() >= 2:
            cell = Vector2i(int(value[0]), int(value[1]))
        else:
            continue
        unique["%012d|%012d" % [cell.x, cell.y]] = cell
    var keys: Array = unique.keys()
    keys.sort()
    var output: Array[Vector2i] = []
    for key in keys:
        output.append(unique[key])
    return output
