local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontToast = require("storefront_toast")
local StorefrontScreensavers = require("storefront_screensavers_ui")
local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
local StorefrontUtils = require("storefront_utils")

local StorefrontCollectionsDialog = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

function StorefrontCollectionsDialog.show(Storefront, on_close_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(12), sc(580))

    local overlay = nil
    local current_page = 1
    local ITEMS_PER_PAGE = 2
    local active_collections = {}

    local function closeDialog()
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

    local function openCollection(col)
        if not col or not col.id then return end
        closeDialog()
        if Storefront and Storefront.browser_state then
            Storefront.browser_state.screensaver_collection = col.id
            Storefront.browser_state.page = 1
            if Storefront.browser_menu and Storefront.browser_menu.updateTabContent then
                Storefront:updateBrowserTabInPlace("Screensavers", 1, nil, true)
            else
                Storefront:reopenBrowser()
            end
        end
    end

    local function formatSize(bytes)
        bytes = tonumber(bytes) or 0
        if bytes >= 1024 * 1024 * 1024 then
            return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
        elseif bytes >= 1024 * 1024 then
            return string.format("%.1f MB", bytes / (1024 * 1024))
        elseif bytes >= 1024 then
            return string.format("%.0f KB", bytes / 1024)
        else
            return string.format("%d B", bytes)
        end
    end

    function StorefrontCollectionsDialog.downloadAllInCollection(col)
        if not col or not col.items or #col.items == 0 then
            StorefrontToast.show(_("This collection has no wallpapers to download."), 3)
            return
        end

        local catalog = StorefrontScreensavers.getCachedCatalog() or {}
        local catalog_map = {}
        for _, item in ipairs(catalog) do
            if item.id then
                catalog_map[tostring(item.id)] = item
            end
        end

        local to_download = {}
        for _, item_id in ipairs(col.items) do
            local item = catalog_map[tostring(item_id)]
            if item then
                local is_dl = StorefrontScreensaverMgr.isWallpaperDownloaded(item)
                if not is_dl then
                    table.insert(to_download, item)
                end
            end
        end

        if #to_download == 0 then
            StorefrontToast.show(_("All wallpapers in this collection are already downloaded!"), 3)
            return
        end

        -- Check available storage space before starting
        local ss_dir = StorefrontScreensaverMgr.getScreensaverFolder()
        local ok_util, util = pcall(require, "ffi/util")
        if ok_util and util and util.df then
            local ok_df, total_b, free_b = pcall(util.df, ss_dir)
            if ok_df and free_b and type(free_b) == "number" then
                -- Estimate ~600KB per wallpaper + 15MB safety buffer
                local est_needed = #to_download * 600 * 1024
                local min_required = est_needed + (15 * 1024 * 1024)
                if free_b < min_required then
                    local ConfirmBox = require("ui/widget/confirmbox")
                    local alert = ConfirmBox:new{
                        text = string.format(_("Insufficient storage space to download %d wallpapers.\n\nRequired: %s\nAvailable: %s"), #to_download, formatSize(est_needed), formatSize(free_b)),
                        ok_text = _("Close"),
                    }
                    UIManager:show(alert, "ui")
                    return
                end
            end
        end

        local total = #to_download
        local completed = 0
        local failed = 0
        local is_cancelled = false
        local progress_overlay = nil

        local function closeProgressDialog()
            if progress_overlay then
                local ov = progress_overlay
                progress_overlay = nil
                ov.onClose = nil
                UIManager:close(ov, "ui")
            end
        end

        local title_lbl = TextWidget:new{
            text = _("Downloading Collection"),
            face = StorefrontUtils.getTitleFace(20),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local col_lbl = TextWidget:new{
            text = col.title or _("Collection"),
            face = Font:getFace("cfont", 15),
            fgcolor = storefront_theme.color_label_dim,
        }

        local status_lbl = TextWidget:new{
            text = string.format(_("Starting download (0/%d)..."), total),
            face = Font:getFace("cfont", 16),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local item_lbl = TextWidget:new{
            text = "",
            face = Font:getFace("cfont", 14),
            fgcolor = storefront_theme.color_label_dim,
        }

        local cancel_btn = StorefrontUtils.createButton{
            text = _("Cancel"),
            text_font_size = 15,
            bold = true,
            bordersize = sc(1),
            radius = sc(5),
            padding_h = sc(24),
            height = sc(38),
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                if is_cancelled then return end
                is_cancelled = true
                closeProgressDialog()
                StorefrontToast.show(string.format(_("Download cancelled (%d downloaded)."), completed), 3)
            end,
        }

        local modal_w = math.min(sw - sc(40), sc(420))
        local modal_vg = VerticalGroup:new{
            align = "center",
            title_lbl,
            VerticalSpan:new{ width = sc(3) },
            col_lbl,
            VerticalSpan:new{ width = sc(16) },
            status_lbl,
            VerticalSpan:new{ width = sc(4) },
            item_lbl,
            VerticalSpan:new{ width = sc(18) },
            cancel_btn,
        }

        local modal_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            radius = sc(6),
            padding = sc(18),
            width = modal_w,
            modal_vg,
        }

        progress_overlay = FocusManager:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            layout = { { cancel_btn } },
            key_events = {
                Close = { { "Back" }, { "Escape" } },
            },
            modal_frame,
        }
        cancel_btn.show_parent = progress_overlay
        progress_overlay.onClose = function()
            if not is_cancelled then
                is_cancelled = true
                closeProgressDialog()
                StorefrontToast.show(string.format(_("Download cancelled (%d downloaded)."), completed), 3)
            end
            return true
        end

        UIManager:show(progress_overlay, "ui")

        local function downloadNext(index)
            if is_cancelled then
                closeProgressDialog()
                return
            end

            if index > total then
                closeProgressDialog()
                if not is_cancelled then
                    if failed == 0 then
                        StorefrontToast.show(string.format(_("Downloaded %d wallpapers from '%s'!"), completed, col.title or "Collection"), 3)
                    else
                        StorefrontToast.show(string.format(_("Downloaded %d wallpapers (%d failed)."), completed, failed), 3)
                    end
                end
                return
            end

            local cur_item = to_download[index]
            if status_lbl and status_lbl.setText then
                status_lbl:setText(string.format(_("Downloading %d of %d…"), index, total))
            end
            if item_lbl and item_lbl.setText then
                item_lbl:setText(cur_item and (cur_item.title or cur_item.name) or "")
            end
            if progress_overlay then
                UIManager:setDirty(progress_overlay, "fast")
            end

            UIManager:scheduleIn(0.05, function()
                if is_cancelled then
                    closeProgressDialog()
                    return
                end

                StorefrontScreensaverMgr.downloadWallpaper(cur_item, function(ok, err)
                    if is_cancelled then
                        closeProgressDialog()
                        return
                    end
                    if ok then
                        completed = completed + 1
                    else
                        failed = failed + 1
                    end
                    downloadNext(index + 1)
                end)
            end)
        end

        downloadNext(1)
    end
    local downloadAllInCollection = StorefrontCollectionsDialog.downloadAllInCollection

    local function renderDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local collections = StorefrontScreensavers.getCachedCollections() or {}
        active_collections = collections

        local total_pages = math.max(1, math.ceil(#collections / ITEMS_PER_PAGE))
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        -- Header
        local title_label = TextWidget:new{
            text = _("Curated Collections"),
            face = StorefrontUtils.getTitleFace(26),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local count_text = string.format(_("%d Curated Collections"), #collections)
        local count_label = TextWidget:new{
            text = count_text,
            face = Font:getFace("cfont", 16),
            fgcolor = storefront_theme.color_label_dim,
        }

        local header_left = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(3) },
            count_label,
        }

        local header_close_btn = Button:new{
            text = "✕",
            text_font_size = 22,
            bold = true,
            bordersize = 0,
            padding = sc(8),
            padding_h = sc(14),
            background = Blitbuffer.COLOR_WHITE,
            callback = closeDialog,
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

        if #collections == 0 then
            content_vg[#content_vg + 1] = FrameContainer:new{
                padding = sc(30),
                bordersize = 0,
                width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(24), h = sc(220) },
                    VerticalGroup:new{
                        align = "center",
                        TextWidget:new{
                            text = _("No collections available"),
                            face = StorefrontUtils.getTitleFace(22),
                            bold = true,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                        },
                        VerticalSpan:new{ width = sc(8) },
                        TextWidget:new{
                            text = _("Collections will appear here once published from the studio."),
                            face = Font:getFace("cfont", 16),
                            fgcolor = storefront_theme.color_label_dim,
                        },
                    }
                }
            }
        else
            local start_idx = (current_page - 1) * ITEMS_PER_PAGE + 1
            local end_idx = math.min(#collections, start_idx + ITEMS_PER_PAGE - 1)

            -- Prominent 3:4 portrait cover sizing (e.g. 172x230 on standard screen)
            local avail_cards_h = sh - sc(130)
            local card_target_h = math.floor(avail_cards_h / ITEMS_PER_PAGE)
            local thumb_h = math.min(sc(230), math.max(sc(160), card_target_h - sc(32)))
            local thumb_w = math.floor(thumb_h * 3 / 4)
            local card_pad = sc(12)
            local action_buttons_list = {}
            local nav_buttons_list = {}

            for i = start_idx, end_idx do
                local col = collections[i]
                local cover_path = StorefrontScreensavers.fetchCollectionCover(col)

                local cover_widget
                if cover_path then
                    local ok_cov, res_cov = pcall(StorefrontScreensavers.createCoverImageWidget, cover_path, thumb_w, thumb_h)
                    if ok_cov and res_cov then
                        cover_widget = res_cov
                    end
                end

                if not cover_widget then
                    local ok_net, CatalogClient = pcall(require, "storefront_net_catalog")
                    local info = debug.getinfo(1, "S")
                    local src = (info and info.source) and info.source:gsub("^@", "") or ""
                    local dir = src:match("^(.*[/\\])") or ""
                    local layers_path = dir .. "assets/layers.svg"
                    cover_widget = FrameContainer:new{
                        bordersize = 0,
                        background = Blitbuffer.Color8(235),
                        padding = 0,
                        CenterContainer:new{
                            dimen = Geom:new{ w = thumb_w, h = thumb_h },
                            ImageWidget:new{
                                file = layers_path,
                                width = sc(48),
                                height = sc(48),
                                is_icon = true,
                            }
                        }
                    }
                end

                local mid_avail_w = dialog_w - sc(16) - (card_pad * 2) - thumb_w - sc(16)

                local col_title = TextWidget:new{
                    text = col.title or _("Untitled Collection"),
                    face = StorefrontUtils.getTitleFace(22),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = mid_avail_w,
                }

                local curator_str = string.format(_("Curated by %s · %d wallpapers"), col.curator or _("Maintainer"), #(col.items or {}))
                local col_meta = TextWidget:new{
                    text = curator_str,
                    face = Font:getFace("cfont", 16),
                    fgcolor = storefront_theme.color_label_dim,
                    max_width = mid_avail_w,
                }

                local col_desc = TextBoxWidget:new{
                    text = col.description or "",
                    face = Font:getFace("cfont", 16),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width = mid_avail_w,
                    alignment = "left",
                }

                local browse_btn = StorefrontUtils.createButton{
                    text = _("Browse Collection ›"),
                    text_font_size = 15,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(5),
                    padding_h = sc(14),
                    height = sc(40),
                    background = Blitbuffer.COLOR_BLACK,
                    text_font_color = Blitbuffer.COLOR_WHITE,
                    callback = function() openCollection(col) end,
                }

                local dl_all_btn = StorefrontUtils.createButton{
                    text = string.format(_("Download All (%d)"), #(col.items or {})),
                    text_font_size = 15,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(5),
                    padding_h = sc(14),
                    height = sc(40),
                    background = Blitbuffer.COLOR_WHITE,
                    text_font_color = Blitbuffer.COLOR_BLACK,
                    callback = function() downloadAllInCollection(col) end,
                }

                local btn_group
                local b_w = browse_btn:getSize().w
                local d_w = dl_all_btn:getSize().w
                if (b_w + d_w + sc(8)) <= mid_avail_w then
                    table.insert(action_buttons_list, { browse_btn, dl_all_btn })
                    btn_group = HorizontalGroup:new{
                        browse_btn,
                        HorizontalSpan:new{ width = sc(8) },
                        dl_all_btn,
                    }
                else
                    browse_btn.width = mid_avail_w
                    dl_all_btn.width = mid_avail_w
                    table.insert(action_buttons_list, { browse_btn })
                    table.insert(action_buttons_list, { dl_all_btn })
                    btn_group = VerticalGroup:new{
                        align = "left",
                        browse_btn,
                        VerticalSpan:new{ width = sc(6) },
                        dl_all_btn,
                    }
                end

                local text_group = VerticalGroup:new{
                    align = "left",
                    col_title,
                    VerticalSpan:new{ width = sc(4) },
                    col_meta,
                    VerticalSpan:new{ width = sc(8) },
                    col_desc,
                    VerticalSpan:new{ width = sc(12) },
                    btn_group,
                }

                local card_row = HorizontalGroup:new{
                    FrameContainer:new{
                        bordersize = sc(1),
                        color = Blitbuffer.Color8(200),
                        radius = sc(4),
                        padding = 0,
                        cover_widget,
                    },
                    HorizontalSpan:new{ width = sc(16) },
                    text_group,
                }

                content_vg[#content_vg + 1] = FrameContainer:new{
                    bordersize = sc(1),
                    color = Blitbuffer.Color8(215),
                    radius = sc(6),
                    padding = card_pad,
                    background = Blitbuffer.COLOR_WHITE,
                    margin_bottom = sc(8),
                    width = dialog_w - sc(16),
                    card_row,
                }
            end

            -- Pagination if multiple pages
            if total_pages > 1 then
                local prev_btn = StorefrontUtils.createButton{
                    text = _("‹ Previous"),
                    text_font_size = 15,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(5),
                    padding_h = sc(16),
                    height = sc(38),
                    enabled = current_page > 1,
                    callback = function()
                        if current_page > 1 then
                            current_page = current_page - 1
                            renderDialog()
                        end
                    end,
                }

                local page_info = TextWidget:new{
                    text = string.format(_("Page %d of %d"), current_page, total_pages),
                    face = Font:getFace("cfont", 15),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local next_btn = StorefrontUtils.createButton{
                    text = _("Next ›"),
                    text_font_size = 15,
                    bold = true,
                    bordersize = sc(1),
                    radius = sc(5),
                    padding_h = sc(16),
                    height = sc(38),
                    enabled = current_page < total_pages,
                    callback = function()
                        if current_page < total_pages then
                            current_page = current_page + 1
                            renderDialog()
                        end
                    end,
                }

                nav_buttons_list = { prev_btn, next_btn }

                local avail_w = dialog_w - sc(32)
                local p_row = HorizontalGroup:new{
                    prev_btn,
                    HorizontalSpan:new{ width = math.max(sc(10), math.floor((avail_w - prev_btn:getSize().w - next_btn:getSize().w - page_info:getSize().w) / 2)) },
                    page_info,
                    HorizontalSpan:new{ width = math.max(sc(10), math.floor((avail_w - prev_btn:getSize().w - next_btn:getSize().w - page_info:getSize().w) / 2)) },
                    next_btn,
                }

                content_vg[#content_vg + 1] = VerticalSpan:new{ width = sc(6) }
                content_vg[#content_vg + 1] = FrameContainer:new{
                    padding = sc(6),
                    bordersize = 0,
                    width = dialog_w - sc(16),
                    CenterContainer:new{
                        dimen = Geom:new{ w = dialog_w - sc(16), h = sc(44) },
                        p_row,
                    }
                }
            end
        end

        local dialog_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            radius = sc(6),
            padding = sc(4),
            width = dialog_w,
            content_vg,
        }

        local layout = {}
        table.insert(layout, { header_close_btn })
        for _, btn_pair in ipairs(action_buttons_list or {}) do
            table.insert(layout, btn_pair)
        end
        if nav_buttons_list and #nav_buttons_list > 0 then
            table.insert(layout, nav_buttons_list)
        end

        local Input = Device and Device.input
        local key_events = {
            Close = { { "Back" }, { "Escape" } }
        }
        if Input and Input.group and Input.group.Back then
            table.insert(key_events.Close, { Input.group.Back })
        end
        if total_pages > 1 then
            key_events.NextPage = {
                { "PageDown" },
                { "RPgFwd" },
                { "LPgFwd" },
            }
            key_events.PrevPage = {
                { "PageUp" },
                { "RPgBack" },
                { "LPgBack" },
            }
            if Input and Input.group then
                if Input.group.PgFwd then
                    table.insert(key_events.NextPage, { Input.group.PgFwd })
                end
                if Input.group.PgBack then
                    table.insert(key_events.PrevPage, { Input.group.PgBack })
                end
            end
        end

        overlay = FocusManager:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            layout = layout,
            selected = { x = 1, y = 1 },
            key_events = key_events,
            dialog_frame,
        }

        header_close_btn.show_parent = overlay
        for _, row in ipairs(layout) do
            for _, item in ipairs(row) do
                if item then item.show_parent = overlay end
            end
        end

        overlay.onNextPage = function(self)
            if current_page < total_pages then
                current_page = current_page + 1
                renderDialog()
            end
            return true
        end

        overlay.onPrevPage = function(self)
            if current_page > 1 then
                current_page = current_page - 1
                renderDialog()
            end
            return true
        end

        overlay.onSwipe = function(self, arg, ges_ev)
            local ev = (type(arg) == "table" and arg) or (type(ges_ev) == "table" and ges_ev)
            local direction = ev and ev.direction
            if direction == "left" or direction == "west" then
                return self:onNextPage()
            elseif direction == "right" or direction == "east" then
                return self:onPrevPage()
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

    -- Render immediately from local cache / bundled collections
    renderDialog()

    -- Asynchronously fetch latest feed in background and update dialog if changed
    UIManager:nextTick(function()
        StorefrontScreensavers.fetchCollections(function(ok, updated_data)
            if ok and overlay then
                renderDialog()
            end
        end)
    end)
end

return StorefrontCollectionsDialog
