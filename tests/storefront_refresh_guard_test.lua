-- storefront_refresh_guard_test.lua
-- Unit tests for Refresh Safeguarding & In-Flight Background Refresh Detection

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

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
    unschedule = function() end,
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

-- Test 5: CatalogClient.cancelAsyncFetch terminates subprocess before reading/closing pipe FD
do
    local cleanup_events = {}
    local mock_ffiutil = {
        terminateSubProcess = function(pid)
            table.insert(cleanup_events, "terminate:" .. tostring(pid))
            return true
        end,
        isSubProcessDone = function(pid, wait)
            table.insert(cleanup_events, "done:" .. tostring(pid) .. ":" .. tostring(wait))
            return true
        end,
        readAllFromFD = function(fd)
            table.insert(cleanup_events, "readAll:" .. tostring(fd))
            return ""
        end,
    }

    local orig_ffi = package.loaded["ffi/util"]
    package.loaded["ffi/util"] = mock_ffiutil
    package.loaded["ffiutil"] = mock_ffiutil

    CatalogClient._async_pid = 12345
    CatalogClient._poll_fd = 54321
    local poll_unscheduled = false
    CatalogClient._poll_func = function() end

    local orig_unschedule = package.loaded["ui/uimanager"].unschedule
    package.loaded["ui/uimanager"].unschedule = function(self, fn)
        poll_unscheduled = true
    end

    CatalogClient.cancelAsyncFetch()

    check("cancelAsyncFetch unscheduled poll func", poll_unscheduled == true)
    check("cancelAsyncFetch cleared _async_pid", CatalogClient._async_pid == nil)
    check("cancelAsyncFetch cleared _poll_fd", CatalogClient._poll_fd == nil)
    check("cancelAsyncFetch cleared _poll_func", CatalogClient._poll_func == nil)
    check("cancelAsyncFetch called terminateSubProcess FIRST", cleanup_events[1] == "terminate:12345")
    check("cancelAsyncFetch called isSubProcessDone SECOND", cleanup_events[2] == "done:12345:true")
    check("cancelAsyncFetch called readAllFromFD LAST", cleanup_events[3] == "readAll:54321")

    package.loaded["ui/uimanager"].unschedule = orig_unschedule
    package.loaded["ffi/util"] = orig_ffi
    package.loaded["ffiutil"] = orig_ffi
end

-- Test 6: Verify requestWithRedirects calls socketutil:set_timeout before sink_fn
do
    local call_order = {}
    local mock_socketutil = {
        FILE_BLOCK_TIMEOUT = 15,
        FILE_TOTAL_TIMEOUT = 30,
        total_timeout = -1,
        set_timeout = function(self, b, t)
            self.total_timeout = t
            table.insert(call_order, "set_timeout:" .. tostring(t))
        end,
        reset_timeout = function(self)
            self.total_timeout = -1
            table.insert(call_order, "reset_timeout")
        end,
        file_sink = function(handle)
            return function(chunk) return 1 end
        end,
        SINK_TIMEOUT_CODE = "sink timeout",
    }
    package.loaded["socketutil"] = mock_socketutil

    -- Test requestWithRedirects by calling fetchCatalogToFile with mock http
    local orig_http = package.loaded["socket.http"]
    package.loaded["socket.http"] = {
        request = function(params)
            table.insert(call_order, "http_request")
            return 1, 200, { etag = "test_etag" }
        end
    }

    local sink_called_with_total_timeout = nil
    local orig_fetch = CatalogClient.fetchCatalogToFile
    -- Test directly via requestWithRedirects by requiring clean or testing internal flow
    local ok_res, code_res = CatalogClient.fetchCatalogToFile("https://example.com/test.json", "/tmp/nonexistent_test.json")

    check("socketutil:set_timeout called before request and reset after", #call_order >= 2 and call_order[1]:find("^set_timeout") ~= nil)

    package.loaded["socket.http"] = orig_http
    os.remove("/tmp/nonexistent_test.json")
end

-- Test 7: Storefront:onSuspend deduplication and onResume state reset
do
    local MainStorefront = {
        _is_suspended = nil,
    }
    local ok_main, SF = pcall(require, "main")
    if ok_main and SF then
        MainStorefront = SF
    end

    MainStorefront._is_suspended = nil
    MainStorefront:onSuspend()
    check("onSuspend marks _is_suspended as true", MainStorefront._is_suspended == true)

    -- Second onSuspend call in same sleep cycle returns early
    MainStorefront:onSuspend()
    check("onSuspend maintains _is_suspended as true on duplicate call", MainStorefront._is_suspended == true)

    MainStorefront:onResume()
    check("onResume resets _is_suspended to false", MainStorefront._is_suspended == false)

    -- Duplicate onResume is safe
    MainStorefront:onResume()
    check("duplicate onResume keeps _is_suspended as false", MainStorefront._is_suspended == false)

    -- onCloseWidget cleans up without leaving _is_suspended true
    MainStorefront:onCloseWidget()
    check("onCloseWidget does not mark _is_suspended as true", MainStorefront._is_suspended ~= true)
end

print("=== Refresh Guard Unit Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
