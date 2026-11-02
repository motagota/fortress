class_name SimAnimal
extends RefCounted

# A wild creature roaming the world. Colonists can trap it with a thrown net.
#   state "wild"   - wanders around
#   state "netted" - pinned under a net, waiting for a colonist to collect it

const STATE_WILD := "wild"
const STATE_NETTED := "netted"

var id: String
var species: String
var position: Vector3i
var state: String = STATE_WILD
var netted_by_net_id: String = ""

func _init(pid: String = "", pspecies: String = "rabbit", pposition: Vector3i = Vector3i.ZERO) -> void:
	id = pid
	species = pspecies
	position = pposition

func is_wild() -> bool:
	return state == STATE_WILD

func is_netted() -> bool:
	return state == STATE_NETTED

func to_canonical_dict() -> Dictionary:
	return {
		"id": id,
		"species": species,
		"position": [position.x, position.y, position.z],
		"state": state,
		"netted_by_net_id": netted_by_net_id,
	}
