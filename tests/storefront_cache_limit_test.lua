-- Unit tests for storefront_cache_limit.lua

local spec_helper = require("tests/spec_helper")

local describe = _G.describe
local it = _G.it
local setup = _G.setup
local teardown = _G.teardown
local luassert = {}
if type(_G.assert) == "table" then
    luassert = _G.assert
else
    setmetatable(luassert, {
        __call = function(_, cond, msg)
            return _G.assert(cond, msg)
        end
    })
    luassert.equals = function(expected, actual)
        if expected ~= actual then
            error(string.format("Expected %s, got %s", tostring(expected), tostring(actual)), 2)
        end
    end
    luassert.is_true = function(val)
        if not val then error("Expected true, got " .. tostring(val), 2) end
    end
    luassert.is_false = function(val)
        if val then error("Expected false, got " .. tostring(val), 2) end
    end
    luassert.is_nil = function(val)
        if val ~= nil then error("Expected nil, got " .. tostring(val), 2) end
    end
    luassert.is_not_nil = function(val)
        if val == nil then error("Expected not nil, got nil", 2) end
    end
    luassert.is_table = function(val)
        if type(val) ~= "table" then error("Expected table, got " .. type(val), 2) end
    end
    luassert.is_number = function(val)
        if type(val) ~= "number" then error("Expected number, got " .. type(val), 2) end
    end
end
local assert = luassert

if not describe then
    local passed = 0
    describe = function(name, fn)
        print("=== Running " .. name .. " Test Suite ===")
        fn()
        print("=== " .. name .. " Tests Complete: 0 Failures ===")
    end
    it = function(desc, fn)
        fn()
        passed = passed + 1
        print("PASS\t" .. desc)
    end
    setup = function(fn) fn() end
    teardown = function(fn) fn() end
end

