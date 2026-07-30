#!/usr/bin/env python3
import os
import re
import sys

LANGUAGES_DIR = os.path.join(os.path.dirname(__file__), '..', 'languages')

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

def run_length_audit():
    print("==================================================")
    print("   STOREFRONT TRANSLATION LENGTH AUDIT REPORT    ")
    print("==================================================\n")

    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = parse_po(en_path)
    en_entries.pop("", None)

    # Categories of keys where length ratio matters most:
    # 1. Tab labels (critical: <= 12 chars)
    # 2. Buttons / Action labels (important: <= 20 chars)
    # 3. Settings / Filter rows (important: ratio <= 1.8x)

    tab_keys = {'tab_plugins', 'tab_patches', 'tab_fonts', 'filter_installed', 'filter_updates', 'tab_all', 'tab_readme', 'tab_versions'}
    
    total_warnings = 0

    for lang_code, lang_name in sorted(LANG_NAMES.items()):
        if lang_code == 'en': continue
        po_path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        entries = parse_po(po_path)
        entries.pop("", None)

        lang_warnings = []

        for key, en_val in sorted(en_entries.items()):
            tr_val = entries.get(key, "")
            if not tr_val: continue

            en_len = len(en_val)
            tr_len = len(tr_val)

            # Ignore long paragraph texts (like reading passages or about descriptions)
            if en_len > 80: continue

            # Check 1: Top Tab Bar strings (must be <= 12 characters)
            if key in tab_keys:
                if tr_len > 12:
                    lang_warnings.append((key, en_val, tr_val, f"Tab key too long ({tr_len} chars > 12)"))

            # Check 2: UI Labels / Buttons (ratio > 1.8x AND tr_len > 18 chars)
            elif en_len > 0 and (tr_len / en_len) > 1.8 and tr_len > 18:
                lang_warnings.append((key, en_val, tr_val, f"Ratio {tr_len/en_len:.1f}x ({tr_len} vs {en_len} chars)"))

        if lang_warnings:
            total_warnings += len(lang_warnings)
            print(f"⚠️  {lang_code}.po ({lang_name}): {len(lang_warnings)} long translation strings:")
            for key, en_val, tr_val, reason in lang_warnings:
                print(f"   - Key '{key}': English='{en_val}' ({len(en_val)}c) -> {lang_code.upper()}='{tr_val}' ({len(tr_val)}c) [{reason}]")
            print()
        else:
            print(f"✅ {lang_code}.po ({lang_name}): All UI translation string lengths look great!")

    print("==================================================")
    if total_warnings == 0:
        print("  PERFECT RESULT: ALL TRANSLATION LENGTHS ARE OK! ")
    else:
        print(f"  AUDIT FOUND {total_warnings} OVERLY LONG TRANSLATION STRINGS  ")
    print("==================================================")

if __name__ == "__main__":
    run_length_audit()
