extends RefCounted

const MainScript := preload("res://scripts/main.gd")
const GameHudScene := preload("res://scenes/ui/GameHud.tscn")

func _assert(cond: bool, message: String) -> bool:
    if not cond:
        push_error(message)
        return false
    return true

func _test_main_starts_in_inspect_mode() -> bool:
    var main := MainScript.new()
    var ok := _assert(main.active_tool_mode == "inspect", "main must default to inspect tool mode")
    main.free()
    return ok

func _test_main_accepts_only_known_tool_modes() -> bool:
    var ok := true
    var main := MainScript.new()
    ok = _assert(main.set_active_tool_mode("gather_wood"), "gather_wood must be an accepted tool mode") and ok
    ok = _assert(main.active_tool_mode == "gather_wood", "main must switch to gather_wood") and ok
    ok = _assert(not main.set_active_tool_mode("paint_castle"), "unknown tool modes must be rejected") and ok
    ok = _assert(main.active_tool_mode == "gather_wood", "rejected tool mode must not change active mode") and ok
    main.free()
    return ok

func _test_keyboard_shortcuts_select_tool_modes() -> bool:
    var ok := true
    var main := MainScript.new()
    var key_to_mode := {
        KEY_1: "inspect",
        KEY_2: "gather_wood",
        KEY_3: "gather_stone",
        KEY_4: "gather_food",
    }
    for key_code in key_to_mode.keys():
        var event := InputEventKey.new()
        event.keycode = key_code
        event.pressed = true
        event.echo = false
        main._unhandled_input(event)
        ok = _assert(main.active_tool_mode == key_to_mode[key_code], "key %s must select %s, got %s" % [key_code, key_to_mode[key_code], main.active_tool_mode]) and ok
    main.free()
    return ok

func _test_hud_tool_buttons_emit_modes_and_update_status() -> bool:
    var ok := true
    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var modes_seen: Array[String] = []
    hud.tool_mode_requested.connect(func(mode: String) -> void:
        modes_seen.append(mode)
    )

    var expected := {
        "InspectButton": "inspect",
        "GatherWoodButton": "gather_wood",
        "GatherStoneButton": "gather_stone",
        "GatherFoodButton": "gather_food",
    }
    for button_name in expected.keys():
        var button := hud.get_node("Panel/%s" % button_name) as Button
        ok = _assert(button != null, "HUD must include %s" % button_name) and ok
        if button != null:
            button.pressed.emit()
            ok = _assert(hud.active_tool_mode == expected[button_name], "%s must make HUD active mode %s" % [button_name, expected[button_name]]) and ok
            ok = _assert(modes_seen.has(expected[button_name]), "%s must emit %s" % [button_name, expected[button_name]]) and ok

    var label := hud.get_node("Panel/StatusLabel") as Label
    ok = _assert(label.text.contains("Tool Gather Food"), "status text must show selected tool mode, got: %s" % label.text) and ok
    hud.get_parent().remove_child(hud)
    hud.free()
    return ok

func run() -> bool:
    var ok := true
    ok = _test_main_starts_in_inspect_mode() and ok
    ok = _test_main_accepts_only_known_tool_modes() and ok
    ok = _test_keyboard_shortcuts_select_tool_modes() and ok
    ok = _test_hud_tool_buttons_emit_modes_and_update_status() and ok
    return ok