describe("storefront_cache_limit", function()
    local StorefrontCacheLimit
    local StorefrontSettings

    setup(function()
        spec_helper.setup()
        package.loaded["storefront_settings"] = nil
        StorefrontSettings = require("storefront_settings")
        package.loaded["storefront_cache_limit"] = nil
        StorefrontCacheLimit = require("storefront_cache_limit")
    end)

    teardown(function()
        spec_helper.teardown()
    end)

    it("has expected default limit and presets", function()
        assert.equals(100, StorefrontCacheLimit.DEFAULT_MB)
        assert.equals(30, StorefrontCacheLimit.MAX_AGE_DAYS)
        assert.is_table(StorefrontCacheLimit.PRESETS_MB)
        assert.equals(6, #StorefrontCacheLimit.PRESETS_MB)
        assert.equals(25, StorefrontCacheLimit.PRESETS_MB[1])
        assert.equals(50, StorefrontCacheLimit.PRESETS_MB[2])
        assert.equals(100, StorefrontCacheLimit.PRESETS_MB[3])
        assert.equals(250, StorefrontCacheLimit.PRESETS_MB[4])
        assert.equals(500, StorefrontCacheLimit.PRESETS_MB[5])
        assert.equals(0, StorefrontCacheLimit.PRESETS_MB[6])
    end)

    it("cycles through presets correctly with nextPreset", function()
        assert.equals(50, StorefrontCacheLimit.nextPreset(25))
        assert.equals(100, StorefrontCacheLimit.nextPreset(50))
        assert.equals(250, StorefrontCacheLimit.nextPreset(100))
        assert.equals(500, StorefrontCacheLimit.nextPreset(250))
        assert.equals(0, StorefrontCacheLimit.nextPreset(500))
        assert.equals(25, StorefrontCacheLimit.nextPreset(0))
        assert.equals(100, StorefrontCacheLimit.nextPreset(999))
    end)

    it("reads and falls back to default limit", function()
        StorefrontSettings:delSetting("cache_limit_mb")
        assert.equals(100, StorefrontCacheLimit.getLimitMB())

        StorefrontSettings:saveSetting("cache_limit_mb", "invalid")
        assert.equals(100, StorefrontCacheLimit.getLimitMB())

        StorefrontSettings:saveSetting("cache_limit_mb", -50)
        assert.equals(100, StorefrontCacheLimit.getLimitMB())

        StorefrontSettings:saveSetting("cache_limit_mb", 250)
        assert.equals(250, StorefrontCacheLimit.getLimitMB())

        StorefrontSettings:saveSetting("cache_limit_mb", 0)
        assert.equals(0, StorefrontCacheLimit.getLimitMB())
    end)

    it("sets limit and triggers immediate enforcement", function()
        StorefrontCacheLimit.setLimitMB(50)
        assert.equals(50, StorefrontCacheLimit.getLimitMB())
        assert.equals(50, StorefrontSettings:readSetting("cache_limit_mb"))
    end)

    it("identifies active screensaver thumbnails as protected", function()
        local mock_screensaver_mgr = {
            getActiveScreensaverIdentifiers = function()
                return {
                    ["alice-in-wonderland.png"] = true,
                    ["mountain_view"] = true,
                }
            end
        }
        package.loaded["storefront_screensaver_mgr"] = mock_screensaver_mgr

        local protected = StorefrontCacheLimit.getProtectedIdentifiers()
        assert.is_true(protected["alice-in-wonderland.png"])
        assert.is_true(protected["alice-in-wonderland"])
        assert.is_true(protected["mountain_view"])
        assert.is_nil(protected["unrelated_image.png"])
    end)

    it("collects files and respects protected items in storefront_thumbs", function()
        -- Create isolated mock VFS
        local vfs_files = {
            ["/cache/storefront_thumbs/active_pic.jpg"] = { mode = "file", size = 15000, mtime = 1000 },
            ["/cache/storefront_thumbs/old_unused.jpg"] = { mode = "file", size = 25000, mtime = 500 },
        }
        local vfs_dirs = {
            ["/cache/storefront_thumbs"] = { "active_pic.jpg", "old_unused.jpg" }
        }

        local mock_lfs = {
            attributes = function(path, req)
                local f = vfs_files[path]
                if f then
                    if req == "mode" then return f.mode
                    elseif req == "size" then return f.size
                    elseif req == "modification" then return f.mtime
                    end
                    return { mode = f.mode, size = f.size, modification = f.mtime }
                end
                if vfs_dirs[path] then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries = vfs_dirs[path] or {}
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        local protected_keys = {
            ["active_pic.jpg"] = true,
            ["active_pic"] = true,
        }

        local files = CacheLimit.collectFiles({ "/cache/storefront_thumbs" }, protected_keys)
        assert.equals(2, #files)

        local found_protected = false
        local found_unprotected = false
        for _, f in ipairs(files) do
            if f.path:find("active_pic.jpg") then
                assert.is_true(f.protected)
                found_protected = true
            elseif f.path:find("old_unused.jpg") then
                assert.is_false(f.protected)
                found_unprotected = true
            end
        end
        assert.is_true(found_protected)
        assert.is_true(found_unprotected)
    end)

    it("evicts oldest non-protected files when size exceeds limit", function()
        local deleted = {}
        local orig_os_remove = os.remove
        os.remove = function(path)
            table.insert(deleted, path)
            return true
        end

        local now = os.time()
        local vfs_files = {
            ["/cache/sf/f1_oldest.dat"] = { mode = "file", size = 100 * 1024, mtime = now - 300 },
            ["/cache/sf/f2_middle.dat"] = { mode = "file", size = 100 * 1024, mtime = now - 200 },
            ["/cache/sf/f3_newest.dat"] = { mode = "file", size = 100 * 1024, mtime = now - 100 },
        }
        local vfs_dirs = {
            ["/cache/sf"] = { "f1_oldest.dat", "f2_middle.dat", "f3_newest.dat" }
        }

        local mock_lfs = {
            attributes = function(path, req)
                local f = vfs_files[path]
                if f then
                    if req == "mode" then return f.mode
                    elseif req == "size" then return f.size
                    elseif req == "modification" then return f.mtime
                    end
                    return { mode = f.mode, size = f.size, modification = f.mtime }
                end
                if vfs_dirs[path] then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries = vfs_dirs[path] or {}
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.getCacheRoots = function() return { "/cache/sf" } end
        CacheLimit.getProtectedIdentifiers = function() return {} end

        -- Total is 300 KB. We limit to ~0.2 MB (approx 204.8 KB).
        -- f1_oldest.dat should be evicted, remaining 200 KB <= 204.8 KB.
        CacheLimit.resetThrottle()
        local res = CacheLimit.enforce(true, 0.2, 365)
        assert.is_not_nil(res)
        assert.equals(1, res.removed)
        assert.equals(1, #deleted)
        assert.equals("/cache/sf/f1_oldest.dat", deleted[1])

        os.remove = orig_os_remove
    end)

    it("never evicts protected active screensavers even when over limit", function()
        local deleted = {}
        local orig_os_remove = os.remove
        os.remove = function(path)
            table.insert(deleted, path)
            return true
        end

        local now = os.time()
        local vfs_files = {
            ["/cache/storefront_thumbs/active_saver.jpg"] = { mode = "file", size = 100 * 1024, mtime = now - 500 },
            ["/cache/storefront_thumbs/other_saver.jpg"]  = { mode = "file", size = 100 * 1024, mtime = now - 300 },
        }
        local vfs_dirs = {
            ["/cache/storefront_thumbs"] = { "active_saver.jpg", "other_saver.jpg" }
        }

        local mock_lfs = {
            attributes = function(path, req)
                local f = vfs_files[path]
                if f then
                    if req == "mode" then return f.mode
                    elseif req == "size" then return f.size
                    elseif req == "modification" then return f.mtime
                    end
                    return { mode = f.mode, size = f.size, modification = f.mtime }
                end
                if vfs_dirs[path] then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries = vfs_dirs[path] or {}
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.getCacheRoots = function() return { "/cache/storefront_thumbs" } end
        CacheLimit.getProtectedIdentifiers = function()
            return { ["active_saver.jpg"] = true, ["active_saver"] = true }
        end

        -- Total is 200 KB. We limit to ~0.05 MB (approx 51.2 KB).
        -- active_saver.jpg is oldest (mtime 50), but protected.
        -- other_saver.jpg is evicted. active_saver is NEVER evicted.
        CacheLimit.resetThrottle()
        local res = CacheLimit.enforce(true, 0.05, 365)
        assert.is_not_nil(res)
        assert.equals(1, res.removed)
        assert.equals(1, #deleted)
        assert.equals("/cache/storefront_thumbs/other_saver.jpg", deleted[1])

        os.remove = orig_os_remove
    end)

    it("respects unlimited setting (0 MB) without size eviction", function()
        local deleted = {}
        local orig_os_remove = os.remove
        os.remove = function(path)
            table.insert(deleted, path)
            return true
        end

        local now = os.time()
        local vfs_files = {
            ["/cache/sf/f1.dat"] = { mode = "file", size = 500 * 1024, mtime = now - 500 },
        }
        local vfs_dirs = {
            ["/cache/sf"] = { "f1.dat" }
        }

        local mock_lfs = {
            attributes = function(path, req)
                local f = vfs_files[path]
                if f then
                    if req == "mode" then return f.mode
                    elseif req == "size" then return f.size
                    elseif req == "modification" then return f.mtime
                    end
                    return { mode = f.mode, size = f.size, modification = f.mtime }
                end
                if vfs_dirs[path] then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries = vfs_dirs[path] or {}
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.getCacheRoots = function() return { "/cache/sf" } end
        CacheLimit.resetThrottle()
        local res = CacheLimit.enforce(true, 0, 365) -- 0 MB == Unlimited
        assert.equals(0, res.removed)
        assert.equals(0, #deleted)

        os.remove = orig_os_remove
    end)

    it("enforces 30-day age expiry even when total size is under limit", function()
        local deleted = {}
        local orig_os_remove = os.remove
        os.remove = function(path)
            table.insert(deleted, path)
            return true
        end

        local now = os.time()
        local vfs_files = {
            ["/cache/sf/expired.dat"] = { mode = "file", size = 100, mtime = now - (35 * 86400) },
            ["/cache/sf/fresh.dat"]   = { mode = "file", size = 100, mtime = now - (5 * 86400) },
        }
        local vfs_dirs = {
            ["/cache/sf"] = { "expired.dat", "fresh.dat" }
        }

        local mock_lfs = {
            attributes = function(path, req)
                local f = vfs_files[path]
                if f then
                    if req == "mode" then return f.mode
                    elseif req == "size" then return f.size
                    elseif req == "modification" then return f.mtime
                    end
                    return { mode = f.mode, size = f.size, modification = f.mtime }
                end
                if vfs_dirs[path] then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries = vfs_dirs[path] or {}
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.getCacheRoots = function() return { "/cache/sf" } end
        CacheLimit.resetThrottle()
        local res = CacheLimit.enforce(true, 500, 30) -- 500 MB limit, 30 days expiry
        assert.equals(1, res.removed)
        assert.equals(1, #deleted)
        assert.equals("/cache/sf/expired.dat", deleted[1])

        os.remove = orig_os_remove
    end)

    it("throttles enforcement to avoid repetitive disk I/O", function()
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.getCacheRoots = function() return {} end
        CacheLimit.resetThrottle()

        local res1 = CacheLimit.enforce(false)
        assert.is_nil(res1.throttled)

        -- Immediate second call without force should be throttled
        local res2 = CacheLimit.enforce(false)
        assert.is_true(res2.throttled)

        -- Call with force should bypass throttle
        local res3 = CacheLimit.enforce(true)
        assert.is_nil(res3.throttled)
    end)

    it("prunes empty subdirectories after eviction", function()
        local removed_dirs = {}
        local mock_lfs = {
            attributes = function(path, req)
                if path == "/cache/sf" or path == "/cache/sf/empty_sub" then
                    if req == "mode" then return "directory" end
                    return { mode = "directory" }
                end
                return nil
            end,
            dir = function(path)
                local entries
                if path == "/cache/sf" then
                    entries = { "empty_sub" }
                elseif path == "/cache/sf/empty_sub" then
                    entries = {}
                else
                    entries = {}
                end
                local i = 0
                return function()
                    i = i + 1
                    return entries[i]
                end
            end,
            rmdir = function(path)
                table.insert(removed_dirs, path)
                return true
            end
        }

        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs
        package.loaded["storefront_cache_limit"] = nil
        local CacheLimit = require("storefront_cache_limit")

        CacheLimit.pruneEmptyDirs({ "/cache/sf" })
        assert.equals(1, #removed_dirs)
        assert.equals("/cache/sf/empty_sub", removed_dirs[1])
    end)
end)
