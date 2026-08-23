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
local StorefrontUtils = require("storefront_utils")
local logger = require("logger")

local StorefrontFolderPicker = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs then
        return lfs
    end
    return nil
end

function StorefrontFolderPicker.getParentPath(path)
    if not path or path == "" or path == "/" then
        return nil
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean == "" or clean == "/" then
        return nil
    end
    local parent = clean:match("^(.-)[/\\]+[^/\\]+$")
    if not parent or parent == "" then
        if clean:match("^/[^/]+$") then
            return "/"
        elseif clean:match("^[a-zA-Z]:$") then
            return nil
        end
        return "/"
    end
    return parent
end

function StorefrontFolderPicker.scanDirectory(path)
    local subdirs = {}
    local image_count = 0
    local lfs = getLfs()

    if not lfs or not lfs.dir then
        return subdirs, image_count
    end

    pcall(function()
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                local full_path = (path == "/" and "/" .. entry) or (path .. "/" .. entry)
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                if ok_attr and attr and attr.mode == "directory" then
                    table.insert(subdirs, {
                        name = entry,
                        path = full_path,
                        mtime = (attr and attr.modification) or 0,
                    })
                elseif ok_attr and attr and attr.mode == "file" then
                    local lower = entry:lower()
                    if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                        image_count = image_count + 1
                    end
                end
            end
        end
    end)

    table.sort(subdirs, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    return subdirs, image_count
end

function StorefrontFolderPicker.show(options)
    options = options or {}
    local title_text = options.title or _("Select Folder")
    local current_path = options.initial_path
    local current_page = 1

    if not current_path or current_path == "" then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/tmp/koreader"
    end
    current_path = tostring(current_path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if current_path == "" then
        current_path = "/"
    end

    local lfs = getLfs()
    if lfs and lfs.attributes then
        local ok_attr, attr = pcall(lfs.attributes, current_path)
        if not ok_attr or not attr or attr.mode ~= "directory" then
            local ok_ds, DataStorage = pcall(require, "datastorage")
            current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
        end
    end

    local on_confirm = options.on_confirm
    local on_cancel = options.on_cancel

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(460))
    local max_dialog_h = math.min(sh - sc(30), sc(760))

    local overlay
    local refresh

    local function closePicker()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_cancel then
            on_cancel()
        end
    end

    local function confirmPicker()
        local chosen = current_path
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_confirm then
            on_confirm(chosen)
        end
    end

    local function promptNewFolder()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("New Folder"),
            description = string.format(_("Create subfolder in '%s':"), current_path),
            input = "",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("Create"),
                        is_enter_default = true,
                        callback = function()
                            local folder_name = dialog:getInputText()
                            UIManager:close(dialog)
                            if folder_name and folder_name ~= "" and not folder_name:match("[/\\%:%*%?%\"%<%>%|]") then
                                local new_dir = (current_path == "/" and "/" .. folder_name) or (current_path .. "/" .. folder_name)
                                local lfs_mod = getLfs()
                                if lfs_mod and lfs_mod.mkdir then
                                    local ok_mk = pcall(lfs_mod.mkdir, new_dir)
                                    if ok_mk then
                                        current_path = new_dir
                                        current_page = 1
                                        refresh()
                                        local StorefrontToast = require("storefront_toast")
                                        StorefrontToast.show(string.format(_("Created '%s'"), folder_name), 2)
                                        return
                                    end
                                end
                            end
                            local StorefrontToast = require("storefront_toast")
                            StorefrontToast.show(_("Failed to create folder."), 2)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        if dialog.onShowKeyboard then
            dialog:onShowKeyboard()
        end
    end

    local function make_row_item(frame, callback)
        local item = InputContainer:new{ frame }
        item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        return item.dimen or (frame.getSize and frame:getSize()) or Geom:new{ w = dialog_w, h = sc(40) }
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
        local ok, err = pcall(function()
            if overlay then
                local ov = overlay
                overlay = nil
                ov.onClose = nil
                UIManager:close(ov, "ui")
            end

            local available_h = sh - sc(24)
            local title_font_size = (available_h >= sc(650)) and 20 or ((available_h >= sc(520)) and 18 or 16)
            local ui_font_size = (available_h >= sc(650)) and 15 or ((available_h >= sc(520)) and 14 or 13)
            local subtext_font_size = (available_h >= sc(650)) and 13 or ((available_h >= sc(520)) and 12 or 11)
            local btn_font_size = (available_h >= sc(650)) and 14 or ((available_h >= sc(520)) and 13 or 12)
            local close_h = (available_h >= sc(650)) and sc(38) or ((available_h >= sc(520)) and sc(34) or sc(30))
            local row_pad_v = (available_h >= sc(650)) and sc(6) or sc(4)

            local subdirs, image_count = StorefrontFolderPicker.scanDirectory(current_path)
            local parent_path = StorefrontFolderPicker.getParentPath(current_path)

            -- Calculate items per page
            local fixed_header_h = sc(130)
            local fixed_footer_h = close_h + sc(50)
            local available_list_h = math.max(sc(180), max_dialog_h - fixed_header_h - fixed_footer_h)
            local row_h = (ui_font_size + subtext_font_size) + (row_pad_v * 2) + sc(14)
            local items_per_page = math.max(4, math.min(7, math.floor((available_list_h - (parent_path and row_h or 0)) / row_h)))

            local total_items = #subdirs
            local total_pages = math.max(1, math.ceil(total_items / items_per_page))
            if current_page > total_pages then current_page = total_pages end
            if current_page < 1 then current_page = 1 end

            -- Title Row
            local title_label = TextWidget:new{
                text = title_text,
                face = Font:getFace("NotoSerif-Regular.ttf", title_font_size) or Font:getFace("cfont", title_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local title_close_btn = Button:new{
                text = "X",
                face = Font:getFace("cfont", title_font_size),
                bordersize = 0,
                padding = sc(4),
                padding_h = sc(8),
                background = Blitbuffer.COLOR_WHITE,
                callback = closePicker,
            }

            local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(150)
            local close_btn_w = (title_close_btn.getSize and title_close_btn:getSize().w) or sc(30)
            local header_avail_w = dialog_w - sc(24)

            local title_row = HorizontalGroup:new{
                title_label,
                HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - title_left_w - close_btn_w) },
                title_close_btn,
            }

            local title_container = FrameContainer:new{
                padding = sc(8),
                padding_left = sc(12),
                bordersize = 0,
                width = dialog_w - sc(4),
                title_row,
            }

            local content_vg = VerticalGroup:new{
                align = "left",
                title_container,
                LineWidget:new{
                    dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                    background = Blitbuffer.COLOR_BLACK,
                },
            }

            -- Current Location Header Bar
            local path_display_text = current_path
            local path_label = TextBoxWidget:new{
                text = path_display_text,
                face = Font:getFace("cfont", ui_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = dialog_w - sc(28),
            }

            local count_text = string.format(_("%d wallpapers found in this folder"), image_count)
            local count_label = TextWidget:new{
                text = count_text,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }

            local path_header_vg = VerticalGroup:new{
                align = "left",
                path_label,
                VerticalSpan:new{ width = sc(2) },
                count_label,
            }

            local path_header_frame = FrameContainer:new{
                padding = sc(8),
                padding_left = sc(10),
                padding_right = sc(10),
                bordersize = 0,
                width = dialog_w - sc(4),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                path_header_vg,
            }

            table.insert(content_vg, path_header_frame)
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_DARK_GRAY,
            })

            -- Parent Directory Row (Pinned above folder list if not at root)
            if parent_path then
                local up_title = TextWidget:new{
                    text = _(".. (Parent Folder)"),
                    face = Font:getFace("cfont", ui_font_size),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local up_desc = TextWidget:new{
                    text = parent_path,
                    face = Font:getFace("cfont", subtext_font_size),
                    fgcolor = storefront_theme.color_label_dim,
                }

                local up_text_vg = VerticalGroup:new{
                    align = "left",
                    up_title,
                    VerticalSpan:new{ width = sc(1) },
                    up_desc,
                }

                local up_icon = TextWidget:new{
                    text = "<",
                    face = Font:getFace("cfont", ui_font_size + 2),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local up_hg = HorizontalGroup:new{
                    up_icon,
                    HorizontalSpan:new{ width = sc(8) },
                    up_text_vg,
                }

                local up_frame = FrameContainer:new{
                    padding = row_pad_v,
                    padding_left = sc(12),
                    padding_right = sc(10),
                    bordersize = 0,
                    width = dialog_w - sc(4),
                    up_hg,
                }

                table.insert(content_vg, make_row_item(up_frame, function()
                    current_path = parent_path
                    current_page = 1
                    refresh()
                end))

                table.insert(content_vg, LineWidget:new{
                    dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end

            -- Paginated Folder List
            if total_items == 0 then
                local empty_label = TextBoxWidget:new{
                    text = _("No subfolders in this directory.\nTap 'Select Folder' below to use it, or '+ New' to create a subfolder."),
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = storefront_theme.color_label_dim,
                    width = dialog_w - sc(40),
                    alignment = "center",
                }
                local empty_frame = FrameContainer:new{
                    padding = sc(24),
                    bordersize = 0,
                    width = dialog_w - sc(4),
                    CenterContainer:new{
                        dimen = Geom:new{ w = dialog_w - sc(40), h = sc(120) },
                        empty_label,
                    }
                }
                table.insert(content_vg, empty_frame)
            else
                local start_idx = (current_page - 1) * items_per_page + 1
                local end_idx = math.min(total_items, current_page * items_per_page)

                for i = start_idx, end_idx do
                    local subdir = subdirs[i]
                    local name_w = TextWidget:new{
                        text = subdir.name,
                        face = Font:getFace("cfont", ui_font_size),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }

                    local info_w = TextWidget:new{
                        text = _("Folder"),
                        face = Font:getFace("cfont", subtext_font_size),
                        fgcolor = storefront_theme.color_label_dim,
                    }

                    local text_col = VerticalGroup:new{
                        align = "left",
                        name_w,
                        VerticalSpan:new{ width = sc(1) },
                        info_w,
                    }

                    local chevron_w = TextWidget:new{
                        text = ">",
                        face = Font:getFace("cfont", ui_font_size + 2),
                        bold = true,
                        fgcolor = storefront_theme.color_label_dim,
                    }

                    local left_w = (text_col.getSize and text_col:getSize().w) or sc(100)
                    local chev_w = (chevron_w.getSize and chevron_w:getSize().w) or sc(16)
                    local avail_row_w = dialog_w - sc(30)
                    local span_w = math.max(sc(6), avail_row_w - left_w - chev_w)

                    local row_hg = HorizontalGroup:new{
                        text_col,
                        HorizontalSpan:new{ width = span_w },
                        chevron_w,
                    }

                    local row_frame = FrameContainer:new{
                        padding = row_pad_v,
                        padding_left = sc(12),
                        padding_right = sc(10),
                        bordersize = 0,
                        width = dialog_w - sc(4),
                        row_hg,
                    }

                    table.insert(content_vg, make_row_item(row_frame, function()
                        current_path = subdir.path
                        current_page = 1
                        refresh()
                    end))

                    table.insert(content_vg, LineWidget:new{
                        dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                    })
                end
            end

            -- Pagination Controls (When more than 1 page exists)
            if total_pages > 1 then
                local is_prev_active = (current_page > 1)
                local is_next_active = (current_page < total_pages)
                local pag_btn_w = sc(48)

                local prev_btn = Button:new{
                    text = "<",
                    text_font_size = 18,
                    bold = true,
                    bordersize = sc(1),
                    color = is_prev_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                    radius = sc(3),
                    padding = sc(3),
                    width = pag_btn_w,
                    background = is_prev_active and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(240),
                    text_font_color = is_prev_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(160),
                    callback = function()
                        if current_page > 1 then
                            current_page = current_page - 1
                            refresh()
                        end
                    end,
                }

                local page_text = TextWidget:new{
                    text = string.format(_("Page %d of %d"), current_page, total_pages),
                    face = Font:getFace("cfont", 14),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local next_btn = Button:new{
                    text = ">",
                    text_font_size = 18,
                    bold = true,
                    bordersize = sc(1),
                    color = is_next_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                    radius = sc(3),
                    padding = sc(3),
                    width = pag_btn_w,
                    background = is_next_active and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(240),
                    text_font_color = is_next_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(160),
                    callback = function()
                        if current_page < total_pages then
                            current_page = current_page + 1
                            refresh()
                        end
                    end,
                }

                local pag_hg = HorizontalGroup:new{
                    prev_btn,
                    HorizontalSpan:new{ width = sc(16) },
                    page_text,
                    HorizontalSpan:new{ width = sc(16) },
                    next_btn,
                }

                local pag_frame = FrameContainer:new{
                    padding = sc(6),
                    bordersize = 0,
                    width = dialog_w - sc(4),
                    CenterContainer:new{
                        dimen = Geom:new{ w = dialog_w - sc(20), h = sc(32) },
                        pag_hg,
                    }
                }
                table.insert(content_vg, pag_frame)
            end

            -- Bottom Toolbar (Cancel, + New Folder, Select Folder)
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_DARK_GRAY,
            })

            local btn_gap = sc(8)
            local total_btns_w = dialog_w - sc(20)
            local cancel_str = _("Cancel")
            local new_folder_str = _("+ New")
            local select_str = _("Select Folder")

            local dyn_btn_font_size = StorefrontUtils.calcGroupFontSize(
                { cancel_str, new_folder_str, select_str },
                total_btns_w,
                btn_gap,
                "cfont",
                sc(16),
                btn_font_size,
                10
            )

            local btn_widths = StorefrontUtils.calcProportionalBtnWidths(
                { cancel_str, new_folder_str, select_str },
                total_btns_w,
                btn_gap,
                dyn_btn_font_size,
                "cfont"
            )

            local cancel_btn = StorefrontUtils.createButton{
                text = cancel_str,
                text_font_size = dyn_btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = sc(4),
                width = btn_widths[1],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = closePicker,
            }

            local new_btn = StorefrontUtils.createButton{
                text = new_folder_str,
                text_font_size = dyn_btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = sc(4),
                width = btn_widths[2],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = promptNewFolder,
            }

            local select_btn = StorefrontUtils.createButton{
                text = select_str,
                text_font_size = dyn_btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = sc(4),
                width = btn_widths[3],
                height = close_h,
                background = Blitbuffer.COLOR_BLACK,
                text_font_color = Blitbuffer.COLOR_WHITE,
                callback = confirmPicker,
            }

            local btn_row = FrameContainer:new{
                padding = sc(6),
                bordersize = 0,
                width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = total_btns_w, h = close_h },
                    HorizontalGroup:new{
                        cancel_btn,
                        HorizontalSpan:new{ width = btn_gap },
                        new_btn,
                        HorizontalSpan:new{ width = btn_gap },
                        select_btn,
                    }
                }
            }
            table.insert(content_vg, btn_row)

            local card = FrameContainer:new{
                padding = 0,
                radius = storefront_theme.radius_window or 0,
                bordersize = sc(2),
                color = Blitbuffer.COLOR_BLACK,
                background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
                width = dialog_w,
                content_vg,
            }

            local key_events = {
                Close = { { "Back" } },
                NextPage = {
                    { "Right" },
                    { "PageDown" },
                    { "Down" },
                },
                PrevPage = {
                    { "Left" },
                    { "PageUp" },
                    { "Up" },
                },
            }

            local Device_input = Device.input
            if Device_input and Device_input.group then
                if Device_input.group.PgFwd then
                    table.insert(key_events.NextPage, { Device_input.group.PgFwd })
                end
                if Device_input.group.PgBack then
                    table.insert(key_events.PrevPage, { Device_input.group.PgBack })
                end
                if Device_input.group.Back then
                    table.insert(key_events.Close, { Device_input.group.Back })
                end
            end

            overlay = InputContainer:new{
                align = "center",
                vertical_align = "center",
                dimen = Geom:new{ w = sw, h = sh },
                key_events = key_events,
                ges_events = {
                    Swipe = {
                        GestureRange:new{
                            ges = "swipe",
                            range = function() return Geom:new{ w = sw, h = sh } end,
                        }
                    }
                },
                card,
            }

            overlay.onNextPage = function()
                if current_page < total_pages then
                    current_page = current_page + 1
                    refresh()
                    return true
                end
            end

            overlay.onPrevPage = function()
                if current_page > 1 then
                    current_page = current_page - 1
                    refresh()
                    return true
                end
            end

            overlay.onSwipe = function(self, arg, ges)
                if ges and (ges.direction == "west" or ges.direction == "south") then
                    if current_page < total_pages then
                        current_page = current_page + 1
                        refresh()
                        return true
                    end
                elseif ges and (ges.direction == "east" or ges.direction == "north") then
                    if current_page > 1 then
                        current_page = current_page - 1
                        refresh()
                        return true
                    end
                end
            end

            overlay.onClose = function()
                if parent_path then
                    current_path = parent_path
                    current_page = 1
                    refresh()
                else
                    closePicker()
                end
                return true
            end

            UIManager:show(overlay, "ui")
        end)
        if not ok then
            logger.err("StorefrontFolderPicker refresh error: " .. tostring(err))
            if on_cancel then
                on_cancel()
            end
        end
    end

    refresh()
end

return StorefrontFolderPicker
