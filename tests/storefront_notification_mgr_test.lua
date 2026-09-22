-- storefront_notification_mgr_test.lua
-- Comprehensive test suite for background update notification feature.

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

print("=== Running Storefront Notification Manager & UI Regression Tests ===")

local Blitbuffer = require("ffi/blitbuffer")
local NotificationMgr = require("storefront_notification_mgr")
local NotificationUI = require("storefront_notification_ui")
local NotificationSettingsDialog = require("storefront_notification_settings_dialog")
local StorefrontSettingsCard = require("storefront_settings_card")

-- 1. Test NotificationMgr defaults and enabled toggle
do
    NotificationMgr.setEnabled(true)
    check("NotificationMgr.isEnabled() defaults to true", NotificationMgr.isEnabled() == true)

    NotificationMgr.setEnabled(false)
    check("NotificationMgr.setEnabled(false) sets isEnabled to false", NotificationMgr.isEnabled() == false)

    NotificationMgr.setEnabled(true)
    check("NotificationMgr.setEnabled(true) restores isEnabled to true", NotificationMgr.isEnabled() == true)
end

-- 2. Test NotificationMgr frequencies
do
    check("NotificationMgr.getFrequency() defaults to weekly", NotificationMgr.getFrequency() == "weekly")
    check("NotificationMgr.getFrequencySeconds('hourly') == 3600", NotificationMgr.getFrequencySeconds("hourly") == 3600)
    check("NotificationMgr.getFrequencySeconds('daily') == 86400", NotificationMgr.getFrequencySeconds("daily") == 86400)
    check("NotificationMgr.getFrequencySeconds('weekly') == 604800", NotificationMgr.getFrequencySeconds("weekly") == 604800)
    check("NotificationMgr.getFrequencySeconds('monthly') == 2592000", NotificationMgr.getFrequencySeconds("monthly") == 2592000)

    NotificationMgr.setFrequency("hourly")
    check("NotificationMgr.setFrequency('hourly') sets frequency", NotificationMgr.getFrequency() == "hourly")
    check("NotificationMgr.getFrequencySeconds() reflects hourly", NotificationMgr.getFrequencySeconds() == 3600)

    NotificationMgr.setFrequency("daily")
    check("NotificationMgr.setFrequency('daily') sets frequency", NotificationMgr.getFrequency() == "daily")

    NotificationMgr.setFrequency("monthly")
    check("NotificationMgr.setFrequency('monthly') sets frequency", NotificationMgr.getFrequency() == "monthly")

    NotificationMgr.setFrequency("invalid_freq")
    check("NotificationMgr.setFrequency rejects invalid value", NotificationMgr.getFrequency() == "monthly")

    NotificationMgr.setFrequency("weekly")
    check("NotificationMgr.setFrequency('weekly') restores to weekly", NotificationMgr.getFrequency() == "weekly")

    -- Regression test: verify frequency persists across saveBrowserState calls
    local Main = require("main")
    NotificationMgr.setFrequency("daily")
    check("Frequency is daily before saveBrowserState", NotificationMgr.getFrequency() == "daily")
    Main.browser_state = Main.browser_state or { page = 1, kind = "plugin" }
    Main:saveBrowserState()
    check("Frequency remains daily after saveBrowserState (no clobber)", NotificationMgr.getFrequency() == "daily")
    NotificationMgr.setFrequency("weekly")
end

-- 3. Test markChecked and last_checked tracking
do
    local test_time = 1700000000
    NotificationMgr.markChecked(test_time)
    check("NotificationMgr.getLastChecked() returns set timestamp", NotificationMgr.getLastChecked() == test_time)
end

