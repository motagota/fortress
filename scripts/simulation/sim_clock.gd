class_name SimClock
extends RefCounted

signal ticked(tick: int)

var tick: int = 0
var paused: bool = false
var speed: int = 1
var base_tick_interval_seconds: float = 0.1  # 10 ticks/second
var accumulated_seconds: float = 0.0

func set_paused(value: bool) -> void:
    paused = value

func set_speed(value: int) -> void:
    speed = max(1, value)

func advance_steps(delta_seconds: float = -1.0) -> int:
    if paused:
        return 0
    var frame_delta: float = base_tick_interval_seconds if delta_seconds < 0.0 else delta_seconds
    accumulated_seconds += frame_delta * float(speed)
    var advanced: int = 0
    while accumulated_seconds + 0.000001 >= base_tick_interval_seconds:
        accumulated_seconds -= base_tick_interval_seconds
        tick += 1
        advanced += 1
        ticked.emit(tick)
    return advanced
