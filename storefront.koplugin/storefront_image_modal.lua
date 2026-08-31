local ImageViewer = require("ui/widget/imageviewer")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local StorefrontImageModal = {}

function StorefrontImageModal:new(opts)
    opts = opts or {}
    local image_path = opts.image_path
    local title_str = opts.title or _("Image View")

    local display_title = title_str:match("[^/]+$") or title_str
    if #display_title > 35 then
        display_title = display_title:sub(1, 32) .. "..."
    end

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

    if not viewer.onClose then
        viewer.onClose = function(self)
            UIManager:close(self, "ui")
            return true
        end
    end

    return viewer
end

return StorefrontImageModal
