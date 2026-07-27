#!/usr/bin/env python3
"""
Syncs the CORE_KOREADER_PLUGINS set in storefront.koplugin/main.lua
with the official KOReader repository's plugins directory on GitHub.

Usage:
    python tools/sync_core_plugins.py          # Check diff
    python tools/sync_core_plugins.py --apply  # Update main.lua in-place
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

GITHUB_API_URL = "https://api.github.com/repos/koreader/koreader/contents/plugins"
MAIN_LUA_PATH = Path(__file__).resolve().parent.parent / "storefront.koplugin" / "main.lua"

def fetch_core_plugins():
    req = urllib.request.Request(
        GITHUB_API_URL,
        headers={"User-Agent": "Storefront-Sync-Tool"}
    )
    with urllib.request.urlopen(req) as resp:
        if resp.status != 200:
            raise RuntimeError(f"GitHub API returned HTTP {resp.status}")
        data = json.loads(resp.read().decode("utf-8"))

    plugins = set()
    for item in data:
        name = item.get("name", "")
        if item.get("type") == "dir" and name.lower().endswith(".koplugin"):
            plugins.add(name.lower())
    return sorted(list(plugins))

def format_lua_table(plugins):
    lines = ["local CORE_KOREADER_PLUGINS = {"]
    for p in plugins:
        lines.append(f'    ["{p}"] = true,')
    lines.append("}")
    return "\n".join(lines)

def main():
    apply_changes = "--apply" in sys.argv

    if not MAIN_LUA_PATH.exists():
        print(f"Error: Could not find main.lua at {MAIN_LUA_PATH}")
        sys.exit(1)

    print("Fetching KOReader core plugins from GitHub...")
    try:
        remote_plugins = fetch_core_plugins()
    except Exception as e:
        print(f"Failed to fetch plugins from GitHub: {e}")
        sys.exit(1)

    content = MAIN_LUA_PATH.read_text(encoding="utf-8")
    match = re.search(r"local CORE_KOREADER_PLUGINS = \{.*?\n\}", content, re.DOTALL)
    if not match:
        print("Error: CORE_KOREADER_PLUGINS pattern not found in main.lua")
        sys.exit(1)

    old_block = match.group(0)
    new_block = format_lua_table(remote_plugins)

    if old_block == new_block:
        print("CORE_KOREADER_PLUGINS is already up-to-date with KOReader master!")
        sys.exit(0)

    print("\nDifferences found:")
    print("--- Current main.lua")
    print("+++ GitHub KOReader master")
    old_set = set(re.findall(r'\["(.*?)"\]', old_block))
    new_set = set(remote_plugins)

    added = new_set - old_set
    removed = old_set - new_set

    if added:
        print(f"  + Added: {', '.join(sorted(added))}")
    if removed:
        print(f"  - Removed: {', '.join(sorted(removed))}")

    if apply_changes:
        updated_content = content[:match.start()] + new_block + content[match.end():]
        MAIN_LUA_PATH.write_text(updated_content, encoding="utf-8")
        print(f"\nSuccessfully updated {MAIN_LUA_PATH}")
    else:
        print("\nRun with --apply to apply these changes to main.lua.")

if __name__ == "__main__":
    main()
