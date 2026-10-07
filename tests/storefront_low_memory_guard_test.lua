-- storefront_low_memory_guard_test.lua
-- Unit tests for Low-Memory Guard & Subprocess Optimization

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

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

package.loaded["storefront_toast"] = {
    show = function(text, timeout, opts)
        return { close = function() end }
    end
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    forceRePaint = function() end,
    scheduleIn = function(delay, fn) end,
}
package.loaded["storefront_net_github"] = {
    isDirectApiEnabled = function() return false end,
}

print("=== Running Low-Memory Guard & Catalog Staging Unit Tests ===")

local StorefrontUtils = require("storefront_utils")
local CatalogClient = require("storefront_net_catalog")
local json = require("json")

-- ----------------------------------------------------
-- Test 1: getMemoryInfo with modern Linux meminfo (MemAvailable present)
-- ----------------------------------------------------
do
    local tmp_meminfo = "/tmp/test_meminfo_modern.txt"
    local f = io.open(tmp_meminfo, "w")
    if f then
        f:write([[
MemTotal:         512000 kB
MemFree:           10240 kB
MemAvailable:      45000 kB
Buffers:            4096 kB
Cached:            30000 kB
]])
        f:close()

        local mem = StorefrontUtils.getMemoryInfo(tmp_meminfo)
        check("getMemoryInfo parses MemTotal correctly", mem and mem.total_kb == 512000)
        check("getMemoryInfo uses MemAvailable when present", mem and mem.available_kb == 45000)
        check("getMemoryInfo parses MemFree correctly", mem and mem.free_kb == 10240)

        local is_low, avail = StorefrontUtils.isLowMemory(30 * 1024, tmp_meminfo)
        check("isLowMemory is false when available > 30MB (45MB available)", is_low == false and avail == 45000)

        os.remove(tmp_meminfo)
    else
        print("SKIP\tCould not write temporary meminfo file")
    end
end

-- ----------------------------------------------------
-- Test 2: getMemoryInfo with legacy Kindle Linux 3.0 kernel (MemAvailable absent)
-- ----------------------------------------------------
do
    local tmp_meminfo = "/tmp/test_meminfo_kindle_pw2.txt"
    local f = io.open(tmp_meminfo, "w")
    if f then
        f:write([[
MemTotal:         247852 kB
MemFree:            3584 kB
Buffers:            1024 kB
Cached:            12288 kB
SwapTotal:             0 kB
SwapFree:              0 kB
]])
        f:close()

        local mem = StorefrontUtils.getMemoryInfo(tmp_meminfo)
        check("getMemoryInfo parses MemTotal on Kindle PW2 (256MB)", mem and mem.total_kb == 247852)
        -- Fallback: MemFree (3584) + Buffers (1024) + Cached (12288) = 16896 kB (~16.5 MB)
        check("getMemoryInfo calculates fallback available memory accurately", mem and mem.available_kb == 16896)

        local is_low, avail, total = StorefrontUtils.isLowMemory(30 * 1024, tmp_meminfo)
        check("isLowMemory is true on Kindle PW2 with 16.5MB free (<30MB threshold)", is_low == true and avail == 16896 and total == 247852)

        os.remove(tmp_meminfo)
    else
        print("SKIP\tCould not write temporary meminfo file")
    end
end

-- ----------------------------------------------------
-- Test 3: getMemoryInfo when /proc/meminfo does not exist (non-Linux fallback)
-- ----------------------------------------------------
do
    local mem = StorefrontUtils.getMemoryInfo("/nonexistent_path_to_meminfo")
    check("getMemoryInfo returns nil gracefully on nonexistent path", mem == nil)

    local is_low = StorefrontUtils.isLowMemory(30 * 1024, "/nonexistent_path_to_meminfo")
    check("isLowMemory returns false gracefully when meminfo unavailable", is_low == false)
end

-- ----------------------------------------------------
-- Test 4: fetchAndUpdateCacheAsync background guard on critically low memory
-- ----------------------------------------------------
do
    -- Temporarily point /proc/meminfo or mock isLowMemory
    local orig_isLowMemory = StorefrontUtils.isLowMemory
    StorefrontUtils.isLowMemory = function(threshold)
        return true, 12000, 247852 -- Simulating 12MB available
    end

    local called = false
    local result_ok = nil
    local result_msg = nil
    CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, msg)
        called = true
        result_ok = ok
        result_msg = msg
    end, true) -- is_background = true

    check("fetchAndUpdateCacheAsync aborts early when is_background=true and memory is low", called == true and result_ok == false and result_msg == "low_memory")

    -- Foreground / manual refresh ignores the low-memory check and proceeds
    local orig_async_pid = CatalogClient._async_pid
    CatalogClient._async_pid = 9999 -- Mock as active to verify it didn't abort with low_memory
    called = false
    CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, msg)
        called = true
        result_ok = ok
        result_msg = msg
    end, false) -- is_background = false
    check("fetchAndUpdateCacheAsync proceeds past memory check when is_background is false/omitted", called == true and result_msg == "already in progress")
    CatalogClient._async_pid = orig_async_pid

    StorefrontUtils.isLowMemory = orig_isLowMemory
end

