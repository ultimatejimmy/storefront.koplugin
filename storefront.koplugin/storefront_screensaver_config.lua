local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")

local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")

local StorefrontScreensaverConfig = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

function StorefrontScreensaverConfig.show(Storefront, on_close_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(420))
    local dialog_h = math.min(sh - sc(40), sc(620))

    local title_font_size = storefront_theme.title_font_size or 22

    local overlay
    local refresh

    local function closeConfig()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_close_callback then
            on_close_callback()
        end
    end

    local function openGallery()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        local StorefrontScreensaverGallery = require("storefront_screensaver_gallery")
        StorefrontScreensaverGallery.show(Storefront, on_close_callback, function()
            StorefrontScreensaverConfig.show(Storefront, on_close_callback)
        end)
    end

    local function make_row_item(frame, callback)
        local item = InputContainer:new{ frame }
        item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        return item.dimen or frame:getSize()
                    end
                }
            }
        }
        item.onTap = function()
            if callback then callback() end
            return true
        end
        return item
    end

    refresh = function()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local settings = StorefrontScreensaverMgr.getScreensaverSettings()
        local local_wallpapers = StorefrontScreensaverMgr.listLocalScreensavers()

        -- Title Widget
        local title_label = TextWidget:new{
            text = _("Screensaver Settings"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local title_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            title_label,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_container,
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            }
        }

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", storefront_theme.section_header_font_size or 15),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(5),
                padding_left = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function create_mode_row(mode_key, label_text, desc_text, right_btn_text, on_right_btn)
            local is_selected = (settings.effective_mode == mode_key)
            local radio_symbol = is_selected and "● " or "○ "

            local title_line = TextWidget:new{
                text = radio_symbol .. label_text,
                face = Font:getFace("NotoSerif-Regular.ttf", 17),
                bold = is_selected,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local btn_widget = nil
            local btn_w = 0
            if right_btn_text and on_right_btn then
                btn_w = sc(84)
                btn_widget = Button:new{
                    text = right_btn_text,
                    text_font_size = 13,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(3),
                    padding = sc(4),
                    padding_h = sc(8),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = on_right_btn,
                }
            end

            local desc_w = dialog_w - sc(36) - btn_w
            local desc_line = TextBoxWidget:new{
                text = desc_text,
                face = Font:getFace("cfont", 13),
                fgcolor = storefront_theme.color_label_dim,
                width = desc_w,
            }

            local left_vg = VerticalGroup:new{
                align = "left",
                title_line,
                VerticalSpan:new{ width = sc(2) },
                desc_line,
            }

            local left_frame = FrameContainer:new{
                padding = 0,
                bordersize = 0,
                width = desc_w,
                left_vg,
            }

            local left_item = make_row_item(left_frame, function()
                StorefrontScreensaverMgr.setScreensaverMode(mode_key)
                refresh()
            end)

            local row_elements = { left_item }
            if btn_widget then
                table.insert(row_elements, HorizontalSpan:new{ width = sc(8) })
                table.insert(row_elements, btn_widget)
            end

            local row_hg = HorizontalGroup:new(row_elements)
            return FrameContainer:new{
                padding = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                row_hg,
            }
        end

        local function create_toggle_row(checked, label_text, on_toggle)
            local icon_str = checked and "☑ " or "☐ "
            local title_line = TextWidget:new{
                text = icon_str .. label_text,
                face = Font:getFace("cfont", 16),
                bold = checked,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local frame = FrameContainer:new{
                padding = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                title_line,
            }

            return make_row_item(frame, function()
                on_toggle()
                refresh()
            end)
        end

        local scroll_vg = VerticalGroup:new{ align = "left" }

        -- SECTION 1: SCREENSAVER MODE
        table.insert(scroll_vg, create_section_header(_("Screensaver Mode")))

        -- Single Image Mode
        local active_file_str = tostring(settings.file or "")
        local active_filename = (active_file_str ~= "") and (active_file_str:match("([^/\\]+)$") or active_file_str) or _("None selected")
        local single_desc = string.format(_("Displays a static wallpaper on sleep.\nActive: %s"), active_filename)
        table.insert(scroll_vg, create_mode_row("single", _("Single Wallpaper"), single_desc, _("Change..."), openGallery))

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Folder Shuffle Mode
        local shuffle_desc = string.format(_("Shuffles through all wallpapers in folder on sleep.\nPool size: %d wallpapers in rotation"), #local_wallpapers)
        table.insert(scroll_vg, create_mode_row("shuffle", _("Folder Shuffle"), shuffle_desc, _("Collection"), openGallery))

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Book Cover Mode
        table.insert(scroll_vg, create_mode_row("cover", _("Book Cover"), _("Shows the cover of the book currently being read"), nil, nil))

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Reading Progress Mode
        table.insert(scroll_vg, create_mode_row("book_status", _("Reading Progress / Summary"), _("Shows reading stats, percentage, and chapter progress"), nil, nil))

        -- SECTION 2: DISPLAY OPTIONS
        table.insert(scroll_vg, create_section_header(_("Display Options")))

        -- Banner toggle
        table.insert(scroll_vg, create_toggle_row(settings.banner, _("Show reading progress banner overlay"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { banner = not settings.banner })
        end))

        -- Stretch toggle
        table.insert(scroll_vg, create_toggle_row(settings.stretch, _("Stretch image to fill entire screen"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { stretch = not settings.stretch })
        end))

        -- Invert toggle
        table.insert(scroll_vg, create_toggle_row(settings.invert, _("Invert colors (night mode / dark background)"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { invert = not settings.invert })
        end))

        -- SECTION 3: QUICK ACTIONS
        table.insert(scroll_vg, create_section_header(_("Wallpaper Collection")))

        local function create_action_row(label_text, badge_text, callback)
            local title_line = TextWidget:new{
                text = label_text,
                face = Font:getFace("cfont", 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local badge_w = badge_text and TextWidget:new{
                text = badge_text,
                face = Font:getFace("cfont", 14),
                fgcolor = storefront_theme.color_label_dim,
            }

            local row_elements = { title_line }
            if badge_w then
                local avail_w = dialog_w - sc(36)
                local left_w = title_line:getSize().w
                local right_w = badge_w:getSize().w
                local span_w = math.max(sc(8), avail_w - left_w - right_w)
                table.insert(row_elements, HorizontalSpan:new{ width = span_w })
                table.insert(row_elements, badge_w)
            end

            local frame = FrameContainer:new{
                padding = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                HorizontalGroup:new(row_elements),
            }

            return make_row_item(frame, callback)
        end

        table.insert(scroll_vg, create_action_row(_("Open Wallpaper Collection Gallery"), string.format(_("%d items"), #local_wallpapers), openGallery))

        table.insert(scroll_vg, create_action_row(_("Browse Wallpapers in Storefront"), "→", function()
            if overlay then
                local ov = overlay
                overlay = nil
                ov.onClose = nil
                UIManager:close(ov, "ui")
            end
            if Storefront and type(Storefront.showBrowser) == "function" then
                Storefront:showBrowser("screensaver")
            end
        end))

        local scroll_container = ScrollableContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = dialog_h - sc(120) },
            scroll_bar_width = 0,
            show_scrollbar = false,
            show_scrollbar_h = false,
            show_scrollbar_v = false,
            bordersize = 0,
            padding = 0,
            scroll_vg,
        }
        table.insert(content_vg, scroll_container)

        -- Bottom Close Button
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        local close_btn = Button:new{
            text = _("Close"),
            text_font_size = 16,
            bold = true,
            bordersize = 0,
            radius = sc(4),
            padding = sc(8),
            width = dialog_w - sc(20),
            background = Blitbuffer.COLOR_WHITE,
            callback = closeConfig,
        }

        table.insert(content_vg, FrameContainer:new{
            padding = sc(6),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = close_btn:getSize().h },
                close_btn,
            }
        })

        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg,
        }

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card,
        }
        overlay.onClose = function()
            overlay = nil
            if on_close_callback then
                on_close_callback()
            end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontScreensaverConfig
