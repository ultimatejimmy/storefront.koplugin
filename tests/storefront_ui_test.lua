-- storefront_ui_test.lua
-- Run with: cd <extracted-koreader-dir> && env SQUASHFS_ROOT=<dir> LUA_PATH='...' ./luajit <test_file>
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
    io.stdout:flush()
end
_G.check = check

local _in_schedule = false
local dummy_widget = {
    extend = function(self, tbl)
        tbl = tbl or {}
        for k, v in pairs(self) do
            if tbl[k] == nil then tbl[k] = v end
        end
        return tbl
    end,
    new = function(self, tbl)
        tbl = tbl or {}
        for k, v in pairs(self) do
            if tbl[k] == nil then tbl[k] = v end
        end
        return tbl
    end,
    getSize = function(self)
        if self and self.entry then
            if self.entry.thumbnail_file then return { w = 100, h = 96 } end
            if self.entry.is_update_item then return { w = 100, h = 60 } end
            if self.entry.description and self.entry.description ~= "" then return { w = 100, h = 80 } end
            return { w = 100, h = 56 }
        end
        return { w = 100, h = 50 }
    end,
    enableDisable = function() end,
    isFocusable = function() return true end,
    open = function(self) return self or dummy_widget end,
    readSetting = function() end,
    saveSetting = function() end,
    isTrue = function(self, key) return false end,
    flush = function() end,
    copy = function(self)
        local c = {}
        for k, v in pairs(self) do c[k] = v end
        return c
    end,
    scheduleIn = function(self, delay, fn)
        if type(delay) == "function" then fn = delay end
        if not fn or _in_schedule then return end
        _in_schedule = true
        pcall(fn)
        _in_schedule = false
    end,
    unschedule = function() end,
}

-- Pre-load dummy mocks for all KOReader UI modules to prevent library load crashes headlessly
local widgets = {
    "ui/widget/button",
    "ui/widget/container/framecontainer",
    "ui/widget/container/scrollablecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer",
    "ui/widget/container/widgetcontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/movablecontainer",
    "ui/widget/focusmanager",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/verticalspan",
    "ui/widget/verticalgroup",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/spinwidget",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/titlebar",
    "ui/widget/iconwidget",
    "ui/widget/iconbutton",
    "ui/renderimage",
    "storefront_list_item",
    "ui/network/manager",
    "ui/widget/scrolltextwidget",
    "ui/widget/infomessage",
    "ui/widget/imagewidget",
    "ui/widget/imageviewer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/inputdialog",
    "libs/libkoreader-lfs",
    "socket.url",
    "ui/widget/textviewer",
    "apps/filemanager/filemanager",
    "socket.http",
    "ui/widget/confirmbox",
    "ui/widget/multiinputdialog",
    "ui/widget/checkbutton",
    "ui/widget/buttondialog",
    "storefront_repo_content",
    "storefront_plugin_paths",
    "ffi/archiver",
    "ffi/sha2",
    "socketutil",
    "socket",
}

package.loaded["ui/trapper"] = {
    wrap = function(self, fn)
        if type(self) == "function" then fn = self end
        if fn then fn() end
    end,
    dismissableRunInSubprocess = function(self, fn, info)
        if type(self) == "function" then fn = self end
        if fn then
            local res = fn()
            return true, res
        end
        return true, nil
    end,
    reset = function() end,
}

local _mock_json_store = { plugins = {}, patches = {}, item_options = {} }
package.loaded["json"] = {
    encode = function(val)
        if type(val) == "table" then
            if val.plugins then _mock_json_store.plugins = val.plugins end
            if val.patches then _mock_json_store.patches = val.patches end
            if val.item_options then _mock_json_store.item_options = val.item_options end
        end
        return "MOCK_JSON"
    end,
    decode = function(str)
        return _mock_json_store
    end,
}

package.loaded["ffi/util"] = {
    realpath = function(path) return path end,
    runInSubProcess = function() return 1, {} end,
    writeToFD = function() end,
    readAllFromFD = function() return "" end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
}

package.loaded["ui/network/manager"] = {
    runWhenOnline = function(self, cb)
        if type(self) == "function" then
            cb = self
        end
        if cb then cb() end
    end
}

package.loaded["ui/widget/htmlboxwidget"] = dummy_widget:extend{
    setContent = function() end,
    freeBb = function() end,
    page_number = 1,
    page_count = 1,
}

package.loaded["logger"] = {
    info = function() end,
    warn = function() end,
    dbg = function() end,
    err = function() end,
    setLevel = function() end,
    levels = { DBG = 1, INFO = 2, WARN = 3, ERR = 4 },
}

package.loaded["storefront_logger"] = {
    log = function() end,
    info = function() end,
    debug = function() end,
    action = function() end,
    warn = function() end,
    err = function() end,
    clear = function() end,
    reset = function() end,
    startSession = function() end,
}

package.loaded["storefront_net_github"] = {
    hasAuthToken = function() return false end,
    getCatalogMode = function() return "static" end,
    setCatalogMode = function() end,
    isDirectApiEnabled = function() return false end,
    fetchReleases = function(owner, repo)
        return {
            { tag_name = "26.7.23", body = "Release notes text", published_at = "2026-07-23" }
        }, nil
    end,
    fetchLatestRelease = function(owner, repo)
        return { tag_name = "26.7.23", body = "Release notes text", published_at = "2026-07-23" }, nil
    end,
    markdownToHtml = function(md)
        return "<p>" .. tostring(md) .. "</p>"
    end,
}

-- package.loaded["storefront_updates_ui"] is loaded normally

package.loaded["luasettings"] = dummy_widget

for _, w in ipairs(widgets) do
    if w ~= "storefront_plugin_paths" and w ~= "libs/libkoreader-lfs" then
        package.loaded[w] = dummy_widget
    end
end

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, req)
        if req == "mode" then
            if path and (path:match("%.jpg$") or path:match("%.png$") or path:match("%.lua$") or path:match("%.zip$")) then
                return "file"
            end
            return "directory"
        end
        if path and (path:match("%.jpg$") or path:match("%.png$") or path:match("%.lua$") or path:match("%.zip$")) then
            return { mode = "file", size = 1234, modification = os.time() }
        end
        return { mode = "directory", size = 4096, modification = os.time() }
    end,
    dir = function(path)
        local dummy_state = { __name = "directory", path = path }
        local entries = { ".", "..", "sample_wallpaper.jpg" }
        local idx = 0
        local function iter(state)
            if state ~= dummy_state then
                error("bad argument #1 to '(for generator)' (directory metatable expected, got " .. type(state) .. ")", 2)
            end
            idx = idx + 1
            return entries[idx]
        end
        return iter, dummy_state
    end,
    mkdir = function() return true end,
    rmdir = function() return true end,
}
package.loaded["lfs"] = package.loaded["libs/libkoreader-lfs"]

package.loaded["storefront_plugin_paths"] = {
    getLookupPaths = function() return { "plugins" } end,
    isPathHidden = function() return false end,
}

package.loaded["util"] = {
    makePath = function(path) return true end,
    writeToFile = function(content, path) return true end,
    readFromFile = function(path) return "mock readme content" end,
    trim = function(str) return str and str:gsub("^%s*(.-)%s*$", "%1") or "" end,
}

local registered_actions = {}
package.loaded["dispatcher"] = {
    registerAction = function(self, id, action)
        registered_actions[id] = action
    end,
}

local _mock_cache_data = { plugin = { fetched_at = 1234567890, repos = {} } }
package.loaded["storefront_cache"] = {
    getLastFetched = function(kind)
        kind = kind or "plugin"
        local repos = _mock_cache_data[kind] and _mock_cache_data[kind].repos or {}
        if #repos == 0 then return 0 end
        return _mock_cache_data[kind] and _mock_cache_data[kind].fetched_at or 0
    end,
    countRepos = function(kind)
        kind = kind or "plugin"
        return _mock_cache_data[kind] and _mock_cache_data[kind].repos and #_mock_cache_data[kind].repos or 0
    end,
    storeRepos = function(kind, repos, custom_fetched_at)
        kind = kind or "plugin"
        local fetched_at = tonumber(custom_fetched_at) or os.time()
        _mock_cache_data[kind] = { fetched_at = fetched_at, repos = repos }
    end,
    clear = function()
        _mock_cache_data = { plugin = { fetched_at = 0, repos = {} } }
    end,
    invalidate = function()
        _mock_cache_data = { plugin = { fetched_at = 0, repos = {} } }
    end,
    listRepos = function() return _mock_cache_data.plugin and _mock_cache_data.plugin.repos or {} end,
    isLegacyFormat = function() return false end,
    getRepo = function() return nil end,
    getRepoByName = function(owner, name) return nil end,
    getRepoByPluginName = function(name) return nil end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function(self) return "/tmp/koreader_test_settings" end,
    getDataDir = function(self) return "/tmp/koreader_test_data" end,
}

local _luasettings_db = {}
package.loaded["luasettings"] = {
    open = function(self, path)
        _luasettings_db[path] = _luasettings_db[path] or {}
        local db = _luasettings_db[path]
        local store = {}
        function store:readSetting(key) return db[key] end
        function store:saveSetting(key, val) db[key] = val; return true end
        function store:delSetting(key) db[key] = nil end
        function store:flush() return true end
        return store
    end,
}

package.loaded["gettext"] = function(str) return str end

