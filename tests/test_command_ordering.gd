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
    a.initialize_new_game(777)
    b.initialize_new_game(777)
    var ca: Dictionary = a.make_command(2, "player_001", "DESIGNATE_CHOP", Vector2i(1, 1), {}, "cmd_000002")
    var cb: Dictionary = a.make_command(2, "player_001", "DESIGNATE_CHOP", Vector2i(2, 3), {}, "cmd_000001")
    a.queue_existing_command(ca)
    a.queue_existing_command(cb)
    b.queue_existing_command(cb.duplicate(true))
    b.queue_existing_command(ca.duplicate(true))
    for i in range(3):
        a.step_tick()
        b.step_tick()
    return _assert(a.state_hash() == b.state_hash(), "same-tick commands must be applied in canonical command_id order")