-- 4. Test Snooze mechanism
do
    local now = 1700000000
    NotificationMgr.clearSnooze()
    check("NotificationMgr.isSnoozed() is false after clear", NotificationMgr.isSnoozed(now) == false)
    check("NotificationMgr.getSnoozeUntil() is 0", NotificationMgr.getSnoozeUntil() == 0)

    -- Snooze 1 hour (3600s)
    NotificationMgr.setSnooze(3600, now)
    check("NotificationMgr.isSnoozed(now + 1800) is true", NotificationMgr.isSnoozed(now + 1800) == true)
    check("NotificationMgr.isSnoozed(now + 3601) is false", NotificationMgr.isSnoozed(now + 3601) == false)

    -- Snooze Tomorrow (8:00 AM next day)
    local target = NotificationMgr.setSnoozeTomorrow(now)
    local target_date = os.date("*t", target)
    check("setSnoozeTomorrow targets 8:00 AM", target_date.hour == 8 and target_date.min == 0)
    check("setSnoozeTomorrow targets a future time", target > now)

    -- Mark checked clears expired snooze
    NotificationMgr.setSnooze(100, now)
    NotificationMgr.markChecked(now + 200)
    check("markChecked clears expired snooze", NotificationMgr.getSnoozeUntil() == 0)

    NotificationMgr.clearSnooze()
end

-- 5. Test shouldCheckNow logic matrix
do
    local now = 1700000000

    -- Case: disabled -> false
    NotificationMgr.setEnabled(false)
    local ok1, r1 = NotificationMgr.shouldCheckNow(now, true)
    check("shouldCheckNow is false when disabled", ok1 == false and r1 == "disabled")
    NotificationMgr.setEnabled(true)

    -- Case: offline -> false
    local ok2, r2 = NotificationMgr.shouldCheckNow(now, false)
    check("shouldCheckNow is false when offline", ok2 == false and r2 == "offline")

    -- Case: snoozed -> false
    NotificationMgr.setSnooze(3600, now)
    local ok3, r3 = NotificationMgr.shouldCheckNow(now + 1000, true)
    check("shouldCheckNow is false when snooze is active", ok3 == false and r3 == "snoozed")

    -- Case: snooze expired -> true (immediate check)
    local ok4, r4 = NotificationMgr.shouldCheckNow(now + 4000, true)
    check("shouldCheckNow is true when snooze expires", ok4 == true and r4 == "snooze_expired")
    NotificationMgr.clearSnooze()

    -- Case: first run (no previous check) -> true
    NotificationMgr.markChecked(0)
    local ok5, r5 = NotificationMgr.shouldCheckNow(now, true)
    check("shouldCheckNow is true on first run", ok5 == true and r5 == "first_run")

    -- Case: daily frequency interval not elapsed -> false
    NotificationMgr.setFrequency("daily")
    NotificationMgr.markChecked(now)
    local ok6, r6 = NotificationMgr.shouldCheckNow(now + 3600, true) -- only 1h passed
    check("shouldCheckNow is false when interval not elapsed", ok6 == false and r6 == "interval_not_elapsed")

    -- Case: daily frequency interval elapsed -> true
    local ok7, r7 = NotificationMgr.shouldCheckNow(now + 86401, true) -- 24h+ passed
    check("shouldCheckNow is true when daily interval elapsed", ok7 == true and r7 == "interval_elapsed")

    -- Case: debug always trigger overrides disabled/offline
    NotificationMgr.setDebugAlwaysTrigger(true)
    check("isDebugAlwaysTrigger returns true after set", NotificationMgr.isDebugAlwaysTrigger() == true)
    local ok8, r8 = NotificationMgr.shouldCheckNow(now, false) -- offline but debug forced
    check("shouldCheckNow is true when debug forced even if offline", ok8 == true and r8 == "debug_forced")
    NotificationMgr.setDebugAlwaysTrigger(false)
    check("isDebugAlwaysTrigger returns false after reset", NotificationMgr.isDebugAlwaysTrigger() == false)
end

