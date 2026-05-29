extends Node3D

# Presentation-only renderer. It reads simulation state and creates simple meshes;
# it must never mutate simulation state or feed camera/scene-tree data back into sim.

const UnitViewScene := preload("res://scenes/units/UnitView.tscn")
const ChunkedWorldStoreScript := preload("res://scripts/simulation/chunked_world_store.gd")
const INVALID_CELL := Vector2i(-1, -1)
const CELL_HEIGHT_FACTOR := 1.0
const MIN_LAYER_DEPTH := -15
const MAX_LAYER_DEPTH := 0
const RENDERED_CHUNK_SIZE := 16

@onready var chunk_volume_root: Node3D = get_node_or_null("ChunkVolume") as Node3D
@onready var resources_root: Node3D = $Resources
@onready var buildings_root: Node3D = get_node_or_null("Buildings") as Node3D
@onready var items_root: Node3D = get_node_or_null("Items") as Node3D
@onready var stockpiles_root: Node3D = get_node_or_null("Stockpiles") as Node3D
@onready var stockpile_preview_root: Node3D = get_node_or_null("StockpilePreview") as Node3D
@onready var stockpile_resize_root: Node3D = get_node_or_null("StockpileResizeHandles") as Node3D
@onready var designations_root: Node3D = get_node_or_null("Designations") as Node3D
@onready var hover_root: Node3D = get_node_or_null("Hover") as Node3D
@onready var units_root: Node3D = $Units
@onready var debug_labels_root: Node3D = $DebugLabels

var tile_size: float = 1.0
@export var show_debug_labels: bool = true
var selected_stockpile_id: String = ""
var layer_cutaway_depth: int = 0
var hover_cell: Vector2i = INVALID_CELL
var hover_valid: bool = true
var _cell_surface_y: Dictionary = {}
var _cell_surface_height: Dictionary = {}
var _cell_render_z: Dictionary = {}

func _ready() -> void:
    pass

func sync_from_simulation(simulation: Simulation) -> void:
    _resolve_child_roots()
    var snapshot: Dictionary = simulation.canonical_snapshot()
    _cache_cell_surface_heights(snapshot)
    _sync_chunk_volume(simulation)
    _sync_resources(snapshot)
    _sync_buildings(snapshot)
    _sync_stockpiles(snapshot)
    _sync_stockpile_resize_handles(snapshot)
    _sync_items(snapshot)
    _sync_designations(snapshot)
    _sync_units(snapshot)
    _sync_hover_cell()

func set_stockpile_preview_cells(cells: Array) -> void:
    _resolve_child_roots()
    _sync_stockpile_cells(stockpile_preview_root, "StockpilePreview", cells, Color(0.25, 0.75, 1.0, 0.34), 0.075)

func set_kitchen_preview_cells(cells: Array, valid: bool = true) -> void:
    _resolve_child_roots()
    var color: Color = Color(0.95, 0.58, 0.18, 0.5) if valid else Color(0.95, 0.18, 0.12, 0.5)
    _sync_stockpile_cells(stockpile_preview_root, "KitchenPreview", cells, color, 0.11)

func set_selected_stockpile_id(stockpile_id: String) -> void:
    selected_stockpile_id = stockpile_id

func set_layer_cutaway_depth(depth: int) -> void:
    layer_cutaway_depth = clampi(depth, MIN_LAYER_DEPTH, MAX_LAYER_DEPTH)

func adjust_layer_cutaway(delta: int) -> int:
    set_layer_cutaway_depth(layer_cutaway_depth + delta)
    return layer_cutaway_depth

func set_hover_cell(cell: Vector2i, valid: bool = true) -> void:
    hover_cell = cell
    hover_valid = valid
    _sync_hover_cell()

func world_position_to_cell(world_position: Vector3, grid_world) -> Vector2i:
    if grid_world == null or tile_size <= 0.0:
        return INVALID_CELL
    var display_cell := Vector2i(int(floor(world_position.x / tile_size)), int(floor(world_position.z / tile_size)))
    if display_cell.x < 0 or display_cell.y < 0:
        return INVALID_CELL
    if layer_cutaway_depth == 0:
        if display_cell.x >= int(grid_world.width) or display_cell.y >= int(grid_world.height):
            return INVALID_CELL
        var direct_cell = grid_world.get_cell(display_cell)
        if direct_cell != null and _is_visible_pick_cell(direct_cell):
            return display_cell
        return _top_visible_cell_at_display_cell(display_cell, grid_world)
    return _top_visible_cell_at_display_cell(display_cell, grid_world)

func ray_to_grid_cell(ray_origin: Vector3, ray_direction: Vector3, grid_world) -> Vector2i:
    if absf(ray_direction.y) < 0.00001:
        return INVALID_CELL
    if grid_world == null or tile_size <= 0.0:
        return INVALID_CELL
    if layer_cutaway_depth == 0:
        return _ray_to_surface_grid_cell(ray_origin, ray_direction, grid_world)
    var best_cell: Vector2i = INVALID_CELL
    var best_distance: float = INF
    for z in range(int(grid_world.height)):
        for x in range(int(grid_world.width)):
            var cell := Vector2i(x, z)
            var sim_cell = grid_world.get_cell(cell)
            if sim_cell == null or not _is_visible_pick_cell(sim_cell):
                continue
            var surface_y: float = _surface_y_for_depth(int(sim_cell.depth))
            var distance_to_plane: float = (surface_y - ray_origin.y) / ray_direction.y
            if distance_to_plane < 0.0 or distance_to_plane >= best_distance:
                continue
            var hit_position: Vector3 = ray_origin + (ray_direction * distance_to_plane)
            var display_cell := Vector2i(int(floor(hit_position.x / tile_size)), int(floor(hit_position.z / tile_size)))
            if display_cell.x == cell.x and display_cell.y == _render_z_for_grid_cell(grid_world, cell):
                best_cell = cell
                best_distance = distance_to_plane
    return best_cell

func ray_to_world_cell(ray_origin: Vector3, ray_direction: Vector3, grid_world) -> Vector3i:
    var projected_cell: Vector2i = ray_to_grid_cell(ray_origin, ray_direction, grid_world)
    if projected_cell == INVALID_CELL or grid_world == null or not grid_world.has_method("get_storage_address_for_projected_cell"):
        return Vector3i(-2147483648, -2147483648, -2147483648)
    var address: Dictionary = grid_world.get_storage_address_for_projected_cell(projected_cell)
    if not bool(address.get("valid", false)):
        return Vector3i(-2147483648, -2147483648, -2147483648)
    return _array_to_vector3i(address.get("world_cell", []))

func _ray_to_surface_grid_cell(ray_origin: Vector3, ray_direction: Vector3, grid_world) -> Vector2i:
    var best_cell: Vector2i = INVALID_CELL
    var best_distance: float = INF
    for z in range(int(grid_world.height)):
        for x in range(int(grid_world.width)):
            var cell := Vector2i(x, z)
            var surface_y: float = 0.0
            if grid_world.has_method("get_surface_height"):
                surface_y = float(grid_world.get_surface_height(cell)) * _cell_height()
            var distance_to_plane: float = (surface_y - ray_origin.y) / ray_direction.y
            if distance_to_plane < 0.0 or distance_to_plane >= best_distance:
                continue
            var hit_position: Vector3 = ray_origin + (ray_direction * distance_to_plane)
            var display_cell := Vector2i(int(floor(hit_position.x / tile_size)), int(floor(hit_position.z / tile_size)))
            if display_cell == cell:
                var sim_cell = grid_world.get_cell(cell)
                best_cell = cell if sim_cell != null and _is_visible_pick_cell(sim_cell) else _top_visible_cell_at_display_cell(cell, grid_world)
                best_distance = distance_to_plane
    return best_cell

