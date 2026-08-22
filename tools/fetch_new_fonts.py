#!/usr/bin/env python3
"""
tools/fetch_new_fonts.py

Downloads Libre Baskerville and Merriweather Sans regular font files from GitHub into:
- assets/fonts/
- storefront.koplugin/assets/fonts/
"""

import os
import urllib.request

FONTS = [
    {
        "name": "Libre Baskerville",
        "file": "LibreBaskerville-Regular.ttf",
        "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/librebaskerville/LibreBaskerville%5Bwght%5D.ttf",
    },
    {
        "name": "Merriweather Sans",
        "file": "MerriweatherSans-Regular.ttf",
        "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/merriweathersans/MerriweatherSans%5Bwght%5D.ttf",
    },
    {
        "name": "Fast Sans",
        "file": "Fast_Sans.otf",
        "url": "https://raw.githubusercontent.com/jloutsch/fast-fonts-for-kindle/main/Fast_Sans/Fast_Sans.otf",
    },
    {
        "name": "Fast Sans Dotted",
        "file": "Fast_Sans_Dotted.otf",
        "url": "https://raw.githubusercontent.com/jloutsch/fast-fonts-for-kindle/main/Fast_Sans_Dotted/Fast_Sans_Dotted.otf",
    },
    {
        "name": "Fast Serif",
        "file": "Fast_Serif.otf",
        "url": "https://raw.githubusercontent.com/jloutsch/fast-fonts-for-kindle/main/Fast_Serif/Fast_Serif.otf",
    },
]

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    repo_root = os.path.abspath(os.path.join(script_dir, ".."))

    targets = [
        os.path.join(repo_root, "assets", "fonts"),
        os.path.join(repo_root, "storefront.koplugin", "assets", "fonts"),
    ]

    for item in FONTS:
        print(f"Fetching {item['name']} ({item['file']})...")
        req = urllib.request.Request(item['url'], headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req) as resp:
                data = resp.read()
                
            for base in targets:
                font_dir = os.path.join(base, item['name'])
                os.makedirs(font_dir, exist_ok=True)
                out_file = os.path.join(font_dir, item['file'])
                with open(out_file, "wb") as f:
                    f.write(data)
                print(f"  Saved to {out_file} ({len(data)} bytes)")
        except Exception as e:
            print(f"  Error fetching {item['name']}: {e}")

if __name__ == "__main__":
    main()
