extends RefCounted

const Simulation := preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var a: Simulation = Simulation.new()
    var b: Simulation = Simulation.new()
    var c: Simulation = Simulation.new()
    a.initialize_new_game(111)
    b.initialize_new_game(111)
    c.initialize_new_game(222)
    var same_seed_same_hash: bool = a.state_hash() == b.state_hash()
    var different_seed_different_hash: bool = a.state_hash() != c.state_hash()
    return _assert(same_seed_same_hash, "same seed must create same forest") and _assert(different_seed_different_hash, "different seed should create a different forest/resource layout")
