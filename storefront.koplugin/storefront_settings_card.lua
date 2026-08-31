local Screen = require("device").screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("storefront_toast")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local Cache = require("storefront_cache")
local GitHubClient = require("storefront_net_github")
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")

local StorefrontSettingsCard = {}

local function sc(val)
    return Screen:scaleBySize(val)
end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

function StorefrontSettingsCard.show(Storefront)
    local current_kind = (Storefront.browser_state and Storefront.browser_state.kind) or "plugin"
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
        end

        local available_h = sh - sc(24)
        local title_font_size
        local header_font_size
        local ui_font_size
        local subtext_font_size
        local row_pad_v
        local row_pad_h = sc(10)
        local header_pad_v
        local title_pad_v
        local close_h

        if available_h >= sc(650) then
            title_font_size = 20
            header_font_size = 14
            ui_font_size = 16
            subtext_font_size = 14
            row_pad_v = sc(6)
            header_pad_v = sc(4)
            title_pad_v = sc(8)
            close_h = sc(36)
        elseif available_h >= sc(520) then
            title_font_size = 18
            header_font_size = 13
            ui_font_size = 14
            subtext_font_size = 13
            row_pad_v = sc(4)
            header_pad_v = sc(3)
            title_pad_v = sc(6)
            close_h = sc(32)
        elseif available_h >= sc(440) then
            title_font_size = 16
            header_font_size = 11
            ui_font_size = 13
            subtext_font_size = 12
            row_pad_v = sc(2)
            header_pad_v = sc(2)
            title_pad_v = sc(4)
            close_h = sc(28)
        else
            title_font_size = 14
            header_font_size = 10
            ui_font_size = 11
            subtext_font_size = 10
            row_pad_v = sc(1)
            header_pad_v = sc(1)
            title_pad_v = sc(3)
            close_h = sc(24)
        end

        -- Title Widget
        local title_text = _("Settings")
        local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(title_text, dialog_w - sc(24), "NotoSerif-Regular.ttf", title_font_size, 12, true)
        local title_label = TextBoxWidget:new{
            text = title_text,
            face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = dialog_w - sc(24),
        }

        local title_container = FrameContainer:new{
            padding_v = title_pad_v,
            padding_h = sc(10),
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

        local FocusManager = require("ui/widget/focusmanager")
        local focusable_rows = {}

        -- Helper to create setting row
        local function create_setting_row(icon_arg, left_text, right_widget, callback)
            local row_elements = {}

            -- Icon (represented as table/widget, SVG asset filename, or unicode text)
            local icon_widget
            local icon_w = 0
            if icon_arg then
                if type(icon_arg) == "table" then
                    icon_widget = icon_arg
                elseif type(icon_arg) == "string" and icon_arg:match("%.svg$") then
                    local icon_sz = math.min(sc(20), math.max(sc(14), ui_font_size + sc(2)))
                    icon_widget = ImageWidget:new{
                        file = getAssetPath(icon_arg),
                        width = icon_sz,
                        height = icon_sz,
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }
                elseif type(icon_arg) == "string" then
                    icon_widget = TextWidget:new{
                        text = icon_arg,
                        face = Font:getFace("cfont", ui_font_size),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end
            end

            if icon_widget then
                icon_w = (icon_widget.getSize and icon_widget:getSize().w) or sc(20)
                table.insert(row_elements, icon_widget)
                table.insert(row_elements, HorizontalSpan:new{ width = sc(8) })
            end

            -- Measure dynamic right widget size
            local right_w = 0
            if right_widget then
                right_w = (right_widget.getSize and right_widget:getSize().w) or sc(60)
            end

            -- Constrain left text width to guarantee it never wraps or pushes right_widget off-screen
            local frame_padding_h = row_pad_h
            local avail_w = dialog_w - (frame_padding_h * 2) - sc(4)
            local max_left_w = avail_w - icon_w - (icon_widget and sc(8) or 0) - right_w - sc(8)
            if max_left_w < sc(60) then
                max_left_w = sc(60)
            end

            -- Left Text Label (Strict high-contrast COLOR_BLACK)
            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }
            table.insert(row_elements, txt)

            -- Flexible Spacer to right-align right_widget
            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = avail_w - icon_w - (icon_widget and sc(8) or 0) - left_used_w - right_w
            if spacer_w < sc(8) then
                spacer_w = sc(8)
            end
            table.insert(row_elements, HorizontalSpan:new{ width = spacer_w })

            -- Right Widget (optional)
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local row_content = HorizontalGroup:new(row_elements)

            local frame = FrameContainer:new{
                bordersize = 0,
                padding_v = row_pad_v,
                padding_h = row_pad_h,
                width = dialog_w - sc(4),
                row_content,
            }

            if not callback then
                return frame
            end

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
                callback()
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

        local StorefrontSettings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/Storefront.lua")

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", header_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding_v = header_pad_v,
                padding_h = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        -- SECTION 1: CATALOG & CACHE
        table.insert(content_vg, create_section_header(_("Catalog & Cache")))

        -- Catalog Source Row
        local catalog_mode = GitHubClient.getCatalogMode()
        local catalog_mode_label = (catalog_mode == "static") and _("Storefront") or _("Direct GitHub API")
        local catalog_widget = TextWidget:new{
            text = catalog_mode_label,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(nil, _("Catalog source"), catalog_widget, function()
            local next_mode = (catalog_mode == "static") and "direct" or "static"
            GitHubClient.setCatalogMode(next_mode)
            refresh()
        end))

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

    local ok_dt, datetime = pcall(require, "datetime")
    if not ok_dt then ok_dt, datetime = pcall(require, "ui/datetime") end
    if ok_dt and datetime then
        if type(datetime.is12HourClock) == "function" then
            local res = datetime.is12HourClock()
            if res ~= nil then return res end
        end
        if type(datetime.has12HourClock) == "function" then
            local res = datetime.has12HourClock()
            if res ~= nil then return res end
        end
        if type(datetime.is12Hour) == "function" then
            local res = datetime.is12Hour()
            if res ~= nil then return res end
        end
    end

    if G_reader_settings then
        if type(G_reader_settings.isTrue) == "function" then
            if G_reader_settings:isTrue("clock_12h")
                or G_reader_settings:isTrue("clock_format_12h")
                or G_reader_settings:isTrue("c_clock_12h")
                or G_reader_settings:isTrue("c_time_12h")
                or G_reader_settings:isTrue("time_12h")
                or G_reader_settings:isTrue("12h_clock")
                or G_reader_settings:isTrue("use_12h_clock")
                or G_reader_settings:isTrue("is_12h_clock")
                or G_reader_settings:isTrue("is_12h")
                or G_reader_settings:isTrue("12_hour_clock")
                or G_reader_settings:isTrue("c_12_hour_clock") then
                return true
            end
        end

        if type(G_reader_settings.readSetting) == "function" then
            local keys = {
                "c_time_format", "clock_format", "time_format", "c_clock_format",
                "clock", "time_mode", "clock_mode", "time_display", "status_time_format"
            }
            for _, key in ipairs(keys) do
                local val = G_reader_settings:readSetting(key)
                if val ~= nil then
                    local sval = tostring(val):lower()
                    if sval:find("12") or sval == "true" then
                        return true
                    end
                end
            end
        end
    end

    return false
end

local function formatDateTime(ts)
    if not ts or ts <= 0 then
        return _("Never")
    end

    if is12HourClockEnabled() then
        local formatted = os.date("%Y-%m-%d %I:%M%p", ts):lower()
        return (formatted:gsub(" 0(%d:)", " %1"))
    else
        return os.date("%Y-%m-%d %H:%M", ts)
    end
end

        -- Refresh Catalog Row
        local is_currently_refreshing = Storefront.isRefreshing and Storefront:isRefreshing()
        local ts = Cache.getLastFetched(current_kind)
        local meta_text = is_currently_refreshing
            and _("Refreshing…")
            or (ts and ts > 0 and formatDateTime(ts) or _("Never"))
        local meta_widget = TextWidget:new{
            text = meta_text,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row("rotate-cw.svg", _("Refresh catalog"), meta_widget, function()
            if Storefront.isRefreshing and Storefront:isRefreshing() then
                InfoMessage:new{ text = _("Catalog refresh is already in progress in the background."), timeout = 3 }:show()
                return
            end
            UIManager:close(overlay, "ui")
            local browser_was_open = Storefront.browser_menu ~= nil
            local kind = (Storefront.browser_state and Storefront.browser_state.kind) or "plugin"
            local ok_nm, NetworkMgr2 = pcall(require, "ui/network/manager")
            local do_refresh = function()
                Storefront:refreshCache(kind, function(ok)
                    if browser_was_open then
                        Storefront:softRefreshCurrentBrowserView()
                    end
                end)
            end
            if ok_nm and NetworkMgr2 and type(NetworkMgr2.runWhenOnline) == "function" then
                NetworkMgr2:runWhenOnline(do_refresh)
            else
                do_refresh()
            end
        end))

        -- Clear Cache Row
        local cache_arrow_widget = TextWidget:new{
            text = "›",
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(nil, _("Clear cache…"), cache_arrow_widget, function()
            UIManager:close(overlay, "ui")
            local StorefrontClearCacheDialog = require("storefront_clear_cache_dialog")
            StorefrontClearCacheDialog.show(Storefront, function()
                StorefrontSettingsCard.show(Storefront)
            end)
        end))

        -- SECTION 2: SEARCH & API
        table.insert(content_vg, create_section_header(_("Search & API")))

        -- Include 0-star forks Row
        local include_zero = StorefrontSettings:readSetting("include_zero_star_forks") == true
            or (Storefront.browser_state and Storefront.browser_state.include_zero_star_forks == true)
        local fork_indicator = include_zero and "☑" or "☐"
        table.insert(content_vg, create_setting_row(fork_indicator, _("Include 0-star forks"), nil, function()
            local next_val = not include_zero
            StorefrontSettings:saveSetting("include_zero_star_forks", next_val)
            StorefrontSettings:flush()
            if Storefront.browser_state then
                Storefront.browser_state.include_zero_star_forks = next_val
                Storefront:saveBrowserState()
            end
            Storefront._repo_descriptors_cache = nil
            refresh()
        end))

        -- GitHub Token Row
        local github_configured = GitHubClient.hasAuthToken()
        local token_status_text = github_configured and _("Configured ✓") or _("Not set")
        local token_widget = TextWidget:new{
            text = token_status_text,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(nil, _("GitHub token"), token_widget, function()
            local token_dialog
            token_dialog = InputDialog:new{
                title = _("GitHub personal access token"),
                description = _("Optional. Raises the GitHub API rate limit. Generate one (classic, 'public_repo' scope is enough) at github.com/settings/tokens, then paste it here."),
                input = GitHubClient.getToken() or "",
                input_hint = _("ghp_..."),
                text_type = "password",
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(token_dialog)
                            end,
                        },
                        {
                            text = _("Clear"),
                            callback = function()
                                GitHubClient.setToken(nil)
                                UIManager:close(token_dialog)
                                refresh()
                            end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                GitHubClient.setToken(token_dialog:getInputText())
                                UIManager:close(token_dialog)
                                refresh()
                                UIManager:show(InfoMessage:new{
                                    text = _("GitHub token saved."),
                                    timeout = 2,
                                })
                            end,
                        },
                    },
                },
            }
            UIManager:show(token_dialog)
            token_dialog:onShowKeyboard()
        end))

        -- SECTION 3: SCREENSAVER & WALLPAPERS
        table.insert(content_vg, create_section_header(_("Screensaver & Wallpapers")))

        local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
        local ss_settings = StorefrontScreensaverMgr.getScreensaverSettings()
        local ss_local = StorefrontScreensaverMgr.listLocalScreensavers()

        local mode_display_str = _("Book Cover")
        if ss_settings.effective_mode == "single" then
            local fname = (ss_settings.file ~= "") and ss_settings.file:match("([^/\\]+)$") or _("Single")
            mode_display_str = _("Single") .. " (" .. fname .. ")"
        elseif ss_settings.effective_mode == "shuffle" then
            mode_display_str = string.format(_("Shuffle (%d)"), #ss_local)
        elseif ss_settings.effective_mode == "book_status" then
            mode_display_str = _("Reading Progress")
        elseif ss_settings.effective_mode == "blank" then
            mode_display_str = _("Blank")
        end

        local mode_widget = TextWidget:new{
            text = mode_display_str,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
            max_width = sc(140),
        }

        table.insert(content_vg, create_setting_row("image-active.svg", _("Screensaver mode"), mode_widget, function()
            UIManager:close(overlay, "ui")
            local StorefrontScreensaverConfig = require("storefront_screensaver_config")
            StorefrontScreensaverConfig.show(Storefront, function()
                StorefrontSettingsCard.show(Storefront)
            end)
        end))

        local count_widget = TextWidget:new{
            text = string.format(_("%d wallpapers"), #ss_local),
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }

        table.insert(content_vg, create_setting_row(nil, _("My wallpaper collection"), count_widget, function()
            UIManager:close(overlay, "ui")
            local StorefrontScreensaverGallery = require("storefront_screensaver_gallery")
            StorefrontScreensaverGallery.show(Storefront, function()
                StorefrontSettingsCard.show(Storefront)
            end)
        end))

        -- SECTION 4: ABOUT STOREFRONT
        table.insert(content_vg, create_section_header(_("About Storefront")))

        -- About Storefront Row
        local StorefrontAboutDialog = require("storefront_about_dialog")
        local current_ch = StorefrontAboutDialog.getChannel()
        local version_str = StorefrontAboutDialog.getVersion()
        local ver_widget = TextWidget:new{
            text = string.format("v%s", version_str),
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(nil, _("About Storefront"), ver_widget, function()
            UIManager:close(overlay, "ui")
            StorefrontAboutDialog.show(Storefront, function()
                StorefrontSettingsCard.show(Storefront)
            end)
        end))

        -- Update channel Row
        local ch_label = (current_ch == "beta") and _("Beta") or _("Stable")
        local ch_widget = TextWidget:new{
            text = ch_label,
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(nil, _("Update channel"), ch_widget, function()
            UIManager:close(overlay, "ui")
            StorefrontAboutDialog.show(Storefront, function()
                StorefrontSettingsCard.show(Storefront)
            end)
        end))

        -- Divider line
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        -- Close Button Row
        local StorefrontUtils = require("storefront_utils")
        local close_btn = StorefrontUtils.createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = storefront_theme.radius_btn or sc(4),
            width = dialog_w - sc(20),
            height = close_h,
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                UIManager:close(overlay, "ui")
            end,
        }
        table.insert(content_vg, FrameContainer:new{
            padding = sc(4),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = close_h },
                close_btn,
            }
        })

        -- Build modal frame
        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg,
            width = dialog_w,
            content_vg
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
            card
        }

        for _, row_item in ipairs(focusable_rows) do
            row_item.show_parent = overlay
        end
        close_btn.show_parent = overlay

        overlay.onClose = function()
            overlay = nil
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontSettingsCard
