extends Node3D

# Presentation-only renderer. It reads simulation state and creates simple meshes;
# it must never mutate simulation state or feed camera/scene-tree data back into sim.

const UnitViewScene := preload("res://scenes/units/UnitView.tscn")
const INVALID_CELL := Vector2i(-1, -1)
const CELL_HEIGHT_FACTOR := 1.0
const MIN_LAYER_DEPTH := -4
const MAX_LAYER_DEPTH := 0

@onready var terrain_root: Node3D = $Terrain
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
var _cell_render_z: Dictionary = {}

func _ready() -> void:
    pass

func sync_from_simulation(simulation: Simulation) -> void:
    _resolve_child_roots()
    var snapshot: Dictionary = simulation.canonical_snapshot()
    _cache_cell_surface_heights(snapshot)
    _sync_terrain(snapshot)
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
    return _top_visible_cell_at_display_cell(display_cell, grid_world)

func ray_to_grid_cell(ray_origin: Vector3, ray_direction: Vector3, grid_world) -> Vector2i:
    if absf(ray_direction.y) < 0.00001:
        return INVALID_CELL
    if grid_world == null or tile_size <= 0.0:
        return INVALID_CELL
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

func _resolve_child_roots() -> void:
    # Headless tests can instantiate Main.tscn and call sync_from_simulation()
    # before the scene enters the tree, so @onready variables may not have run yet.
    if terrain_root == null:
        terrain_root = get_node_or_null("Terrain") as Node3D
    if terrain_root == null:
        terrain_root = Node3D.new()
        terrain_root.name = "Terrain"
        add_child(terrain_root)
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

func _sync_terrain(snapshot: Dictionary) -> void:
    if terrain_root == null:
        return
    var stone_resource_ids: Dictionary = _resource_ids_by_type(snapshot, "stone")
    var seen: Dictionary = {}
    for cell_data in snapshot["world"]["cells"]:
        var node_name: String = "Tile_%02d_%02d" % [cell_data["x"], cell_data["z"]]
        seen[node_name] = true
        var tile: MeshInstance3D = terrain_root.get_node_or_null(node_name) as MeshInstance3D
        if tile == null:
            tile = MeshInstance3D.new()
            tile.name = node_name
            tile.mesh = BoxMesh.new()
            terrain_root.add_child(tile)
        var mesh: BoxMesh = tile.mesh as BoxMesh
        if mesh == null:
            mesh = BoxMesh.new()
            tile.mesh = mesh
        mesh.size = Vector3(tile_size, _cell_height(), tile_size)
        var cell := Vector2i(int(cell_data["x"]), int(cell_data["z"]))
        tile.position = _render_position_for_cell(cell, -_cell_height() * 0.5)
        tile.material_override = _make_material(_terrain_color(str(cell_data.get("terrain", "grass")), int(cell_data.get("depth", 0))))
        var resource_id: String = str(cell_data.get("resource_id", ""))
        tile.visible = _cell_data_visible_by_cutaway(cell_data) and str(cell_data.get("terrain", "grass")) != "excavated" and not stone_resource_ids.has(resource_id)
    _remove_unseen_children(terrain_root, seen)

func _sync_resources(snapshot: Dictionary) -> void:
    if resources_root == null:
        return
    var seen: Dictionary = {}
    for resource in snapshot["resources"]:
        var visual_name: String = _resource_node_name(resource)
        seen[visual_name] = true
        var node: MeshInstance3D = resources_root.get_node_or_null(visual_name) as MeshInstance3D
        if node == null:
            node = MeshInstance3D.new()
            node.name = visual_name
            node.mesh = BoxMesh.new()
            resources_root.add_child(node)
        _update_resource_node(node, resource)
        node.visible = node.visible and _resource_visible_by_cutaway(resource)
        _sync_debug_label(str(resource["type"]), node.position + Vector3(0.0, _resource_height(resource) * 0.5 + 0.25, 0.0), str(resource["id"]), node.visible)
    _remove_unseen_children(resources_root, seen)
    _remove_unseen_debug_labels(snapshot["resources"])

