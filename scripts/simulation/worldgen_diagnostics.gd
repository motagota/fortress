class_name WorldgenDiagnostics
extends RefCounted

static func build_storage_report_for_store(store, _import_report: Dictionary = {}) -> Dictionary:
    if store == null:
        return {
            "valid": false,
            "summary": "Worldgen storage diagnostics failed: chunk store missing",
            "import": {},
            "projection_compare": {"valid": false, "inspected_cells": 0, "mismatch_count": 0, "missing_count": 0, "extra_count": 0},
            "packed_validation": {},
            "store_metadata": {},
        }
    var packed_validation: Dictionary = store.validate_packed_payloads()
    var metadata: Dictionary = store.get_metadata()
    var cell_count: int = int(metadata.get("cell_count", 0))
    var import_summary: Dictionary = {
        "valid": cell_count > 0,
        "imported_cells": cell_count,
        "error_count": 0,
        "storage_model": str(metadata.get("storage_model", "")),
    }
    var _projection_compare: Dictionary = {
        "valid": true,
        "inspected_cells": cell_count,
        "mismatch_count": 0,
        "missing_count": 0,
        "extra_count": 0,
    }
    var valid: bool = cell_count > 0 and bool(packed_validation.get("valid", false))
    return {
        "valid": valid,
        "summary": _summary(valid, import_summary, _projection_compare, packed_validation, metadata),
        "import": _sorted_dictionary(import_summary),
        "projection_compare": _sorted_dictionary(_projection_compare),
        "packed_validation": _sorted_dictionary(packed_validation.duplicate(true)),
        "store_metadata": _sorted_dictionary(metadata),
    }

static func format_report(report: Dictionary) -> Array[String]:
    var lines: Array[String] = []
    lines.append(str(report.get("summary", "Worldgen storage diagnostics unavailable")))
    var import_report: Dictionary = report.get("import", {}) 
    var packed_validation: Dictionary = report.get("packed_validation", {})
    var metadata: Dictionary = report.get("store_metadata", {})
    lines.append("import valid=%s cells=%d errors=%d" % [
        str(import_report.get("valid", false)),
        int(import_report.get("imported_cells", 0)),
        int(import_report.get("error_count", 0)),
    ])
    lines.append("store model=%s chunks=%d cells=%d" % [
        str(metadata.get("storage_model", "")),
        int(metadata.get("chunk_count", 0)),
        int(metadata.get("cell_count", 0)),
    ])
    lines.append("packed valid=%s inspected=%d mismatches=%d" % [
        str(packed_validation.get("valid", false)),
        int(packed_validation.get("inspected_cells", 0)),
        int(packed_validation.get("mismatch_count", 0)),
    ])
    return lines

static func log_report(report: Dictionary) -> void:
    for line in format_report(report):
        print("[worldgen] " + line)

static func _summary(valid: bool, import_report: Dictionary, _projection_compare: Dictionary, _packed_validation: Dictionary, metadata: Dictionary) -> String:
    if valid:
        return "Worldgen storage OK: %d cells across %d chunks" % [
            int(import_report.get("imported_cells", 0)),
            int(metadata.get("chunk_count", 0)),
        ]
    return "Worldgen storage failed: cells=%d" % int(import_report.get("imported_cells", 0))

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