func _resolve_child_roots() -> void:
    # Headless tests can instantiate Main.tscn and call sync_from_simulation()
    # before the scene enters the tree, so @onready variables may not have run yet.
    if chunk_volume_root == null:
        chunk_volume_root = get_node_or_null("ChunkVolume") as Node3D
    if chunk_volume_root == null:
        chunk_volume_root = Node3D.new()
        chunk_volume_root.name = "ChunkVolume"
        add_child(chunk_volume_root)
    if resources_root == null:
        resources_root = get_node_or_null("Resources") as Node3D
    if resources_root == null:
        resources_root = Node3D.new()
        resources_root.name = "Resources"
        add_child(resources_root)
    if buildings_root == null:
        buildings_root = get_node_or_null("Buildings") as Node3D
    if buildings_root == null:
        buildings_root = Node3D.new()
        buildings_root.name = "Buildings"
        add_child(buildings_root)
    if items_root == null:
        items_root = get_node_or_null("Items") as Node3D
    if items_root == null:
        items_root = Node3D.new()
        items_root.name = "Items"
        add_child(items_root)
    if stockpiles_root == null:
        stockpiles_root = get_node_or_null("Stockpiles") as Node3D
    if stockpiles_root == null:
        stockpiles_root = Node3D.new()
        stockpiles_root.name = "Stockpiles"
        add_child(stockpiles_root)
    if stockpile_preview_root == null:
        stockpile_preview_root = get_node_or_null("StockpilePreview") as Node3D
    if stockpile_preview_root == null:
        stockpile_preview_root = Node3D.new()
        stockpile_preview_root.name = "StockpilePreview"
        add_child(stockpile_preview_root)
    if stockpile_resize_root == null:
        stockpile_resize_root = get_node_or_null("StockpileResizeHandles") as Node3D
    if stockpile_resize_root == null:
        stockpile_resize_root = Node3D.new()
        stockpile_resize_root.name = "StockpileResizeHandles"
        add_child(stockpile_resize_root)
    if designations_root == null:
        designations_root = get_node_or_null("Designations") as Node3D
    if designations_root == null:
        designations_root = Node3D.new()
        designations_root.name = "Designations"
        add_child(designations_root)
    if hover_root == null:
        hover_root = get_node_or_null("Hover") as Node3D
    if hover_root == null:
        hover_root = Node3D.new()
        hover_root.name = "Hover"
        add_child(hover_root)
    if units_root == null:
        units_root = get_node_or_null("Units") as Node3D
    if units_root == null:
        units_root = Node3D.new()
        units_root.name = "Units"
        add_child(units_root)
    if debug_labels_root == null:
        debug_labels_root = get_node_or_null("DebugLabels") as Node3D
    if debug_labels_root == null:
        debug_labels_root = Node3D.new()
        debug_labels_root.name = "DebugLabels"
        add_child(debug_labels_root)

func _sync_chunk_volume(simulation: Simulation) -> void:
    if chunk_volume_root == null or simulation == null or simulation.world == null:
        return
    var store = ChunkedWorldStoreScript.new(RENDERED_CHUNK_SIZE)
    var report: Dictionary = store.import_playable_chunk_volume(simulation.world)
    if not bool(report.get("valid", false)):
        _remove_unseen_children(chunk_volume_root, {})
        return
    chunk_volume_root.visible = true
    var visible_cells: Dictionary = _visible_solid_chunk_cells_from_store(store)
    var mesh_data_by_material: Dictionary = _build_greedy_chunk_mesh_data(visible_cells)
    _sync_chunk_mesh_nodes(mesh_data_by_material)

func _visible_solid_chunk_cells_from_store(store) -> Dictionary:
    var visible_cells: Dictionary = {}
    for stored in store.to_canonical_array():
        var world_cell := _array_to_vector3i(stored.get("world_cell", []))
        var source: Dictionary = stored.get("source", {})
        var local_cell := _array_to_vector3i(source.get("volume_local_cell", stored.get("local_cell", [])))
        var payload: Dictionary = stored.get("payload", {})
        if not _chunk_local_cell_visible_by_cutaway(local_cell) or not _chunk_payload_is_solid(payload):
            continue
        var render_cell := Vector3i(local_cell.x, local_cell.y + int(payload.get("surface_height", 0)), local_cell.z)
        visible_cells[_chunk_local_key(render_cell)] = {
            "local_cell": local_cell,
            "render_cell": render_cell,
            "payload": payload,
            "world_y": world_cell.y,
        }
    return visible_cells

func _sync_chunk_mesh_nodes(mesh_data_by_material: Dictionary) -> void:
    if chunk_volume_root == null:
        return
    var seen: Dictionary = {}
    var material_keys: Array = mesh_data_by_material.keys()
    material_keys.sort()
    for material_key in material_keys:
        var data: Dictionary = mesh_data_by_material[material_key]
        var node_name: String = _chunk_mesh_node_name(str(material_key))
        seen[node_name] = true
        var node: MeshInstance3D = chunk_volume_root.get_node_or_null(node_name) as MeshInstance3D
        if node == null:
            node = MeshInstance3D.new()
            node.name = node_name
            chunk_volume_root.add_child(node)
        node.mesh = _make_chunk_array_mesh(data)
        node.material_override = _make_chunk_volume_material(data.get("color", Color.WHITE))
        node.position = Vector3.ZERO
        node.visible = true
    _remove_unseen_children(chunk_volume_root, seen)

func _make_chunk_array_mesh(data: Dictionary) -> ArrayMesh:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = data.get("vertices", PackedVector3Array())
    arrays[Mesh.ARRAY_NORMAL] = data.get("normals", PackedVector3Array())
    arrays[Mesh.ARRAY_COLOR] = data.get("colors", PackedColorArray())
    arrays[Mesh.ARRAY_INDEX] = data.get("indices", PackedInt32Array())
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _new_colored_mesh_data() -> Dictionary:
    return {
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "colors": PackedColorArray(),
        "indices": PackedInt32Array(),
    }

func _sync_colored_mesh_node(root: Node3D, node_name: String, mesh_data: Dictionary, material: Material) -> void:
    if root == null:
        return
    var vertices: PackedVector3Array = mesh_data.get("vertices", PackedVector3Array())
    if vertices.is_empty():
        _remove_unseen_children(root, {})
        return
    var seen: Dictionary = {node_name: true}
    var node: MeshInstance3D = root.get_node_or_null(node_name) as MeshInstance3D
    if node == null:
        node = MeshInstance3D.new()
        node.name = node_name
        root.add_child(node)
    node.mesh = _make_chunk_array_mesh(mesh_data)
    node.material_override = material
    node.visible = true
    _remove_unseen_children(root, seen)

func _append_box(mesh_data: Dictionary, center: Vector3, size: Vector3, color: Color) -> void:
    var half := size * 0.5
    var x0: float = center.x - half.x
    var x1: float = center.x + half.x
    var y0: float = center.y - half.y
    var y1: float = center.y + half.y
    var z0: float = center.z - half.z
    var z1: float = center.z + half.z
    _append_colored_quad(mesh_data, [Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1)], Vector3.RIGHT, color)
    _append_colored_quad(mesh_data, [Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0)], Vector3.LEFT, color)
    _append_colored_quad(mesh_data, [Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)], Vector3.UP, color)
    _append_colored_quad(mesh_data, [Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1)], Vector3.DOWN, color)
    _append_colored_quad(mesh_data, [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)], Vector3.BACK, color)
    _append_colored_quad(mesh_data, [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)], Vector3.FORWARD, color)

func _append_colored_quad(mesh_data: Dictionary, quad: Array, normal: Vector3, color: Color) -> void:
    var vertices: PackedVector3Array = mesh_data["vertices"]
    var normals: PackedVector3Array = mesh_data["normals"]
    var colors: PackedColorArray = mesh_data["colors"]
    var indices: PackedInt32Array = mesh_data["indices"]
    var start_index: int = vertices.size()
    for vertex in quad:
        vertices.append(vertex)
        normals.append(normal)
        colors.append(color)
    indices.append(start_index)
    indices.append(start_index + 1)
    indices.append(start_index + 2)
    indices.append(start_index)
    indices.append(start_index + 2)
    indices.append(start_index + 3)

