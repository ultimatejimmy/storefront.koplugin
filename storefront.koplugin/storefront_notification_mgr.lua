--- storefront_notification_mgr.lua
--- Core logic and persistence for Storefront update background notifications.
-- Manages configuration (enabled, frequency, snooze, last checked) and decision logic.

local StorefrontSettings = require("storefront_settings")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then
    StorefrontLogger = {
        action = function() end,
        err = function() end,
        info = function() end,
        warn = function() end,
        debug = function() end,
    }
end

---@class StorefrontNotificationMgr
local NotificationMgr = {}

local SETTINGS_KEY_ENABLED = "notification_enabled"
local SETTINGS_KEY_FREQUENCY = "notification_frequency"
local SETTINGS_KEY_LAST_CHECKED = "notification_last_checked"
local SETTINGS_KEY_SNOOZE_UNTIL = "notification_snooze_until"

local FREQUENCY_SECONDS = {
    hourly = 3600,
    daily = 86400,
    weekly = 604800,
    monthly = 2592000, -- 30 days
}

local DEFAULT_FREQUENCY = "weekly"

local function getSettings()
    return StorefrontSettings.getSettings()
end

NotificationMgr.getSettings = getSettings

--- Returns whether background update notifications are enabled.
--- Defaults to true.
---@return boolean
function NotificationMgr.isEnabled()
    local settings = getSettings()
    local val = settings:readSetting(SETTINGS_KEY_ENABLED)
    if val == nil then
        return true
    end
    if val == false or val == "false" or val == 0 then
        return false
    end
    return val == true or val == "true" or val == 1
end

--- Enables or disables background update notifications.
---@param enabled boolean
function NotificationMgr.setEnabled(enabled)
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_ENABLED, enabled == true)
    settings:flush()
    StorefrontLogger.info(string.format("Storefront notifications: enabled set to %s", tostring(enabled)))
end

--- Returns the configured notification frequency identifier.
---@return string "hourly"|"daily"|"weekly"|"monthly"
function NotificationMgr.getFrequency()
    local settings = getSettings()
    local val = settings:readSetting(SETTINGS_KEY_FREQUENCY)
    if val and FREQUENCY_SECONDS[val] then
        return val
    end
    return DEFAULT_FREQUENCY
end

--- Sets the notification frequency.
---@param freq string "hourly"|"daily"|"weekly"|"monthly"
---@return boolean success
function NotificationMgr.setFrequency(freq)
    if not freq or not FREQUENCY_SECONDS[freq] then
        return false
    end
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_FREQUENCY, freq)
    settings:flush()
    StorefrontLogger.info(string.format("Storefront notifications: frequency set to %s", tostring(freq)))
    return true
end

--- Returns the interval in seconds for a given frequency string.
---@param freq? string
---@return number seconds
function NotificationMgr.getFrequencySeconds(freq)
    freq = freq or NotificationMgr.getFrequency()
    return FREQUENCY_SECONDS[freq] or FREQUENCY_SECONDS[DEFAULT_FREQUENCY]
end

--- Returns the timestamp of when notifications were last checked.
---@return number
function NotificationMgr.getLastChecked()
    local settings = getSettings()
    local val = settings:readSetting(SETTINGS_KEY_LAST_CHECKED)
    return tonumber(val) or 0
end

--- Marks the notification check timestamp as now.
--- Clears any expired snooze timestamp.
---@param now? number optional timestamp override (for testing)
function NotificationMgr.markChecked(now)
    now = now or os.time()
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_LAST_CHECKED, now)

    -- If snooze has elapsed, clear it
    local snooze = tonumber(settings:readSetting(SETTINGS_KEY_SNOOZE_UNTIL)) or 0
    if snooze > 0 and now >= snooze then
        settings:saveSetting(SETTINGS_KEY_SNOOZE_UNTIL, 0)
    end

    settings:flush()
end

--- Returns the timestamp until which notifications are snoozed, or 0.
---@return number
function NotificationMgr.getSnoozeUntil()
    local settings = getSettings()
    return tonumber(settings:readSetting(SETTINGS_KEY_SNOOZE_UNTIL)) or 0
end

--- Returns true if notifications are currently snoozed.
---@param now? number optional timestamp override
---@return boolean
function NotificationMgr.isSnoozed(now)
    now = now or os.time()
    local snooze = NotificationMgr.getSnoozeUntil()
    return snooze > now
end

--- Sets a snooze duration in seconds from now.
---@param seconds number
---@param now? number optional timestamp override
function NotificationMgr.setSnooze(seconds, now)
    now = now or os.time()
    seconds = tonumber(seconds) or 3600
    local target = now + seconds
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_SNOOZE_UNTIL, target)
    settings:flush()
    StorefrontLogger.info(string.format("Storefront notifications: snoozed for %d seconds (until %d)", seconds, target))
end

