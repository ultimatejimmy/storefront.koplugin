package.path = "/home/jimmy/.config/koreader/plugins/storefront.koplugin/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;" .. package.path
local t0 = os.clock()
local sf = require("storefront_screensavers_ui")
local cat = sf.getCachedCatalog()
local t1 = os.clock()
print(string.format("Load & merge catalog: %.4f seconds (items: %d)", t1 - t0, cat and #cat or 0))

local Main = require("main")
Main.screensavers_cache = cat
Main:ensureBrowserState()
Main.browser_state.tab = "Screensavers"

local t2 = os.clock()
local items, total_pages = Main:buildScreensaverEntries()
local t3 = os.clock()
print(string.format("buildScreensaverEntries 1st call: %.4f seconds (cards: %d, pages: %d)", t3 - t2, items and items[1] and items[1].cards and #items[1].cards or 0, total_pages or 0))

local t4 = os.clock()
local items2, total_pages2 = Main:buildScreensaverEntries()
local t5 = os.clock()
print(string.format("buildScreensaverEntries 2nd call (cached): %.4f seconds", t5 - t4))