func _sync_resources(snapshot: Dictionary) -> void:
    if resources_root == null:
        return
    var seen: Dictionary = {}
    for resource in snapshot["resources"]:
        var visual_name: String = _resource_node_name(resource)
        seen[visual_name] = true
        var existing: Node = resources_root.get_node_or_null(visual_name)
        if existing != null and existing is MeshInstance3D:
            resources_root.remove_child(existing)
            existing.queue_free()
            existing = null
        var node: Node3D = existing as Node3D
        if node == null:
            node = Node3D.new()
            node.name = visual_name
            resources_root.add_child(node)
        _update_resource_node(node, resource)
        node.visible = node.visible and _resource_visible_by_cutaway(resource)
        _sync_debug_label(str(resource["type"]), node.position + Vector3(0.0, _resource_height(resource) + 0.25, 0.0), str(resource["id"]), node.visible)
    _remove_unseen_children(resources_root, seen)
    _remove_unseen_debug_labels(snapshot["resources"])

func _sync_items(snapshot: Dictionary) -> void:
    if items_root == null:
        return
    var mesh_data: Dictionary = _new_colored_mesh_data()
    for item in snapshot["items"]:
        var side: float = 0.36
        var item_world_cell: Vector3i = _world_cell_from_snapshot(item, "world_cell", "position")
        if item.get("holder_unit_id", "") != "" or not _world_cell_visible_by_cutaway(item_world_cell):
            continue
        _append_box(mesh_data, _render_position_for_world_cell(item_world_cell, side * 0.5), Vector3(side, side, side), _item_color(str(item.get("item_type", "item"))))
    _sync_colored_mesh_node(items_root, "ItemCollectionMesh", mesh_data, _make_vertex_color_material(false))

func _sync_buildings(snapshot: Dictionary) -> void:
    if buildings_root == null:
        return
    var seen: Dictionary = {}
    for construction in snapshot.get("constructions", []):
        if str(construction.get("status", "")) == "cancelled":
            continue
        var building_id: String = str(construction.get("completed_building_id", ""))
        var node_name: String = "Building_" + building_id if building_id != "" else "BuildingGhost_" + str(construction.get("id", ""))
        seen[node_name] = true
        var node: MeshInstance3D = buildings_root.get_node_or_null(node_name) as MeshInstance3D
        if node == null:
            node = MeshInstance3D.new()
            node.name = node_name
            node.mesh = BoxMesh.new()
            buildings_root.add_child(node)
        _update_building_node(node, construction)
        node.visible = node.visible and _construction_visible_by_cutaway(construction)
    _remove_unseen_children(buildings_root, seen)

func _update_building_node(node: MeshInstance3D, construction: Dictionary) -> void:
    var mesh: BoxMesh = node.mesh as BoxMesh
    if mesh == null:
        mesh = BoxMesh.new()
        node.mesh = mesh
    var footprint: Dictionary = _building_footprint_bounds_from_snapshot(construction)
    var width: int = int(footprint["width"])
    var height: int = int(footprint["height"])
    var is_complete: bool = str(construction.get("status", "")) == "complete"
    mesh.size = Vector3(float(width) * 0.88, _building_height(str(construction.get("type", "")), is_complete), float(height) * 0.88)
    var base_y: float = _surface_y_for_footprint(construction)
    var render_center: Vector2 = _render_center_for_footprint(construction, footprint)
    node.position = Vector3(render_center.x, base_y + (mesh.size.y * 0.5), render_center.y)
    if is_complete:
        node.material_override = _make_material(_building_color(str(construction.get("type", ""))))
    else:
        node.material_override = _make_designation_material(_building_ghost_color(str(construction.get("type", "")), str(construction.get("status", ""))))
    node.visible = true

func _building_footprint_from_snapshot(construction: Dictionary) -> Array:
    match str(construction.get("type", "")):
        "kitchen":
            return [3, 3]
    return [1, 1]

func _building_footprint_bounds_from_snapshot(construction: Dictionary) -> Dictionary:
    var cells: Array = construction.get("cells", [])
    if cells.is_empty():
        var target: Array = construction.get("target_cell", [0, 0])
        var footprint: Array = _building_footprint_from_snapshot(construction)
        return {
            "width": int(footprint[0]),
            "height": int(footprint[1]),
            "center_x": int(target[0]),
            "center_y": int(target[1]),
        }
    var first: Array = cells[0]
    var min_x: int = int(first[0])
    var max_x: int = int(first[0])
    var min_y: int = int(first[1])
    var max_y: int = int(first[1])
    for raw_cell in cells:
        if not (raw_cell is Array) or raw_cell.size() < 2:
            continue
        min_x = mini(min_x, int(raw_cell[0]))
        max_x = maxi(max_x, int(raw_cell[0]))
        min_y = mini(min_y, int(raw_cell[1]))
        max_y = maxi(max_y, int(raw_cell[1]))
    return {
        "width": max_x - min_x + 1,
        "height": max_y - min_y + 1,
        "center_x": float(min_x + max_x) * 0.5,
        "center_y": float(min_y + max_y) * 0.5,
    }

func _building_height(building_type: String, is_complete: bool = true) -> float:
    if not is_complete:
        return 0.12
    match building_type:
        "kitchen":
            return 0.42
    return 0.9

func _building_color(building_type: String) -> Color:
    match building_type:
        "kitchen":
            return Color(0.82, 0.52, 0.22)
    return Color(0.42, 0.42, 0.45)

func _building_ghost_color(building_type: String, status: String) -> Color:
    var alpha: float = 0.38 if status == "planned" else 0.55
    match building_type:
        "kitchen":
            return Color(0.95, 0.58, 0.18, alpha)
    return Color(0.7, 0.7, 0.78, alpha)

func _sync_stockpiles(snapshot: Dictionary) -> void:
    if stockpiles_root == null:
        return
    var mesh_data: Dictionary = _new_colored_mesh_data()
    for stockpile in snapshot["stockpiles"]:
        for world_cell in _world_cells_from_snapshot(stockpile, "world_cells", "cells"):
            if not _world_cell_visible_by_cutaway(world_cell):
                continue
            _append_box(mesh_data, _render_position_for_world_cell(world_cell, 0.045), Vector3(0.92 * tile_size, 0.035, 0.92 * tile_size), Color(0.15, 0.62, 0.95, 0.42))
    _sync_colored_mesh_node(stockpiles_root, "StockpileZoneMesh", mesh_data, _make_vertex_color_material(true))

func _sync_stockpile_cells(root: Node3D, name_prefix: String, cells: Array, color: Color, y: float) -> void:
    if root == null:
        return
    var mesh_data: Dictionary = _new_colored_mesh_data()
    for raw_cell in cells:
        var world_cell: Vector3i
        if raw_cell is Vector3i:
            world_cell = raw_cell
        elif raw_cell is Vector2i:
            var cell: Vector2i = raw_cell
            world_cell = Vector3i(cell.x, _depth_for_cell(cell), _render_z_for_cell(cell))
        elif raw_cell is Array and raw_cell.size() >= 3:
            world_cell = Vector3i(int(raw_cell[0]), int(raw_cell[1]), int(raw_cell[2]))
        elif raw_cell is Array and raw_cell.size() >= 2:
            var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
            world_cell = Vector3i(cell.x, _depth_for_cell(cell), _render_z_for_cell(cell))
        else:
            continue
        if not _world_cell_visible_by_cutaway(world_cell):
            continue
        _append_box(mesh_data, _render_position_for_world_cell(world_cell, y), Vector3(0.92 * tile_size, 0.035, 0.92 * tile_size), color)
    _sync_colored_mesh_node(root, name_prefix + "Mesh", mesh_data, _make_vertex_color_material(true))

func _sync_stockpile_resize_handles(snapshot: Dictionary) -> void:
    if stockpile_resize_root == null:
        return
    if selected_stockpile_id == "":
        _remove_unseen_children(stockpile_resize_root, {})
        return
    var selected_stockpile: Dictionary = {}
    for stockpile in snapshot["stockpiles"]:
        if str(stockpile.get("id", "")) == selected_stockpile_id:
            selected_stockpile = stockpile
            break
    if selected_stockpile.is_empty():
        selected_stockpile_id = ""
        _remove_unseen_children(stockpile_resize_root, {})
        return
    var handles: Array = _stockpile_resize_handles_for_snapshot(selected_stockpile, snapshot["world"])
    var seen: Dictionary = {}
    for handle in handles:
        var raw_cell: Array = handle["cell"]
        var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
        var node_name: String = "Resize_%s_%s_%d" % [str(handle["side"]), str(handle["delta"]), cell.x * 1000 + cell.y]
        seen[node_name] = true
        _sync_resize_handle_node(stockpile_resize_root, node_name, cell, str(handle["label"]), int(handle["delta"]))
    _remove_unseen_children(stockpile_resize_root, seen)

