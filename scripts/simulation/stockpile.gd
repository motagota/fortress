class_name Stockpile
extends Zone

var accepted_item_types: Array[String] = []
var storage_mode: String = "both"

func _init(pid: String = "", paccepted_item_types: Array = [], pcells: Array = [], pstorage_mode: String = "both") -> void:
    super(pid, "stockpile", pcells)
    accepted_item_types = _canonical_item_types(paccepted_item_types)
    storage_mode = canonical_storage_mode(pstorage_mode)

func accepts_item_type(item_type: String) -> bool:
    return accepted_item_types.has(item_type)

func can_store_items() -> bool:
    return storage_mode in ["storage", "both"]

func can_supply_items() -> bool:
    return storage_mode in ["supply", "both"]

func set_storage_mode(mode: String) -> bool:
    var canonical: String = canonical_storage_mode(mode)
    if canonical == "":
        return false
    storage_mode = canonical
    return true

func to_canonical_dict() -> Dictionary:
    return {
        "id": id,
        "zone_type": zone_type,
        "storage_mode": storage_mode,
        "accepted_item_types": accepted_item_types.duplicate(),
        "cells": serialized_cells(),
    }

static func canonical_storage_mode(mode: String) -> String:
    match str(mode):
        "storage", "storage_only":
            return "storage"
        "supply", "supply_only":
            return "supply"
        "both":
            return "both"
    return ""

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
