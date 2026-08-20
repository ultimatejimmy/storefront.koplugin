package.path = "storefront.koplugin/?.lua;" .. package.path

local storefront_font_mgr = require("storefront_font_mgr")

describe("storefront_font_mgr", function()
    it("exports required functions", function()
        assert.is_table(storefront_font_mgr)
        assert.is_function(storefront_font_mgr.init)
        assert.is_function(storefront_font_mgr.listInstalledFonts)
        assert.is_function(storefront_font_mgr.downloadFileToPath)
        assert.is_function(storefront_font_mgr.purgeFontCacheFiles)
        assert.is_function(storefront_font_mgr.getUserFontDirs)
    end)

    it("returns array of user font directories including data and fallback paths", function()
        local dirs = storefront_font_mgr.getUserFontDirs()
        assert.is_table(dirs)
        assert.is_true(#dirs >= 1)
    end)

    it("initializes Storefront mixin methods", function()
        local mockStorefront = {}
        storefront_font_mgr:init(mockStorefront)

        assert.is_function(mockStorefront.listInstalledFonts)
        assert.is_function(mockStorefront.syncPendingFontDownloads)
        assert.is_function(mockStorefront.installFont)
        assert.is_function(mockStorefront.installFontFromRepo)
        assert.is_function(mockStorefront._installFontFromRepoInternal)
        assert.is_function(mockStorefront.deleteFont)
    end)

    describe("downloadFileToPath validation", function()
        it("returns false for invalid inputs", function()
            assert.is_false(storefront_font_mgr.downloadFileToPath(nil, nil))
            assert.is_false(storefront_font_mgr.downloadFileToPath("", ""))
        end)
    end)
end)