func _stockpile_resize_handles_for_snapshot(stockpile: Dictionary, world_data: Dictionary) -> Array:
    var bounds: Dictionary = _stockpile_bounds_from_snapshot_cells(stockpile.get("cells", []))
    if bounds.is_empty():
        return []
    var min_x: int = int(bounds["min_x"])
    var max_x: int = int(bounds["max_x"])
    var min_y: int = int(bounds["min_y"])
    var max_y: int = int(bounds["max_y"])
    var center_x: int = int(floor(float(min_x + max_x) * 0.5))
    var center_y: int = int(floor(float(min_y + max_y) * 0.5))
    var handles: Array = []
    _append_snapshot_resize_handle(handles, Vector2i(center_x, min_y - 1), "north", 1, "^", world_data)
    _append_snapshot_resize_handle(handles, Vector2i(center_x, max_y + 1), "south", 1, "v", world_data)
    _append_snapshot_resize_handle(handles, Vector2i(min_x - 1, center_y), "west", 1, "<", world_data)
    _append_snapshot_resize_handle(handles, Vector2i(max_x + 1, center_y), "east", 1, ">", world_data)
    if min_y < max_y:
        _append_snapshot_resize_handle(handles, Vector2i(center_x, min_y), "north", -1, "v", world_data)
        _append_snapshot_resize_handle(handles, Vector2i(center_x, max_y), "south", -1, "^", world_data)
    if min_x < max_x:
        _append_snapshot_resize_handle(handles, Vector2i(min_x, center_y), "west", -1, ">", world_data)
        _append_snapshot_resize_handle(handles, Vector2i(max_x, center_y), "east", -1, "<", world_data)
    return handles

func _append_snapshot_resize_handle(handles: Array, cell: Vector2i, side: String, delta: int, label: String, world_data: Dictionary) -> void:
    if cell.x < 0 or cell.y < 0 or cell.x >= int(world_data.get("width", 0)) or cell.y >= int(world_data.get("height", 0)):
        return
    handles.append({"cell": [cell.x, cell.y], "side": side, "delta": delta, "label": label})

func _stockpile_bounds_from_snapshot_cells(cells: Array) -> Dictionary:
    if cells.is_empty():
        return {}
    var first: Array = cells[0]
    var min_x: int = int(first[0])
    var max_x: int = int(first[0])
    var min_y: int = int(first[1])
    var max_y: int = int(first[1])
    for raw_cell in cells:
        if not (raw_cell is Array) or raw_cell.size() < 2:
            continue
        var x: int = int(raw_cell[0])
        var y: int = int(raw_cell[1])
        min_x = mini(min_x, x)
        max_x = maxi(max_x, x)
        min_y = mini(min_y, y)
        max_y = maxi(max_y, y)
    return {"min_x": min_x, "max_x": max_x, "min_y": min_y, "max_y": max_y}

func _sync_resize_handle_node(root: Node3D, node_name: String, cell: Vector2i, label_text: String, delta: int) -> void:
    var handle: Node3D = root.get_node_or_null(node_name) as Node3D
    if handle == null:
        handle = Node3D.new()
        handle.name = node_name
        var backing := MeshInstance3D.new()
        backing.name = "Backing"
        backing.mesh = BoxMesh.new()
        handle.add_child(backing)
        var label := Label3D.new()
        label.name = "Label"
        label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
        handle.add_child(label)
        root.add_child(handle)
    handle.position = _render_position_for_cell(cell, 0.32)
    var backing_node: MeshInstance3D = handle.get_node_or_null("Backing") as MeshInstance3D
    if backing_node != null:
        var mesh: BoxMesh = backing_node.mesh as BoxMesh
        if mesh == null:
            mesh = BoxMesh.new()
            backing_node.mesh = mesh
        mesh.size = Vector3(0.52, 0.08, 0.52)
        backing_node.material_override = _make_designation_material(Color(0.15, 0.45, 1.0, 0.74) if delta > 0 else Color(1.0, 0.82, 0.12, 0.78))
    var label_node: Label3D = handle.get_node_or_null("Label") as Label3D
    if label_node != null:
        label_node.text = label_text
        label_node.position = Vector3(0.0, 0.16, 0.0)
        label_node.font_size = 56
        label_node.modulate = Color.WHITE
        label_node.visible = true

func _sync_designations(snapshot: Dictionary) -> void:
    if designations_root == null:
        return
    var mesh_data: Dictionary = _new_colored_mesh_data()
    for job in snapshot["jobs"]:
        if not _job_has_visible_designation(job):
            continue
        var target_world_cell: Vector3i = _world_cell_from_snapshot(job, "target_world_cell", "target_cell")
        if not _world_cell_visible_by_cutaway(target_world_cell):
            continue
        _append_box(mesh_data, _render_position_for_world_cell(target_world_cell, 0.08), Vector3(0.82, 0.06, 0.82), _designation_color(str(job["type"])))
    _sync_colored_mesh_node(designations_root, "JobDesignationMesh", mesh_data, _make_vertex_color_material(true))

func _sync_units(snapshot: Dictionary) -> void:
    if units_root == null:
        return
    var seen: Dictionary = {}
    for unit_data in snapshot["units"]:
        var node_name: String = "UnitView_" + str(unit_data["id"])
        seen[node_name] = true
        var unit_view: Node3D = units_root.get_node_or_null(node_name) as Node3D
        if unit_view == null:
            unit_view = UnitViewScene.instantiate()
            unit_view.name = node_name
            units_root.add_child(unit_view)
        var unit_world_cell: Vector3i = _world_cell_from_snapshot(unit_data, "world_cell", "position")
        unit_view.position = _render_position_for_world_cell(unit_world_cell, 0.42)
        unit_view.visible = not bool(unit_data.get("hidden", false)) and _world_cell_visible_by_cutaway(unit_world_cell)
        if unit_view.has_method("set_unit_data"):
            unit_view.set_unit_data(unit_data)
    _remove_unseen_children(units_root, seen)

func _resource_node_name(resource: Dictionary) -> String:
    var name_prefix: String = "TreeScatter_"
    match resource["type"]:
        "stone":
            name_prefix = "StoneScatter_"
        "berry":
            name_prefix = "BerryScatter_"
    return name_prefix + str(resource["id"])

func _update_resource_node(node: Node3D, resource: Dictionary) -> void:
    var resource_world_cell: Vector3i = _world_cell_from_snapshot(resource, "world_cell", "position")
    var raw_position: Array = resource.get("position", [])
    var surface_y: float = _surface_y_for_depth(resource_world_cell.y)
    if raw_position.size() >= 2:
        surface_y = _surface_top_y_for_height(_height_for_cell(Vector2i(int(raw_position[0]), int(raw_position[1]))))
    node.position = Vector3(float(resource_world_cell.x) * tile_size, surface_y, float(resource_world_cell.z) * tile_size) + _resource_scatter_offset(resource)
    node.visible = _resource_is_available(resource)
    match str(resource["type"]):
        "stone":
            _sync_stone_scatter_visual(node, resource)
        "berry":
            _sync_berry_scatter_visual(node, resource)
        _:
            _sync_tree_scatter_visual(node, resource)

func _resource_height(resource: Dictionary) -> float:
    match resource["type"]:
        "stone":
            return 0.34
        "berry":
            return 0.48
    return 1.72

