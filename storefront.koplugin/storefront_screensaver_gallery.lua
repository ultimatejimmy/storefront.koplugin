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

local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
local Input = Device and Device.input

local StorefrontScreensaverGallery = {}

local ITEMS_PER_PAGE = 5

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function formatSize(bytes)
    if not bytes or bytes <= 0 then return "0 KB" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%d KB", math.ceil(bytes / 1024))
    end
end

function StorefrontScreensaverGallery.show(Storefront, on_close_callback, on_settings_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(440))

    local overlay
    local refresh
    local current_page = 1

    local function closeGallery()
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

    local function openConfig()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_settings_callback then
            on_settings_callback()
        else
            local StorefrontScreensaverConfig = require("storefront_screensaver_config")
            StorefrontScreensaverConfig.show(Storefront, on_close_callback)
        end
    end

    local FocusManager = require("ui/widget/focusmanager")
    local focusable_rows = {}

    local function make_tap_item(frame, callback)
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
        item.isFocusable = function(self) return true end
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
            if self.callback then self.callback() end
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

        local items = StorefrontScreensaverMgr.listLocalScreensavers()
        local settings = StorefrontScreensaverMgr.getScreensaverSettings()
        local is_single_mode = (settings.effective_mode == "single")

        local total_pages = math.max(1, math.ceil(#items / ITEMS_PER_PAGE))
        if current_page > total_pages then
            current_page = total_pages
        end
        if current_page < 1 then
            current_page = 1
        end

        -- Header
        local title_label = TextWidget:new{
            text = _("Wallpaper Collection"),
            face = Font:getFace("NotoSerif-Regular.ttf", storefront_theme.title_font_size or 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local mode_desc
        if settings.effective_mode == "shuffle" then
            mode_desc = string.format(_("%d wallpapers · Folder Shuffle (all in rotation)"), #items)
        elseif settings.effective_mode == "single" then
            mode_desc = string.format(_("%d wallpapers · Single mode active"), #items)
        elseif settings.effective_mode == "cover" then
            mode_desc = string.format(_("%d wallpapers · Mode: Book Cover"), #items)
        else
            mode_desc = string.format(_("%d wallpapers stored on device"), #items)
        end

        local count_label = TextWidget:new{
            text = mode_desc,
            face = Font:getFace("cfont", 13),
            fgcolor = storefront_theme.color_label_dim,
        }

        local header_left = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(2) },
            count_label,
        }

        local header_close_btn = Button:new{
            text = "✕",
            text_font_size = 18,
            bold = true,
            bordersize = 0,
            padding = sc(6),
            padding_h = sc(12),
            background = Blitbuffer.COLOR_WHITE,
            callback = closeGallery,
        }

        local header_left_w = header_left:getSize().w
        local close_btn_w = header_close_btn:getSize().w
        local header_avail_w = dialog_w - sc(24)

        local header_row = HorizontalGroup:new{
            header_left,
            HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - header_left_w - close_btn_w) },
            header_close_btn,
        }

        local header_frame = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            width = dialog_w - sc(4),
            header_row,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            header_frame,
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            }
        }

        local list_vg = VerticalGroup:new{ align = "left" }
        local row_pad_h = sc(8)
        local row_pad_v = sc(6)
        local thumb_w = sc(48)
        local thumb_h = sc(64)
        local btn_col_w = sc(88)
        local btn_h = sc(25)
        local gap = sc(8)
        local mid_w = dialog_w - sc(4) - (row_pad_h * 2) - thumb_w - btn_col_w - (gap * 2) - sc(2)
        local fixed_list_h = sc(395) -- Exact height for 5 item rows

        local function make_action_btn(label_str, bg_color, fg_color, callback)
            return StorefrontUtils.createButton{
                text = label_str,
                text_font_size = 12,
                bold = true,
                bordersize = storefront_theme.border_btn or sc(1),
                radius = sc(4),
                width = btn_col_w,
                height = btn_h,
                background = bg_color,
                text_font_color = fg_color,
                callback = callback,
            }
        end

        if #items == 0 then
            local empty_text = TextBoxWidget:new{
                text = _("No wallpapers found in your screensavers folder.\n\nBrowse the Screensavers catalog in Storefront to download wallpapers!"),
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = dialog_w - sc(40),
                alignment = "center",
            }
            local empty_frame = FrameContainer:new{
                padding = sc(24),
                bordersize = 0,
                width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(40), h = fixed_list_h - sc(48) },
                    empty_text,
                }
            }
            table.insert(list_vg, empty_frame)
        else
            local start_idx = (current_page - 1) * ITEMS_PER_PAGE + 1
            local end_idx = math.min(#items, current_page * ITEMS_PER_PAGE)

            for idx = start_idx, end_idx do
                local current_item = items[idx]
                local thumb_img

                local ok_screensavers, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                local ok_img, res_img = false, nil

                -- 1. Check for pre-cached thumbnail in storefront_thumbs cache
                local ok_ds, DataStorage = pcall(require, "datastorage")
                local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp/koreader"
                local cache_dir = data_dir .. "/cache/storefront_thumbs"
                local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

                local thumb_file = current_item.thumbnail_file
                if not thumb_file and lfs and lfs.attributes then
                    for _, ext in ipairs({".png", ".jpg", ".jpeg"}) do
                        local p = cache_dir .. "/" .. tostring(current_item.id) .. ext
                        if lfs.attributes(p, "mode") == "file" then
                            thumb_file = p
                            break
                        end
                    end
                end

                if not thumb_file and ok_screensavers and StorefrontScreensavers and StorefrontScreensavers.fetchThumbnail then
                    pcall(function() thumb_file = StorefrontScreensavers.fetchThumbnail(current_item.catalog_item or current_item) end)
                end

                local source_file = thumb_file or current_item.filepath

                if ok_screensavers and StorefrontScreensavers and StorefrontScreensavers.createCoverImageWidget then
                    ok_img, res_img = pcall(function()
                        return StorefrontScreensavers.createCoverImageWidget(source_file, thumb_w, thumb_h)
                    end)
                end

                if ok_img and res_img then
                    thumb_img = res_img
                else
                    thumb_img = FrameContainer:new{
                        bordersize = sc(1),
                        color = Blitbuffer.COLOR_GRAY,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        width = thumb_w,
                        height = thumb_h,
                        CenterContainer:new{
                            dimen = Geom:new{ w = thumb_w, h = thumb_h },
                            TextWidget:new{ text = "🖼", face = Font:getFace("cfont", 16) }
                        }
                    }
                end

                local thumb_container = FrameContainer:new{
                    bordersize = sc(1),
                    color = Blitbuffer.COLOR_DARK_GRAY,
                    padding = 0,
                    thumb_img,
                }

                local thumb_tap = make_tap_item(thumb_container, function()
                    local ok_modal, StorefrontImageModal = pcall(require, "storefront_image_modal")
                    if ok_modal and StorefrontImageModal then
                        local modal = StorefrontImageModal:new{
                            image_path = current_item.filepath,
                            title = current_item.title or current_item.filename,
                        }
                        modal:show()
                    end
                end)

                -- Middle Info Column
                local title_txt = TextWidget:new{
                    text = current_item.title or current_item.filename,
                    face = Font:getFace("NotoSerif-Regular.ttf", 15),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = mid_w,
                }

                local ext_str = current_item.filename:match("%.(%w+)$") or "image"
                local meta_str = string.format("%s · %s", formatSize(current_item.size), ext_str:upper())
                local meta_txt = TextWidget:new{
                    text = meta_str,
                    face = Font:getFace("cfont", 13),
                    fgcolor = storefront_theme.color_label_dim,
                    max_width = mid_w,
                }

                local mid_vg = VerticalGroup:new{
                    align = "left",
                    title_txt,
                    VerticalSpan:new{ width = sc(3) },
                    meta_txt,
                }

                local mid_container = FrameContainer:new{
                    padding = 0,
                    bordersize = 0,
                    width = mid_w,
                    mid_vg,
                }

                -- Right Action Buttons Column
                local right_actions_vg = VerticalGroup:new{ align = "center" }
                local is_this_active = is_single_mode and current_item.is_active_single

                if is_this_active then
                    local active_badge_frame = FrameContainer:new{
                        bordersize = sc(1),
                        color = Blitbuffer.COLOR_BLACK,
                        radius = sc(4),
                        padding = 0,
                        width = btn_col_w,
                        height = btn_h,
                        background = Blitbuffer.COLOR_BLACK,
                        CenterContainer:new{
                            dimen = Geom:new{ w = btn_col_w, h = btn_h },
                            TextWidget:new{
                                text = _("★ ACTIVE"),
                                face = Font:getFace("cfont", 11),
                                bold = true,
                                fgcolor = Blitbuffer.COLOR_WHITE,
                            }
                        }
                    }
                    table.insert(right_actions_vg, active_badge_frame)
                else
                    local set_active_btn = make_action_btn(_("Set Single"), Blitbuffer.Color8(240), Blitbuffer.COLOR_BLACK, function()
                        StorefrontScreensaverMgr.setScreensaverMode("single", { file = current_item.filepath })
                        refresh()
                        local StorefrontToast = require("storefront_toast")
                        StorefrontToast.show(_("Set as active single wallpaper!"), 2)
                    end)
                    table.insert(right_actions_vg, set_active_btn)
                end

                table.insert(right_actions_vg, VerticalSpan:new{ width = sc(4) })

                local delete_btn = make_action_btn(_("Remove"), Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK, function()
                    local StorefrontUtils = require("storefront_utils")
                    StorefrontUtils.showConfirmDialog{
                        title = _("Remove Wallpaper?"),
                        text = string.format(_("Remove '%s' from your wallpaper collection?"), current_item.title or current_item.filename),
                        ok_text = _("Remove"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            StorefrontScreensaverMgr.deleteLocalScreensaver(current_item.filepath)
                            refresh()
                            local StorefrontToast = require("storefront_toast")
                            StorefrontToast.show(_("Wallpaper removed"), 2)
                        end,
                    }
                end)
                table.insert(right_actions_vg, delete_btn)

                local left_group = HorizontalGroup:new{
                    align = "center",
                    thumb_tap,
                    HorizontalSpan:new{ width = gap },
                    mid_container,
                }

                local row_w = dialog_w - sc(4) - (row_pad_h * 2)
                local left_w = left_group:getSize().w
                local right_w = right_actions_vg:getSize().w
                local flex_span = math.max(gap, row_w - left_w - right_w)

                local row_content = HorizontalGroup:new{
                    align = "center",
                    left_group,
                    HorizontalSpan:new{ width = flex_span },
                    right_actions_vg,
                }
                local row_frame = FrameContainer:new{
                    padding_v = row_pad_v,
                    padding_h = row_pad_h,
                    bordersize = 0,
                    width = dialog_w - sc(4),
                    row_content,
                }

                table.insert(list_vg, row_frame)
                table.insert(list_vg, LineWidget:new{
                    dimen = Geom:new{ w = dialog_w - sc(4), h = Size.line.thin },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end

            -- Pad remaining slots so the list area ALWAYS occupies the exact same height
            local items_on_this_page = end_idx - start_idx + 1
            local empty_slots = ITEMS_PER_PAGE - items_on_this_page
            if empty_slots > 0 then
                local slot_h = sc(78)
                table.insert(list_vg, VerticalSpan:new{ width = empty_slots * slot_h })
            end
        end

        table.insert(content_vg, list_vg)

        -- Fixed-height Pagination Controls (always present so height is constant)
        local pag_btn_w = sc(38)
        local is_prev_active = (current_page > 1)
        local is_next_active = (current_page < total_pages)

        local prev_btn = Button:new{
            text = "‹",
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
            fgcolor = (total_pages > 1) and Blitbuffer.COLOR_BLACK or storefront_theme.color_label_dim,
        }

        local next_btn = Button:new{
            text = "›",
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

        -- Bottom Toolbar (Dual Storefront Action Buttons)
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        local btn_gap = sc(12)
        local total_btns_w = dialog_w - sc(20)
        local config_text = _("⚙ Settings")
        local close_text = _("Close")
        local btn_font_size = StorefrontUtils.calcGroupFontSize({ config_text, close_text }, total_btns_w, btn_gap, "cfont", sc(16))
        local btn_widths = StorefrontUtils.calcProportionalBtnWidths({ config_text, close_text }, total_btns_w, btn_gap, btn_font_size, "cfont")

        local config_btn = StorefrontUtils.createButton{
            text = config_text,
            text_font_size = btn_font_size,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = sc(4),
            width = btn_widths[1],
            height = sc(38),
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = openConfig,
        }

        local close_btn = StorefrontUtils.createButton{
            text = close_text,
            text_font_size = btn_font_size,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = sc(4),
            width = btn_widths[2],
            height = sc(38),
            background = Blitbuffer.COLOR_BLACK,
            text_font_color = Blitbuffer.COLOR_WHITE,
            callback = closeGallery,
        }

        local btn_row = FrameContainer:new{
            padding = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = total_btns_w, h = sc(38) },
                HorizontalGroup:new{
                    config_btn,
                    HorizontalSpan:new{ width = btn_gap },
                    close_btn,
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

        local layout = {}
        for _, item in ipairs(focusable_rows) do
            table.insert(layout, { item })
        end
        table.insert(layout, { config_btn, close_btn })

        local key_events = {
            Close = { { "Back" }, { "Escape" } },
            NextPage = {
                { "PageDown" },
            },
            PrevPage = {
                { "PageUp" },
            },
        }

        if Input and Input.group then
            if Input.group.PgFwd then
                table.insert(key_events.NextPage, { Input.group.PgFwd })
            end
            if Input.group.PgBack then
                table.insert(key_events.PrevPage, { Input.group.PgBack })
            end
            if Input.group.Back then
                table.insert(key_events.Close, { Input.group.Back })
            end
        end

        local ges_events = {
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = function() return Geom:new{ w = sw, h = sh } end,
                }
            }
        }

        overlay = FocusManager:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            layout = layout,
            selected = { x = 1, y = 1 },
            key_events = key_events,
            ges_events = ges_events,
            card,
        }

        for _, item in ipairs(focusable_rows) do
            item.show_parent = overlay
        end
        config_btn.show_parent = overlay
        close_btn.show_parent = overlay

        overlay.onNextPage = function()
            if current_page < total_pages then
                current_page = current_page + 1
                refresh()
            end
            return true
        end

        overlay.onPrevPage = function()
            if current_page > 1 then
                current_page = current_page - 1
                refresh()
            end
            return true
        end

        overlay.onSwipe = function(self, arg, ges_ev)
            local ev = (type(arg) == "table" and arg) or (type(ges_ev) == "table" and ges_ev)
            local direction = ev and ev.direction
            if direction == "left" or direction == "west" then
                return overlay.onNextPage()
            elseif direction == "right" or direction == "east" then
                return overlay.onPrevPage()
            end
            return false
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

    refresh()
end

return StorefrontScreensaverGallery