--- Sets a snooze until 8:00 AM the next day.
---@param now? number optional timestamp override
---@return number target_timestamp
function NotificationMgr.setSnoozeTomorrow(now)
    now = now or os.time()
    local d = os.date("*t", now)
    d.day = d.day + 1
    d.hour = 8
    d.min = 0
    d.sec = 0
    local target = os.time(d)
    local diff = target - now
    if diff <= 0 then
        diff = 86400
        target = now + diff
    end
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_SNOOZE_UNTIL, target)
    settings:flush()
    StorefrontLogger.info(string.format("Storefront notifications: snoozed until tomorrow 8:00 AM (target %d)", target))
    return target
end

--- Clears any active snooze.
function NotificationMgr.clearSnooze()
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_SNOOZE_UNTIL, 0)
    settings:flush()
end

local SETTINGS_KEY_DEBUG_ALWAYS_TRIGGER = "notification_debug_always_trigger"

--- Returns true if testing/developer mode is enabled via configuration or runtime global.
--- This gates the display of developer/testing sections in the settings UI.
---@return boolean
function NotificationMgr.isTestingConfigured()
    if _G.G_storefront_force_notifications == true or _G.G_storefront_debug_notifications == true then
        return true
    end
    local ok_cfg, cfg = pcall(require, "storefront_config")
    if not ok_cfg or type(cfg) ~= "table" then
        ok_cfg, cfg = pcall(require, "storefront_configuration")
    end
    if ok_cfg and type(cfg) == "table" then
        if cfg.debug_notifications == true
            or cfg.force_notifications == true
            or cfg.testing_notifications == true
            or cfg.show_notification_testing == true
            or cfg.notification_testing == true
            or cfg.notifications_testing == true
            or cfg.notification_debug == true then
            return true
        end
    end
    return false
end

--- Returns whether the test/debug mode to force notifications on every launch is enabled.
--- Checks runtime global, storefront_config.lua, and settings.
---@return boolean
function NotificationMgr.isDebugAlwaysTrigger()
    if _G.G_storefront_force_notifications == true then
        return true
    end
    local ok_cfg, cfg = pcall(require, "storefront_config")
    if not ok_cfg or type(cfg) ~= "table" then
        ok_cfg, cfg = pcall(require, "storefront_configuration")
    end
    if ok_cfg and type(cfg) == "table" then
        if cfg.debug_notifications == true
            or cfg.force_notifications == true
            or cfg.testing_notifications == true then
            return true
        end
    end
    local settings = getSettings()
    local val = settings:readSetting(SETTINGS_KEY_DEBUG_ALWAYS_TRIGGER)
    return val == true or val == "true" or val == 1
end

--- Enables or disables the debug always-trigger mode.
---@param enabled boolean
function NotificationMgr.setDebugAlwaysTrigger(enabled)
    local settings = getSettings()
    settings:saveSetting(SETTINGS_KEY_DEBUG_ALWAYS_TRIGGER, enabled == true)
    settings:flush()
    StorefrontLogger.info(string.format("Storefront notifications: debug_always_trigger set to %s", tostring(enabled)))
end

--- Checks if network is currently connected without prompting the user.
---@return boolean
function NotificationMgr.isNetworkConnected()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not (ok_nm and NetworkMgr) then
        return false
    end
    if type(NetworkMgr.isOnline) == "function" then
        return NetworkMgr:isOnline() == true
    elseif type(NetworkMgr.isWifiOn) == "function" then
        return NetworkMgr:isWifiOn() == true
    elseif type(NetworkMgr.isConnected) == "function" then
        return NetworkMgr:isConnected() == true
    end
    return false
end

--- Determines whether an update notification check should run now.
--- Requires:
--- 1. Notifications are enabled (or debug mode is on)
--- 2. Network is connected (or is_online param is true, or debug mode is on)
--- 3. Snooze is not active (or has expired, or debug mode is on)
--- 4. Configured frequency interval has elapsed since last check (or check was triggered by expired snooze or debug mode)
---@param now? number optional timestamp override
---@param is_online? boolean optional online override
---@return boolean should_check, string? reason
function NotificationMgr.shouldCheckNow(now, is_online)
    if NotificationMgr.isDebugAlwaysTrigger() then
        return true, "debug_forced"
    end

    if not NotificationMgr.isEnabled() then
        return false, "disabled"
    end

    if is_online == nil then
        is_online = NotificationMgr.isNetworkConnected()
    end
    if not is_online then
        return false, "offline"
    end

    now = now or os.time()

    local snooze_until = NotificationMgr.getSnoozeUntil()
    if snooze_until > 0 then
        if now < snooze_until then
            return false, "snoozed"
        end
        -- Snooze has expired! This triggers an immediate check.
        return true, "snooze_expired"
    end

    local last_check = NotificationMgr.getLastChecked()
    if last_check <= 0 then
        return true, "first_run"
    end

    local interval = NotificationMgr.getFrequencySeconds()
    local elapsed = now - last_check
    if elapsed >= interval then
        return true, "interval_elapsed"
    end

    return false, "interval_not_elapsed"
end

return NotificationMgr
