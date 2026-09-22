-- storefront_settings_persistence_test.lua
-- Regression tests verifying settings persistence and non-clobbering across Storefront modules.

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

print("=== Running Storefront Settings Persistence & Non-Clobbering Tests ===")

local StorefrontSettings = require("storefront_settings")
local NotificationMgr = require("storefront_notification_mgr")
local MainStorefront = require("main")

-- 1. Verify StorefrontSettings provides a shared singleton instance
do
    local s1 = StorefrontSettings.getSettings()
    local s2 = StorefrontSettings.getSettings()
    check("StorefrontSettings.getSettings() returns singleton instance", s1 == s2)

    local notif_settings = NotificationMgr.getSettings()
    check("NotificationMgr.getSettings() shares StorefrontSettings instance", notif_settings == s1)
end

-- 2. Verify StorefrontSettings proxy methods
do
    StorefrontSettings:saveSetting("test_key", "test_val")
    check("StorefrontSettings:saveSetting saves value", StorefrontSettings:readSetting("test_key") == "test_val")
    check("StorefrontSettings:has is true for existing key", StorefrontSettings:has("test_key") == true)
    check("StorefrontSettings:hasNot is false for existing key", StorefrontSettings:hasNot("test_key") == false)

    StorefrontSettings:saveSetting("test_bool", true)
    check("StorefrontSettings:isTrue works", StorefrontSettings:isTrue("test_bool") == true)
    check("StorefrontSettings:nilOrTrue works", StorefrontSettings:nilOrTrue("test_bool") == true)

    StorefrontSettings:delSetting("test_key")
    check("StorefrontSettings:delSetting deletes key", StorefrontSettings:readSetting("test_key") == nil)
    check("StorefrontSettings:has is false after deletion", StorefrontSettings:has("test_key") == false)
end

-- 3. Core Regression: Notification frequency changed to daily is preserved across saveBrowserState
do
    -- Set to daily
    NotificationMgr.setFrequency("daily")
    check("NotificationMgr.getFrequency() is 'daily'", NotificationMgr.getFrequency() == "daily")
    check("StorefrontSettings has 'notification_frequency' = 'daily'", StorefrontSettings:readSetting("notification_frequency") == "daily")

    -- Simulate user closing Storefront (which invokes saveBrowserState -> StorefrontSettings:flush())
    MainStorefront.browser_state = MainStorefront.browser_state or { page = 1, kind = "plugin", tab = "Plugins" }
    MainStorefront:saveBrowserState()

    -- Verify notification_frequency was NOT clobbered by saveBrowserState
    check("NotificationMgr.getFrequency() remains 'daily' after saveBrowserState", NotificationMgr.getFrequency() == "daily")
    check("StorefrontSettings still has 'daily' after saveBrowserState", StorefrontSettings:readSetting("notification_frequency") == "daily")

    -- Change to hourly
    NotificationMgr.setFrequency("hourly")
    check("NotificationMgr.setFrequency('hourly') sets hourly", NotificationMgr.getFrequency() == "hourly")
    MainStorefront:saveBrowserState()
    check("NotificationMgr.getFrequency() remains 'hourly' after saveBrowserState", NotificationMgr.getFrequency() == "hourly")

    -- Change to monthly
    NotificationMgr.setFrequency("monthly")
    check("NotificationMgr.setFrequency('monthly') sets monthly", NotificationMgr.getFrequency() == "monthly")
    MainStorefront:saveBrowserState()
    check("NotificationMgr.getFrequency() remains 'monthly' after saveBrowserState", NotificationMgr.getFrequency() == "monthly")

    -- Restore to daily for subsequent tests
    NotificationMgr.setFrequency("daily")
    check("Frequency restored to 'daily'", NotificationMgr.getFrequency() == "daily")
end

-- 4. Notification enabled toggle survives browser state saves
do
    NotificationMgr.setEnabled(false)
    check("NotificationMgr.isEnabled() is false", NotificationMgr.isEnabled() == false)
    check("StorefrontSettings has notification_enabled = false", StorefrontSettings:readSetting("notification_enabled") == false)

    MainStorefront:saveBrowserState()
    check("NotificationMgr.isEnabled() remains false after saveBrowserState", NotificationMgr.isEnabled() == false)

    NotificationMgr.setEnabled(true)
    check("NotificationMgr.isEnabled() restored to true", NotificationMgr.isEnabled() == true)
    MainStorefront:saveBrowserState()
    check("NotificationMgr.isEnabled() remains true after saveBrowserState", NotificationMgr.isEnabled() == true)
end

-- 5. Cross-module settings changes do not clobber each other
do
    -- Simulate settings card toggling include_zero_star_forks
    StorefrontSettings:saveSetting("include_zero_star_forks", true)
    StorefrontSettings:flush()

    check("Notification frequency still 'daily' after include_zero_star_forks save", NotificationMgr.getFrequency() == "daily")
    check("include_zero_star_forks is true", StorefrontSettings:readSetting("include_zero_star_forks") == true)

    -- Save browser state again
    MainStorefront:saveBrowserState()
    check("Both include_zero_star_forks and notification_frequency intact",
        StorefrontSettings:readSetting("include_zero_star_forks") == true and
        NotificationMgr.getFrequency() == "daily")
end

-- 6. Blueprint manager reads notification_enabled and notification_frequency correctly
do
    local BlueprintMgr = require("storefront_blueprint_mgr")
    local bp = BlueprintMgr.generateBlueprint({ name = "Test BP", include_settings = true })
    check("Exported blueprint has settings table", bp and bp.settings and bp.settings.storefront ~= nil)
    if bp and bp.settings and bp.settings.storefront then
        check("Blueprint has correct notification_frequency ('daily')", bp.settings.storefront.notification_frequency == "daily")
        check("Blueprint has correct notifications_enabled (true)", bp.settings.storefront.notifications_enabled == true)
    end
end

-- 7. Reset to weekly clean state
do
    NotificationMgr.setFrequency("weekly")
    check("NotificationMgr.getFrequency() reset to weekly", NotificationMgr.getFrequency() == "weekly")
    MainStorefront:saveBrowserState()
    check("NotificationMgr.getFrequency() persists as weekly after saveBrowserState", NotificationMgr.getFrequency() == "weekly")
end

print(string.format("=== Settings Persistence Tests Complete: %d Failures ===", failures))
if failures > 0 then
    os.exit(1)
else
    os.exit(0)
end
