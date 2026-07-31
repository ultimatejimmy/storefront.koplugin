-- storefront_refresh_guard_test.lua
-- Unit tests for Refresh Safeguarding & In-Flight Background Refresh Detection

package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS ", label)
    else
        failures = failures + 1
        print("FAIL ", label)
    end
    io.stdout:flush()
end

-- Mock dependencies for headless testing
package.loaded["socket.http"] = {}
package.loaded["ssl.https"] = {}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end }

local memory_store = {}
package.loaded["luasettings"] = {
    open = function()
        return {
            readSetting = function(self, k) return memory_store[k] end,
            saveSetting = function(self, k, v) memory_store[k] = v end,
            delSetting = function(self, k) memory_store[k] = nil end,
            flush = function() end,
        }
    end
}

local shown_toasts = {}
package.loaded["storefront_toast"] = {
    show = function(text, timeout, opts)
        table.insert(shown_toasts, text)
        return { close = function() end }
    end
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    forceRePaint = function() end,
    scheduleIn = function() end,
}
package.loaded["storefront_net_github"] = {
    isDirectApiEnabled = function() return false end,
}

print("=== Running Refresh Guard Unit Tests ===")

local CatalogClient = require("storefront_net_catalog")
local SearchNet = require("storefront_search_net")

-- Test 1: CatalogClient.isRefreshing when no async fetch is active
check("CatalogClient.isRefreshing is false initially", CatalogClient.isRefreshing() == false)

-- Test 2: CatalogClient.isRefreshing when _async_pid is set
CatalogClient._async_pid = 9999
check("CatalogClient.isRefreshing is true when _async_pid is set", CatalogClient.isRefreshing() == true)

-- Test 3: Storefront.isRefreshing integration
local mock_sf = { is_refreshing = false }
SearchNet:init(mock_sf)

check("Storefront.isRefreshing returns true when CatalogClient is refreshing", mock_sf:isRefreshing() == true)

CatalogClient._async_pid = nil
check("Storefront.isRefreshing returns false when neither is refreshing", mock_sf:isRefreshing() == false)

mock_sf.is_refreshing = true
check("Storefront.isRefreshing returns true when sf.is_refreshing is true", mock_sf:isRefreshing() == true)

-- Test 4: Storefront.refreshCache early guard
shown_toasts = {}
local callback_called = false
local callback_ok = nil

mock_sf:refreshCache("plugin", function(ok, err)
    callback_called = true
    callback_ok = ok
end)

check("refreshCache returns early when isRefreshing is true", callback_called == true and callback_ok == false)
check("Friendly toast displayed instead of instant progress/error churn", #shown_toasts == 1 and shown_toasts[1]:find("already in progress", 1, true) ~= nil)

print("=== Refresh Guard Unit Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
