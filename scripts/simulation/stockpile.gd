class_name Stockpile
extends RefCounted

var id: String
var accepted_item_types: Array[String] = []
var cells: Array[Vector2i] = []

func _init(pid: String = "", paccepted_item_types: Array = [], pcells: Array = []) -> void:
    id = pid
    accepted_item_types = _canonical_item_types(paccepted_item_types)
    cells = _canonical_cells(pcells)

func accepts_item_type(item_type: String) -> bool:
    return accepted_item_types.has(item_type)

func contains_cell(cell: Vector2i) -> bool:
    return cells.has(cell)

func to_canonical_dict() -> Dictionary:
    var serialized_cells: Array = []
    for cell in cells:
        serialized_cells.append([cell.x, cell.y])
    return {
        "id": id,
        "accepted_item_types": accepted_item_types.duplicate(),
        "cells": serialized_cells,
    }

static func _canonical_item_types(input: Array) -> Array[String]:
    var unique: Dictionary = {}
    for value in input:
        var item_type := str(value)
        if item_type != "":
            unique[item_type] = true
    var sorted: Array = unique.keys()
    sorted.sort()
    var output: Array[String] = []
    for item_type in sorted:
        output.append(str(item_type))
    return output

static func _canonical_cells(input: Array) -> Array[Vector2i]:
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
