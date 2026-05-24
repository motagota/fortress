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
    a.initialize_new_game(12345)
    b.initialize_new_game(12345)
    a.queue_command(1, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {})
    b.queue_command(1, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {})
    for i in range(12):
        a.step_tick()
        b.step_tick()
    return _assert(a.state_hash() == b.state_hash(), "same seed and same commands must replay to identical state_hash")
