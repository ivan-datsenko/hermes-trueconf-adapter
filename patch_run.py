#!/usr/bin/env python3
"""
Insert TrueConfAdapter creation block into gateway/run.py's _create_adapter().

Usage: python3 patch_run.py <path_to_run.py>

Strategy:
1. Find _create_adapter() function
2. Find the last 'elif platform == Platform.XXX:' line
3. Find the first empty line after that elif block
4. Insert TrueConf block before the empty line
"""

import sys
import re

def patch_run_py(path):
    with open(path, 'r') as f:
        content = f.read()

    if 'TrueConfAdapter' in content:
        print("SKIP: TrueConfAdapter already in run.py")
        return False

    lines = content.split('\n')

    # Find _create_adapter function
    func_start = None
    for i, line in enumerate(lines):
        if 'def _create_adapter(' in line:
            func_start = i
            break

    if func_start is None:
        print("ERROR: _create_adapter function not found")
        sys.exit(1)

    print(f"Found _create_adapter at line {func_start}")

    # Find the last 'elif platform == Platform.XXX:' in this function
    last_elif_idx = None
    for i in range(func_start, len(lines)):
        line = lines[i]
        # Stop at next method/function definition
        if i > func_start and line.strip() and not line.startswith(' ' * 12) and line.startswith('    def '):
            break
        if 'elif platform == Platform.' in line and line.strip().startswith('elif'):
            last_elif_idx = i

    if last_elif_idx is None:
        print("ERROR: No elif platform == found in _create_adapter")
        sys.exit(1)

    print(f"Found last elif at line {last_elif_idx}: {lines[last_elif_idx].strip()}")

    # Find the first empty line after the elif block body
    insert_idx = None
    for i in range(last_elif_idx + 1, len(lines)):
        line = lines[i]
        # Stop at next method/function definition
        if i > func_start and line.strip() and not line.startswith(' ' * 12) and line.startswith('    def '):
            insert_idx = i
            break
        # Empty line after the elif body
        if line.strip() == '' and i > last_elif_idx + 1:
            insert_idx = i
            break

    if insert_idx is None:
        print("ERROR: Could not find insertion point after last elif block")
        sys.exit(1)

    print(f"Inserting TrueConf block at line {insert_idx}")

    # Get indent from the last elif line
    elif_indent = len(lines[last_elif_idx]) - len(lines[last_elif_idx].lstrip())
    indent = ' ' * elif_indent

    # Build TrueConf block
    trueconf_block = f"""{indent}elif platform == Platform.TRUECONF:
{indent}    from gateway.platforms.trueconf import TrueConfAdapter, check_trueconf_requirements
{indent}    if not check_trueconf_requirements():
{indent}        logger.warning("TrueConf: python-trueconf-bot not installed. Run: pip install python-trueconf-bot")
{indent}        return None
{indent}    return TrueConfAdapter(config)
"""

    lines.insert(insert_idx, trueconf_block)

    with open(path, 'w') as f:
        f.write('\n'.join(lines))

    print("OK: TrueConfAdapter block inserted")
    return True


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_run.py>")
        sys.exit(1)
    patch_run_py(sys.argv[1])
