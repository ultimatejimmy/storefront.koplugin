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

# Master translations dictionary for common UI strings
DICT = {
    'es': {
        'Check Updates': 'Buscar actualizaciones',
        'Update All': 'Actualizar todo',
        'Checking for updates...': 'Buscando actualizaciones...',
        'No tracked plugins to check.': 'No hay plugins rastreados.',
        'Page %d of %d': 'Página %d de %d',
        'All Types': 'Todas las categ.',
        'User Installed': 'De usuario',
        'Default only': 'Solo de fábrica',
        'Filter & Sort Installed': 'Filtrar y ordenar',
        'Filters': 'Filtros',
        'Type': 'Tipo',
        'Origin': 'Origen',
        'Status': 'Estado',
        'Sorting': 'Ordenación',
        'Sort mode': 'Modo de orden',
        'Reset filters': 'Restablecer filtros',
        'Reset to defaults': 'Restablecer',
        'All': 'Todos',
        'Enabled': 'Activado',
        'Disabled': 'Desactivado',
        'Name (A-Z)': 'Nombre (A-Z)',
        'Name (Z-A)': 'Nombre (Z-A)',
        'Last Updated (Newest)': 'Más recientes',
        'Last Updated (Oldest)': 'Más antiguos',
        'Settings': 'Ajustes',
        'Catalog & Cache': 'Catálogo y caché',
        'Catalog source': 'Fuente del catálogo',
        'Storefront': 'Storefront',
        'Direct GitHub API': 'API directa de GitHub',
        'Refresh cache': 'Refrescar caché',
        'Clear README cache': 'Borrar caché de README',
        'Search & API': 'Búsqueda y API',
        'Include 0-star forks': 'Incluir forks sin estrellas',
        'GitHub token': 'Token de GitHub',
        'Not set': 'No configurado',
        'Configured ✓': 'Configurado ✓',
        'About Storefront': 'Acerca de Storefront',
        'Update channel': 'Canal de actualización',
        'Beta': 'Beta',
        'Stable': 'Estable',
        'Plugin': 'Plugin',
        'Patch': 'Parche',
        'Font': 'Fuente',
        'Default': 'De fábrica',
    },
    'de': {
        'Check Updates': 'Updates prüfen',
        'Update All': 'Alle aktualisieren',
        'Checking for updates...': 'Prüfe auf Updates...',
        'No tracked plugins to check.': 'Keine verfolgten Plugins.',
        'Page %d of %d': 'Seite %d von %d',
        'All Types': 'Alle Typen',
        'User Installed': 'Vom Benutzer',
        'Default only': 'Nur Standard',
        'Filter & Sort Installed': 'Filter & Sortierung',
        'Filters': 'Filter',
        'Type': 'Typ',
        'Origin': 'Herkunft',
        'Status': 'Status',
        'Sorting': 'Sortierung',
        'Sort mode': 'Sortiermodus',
        'Reset filters': 'Filter zurücksetzen',
        'Reset to defaults': 'Zurücksetzen',
        'All': 'Alle',
        'Enabled': 'Aktiviert',
        'Disabled': 'Deaktiviert',
        'Name (A-Z)': 'Name (A-Z)',
        'Name (Z-A)': 'Name (Z-A)',
        'Last Updated (Newest)': 'Neueste',
        'Last Updated (Oldest)': 'Älteste',
        'Settings': 'Einstellungen',
        'Catalog & Cache': 'Katalog & Cache',
        'Catalog source': 'Katalogquelle',
        'Storefront': 'Storefront',
        'Direct GitHub API': 'Direkte GitHub-API',
        'Refresh cache': 'Cache aktualisieren',
        'Clear README cache': 'README-Cache leeren',
        'Search & API': 'Suche & API',
        'Include 0-star forks': 'Forks ohne Sterne einschließen',
        'GitHub token': 'GitHub-Token',
        'Not set': 'Nicht gesetzt',
        'Configured ✓': 'Konfiguriert ✓',
        'About Storefront': 'Über Storefront',
        'Update channel': 'Update-Kanal',
        'Beta': 'Beta',
        'Stable': 'Stabil',
        'Plugin': 'Plugin',
        'Patch': 'Patch',
        'Font': 'Schriftart',
        'Default': 'Standard',
    },
    'fr': {
        'Check Updates': 'Vérifier les màj',
        'Update All': 'Tout mettre à jour',
        'Checking for updates...': 'Recherche de mises à jour...',
        'No tracked plugins to check.': 'Aucun plugin suivi.',
        'Page %d of %d': 'Page %d sur %d',
        'All Types': 'Tous les types',
        'User Installed': 'Utilisateur',
        'Default only': 'Par défaut',
        'Filter & Sort Installed': 'Filtres & Tri',
        'Filters': 'Filtres',
        'Type': 'Type',
        'Origin': 'Origine',
        'Status': 'Statut',
        'Sorting': 'Tri',
        'Sort mode': 'Mode de tri',
        'Reset filters': 'Réinitialiser filtres',
        'Reset to defaults': 'Réinitialiser',
        'All': 'Tous',
        'Enabled': 'Activé',
        'Disabled': 'Désactivé',
        'Name (A-Z)': 'Nom (A-Z)',
        'Name (Z-A)': 'Nom (Z-A)',
        'Last Updated (Newest)': 'Plus récents',
        'Last Updated (Oldest)': 'Plus anciens',
        'Settings': 'Paramètres',
        'Catalog & Cache': 'Catalogue & Cache',
        'Catalog source': 'Source du catalogue',
        'Storefront': 'Storefront',
        'Direct GitHub API': 'API GitHub directe',
        'Refresh cache': 'Actualiser le cache',
        'Clear README cache': 'Vider le cache README',
        'Search & API': 'Recherche & API',
        'Include 0-star forks': 'Inclure forks 0 étoile',
        'GitHub token': 'Jeton GitHub',
        'Not set': 'Non défini',
        'Configured ✓': 'Configuré ✓',
        'About Storefront': 'À propos',
        'Update channel': 'Canal de màj',
        'Beta': 'Bêta',
        'Stable': 'Stable',
        'Plugin': 'Plugin',
        'Patch': 'Patch',
        'Font': 'Police',
        'Default': 'Par défaut',
    },
    'ru': {
        'Check Updates': 'Проверить обновления',
        'Update All': 'Обновить все',
        'Checking for updates...': 'Проверка обновлений...',
        'No tracked plugins to check.': 'Нет отслеживаемых плагинов.',
        'Page %d of %d': 'Страница %d из %d',
        'All Types': 'Все типы',
        'User Installed': 'Пользовательские',
        'Default only': 'Только встроеные',
        'Filter & Sort Installed': 'Фильтр и сортировка',
        'Filters': 'Фильтры',
        'Type': 'Тип',
        'Origin': 'Источник',
        'Status': 'Статус',
        'Sorting': 'Сортировка',
        'Sort mode': 'Режим сортировки',
        'Reset filters': 'Сбросить фильтры',
        'Reset to defaults': 'Сбросить',
        'All': 'Все',
        'Enabled': 'Включено',
        'Disabled': 'Выключено',
        'Name (A-Z)': 'Имя (А-Я)',
        'Name (Z-A)': 'Имя (Я-А)',
        'Last Updated (Newest)': 'Сначала новые',
        'Last Updated (Oldest)': 'Сначала старые',
        'Settings': 'Настройки',
        'Catalog & Cache': 'Каталог и кэш',
        'Catalog source': 'Источник каталога',
        'Storefront': 'Storefront',
        'Direct GitHub API': 'Прямой API GitHub',
        'Refresh cache': 'Обновить кэш',
        'Clear README cache': 'Очистить кэш README',
        'Search & API': 'Поиск и API',
        'Include 0-star forks': 'Форки без звезд',
        'GitHub token': 'Токен GitHub',
        'Not set': 'Не задан',
        'Configured ✓': 'Настроено ✓',
        'About Storefront': 'О Storefront',
        'Update channel': 'Канал обновлений',
        'Beta': 'Бета',
        'Stable': 'Стабильный',
        'Plugin': 'Плагин',
        'Patch': 'Патч',
        'Font': 'Шрифт',
        'Default': 'Встроенный',
    },
    'zh_CN': {
        'Check Updates': '检查更新',
        'Update All': '全部更新',
        'Checking for updates...': '正在检查更新...',
        'No tracked plugins to check.': '无追踪的插件。',
        'Page %d of %d': '第 %d / %d 页',
        'All Types': '所有类型',
        'User Installed': '用户安装',
        'Default only': '仅预装',
        'Filter & Sort Installed': '筛选与排序',
        'Filters': '筛选',
        'Type': '类型',
        'Origin': '来源',
        'Status': '状态',
        'Sorting': '排序',
        'Sort mode': '排序模式',
        'Reset filters': '重置筛选',
        'Reset to defaults': '恢复默认',
        'All': '全部',
        'Enabled': '已启用',
        'Disabled': '已禁用',
        'Name (A-Z)': '名称 (A-Z)',
        'Name (Z-A)': '名称 (Z-A)',
        'Last Updated (Newest)': '按更新时间 (最新)',
        'Last Updated (Oldest)': '按更新时间 (最早)',
        'Settings': '设置',
        'Catalog & Cache': '目录与缓存',
        'Catalog source': '目录来源',
        'Storefront': 'Storefront',
        'Direct GitHub API': 'GitHub API 直连',
        'Refresh cache': '刷新缓存',
        'Clear README cache': '清除 README 缓存',
        'Search & API': '搜索与 API',
        'Include 0-star forks': '包含 0 星 Fork 项目',
        'GitHub token': 'GitHub Token',
        'Not set': '未设置',
        'Configured ✓': '已设置 ✓',
        'About Storefront': '关于 Storefront',
        'Update channel': '更新通道',
        'Beta': '测试版',
        'Stable': '稳定版',
        'Plugin': '插件',
        'Patch': '补丁',
        'Font': '字体',
        'Default': '预装',
    }
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

def populate_all():
    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = parse_po(en_path)
    en_entries.pop("", None)

    for code, name in LANG_NAMES.items():
        if code == 'en': continue
        po_path = os.path.join(LANGUAGES_DIR, f"{code}.po")
        entries = parse_po(po_path)
        entries.pop("", None)

        dict_lang = DICT.get(code, {})

        for k, en_v in en_entries.items():
            if k not in entries or not entries[k] or entries[k].strip() == "":
                tr_v = dict_lang.get(k) or en_v
                entries[k] = tr_v

        save_po(po_path, name, code, entries)
        print(f"Updated {code}.po ({name}) -> {len(entries)} keys complete!")

if __name__ == '__main__':
    populate_all()
