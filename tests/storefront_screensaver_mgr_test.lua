require("tests/spec_helper")

package.path = "storefront.koplugin/?.lua;" .. package.path

local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")

describe("StorefrontScreensaverMgr", function()
    local dummy_settings = {}
    local mock_settings = {
        readSetting = function(self, key)
            return dummy_settings[key]
        end,
        isTrue = function(self, key)
            return dummy_settings[key] == true
        end,
        saveSetting = function(self, key, val)
            dummy_settings[key] = val
        end,
        flush = function(self)
        end,
    }

    local luasettings = {
        open = function(self, path)
            return mock_settings
        end
    }
    package.loaded["luasettings"] = luasettings

    before_each(function()
        dummy_settings = {}
    end)

    describe("getScreensaverSettings", function()
        it("detects single mode when screensaver_type is image", function()
            dummy_settings["screensaver_type"] = "image"
            dummy_settings["screensaver_mode"] = "single"
            dummy_settings["screensaver_file"] = "/path/to/forest.jpg"

            local s = StorefrontScreensaverMgr.getScreensaverSettings()
            assert.are.same("single", s.effective_mode)
            assert.are.same("/path/to/forest.jpg", s.file)
        end)

        it("detects shuffle mode when screensaver_type is random_image", function()
            dummy_settings["screensaver_type"] = "random_image"
            dummy_settings["screensaver_dir"] = "/path/to/screensavers"

            local s = StorefrontScreensaverMgr.getScreensaverSettings()
            assert.are.same("shuffle", s.effective_mode)
            assert.are.same("/path/to/screensavers", s.dir)
        end)

        it("detects book cover mode", function()
            dummy_settings["screensaver_type"] = "cover"

            local s = StorefrontScreensaverMgr.getScreensaverSettings()
            assert.are.same("cover", s.effective_mode)
        end)

        it("detects reading progress / book status mode", function()
            dummy_settings["screensaver_type"] = "book_status"

            local s = StorefrontScreensaverMgr.getScreensaverSettings()
            assert.are.same("book_status", s.effective_mode)
        end)
    end)

    describe("setScreensaverMode", function()
        it("sets single mode properly", function()
            StorefrontScreensaverMgr.setScreensaverMode("single", { file = "/test/wallpaper.jpg" })
            assert.are.same("image", dummy_settings["screensaver_type"])
            assert.are.same("single", dummy_settings["screensaver_mode"])
            assert.are.same("/test/wallpaper.jpg", dummy_settings["screensaver_file"])
        end)

        it("sets shuffle mode properly", function()
            StorefrontScreensaverMgr.setScreensaverMode("shuffle", { dir = "/test/screensavers" })
            assert.are.same("random_image", dummy_settings["screensaver_type"])
            assert.are.same("random", dummy_settings["screensaver_mode"])
            assert.are.same("/test/screensavers", dummy_settings["screensaver_dir"])
        end)

        it("sets cover mode properly", function()
            StorefrontScreensaverMgr.setScreensaverMode("cover")
            assert.are.same("cover", dummy_settings["screensaver_type"])
            assert.are.same("single", dummy_settings["screensaver_mode"])
        end)

        it("updates toggles (banner, stretch, invert)", function()
            StorefrontScreensaverMgr.setScreensaverMode("single", {
                file = "/test/wallpaper.jpg",
                banner = true,
                stretch = true,
                invert = true,
            })
            assert.are.same(true, dummy_settings["screensaver_banner"])
            assert.are.same(true, dummy_settings["screensaver_stretch"])
            assert.are.same(true, dummy_settings["screensaver_invert"])
        end)
    end)
end)
