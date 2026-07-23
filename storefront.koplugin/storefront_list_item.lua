local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local StorefrontListItem = InputContainer:extend{
    align = "left",
    entry = nil,
    width = nil,
    dialog = nil,
}

function StorefrontListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local content_width = self.width or math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
    local text_color = (entry.dim or entry.select_enabled == false) and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    local content_inner = content_width - 2 * Size.padding.default

    local is_control = entry.callback and not entry.is_entry and entry.select_enabled ~= false

    if is_control then
        -- Control rows (Filter / Sort / Settings links) keep the existing TextBox representation with a frame
        local face = Font:getFace("smallinfofont")
        local text_box = TextBoxWidget:new{
            text = entry.text or "",
            width = content_inner,
            face = face,
            fgcolor = text_color,
            alignment = "left",
            justified = false,
            height_adjust = true,
        }
        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.button,
            radius = Size.radius.button,
            text_box,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    elseif not entry.is_entry then
        -- Info/status/warning rows
        local face = Font:getFace("smallinfofont")
        local text_box = TextBoxWidget:new{
            text = entry.text or "",
            width = content_inner,
            face = face,
            fgcolor = text_color,
            alignment = "left",
            justified = false,
            height_adjust = true,
        }
        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = 0,
            text_box,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    else
        -- Redesigned premium 3-line row layout for plugins/patches
        local name_text = entry.name or entry.text or ""
        local owner_text = entry.owner or ""
        local stars_text = entry.stars_fmt or "0"
        local updated_text = entry.updated or ""
        local desc_text = entry.description or ""
        local badge_text = entry.badge
        local badge_icon = entry.badge_icon

        local badge_w
        local right_reserve = 0
        local sc = function(val) return Device.screen:scaleBySize(val) end

        if badge_icon or badge_text then
            local right_widgets = {}

            if badge_text then
                local is_update_btn = (badge_text == _("Update"))
                local is_current_btn = (badge_text == _("✓ Current"))
                local is_installed_badge = (badge_text == _("Installed"))
                local is_solid_inverted = (is_update_btn or is_installed_badge)
                local badge_fg = entry.bFg or (is_solid_inverted and Blitbuffer.COLOR_WHITE or (is_current_btn and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK))
                local badge_bg = entry.bBg or (is_solid_inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)

                local badge_txt_w = TextWidget:new{
                    text = badge_text,
                    face = Font:getFace("smallinfofont", 14),
                    bold = is_solid_inverted,
                    fgcolor = badge_fg,
                }
                local text_chip = FrameContainer:new{
                    padding_top = sc(4),
                    padding_bottom = sc(4),
                    padding_left = sc(8),
                    padding_right = sc(8),
                    bordersize = is_solid_inverted and 0 or sc(1),
                    background = badge_bg,
                    color = Blitbuffer.COLOR_BLACK,
                    radius = is_solid_inverted and sc(10) or sc(4),
                    badge_txt_w,
                }
                table.insert(right_widgets, text_chip)
            end

            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
            local has_icon = false
            if badge_icon then
                if ok_lfs and lfs and lfs.attributes then
                    has_icon = (lfs.attributes(badge_icon, "mode") == "file")
                else
                    has_icon = true
                end
            end

            if badge_icon and has_icon then
                local icon_w = ImageWidget:new{
                    file = badge_icon,
                    width = sc(22),
                    height = sc(22),
                    scale_factor = 0,
                    alpha = true,
                }
                if #right_widgets > 0 then
                    table.insert(right_widgets, HorizontalSpan:new{ width = sc(8) })
                end
                table.insert(right_widgets, icon_w)
            end

            if #right_widgets == 1 then
                badge_w = right_widgets[1]
            else
                badge_w = HorizontalGroup:new(right_widgets)
            end
            right_reserve = badge_w:getSize().w + Size.padding.default
        end

        local text_w = content_inner - right_reserve

        -- Line 1: Name
        local name_face = Font:getFace("NotoSerif-Bold.ttf", 22)
        local name_w = TextWidget:new{
            text = name_text,
            face = name_face,
            bold = true,
            fgcolor = text_color,
            max_width = text_w,
        }

        -- Line 2: Meta Line (owner · ★ stars · updated)
        local meta_parts = {}
        local meta_text = ""
        if entry.is_update_item then
            if entry.kind_label then table.insert(meta_parts, entry.kind_label) end
            if entry.version_transition then table.insert(meta_parts, entry.version_transition) end
            meta_text = table.concat(meta_parts, "  ·  ")
        else
            if owner_text ~= "" then table.insert(meta_parts, owner_text) end
            table.insert(meta_parts, "★ " .. stars_text)
            if updated_text ~= "" then table.insert(meta_parts, updated_text) end
            if entry.kind_label then table.insert(meta_parts, entry.kind_label) end
            meta_text = table.concat(meta_parts, "  ·  ")
        end

        local meta_face = Font:getFace("cfont", 16)
        local meta_w = TextWidget:new{
            text = meta_text,
            face = meta_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = text_w,
        }

        local group
        if entry.is_update_item then
            group = VerticalGroup:new{
                align = "left",
                name_w,
                VerticalSpan:new{ width = 2 },
                meta_w,
            }
        else
            local desc_face = Font:getFace("cfont", 14)
            local desc_w = TextWidget:new{
                text = desc_text,
                face = desc_face,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }

            group = VerticalGroup:new{
                align = "left",
                name_w,
                VerticalSpan:new{ width = 2 },
                meta_w,
                VerticalSpan:new{ width = 4 },
                desc_w,
            }
        end

        local row_widget
        local item_h = group:getSize().h
        if badge_w then
            local badge_h = badge_w:getSize().h
            local total_h = math.max(item_h, badge_h)
            row_widget = OverlapGroup:new{
                dimen = Geom:new{ w = content_inner, h = total_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    group,
                },
                RightContainer:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    badge_w,
                }
            }
        else
            row_widget = LeftContainer:new{
                dimen = Geom:new{ w = content_inner, h = item_h },
                group,
            }
        end

        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = 0,
            row_widget,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    end

    if entry.callback or entry.hold_callback then
        local tap_range = function()
            return Geom:new{
                x = self.dimen.x,
                y = self.dimen.y,
                w = self.dimen.w,
                h = self.dimen.h,
            }
        end
        self.ges_events = {
            StorefrontTap = {
                GestureRange:new{
                    ges = "tap",
                    range = tap_range,
                },
            },
        }
        if entry.hold_callback then
            self.ges_events.StorefrontHold = {
                GestureRange:new{
                    ges = "hold",
                    range = tap_range,
                },
            }
        end
    end
end

function StorefrontListItem:onStorefrontTap(arg, ges)
    if self.entry and self.entry.on_badge_tap and ges and ges.pos then
        local sc = function(val) return Device.screen:scaleBySize(val) end
        local right_edge = (self.dimen and self.dimen.x or 0) + (self.dimen and self.dimen.w or 0)
        local badge_width = sc(70)
        if ges.pos.x >= (right_edge - badge_width) then
            self.entry.on_badge_tap()
            return true
        end
    end
    if self.dialog then
        self.dialog:onEntryActivated(self.entry)
    end
    return true
end

function StorefrontListItem:onStorefrontHold()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

function StorefrontListItem:isFocusable()
    if not self.entry then
        return false
    end
    if self.entry.select_enabled == false then
        return false
    end
    return self.entry.callback ~= nil or self.entry.hold_callback ~= nil
end

function StorefrontListItem:onFocus()
    if not self.frame then
        return true
    end
    self.frame.invert = true
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

function StorefrontListItem:onUnfocus()
    if not self.frame then
        return true
    end
    self.frame.invert = false
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

function StorefrontListItem:onTapSelect()
    if self.dialog then
        self.dialog:onEntryActivated(self.entry)
    end
    return true
end

function StorefrontListItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

return StorefrontListItem