func _sync_items(snapshot: Dictionary) -> void:
    if items_root == null:
        return
    var seen: Dictionary = {}
    for item in snapshot["items"]:
        var node_name: String = "Item_" + str(item["id"])
        seen[node_name] = true
        var node: MeshInstance3D = items_root.get_node_or_null(node_name) as MeshInstance3D
        if node == null:
            node = MeshInstance3D.new()
            node.name = node_name
            node.mesh = BoxMesh.new()
            items_root.add_child(node)
        var mesh: BoxMesh = node.mesh as BoxMesh
        if mesh == null:
            mesh = BoxMesh.new()
            node.mesh = mesh
        var side: float = 0.36
        mesh.size = Vector3(side, side, side)
        var item_cell := Vector2i(int(item["position"][0]), int(item["position"][1]))
        node.position = _render_position_for_cell(item_cell, side * 0.5)
        node.material_override = _make_material(_item_color(str(item.get("item_type", "item"))))
        node.visible = item.get("holder_unit_id", "") == "" and _cell_visible_by_cutaway(item_cell)
    _remove_unseen_children(items_root, seen)

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
    var seen: Dictionary = {}
    for stockpile in snapshot["stockpiles"]:
        var stockpile_id: String = str(stockpile["id"])
        for raw_cell in stockpile["cells"]:
            if not (raw_cell is Array) or raw_cell.size() < 2:
                continue
            var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
            if not _cell_visible_by_cutaway(cell):
                continue
            var node_name: String = "Stockpile_%s_%02d_%02d" % [stockpile_id, cell.x, cell.y]
            seen[node_name] = true
            _sync_stockpile_cell_node(stockpiles_root, node_name, cell, Color(0.15, 0.62, 0.95, 0.42), 0.045)
    _remove_unseen_children(stockpiles_root, seen)

func _sync_stockpile_cells(root: Node3D, name_prefix: String, cells: Array, color: Color, y: float) -> void:
    if root == null:
        return
    var seen: Dictionary = {}
    for raw_cell in cells:
        var cell: Vector2i
        if raw_cell is Vector2i:
            cell = raw_cell
        elif raw_cell is Array and raw_cell.size() >= 2:
            cell = Vector2i(int(raw_cell[0]), int(raw_cell[1]))
        else:
            continue
        var node_name: String = "%s_%02d_%02d" % [name_prefix, cell.x, cell.y]
        if not _cell_visible_by_cutaway(cell):
            continue
        seen[node_name] = true
        _sync_stockpile_cell_node(root, node_name, cell, color, y)
    _remove_unseen_children(root, seen)

func _sync_stockpile_cell_node(root: Node3D, node_name: String, cell: Vector2i, color: Color, y: float) -> void:
    var node: MeshInstance3D = root.get_node_or_null(node_name) as MeshInstance3D
    if node == null:
        node = MeshInstance3D.new()
        node.name = node_name
        node.mesh = BoxMesh.new()
        root.add_child(node)
    var mesh: BoxMesh = node.mesh as BoxMesh
    if mesh == null:
        mesh = BoxMesh.new()
        node.mesh = mesh
    mesh.size = Vector3(0.92 * tile_size, 0.035, 0.92 * tile_size)
    node.position = _render_position_for_cell(cell, y)
    node.material_override = _make_designation_material(color)
    node.visible = true

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
    var seen: Dictionary = {}
    for job in snapshot["jobs"]:
        if not _job_has_visible_designation(job):
            continue
        var node_name: String = "Designation_" + str(job["id"])
        seen[node_name] = true
        var node: MeshInstance3D = designations_root.get_node_or_null(node_name) as MeshInstance3D
        if node == null:
            node = MeshInstance3D.new()
            node.name = node_name
            node.mesh = BoxMesh.new()
            designations_root.add_child(node)
        var mesh: BoxMesh = node.mesh as BoxMesh
        if mesh == null:
            mesh = BoxMesh.new()
            node.mesh = mesh
        mesh.size = Vector3(0.82, 0.06, 0.82)
        var target_cell := Vector2i(int(job["target_cell"][0]), int(job["target_cell"][1]))
        if not _cell_visible_by_cutaway(target_cell):
            continue
        node.position = _render_position_for_cell(target_cell, 0.08)
        node.material_override = _make_designation_material(_designation_color(str(job["type"])))
        node.visible = true
    _remove_unseen_children(designations_root, seen)

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
        var unit_cell := Vector2i(int(unit_data["position"][0]), int(unit_data["position"][1]))
        unit_view.position = _render_position_for_cell(unit_cell, 0.42)
        unit_view.visible = not bool(unit_data.get("hidden", false)) and _cell_visible_by_cutaway(unit_cell)
        if unit_view.has_method("set_unit_data"):
            unit_view.set_unit_data(unit_data)
    _remove_unseen_children(units_root, seen)

func _resource_node_name(resource: Dictionary) -> String:
    var name_prefix: String = "TreeCube_"
    match resource["type"]:
        "stone":
            name_prefix = "StoneCube_"
        "berry":
            name_prefix = "BerryCube_"
    return name_prefix + str(resource["id"])

func _update_resource_node(node: MeshInstance3D, resource: Dictionary) -> void:
    var mesh: BoxMesh = node.mesh as BoxMesh
    if mesh == null:
        mesh = BoxMesh.new()
        node.mesh = mesh
    var height: float = _resource_height(resource)
    var resource_cell := Vector2i(int(resource["position"][0]), int(resource["position"][1]))
    if str(resource["type"]) == "stone":
        mesh.size = Vector3(tile_size, height, tile_size)
        node.position = _render_position_for_cell(resource_cell, -height * 0.5)
    else:
        mesh.size = Vector3(0.55, height, 0.55)
        node.position = _render_position_for_cell(resource_cell, height * 0.5)
    node.material_override = _make_material(_resource_color(resource))
    node.visible = _resource_is_available(resource)

func _resource_height(resource: Dictionary) -> float:
    match resource["type"]:
        "stone":
            return _cell_height()
        "berry":
            return 0.35
    return 0.9

func _resource_color(resource: Dictionary) -> Color:
    if not _resource_is_available(resource):
        return Color(0.12, 0.12, 0.12, 0.35)
    match resource["type"]:
        "stone":
            return Color(0.45, 0.45, 0.50)
        "berry":
            return Color(0.65, 0.08, 0.12)
    return Color(0.1, 0.45, 0.12)

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

func _terrain_color(terrain: String, depth: int = 0) -> Color:
    match terrain:
        "grass":
            return Color(0.25, 0.55, 0.24)
        "dirt":
            if depth <= -3:
                return Color(0.24, 0.18, 0.12)
            if depth <= -2:
                return Color(0.32, 0.24, 0.15)
            return Color(0.45, 0.34, 0.19)
        "excavated":
            return Color(0.22, 0.20, 0.18)
        "rock":
            return Color(0.34, 0.34, 0.38)
        "solid_rock":
            return Color(0.18, 0.18, 0.20)
        "collapsed":
            return Color(0.10, 0.09, 0.08)
    return Color(0.45, 0.34, 0.19)

func _cache_cell_surface_heights(snapshot: Dictionary) -> void:
    _cell_surface_y = {}
    _cell_render_z = {}
    var first_row_by_depth: Dictionary = {}
    for cell_data in snapshot.get("world", {}).get("cells", []):
        var cell := Vector2i(int(cell_data.get("x", 0)), int(cell_data.get("z", 0)))
        var depth: int = int(cell_data.get("depth", 0))
        _cell_surface_y[_cell_key(cell)] = _surface_y_for_depth(depth)
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

func _cell_height() -> float:
    return tile_size * CELL_HEIGHT_FACTOR

func _resource_ids_by_type(snapshot: Dictionary, resource_type: String) -> Dictionary:
    var resource_ids: Dictionary = {}
    for resource in snapshot.get("resources", []):
        if str(resource.get("type", "")) == resource_type:
            resource_ids[str(resource.get("id", ""))] = true
    return resource_ids

func _cell_data_visible_by_cutaway(cell_data: Dictionary) -> bool:
    return _depth_visible_by_cutaway(int(cell_data.get("depth", 0)))

func _depth_visible_by_cutaway(depth: int) -> bool:
    return depth <= layer_cutaway_depth

func _cell_visible_by_cutaway(cell: Vector2i) -> bool:
    return _depth_visible_by_cutaway(_depth_for_cell(cell))

func _resource_visible_by_cutaway(resource: Dictionary) -> bool:
    var raw_position: Array = resource.get("position", [])
    if raw_position.size() < 2:
        return true
    return _cell_visible_by_cutaway(Vector2i(int(raw_position[0]), int(raw_position[1])))

func _construction_visible_by_cutaway(construction: Dictionary) -> bool:
    var cells: Array = construction.get("cells", [])
    if cells.is_empty():
        var target: Array = construction.get("target_cell", [0, 0])
        return _cell_visible_by_cutaway(Vector2i(int(target[0]), int(target[1])))
    for raw_cell in cells:
        if raw_cell is Array and raw_cell.size() >= 2 and _cell_visible_by_cutaway(Vector2i(int(raw_cell[0]), int(raw_cell[1]))):
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
    var cells: Array = construction.get("cells", [])
    if cells.is_empty():
        return Vector2(float(footprint["center_x"]) * tile_size, _render_z_for_cell(Vector2i(int(footprint["center_x"]), int(footprint["center_y"]))) * tile_size)
    var found: bool = false
    var min_x: float = 0.0
    var max_x: float = 0.0
    var min_z: float = 0.0
    var max_z: float = 0.0
    for raw_cell in cells:
        if not (raw_cell is Array) or raw_cell.size() < 2:
            continue
        var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
        var render_x: float = float(cell.x) * tile_size
        var render_z: float = float(_render_z_for_cell(cell)) * tile_size
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
    var cells: Array = construction.get("cells", [])
    if cells.is_empty():
        var target: Array = construction.get("target_cell", [0, 0])
        return _surface_y_for_cell(Vector2i(int(target[0]), int(target[1])))
    var found: bool = false
    var surface_y: float = 0.0
    for raw_cell in cells:
        if not (raw_cell is Array) or raw_cell.size() < 2:
            continue
        var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
        var cell_y: float = _surface_y_for_cell(cell)
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
