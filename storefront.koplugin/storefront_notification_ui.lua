--- storefront_notification_ui.lua
--- Presentation layer for Storefront update notification dialog (Design B).
-- Displays a compact, e-ink optimized modal card with update details and actions.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonDialog = require("ui/widget/buttondialog")

local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontToast = require("storefront_toast")
local StorefrontUtils = require("storefront_utils")
local NotificationMgr = require("storefront_notification_mgr")

local StorefrontNotificationUI = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local function is12HourClockEnabled()
    if G_reader_settings then
        if type(G_reader_settings.isTrue) == "function" and G_reader_settings:isTrue("twelve_hour_clock") then
            return true
        end
        if type(G_reader_settings.readSetting) == "function" then
            local val = G_reader_settings:readSetting("twelve_hour_clock")
            if val == true or val == "true" or val == "12h" or val == 1 then
                return true
            end
        end
    end
    return false
end

local function formatCheckedTime(ts)
    if not ts or type(ts) ~= "number" or ts <= 0 then
        ts = os.time()
    end
    local now = os.time()
    local is_today = os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d", now)
    local time_fmt = is12HourClockEnabled() and "%I:%M%p" or "%H:%M"

    local ok, t_str = pcall(os.date, time_fmt, ts)
    if not ok or not t_str then
        t_str = ""
    else
        t_str = t_str:gsub("^0", "")
    end

    if is_today then
        return string.format(_("Today %s"), t_str)
    end

    local date_fmt = is12HourClockEnabled() and "%Y-%m-%d %I:%M%p" or "%Y-%m-%d %H:%M"
    local ok_d, dt_str = pcall(os.date, date_fmt, ts)
    if ok_d and dt_str then
        return dt_str:gsub(" 0(%d:)", " %1")
    end
    return _("Recently")
end

--- Shows the snooze duration selection dialog styled in Storefront design.
---@param on_snooze_selected? function callback when snooze is set
function StorefrontNotificationUI.showSnoozePicker(on_snooze_selected)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(30), sc(340))
    local pad_h = sc(18)
    local btn_w = dialog_w - (pad_h * 2)
    local btn_h = sc(38)

    local ui_font_size = storefront_theme.face_label_size or 16
    local title_font_size = storefront_theme.title_font_size or 20

    local overlay
    local function closeDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
    end

    local title_label = TextBoxWidget:new{
        text = _("Remind Me Later"),
        face = StorefrontUtils.getTitleFace(title_font_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = dialog_w - sc(24),
        alignment = "center",
    }

    local title_container = FrameContainer:new{
        padding_top = sc(14),
        padding_bottom = sc(12),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = btn_w, h = title_label:getSize().h },
            title_label,
        },
    }

    local content_vg = VerticalGroup:new{
        align = "left",
        title_container,
        LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        },
    }

    local buttons_vg = VerticalGroup:new{
        align = "center",
    }

    local function makeOptionBtn(text, callback, is_bold)
        return StorefrontUtils.createButton{
            text = text,
            text_font_size = ui_font_size,
            bold = is_bold or false,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = storefront_theme.radius_btn or sc(4),
            width = btn_w,
            height = btn_h,
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = callback,
        }
    end

    local btn_1h = makeOptionBtn(_("1 hour"), function()
        closeDialog()
        NotificationMgr.setSnooze(3600)
        StorefrontToast.show(_("Remind me in 1 hour."), 2)
        if on_snooze_selected then on_snooze_selected() end
    end)

    local btn_4h = makeOptionBtn(_("4 hours"), function()
        closeDialog()
        NotificationMgr.setSnooze(14400)
        StorefrontToast.show(_("Remind me in 4 hours."), 2)
        if on_snooze_selected then on_snooze_selected() end
    end)

    local btn_tomorrow = makeOptionBtn(_("Tomorrow"), function()
        closeDialog()
        NotificationMgr.setSnoozeTomorrow()
        StorefrontToast.show(_("Remind me tomorrow."), 2)
        if on_snooze_selected then on_snooze_selected() end
    end)

    local cancel_btn = makeOptionBtn(_("Cancel"), function()
        closeDialog()
    end, true)

    local options = { btn_1h, btn_4h, btn_tomorrow }
    for _, btn in ipairs(options) do
        table.insert(buttons_vg, VerticalSpan:new{ width = sc(8) })
        table.insert(buttons_vg, btn)
    end

    table.insert(buttons_vg, VerticalSpan:new{ width = sc(12) })
    table.insert(buttons_vg, LineWidget:new{
        dimen = Geom:new{ w = btn_w, h = sc(1) },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    })
    table.insert(buttons_vg, VerticalSpan:new{ width = sc(10) })
    table.insert(buttons_vg, cancel_btn)
    table.insert(buttons_vg, VerticalSpan:new{ width = sc(4) })

    table.insert(content_vg, FrameContainer:new{
        padding_top = sc(4),
        padding_bottom = sc(12),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        buttons_vg,
    })

    local card = FrameContainer:new{
        padding = 0,
        radius = storefront_theme.radius_window or 0,
        bordersize = storefront_theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        content_vg,
    }

    local layout = {
        { btn_1h },
        { btn_4h },
        { btn_tomorrow },
        { cancel_btn },
    }

    local Input = Device and Device.input
    local key_events = {
        Close = { { "Back" }, { "Escape" } },
    }
    if Input and Input.group and Input.group.Back then
        table.insert(key_events.Close, { Input.group.Back })
    end

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = layout,
        selected = { x = 1, y = 1 },
        key_events = key_events,
        card,
    }

    btn_1h.show_parent = overlay
    btn_4h.show_parent = overlay
    btn_tomorrow.show_parent = overlay
    cancel_btn.show_parent = overlay

    overlay.onClose = function()
        closeDialog()
        return true
    end

    UIManager:show(overlay, "ui")
    return overlay
