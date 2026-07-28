package.path = "/home/jpautz/.config/koreader/plugins/storefront.koplugin/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;" .. package.path

package.loaded["gettext"] = function(str) return str end

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

local ok_json, json = pcall(require, "json")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local catalog_path = "/home/jpautz/.config/koreader/plugins/storefront.koplugin/catalog.json"
local f = io.open(catalog_path, "r")
if not f then
    print("ERROR: catalog.json not found")
    return
end
local content = f:read("*all")
f:close()

local catalog = json.decode(content)
local fonts = catalog and catalog.fonts or {}

print("Loaded catalog fonts count:", #fonts)

local DetailsDialog = require("storefront_details_dialog")

for idx, font_entry in ipairs(fonts) do
    print(string.format("[%d/%d] Testing font: %s (%s)", idx, #fonts, tostring(font_entry.name), tostring(font_entry.font_file)))
    local ok, err = pcall(function()
        local dlg = DetailsDialog:new{
            Storefront = {},
            repo = font_entry,
            kind = "font",
        }
        dlg:show()
    end)
    if not ok then
        print(string.format("--> CRASH FOR FONT %s: %s", tostring(font_entry.name), tostring(err)))
    else
        print(string.format("--> OK FOR FONT %s", tostring(font_entry.name)))
    end
end
