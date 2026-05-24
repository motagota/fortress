extends RefCounted

const SimulationScript = preload("res://scripts/simulation/simulation.gd")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func run() -> bool:
    var a = SimulationScript.new()
    var b = SimulationScript.new()
    var c = SimulationScript.new()
    a.initialize_new_game(12345)
    b.initialize_new_game(12345)
    c.initialize_new_game(99999)
    a.queue_command(1, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {})
    b.queue_command(1, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {})
    c.queue_command(1, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {})
    for i in range(12):
        a.step_tick()
        b.step_tick()
        c.step_tick()
    var same_seed_same_hash: bool = a.state_hash() == b.state_hash()
    var different_seed_different_hash: bool = a.state_hash() != c.state_hash()
    return _assert(same_seed_same_hash, "same seed and same commands must replay to identical state_hash") \
        and _assert(different_seed_different_hash, "different seed with same commands must produce different state_hash")