-- ----------------------------------------------------
-- Test 5: processCatalogDataToStaging sequential memory staging and GC
-- ----------------------------------------------------
do
    local tmp_plugins = "/tmp/test_staging_plugins.json.tmp"
    local tmp_patches = "/tmp/test_staging_patches.json.tmp"
    local tmp_fonts = "/tmp/test_staging_fonts.json.tmp"

    local mock_catalog = {
        plugins = {
            { id = 101, name = "testplugin", full_name = "user/testplugin", stars = 10, version = "1.0.0" }
        },
        patches = {
            { id = 201, name = "testpatch", full_name = "user/testpatch", stars = 5, patch_files = { { filename = "patch1.lua", size = 100 } } }
        },
        fonts = {
            { id = 301, name = "testfont", font_family = "TestFont", font_file = "test.ttf", stars = 20 }
        }
    }

    local orig_getBundled = CatalogClient.getBundledCatalogPath
    CatalogClient.getBundledCatalogPath = function() return nil end

    local ok, err = CatalogClient.processCatalogDataToStaging(mock_catalog, tmp_plugins, tmp_patches, tmp_fonts)
    CatalogClient.getBundledCatalogPath = orig_getBundled
    check("processCatalogDataToStaging returns true", ok == true)

    -- Verify plugins file written correctly
    local fp = io.open(tmp_plugins, "r")
    check("staging plugins file exists", fp ~= nil)
    if fp then
        local p_data = json.decode(fp:read("*a"))
        fp:close()
        check("staging plugins contains 1 repo", p_data and p_data.repos and #p_data.repos == 1)
        check("staging plugin repo name matches", p_data and p_data.repos[1].name == "testplugin")
        os.remove(tmp_plugins)
    end

    -- Verify patches file written correctly
    local fpt = io.open(tmp_patches, "r")
    check("staging patches file exists", fpt ~= nil)
    if fpt then
        local pt_data = json.decode(fpt:read("*a"))
        fpt:close()
        check("staging patches contains 1 repo", pt_data and pt_data.repos and #pt_data.repos == 1)
        check("staging patch files preserved", pt_data and pt_data.repos[1].patch_files and #pt_data.repos[1].patch_files == 1)
        os.remove(tmp_patches)
    end

    -- Verify fonts file written correctly
    local ff = io.open(tmp_fonts, "r")
    check("staging fonts file exists", ff ~= nil)
    if ff then
        local f_data = json.decode(ff:read("*a"))
        ff:close()
        check("staging fonts contains 1 repo", f_data and f_data.repos and #f_data.repos == 1)
        check("staging font family matches", f_data and f_data.repos[1].font_family == "TestFont")
        os.remove(tmp_fonts)
    end
end

-- ----------------------------------------------------
-- Test 6: ReaderBackdrop ETag storage and clear
-- ----------------------------------------------------
do
    CatalogClient.clearStoredReaderBackdropEtag()
    check("getStoredReaderBackdropEtag is nil initially", CatalogClient.getStoredReaderBackdropEtag() == nil)

    CatalogClient.setStoredReaderBackdropEtag("rb_etag_12345")
    check("getStoredReaderBackdropEtag returns saved etag", CatalogClient.getStoredReaderBackdropEtag() == "rb_etag_12345")

    CatalogClient.clearStoredScreensaverEtag()
    check("clearStoredScreensaverEtag also clears readerbackdrop etag", CatalogClient.getStoredReaderBackdropEtag() == nil)

    CatalogClient.setStoredReaderBackdropEtag("rb_etag_abc")
    CatalogClient.clearStoredReaderBackdropEtag()
    check("clearStoredReaderBackdropEtag clears readerbackdrop etag", CatalogClient.getStoredReaderBackdropEtag() == nil)
end

-- ----------------------------------------------------
-- Test 7: Shmem accounting and isLowMemoryDevice on legacy Kindle kernels
-- ----------------------------------------------------
do
    local tmp_meminfo = "/tmp/test_meminfo_kindle_shmem.txt"
    local f = io.open(tmp_meminfo, "w")
    if f then
        f:write([[
MemTotal:         247852 kB
MemFree:            3584 kB
Buffers:            1024 kB
Cached:            20480 kB
Shmem:             10240 kB
SwapTotal:             0 kB
SwapFree:              0 kB
]])
        f:close()

        local mem = StorefrontUtils.getMemoryInfo(tmp_meminfo)
        check("getMemoryInfo parses Shmem on Kindle", mem and mem.shmem_kb == 10240)
        -- Fallback: MemFree (3584) + Buffers (1024) + clean Cached (20480 - 10240 = 10240) = 14848 kB
        check("getMemoryInfo subtracts Shmem from clean Cached", mem and mem.available_kb == 14848)

        local is_low_dev = StorefrontUtils.isLowMemoryDevice(tmp_meminfo)
        check("isLowMemoryDevice is true for 256MB device", is_low_dev == true)

        -- Default threshold should be elevated to 45MB on low-memory device
        local is_low, avail = StorefrontUtils.isLowMemory(nil, tmp_meminfo)
        check("isLowMemory defaults to elevated 45MB threshold on low-memory device", is_low == true and avail == 14848)

        os.remove(tmp_meminfo)
    else
        print("SKIP\tCould not write temporary meminfo file")
    end
end

-- ----------------------------------------------------
-- Test 8: StorefrontScreensavers.getCachedCount zero-JSON decode resolution
-- ----------------------------------------------------
do
    local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
    if ok_ss and StorefrontScreensavers then
        -- Mock StorefrontSettings
        package.loaded["storefront_settings"] = {
            readSetting = function(self, key)
                if key == "cached_screensaver_count" then return 3170 end
                return nil
            end,
            saveSetting = function(self, key, val) end,
            flush = function() end,
        }

        local count = StorefrontScreensavers.getCachedCount()
        check("getCachedCount resolves stored count without parsing JSON", count == 3170)
    else
        print("SKIP\tstorefront_screensavers_ui not available")
    end
end

print("=== Low-Memory Guard & Catalog Staging Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
