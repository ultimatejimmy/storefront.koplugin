package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label .. " | expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
    io.stdout:flush()
end

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
        if fn then pcall(fn) end
    end,
    unschedule = function() end,
}

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

for _, w in ipairs(widgets) do
    if w ~= "storefront_plugin_paths" and w ~= "libs/libkoreader-lfs" then
        package.loaded[w] = dummy_widget
    end
end

package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(self, val) return val end,
    },
    input = { group = { PgFwd = 1, PgBack = 2, Back = 3 } },
    hasKeys = function() return false end,
    hasKeyboard = function() return false end,
}

package.loaded["ui/font"] = {
    getFace = function() return {} end,
}

package.loaded["ffi/blitbuffer"] = {
    new = function() return dummy_widget end,
    COLOR_BLACK = 0,
    COLOR_WHITE = 255,
    COLOR_GRAY = 128,
    COLOR_DARK_GRAY = 64,
    COLOR_LIGHT_GRAY = 192,
    Color8 = function(c) return c end,
}

package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    nextTick = function(self_or_fn, fn)
        local cb = type(self_or_fn) == "function" and self_or_fn or fn
        if cb then pcall(cb) end
    end,
    forceRePaint = function() end,
}

package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/koreader" end,
    getSettingsDir = function() return "/tmp/koreader" end,
}

package.loaded["util"] = {
    makePath = function(path) return true end,
    writeToFile = function(content, path) return true end,
    readFromFile = function(path) return "" end,
    trim = function(str) return str and str:gsub("^%s*(.-)%s*$", "%1") or "" end,
}

package.loaded["logger"] = {
    info = function() end,
    warn = function() end,
    dbg = function() end,
    err = function() end,
    setLevel = function() end,
    levels = { DBG = 1, INFO = 2, WARN = 3, ERR = 4 },
}

local _mock_json_store = { plugins = {}, patches = {}, item_options = {} }
package.loaded["json"] = {
    encode = function(val)
        return "MOCK_JSON"
    end,
    decode = function(str)
        return _mock_json_store
    end,
}

package.loaded["storefront_cache"] = {
    getLastFetched = function() return 0 end,
    countRepos = function() return 0 end,
    listRepos = function() return {} end,
    getRepo = function() return nil end,
    getRepoByName = function() return nil end,
}

local registered_actions = {}
package.loaded["dispatcher"] = {
    registerAction = function(self, id, action)
        registered_actions[id] = action
    end,
}
_G.G_defaults = {}
_G.G_reader_settings = dummy_widget

local Storefront = require("main")
local StorefrontUtils = require("storefront_utils")

local sample_catalog = {
    {
        id = "foggy-forest-pines",
        title = "Foggy Mountain Pines",
        author = "Unsplash (CC0)",
        category = "Nature",
        tags = { "alpine", "atmospheric", "evergreen", "fog", "forest", "pines", "trees" },
    },
    {
        id = "minimalist-ocean-waves",
        title = "Minimalist Ocean Horizon",
        author = "Unsplash (CC0)",
        category = "Minimalist",
        tags = { "coastal", "horizon", "line art", "marine", "minimalist", "ocean", "waves" },
    },
    {
        id = "starry-cat",
        title = "Starry Cat",
        author = "brpjtf2",
        submitter = "brpjtf2",
        category = "Nature",
        tags = { "animal", "cat", "kitten", "pet", "starry" },
    },
    {
        id = "durer-rhinoceros",
        title = "The Rhinoceros",
        author = "Albrecht Dürer",
        attribution = "The Metropolitan Museum of Art",
        category = "Fine Art",
        tags = { "fine art", "woodcut", "historic", "rhino" },
    },
}

Storefront.screensavers_cache = sample_catalog
Storefront:ensureBrowserState()
Storefront.browser_state.tab = "Screensavers"

local function resetState()
    Storefront.screensavers_cache = sample_catalog
    Storefront.browser_state.search_text = ""
    Storefront.browser_state.owner = ""
    Storefront.browser_state.screensaver_search = ""
    Storefront.browser_state.screensaver_category = ""
    Storefront.browser_state.screensaver_categories = nil
    Storefront.browser_state.screensaver_sort = "downloads"
    Storefront.browser_state.page = 1
end

print("--- Running Screensaver Search & Filter Tests ---")