func _sync_tree_scatter_visual(root: Node3D, resource: Dictionary) -> void:
    var seen: Dictionary = {}
    var trunk_material := _make_material(Color(0.36, 0.22, 0.10))
    var leaf_color := Color(0.11, 0.36, 0.14)
    if str(resource.get("material_key", "")) == "TREE_PINE":
        leaf_color = Color(0.06, 0.27, 0.18)
    var leaf_material := _make_material(leaf_color)
    _sync_resource_box_part(root, seen, "Trunk", Vector3(0.22, 0.92, 0.22), Vector3(0.0, 0.46, 0.0), trunk_material)
    _sync_resource_box_part(root, seen, "CanopyLower", Vector3(0.86, 0.54, 0.86), Vector3(0.0, 1.00, 0.0), leaf_material)
    _sync_resource_box_part(root, seen, "CanopyUpper", Vector3(0.62, 0.42, 0.62), Vector3(0.0, 1.42, 0.0), leaf_material)
    _remove_unseen_children(root, seen)

func _sync_berry_scatter_visual(root: Node3D, resource: Dictionary) -> void:
    var seen: Dictionary = {}
    var leaf_material := _make_material(Color(0.10, 0.32, 0.12))
    var berry_material := _make_material(Color(0.70, 0.06, 0.12))
    _sync_resource_box_part(root, seen, "Bush", Vector3(0.68, 0.36, 0.68), Vector3(0.0, 0.18, 0.0), leaf_material)
    _sync_resource_box_part(root, seen, "Top", Vector3(0.46, 0.24, 0.46), Vector3(0.0, 0.44, 0.0), leaf_material)
    _sync_resource_box_part(root, seen, "BerryA", Vector3(0.12, 0.12, 0.12), Vector3(-0.22, 0.42, 0.18), berry_material)
    _sync_resource_box_part(root, seen, "BerryB", Vector3(0.12, 0.12, 0.12), Vector3(0.20, 0.32, -0.20), berry_material)
    _sync_resource_box_part(root, seen, "BerryC", Vector3(0.10, 0.10, 0.10), Vector3(0.12, 0.50, 0.22), berry_material)
    _remove_unseen_children(root, seen)

func _sync_stone_scatter_visual(root: Node3D, resource: Dictionary) -> void:
    var seen: Dictionary = {}
    var material := _make_material(Color(0.42, 0.42, 0.46))
    _sync_resource_box_part(root, seen, "BoulderA", Vector3(0.58, 0.28, 0.46), Vector3(-0.08, 0.14, 0.02), material)
    _sync_resource_box_part(root, seen, "BoulderB", Vector3(0.34, 0.20, 0.32), Vector3(0.20, 0.10, -0.16), material)
    _remove_unseen_children(root, seen)

func _sync_resource_box_part(root: Node3D, seen: Dictionary, part_name: String, size: Vector3, part_position: Vector3, material: Material) -> void:
    seen[part_name] = true
    var part: MeshInstance3D = root.get_node_or_null(part_name) as MeshInstance3D
    if part == null:
        part = MeshInstance3D.new()
        part.name = part_name
        part.mesh = BoxMesh.new()
        root.add_child(part)
    var mesh: BoxMesh = part.mesh as BoxMesh
    if mesh == null:
        mesh = BoxMesh.new()
        part.mesh = mesh
    mesh.size = size
    part.position = part_position
    part.material_override = material
    part.visible = true

func _resource_scatter_offset(resource: Dictionary) -> Vector3:
    var id_text: String = str(resource.get("id", ""))
    var hash_value: int = abs(id_text.hash())
    var x_offset: float = (float(hash_value % 9) - 4.0) * 0.025
    var z_offset: float = (float(int(hash_value / 9) % 9) - 4.0) * 0.025
    return Vector3(x_offset, 0.0, z_offset)

func _resource_is_available(resource: Dictionary) -> bool:
    if bool(resource.get("hidden", false)):
        return false
    if bool(resource.get("depleted", false)):
        return false
    if bool(resource.get("exhausted", false)):
        return false
    if resource.has("available") and not bool(resource["available"]):
        return false
    if resource.has("quantity") and int(resource["quantity"]) <= 0:
        return false
    if resource.has("amount") and int(resource["amount"]) <= 0:
        return false
    return true

func _build_greedy_chunk_mesh_data(visible_cells: Dictionary) -> Dictionary:
    var mesh_data_by_material: Dictionary = {}
    var bounds: Dictionary = _chunk_render_bounds(visible_cells)
    if bounds.is_empty():
        return mesh_data_by_material
    for direction in ["pos_x", "neg_x", "pos_y", "neg_y", "pos_z", "neg_z"]:
        var ranges: Dictionary = _axis_ranges_for_chunk_face_direction(bounds, direction)
        var plane_min: int = int(ranges["plane_min"])
        var plane_max: int = int(ranges["plane_max"])
        var u_min: int = int(ranges["u_min"])
        var u_max: int = int(ranges["u_max"])
        var v_min: int = int(ranges["v_min"])
        var v_max: int = int(ranges["v_max"])
        var mask_width: int = u_max - u_min + 1
        var mask_height: int = v_max - v_min + 1
        for plane in range(plane_min, plane_max + 1):
            var mask: Array = []
            mask.resize(mask_width * mask_height)
            for index in range(mask.size()):
                mask[index] = ""
            for v_index in range(mask_height):
                for u_index in range(mask_width):
                    var u: int = u_min + u_index
                    var v: int = v_min + v_index
                    var render_cell := _render_cell_for_face_mask(direction, plane, u, v)
                    var cell_data: Dictionary = visible_cells.get(_chunk_local_key(render_cell), {})
                    if cell_data.is_empty():
                        continue
                    var neighbor := render_cell + _normal_for_chunk_face(direction)
                    if visible_cells.has(_chunk_local_key(neighbor)):
                        continue
                    mask[(v_index * mask_width) + u_index] = _chunk_material_key(cell_data.get("payload", {}))
            _emit_greedy_chunk_mask(mesh_data_by_material, mask, direction, plane, u_min, v_min, mask_width, mask_height)
    return mesh_data_by_material

func _emit_greedy_chunk_mask(mesh_data_by_material: Dictionary, mask: Array, direction: String, plane: int, u_min: int, v_min: int, mask_width: int, mask_height: int) -> void:
    var consumed: Dictionary = {}
    for v_index in range(mask_height):
        for u_index in range(mask_width):
            var index: int = (v_index * mask_width) + u_index
            if consumed.has(index):
                continue
            var mask_value: String = str(mask[index])
            if mask_value == "":
                continue
            var material_key: String = mask_value
            var rect_width: int = 1
            while u_index + rect_width < mask_width:
                var next_index: int = (v_index * mask_width) + u_index + rect_width
                if consumed.has(next_index) or str(mask[next_index]) != mask_value:
                    break
                rect_width += 1
            var rect_height: int = 1
            var can_extend: bool = true
            while v_index + rect_height < mask_height and can_extend:
                for du in range(rect_width):
                    var next_row_index: int = ((v_index + rect_height) * mask_width) + u_index + du
                    if consumed.has(next_row_index) or str(mask[next_row_index]) != mask_value:
                        can_extend = false
                        break
                if can_extend:
                    rect_height += 1
            for dv in range(rect_height):
                for du in range(rect_width):
                    consumed[((v_index + dv) * mask_width) + u_index + du] = true
            _append_chunk_face_rect(mesh_data_by_material, material_key, direction, plane, u_min + u_index, v_min + v_index, rect_width, rect_height)

func _append_chunk_face_rect(mesh_data_by_material: Dictionary, material_key: String, direction: String, plane: int, u: int, v: int, width: int, height: int) -> void:
    var data: Dictionary = _mesh_data_for_material(mesh_data_by_material, material_key, _chunk_color_for_material_key(material_key))
    var vertices: PackedVector3Array = data["vertices"]
    var normals: PackedVector3Array = data["normals"]
    var colors: PackedColorArray = data["colors"]
    var indices: PackedInt32Array = data["indices"]
    var start_index: int = vertices.size()
    var normal_i: Vector3i = _normal_for_chunk_face(direction)
    var normal := Vector3(float(normal_i.x), float(normal_i.y), float(normal_i.z))
    var quad: Array = _chunk_face_rect_vertices(direction, plane, u, v, width, height)
    var color: Color = _chunk_face_color(data.get("color", Color.WHITE), direction)
    for vertex in quad:
        vertices.append(vertex)
        normals.append(normal)
        colors.append(color)
    indices.append(start_index)
    indices.append(start_index + 1)
    indices.append(start_index + 2)
    indices.append(start_index)
    indices.append(start_index + 2)
    indices.append(start_index + 3)

