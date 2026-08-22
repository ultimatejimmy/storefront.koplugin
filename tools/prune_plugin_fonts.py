#!/usr/bin/env python3
"""
tools/prune_plugin_fonts.py

Prunes inner storefront.koplugin/assets/fonts/ directory so that it contains
ONLY the single regular preview font file per font family.
All full font family weights remain intact in repo root assets/fonts/.
"""

import os
import sys

# Map of font family directory name to the exact single regular font file to keep
REGULAR_FONTS_TO_KEEP = {
    "Atkinson Hyperlegible": "AtkinsonHyperlegible-Regular.ttf",
    "Bitter": "NV_Bitter-Regular.ttf",
    "Cartisse": "Cartisse-Regular.ttf",
    "Fast Sans": "Fast_Sans.otf",
    "Fast Sans Dotted": "Fast_Sans_Dotted.otf",
    "Fast Serif": "Fast_Serif.otf",
    "Gentium Plus": "GentiumBookPlus-Regular.ttf",
    "Lexend": "Lexend_Regular.ttf",
    "Libron": "Libron-Regular.ttf",
    "Libre Baskerville": "LibreBaskerville-Regular.ttf",
    "Literata": "NV_Literata-Regular.ttf",
    "Lora": "Lora_Regular.ttf",
    "Merriweather": "Merriweather-Regular.ttf",
    "Merriweather Sans": "MerriweatherSans-Regular.ttf",
    "NV Charis": "NV_Charis-Regular.ttf",
    "NV Garamond": "NV_Garamond-Regular.ttf",
    "NV Jost": "NV_Jost-Regular.ttf",
    "NV Newsreader": "NV_Newsreader-Regular.ttf",
    "OpenDyslexic": "OpenDyslexic_Regular.otf",
    "Readerly": "Readerly-Regular.ttf",
    "Sourcerer": "Sourcerer-Regular.ttf",
}

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    repo_root = os.path.abspath(os.path.join(script_dir, ".."))
    plugin_fonts_dir = os.path.join(repo_root, "storefront.koplugin", "assets", "fonts")

    if not os.path.exists(plugin_fonts_dir):
        print(f"Directory not found: {plugin_fonts_dir}")
        return

    pruned_count = 0
    for font_dir_name in os.listdir(plugin_fonts_dir):
        font_dir = os.path.join(plugin_fonts_dir, font_dir_name)
        if os.path.isdir(font_dir):
            keep_file = REGULAR_FONTS_TO_KEEP.get(font_dir_name)
            for file in os.listdir(font_dir):
                file_path = os.path.join(font_dir, file)
                if os.path.isfile(file_path):
                    if keep_file and file != keep_file:
                        try:
                            os.remove(file_path)
                            print(f"Pruned extra file from inner plugin: {font_dir_name}/{file}")
                            pruned_count += 1
                        except Exception as e:
                            print(f"Error removing {file_path}: {e}")

    print(f"Pruned {pruned_count} extra font files from inner plugin directory.")

if __name__ == "__main__":
    main()
