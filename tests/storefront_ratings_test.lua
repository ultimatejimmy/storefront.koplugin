-- Unit tests for storefront_ratings.lua

local spec_helper = require("tests/spec_helper")

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
end)
