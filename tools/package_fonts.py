#!/usr/bin/env python3
"""
tools/package_fonts.py

Packages static font files from assets/fonts/ into .zip archives in the fonts/ output directory.
Updates catalog.json to point to the new GitHub Pages URLs.
Run this script during the GitHub Actions deployment workflow.
"""

import os
import sys
import json
import zipfile

GITHUB_PAGES_BASE_URL = "https://ultimatejimmy.github.io/storefront.koplugin"

def main():
    print("=== KOReader Storefront Font Packager ===")
    
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    repo_root = os.path.abspath(os.path.join(script_dir, ".."))
    
    assets_fonts_dir = os.path.join(repo_root, "assets", "fonts")
    output_fonts_dir = os.path.join(repo_root, "fonts")
    catalog_path = os.path.join(repo_root, "catalog.json")
    
    if not os.path.exists(assets_fonts_dir):
        print(f"Error: Assets fonts directory not found at {assets_fonts_dir}")
        sys.exit(1)
        
    # Create output directory
    os.makedirs(output_fonts_dir, exist_ok=True)
    
    # 1. Zip each font folder
    print(f"Packaging fonts from {assets_fonts_dir} to {output_fonts_dir}...")
    font_zips = {}
    
    for item in os.listdir(assets_fonts_dir):
        item_path = os.path.join(assets_fonts_dir, item)
        if os.path.isdir(item_path):
            safe_name = item.replace(" ", "-")
            zip_filename = f"{safe_name}.zip"
            zip_path = os.path.join(output_fonts_dir, zip_filename)
            
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                for root, _, files in os.walk(item_path):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.relpath(file_path, item_path)
                        zipf.write(file_path, arcname)
                        
            print(f"  Created {zip_filename}")
            # Map the exact directory name (font family name) to its URL
            font_zips[item.lower()] = f"{GITHUB_PAGES_BASE_URL}/fonts/{zip_filename}"

    # 2. Update catalog.json download_url properties
    if not os.path.exists(catalog_path):
        print("Warning: catalog.json not found. Skipping URL updates.")
        return
        
    print(f"Updating download_url for fonts in {catalog_path}...")
    try:
        with open(catalog_path, "r", encoding="utf-8") as f:
            catalog = json.load(f)
            
        if "fonts" in catalog:
            updated = 0
            for font in catalog["fonts"]:
                # Try matching by font name or repo name
                key1 = font.get("name", "").lower()
                key2 = font.get("font_family", "").lower()
                
                # Check for exact matches to directory names
                url = font_zips.get(key1) or font_zips.get(key2)
                
                # Loose matching if exact fails (e.g. "Atkinson Hyperlegible" vs "atkinsonhyperlegible")
                if not url:
                    for k, v in font_zips.items():
                        if k.replace(" ", "").replace("-", "") == key1.replace(" ", "").replace("-", ""):
                            url = v
                            break
                            
                if url:
                    font["download_url"] = url
                    updated += 1
                else:
                    print(f"  Warning: Could not find matching zip for font: {font.get('name')}")
                    
            print(f"  Updated URLs for {updated} fonts.")
            
        with open(catalog_path, "w", encoding="utf-8") as f:
            json.dump(catalog, f, indent=2, ensure_ascii=False)
            
    except Exception as e:
        print(f"Error updating catalog.json: {e}")

if __name__ == "__main__":
    main()
