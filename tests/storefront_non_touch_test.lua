require("tests/spec_helper")

package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

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

local StorefrontUtils = require("storefront_utils")
local StorefrontListItem = require("storefront_list_item")
local StorefrontAboutDialog = require("storefront_about_dialog")
local StorefrontClearCacheDialog = require("storefront_clear_cache_dialog")
local StorefrontDeleteUI = require("storefront_delete_ui")
local StorefrontFolderPicker = require("storefront_folder_picker")
local StorefrontFilterDialog = require("storefront_filter_dialog")
local StorefrontScreensaverConfig = require("storefront_screensaver_config")
local StorefrontScreensaverGallery = require("storefront_screensaver_gallery")
local StorefrontScreensaverDetail = require("storefront_screensaver_detail")
local StorefrontDetailsDialog = require("storefront_details_dialog")
local StorefrontBrowserUI = require("storefront_browser_ui")

print("=== Running Non-Touch & FocusManager Unit Tests ===")

-- 1. StorefrontListItem non-touch protocol
do
    local called = false
    local item = StorefrontListItem:new{
        entry = {
            name = "Test Item",
            is_entry = true,
            callback = function()
                called = true
            end,
        },
        width = 500,
    }
    check("StorefrontListItem isFocusable returns true", item:isFocusable() == true)
    check("StorefrontListItem onFocus exists", type(item.onFocus) == "function")
    check("StorefrontListItem onUnfocus exists", type(item.onUnfocus) == "function")
    check("StorefrontListItem onTapSelect exists", type(item.onTapSelect) == "function")
    item:onTapSelect()
    check("StorefrontListItem onTapSelect invokes entry callback", called == true)
end

