-- storefront_launch_test.lua
-- Unit test to verify that the Storefront plugin modules load, initialize, and launch cleanly.
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local ok_spec, _ = pcall(require, "spec_helper")
if not ok_spec then
    local ok_spec2, _ = pcall(require, "tests/spec_helper")
    if not ok_spec2 then
        pcall(require, "storefront.koplugin/tests/spec_helper")
    end
end

local failures = 0
local function check(label, got, expected, err_msg)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got), err_msg and ("error: " .. tostring(err_msg)) or "")
    end
    io.stdout:flush()
end

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
    getSize = function() return { w = 100, h = 50 } end,
    enableDisable = function() end,
    isFocusable = function() return true end,
    open = function(self) return self or dummy_widget end,
    readSetting = function() end,
    saveSetting = function() end,
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
    "ui/network/manager",
    "ui/widget/scrolltextwidget",
    "ui/widget/infomessage",
    "ui/widget/imagewidget",
    "ui/widget/imageviewer",
    "ui/widget/buttontable",
    "ui/widget/horizontalscrollbar",
    "ui/widget/multiconfirmbox",
    "ui/data/optionsutil",
    "ui/data/creoptions",
    "ui/data/isolanguage",
    "ui/data/koptoptions",
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
    "ffi/archiver",
    "ffi/sha2",
    "ffi/mupdf",
    "ffi/freetype",
    "ffi/koptcontext",
    "document/canvascontext",
    "document/document",
    "document/doccache",
    "document/pdfdocument",
    "document/koptinterface",
    "ui/document/credocument",
    "socketutil",
    "socket",
}

for _, w in ipairs(widgets) do
    package.loaded[w] = dummy_widget
end

-- Ensure Real Storefront files are loaded from disk
package.loaded["storefront_list_item"] = nil
package.loaded["storefront_details_dialog"] = nil
package.loaded["storefront_ratings"] = nil
package.loaded["main"] = nil

package.loaded["ui/size"] = {
    padding = { default = 10, fullscreen = 10, large = 15, small = 5 },
    border = { button = 1, default = 1 },
    radius = { button = 4, default = 4 },
}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    dir = function() return function() return nil end end,
    mkdir = function() return true end,
}
package.loaded["lfs"] = package.loaded["libs/libkoreader-lfs"]

package.loaded["ffi/util"] = {
    realpath = function(path) return path end,
    runInSubProcess = function() return 1, {} end,
    writeToFD = function() end,
    readAllFromFD = function() return "" end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
    joinPath = function(...)
        local args = {...}
        local res = {}
        for _, a in ipairs(args) do
            if type(a) == "string" and a ~= "" then
                table.insert(res, a)
            end
        end
        return table.concat(res, "/")
    end,
}

package.loaded["util"] = {
    makePath = function(path) return true end,
    writeToFile = function(content, path) return true end,
    readFromFile = function(path) return "mock readme content" end,
    trim = function(str) return str and str:gsub("^%s*(.-)%s*$", "%1") or "" end,
    joinPath = package.loaded["ffi/util"].joinPath,
}

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

package.loaded["logger"] = {
    info = function() end,
    warn = function() end,
    dbg = function() end,
    err = function() end,
    setLevel = function() end,
    levels = { DBG = 1, INFO = 2, WARN = 3, ERR = 4 },
}

package.loaded["dispatcher"] = {
    registerAction = function() end,
}

print("=== Storefront Module Launch Tests ===")

-- 1. Test StorefrontRatings module load and function availability
local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")
check("storefront_ratings loads without error", ok_ratings, true, StorefrontRatings)
if ok_ratings and type(StorefrontRatings) == "table" then
    check("StorefrontRatings has getRating", type(StorefrontRatings.getRating), "function")
    check("StorefrontRatings has submitVote", type(StorefrontRatings.submitVote), "function")
end

-- 2. Test StorefrontListItem initialization
local ok_item, StorefrontListItem = pcall(require, "storefront_list_item")
check("storefront_list_item loads without error", ok_item, true, StorefrontListItem)

if ok_item and StorefrontListItem then
    local test_entry = {
        id = 12345,
        name = "Test Plugin",
        owner = "testowner",
        stars_fmt = "42",
        updated = "2026-08-07",
        description = "Test description",
        is_entry = true,
    }

    local ok_inst, item_err = pcall(function()
        return StorefrontListItem:new{ entry = test_entry, width = 800 }
    end)
    check("StorefrontListItem instantiates cleanly with rating item", ok_inst, true, item_err)
end

-- 3. Test StorefrontDetailsDialog require
local ok_details, StorefrontDetailsDialog = pcall(require, "storefront_details_dialog")
check("storefront_details_dialog loads without error", ok_details, true, StorefrontDetailsDialog)

-- 4. Test Main Storefront plugin load
local ok_main, Storefront = pcall(require, "main")
check("main.lua loads without error", ok_main, true, Storefront)

if failures > 0 then
    print(string.format("\nLAUNCH TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("\nALL LAUNCH TESTS PASSED")
    os.exit(0)
end
