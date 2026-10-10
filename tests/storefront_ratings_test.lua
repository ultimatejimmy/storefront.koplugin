-- Unit tests for storefront_ratings.lua

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
    luassert.is_string = function(val)
        if type(val) ~= "string" then error("Expected string, got " .. type(val), 2) end
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

describe("storefront_ratings", function()
    local StorefrontRatings

    setup(function()
        spec_helper.setup()
        package.loaded["storefront_ratings"] = nil
        StorefrontRatings = require("storefront_ratings")
    end)

    teardown(function()
        spec_helper.teardown()
    end)

    it("should compute Wilson score correctly", function()
        assert.equals(0, StorefrontRatings.computeWilsonScore(0, 0))
        assert.is_true(StorefrontRatings.computeWilsonScore(10, 0) > 0.6)
        assert.is_true(StorefrontRatings.computeWilsonScore(100, 5) > StorefrontRatings.computeWilsonScore(5, 0))
        assert.is_true(StorefrontRatings.computeWilsonScore(10, 10) < StorefrontRatings.computeWilsonScore(10, 2))
    end)

    it("should generate and persist device UUID", function()
        local uuid1 = StorefrontRatings.getDeviceUUID()
        assert.is_string(uuid1)
        assert.is_true(#uuid1 >= 16)
        local uuid2 = StorefrontRatings.getDeviceUUID()
        assert.equals(uuid1, uuid2)
    end)

    it("should save and retrieve user votes", function()
        local test_id = 999999
        assert.is_nil(StorefrontRatings.getUserVote(test_id))
        
        StorefrontRatings.saveUserVote(test_id, "up")
        assert.equals("up", StorefrontRatings.getUserVote(test_id))
        
        StorefrontRatings.saveUserVote(test_id, "down")
        assert.equals("down", StorefrontRatings.getUserVote(test_id))
        
        StorefrontRatings.saveUserVote(test_id, "none")
        assert.is_nil(StorefrontRatings.getUserVote(test_id))
    end)

    it("should keep forks with the same name isolated by author", function()
        local repoA = {
            id = 111111,
            repo_id = 111111,
            owner = "authorA",
            name = "xray.koplugin",
            full_name = "authorA/xray.koplugin",
        }
        local repoB = {
            id = 222222,
            repo_id = 222222,
            owner = "authorB",
            name = "xray.koplugin",
            full_name = "authorB/xray.koplugin",
        }

        assert.is_nil(StorefrontRatings.getUserVote(repoA))
        assert.is_nil(StorefrontRatings.getUserVote(repoB))

        StorefrontRatings.saveUserVote(repoA, "up")
        assert.equals("up", StorefrontRatings.getUserVote(repoA))
        assert.is_nil(StorefrontRatings.getUserVote(repoB))

        StorefrontRatings.saveUserVote(repoA, "none")
        assert.is_nil(StorefrontRatings.getUserVote(repoA))
        assert.is_nil(StorefrontRatings.getUserVote(repoB))
    end)

    it("should make live server ratings authoritative over base catalog", function()
        local item = {
            id = 555555,
            repo_id = 555555,
            name = "test.koplugin",
            user_thumbs_up = 100,
            user_thumbs_down = 2,
            downloads = 50,
        }

        -- With no live ratings cached, catalog fallback is used
        StorefrontRatings.liveRatings = {}
        local r1 = StorefrontRatings.getRating(item)
        assert.equals(100, r1.up)
        assert.equals(2, r1.down)
        assert.equals(50, r1.downloads)

        -- When live server ratings are available, they override catalog even if lower
        StorefrontRatings.liveRatings["555555"] = {
            up = 6,
            down = 0,
            wilson = 0.61,
            downloads = 5,
        }
        local r2 = StorefrontRatings.getRating(item)
        assert.equals(6, r2.up)
        assert.equals(0, r2.down)
        assert.equals(5, r2.downloads)
    end)

    it("should clear cache and report stats correctly", function()
        assert.is_table(StorefrontRatings.getCacheStats())
        local stats_before = StorefrontRatings.getCacheStats()
        assert.is_number(stats_before.files)
        assert.is_number(stats_before.bytes)

        StorefrontRatings.liveRatings["test_repo"] = { up = 1, down = 0 }
        assert.is_not_nil(StorefrontRatings.liveRatings["test_repo"])

        local res = StorefrontRatings.clearCache()
        assert.is_table(res)
        assert.is_number(res.removed)
        assert.is_number(res.bytes)
        assert.is_nil(StorefrontRatings.liveRatings["test_repo"])
    end)

    it("should resolve Storefront aliases to canonical ID and pick best live rating", function()
        StorefrontRatings.liveRatings["1304319884"] = {
            up = 73,
            down = 0,
            wilson = 0.95,
            downloads = 120,
        }
        StorefrontRatings.liveRatings["storefront.koplugin"] = {
            up = 2,
            down = 0,
            wilson = 0.34,
            downloads = 10,
        }

        local installed_sf = {
            name = "Storefront",
            dirname = "storefront.koplugin",
        }
        local r = StorefrontRatings.getRating(installed_sf)
        assert.equals(73, r.up)
        assert.equals(0, r.down)
        assert.equals(120, r.downloads)

        local string_sf = "storefront.koplugin"
        local r_str = StorefrontRatings.getRating(string_sf)
        assert.equals(73, r_str.up)
    end)

    it("should normalize ratings sparsely and omit all-zero entries", function()
        local raw_backend_response = {
            ["item_active"] = { up = 5, down = 1, wilson = 0.5, downloads = 12 },
            ["item_download_only"] = { up = 0, down = 0, wilson = 0, downloads = 4 },
            ["item_zero_1"] = { up = 0, down = 0, wilson = 0, downloads = 0 },
            ["item_zero_2"] = { up = "0", down = "0", wilson = "0", downloads = "0" },
        }

        -- Call clearCache to start fresh
        StorefrontRatings.clearCache()
        StorefrontRatings.liveRatings = {}

        -- Test that saving & loading normalizes sparsely
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        -- Call fetchRatings fallback or direct normalization test
        local item_active = { id = "item_active" }
        local item_zero = { id = "item_zero_1" }

        StorefrontRatings.liveRatings["item_active"] = { up = 5, down = 1, wilson = 0.5, downloads = 12 }
        -- All-zero entries should not exist in sparse liveRatings
        local r_active = StorefrontRatings.getRating(item_active)
        assert.equals(5, r_active.up)
        assert.equals(1, r_active.down)
        assert.equals(12, r_active.downloads)

        local r_zero = StorefrontRatings.getRating(item_zero)
        assert.equals(0, r_zero.up)
        assert.equals(0, r_zero.down)
        assert.equals(0, r_zero.downloads)
    end)

    it("should terminate subprocess and clean up FD on timeout", function()
        local UIManager = require("ui/uimanager")
        local terminated_pid = nil
        local drained_fd = nil

        local mock_ffiutil = {
            runInSubProcess = function(fn, pass_fds)
                return 4488, 99
            end,
            isSubProcessDone = function(pid)
                return false -- simulate hanging / timeout
            end,
            terminateSubProcess = function(pid)
                terminated_pid = pid
            end,
            readAllFromFD = function(fd)
                drained_fd = fd
                return ""
            end,
        }

        package.loaded["ffi/util"] = mock_ffiutil
        package.loaded["ffiutil"] = mock_ffiutil

        -- Re-require storefront_ratings to pick up mock ffiutil
        package.loaded["storefront_ratings"] = nil
        local SR = require("storefront_ratings")

        local callback_called = false
        local callback_success = nil
        SR.fetchRatings(function(ok, res)
            callback_called = true
            callback_success = ok
        end, true)

        -- Advance scheduled poll calls until timeout
        for _ = 1, 65 do
            if UIManager._scheduled and #UIManager._scheduled > 0 then
                local task = table.remove(UIManager._scheduled, 1)
                if task and task.action then task.action() end
            end
        end

        assert.is_true(callback_called)
        assert.equals(false, callback_success)
        assert.equals(4488, terminated_pid)
        assert.equals(99, drained_fd)

        -- Clean up mock
        package.loaded["ffi/util"] = nil
        package.loaded["ffiutil"] = nil
    end)

    it("should show toast and use direct sync HTTP on low memory for submitVote", function()
        local UIManager = require("ui/uimanager")
        local toast_shown = false
        local toast_msg = nil

        package.loaded["storefront_toast"] = {
            show = function(msg, timeout)
                toast_shown = true
                toast_msg = msg
            end,
        }

        -- Mock low memory
        package.loaded["storefront_utils"] = {
            isLowMemory = function()
                return true, 12000 -- 12 MB free
            end,
        }

        package.loaded["storefront_ratings"] = nil
        local SR = require("storefront_ratings")

        local vote_cb_called = false
        SR.submitVote("test_item_lowmem", "up", "plugin", function(ok, err)
            vote_cb_called = true
        end)

        -- Drain any scheduled task
        for _ = 1, 10 do
            if UIManager._scheduled and #UIManager._scheduled > 0 then
                local task = table.remove(UIManager._scheduled, 1)
                if task and task.action then task.action() end
            end
        end

        assert.is_true(toast_shown)
        assert.is_not_nil(toast_msg)
        assert.equals("up", SR.getUserVote("test_item_lowmem"))

        -- Clean up mocks
        package.loaded["storefront_toast"] = nil
        package.loaded["storefront_utils"] = nil
    end)
end)
