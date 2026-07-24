# Storefront Plugin for KOReader
![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-MIT-yellow.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)
![liberapay](https://img.shields.io/liberapay/patrons/ultimatejimmy.svg?logo=liberapay) 

Discover, install, and update community-created KOReader plugins and user patches without leaving your device. 

Storefront surfaces a curated list of plugins and patches from GitHub with filtering, sorting, and install flows designed to feel native on e-ink hardware.

![Storefront Plugins](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/plugin_list.png)

## Key Capabilities

- **Unified browser** for both plugins and user patches with persistent filters and paging.
- **Offline-friendly cache** stored under `data/cache/Storefront` so existing results remain accessible when you lose connectivity.
- **Per-entry README viewer** that fetches `README.md` directly from GitHub and displays it in the plugin.
- **Install/update pipeline** that handles `.koplugin` archives, verifies metadata, and copies files to `data/plugins` or `data/patches` accordingly.
- **Update tracking** for installed plugins and numbered patch files, complete with SHA comparisons and refreshable summaries.
- **Versions tab** showing all published releases for any plugin or patch, with per-version install, ignore, and pre-release filtering.
- **Optional authentication** through a GitHub Personal Access Token (PAT) to increase API rate limits.

## Screenshots

| Plugins Browser | Patches Browser |
| :---: | :---: |
| ![Plugins Browser](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/plugin_list.png) | ![Patches Browser](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/patches_list.png) |

| Plugin Detail & README | Check Updates |
| :---: | :---: |
| ![Plugin Detail](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/plugin_detail.png) | ![Updates](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/update.png) |

| Installed Plugins | Versions Tab |
| :---: | :---: |
| ![Installed Plugins](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/installed.png) | ![Versions](https://raw.githubusercontent.com/wiki/ultimatejimmy/storefront.koplugin/img/versions.png) |

## Documentation

For full details on how to install, configure, and use the plugin, please visit the [Storefront Wiki](https://github.com/ultimatejimmy/storefront.koplugin/wiki).

Detailed guides available on the wiki:
* [1. Installation Guide](https://github.com/ultimatejimmy/storefront.koplugin/wiki/1.-Installation)
* [2. Configuration (GitHub PAT setup)](https://github.com/ultimatejimmy/storefront.koplugin/wiki/2.-Configuration)
* [3. Usage and Capabilities Guide](https://github.com/ultimatejimmy/storefront.koplugin/wiki/3.-Usage)
* [4. Plugin and Patch Management Guide](https://github.com/ultimatejimmy/storefront.koplugin/wiki/4.-Management)
* [5. Troubleshooting](https://github.com/ultimatejimmy/storefront.koplugin/wiki/5.-Troubleshooting)

## Support me

[liberapay](https://liberapay.com/ultimatejimmy) 

[Buy me a coffee](https://www.buymeacoffee.com/ultimatejimmy)

