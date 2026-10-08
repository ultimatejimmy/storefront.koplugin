local ImageViewer = require("ui/widget/imageviewer")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local StorefrontImageModal = {}

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then return lfs end
    local ok_lfs2, lfs2 = pcall(require, "lfs")
    if ok_lfs2 and lfs2 then return lfs2 end
    return nil
end

local function isValidFile(path)
    if not path or path == "" then return false end
    local fname = path:match("([^/\\]+)$") or path
    if fname:sub(1, 1) == "." then return false end
    local lfs = getLfs()
    if lfs and lfs.attributes then
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "file" or (attr.size or 0) <= 0 then
            return false
        end
    end
    return true
end

local function testImageRenderable(path)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if ok_ri and RenderImage and RenderImage.renderImageFile then
        local ok_test, test_bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, 16, 16)
        if not ok_test or not test_bb then
            return false
        end
        if test_bb.free then pcall(test_bb.free, test_bb) end
    end
    return true
end

function StorefrontImageModal:new(opts)
    opts = opts or {}
    local image_path = opts.image_path
    local title_str = opts.title or _("Image View")

    local display_title = title_str:match("[^/]+$") or title_str
    if #display_title > 35 then
        display_title = display_title:sub(1, 32) .. "..."
    end

    local StorefrontToast = nil
    local ok_toast, toast_mod = pcall(require, "storefront_toast")
    if ok_toast and toast_mod then StorefrontToast = toast_mod end

    -- 1. Validate file existence and non-zero size
    if not isValidFile(image_path) then
        if opts.fallback_thumb and isValidFile(opts.fallback_thumb) then
            image_path = opts.fallback_thumb
        else
            if StorefrontToast and StorefrontToast.show then
                StorefrontToast.show(_("Cannot open image: file is missing or empty."), 3)
            end
            return nil
        end
    end

    -- 2. Verify that MuPDF can actually decode this image file (prevent fallback checkerboard)
    if not testImageRenderable(image_path) then
        if opts.fallback_thumb and isValidFile(opts.fallback_thumb) and testImageRenderable(opts.fallback_thumb) then
            image_path = opts.fallback_thumb
            if StorefrontToast and StorefrontToast.show then
                StorefrontToast.show(_("Showing thumbnail preview (original image could not be decoded)."), 3)
            end
        else
            if StorefrontToast and StorefrontToast.show then
                StorefrontToast.show(_("Unable to render image (file may be corrupted or format unsupported)."), 3)
            end
            return nil
        end
    end

    -- 3. Free temporary Lua memory to provide maximum contiguous RAM for decode
    collectgarbage("collect")

    local viewer
    local ok, res = pcall(function()
        return ImageViewer:new{
            file = image_path,
            title_text = display_title,
            fullscreen = false,
        }
    end)

    if ok and res and type(res) == "table" and res.handleEvent then
        viewer = res
    else
        local Device = require("device")
        local Input = Device and Device.input
        local key_events = {
            Close = { { "Back" }, { "Escape" } },
        }
        if Input and Input.group and Input.group.Back then
            table.insert(key_events.Close, { Input.group.Back })
        end
        viewer = InputContainer:new{
            covers_fullscreen = true,
            image_path = image_path,
            title = display_title,
            key_events = key_events,
        }
    end

    if not viewer.show then
        viewer.show = function(self)
            UIManager:show(self)
        end
    end

    local orig_onClose = viewer.onClose
    viewer.onClose = function(self)
        if self._clean_image_wg then
            pcall(self._clean_image_wg, self)
        end
        local ret = true
        if orig_onClose then
            ret = orig_onClose(self)
        else
            UIManager:close(self, "ui")
        end
        collectgarbage("step", 200)
        return ret
    end

    return viewer
end

return StorefrontImageModal
