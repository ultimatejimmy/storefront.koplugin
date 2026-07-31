#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import time
import hashlib

if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

PLUGIN_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'storefront.koplugin'))
LANGUAGES_DIR = os.path.join(PLUGIN_DIR, 'languages')
SOURCE_DIR = PLUGIN_DIR
MASTER_LANG = 'en'


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

ALLOWLIST = {
    'storefront_title',
    'menu_storefront',
    'btn_ok',
    'status_builtin',
}

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

def parse_po(file_path):
    entries = []
    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
    current_field = None
    if not os.path.exists(file_path): return []
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                if current_entry['msgid'] or current_entry['msgstr']:
                    entries.append(current_entry)
                    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
                current_field = None
                continue
            if line.startswith('#'):
                current_entry['comments'].append(line)
                m = re.match(r'^#\s*en-hash:\s*([a-f0-9]+)$', line)
                if m:
                    current_entry['en_hash'] = m.group(1)
            elif line.startswith('msgid '):
                m = re.match(r'^msgid "(.*)"$', line)
                if m:
                    current_entry['msgid'] = m.group(1)
                current_field = 'msgid'
            elif line.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line)
                if m:
                    current_entry['msgstr'] = m.group(1)
                current_field = 'msgstr'
            elif line.startswith('"'):
                m = re.match(r'^"(.*)"$', line)
                if m:
                    if current_field == 'msgid':
                        current_entry['msgid'] += m.group(1)
                    elif current_field == 'msgstr':
                        current_entry['msgstr'] += m.group(1)
        if current_entry['msgid'] or current_entry['msgstr']:
            entries.append(current_entry)
    return entries

def save_po(file_path, lang_name, lang_code, keys, translations, fallback_map, en_final):
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(f'msgid ""\nmsgstr ""\n"Language-Team: {lang_name}\\n"\n"Language: {lang_code}\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n')
        for key in sorted(keys):
            if not key: continue
            if lang_code == 'en':
                val = translations.get(key) or fallback_map.get(key) or key
            else:
                val = translations.get(key, "")
            escaped_val = val.replace('\n', '\\n').replace('"', '\\"')
            
            if lang_code != 'en':
                en_val = en_final.get(key, "")
                if en_val:
                    f.write(f'# en-hash: {get_md5(en_val)}\n')
            f.write(f'msgid "{key}"\nmsgstr "{escaped_val}"\n\n')

def get_gemini_key():
    return os.environ.get("GEMINI_API_KEY")

def call_gemini(prompt):
    import urllib.error
    key = get_gemini_key()
    if not key: return None
    
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key={key}"
    headers = {"Content-Type": "application/json"}
    data = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"}
    }
    
    req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers, method='POST')
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                text = res_data['candidates'][0]['content']['parts'][0]['text']
                text_stripped = text.strip()
                first_brace = text_stripped.find('{')
                last_brace = text_stripped.rfind('}')
                if first_brace != -1 and last_brace != -1:
                    json_str = text_stripped[first_brace:last_brace+1]
                    return json.loads(json_str)
                return json.loads(text_stripped)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < max_retries - 1:
                retry_after = e.headers.get('Retry-After')
                sleep_time = int(retry_after) if retry_after else 10 * (attempt + 1)
                print(f"  - HTTP {e.code}, waiting {sleep_time}s before retry {attempt + 1}/{max_retries - 1}...")
                time.sleep(sleep_time)
            else:
                print(f"API Error calling Gemini: {e}")
                return None
        except Exception as e:
            print(f"API Error: {e}")
            return None
    return None

def translate_all_gemini(all_untranslated, lang_names, max_pairs=60):
    flat_pairs = []
    for lang_code, keys in all_untranslated.items():
        for key, en_val in keys.items():
            flat_pairs.append((lang_code, key, en_val))
            
    if not flat_pairs:
        return {}
        
    all_results = {}
    
    for i in range(0, len(flat_pairs), max_pairs):
        chunk = flat_pairs[i:i+max_pairs]
        
        batch_dict = {}
        for lang_code, key, en_val in chunk:
            if lang_code not in batch_dict:
                batch_dict[lang_code] = []
            batch_dict[lang_code].append({"key": key, "english": en_val})
            
        targets = []
        for lang_code, strings in batch_dict.items():
            name = lang_names.get(lang_code, lang_code.capitalize())
            targets.append({
                "language_code": lang_code,
                "language_name": name,
                "strings": strings
            })
            
        prompt = f"""You are a professional translator and localization expert. Translate the following English key-value pairs for a KOReader Storefront e-reader plugin UI into their respective target languages.

For each target language, you will receive its language name, language code, and a list of key-value pairs where the values are in English. Translate the English values into the target language, keeping them short, clear, and natural for e-reader menus.

CRITICAL rules:
1. Retain all format specifiers such as %s, %d, %1$s, %2$d, etc. exactly in the translated output.
2. Retain all literal escaped newlines (\\n) and tabs (\\t) exactly.
3. Keep the translation concise, natural, and suited for a mobile e-reader display.
4. Return ONLY a valid JSON object matching this exact schema:
{{
  "translations": {{
    "<language_code>": {{
      "key_name": "translated_value"
    }}
  }}
}}

Input to translate:
{json.dumps(targets, indent=2, ensure_ascii=False)}
"""
        res = call_gemini(prompt)
        if res and isinstance(res, dict) and "translations" in res:
            res_trans = res["translations"]
            for lang_code, kvs in res_trans.items():
                if lang_code not in all_results:
                    all_results[lang_code] = {}
                if isinstance(kvs, dict):
                    for k, v in kvs.items():
                        all_results[lang_code][k] = str(v)
                        
    return all_results

