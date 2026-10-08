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
            assert.are.same("document_cover", dummy_settings["screensaver_type"])
            assert.are.same("single", dummy_settings["screensaver_mode"])
            assert.are.same("/test/wallpaper.jpg", dummy_settings["screensaver_document_cover"])
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

        it("sets book status mode properly", function()
            StorefrontScreensaverMgr.setScreensaverMode("book_status")
            assert.are.same("book_status", dummy_settings["screensaver_type"])
        end)

        it("updates toggles (banner, stretch, invert, background)", function()
            StorefrontScreensaverMgr.setScreensaverMode("single", {
                file = "/test/wallpaper.jpg",
                banner = true,
                stretch = true,
                invert = true,
                background = "none",
            })
            assert.are.same(true, dummy_settings["screensaver_banner"])
            assert.are.same(true, dummy_settings["screensaver_stretch_images"])
            assert.are.same(true, dummy_settings["screensaver_invert"])
            assert.are.same("none", dummy_settings["screensaver_img_background"])
        end)
    end)

    describe("isWallpaperDownloaded", function()
        it("returns false for nil or empty item", function()
            local dl, path = StorefrontScreensaverMgr.isWallpaperDownloaded(nil)
            assert.is_false(dl)
            assert.is_nil(path)

            dl, path = StorefrontScreensaverMgr.isWallpaperDownloaded({})
            assert.is_false(dl)
            assert.is_nil(path)
        end)

        it("checks candidate filenames and extensions", function()
            local lfs = {
                attributes = function(path, mode)
                    if path == "/tmp/koreader/screensavers/test-forest.png" then
                        return { mode = "file" }
                    end
                    return nil
                end
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local dl, path = StorefrontScreensaverMgr.isWallpaperDownloaded({
                id = "test-forest",
            })
            assert.is_true(dl)
            assert.are.same("/tmp/koreader/screensavers/test-forest.png", path)
        end)
    end)

    describe("Title & Author Extraction", function()
        it("extracts exact title and author when matched in catalog", function()
            local dummy_cat = {
                {
                    id = "whisperingsea4-highres-landscape-2a",
                    title = "Highres Landscape 2A",
                    author = "whisperingsea4",
                    filename = "whisperingsea4-highres-landscape-2a.png",
                }
            }
            package.loaded["storefront_screensavers_ui"] = {
                getCachedCatalog = function() return dummy_cat end
            }

            local mock_dir_files = { "whisperingsea4-highres-landscape-2a.png" }
            local lfs = {
                dir = function()
                    local i = 0
                    return function()
                        i = i + 1
                        return mock_dir_files[i]
                    end
                end,
                attributes = function(path, mode)
                    return { mode = "file", size = 1024, modification = 1700000000 }
                end
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local list = StorefrontScreensaverMgr.listLocalScreensavers("/tmp/test_ss")
            assert.are.same(1, #list)
            assert.are.same("Highres Landscape 2A", list[1].title)
            assert.are.same("whisperingsea4", list[1].author)
            assert.are.same("whisperingsea4-highres-landscape-2a.png", list[1].filename)
        end)

        it("strips author prefix cleanly when not matched in catalog", function()
            package.loaded["storefront_screensavers_ui"] = {
                getCachedCatalog = function() return {} end
            }

            local mock_dir_files = { "whisperingsea4-lunar-celestial-eclipse.png" }
            local lfs = {
                dir = function()
                    local i = 0
                    return function()
                        i = i + 1
                        return mock_dir_files[i]
                    end
                end,
                attributes = function(path, mode)
                    return { mode = "file", size = 2048, modification = 1700000000 }
                end
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local list = StorefrontScreensaverMgr.listLocalScreensavers("/tmp/test_ss")
            assert.are.same(1, #list)
            assert.are.same("Lunar Celestial Eclipse", list[1].title)
            assert.are.same("whisperingsea4", list[1].author)
        end)
    end)

    describe("Custom Screensaver Folder", function()
        it("returns default folder when no custom folder is set", function()
            assert.are.same("/tmp/koreader/screensavers", StorefrontScreensaverMgr.getDefaultScreensaverFolder())
            assert.are.same("/tmp/koreader/screensavers", StorefrontScreensaverMgr.getScreensaverFolder())
            assert.is_false(StorefrontScreensaverMgr.isCustomScreensaverFolder())
            assert.is_nil(StorefrontScreensaverMgr.getCustomScreensaverFolder())
        end)

        it("sets, detects, and gets custom screensaver folder", function()
            StorefrontScreensaverMgr.setCustomScreensaverFolder("/mnt/onboard/my_screensavers/")
            assert.is_true(StorefrontScreensaverMgr.isCustomScreensaverFolder())
            assert.are.same("/mnt/onboard/my_screensavers", StorefrontScreensaverMgr.getCustomScreensaverFolder())
            assert.are.same("/mnt/onboard/my_screensavers", StorefrontScreensaverMgr.getScreensaverFolder())
            assert.are.same("/mnt/onboard/my_screensavers", dummy_settings["screensaver_custom_folder"])
            assert.are.same("/mnt/onboard/my_screensavers", dummy_settings["screensaver_dir"])
        end)

        it("resets custom screensaver folder back to default", function()
            StorefrontScreensaverMgr.setCustomScreensaverFolder("/mnt/onboard/my_screensavers")
            assert.is_true(StorefrontScreensaverMgr.isCustomScreensaverFolder())

            StorefrontScreensaverMgr.resetCustomScreensaverFolder()
            assert.is_false(StorefrontScreensaverMgr.isCustomScreensaverFolder())
            assert.are.same("/tmp/koreader/screensavers", StorefrontScreensaverMgr.getScreensaverFolder())
            assert.is_nil(dummy_settings["screensaver_custom_folder"])
            assert.are.same("/tmp/koreader/screensavers", dummy_settings["screensaver_dir"])
        end)

        it("resets to default when setting empty or default folder path", function()
            StorefrontScreensaverMgr.setCustomScreensaverFolder("/mnt/onboard/my_screensavers")
            StorefrontScreensaverMgr.setCustomScreensaverFolder("")
            assert.is_false(StorefrontScreensaverMgr.isCustomScreensaverFolder())

            StorefrontScreensaverMgr.setCustomScreensaverFolder("/mnt/onboard/my_screensavers")
            StorefrontScreensaverMgr.setCustomScreensaverFolder("/tmp/koreader/screensavers/")
            assert.is_false(StorefrontScreensaverMgr.isCustomScreensaverFolder())
        end)
    end)

    describe("deleteLocalScreensaver", function()
        it("returns true and false for non-active screensaver", function()
            local removed = {}
            local lfs = {
                attributes = function(path, mode)
                    if removed[path] then return nil end
                    return { mode = "file" }
                end
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local orig_remove = os.remove
            os.remove = function(path)
                removed[path] = true
                return true
            end

            dummy_settings["screensaver_type"] = "document_cover"
            dummy_settings["screensaver_file"] = "/other/wallpaper.jpg"

            local ok, was_active = StorefrontScreensaverMgr.deleteLocalScreensaver("/test/forest.jpg")
            assert.is_true(ok)
            assert.is_false(was_active)

            os.remove = orig_remove
        end)

        it("returns true and true for active single screensaver", function()
            local removed = {}
            local lfs = {
                attributes = function(path, mode)
                    if removed[path] then return nil end
                    return { mode = "file" }
                end
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local orig_remove = os.remove
            os.remove = function(path)
                removed[path] = true
                return true
            end

            dummy_settings["screensaver_type"] = "document_cover"
            dummy_settings["screensaver_mode"] = "single"
            dummy_settings["screensaver_file"] = "/test/forest.jpg"

            local ok, was_active = StorefrontScreensaverMgr.deleteLocalScreensaver("/test/forest.jpg")
            assert.is_true(ok)
            assert.is_true(was_active)

            os.remove = orig_remove
        end)

        it("autoFallbackAfterDelete does nothing when was_active_single is false", function()
            local called = false
            local orig = StorefrontScreensaverMgr.setScreensaverMode
            StorefrontScreensaverMgr.setScreensaverMode = function(...) called = true end
            StorefrontScreensaverMgr.autoFallbackAfterDelete(false)
            assert.is_false(called)
            StorefrontScreensaverMgr.setScreensaverMode = orig
        end)
    end)

    describe("countLocalScreensavers", function()
        it("accurately counts only valid non-hidden image files with size > 0", function()
            local files = {
                ["."] = { mode = "directory" },
                [".."] = { mode = "directory" },
                ["wallpaper1.jpg"] = { mode = "file", size = 2048 },
                ["wallpaper2.png"] = { mode = "file", size = 4096 },
                ["._hidden.png"] = { mode = "file", size = 1024 }, -- Mac resource fork
                ["empty.jpg"] = { mode = "file", size = 0 }, -- 0-byte corrupt
                ["not_an_image.txt"] = { mode = "file", size = 100 },
            }
            local lfs = {
                attributes = function(path, key)
                    if path == "/test/screensavers" then
                        return { mode = "directory" }
                    end
                    local fname = path:match("([^/\\]+)$") or path
                    return files[fname]
                end,
                dir = function(path)
                    local list = { "wallpaper1.jpg", "wallpaper2.png", "._hidden.png", "empty.jpg", "not_an_image.txt" }
                    local i = 0
                    return function()
                        i = i + 1
                        return list[i]
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local count = StorefrontScreensaverMgr.countLocalScreensavers("/test/screensavers")
            assert.are.same(2, count)
        end)
    end)

    describe("getActiveScreensaverIdentifiers", function()
        it("returns identifier for single active mode", function()
            dummy_settings["screensaver_type"] = "document_cover"
            dummy_settings["screensaver_mode"] = "single"
            dummy_settings["screensaver_file"] = "/screensavers/forest_view.jpg"

            local ids = StorefrontScreensaverMgr.getActiveScreensaverIdentifiers()
            assert.is_true(ids["forest_view.jpg"] == true)
            assert.is_true(ids["forest_view"] == true)
        end)

        it("returns identifiers for shuffle mode", function()
            dummy_settings["screensaver_type"] = "random_image"
            dummy_settings["screensaver_dir"] = "/test/screensavers"

            local lfs = {
                attributes = function(path, key)
                    return { mode = "directory" }
                end,
                dir = function(path)
                    local list = { "ocean.png", "mountain.jpg" }
                    local i = 0
                    return function()
                        i = i + 1
                        return list[i]
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local ids = StorefrontScreensaverMgr.getActiveScreensaverIdentifiers()
            assert.is_true(ids["ocean.png"] == true)
            assert.is_true(ids["ocean"] == true)
            assert.is_true(ids["mountain.jpg"] == true)
            assert.is_true(ids["mountain"] == true)
        end)
    end)

    describe("Thumbnail Focus Inversion Protection", function()
        it("StorefrontListItem double-inverts thumbnail widget to preserve normal contrast on focus", function()
            local StorefrontListItem = require("storefront_list_item")
            local item = StorefrontListItem:new{
                entry = {
                    title = "Test Screensaver",
                    callback = function() end,
                },
            }
            item.frame = { invert = false }
            item.thumb_widget = { invert = false }

            item:onFocus()
            assert.is_true(item.frame.invert == true)
            assert.is_true(item.thumb_widget.invert == true)

            item:onUnfocus()
            assert.is_true(item.frame.invert == false)
            assert.is_true(item.thumb_widget.invert == false)
        end)
    end)
end)

