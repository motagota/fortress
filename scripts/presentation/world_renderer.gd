extends Node3D

# Presentation-only renderer. It reads simulation state and creates simple meshes;
# it must never mutate simulation state or feed camera/scene-tree data back into sim.

const UnitViewScene := preload("res://scenes/units/UnitView.tscn")

@onready var terrain_root: Node3D = $Terrain
@onready var resources_root: Node3D = $Resources
@onready var items_root: Node3D = get_node_or_null("Items") as Node3D
@onready var units_root: Node3D = $Units
@onready var debug_labels_root: Node3D = $DebugLabels

var tile_size: float = 1.0
@export var show_debug_labels: bool = true

func _ready() -> void:
    pass

func sync_from_simulation(simulation: Simulation) -> void:
    _resolve_child_roots()
    var snapshot: Dictionary = simulation.canonical_snapshot()
    _sync_terrain(snapshot)
    _sync_resources(snapshot)
    _sync_items(snapshot)
    _sync_units(snapshot)

func _resolve_child_roots() -> void:
    # Headless tests can instantiate Main.tscn and call sync_from_simulation()
    # before the scene enters the tree, so @onready variables may not have run yet.
    if terrain_root == null:
        terrain_root = get_node_or_null("Terrain") as Node3D
    if resources_root == null:
        resources_root = get_node_or_null("Resources") as Node3D
    if items_root == null:
        items_root = get_node_or_null("Items") as Node3D
    if items_root == null:
        items_root = Node3D.new()
        items_root.name = "Items"
        add_child(items_root)
    if units_root == null:
        units_root = get_node_or_null("Units") as Node3D
    if debug_labels_root == null:
        debug_labels_root = get_node_or_null("DebugLabels") as Node3D

func _sync_terrain(snapshot: Dictionary) -> void:
    if terrain_root == null:
        return
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
        mesh.size = Vector3(tile_size, 0.08, tile_size)
        tile.position = Vector3(cell_data["x"] * tile_size, -0.04, cell_data["z"] * tile_size)
        tile.material_override = _make_material(Color(0.25, 0.55, 0.24) if cell_data["terrain"] == "grass" else Color(0.45, 0.34, 0.19))
        tile.visible = true
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
        _sync_debug_label(str(resource["type"]), node.position + Vector3(0.0, _resource_height(resource) * 0.5 + 0.25, 0.0), str(resource["id"]), _resource_is_available(resource))
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
        node.position = Vector3(item["position"][0] * tile_size, side * 0.5, item["position"][1] * tile_size)
        node.material_override = _make_material(_item_color(str(item.get("item_type", "item"))))
        node.visible = item.get("holder_unit_id", "") == ""
    _remove_unseen_children(items_root, seen)

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
        unit_view.position = Vector3(unit_data["position"][0] * tile_size, 0.42, unit_data["position"][1] * tile_size)
        unit_view.visible = not bool(unit_data.get("hidden", false))
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
    mesh.size = Vector3(0.55, height, 0.55)
    node.position = Vector3(resource["position"][0] * tile_size, height * 0.5, resource["position"][1] * tile_size)
    node.material_override = _make_material(_resource_color(resource))
    node.visible = _resource_is_available(resource)

func _resource_height(resource: Dictionary) -> float:
    match resource["type"]:
        "stone":
            return 0.45
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

func _item_color(item_type: String) -> Color:
    match item_type:
        "wood":
            return Color(0.55, 0.32, 0.12)
        "stone":
            return Color(0.5, 0.5, 0.55)
        "food", "berry":
            return Color(0.8, 0.15, 0.18)
    return Color(0.75, 0.65, 0.35)

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
