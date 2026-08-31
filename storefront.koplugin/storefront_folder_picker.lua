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
local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = { line = { thin = 1, medium = 2, thick = 3 } }
end
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

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local ok_ffiu, ffiutil = pcall(require, "ffi/util")
    local lfs_mod = getLfs()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local rel_path = dir .. "assets/" .. filename
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or ""
    local paths_to_try = {
        rel_path,
        (data_dir ~= "") and (data_dir .. "/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/storefront.koplugin/assets/" .. filename) or nil,
    }
    for _, p in ipairs(paths_to_try) do
        if p then
            if ok_ffiu and ffiutil and ffiutil.realpath then
                local rp = ffiutil.realpath(p)
                if rp and lfs_mod and lfs_mod.attributes and lfs_mod.attributes(rp, "mode") == "file" then
                    _asset_path_cache[filename] = rp
                    return rp
                end
            elseif lfs_mod and lfs_mod.attributes and lfs_mod.attributes(p, "mode") == "file" then
                _asset_path_cache[filename] = p
                return p
            end
        end
    end
    local fallback = dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

local function getTextWidth(text, face, bold)
    if not text or text == "" then return 0 end
    local tw = TextWidget:new{ text = text, face = face, bold = bold }
    local sz = tw.getSize and tw:getSize()
    if sz and sz.w then
        return sz.w
    end
    return #text * 8
end

local function truncateToWidth(text, max_w, face, bold, ellipsis)
    ellipsis = ellipsis or "..."
    if getTextWidth(text, face, bold) <= max_w then
        return text
    end
    local ellip_w = getTextWidth(ellipsis, face, bold)
    local avail_w = max_w - ellip_w
    if avail_w <= 0 then
        return ellipsis
    end

    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(chars, c)
    end
    if #chars == 0 then return ellipsis end

    local low = 1
    local high = #chars
    local best = 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local sub = table.concat(chars, "", 1, mid)
        if getTextWidth(sub, face, bold) <= avail_w then
            best = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if best == 0 then
        return ellipsis
    end
    return table.concat(chars, "", 1, best) .. ellipsis
end

local function formatTwoLinesMax(text, max_w, face, bold)
    if not text or text == "" then return "" end
    text = text:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$") or ""
    if getTextWidth(text, face, bold) <= max_w then
        return text
    end

    -- Find split point for Line 1
    local words = {}
    for w in text:gmatch("%S+") do
        table.insert(words, w)
    end

    local line1 = ""
    local line1_word_count = 0

    if #words > 1 then
        for i, w in ipairs(words) do
            local test_line = (line1 == "") and w or (line1 .. " " .. w)
            if getTextWidth(test_line, face, bold) <= max_w then
                line1 = test_line
                line1_word_count = i
            else
                break
            end
        end
    end

    local remainder = ""
    if line1_word_count > 0 and line1_word_count < #words then
        local rem_words = {}
        for i = line1_word_count + 1, #words do
            table.insert(rem_words, words[i])
        end
        remainder = table.concat(rem_words, " ")
    else
        -- Break Line 1 by character if no multi-word fit was found
        local chars = {}
        for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(chars, c)
        end
        local low = 1
        local high = #chars
        local best = 1
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local sub = table.concat(chars, "", 1, mid)
            if getTextWidth(sub, face, bold) <= max_w then
                best = mid
                low = mid + 1
            else
                high = mid - 1
            end
        end
        line1 = table.concat(chars, "", 1, best)
        if best < #chars then
            remainder = table.concat(chars, "", best + 1):match("^%s*(.-)%s*$") or ""
        else
            remainder = ""
        end
    end

    if remainder == "" then
        return line1
    end

    -- Line 2: remainder if it fits, or truncated with "..."
    local line2
    if getTextWidth(remainder, face, bold) <= max_w then
        line2 = remainder
    else
        line2 = truncateToWidth(remainder, max_w, face, bold, "...")
    end

    return line1 .. "\n" .. line2
end

