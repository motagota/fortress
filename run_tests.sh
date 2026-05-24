#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

find_godot() {
    if [ -n "${GODOT:-}" ]; then
        if command -v "$GODOT" >/dev/null 2>&1 || [ -f "$GODOT" ] || [ -x "$GODOT" ]; then
            printf '%s\n' "$GODOT"
            return 0
        fi
        echo "GODOT is set but not executable/found: $GODOT" >&2
        return 1
    fi

    for candidate in /d/dev/godot /d/dev/godot.exe; do
        if [ -f "$candidate" ] || [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v godot >/dev/null 2>&1; then
        command -v godot
        return 0
    fi

    if [ -f /tmp/Godot_v4.6-stable_linux.x86_64 ] || [ -x /tmp/Godot_v4.6-stable_linux.x86_64 ]; then
        printf '%s\n' /tmp/Godot_v4.6-stable_linux.x86_64
        return 0
    fi

    if command -v godot4 >/dev/null 2>&1; then
        command -v godot4
        return 0
    fi

    return 1
}

echo "Project root: $PROJECT_ROOT"
echo "Running static project checks..."
python tests/static_project_checks.py

if ! GODOT_BIN="$(find_godot)"; then
    echo "Godot not found. Set GODOT=/path/to/godot, install godot on PATH, or place it at /d/dev/godot or /tmp/Godot_v4.6-stable_linux.x86_64." >&2
    exit 1
fi

echo "Running Godot headless tests with: $GODOT_BIN"
set +e
"$GODOT_BIN" --headless --path "$PROJECT_ROOT" --script res://tests/run_godot_tests.gd 2>&1
godot_status=$?
set -e

echo "Godot EXIT: $godot_status"
exit "$godot_status"