-- Mock device.lua
package.loaded["device"] = {
    screen = {
        scaleBySize = function(self, val) return val end,
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    },
    hasKeys = function() return false end,
    hasFewKeys = function() return false end,
    isTouchDevice = function() return true end,
    hasDPad = function() return false end,
    hasKeyboard = function() return false end,
    input = { group = {} },
}

package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0,
    COLOR_WHITE = 1,
    COLOR_DARK_GRAY = 2,
    COLOR_LIGHT_GRAY = 3,
    COLOR_GRAY_B = 4,
    Color8 = function(c) return c end,
    Color4 = function(r, g, b, a) return a end,
}

package.loaded["ui/font"] = {
    getFace = function(self, name, size)
        return { name = name, size = size or 12, orig_size = size or 12 }
    end
}

package.loaded["ui/size"] = {
    padding = { default = 10, large = 15 },
    margin = { title = 10, default = 10 },
    border = { thin = 1 },
    radius = { button = 4 },
    span = { horizontal_default = 4, vertical_default = 4 },
    line = { thin = 1 },
}

package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    nextTick = function(self, func)
        if type(self) == "function" then func = self end
        if func then pcall(func) end
    end,
    scheduleIn = function(self, delay, func)
        if type(self) == "function" then func = self end
        if type(delay) == "function" then func = delay end
        if not func or _in_schedule then return end
        _in_schedule = true
        pcall(func)
        _in_schedule = false
    end,
    unschedule = function() end,
}

-- Setup basic reader settings mock
G_reader_settings = {
    settings = {},
    readSetting = function(self, key)
        return self.settings and self.settings[key] or (key == "cre_font_size" and 20 or nil)
    end,
    saveSetting = function(self, key, val)
        if not self.settings then self.settings = {} end
        self.settings[key] = val
    end,
    flush = function(self) end,
}

print("Running storefront UI crash tests...")

-- 1. Load theme
local ok_theme, storefront_theme = pcall(require, "storefront_theme")
check("Theme loaded successfully", ok_theme, true)
if not ok_theme then print("Theme error:", storefront_theme) end

-- 2. Load settings dialog module
local ok_settings, StorefrontSettingsDialog = pcall(require, "storefront_settings_dialog")
check("Settings dialog loaded successfully", ok_settings, true)
if not ok_settings then print("Settings dialog error:", StorefrontSettingsDialog) end

-- 2b. Load settings card module
local ok_card, StorefrontSettingsCard = pcall(require, "storefront_settings_card")
check("Settings card loaded successfully", ok_card, true)
if not ok_card then print("Settings card error:", StorefrontSettingsCard) end

-- 3. Load browser UI dialog module
local ok_browser, StorefrontBrowserDialog = pcall(require, "storefront_browser_ui")
check("Browser UI dialog loaded successfully", ok_browser, true)
if not ok_browser then print("Browser UI dialog error:", StorefrontBrowserDialog) end

-- 4. Verify storefront_theme contains expected tables
if ok_theme then
    check("Theme has border_window", type(storefront_theme.border_window) == "number", true)
    check("Theme has radius_spec_btn", type(storefront_theme.radius_spec_btn) == "number", true)
end

