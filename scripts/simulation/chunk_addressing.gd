class_name ChunkAddressing
extends RefCounted

const DEFAULT_CHUNK_SIZE := 16

static func floor_div(value: int, divisor: int) -> int:
    if divisor <= 0:
        return 0
    return int(floor(float(value) / float(divisor)))

static func local_coord(value: int, chunk: int, chunk_size: int = DEFAULT_CHUNK_SIZE) -> int:
    return value - chunk * chunk_size

static func is_valid_local_cell(local_cell: Vector3i, chunk_size: int = DEFAULT_CHUNK_SIZE) -> bool:
    if chunk_size <= 0:
        return false
    return local_cell.x >= 0 and local_cell.y >= 0 and local_cell.z >= 0 \
        and local_cell.x < chunk_size and local_cell.y < chunk_size and local_cell.z < chunk_size

static func world_to_chunk(world_cell: Vector3i, chunk_size: int = DEFAULT_CHUNK_SIZE) -> Dictionary:
    if chunk_size <= 0:
        return {
            "valid": false,
            "reason": "invalid_chunk_size",
            "chunk_size": chunk_size,
        }
    var chunk_cell := Vector3i(
        floor_div(world_cell.x, chunk_size),
        floor_div(world_cell.y, chunk_size),
        floor_div(world_cell.z, chunk_size)
    )
    var local_cell := Vector3i(
        local_coord(world_cell.x, chunk_cell.x, chunk_size),
        local_coord(world_cell.y, chunk_cell.y, chunk_size),
        local_coord(world_cell.z, chunk_cell.z, chunk_size)
    )
    return {
        "valid": true,
        "chunk_size": chunk_size,
        "world_cell": vector3i_to_array(world_cell),
        "chunk_cell": vector3i_to_array(chunk_cell),
        "local_cell": vector3i_to_array(local_cell),
    }

static func chunk_local_to_world(chunk_cell: Vector3i, local_cell: Vector3i, chunk_size: int = DEFAULT_CHUNK_SIZE) -> Dictionary:
    if chunk_size <= 0:
        return {
            "valid": false,
            "reason": "invalid_chunk_size",
            "chunk_size": chunk_size,
        }
    if not is_valid_local_cell(local_cell, chunk_size):
        return {
            "valid": false,
            "reason": "local_cell_out_of_bounds",
            "chunk_size": chunk_size,
            "chunk_cell": vector3i_to_array(chunk_cell),
            "local_cell": vector3i_to_array(local_cell),
        }
    var world_cell := Vector3i(
        chunk_cell.x * chunk_size + local_cell.x,
        chunk_cell.y * chunk_size + local_cell.y,
        chunk_cell.z * chunk_size + local_cell.z
    )
    return {
        "valid": true,
        "chunk_size": chunk_size,
        "world_cell": vector3i_to_array(world_cell),
        "chunk_cell": vector3i_to_array(chunk_cell),
        "local_cell": vector3i_to_array(local_cell),
    }

static func vector3i_to_array(value: Vector3i) -> Array:
    return [value.x, value.y, value.z]

static func array_to_vector3i(value: Array) -> Vector3i:
    if value.size() < 3:
        return Vector3i.ZERO
    return Vector3i(int(value[0]), int(value[1]), int(value[2]))
