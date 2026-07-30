#!/usr/bin/env python3
import os
import re
import sys

LANGUAGES_DIR = os.path.join(os.path.dirname(__file__), '..', 'languages')
SOURCE_DIR = os.path.join(os.path.dirname(__file__), '..')

LANG_NAMES = {
    'ar': 'Arabic',
    'de': 'German',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'nl': 'Dutch',
    'pl': 'Polish',
    'pt_br': 'Portuguese (Brazil)',
    'ru': 'Russian',
    'sr': 'Serbian',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'zh_CN': 'Simplified Chinese',
}

def extract_strings_from_lua(filepath):
    keys = set()
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    # 1. Matches _("...") with escaped quotes
    p1 = re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*[\),]', content)
    for m in p1:
        s = m.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
        if s and not s.startswith('%'): keys.add(s)

    # 2. Matches _('...') with escaped quotes
    p2 = re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\'((?:[^\'\\]|\\.)*)\'\s*[\),]', content)
    for m in p2:
        s = m.group(1).replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')
        if s and not s.startswith('%'): keys.add(s)

    # 3. Matches _([[...]]) block strings
    p3 = re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\[\[(.*?)\]\]\s*[\),]', content, re.DOTALL)
    for m in p3:
        s = m.group(1)
        if s: keys.add(s)

    return keys

def parse_po(file_path):
    entries = {}
    if not os.path.exists(file_path):
        return entries
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        current_msgid = None
        current_msgstr = None
        in_msgid = False
        in_msgstr = False
        for line in f:
            line_str = line.strip()
            if not line_str or line_str.startswith('#'):
                if current_msgid is not None and current_msgstr is not None:
                    entries[current_msgid] = current_msgstr
                    current_msgid = None
                    current_msgstr = None
                in_msgid = False
                in_msgstr = False
                continue
            if line_str.startswith('msgid '):
                if current_msgid is not None and current_msgstr is not None:
                    entries[current_msgid] = current_msgstr
                m = re.match(r'^msgid "(.*)"$', line_str)
                current_msgid = m.group(1).replace('\\"', '"').replace('\\n', '\n') if m else ''
                current_msgstr = None
                in_msgid = True
                in_msgstr = False
            elif line_str.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line_str)
                current_msgstr = m.group(1).replace('\\"', '"').replace('\\n', '\n') if m else ''
                in_msgid = False
                in_msgstr = True
            elif line_str.startswith('"'):
                m = re.match(r'^"(.*)"$', line_str)
                if m:
                    val = m.group(1).replace('\\"', '"').replace('\\n', '\n')
                    if in_msgid and current_msgid is not None:
                        current_msgid += val
                    elif in_msgstr and current_msgstr is not None:
                        current_msgstr += val
        if current_msgid is not None and current_msgstr is not None:
            entries[current_msgid] = current_msgstr
    return entries

def main():
    all_extracted_keys = set()
    
    # Also extract FALLBACKS and KEY_ALIASES from localization_storefront.lua
    loc_file = os.path.join(SOURCE_DIR, 'localization_storefront.lua')
    if os.path.exists(loc_file):
        with open(loc_file, 'r', encoding='utf-8') as f:
            content = f.read()
            m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
            if m_fb:
                for line in m_fb.group(1).splitlines():
                    m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        all_extracted_keys.add(m_kv.group(1))

            m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\}', content, re.DOTALL)
            if m_ka:
                for line in m_ka.group(1).splitlines():
                    m_kv = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        all_extracted_keys.add(m_kv.group(1))
                        all_extracted_keys.add(m_kv.group(2))

    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root or 'tools' in root or 'tests' in root: continue
        for file in files:
            if file.endswith('.lua'):
                keys = extract_strings_from_lua(os.path.join(root, file))
                all_extracted_keys.update(keys)

    all_extracted_keys.discard("")
    print(f"Total Unique Translation Keys Extracted from Lua Source: {len(all_extracted_keys)}\n")

    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = parse_po(en_path)
    en_entries.pop("", None)

    print(f"Keys in en.po: {len(en_entries)}")
    missing_in_en = all_extracted_keys - set(en_entries.keys())
    print(f"Keys missing from en.po: {len(missing_in_en)}")
    if missing_in_en:
        print("Sample missing keys in en.po:")
        for k in sorted(missing_in_en)[:20]:
            print(f"  - {k!r}")

    print("\nTarget Languages Missing Keys Audit:")
    for code, name in sorted(LANG_NAMES.items()):
        if code == 'en': continue
        po_path = os.path.join(LANGUAGES_DIR, f"{code}.po")
        entries = parse_po(po_path)
        entries.pop("", None)
        missing = all_extracted_keys - set(entries.keys())
        empty = [k for k, v in entries.items() if not v or v.strip() == ""]
        print(f"  - {code}.po ({name}): {len(entries)} keys in file | {len(missing)} missing from codebase | {len(empty)} empty")

if __name__ == '__main__':
    main()
