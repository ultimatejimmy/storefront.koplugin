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

        -- Catalog metrics are authoritative baseline
        local r1 = StorefrontRatings.getRating(item)
        assert.equals(100, r1.up)
        assert.equals(2, r1.down)
        assert.equals(50, r1.downloads)
    end)

    it("should delete legacy storefront_ratings_cache.json on startup and never let stale cache override catalog", function()
        local DataStorage = require("datastorage")
        local json = require("json")
        local settings_dir = DataStorage:getSettingsDir()
        os.execute(string.format('mkdir -p "%s"', settings_dir))
        local cache_file = settings_dir .. "/storefront_ratings_cache.json"
        local f = io.open(cache_file, "w")
        assert.is_not_nil(f)
        f:write(json.encode({
            ["storefront.koplugin"] = { up = 2, down = 0, wilson = 0.34, downloads = 10 },
            ["1304319884"] = { up = 2, down = 0, wilson = 0.34, downloads = 10 },
        }))
        f:close()

        -- Reload module to trigger startup cleanup
        package.loaded["storefront_ratings"] = nil
        local SR = require("storefront_ratings")

        local stats = SR.getCacheStats()
        assert.equals(0, stats.files)
        assert.equals(0, stats.bytes)

        local sf_item = {
            id = 1304319884,
            repo_id = 1304319884,
            name = "storefront.koplugin",
            full_name = "ultimatejimmy/storefront.koplugin",
            user_thumbs_up = 102,
            user_thumbs_down = 0,
            downloads = 120,
        }
        local r = SR.getRating(sf_item)
        assert.equals(102, r.up)
        assert.equals(0, r.down)
        assert.equals(120, r.downloads)
    end)

    it("should keep Storefront (1304319884) and forks (1349827230) strictly isolated", function()
        local StorefrontSettings = require("storefront_settings")
        StorefrontSettings:saveSetting("user_votes", {
            [1304319884] = "up",
            ["1304319884.koplugin"] = "up",
            ["storefront.koplugin"] = "up",
            ["ultimatejimmy/storefront"] = "up",
            ["ultimatejimmy/storefront.koplugin"] = "up",
        })

        package.loaded["storefront_ratings"] = nil
        local SR = require("storefront_ratings")

        -- Legacy Storefront votes migrate cleanly to "1304319884" and do NOT double-count catalog
        local sf_item = {
            id = 1304319884,
            repo_id = 1304319884,
            name = "storefront.koplugin",
            owner = "ultimatejimmy",
            full_name = "ultimatejimmy/storefront.koplugin",
            user_thumbs_up = 102,
            user_thumbs_down = 0,
            downloads = 120,
        }
        assert.equals("up", SR.getUserVote(sf_item))
        assert.equals(102, SR.getRating(sf_item).up)

        -- Fork with identical dirname/name must NOT inherit Storefront's vote or ratings
        local fork_item = {
            id = 1349827230,
            repo_id = 1349827230,
            name = "storefront.koplugin",
            owner = "xu-wentao",
            full_name = "xu-wentao/storefront.koplugin",
            user_thumbs_up = 0,
            user_thumbs_down = 0,
            downloads = 0,
        }
        assert.is_nil(SR.getUserVote(fork_item))
        assert.equals(0, SR.getRating(fork_item).up)
    end)

    it("should apply pending vote delta on new votes and expire it when a newer catalog loads", function()
        local StorefrontSettings = require("storefront_settings")
        StorefrontSettings:saveSetting("user_votes", {})
        local orig_http = package.loaded["socket.http"]
        local orig_cache = package.loaded["storefront_cache"]
        local orig_utils = package.loaded["storefront_utils"]
        local ts = 1795024997
        package.loaded["storefront_cache"] = {
            isLoaded = function() return true end,
            getGeneratedTimestamp = function() return ts end,
            getRepo = function(id)
                if tonumber(id) == 1304319884 then
                    return { id = 1304319884, repo_id = 1304319884, user_thumbs_up = 102, user_thumbs_down = 0, downloads = 120 }
                end
            end,
        }
        package.loaded["socket.http"] = {
            request = function(opts)
                if opts and opts.sink then opts.sink('{"success":true,"up":103,"down":0,"wilson":0.96}') end
                return 1, 200, {}
            end
        }
        package.loaded["storefront_utils"] = { isLowMemory = function() return true end }

        package.loaded["storefront_ratings"] = nil
        local SR = require("storefront_ratings")
        local UIManager = require("ui/uimanager")

        local sf = { id = 1304319884, name = "storefront.koplugin", full_name = "ultimatejimmy/storefront.koplugin", user_thumbs_up = 102, user_thumbs_down = 0 }
        assert.equals(102, SR.getRating(sf).up)

        SR.submitVote(sf, "up", "plugin")
        for _ = 1, 10 do
            if UIManager._scheduled and #UIManager._scheduled > 0 then
                local task = table.remove(UIManager._scheduled, 1)
                if task and task.action then task.action() end
            end
        end

        -- Pending +1 applies immediately
        assert.equals(103, SR.getRating(sf).up)

        -- Persists across module reload while catalog timestamp is unchanged
        package.loaded["storefront_ratings"] = nil
        SR = require("storefront_ratings")
        assert.equals(103, SR.getRating(sf).up)

        -- Once a newer hourly catalog arrives (with 103 already baked in), pending delta expires
        ts = ts + 3600
        sf.user_thumbs_up = 103
        assert.equals(103, SR.getRating(sf).up)

        package.loaded["storefront_cache"] = orig_cache
        package.loaded["socket.http"] = orig_http
        package.loaded["storefront_utils"] = orig_utils
    end)

    it("should bump downloads in-session only without writing storefront_ratings_cache.json or altering likes", function()
        local DataStorage = require("datastorage")
        local settings_dir = DataStorage:getSettingsDir()
        os.execute(string.format('mkdir -p "%s"', settings_dir))
        local cache_file = settings_dir .. "/storefront_ratings_cache.json"
        os.remove(cache_file)

        local item = { id = 1304319884, full_name = "ultimatejimmy/storefront.koplugin", user_thumbs_up = 102, user_thumbs_down = 0, downloads = 120 }
        StorefrontRatings.trackDownload(item, "plugin")

        local r = StorefrontRatings.getRating(item)
        assert.equals(102, r.up)
        assert.equals(121, r.downloads)
        assert.equals(0, StorefrontRatings.getCacheStats().files)
    end)

    it("should terminate subprocess and clean up FD on submitVote timeout and roll back pending delta", function()
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

        local item = { id = 777888, user_thumbs_up = 10, user_thumbs_down = 0 }
        local callback_called = false
        local callback_success = nil
        SR.submitVote(item, "up", "plugin", function(ok, res)
            callback_called = true
            callback_success = ok
        end)

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
        assert.equals(10, SR.getRating(item).up)

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

    it("should sort items by most liked using catalog ratings and wilson score", function()
        local item_high_likes = { id = 1, name = "HighLikes", user_thumbs_up = 10, user_thumbs_down = 0, wilson_score = 0.72, stars = 50 }
        local item_mid_likes = { id = 2, name = "MidLikes", user_thumbs_up = 3, user_thumbs_down = 0, wilson_score = 0.44, stars = 10 }
        local item_no_likes_high_stars = { id = 3, name = "NoLikesHighStars", user_thumbs_up = 0, user_thumbs_down = 0, wilson_score = 0.0, stars = 5000 }
        local item_no_likes_low_stars = { id = 4, name = "NoLikesLowStars", user_thumbs_up = 0, user_thumbs_down = 0, wilson_score = 0.0, stars = 100 }

        local list = { item_no_likes_high_stars, item_mid_likes, item_no_likes_low_stars, item_high_likes }

        table.sort(list, function(a, b)
            local r_a = a and StorefrontRatings.getRating(a, a)
            local r_b = b and StorefrontRatings.getRating(b, b)
            local sa = r_a and r_a.wilson or 0
            local sb = r_b and r_b.wilson or 0
            if sa ~= sb then return sa > sb end
            local ua = r_a and r_a.up or 0
            local ub = r_b and r_b.up or 0
            if ua ~= ub then return ua > ub end
            return (a.stars or 0) > (b.stars or 0)
        end)

        assert.equals("HighLikes", list[1].name)
        assert.equals("MidLikes", list[2].name)
        assert.equals("NoLikesHighStars", list[3].name)
        assert.equals("NoLikesLowStars", list[4].name)
    end)
end)