func _chunk_face_rect_vertices(direction: String, plane: int, u: int, v: int, width: int, height: int) -> Array:
    var cell_height: float = _cell_height()
    match direction:
        "pos_x":
            var x_pos := (float(plane) + 0.5) * tile_size
            var z0 := (float(u) - 0.5) * tile_size
            var z1 := (float(u + width) - 0.5) * tile_size
            var y0 := float(v - RENDERED_CHUNK_SIZE) * cell_height
            var y1 := float(v + height - RENDERED_CHUNK_SIZE) * cell_height
            return [Vector3(x_pos, y0, z0), Vector3(x_pos, y1, z0), Vector3(x_pos, y1, z1), Vector3(x_pos, y0, z1)]
        "neg_x":
            var x_neg := (float(plane) - 0.5) * tile_size
            var z0n := (float(u) - 0.5) * tile_size
            var z1n := (float(u + width) - 0.5) * tile_size
            var y0n := float(v - RENDERED_CHUNK_SIZE) * cell_height
            var y1n := float(v + height - RENDERED_CHUNK_SIZE) * cell_height
            return [Vector3(x_neg, y0n, z1n), Vector3(x_neg, y1n, z1n), Vector3(x_neg, y1n, z0n), Vector3(x_neg, y0n, z0n)]
        "pos_y":
            var y_pos := float(plane - RENDERED_CHUNK_SIZE + 1) * cell_height
            var x0 := (float(u) - 0.5) * tile_size
            var x1 := (float(u + width) - 0.5) * tile_size
            var z0y := (float(v) - 0.5) * tile_size
            var z1y := (float(v + height) - 0.5) * tile_size
            return [Vector3(x0, y_pos, z1y), Vector3(x1, y_pos, z1y), Vector3(x1, y_pos, z0y), Vector3(x0, y_pos, z0y)]
        "neg_y":
            var y_neg := float(plane - RENDERED_CHUNK_SIZE) * cell_height
            var x0n := (float(u) - 0.5) * tile_size
            var x1n := (float(u + width) - 0.5) * tile_size
            var z0yn := (float(v) - 0.5) * tile_size
            var z1yn := (float(v + height) - 0.5) * tile_size
            return [Vector3(x0n, y_neg, z0yn), Vector3(x1n, y_neg, z0yn), Vector3(x1n, y_neg, z1yn), Vector3(x0n, y_neg, z1yn)]
        "pos_z":
            var z_pos := (float(plane) + 0.5) * tile_size
            var x0z := (float(u) - 0.5) * tile_size
            var x1z := (float(u + width) - 0.5) * tile_size
            var y0z := float(v - RENDERED_CHUNK_SIZE) * cell_height
            var y1z := float(v + height - RENDERED_CHUNK_SIZE) * cell_height
            return [Vector3(x1z, y0z, z_pos), Vector3(x1z, y1z, z_pos), Vector3(x0z, y1z, z_pos), Vector3(x0z, y0z, z_pos)]
        "neg_z":
            var z_neg := (float(plane) - 0.5) * tile_size
            var x0zn := (float(u) - 0.5) * tile_size
            var x1zn := (float(u + width) - 0.5) * tile_size
            var y0zn := float(v - RENDERED_CHUNK_SIZE) * cell_height
            var y1zn := float(v + height - RENDERED_CHUNK_SIZE) * cell_height
            return [Vector3(x0zn, y0zn, z_neg), Vector3(x0zn, y1zn, z_neg), Vector3(x1zn, y1zn, z_neg), Vector3(x1zn, y0zn, z_neg)]
    return []

func _render_cell_for_face_mask(direction: String, plane: int, u: int, v: int) -> Vector3i:
    match direction:
        "pos_x", "neg_x":
            return Vector3i(plane, v, u)
        "pos_y", "neg_y":
            return Vector3i(u, plane, v)
        "pos_z", "neg_z":
            return Vector3i(u, v, plane)
    return Vector3i.ZERO

func _chunk_render_bounds(visible_cells: Dictionary) -> Dictionary:
    var found: bool = false
    var min_cell := Vector3i.ZERO
    var max_cell := Vector3i.ZERO
    for cell_data in visible_cells.values():
        var render_cell: Vector3i = cell_data.get("render_cell", Vector3i.ZERO)
        if not found:
            min_cell = render_cell
            max_cell = render_cell
            found = true
        else:
            min_cell = Vector3i(mini(min_cell.x, render_cell.x), mini(min_cell.y, render_cell.y), mini(min_cell.z, render_cell.z))
            max_cell = Vector3i(maxi(max_cell.x, render_cell.x), maxi(max_cell.y, render_cell.y), maxi(max_cell.z, render_cell.z))
    if not found:
        return {}
    return {"min": min_cell, "max": max_cell}

func _axis_ranges_for_chunk_face_direction(bounds: Dictionary, direction: String) -> Dictionary:
    var min_cell: Vector3i = bounds.get("min", Vector3i.ZERO)
    var max_cell: Vector3i = bounds.get("max", Vector3i.ZERO)
    match direction:
        "pos_x", "neg_x":
            return {"plane_min": min_cell.x, "plane_max": max_cell.x, "u_min": min_cell.z, "u_max": max_cell.z, "v_min": min_cell.y, "v_max": max_cell.y}
        "pos_y", "neg_y":
            return {"plane_min": min_cell.y, "plane_max": max_cell.y, "u_min": min_cell.x, "u_max": max_cell.x, "v_min": min_cell.z, "v_max": max_cell.z}
        "pos_z", "neg_z":
            return {"plane_min": min_cell.z, "plane_max": max_cell.z, "u_min": min_cell.x, "u_max": max_cell.x, "v_min": min_cell.y, "v_max": max_cell.y}
    return {"plane_min": 0, "plane_max": 0, "u_min": 0, "u_max": 0, "v_min": 0, "v_max": 0}

func _normal_for_chunk_face(direction: String) -> Vector3i:
    match direction:
        "pos_x":
            return Vector3i(1, 0, 0)
        "neg_x":
            return Vector3i(-1, 0, 0)
        "pos_y":
            return Vector3i(0, 1, 0)
        "neg_y":
            return Vector3i(0, -1, 0)
        "pos_z":
            return Vector3i(0, 0, 1)
        "neg_z":
            return Vector3i(0, 0, -1)
    return Vector3i.ZERO

func _mesh_data_for_material(mesh_data_by_material: Dictionary, material_key: String, color: Color) -> Dictionary:
    if not mesh_data_by_material.has(material_key):
        mesh_data_by_material[material_key] = {
            "vertices": PackedVector3Array(),
            "normals": PackedVector3Array(),
            "colors": PackedColorArray(),
            "indices": PackedInt32Array(),
            "color": color,
        }
    return mesh_data_by_material[material_key]

func _chunk_material_key(payload: Dictionary) -> String:
    var material_key: String = str(payload.get("material_key", ""))
    if material_key == "":
        return str(payload.get("terrain", "unknown"))
    return material_key

func _chunk_payload_is_solid(payload: Dictionary) -> bool:
    return _chunk_material_key(payload) != "AIR"

func _surface_top_y_for_height(surface_height: int) -> float:
    return float(surface_height) * _cell_height()

func _chunk_color_for_material_key(material_key: String) -> Color:
    return _chunk_volume_color({"material_key": material_key}, 0)

func _chunk_face_color(base_color: Color, direction: String) -> Color:
    var brightness: float = 0.78
    match direction:
        "pos_y":
            brightness = 1.18
        "neg_y":
            brightness = 0.48
        "pos_x":
            brightness = 0.84
        "neg_x":
            brightness = 0.70
        "pos_z":
            brightness = 0.76
        "neg_z":
            brightness = 0.64
    return Color(
        clampf(base_color.r * brightness, 0.0, 1.0),
        clampf(base_color.g * brightness, 0.0, 1.0),
        clampf(base_color.b * brightness, 0.0, 1.0),
        base_color.a
    )