def sync():
    print("--- Synchronizing Storefront Translation Files ---")
    
    # 1. Scan source code for used keys
    used_keys = set()
    fallback_map = {}
    
    loc_file = os.path.join(SOURCE_DIR, 'localization_storefront.lua')
    if os.path.exists(loc_file):
        with open(loc_file, 'r', encoding='utf-8') as f:
            content = f.read()
            m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
            if m_fb:
                fb_block = m_fb.group(1)
                for line in fb_block.splitlines():
                    m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        k, v = m_kv.group(1), m_kv.group(2)
                        fallback_map[k] = v
                        used_keys.add(k)

            m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\}', content, re.DOTALL)
            if m_ka:
                for line in m_ka.group(1).splitlines():
                    m_kv = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        used_keys.add(m_kv.group(1))
                        used_keys.add(m_kv.group(2))


    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root: continue
        for file in files:
            if file.endswith('.lua'):
                with open(os.path.join(root, file), 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    matches = re.finditer(r'(?:loc:t|_|Localization:t)\(\s*[\"\']([^\"\']*)[\"\']', content)
                    for m in matches:
                        used_keys.add(m.group(1))

    used_keys.discard("")
    print(f"Extracted {len(used_keys)} translation keys from source code.")

    # 2. Update English master
    en_path = os.path.join(LANGUAGES_DIR, f'{MASTER_LANG}.po')
    en_existing = parse_po(en_path)
    en_map = {e['msgid']: e['msgstr'] for e in en_existing if e['msgid']}
    
    for k in used_keys:
        if k not in en_map:
            en_map[k] = fallback_map.get(k, k)
            
    save_po(en_path, 'English', 'en', used_keys, en_map, fallback_map, {})
    print(f"Saved master English file: {en_path}")

    # Re-read final en_map
    en_final = {e['msgid']: e['msgstr'] for e in parse_po(en_path) if e['msgid']}

    # 3. Check for untranslated / stale strings across target languages
    all_untranslated = {}
    target_languages = [code for code in LANG_NAMES.keys() if code != 'en']

    for lang_code in target_languages:
        po_path = os.path.join(LANGUAGES_DIR, f'{lang_code}.po')
        entries = parse_po(po_path)
        tr_map = {e['msgid']: e['msgstr'] for e in entries if e['msgid']}
        hash_map = {e['msgid']: e['en_hash'] for e in entries if e['msgid']}
        
        untranslated = {}
        for k in used_keys:
            en_val = en_final.get(k, k)
            current_val = tr_map.get(k)
            stored_hash = hash_map.get(k)
            current_hash = get_md5(en_val)
            
            if not current_val or (stored_hash and stored_hash != current_hash):
                untranslated[k] = en_val
                
        if untranslated:
            all_untranslated[lang_code] = untranslated

    # 4. Auto-translate missing strings if Gemini API key present
    gemini_key = get_gemini_key()
    if all_untranslated and gemini_key:
        total_missing = sum(len(v) for v in all_untranslated.values())
        print(f"Found {total_missing} untranslated or stale strings across {len(all_untranslated)} languages.")
        print("Calling Gemini API to translate missing strings...")
        
        results = translate_all_gemini(all_untranslated, LANG_NAMES)
        
        for lang_code, translations in results.items():
            po_path = os.path.join(LANGUAGES_DIR, f'{lang_code}.po')
            entries = parse_po(po_path)
            tr_map = {e['msgid']: e['msgstr'] for e in entries if e['msgid']}
            for k, v in translations.items():
                tr_map[k] = v
            save_po(po_path, LANG_NAMES.get(lang_code, lang_code), lang_code, used_keys, tr_map, fallback_map, en_final)
            print(f"Updated {lang_code}.po with {len(translations)} new translations.")
    elif all_untranslated:
        print("Notice: Untranslated keys found but GEMINI_API_KEY environment variable is not set.")
        print("Generating placeholder/empty translation entries in target .po files.")
        for lang_code in target_languages:
            po_path = os.path.join(LANGUAGES_DIR, f'{lang_code}.po')
            entries = parse_po(po_path)
            tr_map = {e['msgid']: e['msgstr'] for e in entries if e['msgid']}
            save_po(po_path, LANG_NAMES.get(lang_code, lang_code), lang_code, used_keys, tr_map, fallback_map, en_final)
    else:
        print("All target languages are up to date!")
        for lang_code in target_languages:
            po_path = os.path.join(LANGUAGES_DIR, f'{lang_code}.po')
            entries = parse_po(po_path)
            tr_map = {e['msgid']: e['msgstr'] for e in entries if e['msgid']}
            save_po(po_path, LANG_NAMES.get(lang_code, lang_code), lang_code, used_keys, tr_map, fallback_map, en_final)

    print("\nSync completed successfully.")

if __name__ == "__main__":
    sync()
