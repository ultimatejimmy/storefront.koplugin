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
end)
