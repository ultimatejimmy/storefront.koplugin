---
trigger: always_on
description: Guidelines and rules for translation management, key synchronization, and character length constraints.
---

# Translation Guidelines & Rules

## 1. Master Language & Key Synchronization
- **English Master (`en.po`)**: `en.po` is the primary master translation template.
- **100% Key Parity**: All translation keys referenced in Lua source code (`_("key")`, `loc:t("key")`, `KEY_ALIASES`, `FALLBACKS`) MUST exist in `en.po` and be synchronized across ALL 17 target `.po` files.
- **Automated Synchronization & Auditing**:
  - Run `python tools/sync_translations.py` whenever adding or modifying translation keys.
  - Run `python tools/check_translations.py` to verify 100% key coverage across all languages with 0 missing, empty, or stale keys.

## 2. Character Length & Proportional Scaling Rules
- **Similar Length Requirement**: Target language translations (`msgstr`) should be kept similar in character length to the English source text (`msgid`). Avoid unnecessarily verbose phrasing or long compound words that distort UI alignment.
- **Top Tab Bar Constraints**:
  - Top tab labels (`Plugins`, `Patches`, `Fonts`, `Installed`, `Updates`) MUST be **<= 12 characters** across all languages to prevent tab bar wrapping or text truncation on small e-ink displays.
- **Sort Summary Chips & Filter Bar Options**:
  - Filter summary and sort bar strings (e.g., `Sort: Recently updated` -> `Orden: Fecha` / `Sortierung: Datum`) MUST be **<= 18 characters** so they fit comfortably on a single line.
- **Action Buttons & Badges**:
  - Single-line action buttons (e.g. `Reset to defaults` -> `Restablecer` / `Zurücksetzen`) should aim for a length ratio **<= 1.5x** of the English master text.
- **Automated Length Auditing**:
  - Run `python tools/audit_translation_lengths.py` to automatically audit and flag any translation string that exceeds UI length boundaries or length ratios.

## 3. Localization Best Practices
- **Format Specifiers**: Retain all format specifiers (`%s`, `%d`, `%1$s`) exactly in translated strings.
- **Fallback Mappings**: Ensure `KEY_ALIASES` in `localization_storefront.lua` correctly bridges legacy key identifiers and English literal strings.
- **Native Literary Passage Translations**: For sample passages (e.g. font specimen texts), use established, high-quality native literary translations rather than literal machine-translated text.