end

--- Displays the update notification modal card (Design B).
---@param Storefront table Storefront instance
---@param updates table array of update descriptor items { name = string, version = string, kind = string }
---@param opts? table optional extra parameters
function StorefrontNotificationUI.show(Storefront, updates, opts)
    updates = updates or {}
    if #updates == 0 then
        return
    end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(30), sc(400))

    local ui_font_size = storefront_theme.face_label_size or 16
    local subtext_font_size = storefront_theme.subtext_font_size or 14
    local title_font_size = 22

    local overlay
    local function closeNotification()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
    end

    local content_vg = VerticalGroup:new{
        align = "left",
    }

    -- 1. Header with Storefront lightning bolt icon and Dynamic Title (Singular vs Plural)
    local zap_icon = ImageWidget:new{
        file = getAssetPath("zap.svg"),
        width = sc(24),
        height = sc(24),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local title_text = "Storefront"
    local title_label = TextWidget:new{
        text = title_text,
        face = StorefrontUtils.getTitleFace(title_font_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local header_row = HorizontalGroup:new{
        align = "center",
        zap_icon,
        HorizontalSpan:new{ width = sc(10) },
        title_label,
    }

    local pad_h = sc(23)

    table.insert(content_vg, FrameContainer:new{
        padding_top = sc(14),
        padding_bottom = sc(12),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        header_row,
    })

    -- Divider
    table.insert(content_vg, LineWidget:new{
        dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
        background = Blitbuffer.COLOR_BLACK,
    })

    -- 2. Subtitle: "X updates available" or "1 update available"
    local count_text
    if #updates == 1 then
        count_text = _("1 update available")
    else
        count_text = string.format(_("%d updates available"), #updates)
    end

    local subtitle_widget = TextWidget:new{
        text = count_text,
        face = Font:getFace("cfont", ui_font_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    table.insert(content_vg, FrameContainer:new{
        padding_top = sc(12),
        padding_bottom = sc(8),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        subtitle_widget,
    })

    -- 3. Update items list (indented bullets with name + version)
    local items_vg = VerticalGroup:new{
        align = "left",
    }

    local list_indent = sc(6)
    local inner_w = dialog_w - (pad_h * 2) - list_indent - sc(8)

    local MAX_DISPLAY_CAP = 5
    local total_count = #updates
    local show_count = math.min(total_count, MAX_DISPLAY_CAP)

    for i = 1, show_count do
        local item = updates[i]
        local bullet = TextWidget:new{
            text = "• ",
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local bullet_w = (bullet.getSize and bullet:getSize().w) or sc(12)

        local version_str = item.version or item.tag_name or ""
        if version_str ~= "" and not version_str:match("^[vV]") and not version_str:match("^%(") then
            version_str = "v" .. version_str
        end
        if item.kind == "patch" and version_str == "" then
            version_str = _("(patch)")
        end

        local ver_widget = TextWidget:new{
            text = version_str,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        local ver_w = (ver_widget.getSize and ver_widget:getSize().w) or sc(50)

        local name_w = math.max(sc(40), inner_w - bullet_w - ver_w - sc(14))

        local name_widget = TextWidget:new{
            text = item.name or _("Unknown item"),
            face = Font:getFace("cfont", ui_font_size),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = name_w,
            truncate_with_ellipsis = true,
        }

        local name_used_w = (name_widget.getSize and name_widget:getSize().w) or name_w
        local spacer_w = math.max(sc(8), inner_w - bullet_w - name_used_w - ver_w)

        local item_row = HorizontalGroup:new{
            align = "center",
            bullet,
            name_widget,
            HorizontalSpan:new{ width = spacer_w },
            ver_widget,
        }

        table.insert(items_vg, FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(4),
            padding_left = 0,
            padding_right = 0,
            bordersize = 0,
            item_row,
        })
    end

    -- If there are remaining updates beyond the cap of 5, add simple summary row
    if total_count > show_count then
        local remaining = total_count - show_count
        local more_text = (remaining == 1)
            and _("+1 more")
            or string.format(_("+%d more"), remaining)

        local more_bullet = TextWidget:new{
            text = "• ",
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = storefront_theme.color_label_dim,
        }
        local more_label = TextWidget:new{
            text = more_text,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        local more_row = HorizontalGroup:new{
            align = "center",
            more_bullet,
            more_label,
        }
        table.insert(items_vg, FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(4),
            padding_left = 0,
            padding_right = 0,
            bordersize = 0,
            more_row,
        })
    end

    local list_container = FrameContainer:new{
        padding_top = sc(2),
        padding_bottom = sc(10),
        padding_left = pad_h + list_indent,
        padding_right = pad_h,
        bordersize = 0,
        items_vg,
    }

    -- Accommodate directly without scrollbars
    table.insert(content_vg, list_container)

    -- Divider before buttons
    table.insert(content_vg, LineWidget:new{
        dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
        background = Blitbuffer.COLOR_BLACK,
    })

    -- 4. Three Action Buttons side by side: [ View Updates ] [ Later ] [ Dismiss ]
    local btn_spacing = sc(8)
    local avail_btn_w = dialog_w - (pad_h * 2) - (btn_spacing * 2) - sc(4)
    local open_btn_w = math.floor(avail_btn_w * 0.45)
    local other_btn_w = math.floor((avail_btn_w - open_btn_w) / 2)
    local btn_h = sc(36)

    local open_btn = StorefrontUtils.createButton{
        text = _("View Updates"),
        text_font_size = subtext_font_size,
        bold = true,
        width = open_btn_w,
        height = btn_h,
        background = Blitbuffer.COLOR_BLACK,
        text_font_color = Blitbuffer.COLOR_WHITE,
        bordersize = sc(1),
        callback = function()
            closeNotification()
            -- Deep link directly to Updates tab
            local sf = (Storefront and Storefront.instance) or Storefront
            if sf then
                if sf.ensureBrowserState then sf:ensureBrowserState() end
                if sf.browser_state then
                    sf.browser_state.tab = "Updates"
                    sf.browser_state.kind = "plugin"
                    sf.browser_state.page = 1
                    sf.browser_state.scroll_offset = nil
                    if sf.saveBrowserState then sf:saveBrowserState(true) end
                end
                sf._merged_updates_cache = nil
                sf._cached_plugin_summary = nil
                sf._cached_patch_summary = nil
                if sf.showBrowser then
                    sf:showBrowser()
                end
            end
        end,
    }

    local later_btn = StorefrontUtils.createButton{
        text = _("Later"),
        text_font_size = subtext_font_size,
        bold = false,
        width = other_btn_w,
        height = btn_h,
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        bordersize = sc(1),
        callback = function()
            closeNotification()
            StorefrontNotificationUI.showSnoozePicker()
        end,
    }

    local dismiss_btn = StorefrontUtils.createButton{
        text = _("Dismiss"),
        text_font_size = subtext_font_size,
        bold = false,
        width = other_btn_w,
        height = btn_h,
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        bordersize = sc(1),
        callback = function()
            closeNotification()
        end,
    }

    local button_row = HorizontalGroup:new{
        align = "center",
        open_btn,
        HorizontalSpan:new{ width = btn_spacing },
        later_btn,
        HorizontalSpan:new{ width = btn_spacing },
        dismiss_btn,
    }

    table.insert(content_vg, FrameContainer:new{
        padding_top = sc(12),
        padding_bottom = sc(10),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = dialog_w - (pad_h * 2), h = btn_h },
            button_row,
        },
    })

    -- 5. Footer: "Last checked: Today 8:32 AM"
    local last_checked_ts = NotificationMgr.getLastChecked()
    local checked_str = formatCheckedTime(last_checked_ts)
    local footer_text = string.format(_("Last checked: %s"), checked_str)

    local footer_widget = TextWidget:new{
        text = footer_text,
        face = Font:getFace("cfont", math.max(10, subtext_font_size - sc(2))),
        fgcolor = storefront_theme.color_label_dim,
    }

    table.insert(content_vg, FrameContainer:new{
        padding_top = sc(2),
        padding_bottom = sc(14),
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = dialog_w - (pad_h * 2), h = sc(18) },
            footer_widget,
        },
    })

    -- Assemble outer modal card
    local card = FrameContainer:new{
        padding = 0,
        radius = storefront_theme.radius_window or 0,
        bordersize = storefront_theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        content_vg,
    }

    local layout = {
        { open_btn, later_btn, dismiss_btn },
    }

    local Input = Device and Device.input
    local key_events = {
        Close = { { "Back" }, { "Escape" } },
    }
    if Input and Input.group and Input.group.Back then
        table.insert(key_events.Close, { Input.group.Back })
    end

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = layout,
        selected = { x = 1, y = 1 },
        key_events = key_events,
        card,
    }

    open_btn.show_parent = overlay
    later_btn.show_parent = overlay
    dismiss_btn.show_parent = overlay

    overlay.onClose = function()
        closeNotification()
        return true
    end

    UIManager:show(overlay, "ui")
    return overlay
end

return StorefrontNotificationUI