-- Test 1: All entries returned without search
resetState()
local items, total_pages = Storefront:buildScreensaverEntries()
check("Returns all 4 entries without filters", #items[1].cards, 4)

-- Test 2: Title search via main search bar (search_text)
resetState()
Storefront.browser_state.search_text = "Rhinoceros"
items = Storefront:buildScreensaverEntries()
check("Search title 'Rhinoceros' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.search_text = "Ocean"
items = Storefront:buildScreensaverEntries()
check("Search title 'Ocean' finds 1 entry", #items[1].cards, 1)

-- Test 3: Tag search via main search bar (search_text)
resetState()
Storefront.browser_state.search_text = "atmospheric"
items = Storefront:buildScreensaverEntries()
check("Search tag 'atmospheric' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.search_text = "kitten"
items = Storefront:buildScreensaverEntries()
check("Search tag 'kitten' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.search_text = "woodcut"
items = Storefront:buildScreensaverEntries()
check("Search tag 'woodcut' finds 1 entry", #items[1].cards, 1)

-- Test 4: Multi-term search (matching across title and tags)
resetState()
Storefront.browser_state.search_text = "foggy trees"
items = Storefront:buildScreensaverEntries()
check("Multi-term search 'foggy trees' matches Foggy Mountain Pines", #items[1].cards, 1)

-- Test 5: Submitter / Author search via Owner bar (owner)
resetState()
Storefront.browser_state.owner = "brpjtf2"
items = Storefront:buildScreensaverEntries()
check("Search owner 'brpjtf2' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.owner = "Dürer"
items = Storefront:buildScreensaverEntries()
check("Search owner 'Dürer' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.owner = "Unsplash"
items = Storefront:buildScreensaverEntries()
check("Search owner 'Unsplash' finds 2 entries", #items[1].cards, 2)

resetState()
Storefront.browser_state.owner = "Metropolitan"
items = Storefront:buildScreensaverEntries()
check("Search owner 'Metropolitan' (attribution) finds 1 entry", #items[1].cards, 1)

-- Test 6: Combined search_text (title/tag) + owner (submitter)
resetState()
Storefront.browser_state.search_text = "cat"
Storefront.browser_state.owner = "brpjtf2"
items = Storefront:buildScreensaverEntries()
check("Combined search 'cat' by 'brpjtf2' finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.search_text = "cat"
Storefront.browser_state.owner = "Unsplash"
items = Storefront:buildScreensaverEntries()
check("Combined search 'cat' by 'Unsplash' finds 0 entries", #items[1].cards, 0)

-- Test 7: Combined search with category filter
resetState()
Storefront.browser_state.search_text = "pines"
Storefront.browser_state.screensaver_categories = { nature = true }
items = Storefront:buildScreensaverEntries()
check("Search 'pines' in Nature category finds 1 entry", #items[1].cards, 1)

resetState()
Storefront.browser_state.search_text = "pines"
Storefront.browser_state.screensaver_categories = { minimalist = true }
items = Storefront:buildScreensaverEntries()
check("Search 'pines' in Minimalist category finds 0 entries", #items[1].cards, 0)

-- Test 8: hasActiveFilters for Screensavers
resetState()
check("hasActiveFilters is false when no filter", Storefront:hasActiveFilters("Screensavers"), false)

Storefront.browser_state.search_text = "cat"
check("hasActiveFilters is true when search_text is set", Storefront:hasActiveFilters("Screensavers"), true)

Storefront.browser_state.search_text = ""
Storefront.browser_state.owner = "brpjtf2"
check("hasActiveFilters is true when owner is set", Storefront:hasActiveFilters("Screensavers"), true)

-- Test 9: clearSearchAndFilters resets everything
Storefront:clearSearchAndFilters()
check("clearSearchAndFilters clears search_text", Storefront.browser_state.search_text, "")
check("clearSearchAndFilters clears owner", Storefront.browser_state.owner, "")
check("hasActiveFilters is false after clearSearchAndFilters", Storefront:hasActiveFilters("Screensavers"), false)

if failures > 0 then
    print(string.format("\nFAILED: %d errors", failures))
    os.exit(1)
else
    print("\nALL SCREENSAVER SEARCH TESTS PASSED SUCCESSFULLY!")
    os.exit(0)
end