-- 2. Confirmation Dialogs (StorefrontUtils)
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontUtils.showConfirmDialog{
        title = "Test",
        text = "Confirm message",
        ok_callback = function() end,
    }
    local overlay = _G.ui_tracker.last_shown
    check("Confirmation dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Confirmation dialog has 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 1)
    check("Confirmation dialog has Close key event", overlay and overlay.key_events and overlay.key_events.Close ~= nil)
end

-- 3. About Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local mock_sf = {
        fetchOnlineReleaseVersion = function() return "v1.0.0" end,
    }
    StorefrontAboutDialog.show(mock_sf)
    local overlay = _G.ui_tracker.last_shown
    check("About dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("About dialog has multi-row 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 2)
end

-- 4. Clear Cache Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontClearCacheDialog.show()
    local overlay = _G.ui_tracker.last_shown
    check("Clear Cache dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Clear Cache dialog has 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 1)
end

-- 5. Delete UI Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local mock_sf = {
        executeDelete = function() end,
    }
    StorefrontDeleteUI.showDeleteConfirmationDialog(mock_sf, { name = "Test Plugin", dirname = "test.koplugin" }, "plugin", false)
    local overlay = _G.ui_tracker.last_shown
    check("Delete UI dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Delete UI dialog has 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 1)
end

-- 6. Screensaver Config Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local mock_sf = {
        refreshCurrentBrowserTab = function() end,
    }
    StorefrontScreensaverConfig.show(mock_sf)
    local overlay = _G.ui_tracker.last_shown
    check("Screensaver Config dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Screensaver Config dialog has 2D layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 2)
end

-- 7. Folder Picker Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontFolderPicker.show{
        start_path = "/tmp",
        on_select = function() end,
    }
    local overlay = _G.ui_tracker.last_shown
    check("Folder Picker dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Folder Picker dialog has 2D layout", overlay and type(overlay.layout) == "table")
end

-- 8. Filter Dialogs
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontFilterDialog.showInstalledFilter({
        filter_disabled = "all",
        filter_user_installed = "all",
        filter_ignored = "all",
        on_apply = function() end,
    })
    local overlay = _G.ui_tracker.last_shown
    check("Installed Filter dialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Installed Filter dialog has 2D layout", overlay and type(overlay.layout) == "table")

    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontFilterDialog.showCatalogFilter({
        categories = { "tools", "games" },
        selected_category = "all",
        sort_order = "featured",
        on_apply = function() end,
    })
    overlay = _G.ui_tracker.last_shown
    check("Catalog Filter dialog uses FocusManager", overlay and overlay.type == "FocusManager")

    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    StorefrontFilterDialog.showScreensaverFilter({
        categories = { "nature", "space" },
        selected_categories = {},
        sort_order = "popular",
        on_apply = function() end,
    })
    overlay = _G.ui_tracker.last_shown
    check("Screensaver Filter dialog uses FocusManager", overlay and overlay.type == "FocusManager")
end

-- 9. Screensaver Gallery Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local mock_sf = {
        fetchScreensavers = function()
            return { { id = "ss1", title = "Nature 1" }, { id = "ss2", title = "Nature 2" } }
        end,
    }
    StorefrontScreensaverGallery.show(mock_sf)
    local overlay = _G.ui_tracker.last_shown
    check("Screensaver Gallery uses FocusManager", overlay and overlay.type == "FocusManager")
    check("Screensaver Gallery has 2D layout", overlay and type(overlay.layout) == "table")
end

-- 10. Screensaver Detail Dialog
do
    local detail = StorefrontScreensaverDetail:new{
        item = { id = "ss_test", title = "Test Wallpaper" },
    }
    check("Screensaver Detail dialog extends FocusManager", detail and detail.type == "FocusManager")
    check("Screensaver Detail dialog has 2D layout", detail and type(detail.layout) == "table" and #detail.layout >= 2)
end

-- 11. Details Dialog
do
    local details = StorefrontDetailsDialog:new{
        repo = { name = "test_plugin", full_name = "user/test_plugin" },
    }
    check("Details dialog extends FocusManager", details and details.type == "FocusManager")
    check("Details dialog has 2D layout", details and type(details.layout) == "table" and #details.layout >= 2)

    local font_details = StorefrontDetailsDialog:new{
        repo = { name = "test_font", kind = "font", is_font = true },
    }
    check("Font Details dialog has font size controls in tab_buttons", font_details and font_details.tab_buttons and #font_details.tab_buttons == 4)
    check("Font Details dialog layout row 3 has 4 items", font_details and font_details.layout and font_details.layout[3] and #font_details.layout[3] == 4)
    
    local initial_sz = font_details.preview_font_size or 22
    -- Select dec_btn (row 3, col 2)
    font_details.selected = { x = 2, y = 3 }
    font_details:onPress()
    check("Pressing dec_btn decreases font size", font_details.preview_font_size == initial_sz - 1)

    -- Select inc_btn (row 3, col 4)
    font_details.selected = { x = 4, y = 3 }
    font_details:onPress()
    check("Pressing inc_btn increases font size", font_details.preview_font_size == initial_sz)
end

-- 12. Browser Dialog Key Isolation & Tabs Layout
do
    local browser = StorefrontBrowserUI:new{
        title = "Storefront",
        items = {},
        page = 1,
        total_pages = 1,
        is_probe = true,
    }
    check("Browser dialog is FocusManager", browser and browser.type == "FocusManager")
    check("Browser dialog has header row with search, settings, close", browser and browser.layout and browser.layout[1] and #browser.layout[1] == 3)
    check("Browser dialog has tab row in layout", browser and browser.layout and browser.layout[2] and #browser.layout[2] >= 6)
    
    local has_spans_in_tabs = false
    if browser.layout and browser.layout[2] then
        for _, tab_item in ipairs(browser.layout[2]) do
            if tab_item.type == "HorizontalSpan" then has_spans_in_tabs = true end
        end
    end
    check("Browser dialog tabs layout contains no HorizontalSpans", not has_spans_in_tabs)

    local has_bad_down = false
    local has_bad_up = false
    if browser.key_events and browser.key_events.NextPage then
        for _, mapping in ipairs(browser.key_events.NextPage) do
            for _, key in ipairs(mapping) do
                if key == "Down" or key == "Right" then has_bad_down = true end
            end
        end
    end
    if browser.key_events and browser.key_events.PrevPage then
        for _, mapping in ipairs(browser.key_events.PrevPage) do
            for _, key in ipairs(mapping) do
                if key == "Up" or key == "Left" then has_bad_up = true end
            end
        end
    end
    check("Browser dialog NextPage does not hijack D-pad Down/Right", not has_bad_down)
    check("Browser dialog PrevPage does not hijack D-pad Up/Left", not has_bad_up)
end

-- 13. Focus Stepping Navigation Verification
do
    local browser = StorefrontBrowserUI:new{
        title = "Storefront",
        items = {
            { name = "Plugin 1", is_entry = true, callback = function() end },
            { name = "Plugin 2", is_entry = true, callback = function() end },
            { name = "Plugin 3", is_entry = true, callback = function() end },
        },
        page = 1,
        total_pages = 1,
        is_probe = true,
    }
    -- Tab 1 (Plugins)
    browser.selected = { x = 1, y = 2 }
    browser:onFocusMove({ 0, 1 })
    check("Down from Tab 1 lands on first list item (y=3, x=1)", browser.selected.y == 3 and browser.selected.x == 1)

    -- Tab 3 (Fonts)
    browser.selected = { x = 3, y = 2 }
    browser:onFocusMove({ 0, 1 })
    check("Down from Tab 3 lands on first list item (y=3, x=1)", browser.selected.y == 3 and browser.selected.x == 1)

    -- Tab 4 (Screensavers)
    browser.selected = { x = 4, y = 2 }
    browser:onFocusMove({ 0, 1 })
    check("Down from Tab 4 lands on first list item (y=3, x=1)", browser.selected.y == 3 and browser.selected.x == 1)
end

-- 14. Details Dialog Versions Tab Focus Navigation
do
    local details = StorefrontDetailsDialog:new{
        repo = { name = "test_plugin", full_name = "user/test_plugin" },
    }
    details.active_tab = "versions"
    if details.loadContent then
        details.loadContent("versions")
    end
    check("Details dialog has tab_item_widgets after loading versions", details.tab_item_widgets and #details.tab_item_widgets > 0)
    
    -- Versions tab is button 3 on row 3
    details.selected = { x = 3, y = 3 }
    details:onFocusMove({ 0, 1 })
    check("Down from Versions tab button lands on toggle_btn (y=4, x=1)", details.selected.y == 4 and details.selected.x == 1)
    details:onFocusMove({ 0, 1 })
    check("Down from toggle_btn lands on first version item (y=5, x=1)", details.selected.y == 5 and details.selected.x == 1)
end

print(string.format("=== Non-Touch & FocusManager Tests Complete: %d Failures ===", failures))
if failures > 0 then
    os.exit(1)
end
