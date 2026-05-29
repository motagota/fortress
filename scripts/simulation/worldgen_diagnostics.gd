class_name WorldgenDiagnostics
extends RefCounted

const ChunkedWorldStoreScript := preload("res://scripts/simulation/chunked_world_store.gd")

static func build_storage_report(projected_world) -> Dictionary:
    var store = ChunkedWorldStoreScript.new(16)
    var import_report: Dictionary = store.import_projected_world(projected_world)
    return build_storage_report_for_store(projected_world, store, import_report)

static func build_storage_report_for_store(projected_world, store, import_report: Dictionary = {}) -> Dictionary:
    if store == null:
        return {
            "valid": false,
            "reason": "chunk_store_missing",
            "summary": "Worldgen storage diagnostics failed: chunk store missing",
            "import": import_report,
            "projection_compare": {},
            "packed_validation": {},
            "store_metadata": {},
        }
    if import_report.is_empty():
        import_report = {
            "valid": true,
            "storage_model": str(store.get_metadata().get("storage_model", "")),
            "imported_cells": int(store.get_metadata().get("cell_count", 0)),
            "error_count": 0,
        }
    var projection_compare: Dictionary = store.compare_projected_world(projected_world)
    var packed_validation: Dictionary = store.validate_packed_payloads()
    var metadata: Dictionary = store.get_metadata()
    var valid: bool = bool(import_report.get("valid", false)) \
        and bool(projection_compare.get("valid", false)) \
        and bool(packed_validation.get("valid", false))
    return {
        "valid": valid,
        "summary": _summary(valid, import_report, projection_compare, packed_validation, metadata),
        "import": _sorted_dictionary(import_report.duplicate(true)),
        "projection_compare": _sorted_dictionary(projection_compare.duplicate(true)),
        "packed_validation": _sorted_dictionary(packed_validation.duplicate(true)),
        "store_metadata": _sorted_dictionary(metadata.duplicate(true)),
    }

static func format_report(report: Dictionary) -> Array[String]:
    var lines: Array[String] = []
    lines.append(str(report.get("summary", "Worldgen storage diagnostics unavailable")))
    var import_report: Dictionary = report.get("import", {})
    var projection_compare: Dictionary = report.get("projection_compare", {})
    var packed_validation: Dictionary = report.get("packed_validation", {})
    var metadata: Dictionary = report.get("store_metadata", {})
    lines.append("import valid=%s cells=%d errors=%d" % [
        str(import_report.get("valid", false)),
        int(import_report.get("imported_cells", 0)),
        int(import_report.get("error_count", 0)),
    ])
    lines.append("projection valid=%s inspected=%d mismatches=%d missing=%d extra=%d" % [
        str(projection_compare.get("valid", false)),
        int(projection_compare.get("inspected_cells", 0)),
        int(projection_compare.get("mismatch_count", 0)),
        int(projection_compare.get("missing_count", 0)),
        int(projection_compare.get("extra_count", 0)),
    ])
    lines.append("packed valid=%s inspected=%d mismatches=%d schema=%s" % [
        str(packed_validation.get("valid", false)),
        int(packed_validation.get("inspected_cells", 0)),
        int(packed_validation.get("mismatch_count", 0)),
        str(metadata.get("packed_cell_schema", "")),
    ])
    lines.append("store model=%s source=%s chunks=%d cells=%d" % [
        str(metadata.get("storage_model", "")),
        str(metadata.get("source_storage_model", "")),
        int(metadata.get("chunk_count", 0)),
        int(metadata.get("cell_count", 0)),
    ])
    return lines

static func log_report(report: Dictionary) -> void:
    for line in format_report(report):
        print("[worldgen] " + line)

static func _summary(valid: bool, import_report: Dictionary, projection_compare: Dictionary, packed_validation: Dictionary, metadata: Dictionary) -> String:
    if valid:
        return "Worldgen storage diagnostics passed: %d projected cells match %d chunk-store cells across %d chunks" % [
            int(projection_compare.get("inspected_cells", 0)),
            int(metadata.get("cell_count", 0)),
            int(metadata.get("chunk_count", 0)),
        ]
    return "Worldgen storage diagnostics failed: import_errors=%d projection_mismatches=%d packed_mismatches=%d" % [
        int(import_report.get("error_count", 0)),
        int(projection_compare.get("mismatch_count", 0)),
        int(packed_validation.get("mismatch_count", 0)),
    ]

static func _sorted_dictionary(input: Dictionary) -> Dictionary:
    var output: Dictionary = {}
    var keys: Array = input.keys()
    keys.sort()
    for key in keys:
        var value: Variant = input[key]
        if value is Dictionary:
            output[key] = _sorted_dictionary(value)
        elif value is Array:
            output[key] = _sorted_array(value)
        else:
            output[key] = value
    return output

static func _sorted_array(input: Array) -> Array:
    var output: Array = []
    for value in input:
        if value is Dictionary:
            output.append(_sorted_dictionary(value))
        elif value is Array:
            output.append(_sorted_array(value))
        else:
            output.append(value)
    return output
