local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

local f_sf = io.open("/home/jimmy/.config/koreader/cache/storefront_screensavers_catalog.json", "r")
local content_sf = f_sf:read("*a")
f_sf:close()

local f_rb = io.open("/home/jimmy/.config/koreader/cache/storefront_readerbackdrop_catalog.json", "r")
local content_rb = f_rb:read("*a")
f_rb:close()

local json = require("json")
local t0 = os.clock()
local sf_items = json.decode(content_sf)
local t1 = os.clock()
local rb_items = json.decode(content_rb)
local t2 = os.clock()
print(string.format("JSON decode SF: %.4fs (%d items), RB: %.4fs (%d items)", t1 - t0, #sf_items, t2 - t1, #rb_items))

local sf_screensavers = require("storefront_screensavers_ui")
local t3 = os.clock()
for _, item in ipairs(sf_items) do
    item.source = "Storefront"
    sf_screensavers.normalizeItem(item)
end
for _, item in ipairs(rb_items) do
    item.source = "ReaderBackdrop"
    sf_screensavers.normalizeItem(item)
end
local t4 = os.clock()
print(string.format("Normalize items: %.4fs", t4 - t3))

local Main = require("main")
local merged = {}
for _, it in ipairs(sf_items) do table.insert(merged, it) end
for _, it in ipairs(rb_items) do table.insert(merged, it) end
Main.screensavers_cache = merged
Main:ensureBrowserState()
Main.browser_state.tab = "Screensavers"

local t5 = os.clock()
local items, pages = Main:buildScreensaverEntries()
local t6 = os.clock()
print(string.format("buildScreensaverEntries: %.4fs", t6 - t5))
