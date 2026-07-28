package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;storefront.koplugin/storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

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
    setContent = function() end,
    copy = function(self)
        local c = {}
        for k, v in pairs(self) do c[k] = v end
        return c
    end,
}

local widgets = {
    "ui/widget/button", "ui/widget/container/framecontainer", "ui/widget/container/scrollablecontainer",
    "ui/widget/container/centercontainer", "ui/widget/container/rightcontainer", "ui/widget/container/widgetcontainer",
    "ui/widget/container/inputcontainer", "ui/widget/container/movablecontainer", "ui/widget/focusmanager",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/verticalspan", "ui/widget/verticalgroup",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/textboxwidget", "ui/widget/textwidget",
    "ui/widget/textviewer", "ui/widget/htmlboxwidget", "ui/widget/imagewidget", "ui/widget/infomessage",
    "ui/widget/menu", "ui/widget/confirmbox", "ui/widget/multiinputdialog", "ui/widget/inputdialog",
    "ui/widget/container/leftcontainer", "ui/uimanager", "ui/geometry", "ui/font", "ui/gesturerange",
    "ui/network/manager", "ffi/blitbuffer", "device", "logger", "ffi/util", "libs/libkoreader-lfs",
    "ui/size", "datastorage", "apps/filemanager/filemanager", "socket.url", "socket.http",
    "ui/widget/checkbutton", "ui/widget/buttondialog", "ui/widget/spinwidget", "ui/widget/titlebar",
    "ui/widget/iconwidget", "ui/widget/iconbutton", "ui/renderimage", "ui/trapper", "ui/widget/scrolltextwidget",
    "ui/widget/imageviewer", "ffi/archiver", "ffi/sha2", "util"
}
for _, w in ipairs(widgets) do
    package.loaded[w] = dummy_widget
end

package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp" end,
    getSettingsDir = function() return "/tmp" end,
}

package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    _is_dirty = false,
}

package.loaded["ui/font"] = {
    getFace = function() return dummy_widget end
}

package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0, COLOR_WHITE = 255, COLOR_GRAY = 128,
    Color8 = function(v) return v end,
    colorFromString = function(s) return 0 end
}

package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 961 end,
        scaleBySize = function(self, val) return val end,
    },
    input = {
        group = { PgFwd = 1, PgBack = 2, Back = 3 }
    },
    hasKeys = function() return true end,
}

package.loaded["logger"] = {
    info = function() end, warn = function() end, dbg = function() end, err = function() end
}

package.loaded["gettext"] = function(s) return s end
package.loaded["ffi/util"] = {
    realpath = function(p) return p end
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    dir = function() return function() return nil end end
}

package.loaded["storefront_installs"] = {
    list = function() return {} end,
    listPatches = function() return {} end,
    listFonts = function() return {} end,
    isPreReleaseAllowed = function() return false end,
    isReleaseIgnored = function() return false end,
}

local DetailsDialog = require("storefront_details_dialog")
local font_repo = {
    name = "Chivo",
    full_name = "google/chivo",
    kind = "font",
    stars = 50,
}

print("Instantiating DetailsDialog for font_repo...")
local ok, err = pcall(function()
    local dlg = DetailsDialog:new{
        Storefront = {},
        repo = font_repo,
        kind = "font",
    }
    dlg:show()
end)

if not ok then
    print("CRASH DETECTED:", err)
else
    print("SUCCESS, no crash during show()")
end
