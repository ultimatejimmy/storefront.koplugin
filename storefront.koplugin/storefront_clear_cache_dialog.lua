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
local RepoContent = require("storefront_repo_content")
local StorefrontScreensavers = require("storefront_screensavers_ui")

local StorefrontClearCacheDialog = {}

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

local function formatStats(stats)
    local files = (stats and stats.files) or 0
    local bytes = (stats and stats.bytes) or 0
    local size_str = formatSize(bytes)
    if files == 0 then
        return _("Empty (0 KB)")
    elseif files == 1 then
        return string.format(_("%s · 1 file"), size_str)
    else
        return string.format(_("%s · %d files"), size_str, files)
    end
end

local function showCustomConfirm(title_text, body_text, ok_button_text, on_ok)
    local StorefrontUtils = require("storefront_utils")
    return StorefrontUtils.showConfirmDialog{
        title = title_text,
        text = body_text,
        ok_text = ok_button_text or _("Clear"),
        cancel_text = _("Cancel"),
        ok_callback = on_ok,
    }
end

function StorefrontClearCacheDialog.show(Storefront, on_close_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(400))

    local ui_font_size = storefront_theme.face_label_size or 18
    local subtext_font_size = storefront_theme.subtext_font_size or 16
    local title_font_size = storefront_theme.title_font_size or 22

    local overlay
    local refresh

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

    refresh = function()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local readme_stats = RepoContent.getReadmeCacheStats()
        local wiki_stats = RepoContent.getWikiCacheStats()
        local thumb_stats = StorefrontScreensavers.getThumbnailsCacheStats()

        local total_files = readme_stats.files + wiki_stats.files + thumb_stats.files
        local total_bytes = readme_stats.bytes + wiki_stats.bytes + thumb_stats.bytes
        local total_stats = { files = total_files, bytes = total_bytes }

        -- Title Widget
        local title_label = TextWidget:new{
            text = _("Clear Cache"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local title_close_btn = Button:new{
            text = "✕",
            face = Font:getFace("cfont", title_font_size),
            bordersize = 0,
            callback = function()
                closeDialog()
            end,
        }

        local title_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            HorizontalGroup:new{
                title_label,
                HorizontalSpan:new{ width = math.max(sc(10), dialog_w - sc(20) - (title_label:getSize().w or sc(100)) - (title_close_btn:getSize().w or sc(30))) },
                title_close_btn,
            }
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_container,
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            },
        }

        -- Explanatory subtitle
        local desc_txt = TextBoxWidget:new{
            text = _("Free up storage space on your device. Cached items are re-downloaded automatically when needed."),
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
            width = dialog_w - sc(24),
            alignment = "left",
        }
        table.insert(content_vg, FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            desc_txt,
        })
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        local FocusManager = require("ui/widget/focusmanager")
        local focusable_rows = {}

        local function create_cache_row(title_str, stats, on_clear, is_accent)
            local has_items = stats and (stats.files > 0 or stats.bytes > 0)
            local sub_str = formatStats(stats)

            local title_w = TextWidget:new{
                text = title_str,
                face = Font:getFace("cfont", is_accent and (ui_font_size + 1) or ui_font_size),
                bold = is_accent,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local sub_w = TextWidget:new{
                text = sub_str,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }

            local left_vg = VerticalGroup:new{
                align = "left",
                title_w,
                VerticalSpan:new{ width = sc(3) },
                sub_w,
            }

            local right_action
            if not has_items then
                right_action = TextWidget:new{
                    text = _("Empty"),
                    face = Font:getFace("cfont", subtext_font_size),
                    fgcolor = storefront_theme.color_label_dim,
                }
            else
                local StorefrontUtils = require("storefront_utils")
                right_action = StorefrontUtils.createButton{
                    text = is_accent and _("Clear All") or _("Clear"),
                    text_font_size = is_accent and (ui_font_size - 1) or (ui_font_size - 2),
                    bold = true,
                    bordersize = storefront_theme.border_btn or sc(1),
                    radius = storefront_theme.radius_btn or sc(4),
                    padding = sc(6),
                    padding_h = sc(12),
                    background = is_accent and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    text_font_color = is_accent and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    callback = on_clear,
                }
            end

            local row_h = math.max(left_vg:getSize().h, right_action:getSize().h)
            local avail_w = dialog_w - sc(24)

            local row_overlap = OverlapGroup:new{
                dimen = Geom:new{ w = avail_w, h = row_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = avail_w, h = row_h },
                    left_vg,
                },
                RightContainer:new{
                    dimen = Geom:new{ w = avail_w, h = row_h },
                    right_action,
                }
            }

            local frame = FrameContainer:new{
                padding = sc(8),
                padding_left = sc(10),
                padding_right = sc(10),
                bordersize = 0,
                background = is_accent and Blitbuffer.Color8(240) or Blitbuffer.COLOR_WHITE,
                width = dialog_w - sc(4),
                row_overlap,
            }

            if not has_items or not on_clear then
                return frame
            end

            local item = InputContainer:new{ frame }
            item.frame = frame
            item.callback = on_clear
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then
                                return Geom:new{ x = -1, y = -1, w = 1, h = 1 }
                            end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = dialog_w - sc(4),
                                h = (frame:getSize() and frame:getSize().h) or sc(40),
                            }
                        end,
                    }
                }
            }
            item.onTap = function()
                on_clear()
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

        -- SECTION: ALL CACHES
        table.insert(content_vg, create_cache_row(
            _("All Caches"),
            total_stats,
            function()
                showCustomConfirm(
                    _("Clear All Caches?"),
                    string.format(_("This will delete all cached README files, wiki articles, and screensaver thumbnails (%s)."), formatSize(total_bytes)),
                    _("Clear All"),
                    function()
                        local r1 = RepoContent.clearReadmeCache()
                        local r2 = RepoContent.clearWikiCache()
                        local r3 = StorefrontScreensavers.clearThumbnailsCache()
                        local freed_bytes = (r1.bytes or 0) + (r2.bytes or 0) + (r3.bytes or 0)
                        local freed_files = (r1.removed or 0) + (r2.removed or 0) + (r3.removed or 0)
                        refresh()
                        StorefrontToast.show(string.format(_("Cleared all caches (%s freed, %d files)."), formatSize(freed_bytes), freed_files), 3)
                    end
                )
            end,
            true
        ))

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- ROW 1: README CACHE
        table.insert(content_vg, create_cache_row(
            _("README files & images"),
            readme_stats,
            function()
                showCustomConfirm(
                    _("Clear README Cache?"),
                    string.format(_("This will delete cached README markdown files and downloaded images (%s)."), formatSize(readme_stats.bytes)),
                    _("Clear"),
                    function()
                        local res = RepoContent.clearReadmeCache()
                        refresh()
                        StorefrontToast.show(string.format(_("Cleared README cache (%s freed)."), formatSize(res.bytes or 0)), 3)
                    end
                )
            end,
            false
        ))

        -- ROW 2: WIKI CACHE
        table.insert(content_vg, create_cache_row(
            _("Wiki pages & images"),
            wiki_stats,
            function()
                showCustomConfirm(
                    _("Clear Wiki Cache?"),
                    string.format(_("This will delete cached wiki articles and downloaded images (%s)."), formatSize(wiki_stats.bytes)),
                    _("Clear"),
                    function()
                        local res = RepoContent.clearWikiCache()
                        refresh()
                        StorefrontToast.show(string.format(_("Cleared Wiki cache (%s freed)."), formatSize(res.bytes or 0)), 3)
                    end
                )
            end,
            false
        ))

        -- ROW 3: SCREENSAVER THUMBNAILS
        table.insert(content_vg, create_cache_row(
            _("Screensaver thumbnails"),
            thumb_stats,
            function()
                showCustomConfirm(
                    _("Clear Thumbnail Cache?"),
                    string.format(_("This will delete cached screensaver thumbnail previews (%s)."), formatSize(thumb_stats.bytes)),
                    _("Clear"),
                    function()
                        local res = StorefrontScreensavers.clearThumbnailsCache()
                        refresh()
                        StorefrontToast.show(string.format(_("Cleared screensaver thumbnails (%s freed)."), formatSize(res.bytes or 0)), 3)
                    end
                )
            end,
            false
        ))

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        })

        -- Close Button at bottom
        local StorefrontUtils = require("storefront_utils")
        local close_btn = StorefrontUtils.createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = storefront_theme.radius_btn or sc(4),
            width = dialog_w - sc(20),
            height = sc(38),
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                closeDialog()
            end,
        }
        table.insert(content_vg, FrameContainer:new{
            padding = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(38) },
                close_btn,
            }
        })

        local card_frame = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = storefront_theme.border_window or sc(2),
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
            card_frame,
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

return StorefrontClearCacheDialog
