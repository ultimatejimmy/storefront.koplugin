package.path = "storefront.koplugin/?.lua;" .. package.path

local storefront_installer = require("storefront_installer")

describe("storefront_installer", function()
    it("exports required helper functions", function()
        assert.is_table(storefront_installer)
        assert.is_function(storefront_installer.init)
        assert.is_function(storefront_installer.downloadToFile)
        assert.is_function(storefront_installer.detectPluginFromArchive)
        assert.is_function(storefront_installer.extractPluginToUserDir)
    end)

    it("initializes Storefront installer mixin methods", function()
        local mockStorefront = {}
        storefront_installer:init(mockStorefront)

        assert.is_function(mockStorefront.resolveNewInstallDestination)
        assert.is_function(mockStorefront.renderAssetPickerModal)
        assert.is_function(mockStorefront.promptPluginInstallOptions)
        assert.is_function(mockStorefront.installPluginFromRepo)
        assert.is_function(mockStorefront._installPluginFromRepoInternal)
        assert.is_function(mockStorefront.installPluginFromReleaseAsset)
    end)

    describe("downloadToFile validation", function()
        it("returns false for missing URL", function()
            local ok, err = storefront_installer.downloadToFile("", "target.zip")
            assert.is_false(ok)
            assert.is_string(err)
        end)
    end)
end)
