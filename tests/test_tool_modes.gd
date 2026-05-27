extends RefCounted

const MainScript := preload("res://scripts/main.gd")
const GameHudScene := preload("res://scenes/ui/GameHud.tscn")
const SimulationScript := preload("res://scripts/simulation/simulation.gd")
const SimJobScript := preload("res://scripts/simulation/job.gd")

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
    ok = _assert(main.set_active_tool_mode("mine"), "mine must be an accepted tool mode") and ok
    ok = _assert(main.active_tool_mode == "mine", "main must switch to mine") and ok
    ok = _assert(not main.set_active_tool_mode("paint_castle"), "unknown tool modes must be rejected") and ok
    ok = _assert(main.active_tool_mode == "mine", "rejected tool mode must not change active mode") and ok
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
        KEY_5: "mine",
        KEY_6: "designate_stockpile",
        KEY_7: "place_kitchen",
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

func _test_j_key_toggles_jobs_panel() -> bool:
    var ok := true
    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var main := MainScript.new()
    main.hud = hud
    var event := InputEventKey.new()
    event.keycode = KEY_J
    event.pressed = true
    event.echo = false

    main._unhandled_input(event)
    ok = _assert(hud.jobs_panel_visible, "J should show the jobs panel") and ok
    ok = _assert(hud.get_node("JobsPanel").visible, "jobs panel node should be visible after pressing J") and ok
    main._unhandled_input(event)
    ok = _assert(not hud.jobs_panel_visible, "pressing J again should hide the jobs panel") and ok

    hud.get_parent().remove_child(hud)
    hud.free()
    main.free()
    return ok

func _test_w_key_toggles_workers_panel() -> bool:
    var ok := true
    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var main := MainScript.new()
    main.hud = hud
    var event := InputEventKey.new()
    event.keycode = KEY_W
    event.pressed = true
    event.echo = false

    main._unhandled_input(event)
    ok = _assert(hud.workers_panel_visible, "W should show the workers panel") and ok
    ok = _assert(hud.get_node("WorkersPanel").visible, "workers panel node should be visible after pressing W") and ok
    main._unhandled_input(event)
    ok = _assert(not hud.workers_panel_visible, "pressing W again should hide the workers panel") and ok

    hud.get_parent().remove_child(hud)
    hud.free()
    main.free()
    return ok

func _test_hud_jobs_panel_lists_simulation_jobs() -> bool:
    var ok := true
    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var sim = SimulationScript.new()
    sim.initialize_new_game(601)
    sim.job_board.add_job(SimJobScript.new("job_manual_food", "GATHER_FOOD", Vector2i(4, 5), 7))
    hud.set_jobs_panel_visible(true)
    hud.sync_from_simulation(sim)

    var jobs_label := hud.get_node("JobsPanel/JobsListLabel") as Label
    ok = _assert(jobs_label.text.contains("job_manual_food"), "jobs panel should list job ids, got: %s" % jobs_label.text) and ok
    ok = _assert(jobs_label.text.contains("GATHER_FOOD"), "jobs panel should list job types, got: %s" % jobs_label.text) and ok
    ok = _assert(jobs_label.text.contains("(4,5)"), "jobs panel should list target cells, got: %s" % jobs_label.text) and ok

    hud.get_parent().remove_child(hud)
    hud.free()
    return ok

func _test_hud_workers_panel_lists_simulation_workers() -> bool:
    var ok := true
    var hud: CanvasLayer = GameHudScene.instantiate()
    Engine.get_main_loop().root.add_child(hud)
    if not hud.is_node_ready():
        hud._ready()

    var sim = SimulationScript.new()
    sim.initialize_new_game(602)
    hud.set_workers_panel_visible(true)
    hud.sync_from_simulation(sim)

    var workers_list := hud.get_node("WorkersPanel/WorkersList") as ItemList
    var detail_label := hud.get_node("WorkersPanel/WorkerDetailLabel") as Label
    ok = _assert(workers_list.get_item_count() == 3, "workers panel should list every worker") and ok
    ok = _assert(workers_list.get_item_text(0).contains("Ari"), "workers panel should list worker names, got: %s" % workers_list.get_item_text(0)) and ok
    ok = _assert(workers_list.get_item_text(0).contains("idle"), "workers panel should list worker states, got: %s" % workers_list.get_item_text(0)) and ok
    ok = _assert(workers_list.get_item_text(0).contains("(1,1)"), "workers panel should list worker positions, got: %s" % workers_list.get_item_text(0)) and ok
    ok = _assert(workers_list.get_item_text(0).contains("H0 E100"), "workers panel should list worker needs, got: %s" % workers_list.get_item_text(0)) and ok

    workers_list.select(0)
    workers_list.item_selected.emit(0)
    ok = _assert(detail_label.text.contains("Ari (unit_000001)"), "worker detail should show the selected worker identity, got: %s" % detail_label.text) and ok
    ok = _assert(detail_label.text.contains("Current job: None"), "worker detail should show the current job, got: %s" % detail_label.text) and ok
    ok = _assert(detail_label.text.contains("Needs: Hunger 0 | Energy 100 | Morale 50"), "worker detail should show worker needs, got: %s" % detail_label.text) and ok
    ok = _assert(detail_label.text.contains("Allowed jobs:"), "worker detail should show allowed jobs, got: %s" % detail_label.text) and ok

    hud.get_parent().remove_child(hud)
    hud.free()
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
        "MineButton": "mine",
        "StockpileButton": "designate_stockpile",
        "KitchenButton": "place_kitchen",
    }
    for button_name in expected.keys():
        var button := hud.get_node("Panel/%s" % button_name) as Button
        ok = _assert(button != null, "HUD must include %s" % button_name) and ok
        if button != null:
            button.pressed.emit()
            ok = _assert(hud.active_tool_mode == expected[button_name], "%s must make HUD active mode %s" % [button_name, expected[button_name]]) and ok
            ok = _assert(modes_seen.has(expected[button_name]), "%s must emit %s" % [button_name, expected[button_name]]) and ok

    var label := hud.get_node("Panel/StatusLabel") as Label
    hud.set_active_tool_mode("gather_food")
    ok = _assert(label.text.contains("Tool Gather Food"), "status text must show selected tool mode, got: %s" % label.text) and ok
    hud.get_parent().remove_child(hud)
    hud.free()
    return ok

func run() -> bool:
    var ok := true
    ok = _test_main_starts_in_inspect_mode() and ok
    ok = _test_main_accepts_only_known_tool_modes() and ok
    ok = _test_keyboard_shortcuts_select_tool_modes() and ok
    ok = _test_j_key_toggles_jobs_panel() and ok
    ok = _test_w_key_toggles_workers_panel() and ok
    ok = _test_hud_tool_buttons_emit_modes_and_update_status() and ok
    ok = _test_hud_jobs_panel_lists_simulation_jobs() and ok
    ok = _test_hud_workers_panel_lists_simulation_workers() and ok
    return ok
