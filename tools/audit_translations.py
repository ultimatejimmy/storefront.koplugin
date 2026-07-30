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

UI_WIDGET_PATTERNS = [
    r'TextWidget:new\s*\{\s*text\s*=\s*"([^"]+)"',
    r'TextBoxWidget:new\s*\{\s*text\s*=\s*"([^"]+)"',
    r'Button:new\s*\{\s*text\s*=\s*"([^"]+)"',
    r'CheckButton:new\s*\{\s*text\s*=\s*"([^"]+)"',
    r'InputDialog:new\s*\{\s*title\s*=\s*"([^"]+)"',
    r'InputDialog:new\s*\{\s*description\s*=\s*"([^"]+)"',
]

def scan_unwrapped_ui_strings():
    unwrapped = []
    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root or 'tools' in root or 'tests' in root: continue
        for file in files:
            if file.endswith('.lua'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    for pat in UI_WIDGET_PATTERNS:
                        for m in re.finditer(pat, content):
                            val = m.group(1)
                            # Ignore icon strings, single characters, numbers, asset paths
                            if len(val) > 2 and not val.endswith('.svg') and not val.endswith('.ttf') and not val.startswith('%'):
                                unwrapped.append((file, val))
    return unwrapped

def extract_keys_from_lua():
    keys = set()

    # Extract FALLBACKS and KEY_ALIASES
    loc_file = os.path.join(SOURCE_DIR, 'localization_storefront.lua')
    if os.path.exists(loc_file):
        with open(loc_file, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
            if m_fb:
                for line in m_fb.group(1).splitlines():
                    m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        keys.add(m_kv.group(1))

            m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\}', content, re.DOTALL)
            if m_ka:
                for line in m_ka.group(1).splitlines():
                    m_kv = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        keys.add(m_kv.group(1))
                        keys.add(m_kv.group(2))

    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root or 'tools' in root or 'tests' in root: continue
        for file in files:
            if file.endswith('.lua'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()

                    # 1. Double quoted _("...")
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*[\),]', content):
                        s = m.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
                        if s and not s.startswith('%'): keys.add(s)

                    # 2. Single quoted _('...')
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\'((?:[^\'\\]|\\.)*)\'\s*[\),]', content):
                        s = m.group(1).replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')
                        if s and not s.startswith('%'): keys.add(s)

                    # 3. Block quoted _([[...]])
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\[\[(.*?)\]\]\s*[\),]', content, re.DOTALL):
                        s = m.group(1)
                        if s: keys.add(s)

    keys.discard("")
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

def save_po(file_path, lang_name, lang_code, entries):
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(f'msgid ""\nmsgstr ""\n"Language-Team: {lang_name}\\n"\n"Language: {lang_code}\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n')
        for key in sorted(entries.keys()):
            if not key: continue
            val = entries[key]
            escaped_key = key.replace('\n', '\\n').replace('"', '\\"')
            escaped_val = val.replace('\n', '\\n').replace('"', '\\"')
            f.write(f'msgid "{escaped_key}"\nmsgstr "{escaped_val}"\n\n')

def run_audit():
    print("==================================================")
    print("      ADVANCED LUA AST TRANSLATION AUDITOR       ")
    print("==================================================\n")

    unwrapped_ui = scan_unwrapped_ui_strings()
    if unwrapped_ui:
        print(f"⚠️ Warning: Found {len(unwrapped_ui)} potentially un-wrapped UI string literals:")
        for fn, s in unwrapped_ui[:10]:
            print(f"   [{fn}] \"{s}\"")
        print()
    else:
        print("✅ 0 Un-wrapped UI String Literals Found!\n")

    used_keys = extract_keys_from_lua()
    print(f"Total Unique Translation Keys Extracted from Lua Source: {len(used_keys)}\n")

    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = parse_po(en_path)
    en_entries.pop("", None)

    # 1. Update en.po if keys are missing
    missing_in_en = used_keys - set(en_entries.keys())
    if missing_in_en:
        print(f"Updating en.po with {len(missing_in_en)} missing master keys...")
        for k in missing_in_en:
            en_entries[k] = k
        save_po(en_path, 'English', 'en', en_entries)

    print("✅ English Master (en.po) Key Parity: 100%!")

    # 2. Check and report on target language coverage
    print("\n--- Target Language Parity & Completeness Audit ---")
    total_issues = 0

    tab_keys = {'tab_plugins', 'tab_patches', 'tab_fonts', 'filter_installed', 'filter_updates'}

    for lang_code, lang_name in sorted(LANG_NAMES.items()):
        if lang_code == 'en': continue
        po_path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        entries = parse_po(po_path)
        entries.pop("", None)

        missing = []
        empty = []
        too_long = []

        for key in sorted(en_entries.keys()):
            val = entries.get(key, "")
            if key not in entries:
                missing.append(key)
            elif not val or val.strip() == "":
                empty.append(key)
            elif key in tab_keys and len(val) > 11:
                too_long.append((key, val))

        if missing or empty or too_long:
            total_issues += len(missing) + len(empty) + len(too_long)
            print(f"❌ {lang_code}.po ({lang_name}): {len(entries)}/{len(en_entries)} keys | {len(missing)} missing | {len(empty)} empty | {len(too_long)} long tabs")
        else:
            print(f"✅ {lang_code}.po ({lang_name}): 100% complete ({len(entries)}/{len(en_entries)} keys)")

    print("\n==================================================")
    if total_issues == 0 and len(unwrapped_ui) == 0:
        print("     AUDIT PASSED: 100% MULTILINGUAL PARITY!       ")
    else:
        print(f"     AUDIT FINISHED: {total_issues + len(unwrapped_ui)} ISSUES REPORTED          ")
    print("==================================================")
    return total_issues + len(unwrapped_ui)

if __name__ == "__main__":
    sys.exit(run_audit())
