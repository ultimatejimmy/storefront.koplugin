package.path = "storefront.koplugin/?.lua;" .. package.path

local storefront_patch_mgr = require("storefront_patch_mgr")

describe("storefront_patch_mgr", function()
    it("exports required helper functions", function()
        assert.is_table(storefront_patch_mgr)
        assert.is_function(storefront_patch_mgr.init)
        assert.is_function(storefront_patch_mgr.listInstalledPatches)
        assert.is_function(storefront_patch_mgr.getPatchRecordsMap)
        assert.is_function(storefront_patch_mgr.buildPatchRecordFields)
        assert.is_function(storefront_patch_mgr.buildPatchSummary)
        assert.is_function(storefront_patch_mgr.computeFileSha1)
    end)

    it("initializes Storefront patch manager mixin methods", function()
        local mockStorefront = {}
        storefront_patch_mgr:init(mockStorefront)

        assert.is_function(mockStorefront.listInstalledPatches)
        assert.is_function(mockStorefront.getPatchRecordsMap)
        assert.is_function(mockStorefront.collectPatchUpdateSummary)
        assert.is_function(mockStorefront.buildPatchUpdateItems)
        assert.is_function(mockStorefront.fetchPatchEntriesFromGitHub)
        assert.is_function(mockStorefront.storePatchEntriesForRepo)
        assert.is_function(mockStorefront.refreshPatchFileListings)
        assert.is_function(mockStorefront.getPatchEntriesForRepo)
        assert.is_function(mockStorefront.disablePatch)
        assert.is_function(mockStorefront.enablePatch)
        assert.is_function(mockStorefront.deletePatch)
        assert.is_function(mockStorefront.checkSinglePatch)
        assert.is_function(mockStorefront.updatePatchFromRecord)
        assert.is_function(mockStorefront.installPatchFromRepo)
        assert.is_function(mockStorefront._installPatchFromRepoInternal)
    end)

    describe("buildPatchRecordFields validation", function()
        it("returns nil for missing parameters", function()
            assert.is_nil(storefront_patch_mgr.buildPatchRecordFields(nil, nil, nil, false))
            assert.is_nil(storefront_patch_mgr.buildPatchRecordFields("", {}, nil, false))
        end)

        it("constructs valid record table", function()
            local repo = { name = "myrepo", owner = "myowner", id = 123 }
            local patch_info = { branch = "main", path = "2-test.lua", sha = "abc" }
            local rec = storefront_patch_mgr.buildPatchRecordFields("2-test.lua", repo, patch_info, true)
            assert.is_table(rec)
            assert.are.equal("2-test.lua", rec.filename)
            assert.are.equal("myowner", rec.owner)
            assert.are.equal("myrepo", rec.repo)
            assert.are.equal("abc", rec.sha)
        end)
    end)
end)
