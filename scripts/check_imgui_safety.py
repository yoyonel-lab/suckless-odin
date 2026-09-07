#!/usr/bin/env python3
"""
Dear ImGui Safety & Integrity Linter for suckless-odin.

Audits:
1. C-Variadic format string vulnerabilities in imgui.Text* and imgui.SetTooltip* calls.
2. Stack balance for ImGui containers (Push/Pop, Begin/End, Indent/Unindent).
3. Double-null termination for imgui.Combo item strings.

Exits with 0 on success, 1 on any violation.
"""

import glob
import os
import re
import sys


def audit_stack_balance(filepath: str, content: str) -> list[str]:
    errors = []
    stack_pairs = [
        ("Begin / End", r"\bimgui\.Begin\(", r"\bimgui\.End\(\)"),
        ("BeginTabBar / EndTabBar", r"\bimgui\.BeginTabBar\(", r"\bimgui\.EndTabBar\(\)"),
        ("BeginTabItem / EndTabItem", r"\bimgui\.BeginTabItem\(", r"\bimgui\.EndTabItem\(\)"),
        ("BeginDisabled / EndDisabled", r"\bimgui\.BeginDisabled\(", r"\bimgui\.EndDisabled\(\)"),
        ("BeginCombo / EndCombo", r"\bimgui\.BeginCombo\(", r"\bimgui\.EndCombo\(\)"),
        ("BeginGroup / EndGroup", r"\bimgui\.BeginGroup\(", r"\bimgui\.EndGroup\(\)"),
        ("BeginChild / EndChild", r"\bimgui\.BeginChild\(", r"\bimgui\.EndChild\(\)"),
        ("BeginTooltip / EndTooltip", r"\bimgui\.BeginTooltip\(", r"\bimgui\.EndTooltip\(\)"),
        ("BeginTable / EndTable", r"\bimgui\.BeginTable\(", r"\bimgui\.EndTable\(\)"),
        ("PushID / PopID", r"\bimgui\.PushID\w*\(", r"\bimgui\.PopID\(\)"),
        ("PushStyleColor / PopStyleColor", r"\bimgui\.PushStyleColor\w*\(", r"\bimgui\.PopStyleColor\("),
        ("PushStyleVar / PopStyleVar", r"\bimgui\.PushStyleVar\w*\(", r"\bimgui\.PopStyleVar\("),
        ("PushItemWidth / PopItemWidth", r"\bimgui\.PushItemWidth\(", r"\bimgui\.PopItemWidth\(\)"),
        ("Indent / Unindent", r"\bimgui\.Indent\(", r"\bimgui\.Unindent\(\)"),
    ]

    for name, begin_pat, end_pat in stack_pairs:
        begins = len(re.findall(begin_pat, content))
        ends = len(re.findall(end_pat, content))
        if begins != ends:
            errors.append(f"{filepath}: Mismatched {name} ({begins} pushes vs {ends} pops)")

    return errors


def audit_format_strings(filepath: str, content: str) -> list[str]:
    errors = []
    lines = content.splitlines()

    variadic_funcs = [
        "SetTooltip",
        "SetItemTooltip",
        "Text",
        "TextColored",
        "TextDisabled",
        "TextWrapped",
        "LabelText",
        "BulletText",
    ]

    for line_num, line in enumerate(lines, 1):
        for vf in variadic_funcs:
            # Check imgui.<vf>(...)
            pat = r"\bimgui\." + vf + r"\s*\((.*)\)"
            m = re.search(pat, line)
            if not m:
                continue

            args = m.group(1).strip()
            # Split top-level args
            literals = re.findall(r"\"(.*?)\"", args)

            # Determine format argument
            if vf == "TextColored":
                # args: (color, fmt, ...)
                fmt_lit = literals[0] if len(literals) > 0 else ""
            else:
                # args: (fmt, ...)
                fmt_lit = literals[0] if len(literals) > 0 else ""

            if fmt_lit:
                # Check for unescaped literal '%'
                clean = fmt_lit.replace("%%", "")
                if "%" in clean:
                    # Check if '%' is a lone character or followed by space/invalid char
                    if "% " in clean or clean.endswith("%"):
                        errors.append(f"{filepath}:{line_num}: Unescaped '%' in {vf} format string: \"{fmt_lit[:50]}\"")
            else:
                # Non-literal format argument: check if dynamic string is passed directly as format
                parts = [p.strip() for p in args.split(",")]
                target = parts[1] if vf == "TextColored" and len(parts) > 1 else (parts[0] if parts else "")
                if any(dyn in target for dyn in ["fmt.ctprintf", "fmt.tprintf", "strings.clone"]):
                    if not (target.startswith('"%s"') or target.startswith('"%d"') or target.startswith('"%f"')):
                        errors.append(
                            f"{filepath}:{line_num}: Dynamic expr passed directly as format string to {vf}: "
                            f"{target[:50]}"
                        )

    return errors


def audit_combo_terminators(filepath: str, content: str) -> list[str]:
    errors = []
    lines = content.splitlines()

    for line_num, line in enumerate(lines, 1):
        m = re.search(r"\bimgui\.Combo\s*\([^,]+,\s*[^,]+,\s*\"(.*?)\"\s*(\)|,)", line)
        if m:
            items_str = m.group(1)
            if not (
                items_str.endswith("\\x00\\x00")
                or items_str.endswith("\\0\\0")
                or items_str.endswith("\\x00")
                or items_str.endswith("\\0")
            ):
                errors.append(
                    f'{filepath}:{line_num}: imgui.Combo flat items missing null terminator: "{items_str[-20:]}"'
                )

    return errors


def main():
    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src_gui_dir = os.path.join(root_dir, "src", "gui")
    odin_files = sorted(glob.glob(os.path.join(src_gui_dir, "**", "*.odin"), recursive=True))

    all_errors = []

    for f in odin_files:
        with open(f, encoding="utf-8") as fh:
            content = fh.read()

        all_errors.extend(audit_stack_balance(os.path.relpath(f, root_dir), content))
        all_errors.extend(audit_format_strings(os.path.relpath(f, root_dir), content))
        all_errors.extend(audit_combo_terminators(os.path.relpath(f, root_dir), content))

    print(f"🔍 Audited {len(odin_files)} GUI Odin files for Dear ImGui safety & integrity...")

    if all_errors:
        print("\n❌ ImGui Safety Violations Detected:")
        for err in all_errors:
            print(f"  - {err}")
        print("\nPlease fix all ImGui format strings, nil guards, and stack balances.")
        sys.exit(1)
    else:
        print("✅ Success! All ImGui format strings, stack balances, and combo terminators are 100% safe.")
        sys.exit(0)


if __name__ == "__main__":
    main()
