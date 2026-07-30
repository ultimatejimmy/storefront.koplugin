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
            line = line.strip()
            if not line or line.startswith('#'):
                if current_msgid is not None and current_msgstr is not None:
                    entries[current_msgid] = current_msgstr
                    current_msgid = None
                    current_msgstr = None
                in_msgid = False
                in_msgstr = False
                continue
            if line.startswith('msgid '):
                m = re.match(r'^msgid "(.*)"$', line)
                if m:
                    current_msgid = m.group(1)
                in_msgid = True
                in_msgstr = False
            elif line.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line)
                if m:
                    current_msgstr = m.group(1)
                in_msgid = False
                in_msgstr = True
            elif line.startswith('"'):
                m = re.match(r'^"(.*)"$', line)
                if m:
                    if in_msgid and current_msgid is not None:
                        current_msgid += m.group(1)
                    elif in_msgstr and current_msgstr is not None:
                        current_msgstr += m.group(1)
        if current_msgid is not None and current_msgstr is not None:
            entries[current_msgid] = current_msgstr
    return entries

def run_audit():
    print("==================================================")
    print("     STOREFRONT TRANSLATION KEY AUDIT REPORT      ")
    print("==================================================\n")

    used_keys = set()
    fallback_map = {}
    key_aliases = {}

    loc_file = os.path.join(SOURCE_DIR, 'localization_storefront.lua')
    if os.path.exists(loc_file):
        with open(loc_file, 'r', encoding='utf-8') as f:
            content = f.read()
            m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
            if m_fb:
                for line in m_fb.group(1).splitlines():
                    m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        fallback_map[m_kv.group(1)] = m_kv.group(2)
                        used_keys.add(m_kv.group(1))

            m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\}', content, re.DOTALL)
            if m_ka:
                for line in m_ka.group(1).splitlines():
                    m_kv = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        key_aliases[m_kv.group(1)] = m_kv.group(2)
                        used_keys.add(m_kv.group(1))
                        used_keys.add(m_kv.group(2))

    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root: continue
        for file in files:
            if file.endswith('.lua'):
                with open(os.path.join(root, file), 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    matches = re.finditer(r'(?:loc:t|_|Localization:t)\(\s*["\']([^"\']*)["\']', content)
                    for m in matches:
                        used_keys.add(m.group(1))

    used_keys.discard("")
    print(f"Total Translation Keys Identified in Codebase: {len(used_keys)}\n")

    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = parse_po(en_path)
    en_entries.pop("", None)

    missing_in_en = used_keys - set(en_entries.keys())
    if missing_in_en:
        print(f"⚠️  {len(missing_in_en)} keys missing in English master (en.po):")
        for k in sorted(missing_in_en):
            print(f"   - {k}")
    else:
        print("✅ 100% English Master (en.po) Coverage! (0 missing keys)")

    print("\n--- Target Language Coverage Audit ---")
    total_issues = 0

    for lang_code, lang_name in sorted(LANG_NAMES.items()):
        if lang_code == 'en': continue
        po_path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        entries = parse_po(po_path)
        entries.pop("", None)

        missing = []
        empty = []

        for key in sorted(en_entries.keys()):
            if key not in entries:
                missing.append(key)
            elif not entries[key] or entries[key].strip() == "":
                empty.append(key)

        if missing or empty:
            total_issues += len(missing) + len(empty)
            print(f"❌ {lang_code}.po ({lang_name}): {len(missing)} missing, {len(empty)} empty")
        else:
            print(f"✅ {lang_code}.po ({lang_name}): 100% translated ({len(entries)}/{len(en_entries)} keys)")

    print("\n==================================================")
    if total_issues == 0 and not missing_in_en:
        print("     AUDIT PASSED: ALL TRANSLATION KEYS ARE 100% OK!   ")
    else:
        print(f"     AUDIT FINISHED WITH {total_issues + len(missing_in_en)} ISSUES TO FIX   ")
    print("==================================================")

if __name__ == "__main__":
    run_audit()
