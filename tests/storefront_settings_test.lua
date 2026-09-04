-- storefront_settings_test.lua
-- Tests settings button tap flow and StorefrontSettingsCard dialog rendering.

require("tests/spec_helper")

package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;/mnt/c/Users/jpautz/Documents/storefront/storefront.koplugin/storefront.koplugin/?.lua;/mnt/c/Users/jpautz/Documents/storefront/storefront.koplugin/?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS\t" .. label)
    else
        failures = failures + 1
        print("FAIL\t" .. label)
    end
    io.stdout:flush()
end

local MainStorefront = require("main")
local StorefrontBrowserDialog = require("storefront_browser_ui")
local StorefrontSettingsDialog = require("storefront_settings_dialog")
local StorefrontSettingsCard = require("storefront_settings_card")
local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")

print("=== Running Storefront Settings Button & Dialog Regression Tests ===")

-- 1. Test Screensaver Manager local directory listing
do
    local ok, local_wallpapers = pcall(function()
        return StorefrontScreensaverMgr.listLocalScreensavers()
    end)
    check("listLocalScreensavers succeeds without directory generator error", ok)
    check("listLocalScreensavers returns a table", type(local_wallpapers) == "table")
end

-- 2. Test StorefrontSettingsCard dialog instantiation and display
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local dummy_storefront = {
        browser_state = { kind = "plugin" },
        browserRefresh = function() end,
        saveBrowserState = function() end,
        getInstallRecordsMap = function() return {} end,
        getPatchRecordsMap = function() return {} end,
    }
    local ok, err = pcall(function()
        StorefrontSettingsCard.show(dummy_storefront)
    end)
    check("StorefrontSettingsCard.show executes without error", ok)
    if not ok then print("SettingsCard show error:", err) end

    local overlay = _G.ui_tracker.last_shown
    check("Settings card dialog shows overlay", overlay ~= nil)
    check("Settings card dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Settings card dialog has 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 2)
    check("Settings card dialog has Close key event", overlay and overlay.key_events and overlay.key_events.Close ~= nil)

    -- Test close callback
    local close_btn = overlay and overlay.layout and overlay.layout[#overlay.layout] and overlay.layout[#overlay.layout][1]
    check("Settings card dialog close button exists", close_btn ~= nil and close_btn.callback ~= nil)
    if close_btn and close_btn.callback then
        local close_ok, close_err = pcall(close_btn.callback)
        check("Settings card dialog close button executes cleanly", close_ok)
    end
end

-- 3. Test tapping the settings button from StorefrontBrowserDialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local settings_tapped = false
    local settings_dialog_opened = false

    local browser = StorefrontBrowserDialog:new{
        title = "Storefront",
        items = {
            { name = "Test Item", is_entry = true, callback = function() end }
        },
        page = 1,
        total_pages = 1,
        is_probe = true,
        on_tab_switch = function() end,
        on_settings_tap = function()
            settings_tapped = true
            MainStorefront:showStorefrontSettingsDialog()
            settings_dialog_opened = true
        end,
    }
    browser:init()

    check("Browser dialog header settings button is present", browser._header_settings_btn ~= nil)
    check("Browser dialog header settings button has callback", type(browser._header_settings_btn.callback) == "function")

    -- Tap the settings button
    local tap_ok, tap_err = pcall(function()
        browser._header_settings_btn.callback()
    end)
    check("Tapping settings button executes without crash", tap_ok)
    if not tap_ok then print("Settings tap error:", tap_err) end
    check("Settings button callback invoked on_settings_tap handler", settings_tapped)
    check("Settings button tap opened StorefrontSettingsDialog", settings_dialog_opened)

    local shown_overlay = _G.ui_tracker.last_shown
    check("Settings dialog overlay was presented to UIManager", shown_overlay ~= nil)
end

-- 4. Test StorefrontUtils.createButton padding and dimensions
do
    local StorefrontUtils = require("storefront_utils")
    local btn_with_pad = StorefrontUtils.createButton{
        text = "Clear All",
        padding_h = 10,
        padding_v = 5,
        width = 92,
        height = 32,
    }
    check("createButton with width/height sets dimensions", btn_with_pad.width == 92 and btn_with_pad.height == 32)
    check("createButton passes through padding_h", btn_with_pad.padding_h == 10)
    check("createButton passes through padding_v", btn_with_pad.padding_v == 5)

    local btn_auto = StorefrontUtils.createButton{
        text = "Clear",
    }
    check("createButton without width assigns default horizontal padding", (btn_auto.padding_h or 0) > 0)
    check("createButton without width assigns default vertical padding", (btn_auto.padding_v or 0) > 0)
end

-- 5. Test StorefrontClearCacheDialog button styling and layout
do
    local StorefrontClearCacheDialog = require("storefront_clear_cache_dialog")
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local ok, err = pcall(function()
        StorefrontClearCacheDialog.show()
    end)
    check("StorefrontClearCacheDialog.show executes without error", ok)
    if not ok then print("ClearCache show error:", err) end

    local overlay = _G.ui_tracker.last_shown
    check("Clear Cache dialog overlay is shown", overlay ~= nil)
    check("Clear Cache dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Clear Cache dialog has at least 2 layout rows", overlay and type(overlay.layout) == "table" and #overlay.layout >= 2)

    -- Close button should be at the bottom of the layout
    local bottom_row = overlay and overlay.layout and overlay.layout[#overlay.layout]
    local close_btn = bottom_row and bottom_row[1]
    check("Clear Cache dialog close button exists", close_btn ~= nil and close_btn.callback ~= nil)
    if close_btn and close_btn.callback then
        local close_ok = pcall(close_btn.callback)
        check("Clear Cache dialog close button callback executes", close_ok)
    end
end

print(string.format("=== Settings Regression Tests Complete: %d Failures ===", failures))
if failures > 0 then
    os.exit(1)
end
