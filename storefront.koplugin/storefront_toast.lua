local StorefrontToast = {}

function StorefrontToast.new(opts_or_text, timeout_arg)
    local text = ""
    local timeout = nil

    -- Handle colon invocation syntax (StorefrontToast:new(...) / InfoMessage:new(...))
    if opts_or_text == StorefrontToast or (type(opts_or_text) == "table" and opts_or_text.new == StorefrontToast.new) then
        opts_or_text = timeout_arg
        timeout_arg = nil
    end

    if type(opts_or_text) == "table" then
        text = opts_or_text.text or ""
        timeout = opts_or_text.timeout
    elseif type(opts_or_text) == "string" then
        text = opts_or_text
        timeout = timeout_arg
    end

    local Device = package.loaded["device"]
    if not Device then
        local ok_dev, dev = pcall(require, "device")
        if ok_dev then Device = dev end
    end

    local sc = function(val)
        return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
    end

    local sw = (Device and Device.screen and Device.screen:getWidth()) or 600
    local sh = (Device and Device.screen and Device.screen:getHeight()) or 800
    local dialog_w = math.min(sw - sc(40), sc(380))

    local storefront_theme = package.loaded["storefront_theme"] or require("storefront_theme")
    local ui_font_size = storefront_theme.face_label_size or 18

    local Font = package.loaded["ui/font"]
    if not Font then
        local ok_f, f = pcall(require, "ui/font")
        if ok_f then Font = f end
    end
    local face = (Font and Font.getFace and Font:getFace("cfont", ui_font_size)) or nil

    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local GestureRange = require("ui/gesturerange")

    local body_widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = dialog_w - sc(36),
        alignment = "center",
    }

    local body_container = FrameContainer:new{
        padding = sc(16),
        bordersize = 0,
        body_widget,
    }

    local card = FrameContainer:new{
        padding = sc(6),
        radius = storefront_theme.radius_window or sc(12),
        bordersize = storefront_theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        body_container,
    }

    local overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        },
    }

    local timer = nil
    local closed = false

    local function close_toast()
        if not closed then
            closed = true
            if timer then
                local ok_ui, UIManager = pcall(require, "ui/uimanager")
                if ok_ui and UIManager then
                    UIManager:unschedule(timer)
                end
                timer = nil
            end
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            if ok_ui and UIManager then
                UIManager:close(overlay, "ui")
            end
        end
    end

    overlay.onTap = function()
        close_toast()
        return true
    end

    overlay.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{ x = 0, y = 0, w = sw, h = sh } end
            }
        }
    }

    overlay.onClose = function()
        close_toast()
        return true
    end

    overlay.onShow = function()
        if timeout and timeout > 0 then
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            if ok_ui and UIManager then
                timer = UIManager:scheduleIn(timeout, close_toast)
            end
        end
    end

    overlay.close = close_toast
    overlay.dismiss = close_toast

    return overlay
end

function StorefrontToast.show(opts_or_text, timeout_arg)
    local toast = StorefrontToast.new(opts_or_text, timeout_arg)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager then
        UIManager:show(toast, "ui")
    end
    return toast
end

return StorefrontToast