func _chunk_volume_color(payload: Dictionary, world_y: int) -> Color:
    var material_key: String = str(payload.get("material_key", ""))
    match material_key:
        "AIR":
            return Color(0.25, 0.48, 0.75, 0.18)
        "WATER_FLOW":
            return Color(0.08, 0.36, 0.92, 0.82)
        "DIRT":
            return Color(0.50, 0.34, 0.18)
        "CLAY":
            return Color(0.58, 0.42, 0.26)
        "GRAVEL":
            return Color(0.42, 0.42, 0.38)
        "SOFT_ROCK":
            return Color(0.44, 0.44, 0.50)
        "HARD_ROCK":
            return Color(0.20, 0.20, 0.23)
        "BEDROCK":
            return Color(0.06, 0.06, 0.07)
        "LAVA":
            return Color(1.0, 0.22, 0.04)
        "GRASS":
            return Color(0.24, 0.56, 0.22)
        "ORE_COAL":
            return Color(0.08, 0.08, 0.09)
        "ORE_COPPER":
            return Color(0.78, 0.38, 0.18)
        "ORE_IRON":
            return Color(0.62, 0.22, 0.14)
        "ORE_SILVER":
            return Color(0.78, 0.78, 0.86)
        "ORE_GOLD":
            return Color(0.95, 0.68, 0.16)
        "OIL":
            return Color(0.03, 0.025, 0.018)
    if world_y <= -12:
        return Color(0.20, 0.20, 0.23)
    if world_y <= -6:
        return Color(0.44, 0.44, 0.50)
    return Color(0.50, 0.34, 0.18)

func _make_chunk_volume_material(color: Color) -> StandardMaterial3D:
    var material: StandardMaterial3D = _make_material(Color.WHITE)
    if color.a < 0.999:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return material

func _make_vertex_color_material(transparent: bool) -> StandardMaterial3D:
    var material: StandardMaterial3D = _make_material(Color.WHITE)
    material.vertex_color_use_as_albedo = true
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return material

func _chunk_mesh_node_name(material_key: String) -> String:
    return "ChunkMesh_" + material_key.replace("/", "_").replace(" ", "_")

func _chunk_local_key(local_cell: Vector3i) -> String:
    return "%d,%d,%d" % [local_cell.x, local_cell.y, local_cell.z]

func _render_position_for_chunk_local_cell(local_cell: Vector3i, y_offset: float = 0.0) -> Vector3:
    return Vector3(
        float(local_cell.x) * tile_size,
        float(local_cell.y - 15) * _cell_height() - (_cell_height() * 0.5) + y_offset,
        float(local_cell.z) * tile_size
    )

func _array_to_vector3i(value: Array) -> Vector3i:
    if value.size() < 3:
        return Vector3i.ZERO
    return Vector3i(int(value[0]), int(value[1]), int(value[2]))

func _world_cell_from_snapshot(data: Dictionary, world_key: String, projected_key: String) -> Vector3i:
    var raw_world: Array = data.get(world_key, [])
    if raw_world.size() >= 3:
        return _array_to_vector3i(raw_world)
    var raw_projected: Array = data.get(projected_key, [])
    if raw_projected.size() >= 2:
        var projected_cell := Vector2i(int(raw_projected[0]), int(raw_projected[1]))
        return Vector3i(projected_cell.x, _depth_for_cell(projected_cell), _render_z_for_cell(projected_cell))
    return Vector3i.ZERO

func _world_cells_from_snapshot(data: Dictionary, world_key: String, projected_key: String) -> Array[Vector3i]:
    var output: Array[Vector3i] = []
    var raw_world_cells: Array = data.get(world_key, [])
    if not raw_world_cells.is_empty():
        for raw_world in raw_world_cells:
            if raw_world is Array and raw_world.size() >= 3:
                output.append(_array_to_vector3i(raw_world))
        if not output.is_empty():
            return output
    for raw_projected in data.get(projected_key, []):
        if raw_projected is Array and raw_projected.size() >= 2:
            var projected_cell := Vector2i(int(raw_projected[0]), int(raw_projected[1]))
            output.append(Vector3i(projected_cell.x, _depth_for_cell(projected_cell), _render_z_for_cell(projected_cell)))
    return output

func _cache_cell_surface_heights(snapshot: Dictionary) -> void:
    _cell_surface_y = {}
    _cell_surface_height = {}
    _cell_render_z = {}
    var first_row_by_depth: Dictionary = {}
    for cell_data in snapshot.get("world", {}).get("cells", []):
        var cell := Vector2i(int(cell_data.get("x", 0)), int(cell_data.get("z", 0)))
        var depth: int = int(cell_data.get("depth", 0))
        _cell_surface_y[_cell_key(cell)] = _surface_y_for_depth(depth)
        _cell_surface_height[_cell_key(cell)] = int(cell_data.get("surface_height", 0))
        var depth_key: String = str(depth)
        if not first_row_by_depth.has(depth_key):
            first_row_by_depth[depth_key] = cell.y
        else:
            first_row_by_depth[depth_key] = mini(int(first_row_by_depth[depth_key]), cell.y)
    for cell_data in snapshot.get("world", {}).get("cells", []):
        var cell := Vector2i(int(cell_data.get("x", 0)), int(cell_data.get("z", 0)))
        var depth_key: String = str(int(cell_data.get("depth", 0)))
        _cell_render_z[_cell_key(cell)] = cell.y - int(first_row_by_depth.get(depth_key, 0))

func _surface_y_for_cell(cell: Vector2i) -> float:
    return float(_cell_surface_y.get(_cell_key(cell), 0.0))

func _height_for_cell(cell: Vector2i) -> int:
    return int(_cell_surface_height.get(_cell_key(cell), 0))

func _surface_y_for_depth(depth: int) -> float:
    return float(depth) * _cell_height()

func _top_visible_cell_at_display_cell(display_cell: Vector2i, grid_world) -> Vector2i:
    var best_cell: Vector2i = INVALID_CELL
    var best_depth: int = -999999
    for z in range(int(grid_world.height)):
        var cell := Vector2i(display_cell.x, z)
        var sim_cell = grid_world.get_cell(cell)
        if sim_cell == null or not _is_visible_pick_cell(sim_cell):
            continue
        if _render_z_for_grid_cell(grid_world, cell) != display_cell.y:
            continue
        var depth: int = int(sim_cell.depth)
        if best_cell == INVALID_CELL or depth > best_depth:
            best_cell = cell
            best_depth = depth
    return best_cell

func _is_visible_pick_cell(sim_cell) -> bool:
    return _depth_visible_by_cutaway(int(sim_cell.depth)) and str(sim_cell.terrain) != "excavated"

func _render_z_for_grid_cell(grid_world, cell: Vector2i) -> int:
    var sim_cell = grid_world.get_cell(cell)
    if sim_cell == null:
        return cell.y
    var depth: int = int(sim_cell.depth)
    for z in range(int(grid_world.height)):
        var layer_cell = grid_world.get_cell(Vector2i(cell.x, z))
        if layer_cell != null and int(layer_cell.depth) == depth:
            return cell.y - z
    return cell.y

func _render_position_for_cell(cell: Vector2i, y_offset: float = 0.0) -> Vector3:
    return Vector3(cell.x * tile_size, _surface_y_for_cell(cell) + y_offset, _render_z_for_cell(cell) * tile_size)

func _render_position_for_world_cell(world_cell: Vector3i, y_offset: float = 0.0) -> Vector3:
    return Vector3(float(world_cell.x) * tile_size, _surface_y_for_depth(world_cell.y) + y_offset, float(world_cell.z) * tile_size)

func _cell_height() -> float:
    return tile_size * CELL_HEIGHT_FACTOR

func _depth_visible_by_cutaway(depth: int) -> bool:
    return depth <= layer_cutaway_depth

