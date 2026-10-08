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
local ImageWidget = require("ui/widget/imagewidget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")

local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
local Event = require("ui/event")
local FocusManager = require("ui/widget/focusmanager")
local Input = Device and Device.input

local StorefrontScreensaverGallery = {}

local ITEMS_PER_PAGE = 5

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

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

local function formatSize(bytes)
    if not bytes or bytes <= 0 then return "0 KB" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%d KB", math.ceil(bytes / 1024))
    end
end

function StorefrontScreensaverGallery.show(Storefront, on_close_callback, on_settings_callback, initial_selected)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(440))

    local overlay
    local refresh
    local current_page = 1
    local cached_items = nil
    local active_image_widgets = {}

    local function freeActiveWidgets()
        for _, w in ipairs(active_image_widgets) do
            if w and w.free then
                pcall(w.free, w)
            end
        end
        active_image_widgets = {}
        collectgarbage("step", 200)
    end

    local function closeGallery()
        freeActiveWidgets()
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
        local cur_selected = overlay and overlay.selected and { x = overlay.selected.x, y = overlay.selected.y }
        freeActiveWidgets()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_settings_callback then
            on_settings_callback(cur_selected)
        else
            local StorefrontScreensaverConfig = require("storefront_screensaver_config")
            StorefrontScreensaverConfig.show(Storefront, on_close_callback)
        end
    end

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

        return item
    end

    local function make_thumb_tap_item(frame, callback)
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
                self.frame.bordersize = sc(2)
                self.frame.color = Blitbuffer.COLOR_BLACK
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        item.onUnfocus = function(self)
            if self.frame then
                self.frame.bordersize = sc(1)
                self.frame.color = Blitbuffer.COLOR_DARK_GRAY
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        item.onTapSelect = function(self)
            if self.callback then self.callback() end
            return true
        end

        return item
    end


    refresh = function(saved_selected)
        local cur_selected = saved_selected or (overlay and overlay.selected and { x = overlay.selected.x, y = overlay.selected.y })
        freeActiveWidgets()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        if not cached_items then
            cached_items = StorefrontScreensaverMgr.listLocalScreensavers()
        end
        local items = cached_items
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
            face = StorefrontUtils.getTitleFace(storefront_theme.title_font_size or 22),
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
            local btn = StorefrontUtils.createButton{
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
            local orig_focus = btn.onFocus
            btn.onFocus = function(self)
                if orig_focus then orig_focus(self) elseif self.frame then self.frame.invert = true end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end
            local orig_unfocus = btn.onUnfocus
            btn.onUnfocus = function(self)
                if orig_unfocus then orig_unfocus(self) elseif self.frame then self.frame.invert = false end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end
            return btn
        end

        local layout = {}

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
                    local candidates = {
                        cache_dir .. "/" .. tostring(current_item.id) .. ".png",
                        cache_dir .. "/" .. tostring(current_item.id) .. ".jpg",
                        cache_dir .. "/" .. tostring(current_item.id) .. ".jpeg",
                    }
                    if current_item.catalog_item and current_item.catalog_item.id then
                        table.insert(candidates, cache_dir .. "/" .. tostring(current_item.catalog_item.id) .. ".png")
                        table.insert(candidates, cache_dir .. "/" .. tostring(current_item.catalog_item.id) .. ".jpg")
                        table.insert(candidates, cache_dir .. "/" .. tostring(current_item.catalog_item.id) .. ".jpeg")
                    end
                    for _, p in ipairs(candidates) do
                        local attr_t = lfs.attributes(p)
                        if attr_t and attr_t.mode == "file" and (attr_t.size or 0) > 0 then
                            thumb_file = p
                            break
                        end
                    end
                end

                -- Strict guard: load verified small thumbnail files (< 300 KB)
                local source_file = nil
                if thumb_file and lfs and lfs.attributes then
                    local attr_s = lfs.attributes(thumb_file)
                    if attr_s and attr_s.mode == "file" and (attr_s.size or 0) > 0 and (attr_s.size or 0) <= 300 * 1024 then
                        source_file = thumb_file
                    end
                end

                -- If no cached thumbnail was found, check if full local file is small enough to preview safely
                if not source_file and current_item.filepath and lfs and lfs.attributes then
                    local attr_f = lfs.attributes(current_item.filepath)
                    if attr_f and attr_f.mode == "file" and (attr_f.size or 0) > 0 and (attr_f.size or 0) <= 150 * 1024 then
                        source_file = current_item.filepath
                    end
                end

                -- If thumbnail is still missing, trigger background async download if item is in catalog
                if not source_file and ok_screensavers and StorefrontScreensavers then
                    local cat_item = current_item.catalog_item
                    if not cat_item and StorefrontScreensavers.getCachedCatalog then
                        local cat = StorefrontScreensavers.getCachedCatalog()
                        if type(cat) == "table" then
                            for _, ci in ipairs(cat) do
                                if (ci.id and tostring(ci.id):lower() == tostring(current_item.id):lower()) or
                                   (ci.filename and tostring(ci.filename):lower() == tostring(current_item.filename):lower()) then
                                    cat_item = ci
                                    current_item.catalog_item = ci
                                    break
                                end
                            end
                        end
                    end
                    if cat_item and StorefrontScreensavers.fetchThumbnailAsync then
                        pcall(StorefrontScreensavers.fetchThumbnailAsync, cat_item)
                    end
                end

                if source_file and ok_screensavers and StorefrontScreensavers and StorefrontScreensavers.createCoverImageWidget then
                    ok_img, res_img = pcall(function()
                        return StorefrontScreensavers.createCoverImageWidget(source_file, thumb_w, thumb_h)
                    end)
                end

                if ok_img and res_img then
                    thumb_img = res_img
                    table.insert(active_image_widgets, res_img)
                else
                    local placeholder_inner = nil
                    local img_svg_path = getAssetPath("image.svg")
                    if img_svg_path and ImageWidget then
                        local ok_icon, icon_w = pcall(function()
                            return ImageWidget:new{
                                file = img_svg_path,
                                width = sc(24),
                                height = sc(24),
                                scale_factor = 0,
                            }
                        end)
                        if ok_icon and icon_w then
                            placeholder_inner = icon_w
                            if icon_w.free then
                                table.insert(active_image_widgets, icon_w)
                            end
                        end
                    end
                    if not placeholder_inner then
                        placeholder_inner = TextWidget:new{
                            text = _("Screensaver"),
                            face = Font:getFace("cfont", 10),
                        }
                    end

                    thumb_img = FrameContainer:new{
                        bordersize = sc(1),
                        color = Blitbuffer.COLOR_GRAY,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        width = thumb_w,
                        height = thumb_h,
                        CenterContainer:new{
                            dimen = Geom:new{ w = thumb_w, h = thumb_h },
                            placeholder_inner,
                        }
                    }
                end

                local thumb_container = FrameContainer:new{
                    bordersize = sc(1),
                    color = Blitbuffer.COLOR_DARK_GRAY,
                    padding = 0,
                    thumb_img,
                }

                local thumb_tap = make_thumb_tap_item(thumb_container, function()
                    local ok_modal, StorefrontImageModal = pcall(require, "storefront_image_modal")
                    if ok_modal and StorefrontImageModal then
                        local modal = StorefrontImageModal:new{
                            image_path = current_item.filepath,
                            fallback_thumb = thumb_file or current_item.thumbnail_file,
                            title = current_item.title or current_item.filename,
                        }
                        if modal and modal.show then
                            modal:show()
                        end
                    end
                end)

                -- Middle Info Column
                local title_txt = TextWidget:new{
                    text = current_item.title or current_item.filename,
                    face = StorefrontUtils.getTitleFace(15),
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

                local action_item
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
                    action_item = make_tap_item(active_badge_frame, function()
                        local StorefrontToast = require("storefront_toast")
                        StorefrontToast.show(_("This wallpaper is currently active"), 2)
                    end)
                    table.insert(right_actions_vg, action_item)
                else
                    local set_active_btn = make_action_btn(_("Set Single"), Blitbuffer.Color8(240), Blitbuffer.COLOR_BLACK, function()
                        StorefrontScreensaverMgr.setScreensaverMode("single", { file = current_item.filepath })
                        cached_items = StorefrontScreensaverMgr.listLocalScreensavers()
                        refresh()
                        local StorefrontToast = require("storefront_toast")
                        StorefrontToast.show(_("Set as active single wallpaper!"), 2)
                    end)
                    table.insert(right_actions_vg, set_active_btn)
                    action_item = set_active_btn
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
                            local StorefrontToast = require("storefront_toast")
                            local ok, was_active_single = StorefrontScreensaverMgr.deleteLocalScreensaver(current_item.filepath)
                            if ok then
                                StorefrontToast.show(_("Wallpaper removed"), 2)
                                UIManager:nextTick(function()
                                    StorefrontScreensaverMgr.autoFallbackAfterDelete(was_active_single)
                                    cached_items = StorefrontScreensaverMgr.listLocalScreensavers()
                                    refresh()
                                end)
                            else
                                StorefrontToast.show(_("Could not remove wallpaper"), 2)
                            end
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

                table.insert(layout, { thumb_tap, action_item, delete_btn })
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
                    refresh({ x = 1, y = 1 })
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
                    refresh({ x = 1, y = 1 })
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

        if total_pages > 1 then
            local orig_prev_focus = prev_btn.onFocus
            prev_btn.onFocus = function(self)
                if orig_prev_focus then orig_prev_focus(self) elseif self.frame then self.frame.invert = true end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end
            local orig_prev_unfocus = prev_btn.onUnfocus
            prev_btn.onUnfocus = function(self)
                if orig_prev_unfocus then orig_prev_unfocus(self) elseif self.frame then self.frame.invert = false end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end

            local orig_next_focus = next_btn.onFocus
            next_btn.onFocus = function(self)
                if orig_next_focus then orig_next_focus(self) elseif self.frame then self.frame.invert = true end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end
            local orig_next_unfocus = next_btn.onUnfocus
            next_btn.onUnfocus = function(self)
                if orig_next_unfocus then orig_next_unfocus(self) elseif self.frame then self.frame.invert = false end
                UIManager:setDirty(self.show_parent or self, "fast")
                return true
            end

            table.insert(layout, { prev_btn, next_btn })
        end

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

        local orig_cfg_focus = config_btn.onFocus
        config_btn.onFocus = function(self)
            if orig_cfg_focus then orig_cfg_focus(self) elseif self.frame then self.frame.invert = true end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end
        local orig_cfg_unfocus = config_btn.onUnfocus
        config_btn.onUnfocus = function(self)
            if orig_cfg_unfocus then orig_cfg_unfocus(self) elseif self.frame then self.frame.invert = false end
            UIManager:setDirty(self.show_parent or self, "fast")
            return true
        end

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

        table.insert(layout, { config_btn, close_btn })

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

        local prev_selected = cur_selected or initial_selected
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
            ges_events = ges_events,
            card,
        }

        overlay.key_events = overlay.key_events or {}
        overlay.key_events.Close = { { "Back" }, { "Escape" } }
        overlay.key_events.NextPage = {
            { "PageDown" },
            { "RPgFwd" },
            { "LPgFwd" },
        }
        overlay.key_events.PrevPage = {
            { "PageUp" },
            { "RPgBack" },
            { "LPgBack" },
        }
        if Input and Input.group then
            if Input.group.Back then
                table.insert(overlay.key_events.Close, { Input.group.Back })
            end
            if Input.group.PgFwd then
                table.insert(overlay.key_events.NextPage, { Input.group.PgFwd })
            end
            if Input.group.PgBack then
                table.insert(overlay.key_events.PrevPage, { Input.group.PgBack })
            end
        end

        for _, row in ipairs(layout) do
            for _, item in ipairs(row) do
                item.show_parent = overlay
            end
        end

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

        overlay.onNextPage = function(self)
            if current_page < total_pages then
                current_page = current_page + 1
                refresh({ x = 1, y = 1 })
            end
            return true
        end

        overlay.onPrevPage = function(self)
            if current_page > 1 then
                current_page = current_page - 1
                refresh({ x = 1, y = 1 })
            end
            return true
        end

        -- Direct onKeyPress/onKeyRepeat fallback to guarantee physical button presses paginate
        local orig_onKeyPress = overlay.onKeyPress
        local function handleKey(self, key)
            if orig_onKeyPress and orig_onKeyPress(self, key) then
                return true
            end
            local k_name = (type(key) == "table" and key.key) or (type(key) == "string" and key) or ""
            if k_name == "PageDown" or k_name == "RPgFwd" or k_name == "LPgFwd"
                or (type(key) == "table" and (key.PageDown or key.RPgFwd or key.LPgFwd)) then
                return self:onNextPage()
            elseif k_name == "PageUp" or k_name == "RPgBack" or k_name == "LPgBack"
                or (type(key) == "table" and (key.PageUp or key.RPgBack or key.LPgBack)) then
                return self:onPrevPage()
            end
            return false
        end
        overlay.onKeyPress = handleKey
        overlay.onKeyRepeat = handleKey

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
            freeActiveWidgets()
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

return StorefrontScreensaverGallery
