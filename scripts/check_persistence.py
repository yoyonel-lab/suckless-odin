#!/usr/bin/env python3
import os
import re
import sys

# Paths to source files
GUI_FILE = "src/gui/gui.odin"
SESSION_DEF_FILE = "src/core/session/session.odin"
SESSION_APP_FILE = "src/app/session.odin"
TEST_FILE = "tests/test_session.odin"

# Fields in Scene_State that are NOT intended to be persisted directly (non-interactive or complex lifecycle)
EXCLUDED_GUI_FIELDS = {
    "camera",  # Handled globally via individual fields (camera_pos, camera_yaw, etc.)
    "cubemap_dirty",  # Dirty flag trigger, transient
    "postfx",  # Handled via postfx_active and postfx_settings
    "perf",  # Handled via perf_mode_active
    "live_compute_tuning",  # Temporary runtime tuning parameters
    "point_light",  # Handled via volumetric/light settings subsystem
    "shadow_cubemap",  # Transient GPU framebuffer resource
}

# Fields in Session_State that are handled directly in app initialization rather than restore_session_state
EXCLUDED_RESTORE_FIELDS = {
    "window_pos",
    "window_size",
    "perf_mode_active",
}

# Mapping between Scene_State field name and Session_State field name if they differ
FIELD_MAPPING = {
    "show_mipmap_diff": "show_blur_diff",
    "specular_aa_enabled": "specular_aa",
    "specular_aa_mode": "specular_aa",
    "specular_aa_debug_mode": "specular_aa",
    "specular_aa_split_enabled": "specular_aa",
    "specular_aa_split_position": "specular_aa",
}


def extract_gui_fields(filepath):
    """Extracts fields of type pointer (e.g., ^bool, ^f32) from Scene_State :: struct"""
    with open(filepath) as f:
        content = f.read()

    # Locate Scene_State :: struct { ... }
    match = re.search(r"Scene_State\s*::\s*struct\s*\{(.*?)\n\}", content, re.DOTALL)
    if not match:
        print(f"Error: Could not locate Scene_State struct in {filepath}")
        sys.exit(1)

    struct_body = match.group(1)
    fields = []

    for line in struct_body.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        # Clean trailing comments
        line = line.split("//")[0].strip()
        if ":" not in line:
            continue

        name, type_part = line.split(":", 1)
        name = name.strip()
        type_part = type_part.strip()

        # If the type is a pointer, it represents mutable UI state
        if type_part.startswith("^"):
            if name not in EXCLUDED_GUI_FIELDS:
                fields.append((name, type_part))

    return fields


def extract_session_fields(filepath):
    """Extracts all fields from Session_State :: struct"""
    with open(filepath) as f:
        content = f.read()

    match = re.search(r"Session_State\s*::\s*struct\s*\{(.*?)\n\}", content, re.DOTALL)
    if not match:
        print(f"Error: Could not locate Session_State struct in {filepath}")
        sys.exit(1)

    struct_body = match.group(1)
    fields = set()

    for line in struct_body.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        line = line.split("//")[0].strip()
        if ":" not in line:
            continue

        name = line.split(":")[0].strip()
        fields.add(name)

    return fields


def extract_function_body(content, func_name):
    """Extracts the body of a procedure from its declaration to the end of block"""
    # Simple brace counting or finding procedure boundary
    pattern = rf"{func_name}\s*::\s*proc\s*\(.*?\)(?:\s*->\s*[^\s{{]+)?\s*\{{"
    match = re.search(pattern, content)
    if not match:
        return None

    start_idx = match.end()
    brace_count = 1
    i = start_idx
    while i < len(content) and brace_count > 0:
        if content[i] == "{":
            brace_count += 1
        elif content[i] == "}":
            brace_count -= 1
        i += 1

    return content[start_idx : i - 1]