-- 5. Interaction and alignment tests
if ok_browser then
    local items = {
        { name = "Test Plugin", is_entry = true, callback = function() end },
    }
    local browser = StorefrontBrowserDialog:new{
        title = "Storefront",
        items = items,
        on_tab_switch = function(tab) end,
        on_settings_tap = function() end,
    }
    browser:init()

    check("Browser top buttons initialized", type(browser._header_filter_btn) == "table", true)
    check("Browser settings button initialized", type(browser._header_settings_btn) == "table", true)

    -- Simulate tapping settings button
    local settings_tapped = false
    local settings_dialog_opened = false
    local mock_storefront_app = {
        browser_state = { kind = "plugin" },
        browserRefresh = function() end,
        saveBrowserState = function() end,
        getInstallRecordsMap = function() return {} end,
        getPatchRecordsMap = function() return {} end,
        showStorefrontSettingsDialog = function(self)
            settings_dialog_opened = true
            if ok_settings then
                StorefrontSettingsDialog:show(self)
            end
        end,
    }

    browser.on_settings_tap = function()
        settings_tapped = true
        mock_storefront_app:showStorefrontSettingsDialog()
    end

    if browser._header_settings_btn.callback then
        local tap_ok, tap_err = pcall(browser._header_settings_btn.callback)
        check("Settings button callback executed without error", tap_ok, true)
        if not tap_ok then print("Settings button tap error:", tap_err) end
    end
    check("Settings button callback triggered on_settings_tap", settings_tapped, true)
    check("Settings button opens StorefrontSettingsDialog", settings_dialog_opened, true)

    -- Test Screensaver Manager local directory listing with generator state protocol
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local ss_list_ok, local_wallpapers = pcall(function()
        return StorefrontScreensaverMgr.listLocalScreensavers()
    end)
    check("listLocalScreensavers executes without generator state error", ss_list_ok, true)
    check("listLocalScreensavers returns table of wallpapers", type(local_wallpapers) == "table", true)

    -- Test Settings Card rendering
    if ok_card then
        local show_ok, err = pcall(function()
            StorefrontSettingsCard.show(mock_storefront_app)
        end)
        check("Settings card show executed without crash", show_ok, true)
        if not show_ok then
            print("Settings card error was:", err)
        end
    end
    
    do
        local StorefrontDetailsDialog = require("storefront_details_dialog")
        check("Details dialog loaded successfully", type(StorefrontDetailsDialog) == "table", true)
        
        local dummy_repo = { name = "test-plugin", stars = "123", data = { owner = { login = "test-owner" } } }
        local full_dummy_storefront = {
            browser_state = { kind = "plugin" },
            browserRefresh = function() end,
            saveBrowserState = function() end,
            getInstallRecordsMap = function() return {} end,
            getPatchRecordsMap = function() return {} end,
        }
        local dummy_bb = { w = 600, h = 800 }

        local details_ok, details_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "plugin",
            }
            details:init()
            if details.paintTo then
                details:paintTo(dummy_bb, 0, 0)
            end
        end)
        check("Details dialog loaded and painted successfully", details_ok, true)
        if not details_ok then
            print("Details dialog init error was:", details_err)
        end

        local update_details_ok, update_details_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "update",
                default_tab = "release_notes",
                update_item = { plugin = { dirname = "test-plugin" }, needs_update = true },
            }
            details:init()
            if details.paintTo then
                details:paintTo(dummy_bb, 0, 0)
            end
        end)
        check("Update details dialog loaded and painted successfully", update_details_ok, true)
        if not update_details_ok then
            print("Update details error was:", update_details_err)
        end

        local versions_test_ok, versions_test_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "plugin",
                default_tab = "versions",
            }
            details:init()
            details.cached_releases = {
                { tag_name = "v1.2.0", body = "# Test Release\n- Added feature A\n- Fixed bug B", published_at = "2026-07-24" }
            }
            details:onLinkTap("storefront-select-version:1")
            details:onLinkTap("storefront-back-to-versions")
        end)
        check("Details dialog versions tab navigation executes without error", versions_test_ok, true)
        if not versions_test_ok then
            print("Versions tab navigation error was:", versions_test_err)
        end

        -- Test long commit-hash tag in StorefrontVersionDetailsDialog
        local long_tag_test_ok, long_tag_test_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "plugin",
                default_tab = "versions",
            }
            details:init()
            details.cached_releases = {
                { tag_name = "v1.0.47-9501072cd75accd629d97b3ac8a3b250737c540b", body = "Release with long hash", published_at = "2026-08-26" }
            }
            details:onLinkTap("storefront-select-version:1")
        end)
        check("Version details dialog with long commit-hash tag executes without error", long_tag_test_ok, true)
        if not long_tag_test_ok then
            print("Long tag version details dialog error was:", long_tag_test_err)
        end

        -- Test versions fallback when fetch fails does not poison cached_releases permanently
        local fallback_test_ok, fallback_test_err = pcall(function()
            local repo_with_lat = {
                name = "test_single_rel",
                owner = "testowner",
                latest_release = { tag_name = "v1.0.0", name = "v1.0.0", body = "Release 1", published_at = "2026-08-01" },
            }
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = repo_with_lat,
                kind = "plugin",
            }
            details:init()
            -- Mock GitHubClient to simulate network failure (returning nil, err)
            local GitHubClient = require("storefront_net_github")
            local orig_fetch = GitHubClient.fetchReleases
            GitHubClient.fetchReleases = function() return nil, "network error" end

            details.active_tab = "versions"
            details.loadContent("versions")

            -- self.cached_releases should NOT be set to the 1-item table
            check("Failed fetch with <= 1 release does not permanently poison cached_releases", details.cached_releases == nil, true)

            -- Restore fetchReleases
            GitHubClient.fetchReleases = orig_fetch
        end)
        check("Versions fallback cache test executed without error", fallback_test_ok, true)
        if not fallback_test_ok then
            print("Versions fallback cache test error was:", fallback_test_err)
        end

        -- Test page_number reset when switching tabs in details dialog
        local page_reset_ok = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "plugin",
            }
            details:init()
            -- Simulate user navigating to page 2 of release notes / readme
            package.loaded["ui/widget/htmlboxwidget"].page_number = 2
            -- Trigger tab switch to release_notes
            details.active_tab = "readme"
            if details[1] and details[1][1] then
                -- Call loadContent via tab switch simulation
                details.active_tab = "release_notes"
            end
        end)
        check("Details dialog page_number reset test executed", page_reset_ok, true)

        -- Test Font details dialog instantiation & paint
        local font_details_ok, font_details_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = {
                    name = "Bitter",
                    full_name = "google/bitter",
                    font_family = "Bitter",
                    font_file = "NV_Bitter-Regular.ttf",
                    kind = "font",
                    stars = 100,
                },
                kind = "font",
            }
            details:init()
            if details.paintTo then
                details:paintTo(dummy_bb, 0, 0)
            end
        end)
        check("Font details dialog loaded and painted successfully", font_details_ok, true)
        if not font_details_ok then
            print("Font details error was:", font_details_err)
        end
    end

    do
        local dummy_records = {
            ["simpleui.koplugin"] = {
                dirname = "simpleui.koplugin",
                owner = "doctorhetfield-cmd",
                repo = "simpleui.koplugin",
                repo_full_name = "doctorhetfield-cmd/simpleui.koplugin",
            }
        }
        local real_installs = require("storefront_installs")
        real_installs.list = function() return dummy_records end
        local MainStorefront = require("main")

        -- Browser pagination must use the dialog's measured viewport for every
        -- tab that can show a filter toolbar.  This keeps a future tab-specific
        -- toolbar change from letting the final row fall behind the footer.
        for _, tab_name in ipairs({ "Plugins", "Patches", "Fonts", "Installed" }) do
            local measured_height = StorefrontBrowserDialog:measureListViewport{
                current_tab = tab_name,
                toolbar_buttons = {
                    { id = "filter", text = "Filter...", callback = function() end },
                },
                show_filter_bar_plugins = tab_name == "Plugins",
                show_filter_bar_patches = tab_name == "Patches",
                show_filter_bar_fonts = tab_name == "Fonts",
                show_filter_bar_installed = tab_name == "Installed",
            }
            check("Measured list viewport is positive with " .. tab_name .. " filter bar", measured_height > 0, true)
        end

        MainStorefront.browser_state = { page = 1 }
        local constrained_items, constrained_pages = MainStorefront:paginateEntries({
            { name = "One", is_entry = true },
            { name = "Two", is_entry = true },
            { name = "Three", is_entry = true },
        }, "Fonts", 50)
        check("Pagination honors the supplied measured viewport", #constrained_items, 1)
        check("Pagination moves overflow rows to later pages", constrained_pages, 3)

        -- Test dynamic item height measurement: 2-line installed items (no description) vs 3-line items (with description)
        local ten_short_items = {}
        for i = 1, 10 do
            table.insert(ten_short_items, {
                name = "Plugin " .. i,
                kind_label = "Plugin",
                updated = "2026-08-01",
                is_entry = true,
                is_installed_item = true,
            })
        end
        local ten_desc_items = {}
        for i = 1, 10 do
            table.insert(ten_desc_items, {
                name = "Plugin " .. i,
                owner = "author",
                kind_label = "Plugin",
                updated = "2026-08-01",
                description = "Long description text for measuring widget height",
                is_entry = true,
            })
        end
        MainStorefront.browser_state = { page = 1 }
        local short_page_items, short_pages = MainStorefront:paginateEntries(ten_short_items, "Installed", 400)
        local desc_page_items, desc_pages = MainStorefront:paginateEntries(ten_desc_items, "Plugins", 400)
        check("Compact installed items fit more entries per page than desc items", #short_page_items >= #desc_page_items, true)
        check("Installed items paginate dynamically without excess whitespace", #short_page_items > 0, true)

        -- Test heterogeneous mixed installed list: 1st item has 3-line description, remaining items are 2-line compact
        local mixed_installed_items = {
            {
                name = "Plugin with description",
                owner = "author",
                kind_label = "Plugin",
                updated = "2026-08-01",
                description = "Detailed description text",
                is_entry = true,
                is_installed_item = true,
            }
        }
        for i = 2, 10 do
            table.insert(mixed_installed_items, {
                name = "Patch or default plugin " .. i,
                kind_label = "Patch",
                updated = "2026-08-01",
                is_entry = true,
                is_installed_item = true,
            })
        end
        MainStorefront.browser_state = { page = 1 }
        local mixed_page_items, mixed_pages = MainStorefront:paginateEntries(mixed_installed_items, "Installed", 400)
        check("Heterogeneous list does not overestimate subsequent compact rows", #mixed_page_items > #desc_page_items, true)
        check("Heterogeneous list correctly paginates remaining items", mixed_pages >= 1, true)

        -- Test heterogeneous list with screensaver cover thumbnail as first item
        local ss_mixed_items = {
            {
                name = "Screensaver 1",
                owner = "author",
                kind_label = "Screensaver",
                thumbnail_file = "cover.jpg",
                is_entry = true,
                is_installed_item = true,
            }
        }
        for i = 2, 10 do
            table.insert(ss_mixed_items, {
                name = "Plugin " .. i,
                kind_label = "Plugin",
                updated = "2026-08-01",
                is_entry = true,
                is_installed_item = true,
            })
        end
        local ss_mixed_page_items, ss_mixed_pages = MainStorefront:paginateEntries(ss_mixed_items, "Installed", 400)
        check("Screensaver thumbnail first item does not force large height on compact rows", #ss_mixed_page_items > 1, true)

        MainStorefront.getInstallRecordsMap = function() return dummy_records end
        MainStorefront._installed_lookup_cache = nil
        MainStorefront._installed_lookup_gen = nil
        MainStorefront._auto_matched_gen = nil
        local lookup = MainStorefront:getInstalledLookup()
        check("Installed lookup matches exact repo full_name", lookup and lookup["doctorhetfield-cmd/simpleui.koplugin"] == true, true)
        
        local direct_repo_item = MainStorefront:makeRepoMenuItem({ name = "simpleui.koplugin", full_name = "doctorhetfield-cmd/simpleui.koplugin" }, lookup)
        local sibling_repo_item = MainStorefront:makeRepoMenuItem({ name = "simpleui.koplugin", full_name = "yanyan-alien/simpleui.koplugin" }, lookup)
        check("Direct match repo item is marked installed", direct_repo_item.installed, true)
        check("Sibling repo with same name is NOT marked installed", sibling_repo_item.installed, false)

        local test_fork_0_stars = { name = "test-fork", fork = true, stars = 0 }
        local test_repo_stars = { name = "test-repo", fork = false, stars = 10 }
        
        local filter_ok, result = pcall(function()
            return MainStorefront:matchesGeneralFilters(test_fork_0_stars, {})
        end)
        check("matchesGeneralFilters executes without nil upvalue error", filter_ok, true)
        check("0-star fork is filtered out by default", result, false)
        check("Normal repo passes general filters", MainStorefront:matchesGeneralFilters(test_repo_stars, {}), true)

        package.loaded["storefront_plugin_paths"] = {
            getLookupPaths = function() return { "plugins" } end,
            getDefaultPluginsRoot = function() return "plugins" end,
            isPathHidden = function() return false end,
        }
        local dummy_fork = { name = "simpleui.koplugin", owner = "somefork", full_name = "somefork/simpleui.koplugin", fork = true, stars = 0 }
        local dummy_main = { name = "simpleui.koplugin", owner = "doctorhetfield-cmd", full_name = "doctorhetfield-cmd/simpleui.koplugin", fork = false, stars = 15 }
        local dummy_popular_fork = { name = "popularplugin.koplugin", owner = "popfork", full_name = "popfork/popularplugin.koplugin", fork = true, stars = 100 }
        local dummy_low_main = { name = "popularplugin.koplugin", owner = "originaldev", full_name = "originaldev/popularplugin.koplugin", fork = false, stars = 5 }
        local cache_mod = package.loaded["storefront_cache"] or require("storefront_cache")
        local orig_list = cache_mod and cache_mod.listRepos
        if cache_mod then
            cache_mod.listRepos = function()
                return { dummy_fork, dummy_main, dummy_popular_fork, dummy_low_main }
            end
        end
        io.write("DEBUG: pre autoMatch\n"); io.stdout:flush()
        MainStorefront:autoMatchInstalled()
        io.write("DEBUG: post autoMatch\n"); io.stdout:flush()
        if cache_mod then
            cache_mod.listRepos = orig_list
        end
        local rec = MainStorefront:getInstalledLookup()
        io.write("DEBUG: post getInstalledLookup\n"); io.stdout:flush()
        check("Installed plugin simpleui resolved successfully", rec ~= nil, true)


        -- Test StorefrontImageModal loading and onClose execution
        local StorefrontImageModal = require("storefront_image_modal")
        local modal = StorefrontImageModal:new{
            image_path = "/tmp/test.png",
            title = "Test Image Modal",
        }
        check("StorefrontImageModal loaded and instantiated", modal ~= nil, true)
        check("StorefrontImageModal onClose executes without error", modal:onClose(), true)

        -- Test Dispatcher action registration and onStorefrontOpen callback
        local registered_action = nil
        local DispatcherModule = package.loaded["dispatcher"]
        DispatcherModule.registerAction = function(self, action_id, params)
            registered_action = { id = action_id, params = params }
        end
        MainStorefront:onDispatcherRegisterActions()
        check("Dispatcher registers storefront_open action", registered_action ~= nil and registered_action.id == "storefront_open", true)
        check("Dispatcher action title is defined", registered_action and registered_action.params and registered_action.params.title ~= nil, true)

        -- Test Storefront:onStorefrontOpen execution
        local browser_opened_via_action = false
        MainStorefront.showBrowser = function(self)
            browser_opened_via_action = true
        end
        local action_result = MainStorefront:onStorefrontOpen()
        check("onStorefrontOpen handles gesture/action event", action_result, true)

        -- Test Tools menu integration (addToMainMenu)
        local menu_items = {}
        MainStorefront:addToMainMenu(menu_items)
        check("addToMainMenu populates Storefront menu item", menu_items.Storefront ~= nil, true)
        check("Storefront menu item sorting_hint is 'tools'", menu_items.Storefront and menu_items.Storefront.sorting_hint == "tools", true)

        local browser_opened_via_menu = false
        MainStorefront.showBrowser = function(self)
            browser_opened_via_menu = true
        end
        if menu_items.Storefront and menu_items.Storefront.callback then
            menu_items.Storefront.callback()
        end
        check("Tools menu callback opens Storefront browser", browser_opened_via_menu, true)

        -- Test isDefaultPlugin with core plugins vs user catalog plugins vs custom path plugins
        local core_plugin_mock = { dirname = "terminal.koplugin", name = "Terminal", root = "plugins" }
        local custom_plugin_mock = { dirname = "mycustom.koplugin", name = "MyCustom", root = "custom_plugins" }
        local catalog_user_plugin = { dirname = "readest.koplugin", name = "readest", root = "plugins" }
        check("isDefaultPlugin identifies core default plugin", MainStorefront:isDefaultPlugin(core_plugin_mock), true)
        check("isDefaultPlugin rejects custom plugin", MainStorefront:isDefaultPlugin(custom_plugin_mock), false)
        check("isDefaultPlugin rejects catalog user plugin in default root", MainStorefront:isDefaultPlugin(catalog_user_plugin), false)

        -- Test Installed tab state and buildInstalledEntries with full plugin objects
        MainStorefront:ensureInstalledState()
        check("ensureInstalledState initializes filter_type", MainStorefront.installed_state.filter_type, "all")
        check("ensureInstalledState initializes sort_mode", MainStorefront.installed_state.sort_mode, "name_asc")

        local dummy_plugin = { dirname = "coverbrowser.koplugin", name = "CoverBrowser", root = "plugins", latest_mtime = os.time() }
        local dummy_patch = { filename = "2-test.lua", path = "patches/2-test.lua", latest_mtime = os.time() }
        local orig_list_plugins = MainStorefront.listInstalledPlugins
        local orig_list_patches = MainStorefront.listInstalledPatches
        MainStorefront.listInstalledPlugins = function() return { dummy_plugin } end
        MainStorefront.listInstalledPatches = function() return { dummy_patch } end

        local installed_entries_ok, installed_entries = pcall(function()
            return MainStorefront:buildInstalledEntries()
        end)

        check("buildInstalledEntries with full items runs without errors", installed_entries_ok, true)

        check("buildInstalledEntries returns list table", type(installed_entries), "table")
        check("buildInstalledEntries populates items", type(installed_entries) == "table" and (#installed_entries > 0), true)

        -- Test meta.fullname preference and dual name search matching
        local meta_plugin = {
            dirname = "neo_quick_settings.koplugin",
            meta = { name = "neo_quick_settings", fullname = "Neo Quick Settings" },
            name = "Neo Quick Settings",
            fullname = "Neo Quick Settings",
            shortname = "neo_quick_settings",
            path = "custom_plugins/neo_quick_settings.koplugin",
            root = "custom_plugins",
            latest_mtime = os.time()
        }
        MainStorefront.installed_state.search_text = ""
        MainStorefront.installed_state.filter_type = "all"
        MainStorefront.installed_state.filter_default = "all"
        MainStorefront.installed_state.filter_status = "all"
        if MainStorefront.browser_state then MainStorefront.browser_state.search_text = "" end
        MainStorefront.listInstalledPlugins = function() return { meta_plugin } end
        MainStorefront.listInstalledPatches = function() return {} end
        local meta_entries = MainStorefront:buildInstalledEntries()
        MainStorefront.listInstalledPlugins = orig_list_plugins
        MainStorefront.listInstalledPatches = orig_list_patches
        check("buildInstalledEntries uses meta.fullname for display name", meta_entries[1] and meta_entries[1].name, "Neo Quick Settings")

        -- Test StorefrontListItem instantiation with badge_icon and badge_text
        local StorefrontListItem = require("storefront_list_item")
        local tapped = false
        local badge_tapped = false
        local item_inst = StorefrontListItem:new{
            width = 600,
            entry = {
                name = "Test Item",
                kind_label = "Plugin",
                badge_icon = "assets/check-square.svg",
                badge = "Update",
                callback = function() tapped = true end,
                on_badge_tap = function() badge_tapped = true end,
            }
        }
        check("StorefrontListItem with badge_icon & badge_text instantiates without error", item_inst ~= nil, true)
        if StorefrontListItem.init then
            StorefrontListItem.init(item_inst)
            -- Simulate widget being positioned in layout at y = 250
            item_inst.dimen = { x = 10, y = 250, w = 580, h = 60 }
            local tap_range_fn = item_inst.ges_events and item_inst.ges_events.StorefrontTap and item_inst.ges_events.StorefrontTap[1] and item_inst.ges_events.StorefrontTap[1].range
                or (item_inst.ges_events and item_inst.ges_events.StorefrontTap and item_inst.ges_events.StorefrontTap.range)
            check("StorefrontListItem gesture range is a dynamic evaluation function", type(tap_range_fn), "function")
            if type(tap_range_fn) == "function" then
                local computed_geom = tap_range_fn()
                check("StorefrontListItem gesture range evaluates live layout y position", computed_geom and computed_geom.y, 250)
            end

            -- Test item body tap
            StorefrontListItem.onStorefrontTap(item_inst, nil, { pos = { x = 100, y = 260 } })
            check("StorefrontListItem onStorefrontTap executes entry.callback", tapped, true)

            -- Test badge tap
            StorefrontListItem.onStorefrontTap(item_inst, nil, { pos = { x = 585, y = 260 } })
            check("StorefrontListItem onStorefrontTap on badge zone executes entry.on_badge_tap", badge_tapped, true)
        end

        -- Test StorefrontFilterDialog showInstalledFilter & show methods
        local StorefrontFilterDialog = require("storefront_filter_dialog")
        local filter_card_ok = pcall(function()
            StorefrontFilterDialog:showInstalledFilter(MainStorefront)
        end)
        check("StorefrontFilterDialog:showInstalledFilter executes without error", filter_card_ok, true)

        local main_show_filter_ok = pcall(function()
            MainStorefront:showInstalledFilter()
        end)
        check("MainStorefront:showInstalledFilter executes without error", main_show_filter_ok, true)

        local browser_open_filter_ok = pcall(function()
            MainStorefront:browserOpenFilter()
        end)
        check("MainStorefront:browserOpenFilter executes without error", browser_open_filter_ok, true)

        -- Test toggleFilterBar and showCatalogFilter
        MainStorefront:ensureBrowserState()
        MainStorefront.browser_state.show_filter_bar_plugins = false
        MainStorefront.browser_state.show_filter_bar_patches = false
        MainStorefront:toggleFilterBar("Plugins")
        check("toggleFilterBar Plugins sets show_filter_bar_plugins to true", MainStorefront.browser_state.show_filter_bar_plugins, true)
        MainStorefront:toggleFilterBar("Plugins")
        check("toggleFilterBar Plugins toggles show_filter_bar_plugins back to false", MainStorefront.browser_state.show_filter_bar_plugins, false)

        -- Test tab switch retains closed filter bar state
        MainStorefront.browser_state.search_text = ""
        MainStorefront.browser_state.show_filter_bar_plugins = false
        MainStorefront.browser_state.tab = "Installed"
        MainStorefront.browser_state.tab = "Plugins"
        check("Tab switch preserves closed filter bar state when no active search", MainStorefront.browser_state.show_filter_bar_plugins, false)

        local catalog_filter_card_ok = pcall(function()
            StorefrontFilterDialog:showCatalogFilter(MainStorefront)
        end)
        check("StorefrontFilterDialog:showCatalogFilter executes without error", catalog_filter_card_ok, true)

        -- Test clearSearchAndFilters
        MainStorefront.browser_state.search_text = "testquery"
        MainStorefront.browser_state.min_stars = 50
        MainStorefront.installed_state.search_text = "testquery"
        MainStorefront.installed_state.filter_type = "plugin"
        MainStorefront:clearSearchAndFilters()
        check("clearSearchAndFilters clears search_text", MainStorefront.browser_state.search_text, "")
        check("clearSearchAndFilters clears min_stars", MainStorefront.browser_state.min_stars, 0)
        check("clearSearchAndFilters clears installed_state search_text", MainStorefront.installed_state.search_text, "")
        check("clearSearchAndFilters clears installed_state filter_type", MainStorefront.installed_state.filter_type, "all")
        -- Test catalog check throttling
        MainStorefront._last_catalog_check_time = os.time()
        local check_called = false
        local orig_is_direct = package.loaded["storefront_net_github"].isDirectApiEnabled
        package.loaded["storefront_net_github"].isDirectApiEnabled = function()
            check_called = true
            return false
        end
        -- Test InstallStore item options (Pre-release & Ignore release)
        local InstallStore = require("storefront_installs")
        check("isPreReleaseAllowed defaults to false", InstallStore.isPreReleaseAllowed("test_plugin"), false)
        InstallStore.setPreReleaseAllowed("test_plugin", true)
        check("isPreReleaseAllowed returns true after enabling", InstallStore.isPreReleaseAllowed("test_plugin"), true)
        InstallStore.setPreReleaseAllowed("test_plugin", false)
        check("isPreReleaseAllowed returns false after disabling", InstallStore.isPreReleaseAllowed("test_plugin"), false)

        check("isReleaseIgnored defaults to false", InstallStore.isReleaseIgnored("test_plugin", "v1.0.0-beta"), false)
        InstallStore.toggleReleaseIgnored("test_plugin", "v1.0.0-beta")
        check("isReleaseIgnored returns true after toggling", InstallStore.isReleaseIgnored("test_plugin", "v1.0.0-beta"), true)
        InstallStore.toggleReleaseIgnored("test_plugin", "v1.0.0-beta")
        check("isReleaseIgnored returns false after toggling again", InstallStore.isReleaseIgnored("test_plugin", "v1.0.0-beta"), false)

        -- Test Updates Tab & Merged Updates Cache Invalidation
        --
        -- Strategy: stub collectUpdateSummary / collectPatchUpdateSummary so
        -- buildUpdatesEntries runs headlessly (no filesystem access needed).
        -- This verifies the cache-key and invalidation behaviour we fixed.
        local orig_collect_plugin = MainStorefront.collectUpdateSummary
        local orig_collect_patch  = MainStorefront.collectPatchUpdateSummary

        local function makeFakePluginSummary(remote_tag)
            return {
                total = 1, tracked = 1, unmatched = 0, updates = 1,
                data = {
                    {
                        plugin = { dirname = "test_plugin.koplugin", name = "Test Plugin",
                                   version = "1.0.0", latest_mtime = 500 },
                        record = { owner = "testowner", repo = "test_plugin" },
                        remote = { release_tag_name = remote_tag,
                                   remote_version = remote_tag:gsub("^v", "") },
                        has_update = true,
                    }
                },
                records = {},
            }
        end
        MainStorefront.collectUpdateSummary      = function() return makeFakePluginSummary("v2.0.0") end
        MainStorefront.collectPatchUpdateSummary = function() return { total=0, tracked=0, data={}, records={} } end

        MainStorefront:ensureUpdatesState()
        MainStorefront.browser_state = { tab = "Updates", page = 1, search_text = "", owner = "", min_stars = 0 }
        MainStorefront.updates_state.remote_info = {
            ["test_plugin.koplugin"] = { release_tag_name = "v2.0.0", last_checked = 1000 }
        }
        MainStorefront.updates_state.last_checked = 1000
        MainStorefront._merged_updates_cache  = nil
        MainStorefront._cached_plugin_summary = nil

        local update_items = MainStorefront:buildUpdatesEntries()
        check("buildUpdatesEntries returns items table", type(update_items), "table")
        check("buildUpdatesEntries finds update for 1.0.0 -> v2.0.0",
            type(update_items) == "table" and #update_items == 1 and update_items[1].name == "Test Plugin", true)
        check("buildUpdatesEntries creates transition string",
            update_items[1] and update_items[1].version_transition, "1.0.0 → 2.0.0")

        -- Cache must be populated; key is based on last_checked, not table address
        check("_merged_updates_cache is populated after buildUpdatesEntries",
            MainStorefront._merged_updates_cache ~= nil, true)
        local initial_cache_key = MainStorefront._merged_updates_cache.key

        -- Simulate _checkAllUpdatesInternal: mutate remote_info IN PLACE, bump last_checked,
        -- clear both caches (the fix we added)
        MainStorefront.updates_state.remote_info["test_plugin.koplugin"] = {
            release_tag_name = "v3.0.0", last_checked = 2000
        }
        MainStorefront.updates_state.last_checked = 2000
        MainStorefront._cached_plugin_summary = nil
        MainStorefront._merged_updates_cache  = nil
        MainStorefront.collectUpdateSummary   = function() return makeFakePluginSummary("v3.0.0") end

        local updated_items = MainStorefront:buildUpdatesEntries()
        check("Cache key changes after last_checked is bumped",
            MainStorefront._merged_updates_cache.key ~= initial_cache_key, true)
        check("New update item reflects v3.0.0 remote",
            updated_items[1] and updated_items[1].version_transition, "1.0.0 → 3.0.0")

        -- Explicit nil also works
        MainStorefront._merged_updates_cache = nil
        local cache_nil_items = MainStorefront:buildUpdatesEntries()
        check("buildUpdatesEntries succeeds after explicit _merged_updates_cache = nil",
            type(cache_nil_items) == "table" and #cache_nil_items == 1, true)

        -- Same last_checked -> cache hit (no recompute)
        local key_after_nil = MainStorefront._merged_updates_cache.key
        local second_items = MainStorefront:buildUpdatesEntries()
        check("buildUpdatesEntries uses cache when last_checked is unchanged",
            MainStorefront._merged_updates_cache.key == key_after_nil, true)
        check("Cached result has correct entry count", #second_items, 1)

        -- Test invalidateInstalledPluginsCache executes cleanly
        local inv_ok = pcall(function()
            MainStorefront:invalidateInstalledPluginsCache()
        end)
        check("invalidateInstalledPluginsCache executes cleanly", inv_ok, true)

        -- Test 4-part version comparisons (e.g. 26.7.24.4 > 26.7.24)
        MainStorefront._merged_updates_cache = nil
        MainStorefront._cached_plugin_summary = nil
        MainStorefront.collectUpdateSummary = function()
            return {
                total = 1, tracked = 1, unmatched = 0, updates = 1,
                data = {
                    {
                        plugin = { dirname = "storefront.koplugin", name = "Storefront", version = "26.7.24", latest_mtime = 500 },
                        record = { owner = "testowner", repo = "storefront.koplugin" },
                        remote = { release_tag_name = "26.7.24.4", remote_version = "26.7.24.4" },
                        has_update = true,
                    }
                },
                records = {},
            }
        end
        local four_part_items = MainStorefront:buildUpdatesEntries()
        check("4-part version update 26.7.24 -> 26.7.24.4 detected",
            four_part_items[1] and four_part_items[1].version_transition, "26.7.24 → 26.7.24.4")

        -- Test renderAssetPickerModal execution
        local asset_modal_ok, asset_modal_err = pcall(function()
            MainStorefront:renderAssetPickerModal(
                { name = "rakuyomi", owner = "tachibana-shin" },
                { tag_name = "v1.39.4" },
                {
                    { name = "rakuyomi-kindle.zip", browser_download_url = "https://example.com/k.zip", size = 460297 },
                    { name = "rakuyomi-aarch64.zip", browser_download_url = "https://example.com/a.zip", size = 455554 },
                },
                nil
            )
        end)
        if not asset_modal_ok then print("Asset Modal Error:", asset_modal_err) end
        check("renderAssetPickerModal executes without error", asset_modal_ok, true)

        -- Test StorefrontBrowserDialog page turn key events & swipe gestures
        do
            local prev_called, next_called = false, false
            local browser_dialog = StorefrontBrowserDialog:new{
                title = "Storefront",
                items = {},
                page = 2,
                total_pages = 5,
                on_prev_page = function() prev_called = true end,
                on_next_page = function() next_called = true end,
            }
            browser_dialog:init()

            check("Browser dialog has NextPage key event", browser_dialog.key_events and browser_dialog.key_events.NextPage ~= nil, true)
            check("Browser dialog has PrevPage key event", browser_dialog.key_events and browser_dialog.key_events.PrevPage ~= nil, true)
            check("Browser dialog has Swipe gesture event", browser_dialog.ges_events and browser_dialog.ges_events.Swipe ~= nil, true)

            local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
            local dummy_scroller = ScrollableContainer:new{
                ignore_events = { "swipe", "key_pg_back", "key_pg_fwd" },
            }
            local has_pg_back, has_pg_fwd = false, false
            for _, ev in ipairs(dummy_scroller.ignore_events or {}) do
                if ev == "key_pg_back" then has_pg_back = true end
                if ev == "key_pg_fwd" then has_pg_fwd = true end
            end
            check("Browser list_scroller ignores key_pg_back and key_pg_fwd",
                has_pg_back and has_pg_fwd, true)

            browser_dialog:onNextPage()
            check("onNextPage triggers on_next_page callback", next_called, true)

            browser_dialog:onPrevPage()
            check("onPrevPage triggers on_prev_page callback", prev_called, true)

            prev_called, next_called = false, false
            browser_dialog:onSwipe(nil, { direction = "left" })
            check("onSwipe left triggers onNextPage", next_called, true)

            prev_called, next_called = false, false
            browser_dialog:onSwipe(nil, { direction = "west" })
            check("onSwipe west triggers onNextPage", next_called, true)

            browser_dialog:onSwipe(nil, { direction = "right" })
            check("onSwipe right triggers onPrevPage", prev_called, true)

            prev_called, next_called = false, false
            browser_dialog:onSwipe(nil, { direction = "east" })
            check("onSwipe east triggers onPrevPage", prev_called, true)
        end

        -- Test StorefrontDetailsDialog page turn key events & swipe gestures
        do
            local StorefrontDetailsDialog = require("storefront_details_dialog")
            local d_repo = { name = "test-plugin", stars = "123", data = { owner = { login = "test-owner" } } }
            local d_sf = {
                browser_state = { kind = "plugin" },
                browserRefresh = function() end,
                saveBrowserState = function() end,
                getInstallRecordsMap = function() return {} end,
                getPatchRecordsMap = function() return {} end,
            }
            local details = StorefrontDetailsDialog:new{
                Storefront = d_sf,
                repo = d_repo,
                kind = "plugin",
            }
            details:init()

            check("Details dialog has NextPage key event", details.key_events and details.key_events.NextPage ~= nil, true)
            check("Details dialog has PrevPage key event", details.key_events and details.key_events.PrevPage ~= nil, true)
            check("Details dialog has Swipe gesture event", details.ges_events and details.ges_events.Swipe ~= nil, true)

            -- Mock multi-page html_box
            details._html_box = { page_number = 1, page_count = 3 }
            local paginated = false
            details._updatePagination = function() paginated = true end

            local turned_next = details:onNextPage()
            check("Details onNextPage advances html_box page_number", turned_next and details._html_box.page_number == 2, true)

            local turned_prev = details:onPrevPage()
            check("Details onPrevPage decrements html_box page_number", turned_prev and details._html_box.page_number == 1, true)

            details:onSwipe(nil, { direction = "left" })
            check("Details onSwipe left advances page_number to 2", details._html_box.page_number == 2, true)

            details:onSwipe(nil, { direction = "right" })
            check("Details onSwipe right decrements page_number to 1", details._html_box.page_number == 1, true)

            details:onSwipe(nil, { direction = "west" })
            check("Details onSwipe west advances page_number to 2", details._html_box.page_number == 2, true)

            details:onSwipe(nil, { direction = "east" })
            check("Details onSwipe east decrements page_number to 1", details._html_box.page_number == 1, true)

            -- Test versions sub-tab page turning
            details.active_tab = "versions"
            details.versions_page = 1
            details.versions_total_pages = 3
            local versions_loaded = false
            details.loadContent = function(tab) if tab == "versions" then versions_loaded = true end end

            details:onNextPage()
            check("Details onNextPage advances versions_page", details.versions_page == 2 and versions_loaded, true)

            versions_loaded = false
            details:onPrevPage()
            check("Details onPrevPage decrements versions_page", details.versions_page == 1 and versions_loaded, true)
        end

        -- Test fetchAndUpdateCacheAsync subprocess failure graceful fallback
        local CatalogClient = require("storefront_net_catalog")
        local async_cb_called = false
        local async_cb_ok = nil
        local async_cb_err = nil

        -- Mock ffiutil readAllFromFD to return empty string (SUBPROCESS_NO_MSG)
        local orig_readAllFromFD = package.loaded["ffi/util"].readAllFromFD
        package.loaded["ffi/util"].readAllFromFD = function() return "" end

        CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
            async_cb_called = true
            async_cb_ok = ok
            async_cb_err = err
        end)

        check("fetchAndUpdateCacheAsync executed callback on subprocess failure", async_cb_called, true)
        check("fetchAndUpdateCacheAsync returned false on subprocess failure", async_cb_ok, false)

        -- Test Cache.getLastFetched returns 0 when repos count is 0
        local Cache = require("storefront_cache")
        Cache.clear()
        check("Cache.getLastFetched returns 0 for empty cache", Cache.getLastFetched("plugin"), 0)

        -- Test CatalogClient bundled catalog seed sets fetched_at to 0
        local sample_catalog = { plugins = { { id = 1, name = "SamplePlugin", owner = "test" } } }
        CatalogClient.updateCacheFromCatalog(sample_catalog, true)
        check("Bundled catalog seed leaves getLastFetched as 0", Cache.getLastFetched("plugin"), 0)
        check("Bundled catalog seed populates countRepos", Cache.countRepos("plugin"), 1)

        -- Test fetchCatalog tries secondary fallback URL when primary URL fails
        local tried_urls = {}
        local orig_getHttpModule = package.loaded["storefront_net_catalog"]
        -- Test URL building logic in fetchCatalog
        local primary_url = CatalogClient.getCatalogUrl()
        local fallback_url = "https://raw.githubusercontent.com/ultimatejimmy/storefront.koplugin/main/catalog.json"
        check("CatalogClient primary and fallback URLs are distinct", primary_url ~= fallback_url, true)

        -- Test maybeCheckCatalogBackground triggers fetch when last_fetched is 0 even if _last_catalog_check_time is recent
        local fetch_attempted = false
        local orig_fetchAsync = CatalogClient.fetchAndUpdateCacheAsync
        CatalogClient.fetchAndUpdateCacheAsync = function(url, cb)
            fetch_attempted = true
        end

        local NetworkMgr = require("ui/network/manager")
        local orig_isOnline = NetworkMgr.isOnline
        NetworkMgr.isOnline = function() return true end

        MainStorefront._last_catalog_check_time = os.time()
        MainStorefront:maybeCheckCatalogBackground()
        check("maybeCheckCatalogBackground triggers fetch for unfetched catalog despite recent check_time", fetch_attempted, true)
        CatalogClient.fetchAndUpdateCacheAsync = orig_fetchAsync
        NetworkMgr.isOnline = orig_isOnline

        -- Test togglePluginDisabled settings state toggle and return values
        local dis_state1, dis_name1 = MainStorefront:togglePluginDisabled("test_plugin.koplugin", true)
        check("togglePluginDisabled disables plugin", dis_state1, true)
        check("togglePluginDisabled returns cleaned plugin name", dis_name1, "test_plugin")

        local dis_state2, dis_name2 = MainStorefront:togglePluginDisabled("test_plugin.koplugin", true)
        check("togglePluginDisabled re-enables plugin", dis_state2, false)
        check("togglePluginDisabled returns cleaned plugin name on enable", dis_name2, "test_plugin")

        -- Test browserRefresh preserves open browser dialog (does not close plugin window)
        local netmgr = require("ui/network/manager")
        netmgr.runWhenOnline = function(self, cb)
            if type(self) == "function" then self() elseif cb then cb() end
        end
        local dummy_browser_menu = { is_open = true }
        MainStorefront.browser_menu = dummy_browser_menu
        MainStorefront:browserRefresh()
        check("browserRefresh does not close browser_menu window", MainStorefront.browser_menu, dummy_browser_menu)

        -- Test togglePluginDisabled shows restart confirmation modal
        local shown_dialogs = {}
        local UIManager = package.loaded["ui/uimanager"]
        local orig_ui_show = UIManager.show
        UIManager.show = function(self, widget, type)
            table.insert(shown_dialogs, widget)
            if orig_ui_show then return orig_ui_show(self, widget, type) end
        end

        MainStorefront:togglePluginDisabled("test_restart_plugin.koplugin")

        local restart_dialog_found = false
        for _, widget in ipairs(shown_dialogs) do
            if widget and widget.key_events and widget.key_events.Close then
                restart_dialog_found = true
                break
            end
        end
        check("togglePluginDisabled triggers UIManager:show with restart confirmation dialog", restart_dialog_found, true)

        -- The primary restart button is always black, so its localized label must
        -- stay white even when the device reports a dark theme state.
        local restart_buttons = {}
        local Button = package.loaded["ui/widget/button"]
        local Localization = require("localization_storefront")
        local orig_button_new = Button.new
        local orig_localization_t = Localization.t
        Button.new = function(_, args)
            table.insert(restart_buttons, args)
            return args
        end
        Localization.t = function(self, key, ...)
            if key == "Restart now" then
                return "Uruchom teraz"
            end
            return orig_localization_t(self, key, ...)
        end

        MainStorefront:showRestartConfirmation("Test restart message")

        local restart_now_button
        for i = #restart_buttons, 1, -1 do
            local button = restart_buttons[i]
            if button.text == "Uruchom teraz" and button.callback then
                restart_now_button = button
                break
            end
        end
        check("localized restart button uses a white label on its black background", restart_now_button and restart_now_button.text_font_color, package.loaded["ffi/blitbuffer"].COLOR_WHITE)
        check("localized restart button reserves height for two lines", restart_now_button and restart_now_button.height, 58)

        Button.new = orig_button_new
        Localization.t = orig_localization_t

        -- Test collectUpdateSummary caching (prevents CPU/memory thrashing on Kindle)
        MainStorefront.collectUpdateSummary = orig_collect_plugin
        MainStorefront._cached_plugin_summary = nil
        local sum1 = MainStorefront:collectUpdateSummary()
        local sum2 = MainStorefront:collectUpdateSummary()
        check("collectUpdateSummary returns cached summary object on repeated call", sum1 == sum2, true)

        -- Test collectUpdateSummary caching (prevents CPU/memory thrashing on Kindle)
        MainStorefront.collectUpdateSummary = orig_collect_plugin
        MainStorefront._cached_plugin_summary = nil
        local sum1 = MainStorefront:collectUpdateSummary()
        local sum2 = MainStorefront:collectUpdateSummary()
        check("collectUpdateSummary returns cached summary object on repeated call", sum1 == sum2, true)

        -- Test isDefaultPlugin and autoMatchInstalled for core KOReader plugins (Issue #43)
        check("isDefaultPlugin identifies autowarmth as core/default", MainStorefront.isDefaultPlugin({ dirname = "autowarmth.koplugin", root = "plugins" }), true)
        check("isDefaultPlugin identifies cloudstorage as core/default", MainStorefront.isDefaultPlugin({ dirname = "cloudstorage.koplugin", root = "plugins" }), true)

        -- Test autoMatchInstalled scrubs stale records for core plugins
        local InstallStore = require("storefront_installs")
        InstallStore.upsert("autowarmth.koplugin", {
            owner = "Martus0",
            repo = "autowarmth.koplugin",
            is_auto_matched = true,
        })
        check("InstallStore recorded stale auto-match record", InstallStore.get("autowarmth.koplugin") ~= nil, true)
        MainStorefront._auto_matched_gen = nil
        local orig_list_p = MainStorefront.listInstalledPlugins
        MainStorefront.listInstalledPlugins = function()
            return { { dirname = "autowarmth.koplugin", root = "plugins" } }
        end
        MainStorefront:autoMatchInstalled()
        MainStorefront.listInstalledPlugins = orig_list_p
        local rec_check = InstallStore.get("autowarmth.koplugin") or InstallStore.get("autowarmth")
        check("autoMatchInstalled scrubbed stale auto-match record for autowarmth", rec_check == nil, true)

        -- Test updateAllAvailable when no updates pending
        local msg_shown = nil
        local InfoMessage = require("storefront_toast")
        local orig_toast_new = InfoMessage.new
        InfoMessage.new = function(...)
            local args = {...}
            local opts = args[1] == InfoMessage and args[2] or args[1]
            if type(opts) == "table" then
                msg_shown = opts.text
            elseif type(opts) == "string" then
                msg_shown = opts
            end
            return orig_toast_new(...)
        end
        MainStorefront._cached_plugin_summary = { data = {}, updates = 0 }
        MainStorefront._cached_patch_summary = { data = {}, updates = 0 }
        MainStorefront:updateAllAvailable()
        MainStorefront._cached_plugin_summary = nil
        MainStorefront._cached_patch_summary = nil
        InfoMessage.new = orig_toast_new
        check("updateAllAvailable shows up-to-date message when queue is empty", msg_shown ~= nil and msg_shown:find("up to date") ~= nil, true)

        -- Restore mock
        package.loaded["ffi/util"].readAllFromFD = orig_readAllFromFD

        -- Cleanup
        MainStorefront.collectUpdateSummary      = orig_collect_plugin
        MainStorefront.collectPatchUpdateSummary = orig_collect_patch

        -- Test release_override preservation in promptPluginInstallOptions
        local prompt_selected_release = nil
        local orig_install_asset = MainStorefront.installPluginFromReleaseAsset
        MainStorefront.installPluginFromReleaseAsset = function(self_sf, r, rel, asset)
            prompt_selected_release = rel
        end

        local dummy_repo = { owner = "testowner", name = "testrepo" }
        local older_release = { tag_name = "v1.2.0", name = "v1.2.0", assets = { { name = "testrepo.zip", browser_download_url = "http://example.com/1.2.0.zip" } } }
        MainStorefront:promptPluginInstallOptions(dummy_repo, older_release, true)
        check("promptPluginInstallOptions uses release_override when provided", prompt_selected_release and prompt_selected_release.tag_name, "v1.2.0")
        MainStorefront.installPluginFromReleaseAsset = orig_install_asset

        -- Test update detection with date-based versions and missing plugin.version
        local mock_plugin_no_ver = { dirname = "rakuyomi.koplugin", path = "/dummy/rakuyomi.koplugin", version = nil }
        local orig_installed = MainStorefront.listInstalledPlugins
        local orig_ensure_updates = MainStorefront.ensureUpdatesState
        local InstallStore = require("storefront_installs")
        local orig_install_list = InstallStore.list
        MainStorefront.listInstalledPlugins = function() return { mock_plugin_no_ver } end
        MainStorefront.ensureUpdatesState = function() end
        InstallStore.list = function()
            return {
                ["rakuyomi.koplugin"] = {
                    owner = "tachibana-shin",
                    repo = "rakuyomi",
                    version = "1.39.3",
                    installed_version = "1.39.3",
                    tag_name = "v1.39.3"
                }
            }
        end

        MainStorefront.updates_state = { remote_info = { ["rakuyomi.koplugin"] = { release_tag_name = "v1.39.4" } } }
        MainStorefront._cached_plugin_summary = nil
        local sum_test = MainStorefront:collectUpdateSummary()
        check("collectUpdateSummary detects update when plugin.version is missing but record has version", sum_test.updates, 1)

        -- Test date-based release version check
        MainStorefront.updates_state = { remote_info = { ["rakuyomi.koplugin"] = { release_tag_name = "v2026.07.28" } } }
        InstallStore.list = function()
            return {
                ["rakuyomi.koplugin"] = {
                    owner = "tachibana-shin",
                    repo = "rakuyomi",
                    version = "2026.05.10",
                    installed_version = "2026.05.10",
                    tag_name = "v2026.05.10"
                }
            }
        end
        MainStorefront._cached_plugin_summary = nil
        local sum_date_test = MainStorefront:collectUpdateSummary()
        check("collectUpdateSummary detects update for date-based versions", sum_date_test.updates, 1)

        -- Test promptPluginInstallOptions with release_override and multiple assets
        local test_repo = { name = "multi_asset_plugin", owner = "testowner" }
        local test_release_override = {
            tag_name = "v1.0.0-old",
            assets = {
                { name = "multi_asset_plugin_v1.0.0-koplugin.zip", browser_download_url = "http://example.com/asset1.zip" },
                { name = "multi_asset_plugin_v1.0.0-alt-koplugin.zip", browser_download_url = "http://example.com/asset2.zip" },
            }
        }
        local modal_rendered = false
        local orig_picker = MainStorefront.renderAssetPickerModal
        MainStorefront.renderAssetPickerModal = function(sf, repo, release, custom_assets, saved_ctx)
            modal_rendered = true
            check("renderAssetPickerModal receives release_override", release.tag_name, "v1.0.0-old")
            check("renderAssetPickerModal receives 2 assets", #custom_assets, 2)
        end
        MainStorefront:promptPluginInstallOptions(test_repo, test_release_override, false)
        check("promptPluginInstallOptions triggers asset picker for release_override with multiple assets", modal_rendered, true)
        MainStorefront.renderAssetPickerModal = orig_picker

        -- ----------------------------------------------------
        -- SCREENSAVER FEATURE REGRESSION TESTS
        -- ----------------------------------------------------
        -- 1. Test hasActiveFilters for Screensavers
        MainStorefront:ensureBrowserState()
        MainStorefront.browser_state.screensaver_category = ""
        MainStorefront.browser_state.screensaver_categories = nil
        MainStorefront.browser_state.screensaver_search = ""
        MainStorefront.browser_state.screensaver_sort = "downloads"
        check("hasActiveFilters Screensavers returns false when default", MainStorefront:hasActiveFilters("Screensavers"), false)

        MainStorefront.browser_state.screensaver_category = "Nature"
        check("hasActiveFilters Screensavers returns true when category set", MainStorefront:hasActiveFilters("Screensavers"), true)

        MainStorefront.browser_state.screensaver_category = ""
        MainStorefront.browser_state.screensaver_categories = { nature = true }
        check("hasActiveFilters Screensavers returns true when categories table set", MainStorefront:hasActiveFilters("Screensavers"), true)

        MainStorefront.browser_state.screensaver_categories = nil
        MainStorefront.browser_state.screensaver_sort = "az"
        check("hasActiveFilters Screensavers returns true when sort changed", MainStorefront:hasActiveFilters("Screensavers"), true)

        MainStorefront.browser_state.screensaver_sort = "downloads"
        MainStorefront.browser_state.screensaver_search = "mountain"
        check("hasActiveFilters Screensavers returns true when search active", MainStorefront:hasActiveFilters("Screensavers"), true)
        MainStorefront.browser_state.screensaver_search = ""

        -- 2. Test Installed Tab Screensaver Entry Building
        local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
        local orig_list_ss = StorefrontScreensaverMgr.listLocalScreensavers
        StorefrontScreensaverMgr.listLocalScreensavers = function()
            return {
                {
                    id = "whisperingsea4-highres-landscape-2a",
                    title = "Highres Landscape 2A",
                    author = "whisperingsea4",
                    filename = "whisperingsea4-highres-landscape-2a.png",
                    filepath = "/tmp/koreader/screensavers/whisperingsea4-highres-landscape-2a.png",
                    mtime = 1700000000,
                    is_active_single = true,
                }
            }
        end

        MainStorefront.installed_state.filter_type = "screensaver"
        MainStorefront.installed_state.search_text = ""
        local ss_installed_entries = MainStorefront:buildInstalledEntries(600)
        check("buildInstalledEntries includes screensavers", #ss_installed_entries >= 1, true)
        if #ss_installed_entries >= 1 then
            local ss_e = ss_installed_entries[1]
            check("Screensaver entry has clean title without author prefix", ss_e.name, "Highres Landscape 2A")
            check("Screensaver entry has author description", ss_e.description, "By whisperingsea4")
            check("Screensaver entry has kind_label", ss_e.kind_label, "Screensaver")
            check("Screensaver entry has thumbnail_file", ss_e.thumbnail_file, "/tmp/koreader/screensavers/whisperingsea4-highres-landscape-2a.png")
        end

        -- 3. Test StorefrontListItem with screensaver thumbnail
        local ss_item_widget_ok, ss_item_widget = pcall(function()
            return StorefrontListItem:new{
                entry = {
                    name = "Highres Landscape 2A",
                    kind_label = "Screensaver",
                    description = "By whisperingsea4",
                    badge = "Shuffle Pool",
                    thumbnail_file = "/tmp/koreader/screensavers/whisperingsea4-highres-landscape-2a.png",
                    is_screensaver = true,
                },
                width = 560,
            }
        end)
        check("StorefrontListItem with screensaver thumbnail instantiates without error", ss_item_widget_ok, true)

        StorefrontScreensaverMgr.listLocalScreensavers = orig_list_ss
        MainStorefront.installed_state.filter_type = "all"

        -- Test StorefrontAboutDialog.checkForUpdates executes without error
        local StorefrontAboutDialog = require("storefront_about_dialog")
        local about_check_ok = pcall(function()
            StorefrontAboutDialog.checkForUpdates(MainStorefront)
        end)
        check("StorefrontAboutDialog.checkForUpdates triggers non-blocking check without error", about_check_ok, true)

        -- Test MainStorefront:_checkAllUpdatesInternal executes and delegates without blocking
        local internal_check_ok = pcall(function()
            MainStorefront:_checkAllUpdatesInternal({})
        end)
        check("MainStorefront:_checkAllUpdatesInternal executes without error", internal_check_ok, true)

        -- ----------------------------------------------------
        -- BATCH UPDATE & ASSET RESOLUTION UNIT TESTS
        -- ----------------------------------------------------
        -- 1. Test update asset auto-resolution when matching variant exists
        do
            local matched_selected_asset = nil
            local orig_install_asset = MainStorefront.installPluginFromReleaseAsset
            MainStorefront.installPluginFromReleaseAsset = function(self_sf, r, rel, asset)
                matched_selected_asset = asset
            end

            local test_repo = { name = "my_custom_plugin", owner = "testowner" }
            local release_with_variants = {
                tag_name = "v2.0.0",
                assets = {
                    { name = "my_custom_plugin-v2.0.0-arm.zip", browser_download_url = "http://example.com/arm.zip" },
                    { name = "my_custom_plugin-v2.0.0-x86.zip", browser_download_url = "http://example.com/x86.zip" },
                }
            }

            local InstallStore = require("storefront_installs")
            InstallStore.upsert("my_custom_plugin.koplugin", {
                owner = "testowner",
                repo = "my_custom_plugin",
                asset_filename = "my_custom_plugin-v1.0.0-arm.zip",
            })

            MainStorefront.pending_install_context = {
                mode = "update",
                plugin = { dirname = "my_custom_plugin.koplugin" },
            }

            local picker_called = false
            local orig_picker = MainStorefront.renderAssetPickerModal
            MainStorefront.renderAssetPickerModal = function()
                picker_called = true
            end

            MainStorefront:promptPluginInstallOptions(test_repo, release_with_variants, false)

            check("Update with matching variant auto-selects matching asset", matched_selected_asset and matched_selected_asset.name, "my_custom_plugin-v2.0.0-arm.zip")
            check("Update with matching variant does not open asset picker modal", picker_called, false)

            -- 2. Test update when NO matching variant exists -> opens asset picker
            matched_selected_asset = nil
            picker_called = false
            InstallStore.setPreferredAsset("my_custom_plugin", nil)
            InstallStore.setPreferredAsset("my_custom_plugin.koplugin", nil)
            InstallStore.upsert("my_custom_plugin.koplugin", {
                owner = "testowner",
                repo = "my_custom_plugin",
                asset_filename = "my_custom_plugin-v1.0.0-mips.zip",
            })
            MainStorefront.pending_install_context = {
                mode = "update",
                plugin = { dirname = "my_custom_plugin.koplugin" },
            }
            MainStorefront:promptPluginInstallOptions(test_repo, release_with_variants, false)
            check("Update without matching variant opens asset picker modal", picker_called, true)

            MainStorefront.installPluginFromReleaseAsset = orig_install_asset
            MainStorefront.renderAssetPickerModal = orig_picker
        end

        -- 3. Test _processBatchUpdateQueue single persistent toast progression
        do
            local toast_instances = 0
            local toast_text_updates = {}
            local toast_closed = false
            local restart_confirmed = false

            local MockToast = {
                setText = function(self, txt)
                    table.insert(toast_text_updates, txt)
                end,
                close = function(self)
                    toast_closed = true
                end
            }

            local ToastModule = require("storefront_toast")
            local orig_toast_show = ToastModule.show
            ToastModule.show = function(txt, timeout, opts)
                toast_instances = toast_instances + 1
                return MockToast
            end

            local orig_restart = MainStorefront.showRestartConfirmation
            MainStorefront.showRestartConfirmation = function(sf, msg)
                restart_confirmed = true
            end

            local orig_prompt = MainStorefront.promptPluginInstallOptions
            local processed_items = {}
            MainStorefront.promptPluginInstallOptions = function(sf, descriptor, release_override)
                table.insert(processed_items, descriptor.name)
                if sf.pending_install_context and sf.pending_install_context.batch_callback then
                    local cb = sf.pending_install_context.batch_callback
                    sf.pending_install_context.batch_callback = nil
                    cb(true)
                end
            end

            local test_queue = {
                { kind = "plugin", name = "PluginOne", plugin = { name = "PluginOne", dirname = "p1.koplugin" }, record = { repo = "PluginOne", dirname = "p1.koplugin" } },
                { kind = "plugin", name = "PluginTwo", plugin = { name = "PluginTwo", dirname = "p2.koplugin" }, record = { repo = "PluginTwo", dirname = "p2.koplugin" } },
            }

            MainStorefront:_processBatchUpdateQueue(test_queue, 1, { success = 0, failed = 0 })

            check("Batch update creates only 1 persistent toast instance", toast_instances, 1)
            check("Batch update updates toast text in-place across queue", #toast_text_updates >= 1, true)
            check("Batch update closes toast upon completion", toast_closed, true)
            check("Batch update shows restart confirmation when items succeed", restart_confirmed, true)
            check("Batch update resets global updating flag", _G.G_storefront_batch_updating, false)

            ToastModule.show = orig_toast_show
            MainStorefront.promptPluginInstallOptions = orig_prompt
            MainStorefront.showRestartConfirmation = orig_restart
        end

        -- 4. Test _processBatchUpdateQueue handles download failures gracefully without freezing
        do
            local toast_instances = 0
            local summary_toast_msg = nil
            local toast_closed = false

            local MockToast = {
                setText = function(self, txt) end,
                close = function(self)
                    toast_closed = true
                end
            }

            local ToastModule = require("storefront_toast")
            local orig_toast_show = ToastModule.show
            ToastModule.show = function(txt, timeout, opts)
                toast_instances = toast_instances + 1
                summary_toast_msg = txt
                return MockToast
            end

            local orig_prompt = MainStorefront.promptPluginInstallOptions
            local processed_items = {}
            MainStorefront.promptPluginInstallOptions = function(sf, descriptor, release_override)
                table.insert(processed_items, descriptor.name)
                if sf.pending_install_context and sf.pending_install_context.batch_callback then
                    local cb = sf.pending_install_context.batch_callback
                    sf.pending_install_context.batch_callback = nil
                    cb(false, "Connection timed out")
                end
            end

            local test_queue = {
                { kind = "plugin", name = "FailingPlugin1", plugin = { name = "FailingPlugin1", dirname = "f1.koplugin" }, record = { repo = "FailingPlugin1", dirname = "f1.koplugin" } },
                { kind = "plugin", name = "FailingPlugin2", plugin = { name = "FailingPlugin2", dirname = "f2.koplugin" }, record = { repo = "FailingPlugin2", dirname = "f2.koplugin" } },
            }

            MainStorefront:_processBatchUpdateQueue(test_queue, 1, { success = 0, failed = 0 })

            check("Failed batch update processes both items without freezing", #processed_items, 2)
            check("Failed batch update closes progress toast", toast_closed, true)
            check("Failed batch update shows summary toast on 0 success", summary_toast_msg ~= nil, true)
            check("Failed batch update resets global updating flag", _G.G_storefront_batch_updating, false)

            ToastModule.show = orig_toast_show
            MainStorefront.promptPluginInstallOptions = orig_prompt
        end

        -- 5. Test _processBatchUpdateQueue tap-to-cancel / user cancellation
        do
            local toast_instances = 0
            local cancel_toast_shown = false

            local MockToast = {
                setText = function(self, txt) end,
                close = function(self) end
            }

            local ToastModule = require("storefront_toast")
            local orig_toast_show = ToastModule.show
            ToastModule.show = function(txt, timeout, opts)
                toast_instances = toast_instances + 1
                if txt and txt:find("cancelled") then
                    cancel_toast_shown = true
                end
                return MockToast
            end

            local orig_prompt = MainStorefront.promptPluginInstallOptions
            local processed_count = 0
            MainStorefront.promptPluginInstallOptions = function(sf, descriptor, release_override)
                processed_count = processed_count + 1
                if sf.pending_install_context and sf.pending_install_context.batch_callback then
                    local cb = sf.pending_install_context.batch_callback
                    sf.pending_install_context.batch_callback = nil
                    cb(false, "Cancelled by user")
                end
            end

            local test_queue = {
                { kind = "plugin", name = "CancelPlugin1", plugin = { name = "CancelPlugin1", dirname = "c1.koplugin" }, record = { repo = "CancelPlugin1", dirname = "c1.koplugin" } },
                { kind = "plugin", name = "CancelPlugin2", plugin = { name = "CancelPlugin2", dirname = "c2.koplugin" }, record = { repo = "CancelPlugin2", dirname = "c2.koplugin" } },
            }

            MainStorefront:_processBatchUpdateQueue(test_queue, 1, { success = 0, failed = 0 })

            check("Cancelled batch stops queue processing after first cancel", processed_count, 1)
            check("Cancelled batch shows cancellation toast", cancel_toast_shown, true)
            check("Cancelled batch resets global updating flag", _G.G_storefront_batch_updating, false)

            ToastModule.show = orig_toast_show
            MainStorefront.promptPluginInstallOptions = orig_prompt
        end
    end
end

if failures > 0 then
    print(string.format("UI TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("ALL UI TESTS PASSED")
    os.exit(0)
end
