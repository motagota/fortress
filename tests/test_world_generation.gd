extends RefCounted

const GridWorldScript := preload("res://scripts/simulation/grid_world.gd")
const RngScript := preload("res://scripts/simulation/deterministic_rng.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _generated(seed: int) -> Dictionary:
    var world = GridWorldScript.new(16, 16)
    var resources: Dictionary = {}
    world.generate_ironveil_region(RngScript.new(seed), resources)
    return {"world": world, "resources": resources}

func _count_resources(resources: Dictionary, resource_type: String) -> int:
    var total: int = 0
    for id in resources.keys():
        if str(resources[id].get("type", "")) == resource_type:
            total += 1
    return total

func _snapshot_text(generated: Dictionary) -> String:
    var world = generated["world"]
    return JSON.stringify({
        "profile": world.generation_profile,
        "cells": world.to_canonical_array(),
        "resources": generated["resources"],
    })

func _test_seeded_ironveil_generation_is_deterministic() -> bool:
    var a: Dictionary = _generated(4242)
    var b: Dictionary = _generated(4242)
    var c: Dictionary = _generated(9001)
    return _assert(_snapshot_text(a) == _snapshot_text(b), "same Ironveil worldgen seed must produce identical cells and resources") \
        and _assert(_snapshot_text(a) != _snapshot_text(c), "different Ironveil worldgen seeds should vary cells or resources")

func _test_ironveil_layer_projection_shape() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var ok: bool = true
    ok = _assert(world.generation_profile == "ironveil_layered_v1", "worldgen profile should name the Ironveil layered generator") and ok
    ok = _assert(world.get_cell(Vector2i(0, 12)).depth == -3, "row 12 should remain projected depth -3") and ok
    ok = _assert(world.get_cell(Vector2i(0, 12)).terrain == "dirt", "projected layer 4 should remain dirt for current mining rules") and ok
    ok = _assert(world.get_cell(Vector2i(0, 13)).depth == -4, "row 13 should remain projected depth -4") and ok
    ok = _assert(world.get_cell(Vector2i(0, 13)).terrain == "solid_rock", "projected layer 5 should be hard solid rock") and ok
    ok = _assert(world.get_cell(Vector2i(4, 8)).terrain == "rock", "projected layer 3 should introduce shallow mineable rock") and ok
    return ok

func _test_resource_constraints_follow_ironveil_surface_rules() -> bool:
    var generated: Dictionary = _generated(4242)
    var world = generated["world"]
    var resources: Dictionary = generated["resources"]
    var ok: bool = true
    ok = _assert(_count_resources(resources, "tree") > 0, "Ironveil worldgen should place tree resources") and ok
    ok = _assert(_count_resources(resources, "berry") > 0, "Ironveil worldgen should place berry resources") and ok
    ok = _assert(_count_resources(resources, "stone") > 0, "Ironveil worldgen should place loose stone resources") and ok
    for id in resources.keys():
        var resource: Dictionary = resources[id]
        var pos: Array = resource["position"]
        var cell = world.get_cell(Vector2i(int(pos[0]), int(pos[1])))
        ok = _assert(cell != null and cell.resource_id == id, "resource index and cell resource id must agree for " + str(id)) and ok
        ok = _assert(str(resource.get("worldgen_profile", "")) == "ironveil_layered_v1", "generated resources should carry their worldgen profile") and ok
        if resource["type"] in ["tree", "berry"]:
            ok = _assert(int(cell.depth) == 0, "trees and berries must stay on the surface projection") and ok
        if resource["type"] == "stone":
            ok = _assert(int(cell.depth) >= -2 and int(cell.depth) <= 0, "loose stone should stay in surface through shallow stone projection layers") and ok
        ok = _assert(not (int(pos[0]) <= 5 and int(pos[1]) <= 3), "starting workyard should remain clear of generated resources") and ok
    return ok

func run() -> bool:
    return _test_seeded_ironveil_generation_is_deterministic() \
        and _test_ironveil_layer_projection_shape() \
        and _test_resource_constraints_follow_ironveil_surface_rules()
