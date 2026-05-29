class_name Zone
extends RefCounted

var id: String
var zone_type: String
var cells: Array[Vector2i] = []
var world_cells: Array[Vector3i] = []

func _init(pid: String = "", pzone_type: String = "zone", pcells: Array = []) -> void:
    id = pid
    zone_type = pzone_type
    cells = canonical_cells(pcells)
    world_cells = _default_world_cells(cells)

func contains_cell(cell: Vector2i) -> bool:
    return cells.has(cell)

func contains_world_cell(cell: Vector3i) -> bool:
    return world_cells.has(cell)

func set_world_cells(pworld_cells: Array) -> void:
    world_cells = canonical_world_cells(pworld_cells)

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "zone_type": zone_type,
        "cells": serialized_cells(),
        "world_cells": serialized_world_cells(),
    }

func serialized_cells() -> Array:
    var output: Array = []
    for cell in cells:
        output.append([cell.x, cell.y])
    return output

func serialized_world_cells() -> Array:
    var output: Array = []
    for cell in world_cells:
        output.append([cell.x, cell.y, cell.z])
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

static func canonical_world_cells(input: Array) -> Array[Vector3i]:
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

static func _default_world_cells(projected_cells: Array[Vector2i]) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    for cell in projected_cells:
        output.append(Vector3i(cell.x, 0, cell.y))
    return output
