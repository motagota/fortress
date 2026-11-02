class_name SimNet
extends RefCounted

# A net fired by a colonist. It flies from `origin` toward its target animal
# over `flight_ticks_total` ticks (homing on wherever the animal is), then lands
# on the animal and pins it.
#   state "flying" - in the air
#   state "landed" - draped over the caught animal

const STATE_FLYING := "flying"
const STATE_LANDED := "landed"

var id: String
var shooter_unit_id: String
var job_id: String
var target_animal_id: String
var origin: Vector3i
var position: Vector3i
var state: String = STATE_FLYING
var flight_ticks_done: int = 0
var flight_ticks_total: int = 1

func _init(pid: String = "", pshooter: String = "", pjob: String = "", ptarget: String = "", porigin: Vector3i = Vector3i.ZERO, ptotal: int = 1) -> void:
	id = pid
	shooter_unit_id = pshooter
	job_id = pjob
	target_animal_id = ptarget
	origin = porigin
	position = porigin
	flight_ticks_total = max(1, ptotal)

func is_flying() -> bool:
	return state == STATE_FLYING

# 0.0 at launch, 1.0 on impact.
func flight_progress(extra_fraction: float = 0.0) -> float:
	if state != STATE_FLYING:
		return 1.0
	return clampf((float(flight_ticks_done) + extra_fraction) / float(flight_ticks_total), 0.0, 1.0)

func to_canonical_dict() -> Dictionary:
	return {
		"id": id,
		"shooter_unit_id": shooter_unit_id,
		"job_id": job_id,
		"target_animal_id": target_animal_id,
		"origin": [origin.x, origin.y, origin.z],
		"position": [position.x, position.y, position.z],
		"state": state,
		"flight_ticks_done": flight_ticks_done,
		"flight_ticks_total": flight_ticks_total,
	}
