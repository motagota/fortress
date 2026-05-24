extends Camera3D

# Presentation-only camera controls; simulation does not read camera state.
# Controls:
#   WASD          — pan (move pivot point on XZ plane)
#   Mouse wheel   — zoom in/out (clamped)
#   Middle-mouse drag — orbit around pivot point
#   Right-mouse drag  — rotate camera in place (yaw/pitch)
#   F             — reset to default isometric view

@export var pan_speed: float = 10.0
@export var zoom_speed: float = 2.0
@export var rotate_speed: float = 1.5
@export var orbit_speed: float = 0.005
@export var min_zoom: float = 3.0
@export var max_zoom: float = 40.0

# Pivot: the point in world space the camera orbits around.
var _pivot: Vector3 = Vector3(4, 0, 9)
# Distance from pivot (controls zoom).
var _distance: float = 14.0
# Yaw and pitch in radians for orbit orientation.
var _yaw: float = -0.785398   # -45 degrees (looking from corner)
var _pitch: float = 0.955317   # ~54.7 degrees (isometric-ish)

# Drag state
var _dragging: bool = false
var _drag_button: int = 0
var _last_mouse: Vector2 = Vector2.ZERO

# Default isometric view parameters (matching Main.tscn initial transform)
const _DEFAULT_PIVOT := Vector3(4, 0, 9)
const _DEFAULT_DISTANCE := 14.0
const _DEFAULT_YAW := -0.785398
const _DEFAULT_PITCH := 0.955317


func _ready() -> void:
    current = true
    # Initialize from current position so we don't jump on first frame.
    _distance = global_position.distance_to(_pivot)
    # Derive initial yaw/pitch from current transform.
    var _offset: Vector3 = global_position - _pivot
    _yaw = atan2(_offset.x, _offset.z)
    _pitch = clamp(asin(_offset.y / _distance), -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
    _apply_transform()


func _unhandled_input(event: InputEvent) -> void:
    # Presentation-only camera controls; simulation does not read camera state.
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            _distance = max(min_zoom, _distance - zoom_speed)
            _apply_transform()
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            _distance = min(max_zoom, _distance + zoom_speed)
            _apply_transform()
        elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
            _dragging = true
            _drag_button = MOUSE_BUTTON_MIDDLE
            _last_mouse = event.position
        elif event.button_index == MOUSE_BUTTON_MIDDLE and not event.pressed:
            _dragging = false
        elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
            _dragging = true
            _drag_button = MOUSE_BUTTON_RIGHT
            _last_mouse = event.position
        elif event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
            _dragging = false
    elif event is InputEventMouseMotion and _dragging:
        var delta: Vector2 = event.position - _last_mouse
        _last_mouse = event.position
        if _drag_button == MOUSE_BUTTON_MIDDLE:
            # Orbit: adjust yaw and pitch around pivot.
            _yaw -= delta.x * orbit_speed
            _pitch -= delta.y * orbit_speed
            _pitch = clamp(_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
            _apply_transform()
        elif _drag_button == MOUSE_BUTTON_RIGHT:
            # Rotate in place: adjust yaw and pitch without moving position.
            _yaw -= delta.x * orbit_speed
            _pitch -= delta.y * orbit_speed
            _pitch = clamp(_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
            _apply_transform()
    elif event is InputEventKey and event.pressed:
        if event.keycode == KEY_F:
            _reset_to_default()


func _process(delta: float) -> void:
    # WASD panning moves the pivot point on the XZ plane.
    var direction: Vector3 = Vector3.ZERO
    if Input.is_action_pressed("ui_left"):
        direction.x -= 1
    if Input.is_action_pressed("ui_right"):
        direction.x += 1
    if Input.is_action_pressed("ui_up"):
        direction.z -= 1
    if Input.is_action_pressed("ui_down"):
        direction.z += 1
    if direction != Vector3.ZERO:
        # Pan in the camera's local XZ plane (ignoring pitch).
        var forward: Vector3 = Vector3(0, 0, 1).rotated(Vector3.UP, _yaw)
        var right: Vector3 = Vector3(1, 0, 0).rotated(Vector3.UP, _yaw)
        var move: Vector3 = (right * direction.x + forward * -direction.z).normalized()
        _pivot += move * pan_speed * delta
        _apply_transform()


func _apply_transform() -> void:
    # Compute camera position from pivot, distance, yaw, pitch.
    var offset := Vector3(
        sin(_yaw) * cos(_pitch) * _distance,
        sin(_pitch) * _distance,
        cos(_yaw) * cos(_pitch) * _distance
    )
    global_position = _pivot + offset
    # Look at the pivot point.
    look_at(_pivot, Vector3.UP)


func _reset_to_default() -> void:
    _pivot = _DEFAULT_PIVOT
    _distance = _DEFAULT_DISTANCE
    _yaw = _DEFAULT_YAW
    _pitch = _DEFAULT_PITCH
    _apply_transform()