StorefrontFolderPicker.getTextWidth = getTextWidth
StorefrontFolderPicker.truncateToWidth = truncateToWidth
StorefrontFolderPicker.formatTwoLinesMax = formatTwoLinesMax

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
            local fallback = options.fallback_path
            if fallback and fallback ~= "" then
                fallback = tostring(fallback):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
                local ok_fb, fb_attr = pcall(lfs.attributes, fallback)
                if ok_fb and fb_attr and fb_attr.mode == "directory" then
                    current_path = fallback
                else
                    local ok_ds, DataStorage = pcall(require, "datastorage")
                    current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
                end
            else
                local ok_ds, DataStorage = pcall(require, "datastorage")
                current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
            end
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
                        return item.dimen or (frame.getSize and frame:getSize()) or Geom:new{ w = dialog_w, h = sc(40) }
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
            local row_h = (ui_font_size * 2 + subtext_font_size) + (row_pad_v * 2) + sc(14)
            local items_per_page = math.max(4, math.min(7, math.floor((available_list_h - (parent_path and row_h or 0)) / row_h)))

            local total_items = #subdirs
            local total_pages = math.max(1, math.ceil(total_items / items_per_page))
            if current_page > total_pages then current_page = total_pages end
            if current_page < 1 then current_page = 1 end

            local card_padding = sc(10)
            local card_border = storefront_theme.border_window or sc(2)
            local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

            -- Title Row
            local title_label = TextWidget:new{
                text = title_text,
                face = Font:getFace("NotoSerif-Regular.ttf", title_font_size) or Font:getFace("cfont", title_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local close_icon = ImageWidget:new{
                file = getAssetPath("x.svg"),
                width = sc(22),
                height = sc(22),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }

            local close_frame = FrameContainer:new{
                padding = sc(4),
                padding_h = sc(6),
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                close_icon,
            }

            local title_close_btn = make_row_item(close_frame, closePicker)

            local title_sz = title_label.getSize and title_label:getSize()
            local title_left_w = (title_sz and title_sz.w) or sc(150)
            local close_sz = title_close_btn.getSize and title_close_btn:getSize()
            local close_btn_w = (close_sz and close_sz.w) or sc(34)
            local header_avail_w = inner_w

            local title_row = HorizontalGroup:new{
                align = "center",
                title_label,
                HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - title_left_w - close_btn_w) },
                title_close_btn,
            }

            local content_vg = VerticalGroup:new{
                align = "left",
                title_row,
                VerticalSpan:new{ width = sc(6) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = storefront_theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(6) },
            }

            -- Current Location Header Bar
            local path_display_text = current_path
            local path_label = TextBoxWidget:new{
                text = path_display_text,
                face = Font:getFace("cfont", ui_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w - sc(16),
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
                padding = sc(6),
                padding_left = sc(8),
                padding_right = sc(8),
                radius = storefront_theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                path_header_vg,
            }

            table.insert(content_vg, path_header_frame)
            table.insert(content_vg, VerticalSpan:new{ width = sc(4) })

            -- Parent Directory Row (Pinned above folder list if not at root)
            if parent_path then
                local up_icon_reserved = sc(32)
                local max_desc_w = inner_w - sc(16) - up_icon_reserved

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
                    width = max_desc_w,
                }

                local up_text_vg = VerticalGroup:new{
                    align = "left",
                    up_title,
                    VerticalSpan:new{ width = sc(1) },
                    up_desc,
                }

                local up_icon = ImageWidget:new{
                    file = getAssetPath("chevron-left.svg"),
                    width = sc(20),
                    height = sc(20),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                local up_hg = HorizontalGroup:new{
                    align = "center",
                    up_icon,
                    HorizontalSpan:new{ width = sc(8) },
                    up_text_vg,
                }

                local up_frame = FrameContainer:new{
                    padding = row_pad_v,
                    padding_left = sc(6),
                    padding_right = sc(6),
                    bordersize = 0,
                    width = inner_w,
                    up_hg,
                }

                table.insert(content_vg, make_row_item(up_frame, function()
                    current_path = parent_path
                    current_page = 1
                    refresh()
                end))

                table.insert(content_vg, LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = Size.line.thin },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end

            -- Paginated Folder List
            if total_items == 0 then
                local empty_label = TextBoxWidget:new{
                    text = _("No subfolders in this directory.\nTap 'Select Folder' below to use it, or '+ New' to create a subfolder."),
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = storefront_theme.color_label_dim,
                    width = inner_w - sc(20),
                    alignment = "center",
                }
                local empty_frame = FrameContainer:new{
                    padding = sc(24),
                    bordersize = 0,
                    width = inner_w,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w - sc(20), h = sc(120) },
                        empty_label,
                    }
                }
                table.insert(content_vg, empty_frame)
            else
                local start_idx = (current_page - 1) * items_per_page + 1
                local end_idx = math.min(total_items, current_page * items_per_page)

                for i = start_idx, end_idx do
                    local subdir = subdirs[i]
                    local chev_reserved = sc(30)
                    local max_name_w = inner_w - sc(16) - chev_reserved
                    local name_face = Font:getFace("cfont", ui_font_size)
                    local formatted_name = formatTwoLinesMax(subdir.name, max_name_w, name_face, true)

                    local name_w = TextBoxWidget:new{
                        text = formatted_name,
                        face = name_face,
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        width = max_name_w,
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

                    local chevron_w = ImageWidget:new{
                        file = getAssetPath("chevron-right.svg"),
                        width = sc(20),
                        height = sc(20),
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }

                    local left_sz = text_col.getSize and text_col:getSize()
                    local left_w = (left_sz and left_sz.w) or sc(100)
                    local chev_sz = chevron_w.getSize and chevron_w:getSize()
                    local chev_w = (chev_sz and chev_sz.w) or sc(20)
                    local avail_row_w = inner_w - sc(16)
                    local span_w = math.max(sc(6), avail_row_w - left_w - chev_w)

                    local row_hg = HorizontalGroup:new{
                        align = "center",
                        text_col,
                        HorizontalSpan:new{ width = span_w },
                        chevron_w,
                    }

                    local row_frame = FrameContainer:new{
                        padding = row_pad_v,
                        padding_left = sc(6),
                        padding_right = sc(6),
                        bordersize = 0,
                        width = inner_w,
                        row_hg,
                    }

                    table.insert(content_vg, make_row_item(row_frame, function()
                        current_path = subdir.path
                        current_page = 1
                        refresh()
                    end))

                    table.insert(content_vg, LineWidget:new{
                        dimen = Geom:new{ w = inner_w, h = Size.line.thin },
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                    })
                end
            end

            -- Pagination Controls (When more than 1 page exists)
            if total_pages > 1 then
                local is_prev_active = (current_page > 1)
                local is_next_active = (current_page < total_pages)

                local function makePagIconBtn(icon_file, is_active, callback)
                    local icon = ImageWidget:new{
                        file = getAssetPath(icon_file),
                        width = sc(20),
                        height = sc(20),
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                        dimmed = not is_active,
                    }
                    local frame = FrameContainer:new{
                        padding = sc(4),
                        padding_left = sc(12),
                        padding_right = sc(12),
                        bordersize = sc(1),
                        radius = sc(3),
                        color = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                        background = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(240),
                        icon,
                    }
                    return make_row_item(frame, is_active and callback or nil)
                end

                local prev_btn = makePagIconBtn("chevron-left.svg", is_prev_active, function()
                    if current_page > 1 then
                        current_page = current_page - 1
                        refresh()
                    end
                end)

                local page_text = TextWidget:new{
                    text = string.format(_("Page %d of %d"), current_page, total_pages),
                    face = Font:getFace("cfont", 14),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local next_btn = makePagIconBtn("chevron-right.svg", is_next_active, function()
                    if current_page < total_pages then
                        current_page = current_page + 1
                        refresh()
                    end
                end)

                local pag_hg = HorizontalGroup:new{
                    align = "center",
                    prev_btn,
                    HorizontalSpan:new{ width = sc(16) },
                    page_text,
                    HorizontalSpan:new{ width = sc(16) },
                    next_btn,
                }

                local pag_frame = FrameContainer:new{
                    padding = sc(4),
                    bordersize = 0,
                    width = inner_w,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w, h = sc(32) },
                        pag_hg,
                    }
                }
                table.insert(content_vg, pag_frame)
            end

            -- Bottom Toolbar (Cancel, + New Folder, Select Folder)
            table.insert(content_vg, VerticalSpan:new{ width = sc(4) })
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = storefront_theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            })
            table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

            local btn_gap = sc(8)
            local total_btns_w = inner_w
            local cancel_str = _("Cancel")
            local new_folder_str = _("+ New")
            local select_str = _("Select Folder")

            local btn_widths = StorefrontUtils.calcProportionalBtnWidths(
                { cancel_str, new_folder_str, select_str },
                total_btns_w,
                btn_gap,
                btn_font_size,
                "cfont"
            )

            local cancel_btn = StorefrontUtils.createButton{
                text = cancel_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = storefront_theme.radius_btn or sc(4),
                width = btn_widths[1],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = closePicker,
            }

            local new_btn = StorefrontUtils.createButton{
                text = new_folder_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = storefront_theme.radius_btn or sc(4),
                width = btn_widths[2],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = promptNewFolder,
            }

            local select_btn = StorefrontUtils.createButton{
                text = select_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = storefront_theme.radius_btn or sc(4),
                width = btn_widths[3],
                height = close_h,
                background = Blitbuffer.COLOR_BLACK,
                text_font_color = Blitbuffer.COLOR_WHITE,
                callback = confirmPicker,
            }

            local btn_row = FrameContainer:new{
                padding = 0,
                bordersize = 0,
                width = inner_w,
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
                padding = card_padding,
                radius = storefront_theme.radius_window or sc(4),
                bordersize = card_border,
                color = Blitbuffer.COLOR_BLACK,
                background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
                width = dialog_w,
                content_vg,
            }

            local layout = {}
            for _, item in ipairs(focusable_rows) do
                table.insert(layout, { item })
            end
            table.insert(layout, { cancel_btn, new_btn, select_btn })

            local key_events = {
                Close = { { "Back" }, { "Escape" } },
                NextPage = {
                    { "PageDown" },
                },
                PrevPage = {
                    { "PageUp" },
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

            overlay = FocusManager:new{
                align = "center",
                vertical_align = "center",
                dimen = Geom:new{ w = sw, h = sh },
                layout = layout,
                selected = { x = 1, y = 1 },
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

            for _, item in ipairs(focusable_rows) do
                item.show_parent = overlay
            end
            cancel_btn.show_parent = overlay
            new_btn.show_parent = overlay
            select_btn.show_parent = overlay

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
