package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

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
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/linewidget",
    "ui/widget/textwidget",
    "ui/widget/textboxwidget",
    "ui/widget/progresswidget",
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
    getDataDir = function() return "/home/jimmy/.config/koreader" end,
    getSettingsDir = function() return "/home/jimmy/.config/koreader" end,
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

local ok_json, json = pcall(require, "json")

-- Read actual cache files
local f_sf = io.open("/home/jimmy/.config/koreader/cache/storefront_screensavers_catalog.json", "r")
local sf_str = f_sf and f_sf:read("*a") or "[]"
if f_sf then f_sf:close() end

local f_rb = io.open("/home/jimmy/.config/koreader/cache/storefront_readerbackdrop_catalog.json", "r")
local rb_str = f_rb and f_rb:read("*a") or "[]"
if f_rb then f_rb:close() end

local t_dec0 = os.clock()
local sf_data = json.decode(sf_str)
local rb_data = json.decode(rb_str)
local t_dec1 = os.clock()
print(string.format("JSON decode: %.4fs (%d SF, %d RB)", t_dec1 - t_dec0, #sf_data, #rb_data))

local sf_ui = require("storefront_screensavers_ui")
local t_norm0 = os.clock()
for _, it in ipairs(sf_data) do
    it.source = "Storefront"
    sf_ui.normalizeItem(it)
end
for _, it in ipairs(rb_data) do
    it.source = "ReaderBackdrop"
    sf_ui.normalizeItem(it)
end
local t_norm1 = os.clock()
print(string.format("Normalize: %.4fs", t_norm1 - t_norm0))

local full_cat = {}
for _, it in ipairs(sf_data) do table.insert(full_cat, it) end
for _, it in ipairs(rb_data) do table.insert(full_cat, it) end

local Main = require("main")
Main.screensavers_cache = full_cat
Main:ensureBrowserState()
Main.browser_state.tab = "Screensavers"

local t_build0 = os.clock()
local items, total_pages = Main:buildScreensaverEntries()
local t_build1 = os.clock()
print(string.format("buildScreensaverEntries 1st: %.4fs (total pages: %d)", t_build1 - t_build0, total_pages or 0))

local t_build2 = os.clock()
local items2, total_pages2 = Main:buildScreensaverEntries()
local t_build3 = os.clock()
print(string.format("buildScreensaverEntries 2nd (cached): %.4fs", t_build3 - t_build2))
