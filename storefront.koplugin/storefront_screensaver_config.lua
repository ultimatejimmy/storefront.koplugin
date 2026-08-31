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
    local dialog_w = math.min(sw - sc(20), sc(460))
    local max_dialog_h = math.min(sh - sc(30), sc(780))

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

    local FocusManager = require("ui/widget/focusmanager")
    local focusable_rows = {}

    local function make_row_item(frame, callback)
        local item = InputContainer:new{ frame }
        item.frame = frame
        item.callback = callback
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
        item.isFocusable = function(self)
            return true
        end
        item.onFocus = function(self)
            if self.frame then
                self.frame.invert = true
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        item.onUnfocus = function(self)
            if self.frame then
                self.frame.invert = false
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        item.onTapSelect = function(self)
            if self.callback then
                self.callback()
            end
            return true
        end

        table.insert(focusable_rows, item)
        return item
    end

    refresh = function()
        focusable_rows = {}
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local available_h = sh - sc(24)
        local title_font_size
        local header_font_size
        local ui_font_size
        local subtext_font_size
        local btn_font_size
        local icon_font_size
        local row_pad_v
        local header_pad_v
        local title_pad_v
        local close_h

        if available_h >= sc(650) then
            title_font_size = 20
            header_font_size = 14
            ui_font_size = 15
            subtext_font_size = 13
            btn_font_size = 13
            icon_font_size = 16
            row_pad_v = sc(4)
            header_pad_v = sc(3)
            title_pad_v = sc(8)
            close_h = sc(36)
        elseif available_h >= sc(520) then
            title_font_size = 18
            header_font_size = 13
            ui_font_size = 14
            subtext_font_size = 12
            btn_font_size = 12
            icon_font_size = 15
            row_pad_v = sc(3)
            header_pad_v = sc(2)
            title_pad_v = sc(6)
            close_h = sc(32)
        elseif available_h >= sc(440) then
            title_font_size = 16
            header_font_size = 11
            ui_font_size = 13
            subtext_font_size = 11
            btn_font_size = 11
            icon_font_size = 14
            row_pad_v = sc(2)
            header_pad_v = sc(2)
            title_pad_v = sc(4)
            close_h = sc(28)
        else
            title_font_size = 14
            header_font_size = 10
            ui_font_size = 11
            subtext_font_size = 10
            btn_font_size = 10
            icon_font_size = 13
            row_pad_v = sc(1)
            header_pad_v = sc(1)
            title_pad_v = sc(2)
            close_h = sc(24)
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
            padding = title_pad_v,
            padding_left = sc(12),
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
                face = Font:getFace("cfont", header_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = header_pad_v,
                padding_left = sc(10),
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
                face = Font:getFace("cfont", ui_font_size),
                bold = is_selected,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local btn_widget = nil
            local btn_w = 0
            if right_btn_text and on_right_btn then
                btn_w = sc(76)
                btn_widget = Button:new{
                    text = right_btn_text,
                    text_font_size = btn_font_size,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(3),
                    padding = sc(2),
                    padding_h = sc(6),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = on_right_btn,
                }
            end

            local desc_w = dialog_w - sc(36) - btn_w
            local desc_line = (desc_text and desc_text ~= "") and TextBoxWidget:new{
                text = desc_text,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
                width = desc_w,
            } or nil

            local left_vg_items = { title_line }
            if desc_line then
                table.insert(left_vg_items, VerticalSpan:new{ width = sc(1) })
                table.insert(left_vg_items, desc_line)
            end

            local left_vg = VerticalGroup:new{
                align = "left",
                unpack(left_vg_items)
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
                padding = row_pad_v,
                padding_left = sc(10),
                padding_right = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                row_hg,
            }
        end

        local function create_toggle_row(checked, label_text, on_toggle)
            local icon_str = checked and "☑" or "☐"
            local icon_w = TextWidget:new{
                text = icon_str,
                face = Font:getFace("cfont", icon_font_size),
                bold = checked,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local label_w = TextBoxWidget:new{
                text = label_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = dialog_w - sc(50),
            }

            local row_hg = HorizontalGroup:new{
                icon_w,
                HorizontalSpan:new{ width = sc(8) },
                label_w,
            }

            local frame = FrameContainer:new{
                padding = row_pad_v,
                padding_left = sc(10),
                padding_right = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                row_hg,
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
        local single_desc = (active_filename ~= "" and active_filename ~= _("None selected"))
            and string.format(_("Active: %s"), active_filename)
            or _("Displays a static wallpaper on sleep")
        table.insert(scroll_vg, create_mode_row("single", _("Single Wallpaper"), single_desc, _("Change..."), openGallery))

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Folder Shuffle Mode
        local shuffle_desc = string.format(_("Pool size: %d wallpapers in rotation"), #local_wallpapers)
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

        -- SECTION 2: SCREENSAVER FOLDER
        table.insert(scroll_vg, create_section_header(_("Screensaver Folder")))

        local current_folder = StorefrontScreensaverMgr.getScreensaverFolder()
        local is_custom = StorefrontScreensaverMgr.isCustomScreensaverFolder()
        local folder_status_label = is_custom and _("Custom folder") or _("Default folder")

        local function openFolderChooser()
            UIManager:nextTick(function()
                local ok, err = pcall(function()
                    if overlay then
                        local ov = overlay
                        overlay = nil
                        ov.onClose = nil
                        UIManager:close(ov, "ui")
                    end
                    local StorefrontFolderPicker = require("storefront_folder_picker")
                    StorefrontFolderPicker.show{
                        title = _("Select Screensaver Folder"),
                        initial_path = StorefrontScreensaverMgr.getScreensaverFolder(),
                        on_confirm = function(chosen_path)
                            if chosen_path and chosen_path ~= "" then
                                StorefrontScreensaverMgr.setCustomScreensaverFolder(chosen_path)
                                local StorefrontToast = require("storefront_toast")
                                StorefrontToast.show(string.format(_("Screensaver folder set to '%s'"), chosen_path), 2)
                            end
                            UIManager:nextTick(function()
                                StorefrontScreensaverConfig.show(Storefront, on_close_callback)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                StorefrontScreensaverConfig.show(Storefront, on_close_callback)
                            end)
                        end,
                    }
                end)
                if not ok then
                    local logger = require("logger")
                    logger.err("openFolderChooser error: " .. tostring(err))
                    StorefrontScreensaverConfig.show(Storefront, on_close_callback)
                end
            end)
        end

        local folder_title_text = TextWidget:new{
            text = folder_status_label,
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local folder_browse_btn = Button:new{
            text = _("Change..."),
            text_font_size = btn_font_size,
            bold = true,
            bordersize = sc(1),
            radius = sc(3),
            padding = sc(2),
            padding_h = sc(6),
            background = Blitbuffer.COLOR_WHITE,
            callback = openFolderChooser,
        }

        local folder_btn_w = folder_browse_btn:getSize().w
        local folder_desc_w = dialog_w - sc(36) - folder_btn_w
        local folder_path_desc = TextBoxWidget:new{
            text = current_folder,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
            width = folder_desc_w,
        }

        local folder_left_vg = VerticalGroup:new{
            align = "left",
            folder_title_text,
            VerticalSpan:new{ width = sc(1) },
            folder_path_desc,
        }

        local folder_left_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            width = folder_desc_w,
            folder_left_vg,
        }

        local folder_left_item = make_row_item(folder_left_frame, openFolderChooser)

        local folder_row_hg = HorizontalGroup:new{
            folder_left_item,
            HorizontalSpan:new{ width = sc(8) },
            folder_browse_btn,
        }

        table.insert(scroll_vg, FrameContainer:new{
            padding = row_pad_v,
            padding_left = sc(10),
            padding_right = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            folder_row_hg,
        })

        if is_custom then
            table.insert(scroll_vg, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })

            local reset_title = TextWidget:new{
                text = _("Reset to Default Folder"),
                face = Font:getFace("cfont", ui_font_size),
                bold = false,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local reset_desc = TextWidget:new{
                text = string.format(_("Restore: %s"), StorefrontScreensaverMgr.getDefaultScreensaverFolder()),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            local reset_left_vg = VerticalGroup:new{
                align = "left",
                reset_title,
                VerticalSpan:new{ width = sc(1) },
                reset_desc,
            }
            local reset_frame = FrameContainer:new{
                padding = row_pad_v,
                padding_left = sc(10),
                padding_right = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                reset_left_vg,
            }
            table.insert(scroll_vg, make_row_item(reset_frame, function()
                StorefrontScreensaverMgr.resetCustomScreensaverFolder()
                refresh()
                local StorefrontToast = require("storefront_toast")
                StorefrontToast.show(_("Reset to default screensaver folder"), 2)
            end))
        end

        -- SECTION 3: DISPLAY OPTIONS
        table.insert(scroll_vg, create_section_header(_("Display Options")))

        -- Border Fill & Background (Black / White / No Fill)
        local fill_labels = {
            black = _("Black Fill"),
            white = _("White Fill"),
            none = _("No Fill (Transparent)"),
        }
        local current_fill = settings.background or "black"
        local fill_display = fill_labels[current_fill] or _("Black Fill")

        local function cycle_fill()
            local next_fill = "black"
            if current_fill == "black" then
                next_fill = "white"
            elseif current_fill == "white" then
                next_fill = "none"
            else
                next_fill = "black"
            end
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { background = next_fill })
            refresh()
        end

        local fill_title = TextWidget:new{
            text = _("Border Fill / Background"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local fill_badge = TextWidget:new{
            text = fill_display .. " ▾",
            face = Font:getFace("cfont", subtext_font_size),
            bold = true,
            fgcolor = (current_fill == "none") and Blitbuffer.COLOR_BLACK or storefront_theme.color_label_dim,
        }
        local fill_desc = TextWidget:new{
            text = (current_fill == "none") and _("Transparent overlay (page content visible behind)") or _("Solid fill for screen margins & letterboxing"),
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }

        local fill_top_row = HorizontalGroup:new{
            fill_title,
            HorizontalSpan:new{ width = math.max(sc(8), dialog_w - sc(36) - fill_title:getSize().w - fill_badge:getSize().w) },
            fill_badge,
        }

        local fill_vg = VerticalGroup:new{
            align = "left",
            fill_top_row,
            VerticalSpan:new{ width = sc(1) },
            fill_desc,
        }

        local fill_frame = FrameContainer:new{
            padding = row_pad_v,
            padding_left = sc(10),
            padding_right = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            fill_vg,
        }

        table.insert(scroll_vg, make_row_item(fill_frame, cycle_fill))

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

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

        local title_h = title_container:getSize().h + sc(1)
        local close_h_total = close_h + sc(8)
        local max_scroll_h = max_dialog_h - title_h - close_h_total
        local content_h = scroll_vg:getSize().h
        local scroll_h = math.min(content_h, max_scroll_h)
        local is_scrollable = content_h > max_scroll_h

        local scroll_container = ScrollableContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = scroll_h },
            scroll_bar_width = is_scrollable and sc(4) or 0,
            show_scrollbar = is_scrollable,
            show_scrollbar_h = false,
            show_scrollbar_v = is_scrollable,
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

        local StorefrontUtils = require("storefront_utils")
        local close_btn = StorefrontUtils.createButton{
            text = _("Close"),
            text_font_size = btn_font_size + 2,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = sc(4),
            width = dialog_w - sc(20),
            height = close_h,
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = closeConfig,
        }

        table.insert(content_vg, FrameContainer:new{
            padding = sc(3),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = close_h },
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

        local layout = {}
        for _, row_item in ipairs(focusable_rows) do
            table.insert(layout, { row_item })
        end
        table.insert(layout, { close_btn })

        local Device = require("device")
        local Input = Device and Device.input
        local key_events = {
            Close = { { "Back" }, { "Escape" } }
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

        for _, row_item in ipairs(focusable_rows) do
            row_item.show_parent = overlay
        end
        close_btn.show_parent = overlay

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
