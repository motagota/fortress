class_name DeterministicRng
extends RefCounted

const MODULUS := 4294967296
const MULTIPLIER := 1664525
const INCREMENT := 1013904223

var _state: int = 1

func _init(seed_value: int = 1) -> void:
    set_state(seed_value)

func set_state(value: int) -> void:
    _state = int(value) & 0xffffffff
    if _state == 0:
        _state = 1

func get_state() -> int:
    return _state

func next_u32() -> int:
    _state = int((MULTIPLIER * _state + INCREMENT) & 0xffffffff)
    return _state

func range_i(min_value: int, max_value: int) -> int:
    if max_value < min_value:
        return min_value
    var span: int = max_value - min_value + 1
    return min_value + int(next_u32() % span)

func chance(parts_per_thousand: int) -> bool:
    return int(next_u32() % 1000) < parts_per_thousand

func to_canonical_dict() -> Dictionary:
    return {"state": _state}
