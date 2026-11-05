local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

local StorefrontToast = require("storefront_toast")
local StorefrontUtils = require("storefront_utils")
local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
local StorefrontScreensavers = require("storefront_screensavers_ui")

local passed = 0
local failed = 0
local function assert_eq(desc, actual, expected)
    if actual == expected then
        passed = passed + 1
        print(" [PASS] " .. desc)
    else
        failed = failed + 1
        print(" [FAIL] " .. desc .. " -> Expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
    end
end

print("==================================================")
print("  RUNNING GALLERY & COLLECTIONS PERF/CRASH TESTS  ")
print("==================================================")

-- 1. StorefrontUtils button allow_flash default
local btn1 = StorefrontUtils.createButton{ text = "Test", callback = function() end }
assert_eq("createButton defaults allow_flash to false", btn1.allow_flash, false)
local btn2 = StorefrontUtils.createButton{ text = "Test", allow_flash = true, callback = function() end }
assert_eq("createButton honors allow_flash = true when requested", btn2.allow_flash, true)

-- 2. StorefrontToast singleton replacement & pass-through
local t1 = StorefrontToast.show("First message", 2)
assert_eq("Toast 1 shown", t1.text, "First message")
local t2 = StorefrontToast.show("Second message", 2, { passthrough = true, position = "bottom" })
assert_eq("Toast 2 shown with bottom position", t2.position, "bottom")
assert_eq("Toast 2 has passthrough = true", t2.passthrough, true)
assert_eq("Toast 1 was closed when Toast 2 opened", t1._closing, true)

-- Pass-through tap should return false so underlying button receives tap
local tap_result = t2:onTapDismiss()
assert_eq("Passthrough toast returns false on tap to pass event through", tap_result, false)

-- 3. Screensaver Manager O(1) prefix / author extraction
local cat_data = {
    { id = "test-1", author = "Jane Doe", title = "Mountain Vista", filename = "janedoe-mountain.jpg" },
    { id = "test-2", author = "whisperingsea4", title = "Ocean Breeze", filename = "whisperingsea4-ocean.jpg" },
}
local StorefrontScreensavers = require("storefront_screensavers_ui")
StorefrontScreensavers.getCachedCatalog = function() return cat_data end

-- 4. Storefront-hosted rb-* thumbnail routing
local item_hosted = { id = "rb-a143886c", source = "ReaderBackdrop", ext = "png" }
StorefrontScreensavers.normalizeItem(item_hosted)
assert_eq("Storefront-hosted rb-* uses png ext", item_hosted.ext, "png")
assert_eq("Storefront-hosted rb-* routes to images/thumbnails/rb-a143886c.png",
    item_hosted.thumbnailUrl, "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/thumbnails/rb-a143886c.png")

local item_remote = { id = "rb-external", source = "ReaderBackdrop", fullUrl = "https://external.org/wallpaper.jpg" }
StorefrontScreensavers.normalizeItem(item_remote)
assert_eq("External ReaderBackdrop routes to images/thumbnails/rb/rb-external.jpg",
    item_remote.thumbnailUrl, "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/thumbnails/rb/rb-external.jpg")

-- 5. Collections fetchCollections changed flag on not_modified
local mock_net = {
    fetchCollectionsCatalog = function()
        return "not_modified", nil
    end
}
package.loaded["storefront_net_catalog"] = mock_net
StorefrontScreensavers.fetchCollections(function(ok, data, changed)
    assert_eq("fetchCollections ok on not_modified", ok, true)
    assert_eq("fetchCollections changed is false on not_modified (skips re-render)", changed, false)
end)

print(string.format("\n==================================================\n  PERF & CRASH SUITE: %d Passed, %d Failed\n==================================================", passed, failed))
if failed > 0 then os.exit(1) end