func _chunk_local_cell_visible_by_cutaway(local_cell: Vector3i) -> bool:
    return local_cell.y <= 15 + layer_cutaway_depth

func _cell_visible_by_cutaway(cell: Vector2i) -> bool:
    return _depth_visible_by_cutaway(_depth_for_cell(cell))

func _world_cell_visible_by_cutaway(world_cell: Vector3i) -> bool:
    return _depth_visible_by_cutaway(world_cell.y)

func _resource_visible_by_cutaway(resource: Dictionary) -> bool:
    var raw_world_cell: Array = resource.get("world_cell", [])
    if raw_world_cell.size() >= 3:
        return _world_cell_visible_by_cutaway(_array_to_vector3i(raw_world_cell))
    var raw_position: Array = resource.get("position", [])
    if raw_position.size() < 2:
        return true
    return _cell_visible_by_cutaway(Vector2i(int(raw_position[0]), int(raw_position[1])))

func _construction_visible_by_cutaway(construction: Dictionary) -> bool:
    var world_cells: Array[Vector3i] = _world_cells_from_snapshot(construction, "world_cells", "cells")
    if world_cells.is_empty():
        return _world_cell_visible_by_cutaway(_world_cell_from_snapshot(construction, "target_world_cell", "target_cell"))
    for world_cell in world_cells:
        if _world_cell_visible_by_cutaway(world_cell):
            return true
    return false

func _depth_for_cell(cell: Vector2i) -> int:
    return int(round(_surface_y_for_cell(cell) / maxf(_cell_height(), 0.0001)))

func _sync_hover_cell() -> void:
    _resolve_child_roots()
    if hover_root == null:
        return
    if hover_cell == INVALID_CELL or not _cell_visible_by_cutaway(hover_cell):
        hover_root.visible = false
        return
    _ensure_hover_edges()
    hover_root.position = _render_position_for_cell(hover_cell, -_cell_height() * 0.5)
    hover_root.visible = true

func _ensure_hover_edges() -> void:
    var edge_color: Color = Color(1.0, 0.9, 0.15, 0.95) if hover_valid else Color(1.0, 0.12, 0.08, 0.95)
    var edge_material: StandardMaterial3D = _make_designation_material(edge_color)
    var thickness: float = maxf(tile_size * 0.035, 0.025)
    var half_width: float = tile_size * 0.5
    var half_height: float = _cell_height() * 0.5
    var edge_index: int = 0
    for y in [-half_height, half_height]:
        for z in [-half_width, half_width]:
            _sync_hover_edge(edge_index, Vector3(0.0, y, z), Vector3(tile_size + thickness, thickness, thickness), edge_material)
            edge_index += 1
    for x in [-half_width, half_width]:
        for z in [-half_width, half_width]:
            _sync_hover_edge(edge_index, Vector3(x, 0.0, z), Vector3(thickness, _cell_height() + thickness, thickness), edge_material)
            edge_index += 1
    for x in [-half_width, half_width]:
        for y in [-half_height, half_height]:
            _sync_hover_edge(edge_index, Vector3(x, y, 0.0), Vector3(thickness, thickness, tile_size + thickness), edge_material)
            edge_index += 1

func _sync_hover_edge(index: int, local_position: Vector3, size: Vector3, material: Material) -> void:
    var node_name: String = "Edge_%02d" % index
    var edge: MeshInstance3D = hover_root.get_node_or_null(node_name) as MeshInstance3D
    if edge == null:
        edge = MeshInstance3D.new()
        edge.name = node_name
        edge.mesh = BoxMesh.new()
        hover_root.add_child(edge)
    var mesh: BoxMesh = edge.mesh as BoxMesh
    if mesh == null:
        mesh = BoxMesh.new()
        edge.mesh = mesh
    mesh.size = size
    edge.position = local_position
    edge.material_override = material
    edge.visible = true

func _render_z_for_cell(cell: Vector2i) -> int:
    return int(_cell_render_z.get(_cell_key(cell), cell.y))

func _render_center_for_footprint(construction: Dictionary, footprint: Dictionary) -> Vector2:
    var world_cells: Array[Vector3i] = _world_cells_from_snapshot(construction, "world_cells", "cells")
    if world_cells.is_empty():
        var target_world_cell: Vector3i = _world_cell_from_snapshot(construction, "target_world_cell", "target_cell")
        return Vector2(float(target_world_cell.x) * tile_size, float(target_world_cell.z) * tile_size)
    var found: bool = false
    var min_x: float = 0.0
    var max_x: float = 0.0
    var min_z: float = 0.0
    var max_z: float = 0.0
    for world_cell in world_cells:
        var render_x: float = float(world_cell.x) * tile_size
        var render_z: float = float(world_cell.z) * tile_size
        if not found:
            min_x = render_x
            max_x = render_x
            min_z = render_z
            max_z = render_z
            found = true
        else:
            min_x = minf(min_x, render_x)
            max_x = maxf(max_x, render_x)
            min_z = minf(min_z, render_z)
            max_z = maxf(max_z, render_z)
    if not found:
        return Vector2(float(footprint["center_x"]) * tile_size, float(footprint["center_y"]) * tile_size)
    return Vector2((min_x + max_x) * 0.5, (min_z + max_z) * 0.5)

func _surface_y_for_footprint(construction: Dictionary) -> float:
    var world_cells: Array[Vector3i] = _world_cells_from_snapshot(construction, "world_cells", "cells")
    if world_cells.is_empty():
        return _surface_y_for_depth(_world_cell_from_snapshot(construction, "target_world_cell", "target_cell").y)
    var found: bool = false
    var surface_y: float = 0.0
    for world_cell in world_cells:
        var cell_y: float = _surface_y_for_depth(world_cell.y)
        surface_y = cell_y if not found else maxf(surface_y, cell_y)
        found = true
    return surface_y

func _cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func _item_color(item_type: String) -> Color:
    match item_type:
        "wood":
            return Color(0.55, 0.32, 0.12)
        "stone":
            return Color(0.5, 0.5, 0.55)
        "dirt":
            return Color(0.42, 0.28, 0.14)
        "food", "berry":
            return Color(0.8, 0.15, 0.18)
    return Color(0.75, 0.65, 0.35)

func _job_has_visible_designation(job: Dictionary) -> bool:
    return str(job.get("status", "")) in ["open", "claimed", "in_progress"]

func _designation_color(job_type: String) -> Color:
    match job_type:
        "CHOP_TREE":
            return Color(0.1, 0.85, 0.25, 0.62)
        "GATHER_STONE":
            return Color(0.65, 0.75, 0.95, 0.62)
        "GATHER_FOOD":
            return Color(0.95, 0.18, 0.25, 0.62)
        "MINE_CELL":
            return Color(0.95, 0.72, 0.18, 0.68)
    return Color(1.0, 0.85, 0.15, 0.62)

func _make_designation_material(color: Color) -> StandardMaterial3D:
    var material: StandardMaterial3D = _make_material(color)
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    return material

func _sync_debug_label(text: String, label_position: Vector3, stable_id: String, label_visible: bool = true) -> void:
    if not show_debug_labels or debug_labels_root == null:
        return
    var label_name: String = "DebugLabel_" + stable_id
    var label: Label3D = debug_labels_root.get_node_or_null(label_name) as Label3D
    if label == null:
        label = Label3D.new()
        label.name = label_name
        label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
        debug_labels_root.add_child(label)
    label.text = text
    label.position = label_position
    label.visible = label_visible

func _remove_unseen_debug_labels(resources: Array) -> void:
    if debug_labels_root == null:
        return
    var seen: Dictionary = {}
    for resource in resources:
        seen["DebugLabel_" + str(resource["id"])] = true
    _remove_unseen_children(debug_labels_root, seen)

func _remove_unseen_children(root: Node, seen_names: Dictionary) -> void:
    if root == null:
        return
    for child in root.get_children():
        if not seen_names.has(child.name):
            root.remove_child(child)
            child.free()

func _make_material(color: Color) -> StandardMaterial3D:
    var material: StandardMaterial3D = StandardMaterial3D.new()
    material.albedo_color = color
    return material
