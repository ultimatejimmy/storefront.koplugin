#!/usr/bin/env python3
"""
tools/verify_catalog.py

Integrity checker for KOReader Storefront catalog.json files.
Validates structure, non-empty fields, minification, and minimum entity thresholds.
Exits with 0 on success, non-zero on verification failure.
"""

import sys
import os
import json
import argparse

DEFAULT_MIN_PLUGINS = 650
DEFAULT_MIN_PATCHES = 50
DEFAULT_MIN_FONTS = 20

def verify_catalog_file(filepath, min_plugins=DEFAULT_MIN_PLUGINS, min_patches=DEFAULT_MIN_PATCHES, min_fonts=DEFAULT_MIN_FONTS):
    print(f"Verifying catalog integrity: {filepath}")
    if not os.path.isfile(filepath):
        print(f"Error: Catalog file does not exist: {filepath}", file=sys.stderr)
        return False

    file_size = os.path.getsize(filepath)
    if file_size < 1000:
        print(f"Error: Catalog file is suspiciously small ({file_size} bytes)", file=sys.stderr)
        return False

    with open(filepath, "r", encoding="utf-8") as f:
        raw_content = f.read()

    # Check minification: catalog should be exactly one line
    lines = raw_content.splitlines()
    if len(lines) > 1:
        print(f"Error: Catalog file {filepath} has {len(lines)} lines; expected exactly 1 line (minified).", file=sys.stderr)
        return False

    try:
        catalog = json.loads(raw_content)
    except Exception as e:
        print(f"Error: Failed to parse JSON in {filepath}: {e}", file=sys.stderr)
        return False

    if not isinstance(catalog, dict):
        print(f"Error: Root catalog is not a JSON object", file=sys.stderr)
        return False

    required_keys = ["version", "generated_at", "stats", "plugins", "patches", "fonts"]
    for key in required_keys:
        if key not in catalog:
            print(f"Error: Missing required top-level key '{key}' in {filepath}", file=sys.stderr)
            return False

    stats = catalog.get("stats", {})
    plugins = catalog.get("plugins", [])
    patches = catalog.get("patches", [])
    fonts = catalog.get("fonts", [])

    if not isinstance(plugins, list) or not isinstance(patches, list) or not isinstance(fonts, list):
        print(f"Error: plugins, patches, or fonts is not an array", file=sys.stderr)
        return False

    # Verify stat counts match actual lengths
    if stats.get("total_plugins") != len(plugins):
        print(f"Error: stats.total_plugins ({stats.get('total_plugins')}) != actual count ({len(plugins)})", file=sys.stderr)
        return False
    if stats.get("total_patches") != len(patches):
        print(f"Error: stats.total_patches ({stats.get('total_patches')}) != actual count ({len(patches)})", file=sys.stderr)
        return False
    if stats.get("total_fonts") != len(fonts):
        print(f"Error: stats.total_fonts ({stats.get('total_fonts')}) != actual count ({len(fonts)})", file=sys.stderr)
        return False

    # Check minimum thresholds
    if len(plugins) < min_plugins:
        print(f"Error: Plugin count {len(plugins)} is below threshold {min_plugins}!", file=sys.stderr)
        return False
    if len(patches) < min_patches:
        print(f"Error: Patch count {len(patches)} is below threshold {min_patches}!", file=sys.stderr)
        return False
    if len(fonts) < min_fonts:
        print(f"Error: Font count {len(fonts)} is below threshold {min_fonts}!", file=sys.stderr)
        return False

    # Verify item contents
    for idx, p in enumerate(plugins):
        p_name = p.get("name") or p.get("full_name") or f"index {idx}"
        if p.get("id") is None and p.get("repo_id") is None:
            print(f"Error: Plugin '{p_name}' missing repo id", file=sys.stderr)
            return False
        if "latest_release" not in p and "latest_prerelease" not in p:
            print(f"Error: Plugin '{p_name}' has neither latest_release nor latest_prerelease", file=sys.stderr)
            return False

    for idx, pt in enumerate(patches):
        pt_name = pt.get("name") or pt.get("full_name") or f"index {idx}"
        patch_files = pt.get("patch_files")
        if not patch_files or not isinstance(patch_files, list) or len(patch_files) == 0:
            print(f"Error: Patch '{pt_name}' has no patch_files", file=sys.stderr)
            return False

    for idx, f_item in enumerate(fonts):
        f_name = f_item.get("name") or f"font index {idx}"
        if not f_item.get("font_file") and not f_item.get("download_url"):
            print(f"Error: Font '{f_name}' missing font_file / download_url", file=sys.stderr)
            return False

    print(f"Passed: {filepath} is valid! ({len(plugins)} plugins, {len(patches)} patches, {len(fonts)} fonts, minified)")
    return True

def main():
    parser = argparse.ArgumentParser(description="Verify KOReader Storefront catalog integrity")
    parser.add_argument("files", nargs="*", help="Paths to catalog.json file(s) to verify")
    parser.add_argument("--min-plugins", type=int, default=DEFAULT_MIN_PLUGINS, help=f"Minimum required plugins (default {DEFAULT_MIN_PLUGINS})")
    parser.add_argument("--min-patches", type=int, default=DEFAULT_MIN_PATCHES, help=f"Minimum required patches (default {DEFAULT_MIN_PATCHES})")
    parser.add_argument("--min-fonts", type=int, default=DEFAULT_MIN_FONTS, help=f"Minimum required fonts (default {DEFAULT_MIN_FONTS})")

    args = parser.parse_args()
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    
    files_to_check = args.files
    if not files_to_check:
        outer_cat = os.path.abspath(os.path.join(script_dir, "..", "catalog.json"))
        inner_cat = os.path.abspath(os.path.join(script_dir, "..", "storefront.koplugin", "catalog.json"))
        files_to_check = [outer_cat]
        if os.path.isfile(inner_cat):
            files_to_check.append(inner_cat)

    all_ok = True
    for fp in files_to_check:
        if not verify_catalog_file(fp, min_plugins=args.min_plugins, min_patches=args.min_patches, min_fonts=args.min_fonts):
            all_ok = False

    if not all_ok:
        sys.exit(1)
    sys.exit(0)

if __name__ == "__main__":
    main()
