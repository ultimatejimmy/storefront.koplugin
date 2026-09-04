local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local storefront_theme = require("storefront_theme")

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local StorefrontToastWidget = InputContainer:extend{
    text = "",
    timeout = 3,
    dismissable = true,
}

function StorefrontToastWidget:buildCard()
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local max_toast_w = math.min(sw - sc(32), sc(580))

    local icon = ImageWidget:new{
        file = getAssetPath("info.svg"),
        width = sc(22),
        height = sc(22),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local face = Font:getFace("cfont", storefront_theme.face_label_size or 18)
    local max_line_w = 0
    local ok_rt, RenderText = pcall(require, "ui/rendertext")
    if ok_rt and RenderText and RenderText.sizeUtf8Text then
        for line in (self.text or ""):gmatch("[^\r\n]+") do
            local sz = RenderText:sizeUtf8Text(0, 0, face, line)
            if sz and sz.x and sz.x > max_line_w then
                max_line_w = sz.x
            end
        end
    end

    local label_w = max_toast_w - sc(70)
    if max_line_w > 0 then
        label_w = math.min(label_w, math.max(sc(180), max_line_w + sc(16)))
    end

    local label = TextBoxWidget:new{
        text = self.text or "",
        face = face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = label_w,
        alignment = "center",
    }
    self.label_widget = label

    local row = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = sc(10) },
        label,
    }
    self.row = row

    local border_val = (storefront_theme.border_window and storefront_theme.border_window > 0)
        and storefront_theme.border_window or sc(2)

    local card = FrameContainer:new{
        padding = sc(14),
        padding_left = sc(16),
        padding_right = sc(16),
        radius = 0,
        bordersize = border_val,
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        row,
    }
    self.card = card

    local size = card:getSize()
    card.dimen = Geom:new{
        x = math.floor((sw - size.w) / 2),
        y = math.floor((sh - size.h) / 2),
        w = size.w,
        h = size.h,
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        card,
    }

    return card
end

function StorefrontToastWidget:init()
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    self:buildCard()

    if self.dismissable ~= false then
        if Device:hasKeys() then
            self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
        end
        if Device:isTouchDevice() then
            local GestureRange = require("ui/gesturerange")
            self.ges_events = {
                TapDismiss = {
                    GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } }
                },
            }
        end
    end

    if self.timeout and self.timeout > 0 then
        self._timer = UIManager:scheduleIn(self.timeout, function()
            self:close()
        end)
    end
end

function StorefrontToastWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", (self.card and self.card.dimen) or self.dimen
    end)
    return true
end

function StorefrontToastWidget:onCloseWidget()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    UIManager:setDirty(nil, function()
        return "ui", (self.card and self.card.dimen) or self.dimen
    end)
end

function StorefrontToastWidget:onTapDismiss()
    if self.dismissable ~= false then
        if self.dismiss_callback then
            self.dismiss_callback()
        end
        self:close()
        return true
    end
end

function StorefrontToastWidget:onAnyKeyPressed()
    if self.dismissable ~= false then
        if self.dismiss_callback then
            self.dismiss_callback()
        end
        self:close()
        return true
    end
end

function StorefrontToastWidget:onTap()
    return self:onTapDismiss()
end

function StorefrontToastWidget:close()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    UIManager:close(self)
end

function StorefrontToastWidget:show()
    UIManager:show(self)
    if type(UIManager.forceRePaint) == "function" then
        UIManager:forceRePaint()
    elseif type(UIManager.forceRepaint) == "function" then
        UIManager:forceRepaint()
    end
    return self
end

function StorefrontToastWidget:setText(text)
    text = text or ""
    if text == self.text and self.card then
        return
    end
    self.text = text

    local old_card_dimen = self.card and self.card.dimen and Geom:new{
        x = self.card.dimen.x,
        y = self.card.dimen.y,
        w = self.card.dimen.w,
        h = self.card.dimen.h,
    }

    self:buildCard()

    local new_card_dimen = self.card.dimen
    local sw = self.dimen.w
    local sh = self.dimen.h

    local refresh_rect
    if old_card_dimen then
        local rx = math.min(old_card_dimen.x, new_card_dimen.x) - sc(4)
        local ry = math.min(old_card_dimen.y, new_card_dimen.y) - sc(4)
        local rx2 = math.max(old_card_dimen.x + old_card_dimen.w, new_card_dimen.x + new_card_dimen.w) + sc(4)
        local ry2 = math.max(old_card_dimen.y + old_card_dimen.h, new_card_dimen.y + new_card_dimen.h) + sc(4)
        refresh_rect = Geom:new{
            x = math.max(0, rx),
            y = math.max(0, ry),
            w = math.min(sw, rx2 - rx),
            h = math.min(sh, ry2 - ry),
        }
    else
        refresh_rect = new_card_dimen
    end

    if UIManager.isShown and not UIManager:isShown(self) then
        UIManager:show(self)
    end

    UIManager:setDirty(self, function()
        return "ui", refresh_rect
    end)

    if type(UIManager.forceRePaint) == "function" then
        UIManager:forceRePaint()
    elseif type(UIManager.forceRepaint) == "function" then
        UIManager:forceRepaint()
    end
end

local StorefrontToast = {}

function StorefrontToast.show(text, timeout, opts)
    opts = opts or {}
    local dismissable = true
    if opts.dismissable == false then
        dismissable = false
    end
    local toast = StorefrontToastWidget:new{
        text = text or "",
        timeout = timeout or 3,
        dismissable = dismissable,
        dismiss_callback = opts.dismiss_callback,
    }
    UIManager:show(toast)
    if type(UIManager.forceRePaint) == "function" then
        UIManager:forceRePaint()
    elseif type(UIManager.forceRepaint) == "function" then
        UIManager:forceRepaint()
    end
    return toast
end

function StorefrontToast.new(opts_or_text, timeout_arg)
    local text = ""
    local timeout = 3

    if opts_or_text == StorefrontToast or (type(opts_or_text) == "table" and opts_or_text.new == StorefrontToast.new) then
        opts_or_text = timeout_arg
        timeout_arg = nil
    end

    if type(opts_or_text) == "table" then
        text = opts_or_text.text or ""
        timeout = opts_or_text.timeout or 3
    elseif type(opts_or_text) == "string" then
        text = opts_or_text
        timeout = timeout_arg or 3
    end

    return StorefrontToastWidget:new{
        text = text or "",
        timeout = timeout,
    }
end

return StorefrontToast
