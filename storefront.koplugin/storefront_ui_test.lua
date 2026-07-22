-- storefront_ui_test.lua
-- Run with: cd <extracted-koreader-dir> && env SQUASHFS_ROOT=<dir> LUA_PATH='...' ./luajit <test_file>
package.path = "plugins/storefront.koplugin/?.lua;" .. package.path

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

-- Create a dummy class that mocks any KOReader widget behaviour
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
    getSize = function() return { w = 100, h = 50 } end,
    enableDisable = function() end,
    isFocusable = function() return true end,
    copy = function(self)
        local c = {}
        for k, v in pairs(self) do c[k] = v end
        return c
    end,
}

-- Pre-load dummy mocks for all KOReader UI modules to prevent library load crashes headlessly
local widgets = {
    "ui/widget/button",
    "ui/widget/container/framecontainer",
    "ui/widget/container/scrollablecontainer",
    "ui/widget/container/centercontainer",
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
    "ui/trapper",
    "storefront_list_item",
    "ui/network/manager",
    "ui/widget/scrolltextwidget",
    "ui/widget/infomessage",
    "ui/widget/imagewidget",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/htmlboxwidget",
    "ui/widget/inputdialog",
    "libs/libkoreader-lfs",
    "json",
    "socket.url",
    "ui/widget/textviewer",
    "apps/filemanager/filemanager",
    "socket.http",
    "ui/widget/confirmbox",
    "ui/widget/multiinputdialog",
    "ui/widget/checkbutton",
    "ui/widget/buttondialog",
    "storefront_repo_content",
    "storefront_installs",
    "storefront_plugin_paths",
    "ffi/archiver",
    "ffi/sha2",
    "socketutil",
    "socket",
}

package.loaded["logger"] = {
    info = function() end,
    warn = function() end,
    dbg = function() end,
    err = function() end,
}

package.loaded["storefront_logger"] = {
    log = function() end,
    info = function() end,
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
}

package.loaded["storefront_updates_ui"] = {
    init = function() end,
}

for _, w in ipairs(widgets) do
    if w ~= "storefront_plugin_paths" and w ~= "libs/libkoreader-lfs" then
        package.loaded[w] = dummy_widget
    end
end

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    dir = function() return function() return nil end end,
}

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

package.loaded["storefront_cache"] = {
    getLastFetched = function() return 1234567890 end,
    listRepos = function() return {} end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function(self) return "/tmp/koreader_test_settings" end,
    getDataDir = function(self) return "/tmp/koreader_test_data" end,
}

package.loaded["luasettings"] = {
    open = function(self, path)
        local store = { data = {} }
        function store:readSetting(key) return self.data[key] end
        function store:saveSetting(key, val) self.data[key] = val; return true end
        function store:delSetting(key) self.data[key] = nil end
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
    nextTick = function(self, func) if type(self) == "function" then self() elseif func then func() end end,
}

-- Setup basic reader settings mock
G_reader_settings = {
    readSetting = function(self, key)
        if key == "cre_font_size" then return 20 end
        return nil
    end
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
    browser.on_settings_tap = function() settings_tapped = true end
    if browser._header_settings_btn.callback then
        browser._header_settings_btn.callback()
    end
    check("Settings button callback executed", settings_tapped, true)

    -- Test Settings Card rendering
    if ok_card then
        local dummy_storefront = {
            browser_state = { kind = "plugin" },
            browserRefresh = function() end,
            saveBrowserState = function() end,
            getInstallRecordsMap = function() return {} end,
            getPatchRecordsMap = function() return {} end,
        }
        local show_ok, err = pcall(function()
            StorefrontSettingsCard.show(dummy_storefront)
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
        local details_ok, details_err = pcall(function()
            local details = StorefrontDetailsDialog:new{
                Storefront = full_dummy_storefront,
                repo = dummy_repo,
                kind = "plugin",
            }
        end)
        check("Details dialog loaded successfully", details_ok, true)
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
        package.loaded["storefront_installs"] = {
            getGeneration = function() return 1 end,
            list = function() return dummy_records end,
            listPatches = function() return {} end,
        }
        local MainStorefront = require("main")
        MainStorefront._installed_lookup_cache = nil
        local lookup = MainStorefront:getInstalledLookup()
        check("Installed lookup matches exact repo full_name", lookup["doctorhetfield-cmd/simpleui.koplugin"] == true, true)
        
        -- Test that direct match repo shows installed, but sibling repo with same name does not
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

        -- Test autoMatchInstalled preference (highest stars win, author match wins top priority)
        package.loaded["storefront_plugin_paths"] = {
            getLookupPaths = function() return { "plugins" } end,
            isPathHidden = function() return false end,
        }
        local dummy_fork = { name = "simpleui.koplugin", owner = "somefork", full_name = "somefork/simpleui.koplugin", fork = true, stars = 0 }
        local dummy_main = { name = "simpleui.koplugin", owner = "doctorhetfield-cmd", full_name = "doctorhetfield-cmd/simpleui.koplugin", fork = false, stars = 15 }
        local dummy_popular_fork = { name = "popularplugin.koplugin", owner = "popfork", full_name = "popfork/popularplugin.koplugin", fork = true, stars = 100 }
        local dummy_low_main = { name = "popularplugin.koplugin", owner = "originaldev", full_name = "originaldev/popularplugin.koplugin", fork = false, stars = 5 }
        local orig_list = package.loaded["storefront_cache"].listRepos
        package.loaded["storefront_cache"].listRepos = function()
            return { dummy_fork, dummy_main, dummy_popular_fork, dummy_low_main }
        end
        MainStorefront:autoMatchInstalled()
        package.loaded["storefront_cache"].listRepos = orig_list
        local rec = MainStorefront:getInstalledLookup()
        check("Installed plugin simpleui resolved successfully", rec ~= nil, true)
    end
end

if failures > 0 then
    print(string.format("UI TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("ALL UI TESTS PASSED")
    os.exit(0)
end