def check_session_app_functions(filepath, session_fields):
    """Verifies that all Session_State fields are used in extract_session_state and restore_session_state"""
    with open(filepath) as f:
        content = f.read()

    extract_body = extract_function_body(content, "extract_session_state")
    restore_body = extract_function_body(content, "restore_session_state")

    if not extract_body:
        print("Error: Could not locate extract_session_state body")
        sys.exit(1)
    if not restore_body:
        print("Error: Could not locate restore_session_state body")
        sys.exit(1)

    missing_extract = []
    missing_restore = []

    for field in session_fields:
        # Check in extract_session_state: should assign the field (e.g. "field = " or "field =")
        # Or at least reference the field name
        if field not in extract_body:
            missing_extract.append(field)

        # Check in restore_session_state: should reference state.field
        # Using state.field or pfx.field etc.
        if field not in EXCLUDED_RESTORE_FIELDS:
            # Special case: camera fields are combined into s.camera.position etc.
            # but let's check if they are referenced at all
            if field not in restore_body and f"state.{field}" not in restore_body:
                missing_restore.append(field)

    return missing_extract, missing_restore


def check_tests(filepath, session_fields):
    """Verifies that all Session_State fields are tested in tests/test_session.odin"""
    with open(filepath) as f:
        content = f.read()

    missing_tests = []
    for field in session_fields:
        # The field should be referenced in the test file (checking/saving/loading)
        if field not in content:
            missing_tests.append(field)

    return missing_tests


def main():
    print("=== Persistence Coverage and Consistency Check ===")

    # Check if files exist (run from repo root)
    for path in [GUI_FILE, SESSION_DEF_FILE, SESSION_APP_FILE, TEST_FILE]:
        if not os.path.exists(path):
            print(f"Error: Required file {path} not found. Make sure you run from the project root.")
            sys.exit(1)

    # 1. Extract interactive UI fields from Scene_State
    gui_fields = extract_gui_fields(GUI_FILE)
    print(f"Found {len(gui_fields)} interactive GUI fields in {GUI_FILE}.")

    # 2. Extract Session_State fields
    session_fields = extract_session_fields(SESSION_DEF_FILE)
    print(f"Found {len(session_fields)} persisted fields in {SESSION_DEF_FILE}.")

    # 3. Check that every interactive GUI field is mapped to a Session_State field
    unmapped_gui_fields = []
    for gui_name, _ in gui_fields:
        expected_session_name = FIELD_MAPPING.get(gui_name, gui_name)
        if expected_session_name not in session_fields:
            unmapped_gui_fields.append((gui_name, expected_session_name))

    # 4. Check extract/restore coverage
    missing_extract, missing_restore = check_session_app_functions(SESSION_APP_FILE, session_fields)

    # 5. Check test coverage
    missing_tests = check_tests(TEST_FILE, session_fields)

    # Print results and report errors
    has_errors = False

    if unmapped_gui_fields:
        print("\n[ERROR] The following interactive UI fields in Scene_State are not mapped to Session_State:")
        for gui_name, expected in unmapped_gui_fields:
            print(f"  - {gui_name} (expected session field: '{expected}')")
        has_errors = True
    else:
        print("\n[OK] All interactive UI fields are mapped to Session_State.")

    if missing_extract:
        print("\n[ERROR] The following Session_State fields are missing from extract_session_state:")
        for field in missing_extract:
            print(f"  - {field}")
        has_errors = True
    else:
        print("[OK] All Session_State fields are extracted.")

    if missing_restore:
        # Filter out special exceptions if any, but none currently.
        print("\n[ERROR] The following Session_State fields are missing from restore_session_state:")
        for field in missing_restore:
            print(f"  - {field}")
        has_errors = True
    else:
        print("[OK] All Session_State fields are restored.")

    if missing_tests:
        print("\n[ERROR] The following Session_State fields are not tested in tests/test_session.odin:")
        for field in missing_tests:
            print(f"  - {field}")
        has_errors = True
    else:
        print("[OK] All Session_State fields are covered by tests.")

    if has_errors:
        print("\n=== Persistence Validation: FAILED ===")
        sys.exit(1)
    else:
        print("\n=== Persistence Validation: SUCCESS ===")
        sys.exit(0)


if __name__ == "__main__":
    main()