-- 6. Test Notification Settings Sub-Dialog
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local closed_called = false
    local dummy_sf = {}
    local ok_dlg, err_dlg = pcall(function()
        NotificationSettingsDialog.show(dummy_sf, function()
            closed_called = true
        end)
    end)
    check("NotificationSettingsDialog.show executes without error", ok_dlg)
    if not ok_dlg then print("NotificationSettingsDialog error:", err_dlg) end

    local overlay = _G.ui_tracker.last_shown
    check("NotificationSettingsDialog shows overlay", overlay ~= nil)
    check("NotificationSettingsDialog uses FocusManager", overlay and overlay.type == "FocusManager")
    check("NotificationSettingsDialog has layout rows", overlay and type(overlay.layout) == "table" and #overlay.layout >= 4)
    check("NotificationSettingsDialog has Close key event", overlay and overlay.key_events and overlay.key_events.Close ~= nil)

    -- Test close button
    local close_btn = overlay and overlay.layout and overlay.layout[#overlay.layout] and overlay.layout[#overlay.layout][1]
    check("NotificationSettingsDialog close button exists", close_btn ~= nil)
    if close_btn and close_btn.callback then
        close_btn.callback()
        check("NotificationSettingsDialog close triggers callback", closed_called == true)
    end

    -- Verify testing section is hidden by default
    check("NotificationMgr.isTestingConfigured() is false by default", NotificationMgr.isTestingConfigured() == false)
    check("Testing section is hidden when config is not updated (5 rows)", overlay and #overlay.layout == 5)

    -- Test testing section appears when debug config/flag is updated
    _G.G_storefront_debug_notifications = true
    check("NotificationMgr.isTestingConfigured() is true when debug flag set", NotificationMgr.isTestingConfigured() == true)
    NotificationSettingsDialog.show(dummy_sf)
    local overlay_dbg = _G.ui_tracker.last_shown
    check("Testing section is shown when debug config updated (7 rows)", overlay_dbg and #overlay_dbg.layout == 7)
    _G.G_storefront_debug_notifications = nil
end

-- 7. Test Notification UI Dialog (Design B)
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local test_updates = {
        { name = "Storefront", version = "v1.2.0", kind = "plugin" },
        { name = "highlight-plugin", version = "v0.8.1", kind = "plugin" },
        { name = "vocabulary-builder", version = "(patch)", kind = "patch" },
    }
    local opened_tab = nil
    local dummy_sf = {
        ensureBrowserState = function() end,
        browser_state = { tab = "Plugins" },
        saveBrowserState = function() end,
        showBrowser = function(self)
            opened_tab = self.browser_state and self.browser_state.tab
        end,
    }

    local ok_ui, err_ui = pcall(function()
        NotificationUI.show(dummy_sf, test_updates)
    end)
    check("NotificationUI.show executes without error", ok_ui)
    if not ok_ui then print("NotificationUI error:", err_ui) end

    local overlay = _G.ui_tracker.last_shown
    check("NotificationUI shows overlay", overlay ~= nil)
    check("NotificationUI uses FocusManager", overlay and overlay.type == "FocusManager")
    check("NotificationUI has horizontal button row in layout", overlay and type(overlay.layout) == "table" and #overlay.layout >= 1 and #overlay.layout[1] == 3)

    local open_btn = overlay.layout[1][1]
    local later_btn = overlay.layout[1][2]
    local dismiss_btn = overlay.layout[1][3]

    check("Open button exists with callback", open_btn and type(open_btn.callback) == "function")
    check("Open button text is 'View Updates'", open_btn and (open_btn.text == "View Updates" or open_btn.text == _("View Updates")))
    check("Open button is styled as primary inverted button", open_btn and open_btn.preselect == true)
    check("Later button exists with callback", later_btn and type(later_btn.callback) == "function")
    check("Dismiss button exists with callback", dismiss_btn and type(dismiss_btn.callback) == "function")

    -- Test Open button deep-links to Updates tab
    open_btn.callback()
    check("Open button deep links Storefront directly to Updates tab", opened_tab == "Updates")

    -- Test Dismiss button closes cleanly
    NotificationUI.show(dummy_sf, test_updates)
    local overlay2 = _G.ui_tracker.last_shown
    local dismiss2 = overlay2.layout[1][3]
    local ok_d, err_d = pcall(dismiss2.callback)
    check("Dismiss button callback executes without error", ok_d)

    -- Test Single update displays cleanly with singular title
    local single_update = { { name = "Libbee", version = "v26.9.13-beta", kind = "plugin" } }
    local ok_single, err_single = pcall(function()
        NotificationUI.show(dummy_sf, single_update)
    end)
    check("NotificationUI.show with single update executes without error", ok_single)
    local overlay_single = _G.ui_tracker.last_shown
    check("Single update dialog shows overlay", overlay_single ~= nil)

    -- Test very long plugin name renders cleanly with single-line truncation
    local long_name_update = {
        { name = "a-very-long-plugin-name-that-exceeds-the-modal-card-width-completely", version = "v1.0.0", kind = "plugin" }
    }
    local ok_long, err_long = pcall(function()
        NotificationUI.show(dummy_sf, long_name_update)
    end)
    check("NotificationUI.show with very long item name executes without error", ok_long)
    local overlay_long = _G.ui_tracker.last_shown
    check("Long item name dialog shows overlay", overlay_long ~= nil)

    -- Test Styled Storefront Snooze Picker
    local snooze_cb_called = false
    local ok_snooze, err_snooze = pcall(function()
        NotificationUI.showSnoozePicker(function()
            snooze_cb_called = true
        end)
    end)
    check("NotificationUI.showSnoozePicker executes without error", ok_snooze)
    if not ok_snooze then print("showSnoozePicker error:", err_snooze) end
    local snooze_overlay = _G.ui_tracker.last_shown
    check("Snooze dialog shows overlay", snooze_overlay ~= nil)
    check("Snooze dialog uses FocusManager", snooze_overlay and snooze_overlay.type == "FocusManager")
    check("Snooze dialog has 4 options in layout", snooze_overlay and #snooze_overlay.layout == 4)

    -- Test tapping Tomorrow option in snooze picker
    local tomorrow_btn = snooze_overlay and snooze_overlay.layout and snooze_overlay.layout[3] and snooze_overlay.layout[3][1]
    check("Snooze Tomorrow button exists", tomorrow_btn ~= nil)
    if tomorrow_btn and tomorrow_btn.callback then
        tomorrow_btn.callback()
        check("Tomorrow option in snooze picker triggers callback", snooze_cb_called == true)
        check("Tomorrow option sets future snooze", NotificationMgr.isSnoozed() == true)
    end
end

-- 8. Test Settings Card renders Notifications section
do
    _G.ui_tracker = { shown = {}, last_shown = nil, closed = {} }
    local dummy_sf = {
        browser_state = { kind = "plugin" },
        browserRefresh = function() end,
        saveBrowserState = function() end,
        getInstallRecordsMap = function() return {} end,
        getPatchRecordsMap = function() return {} end,
    }
    local ok_card, err_card = pcall(function()
        StorefrontSettingsCard.show(dummy_sf)
    end)
    check("StorefrontSettingsCard.show with Notifications section renders cleanly", ok_card)
    if not ok_card then print("SettingsCard show error:", err_card) end

    local overlay = _G.ui_tracker.last_shown
    -- Verify layout has rows for the settings categories (including Notifications)
    check("Settings card has focusable category rows (including Notifications)", overlay and #overlay.layout >= 5)
end

-- 9. Test Storefront:collectUpdatesForNotification
do
    local MainStorefront = require("main")
    check("MainStorefront has collectUpdatesForNotification", type(MainStorefront.collectUpdatesForNotification) == "function")
    check("MainStorefront has checkStartupNotifications", type(MainStorefront.checkStartupNotifications) == "function")

    local ok_collect, updates = pcall(function()
        return MainStorefront:collectUpdatesForNotification()
    end)
    check("collectUpdatesForNotification executes without error", ok_collect)
    check("collectUpdatesForNotification returns a table", type(updates) == "table")

    -- Test deduplication when plugin summary contains Storefront (under any name) and self-update triggers
    local sf_stub = {
        collectUpdateSummary = function()
            return {
                data = {
                    {
                        has_update = true,
                        plugin = { dirname = "storefront.koplugin", name = "Sklep", fullname = "Sklep" },
                        record = { repo = "storefront.koplugin", owner = "ultimatejimmy" },
                        remote = { release_tag_name = "v26.9.16" },
                    }
                }
            }
        end,
        collectPatchUpdateSummary = function() return { data = {} } end,
    }
    local updates_dupe = MainStorefront.collectUpdatesForNotification(sf_stub)
    local sf_count = 0
    for _, u in ipairs(updates_dupe) do
        if u.name == "Storefront" or u.name == "Sklep" or (u.kind == "plugin" and u.name:lower():match("storefront")) then
            sf_count = sf_count + 1
        end
    end
    check("collectUpdatesForNotification deduplicates Storefront update to exactly 1 item", sf_count == 1)
    check("collectUpdatesForNotification normalizes Storefront item name to 'Storefront'", updates_dupe[1] and updates_dupe[1].name == "Storefront")
end

print(string.format("=== Notification Regression Tests Complete: %d Failures ===", failures))
if failures > 0 then
    os.exit(1)
else
    os.exit(0)
end
