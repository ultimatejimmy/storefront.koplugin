# App Store Plugin for KOReader

Discover, install, and update community-created KOReader plugins and user patches without leaving your device. The AppStore plugin searches both GitHub topics (`koreader-plugin`, `koreader-user-patch`) and repositories whose names follow patterns like `"KOReader.patches"` or `"[NAME].plugins"`. The plugin supports standard owner/topic/description filters, surfacing curated lists with filtering, sorting, and hands-on install flows that feel native on e-ink hardware.

## Installation

1. Download the latest release from the [releases page](https://github.com/omer-faruq/appstore.koplugin/releases) or clone this repository.
2. Copy the `appstore.koplugin` folder to your KOReader's `plugins` directory:
   - **Kobo/Kindle**: `koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
   - **Desktop (Linux)**: `~/.config/koreader/plugins/`
3. Restart KOReader.
4. Access via **Tools** → **App Store**.

## Key Capabilities

- **Unified browser** for both plugins and user patches with persistent filters and paging.
- **Offline-friendly cache** stored under `data/cache/AppStore` so existing results remain accessible when you lose connectivity.
- **Per-entry README viewer** that fetches `README.md` directly from GitHub and opens it in KOReader’s document renderer.
- **Install/update pipeline** that handles `.koplugin` archives, verifies metadata, and copies files to `data/plugins` or `data/patches` accordingly.
- **Update tracking** for installed plugins and numbered patch files, complete with SHA comparisons and refreshable summaries.
- **Optional authentication** through a GitHub Personal Access Token (PAT) to increase API rate limits.

## Requirements

1. KOReader nightly or 2024.12+ with LuaSocket, Archiver, SHA2, and SQLite dependencies (bundled in default releases).
2. Network connectivity for refreshing caches, fetching README files, and downloading plugin or patch archives.
3. (Optional) A GitHub PAT with `public_repo` scope to avoid unauthenticated rate limits (~10 requests/minute shared across the device).

## Configuration (GitHub PAT)

If you routinely browse many repositories or hit rate-limit warnings, supply a PAT in `plugins/appstore.koplugin/appstore_configuration.lua`:

```lua
return {
    auth = {
        github = {
            type = "github",
            token = "ghp_your_token_here",
        },
    },
}
```

### How to create a GitHub PAT

1. Sign in at [github.com](https://github.com/) and open **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** (or **Tokens (classic)**), You can follow [this link](https://github.com/settings/tokens/new).
2. Click **Generate new token**.
3. Name the token (e.g., `KOReader AppStore`), set an expiration, and grant at least the **`public_repo`** scope.
4. Generate and copy the token immediately—GitHub will not show it again.
5. Paste it into `appstore_configuration.lua` (You can create that file from `appstore_configuration.sample.lua`) and restart KOReader.

The plugin automatically includes the token in GitHub API requests, raising your quota to the standard authenticated limits.

## Navigating the Four AppStore Sections

The UI is built around four dedicated dialogs.

1. ### Plugins Browser (`App Store · Plugins`)
   - Lists repositories tagged as KOReader plugins.
   - Actions per entry: **Install / Update / Remove**, **View README**, open detail dialogs with description, stars, last updated timestamp, and repo owner.
   - Toolbar actions: switch to patches tab, refresh cache, adjust filters (`search text`, `owner`, `minimum stars`), change sorting (stars desc/asc, updated, name), and jump into the installed plugins page.
   - **Gear icon (⚙️)**: Access settings including **Install plugin from URL** to manually install plugins by entering GitHub owner/repo.

2. ### Patches Browser (`App Store · Patches`)
   - Lists repositories tagged as KOReader user patches and enumerates files matching `^[number]-*.lua`.
   - Actions per patch: **Install patch**, retry downloads, or open the repo README for full instructions.
   - Toolbar actions: mirror the plugin tab plus shortcuts to the installed patches page and a "matching patch" banner when reconciling installed files with remote entries.
   - **Gear icon (⚙️)**: Access settings including **Install patch from URL** to manually install patches by entering GitHub owner/repo.

3. ### Installed Plugins (`Check plugin updates`)
   - Summarizes every installed plugin, both linked (matched with a repository) and unlinked.
   - Actions: **Check all updates**, toggle between "Only outdated" and "Show all plugins," and jump straight back to the Plugins browser.
   - Each row shows the local version, cached remote version/SHA (for linked plugins), last checked timestamp, and provides **Update** or **Reinstall** buttons when differences are detected.
   - Per-plugin actions: **Disable/Enable**, **Delete**, **Match from List** or **Match with URL** (for unlinked plugins), **Unlink the repo** (for linked plugins).

4. ### Installed Patches (`Check patch updates`)
   - Works just like the installed plugins page but focuses on numbered patch files under `data/patches`.
   - Actions: **Check all updates**, toggle between "Only outdated" and "Show all patches," and jump straight back to the Patches browser.
   - Each row shows the patch filename, cached remote version/SHA (for linked patches), last checked timestamp, and provides **Update** or **Reinstall** buttons when differences are detected.
   - Per-patch actions: **Disable/Enable** (renames with `.disabled` suffix), **Delete**, **Match from List** or **Match with URL** (for unlinked patches), **Unlink the repo** (for linked patches).

## Typical Workflow

1. **Open** KOReader → **Tools** → **App Store**.
2. Pick **Plugins** or **Patches** tab. Use the filter dialog to narrow by owner, name, topics, or star threshold.
3. Tap an entry for a quick action menu. Choosing **Install** downloads the repo ZIP (`/zipball/<ref>`), extracts it to a temp folder, validates `_meta.lua`, then copies it to `data/plugins/<name>.koplugin`.
4. After installation, KOReader prompts for a restart so the new plugin becomes available in the Tools menu.
5. For patches, selecting an item downloads the raw `.lua` file from the default branch and stores it under `data/patches/` while retaining the numbered filename used for KOReader’s patch loader.
6. Return anytime to the Updates dialogs to check for newer commits. The plugin compares cached SHAs with the installed files and highlights items needing attention.
7. Use **View README** to fetch the upstream documentation and open it in KOReader’s file viewer. Files are cached under `data/cache/appstore/readme/owner_repo_README.md` for offline rereads.

## Cache & Offline Behavior

- Repository metadata is stored in SQLite under `data/cache/appstore.db` (automatically created).
- The browser always reads from the cache first, keeping scrolling smooth even when the network is slow.
- When cached data is older than 7 days, the banner reminds you to trigger **Refresh cache**.
- README files, download archives, and installed SHAs are cached so subsequent operations reuse existing data whenever possible.

## Managing Installed Plugins and Patches

The AppStore plugin provides built-in tools to **disable**, **delete**, and **match with repositories** for installed plugins and patches directly from the update dialogs.

### Disable/Enable

- **Plugins**: Uses KOReader's native disable mechanism. Disabled plugins appear with a `[DISABLED]` label and sync with the Tools → Plugin management screen.
- **Patches**: Renames the file with a `.disabled` suffix (e.g., `2-patch.lua` → `2-patch.lua.disabled`). Disabled patches are shown with a `[DISABLED]` label.

### Delete (Uninstall)

- **Linked items** (matched with a repository): Can always be deleted.
- **Unlinked items** (not matched): Can only be deleted if the "Allow delete unlinked plugins/patches" setting is enabled.

### Repository Matching

Link installed plugins/patches with GitHub repositories to enable update tracking:

- **Match from List**: Opens the repository browser with automatic filtering by plugin/patch name for quick matching.
- **Match with URL**: Manually enter GitHub owner and repository name to link items not found in search results.
- **Unlink the repo**: Remove repository association from linked items to return them to unlinked state.

### Accessing Management Options

1. Open **Check plugin updates** or **Check patch updates**.
2. Tap any installed item to open its action dialog.
3. Use **Disable/Enable** buttons to toggle the item's state.
4. Use **Delete** button to permanently remove the item (confirmation required).
5. Use **Match from List** or **Match with URL** for unlinked items to enable update tracking.
6. Use **Unlink the repo** for linked items to remove repository association.
7. Access the **gear icon** (⚙️) to enable deletion of unlinked items.

**Note**: All disable/enable/delete operations require a KOReader restart to take effect.

## Include 0-Star Forks Setting

By default, the AppStore plugin **excludes** repositories that are forks with zero stars from search results.

### How It Works

- **Default behavior (off)**: The plugin skips the `fork:only stars:0` query at the GitHub API level, so 0-star forks never reach your device. This reduces noise and speeds up browsing.
- **When enabled**: The plugin includes an additional `fork:only stars:0` query, bringing all forks into the search results regardless of star count.

### Accessing the Setting

1. Open the **Plugins** or **Patches** browser.
2. Tap the **gear icon** (⚙️) in the top-left corner of the title bar.
3. Toggle **Include 0-star forks** on or off.
4. The setting takes effect immediately and applies to all future cache refreshes.

**Note**: Changing this setting does not automatically refresh the cache. Use the **Refresh cache** action from the toolbar to apply the new filter scope to your current results.

## Troubleshooting

| Symptom | Likely Cause | Suggested Fix |
| --- | --- | --- |
| Rate limit exceeded | Anonymous GitHub quota exhausted | Configure a PAT and retry after a few minutes |
| Missing README | Repo lacks `README.md` or request failed | Confirm file exists upstream, then rerun **View README** while online |
| Patch not listed | Repository is not named `KOReader.patches` (or similar) and/or the `koreader-user-patch` topic is missing | Ask the maintainer to add the correct topic |

## Non-touch devices (Kindle 4 NT, Kindle Keyboard, …)

The AppStore plugin is fully usable on devices without a touchscreen. The browser and updates dialogs follow KOReader's standard non-touch conventions:

- **Up / Down** — move focus between list rows; the list scrolls automatically when the focused row would otherwise be off-screen.
- **Left / Right** — move focus across the title-bar buttons (gear / close) and the pagination row (Previous / Next), or between the top control buttons in the Updates dialog.
- **Press** (centre key on the 5-way) — activate the focused entry, equivalent to a tap.
- **Hold / Long-press** (where supported) — open the secondary action of the focused entry, equivalent to a tap-and-hold.
- **Page-forward / Page-back** keys — flip to the next / previous page in the browser.
- **Back** — close the dialog. On few-keys devices that do not provide a Back key (e.g. Kindle 4 NT), **Left** acts as the close shortcut, mirroring KOReader's built-in `Menu` widget.

## Web Browser Access

You can also browse the repository list from your PC browser by visiting [https://omer-faruq.github.io/appstore.koplugin/](https://omer-faruq.github.io/appstore.koplugin/), or by downloading and opening the `docs/index.html` file locally.

## Credits

This plugin and documentation were prepared with Windsurf (AI).
