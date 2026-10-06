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
local ImageWidget = require("ui/widget/imagewidget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")

local Event = require("ui/event")
local FocusManager = require("ui/widget/focusmanager")

local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")

local _asset_path_cache = {}
local function getAssetPath(filename)
    if not filename or filename == "" then return nil end
    if _asset_path_cache[filename] ~= nil then
        return _asset_path_cache[filename] or nil
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local rel_path = dir .. "assets/" .. filename

    local paths_to_try = { rel_path }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()
    if data_dir then
        table.insert(paths_to_try, data_dir .. "/" .. rel_path)
        table.insert(paths_to_try, data_dir .. "/plugins/storefront.koplugin/assets/" .. filename)
    end

    for _, p in ipairs(paths_to_try) do
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
            _asset_path_cache[filename] = p
            return p
        end
        local f = io.open(p, "r")
        if f then
            f:close()
            _asset_path_cache[filename] = p
            return p
        end
    end

    _asset_path_cache[filename] = false
    return nil
end

local StorefrontScreensaverConfig = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

function StorefrontScreensaverConfig.show(Storefront, on_close_callback, initial_selected)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(460))
    local max_dialog_h = math.min(sh - sc(30), sc(780))

    local title_font_size = storefront_theme.title_font_size or 22

    local overlay
    local scroll_container
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
        local cur_selected = overlay and overlay.selected and { x = overlay.selected.x, y = overlay.selected.y }
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        local StorefrontScreensaverGallery = require("storefront_screensaver_gallery")
        StorefrontScreensaverGallery.show(Storefront, on_close_callback, function()
            StorefrontScreensaverConfig.show(Storefront, on_close_callback, cur_selected)
        end)
    end

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

        return item
    end

    refresh = function(saved_selected)
        local prev_selected = saved_selected
        if not prev_selected and overlay and overlay.selected then
            prev_selected = { x = overlay.selected.x, y = overlay.selected.y }
        end
        local prev_scroll_y = (scroll_container and scroll_container._scroll_offset_y) or 0

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
            face = StorefrontUtils.getTitleFace(title_font_size),
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
                local orig_focus = btn_widget.onFocus
                btn_widget.onFocus = function(self)
                    if orig_focus then orig_focus(self) elseif self.frame then self.frame.invert = true end
                    UIManager:setDirty(self.show_parent or self, "fast")
                    return true
                end
                local orig_unfocus = btn_widget.onUnfocus
                btn_widget.onUnfocus = function(self)
                    if orig_unfocus then orig_unfocus(self) elseif self.frame then self.frame.invert = false end
                    UIManager:setDirty(self.show_parent or self, "fast")
                    return true
                end
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
                padding_v = sc(2),
                padding_h = sc(4),
                bordersize = 0,
                width = desc_w,
                left_vg,
            }

            local left_item = make_row_item(left_frame, function()
                StorefrontScreensaverMgr.setScreensaverMode(mode_key)
                refresh()
            end)

            local layout_row = { left_item }
            local row_elements = { left_item }
            if btn_widget then
                table.insert(row_elements, HorizontalSpan:new{ width = sc(8) })
                table.insert(row_elements, btn_widget)
                table.insert(layout_row, btn_widget)
            end

            local row_hg = HorizontalGroup:new(row_elements)
            local row_container = FrameContainer:new{
                padding = row_pad_v,
                padding_left = sc(6),
                padding_right = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                row_hg,
            }
            return row_container, layout_row
        end

        local function create_toggle_row(checked, label_text, on_toggle)
            local icon_file = getAssetPath(checked and "check-square.svg" or "square.svg")
            local icon_w
            if icon_file then
                icon_w = ImageWidget:new{
                    file = icon_file,
                    width = icon_font_size,
                    height = icon_font_size,
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
            else
                local icon_str = checked and "☑" or "☐"
                icon_w = TextWidget:new{
                    text = icon_str,
                    face = Font:getFace("cfont", icon_font_size),
                    bold = checked,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end
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

            local item = make_row_item(frame, function()
                on_toggle()
                refresh()
            end)
            return item, { item }
        end

        local scroll_vg = VerticalGroup:new{ align = "left" }
        local layout = {}

        -- SECTION 1: SCREENSAVER MODE
        table.insert(scroll_vg, create_section_header(_("Screensaver Mode")))

        -- Single Image Mode
        local active_file_str = tostring(settings.file or "")
        local active_filename = (active_file_str ~= "") and (active_file_str:match("([^/\\]+)$") or active_file_str) or _("None selected")
        local single_desc = (active_filename ~= "" and active_filename ~= _("None selected"))
            and string.format(_("Active: %s"), active_filename)
            or _("Displays a static wallpaper on sleep")
        local mode1_w, mode1_layout = create_mode_row("single", _("Single Wallpaper"), single_desc, _("Change..."), openGallery)
        table.insert(scroll_vg, mode1_w)
        table.insert(layout, mode1_layout)

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Folder Shuffle Mode
        local shuffle_desc = string.format(_("Pool size: %d wallpapers in rotation"), #local_wallpapers)
        local mode2_w, mode2_layout = create_mode_row("shuffle", _("Folder Shuffle"), shuffle_desc, _("Collection"), openGallery)
        table.insert(scroll_vg, mode2_w)
        table.insert(layout, mode2_layout)

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Book Cover Mode
        local mode3_w, mode3_layout = create_mode_row("cover", _("Book Cover"), _("Shows the cover of the book currently being read"), nil, nil)
        table.insert(scroll_vg, mode3_w)
        table.insert(layout, mode3_layout)

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Reading Progress Mode
        local mode4_w, mode4_layout = create_mode_row("book_status", _("Reading Progress/Summary"), _("Shows reading stats, percentage, and chapter progress"), nil, nil)
        table.insert(scroll_vg, mode4_w)
        table.insert(layout, mode4_layout)

        -- SECTION 2: SCREENSAVER FOLDER
        table.insert(scroll_vg, create_section_header(_("Screensaver Folder")))

        local current_folder = StorefrontScreensaverMgr.getScreensaverFolder()
        local is_custom = StorefrontScreensaverMgr.isCustomScreensaverFolder()
        local folder_status_label = is_custom and _("Custom folder") or _("Default folder")

        local function openFolderChooser()
            local cur_selected = overlay and overlay.selected and { x = overlay.selected.x, y = overlay.selected.y }
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
                                StorefrontScreensaverConfig.show(Storefront, on_close_callback, cur_selected)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                StorefrontScreensaverConfig.show(Storefront, on_close_callback, cur_selected)
                            end)
                        end,
                    }
                end)
                if not ok then
                    local logger = require("logger")
                    logger.err("openFolderChooser error: " .. tostring(err))
                    StorefrontScreensaverConfig.show(Storefront, on_close_callback, cur_selected)
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
        local orig_fb_focus = folder_browse_btn.onFocus
        folder_browse_btn.onFocus = function(self)
            if orig_fb_focus then orig_fb_focus(self) elseif self.frame then self.frame.invert = true end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end
        local orig_fb_unfocus = folder_browse_btn.onUnfocus
        folder_browse_btn.onUnfocus = function(self)
            if orig_fb_unfocus then orig_fb_unfocus(self) elseif self.frame then self.frame.invert = false end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end

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
            padding_v = sc(2),
            padding_h = sc(4),
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

        local folder_container = FrameContainer:new{
            padding = row_pad_v,
            padding_left = sc(6),
            padding_right = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            folder_row_hg,
        }
        table.insert(scroll_vg, folder_container)
        table.insert(layout, { folder_left_item, folder_browse_btn })

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
            local reset_item = make_row_item(reset_frame, function()
                StorefrontScreensaverMgr.resetCustomScreensaverFolder()
                refresh()
                local StorefrontToast = require("storefront_toast")
                StorefrontToast.show(_("Reset to default screensaver folder"), 2)
            end)
            table.insert(scroll_vg, reset_item)
            table.insert(layout, { reset_item })
        end

        -- SECTION 3: DISPLAY OPTIONS
        table.insert(scroll_vg, create_section_header(_("Display Options")))

        -- Border Fill & Background (Black/White/No Fill)
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
            text = _("Border Fill/Background"),
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

        local fill_item = make_row_item(fill_frame, cycle_fill)
        table.insert(scroll_vg, fill_item)
        table.insert(layout, { fill_item })

        table.insert(scroll_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Banner toggle
        local banner_w, banner_layout = create_toggle_row(settings.banner, _("Show reading progress banner overlay"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { banner = not settings.banner })
        end)
        table.insert(scroll_vg, banner_w)
        table.insert(layout, banner_layout)

        -- Stretch toggle
        local stretch_w, stretch_layout = create_toggle_row(settings.stretch, _("Stretch image to fill entire screen"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { stretch = not settings.stretch })
        end)
        table.insert(scroll_vg, stretch_w)
        table.insert(layout, stretch_layout)

        -- Invert toggle
        local invert_w, invert_layout = create_toggle_row(settings.invert, _("Invert colors (night mode/dark background)"), function()
            StorefrontScreensaverMgr.setScreensaverMode(settings.effective_mode, { invert = not settings.invert })
        end)
        table.insert(scroll_vg, invert_w)
        table.insert(layout, invert_layout)

        local title_h = title_container:getSize().h + sc(1)
        local close_h_total = close_h + sc(8)
        local max_scroll_h = max_dialog_h - title_h - close_h_total
        local content_h = scroll_vg:getSize().h
        local scroll_h = math.min(content_h, max_scroll_h)
        local is_scrollable = content_h > max_scroll_h

        scroll_container = ScrollableContainer:new{
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
        local orig_close_focus = close_btn.onFocus
        close_btn.onFocus = function(self)
            if orig_close_focus then orig_close_focus(self) elseif self.frame then self.frame.invert = true end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end
        local orig_close_unfocus = close_btn.onUnfocus
        close_btn.onUnfocus = function(self)
            if orig_close_unfocus then orig_close_unfocus(self) elseif self.frame then self.frame.invert = false end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end

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

        table.insert(layout, { close_btn })

        local Device = require("device")
        local Input = Device and Device.input
        local key_events = {
            Close = { { "Back" }, { "Escape" } }
        }
        if Input and Input.group and Input.group.Back then
            table.insert(key_events.Close, { Input.group.Back })
        end

        local target_y = 1
        local target_x = 1
        if prev_selected then
            target_y = math.max(1, math.min(#layout, prev_selected.y or 1))
            target_x = math.max(1, math.min(#layout[target_y], prev_selected.x or 1))
        end

        overlay = FocusManager:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            layout = layout,
            selected = { x = target_x, y = target_y },
            key_events = key_events,
            card,
        }

        for _, row in ipairs(layout) do
            for _, item in ipairs(row) do
                item.show_parent = overlay
            end
        end

        overlay.cropping_widget = scroll_container

        overlay.onPress = function(self)
            local item = self:getFocusItem()
            if item then
                if item.onTapSelect then
                    return item:onTapSelect()
                elseif item.callback then
                    item.callback()
                    return true
                end
            end
            if FocusManager and FocusManager.onPress then
                return FocusManager.onPress(self)
            end
            return false
        end

        overlay._ensureFocusedVisible = function(self)
            if not scroll_container or not scroll_container._is_scrollable then return end
            local focused = self:getFocusItem()
            if not focused or not focused.dimen then return end
            local c_dimen = scroll_container.dimen
            if not c_dimen or not c_dimen.h or c_dimen.h <= 0 then return end
            local item_top = focused.dimen.y
            local item_bottom = focused.dimen.y + (focused.dimen.h or 0)
            local view_top = c_dimen.y
            local view_bottom = c_dimen.y + c_dimen.h

            if item_top < view_top then
                scroll_container:_scrollBy(0, item_top - view_top)
                UIManager:setDirty(self, "fast")
            elseif item_bottom > view_bottom then
                scroll_container:_scrollBy(0, item_bottom - view_bottom)
                UIManager:setDirty(self, "fast")
            end
        end

        overlay.onFocusMove = function(self, args)
            local handled = FocusManager.onFocusMove(self, args)
            self:_ensureFocusedVisible()
            return handled
        end

        if prev_selected or Device:hasDPad() then
            local target_item = layout[target_y] and layout[target_y][target_x]
            if target_item then
                if target_item.onFocus then
                    target_item:onFocus()
                elseif target_item.handleEvent then
                    target_item:handleEvent(Event:new("Focus"))
                end
            end
        end

        if is_scrollable and prev_scroll_y > 0 and scroll_container.setScrolledOffset then
            scroll_container:setScrolledOffset{ x = 0, y = prev_scroll_y }
        end

        overlay.onClose = function()
            overlay = nil
            if on_close_callback then
                on_close_callback()
            end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh(initial_selected)
end

return StorefrontScreensaverConfig
