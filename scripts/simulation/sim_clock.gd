class_name SimClock
extends RefCounted

signal ticked(tick: int)

var tick: int = 0
var paused: bool = false
var speed: int = 1

func set_paused(value: bool) -> void:
    paused = value

func set_speed(value: int) -> void:
    speed = max(1, value)

func advance_steps() -> int:
    if paused:
        return 0
    var advanced: int = 0
    for i in range(speed):
        tick += 1
        advanced += 1
        ticked.emit(tick)
    return advanced
