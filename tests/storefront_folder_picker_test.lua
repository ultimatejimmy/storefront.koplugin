require("tests/spec_helper")

package.path = "storefront.koplugin/?.lua;" .. package.path

local StorefrontFolderPicker = require("storefront_folder_picker")

describe("StorefrontFolderPicker", function()
    describe("getParentPath", function()
        it("returns nil for root, nil, or empty paths", function()
            assert.is_nil(StorefrontFolderPicker.getParentPath(nil))
            assert.is_nil(StorefrontFolderPicker.getParentPath(""))
            assert.is_nil(StorefrontFolderPicker.getParentPath("/"))
            assert.is_nil(StorefrontFolderPicker.getParentPath("   "))
        end)

        it("correctly finds parent directory for nested unix paths", function()
            assert.are.same("/mnt/onboard", StorefrontFolderPicker.getParentPath("/mnt/onboard/screensavers"))
            assert.are.same("/mnt/onboard", StorefrontFolderPicker.getParentPath("/mnt/onboard/screensavers/"))
            assert.are.same("/mnt", StorefrontFolderPicker.getParentPath("/mnt/onboard"))
            assert.are.same("/", StorefrontFolderPicker.getParentPath("/mnt"))
        end)

        it("handles windows-style drive roots gracefully", function()
            assert.are.same("C:/Users", StorefrontFolderPicker.getParentPath("C:/Users/Screensavers"))
            assert.are.same("C:", StorefrontFolderPicker.getParentPath("C:/Users"))
            assert.is_nil(StorefrontFolderPicker.getParentPath("C:"))
        end)
    end)

    describe("scanDirectory", function()
        it("returns subdirectories and counts wallpapers", function()
            local mock_files = {
                ["/test/wallpapers"] = { "nature", "abstract", "sunset.jpg", "nebula.png", "notes.txt" },
            }

            local mock_dirs = {
                ["/test/wallpapers"] = true,
                ["/test/wallpapers/nature"] = true,
                ["/test/wallpapers/abstract"] = true,
            }

            local lfs = {
                dir = function(path)
                    local files = mock_files[path] or {}
                    local i = 0
                    return function()
                        i = i + 1
                        return files[i]
                    end
                end,
                attributes = function(path, mode)
                    if mock_dirs[path] then
                        return { mode = "directory", modification = 1700000000 }
                    else
                        return { mode = "file", size = 1024, modification = 1700000000 }
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local subdirs, img_count = StorefrontFolderPicker.scanDirectory("/test/wallpapers")
            assert.are.same(2, img_count) -- sunset.jpg and nebula.png
            assert.are.same(2, #subdirs)
            assert.are.same("abstract", subdirs[1].name)
            assert.are.same("nature", subdirs[2].name)
        end)
    end)

    describe("formatTwoLinesMax and truncateToWidth", function()
        local Font = require("ui/font")
        local face = Font:getFace("cfont", 14)

        it("returns empty string on nil or empty input", function()
            assert.are.same("", StorefrontFolderPicker.formatTwoLinesMax(nil, 200, face, true))
            assert.are.same("", StorefrontFolderPicker.formatTwoLinesMax("", 200, face, true))
        end)

        it("handles short names without wrapping", function()
            local text = "Screensavers"
            local res = StorefrontFolderPicker.formatTwoLinesMax(text, 500, face, true)
            assert.are.same("Screensavers", res)
            assert.is_nil(res:find("\n"))
        end)

        it("wraps and truncates super long folder names properly", function()
            local long_name = "for testing purposes only test test testTHis is a super long folder for testing purposes"
            -- Provide a custom mock or test with width constraints
            local TextWidget = require("ui/widget/textwidget")
            local orig_new = TextWidget.new
            TextWidget.new = function(a, b)
                local args = b or a or {}
                local txt = args.text or ""
                return {
                    getSize = function()
                        return { w = #txt * 8, h = 16 }
                    end
                }
            end

            local formatted = StorefrontFolderPicker.formatTwoLinesMax(long_name, 200, face, true)
            assert.is_string(formatted)
            -- Should contain newline for 2-line max formatting
            assert.truthy(formatted:find("\n"))

            -- Test with super long single token
            local single_token = "VeryLongSingleFolderNameWithoutAnySpacesInItAtAllForTestingPurposes"
            local formatted_single = StorefrontFolderPicker.formatTwoLinesMax(single_token, 100, face, true)
            assert.is_string(formatted_single)
            assert.truthy(formatted_single:find("\n"))
            assert.truthy(formatted_single:find("%.%.%."))

            TextWidget.new = orig_new
        end)
    end)

    describe("show", function()
        it("instantiates UI and runs refresh without errors with long folder names", function()
            local UIManager = require("ui/uimanager")
            local shown_widget = nil
            local orig_show = UIManager.show
            UIManager.show = function(self, widget)
                shown_widget = widget
            end

            local mock_files = {
                ["/test/screensavers"] = {
                    "for testing purposes only test test testTHis is a super long folder for testing purposes",
                    "short_folder",
                    "wallpaper.png"
                },
            }

            local mock_dirs = {
                ["/test/screensavers"] = true,
                ["/test/screensavers/for testing purposes only test test testTHis is a super long folder for testing purposes"] = true,
                ["/test/screensavers/short_folder"] = true,
            }

            local lfs = {
                dir = function(path)
                    local files = mock_files[path] or {}
                    local i = 0
                    return function()
                        i = i + 1
                        return files[i]
                    end
                end,
                attributes = function(path, mode)
                    if mock_dirs[path] then
                        return { mode = "directory", modification = 1700000000 }
                    else
                        return { mode = "file", size = 1024, modification = 1700000000 }
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local logger = require("logger")
            local last_err = nil
            local orig_err = logger.err
            logger.err = function(msg)
                last_err = msg
            end

            local confirmed_path = nil
            StorefrontFolderPicker.show{
                title = "Select Screensaver Folder",
                initial_path = "/test/screensavers",
                on_confirm = function(path)
                    confirmed_path = path
                end,
            }

            logger.err = orig_err
            if last_err then
                error(last_err)
            end
            assert.is_true(shown_widget ~= nil)
            UIManager.show = orig_show
        end)
    end)
end)
