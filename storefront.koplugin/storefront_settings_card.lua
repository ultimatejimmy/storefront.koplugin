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
local TextBoxWidget = require("ui/widget/textboxwidget")
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
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Event = require("ui/event")

local StorefrontSettingsCard = {}

local function sc(val)
    return (Screen and Screen.scaleBySize and Screen:scaleBySize(val)) or val
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
    if not ts or ts <= 0 then return _("Never") end
    local is_12h = is12HourClockEnabled()
    if is_12h then
        local hour = tonumber(os.date("%I", ts)) or 0
        local min = os.date("%M", ts)
        local ampm = os.date("%p", ts):lower()
        local date_part = os.date("%Y-%m-%d", ts)
        return string.format("%s %d:%s%s", date_part, hour, min, ampm)
    else
        return os.date("%Y-%m-%d %H:%M", ts)
    end
end

local function getStorefrontSettings()
    return require("storefront_settings")
end

-- Generic helper to build a consistent setting row
local function buildSettingRow(dialog_w, row_pad_h, row_pad_v, ui_font_size, icon_arg, left_text, right_widget, callback, focusable_rows)
    local row_elements = {}

    local icon_widget
    local icon_w = 0
    if icon_arg then
        if type(icon_arg) == "table" then
            icon_widget = icon_arg
        elseif type(icon_arg) == "string" and icon_arg:match("%.svg$") then
            local asset_path = getAssetPath(icon_arg)
            if asset_path then
                local icon_sz = math.min(sc(20), math.max(sc(14), ui_font_size + sc(2)))
                icon_widget = ImageWidget:new{
                    file = asset_path,
                    width = icon_sz,
                    height = icon_sz,
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
            end
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

    local right_w = 0
    if right_widget then
        right_w = (right_widget.getSize and right_widget:getSize().w) or sc(60)
    end

    local avail_w = dialog_w - (row_pad_h * 2) - sc(4)
    local max_left_w = avail_w - icon_w - (icon_widget and sc(8) or 0) - right_w - sc(8)
    if max_left_w < sc(60) then max_left_w = sc(60) end

    local txt = TextBoxWidget:new{
        text = left_text,
        face = Font:getFace("cfont", ui_font_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_left_w,
        alignment = "left",
    }
    table.insert(row_elements, txt)

    local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
    local spacer_w = avail_w - icon_w - (icon_widget and sc(8) or 0) - left_used_w - right_w
    if spacer_w < sc(8) then spacer_w = sc(8) end
    table.insert(row_elements, HorizontalSpan:new{ width = spacer_w })

    if right_widget then
        table.insert(row_elements, right_widget)
    end

    local frame = FrameContainer:new{
        bordersize = 0,
        padding_v = row_pad_v,
        padding_h = row_pad_h,
        width = dialog_w - sc(4),
        HorizontalGroup:new(row_elements),
    }

    if not callback then return frame end

    local item = InputContainer:new{ frame }
    item.frame = frame
    item.callback = callback
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return item.dimen or frame:getSize() end,
            }
        }
    }
    item.onTap = function()
        callback()
        return true
    end
    item.isFocusable = function() return true end
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

    if focusable_rows then
        table.insert(focusable_rows, item)
    end
    return item
end

--- Main Settings Card dialog with in-place subviews (single modal dialog).
--- Views: "root", "catalog", "screensavers", "notifications".
function StorefrontSettingsCard.show(Storefront, initial_view, on_close)
    if type(initial_view) == "function" then
        on_close = initial_view
        initial_view = "root"
    end
    initial_view = initial_view or "root"

    local current_kind = (Storefront.browser_state and Storefront.browser_state.kind) or "plugin"
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(400))

    local ui_font_size = storefront_theme.face_label_size or 16
    local title_font_size = storefront_theme.title_font_size or 20
    local subtext_font_size = storefront_theme.subtext_font_size or 14
    local row_pad_v = sc(6)
    local row_pad_h = sc(10)
    local standard_row_h = sc(38) + sc(1)

    local current_view = initial_view
    local overlay = nil
    local card = nil
    local is_closing = false

    local function closeDialog()
        if is_closing then return end
        is_closing = true
        if overlay then
            local ov = overlay
            overlay = nil
            card = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_close then
            on_close()
        end
    end

    local function openExternal(fn, view_to_restore)
        local target_view = view_to_restore or current_view or "root"
        if overlay then
            local ov = overlay
            overlay = nil
            card = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        UIManager:nextTick(function()
            fn(function()
                StorefrontSettingsCard.show(Storefront, target_view, on_close)
            end)
        end)
    end

    local function renderView(view_name)
        current_view = view_name or "root"
        local focusable_rows = {}

        local function add_row(content_vg, icon_arg, left_text, right_widget, callback)
            local item = buildSettingRow(dialog_w, row_pad_h, row_pad_v, ui_font_size, icon_arg, left_text, right_widget, callback, focusable_rows)
            table.insert(content_vg, item)
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })
            return item
        end

        local title_text = _("Settings")
        if current_view == "catalog" then
            title_text = _("Catalog & Search")
        elseif current_view == "screensavers" then
            title_text = _("Screensaver & Wallpapers")
        elseif current_view == "notifications" then
            title_text = _("Notifications")
        end

        local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(title_text, dialog_w - sc(24), "NotoSerif-Regular.ttf", title_font_size, 12, true)
        local title_label = TextBoxWidget:new{
            text = title_text,
            face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = dialog_w - sc(24),
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            FrameContainer:new{
                padding_v = sc(8),
                padding_h = sc(10),
                bordersize = 0,
                title_label,
            },
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            }
        }

        if current_view == "root" then
            -- Category 1: Catalog & Search
            local catalog_mode = GitHubClient.getCatalogMode()
            local catalog_mode_label = (catalog_mode == "static") and "Storefront" or _("GitHub API")
            local cat_widget = TextWidget:new{
                text = catalog_mode_label .. " ›",
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "search.svg", _("Catalog & Search"), cat_widget, function()
                renderView("catalog")
            end)

            -- Category 2: Screensavers & Wallpapers
            local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
            local ss_settings = StorefrontScreensaverMgr.getScreensaverSettings() or {}
            local ss_local = StorefrontScreensaverMgr.listLocalScreensavers() or {}
            local ss_mode_str = _("Cover")
            if ss_settings.effective_mode == "shuffle" then
                ss_mode_str = string.format(_("Shuffle (%d)"), #ss_local)
            elseif ss_settings.effective_mode == "single" then
                ss_mode_str = _("Single")
            end
            local ss_widget = TextWidget:new{
                text = ss_mode_str .. " ›",
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "image-active.svg", _("Screensaver & Wallpapers"), ss_widget, function()
                renderView("screensavers")
            end)

            -- Category 3: Notifications
            local NotificationMgr = require("storefront_notification_mgr")
            local notif_status = NotificationMgr.isEnabled() and (NotificationMgr.getFrequency():gsub("^%l", string.upper)) or _("Off")
            local notif_widget = TextWidget:new{
                text = notif_status .. " ›",
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "bell.svg", _("Notifications"), notif_widget, function()
                renderView("notifications")
            end)

            -- Category 4: Blueprints
            local bp_widget = TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", subtext_font_size + sc(2)),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "send.svg", _("Blueprints"), bp_widget, function()
                openExternal(function(done)
                    local ok_bp, BlueprintUI = pcall(require, "storefront_blueprint_ui")
                    if ok_bp and BlueprintUI and BlueprintUI.showBlueprintsMenu then
                        BlueprintUI.showBlueprintsMenu(Storefront, done)
                    else
                        done()
                    end
                end, "root")
            end)

            -- Category 5: About Storefront
            local StorefrontAboutDialog = require("storefront_about_dialog")
            local version_str = (StorefrontAboutDialog and StorefrontAboutDialog.getVersion and StorefrontAboutDialog.getVersion()) or "1.0.0"
            local about_widget = TextWidget:new{
                text = string.format("v%s ›", version_str),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "zap.svg", _("About Storefront"), about_widget, function()
                openExternal(function(done)
                    StorefrontAboutDialog.show(Storefront, done)
                end, "root")
            end)

        elseif current_view == "catalog" then
            -- Row 1: Catalog Source
            local catalog_mode = GitHubClient.getCatalogMode()
            local catalog_mode_label = (catalog_mode == "static") and "Storefront" or _("Direct GitHub API")
            local cat_widget = TextWidget:new{
                text = catalog_mode_label,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, nil, _("Catalog source"), cat_widget, function()
                local next_mode = (catalog_mode == "static") and "direct" or "static"
                GitHubClient.setCatalogMode(next_mode)
                renderView("catalog")
            end)

            -- Row 2: Refresh Catalog
            local is_refreshing = Storefront.isRefreshing and Storefront:isRefreshing()
            local ts = Cache.getLastFetched(current_kind)
            local meta_text = is_refreshing and _("Refreshing…") or (ts and ts > 0 and formatDateTime(ts) or _("Never"))
            local meta_widget = TextWidget:new{
                text = meta_text,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "rotate-cw.svg", _("Refresh catalog"), meta_widget, function()
                if Storefront.isRefreshing and Storefront:isRefreshing() then
                    InfoMessage:new{ text = _("Catalog refresh is already in progress."), timeout = 3 }:show()
                    return
                end
                closeDialog()
                local browser_was_open = Storefront.browser_menu ~= nil
                local kind = (Storefront.browser_state and Storefront.browser_state.kind) or "plugin"
                local ok_nm, NetworkMgr2 = pcall(require, "ui/network/manager")
                local do_refresh = function()
                    Storefront:refreshCache(kind, function()
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
            end)

            -- Row 3: Clear Cache
            local cache_arrow = TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, nil, _("Clear cache…"), cache_arrow, function()
                openExternal(function(done)
                    local StorefrontClearCacheDialog = require("storefront_clear_cache_dialog")
                    StorefrontClearCacheDialog.show(Storefront, done)
                end, "catalog")
            end)

            -- Row 4: Include 0-star forks
            local StorefrontSettings = getStorefrontSettings()
            local include_zero = StorefrontSettings:readSetting("include_zero_star_forks") == true
                or (Storefront.browser_state and Storefront.browser_state.include_zero_star_forks == true)
            local fork_icon = include_zero and "check-square.svg" or "square.svg"
            add_row(content_vg, fork_icon, _("Include 0-star forks"), nil, function()
                local next_val = not include_zero
                StorefrontSettings:saveSetting("include_zero_star_forks", next_val)
                StorefrontSettings:flush()
                if Storefront.browser_state then
                    Storefront.browser_state.include_zero_star_forks = next_val
                    Storefront:saveBrowserState()
                end
                Storefront._repo_descriptors_cache = nil
                renderView("catalog")
            end)

            -- Row 5: GitHub Token
            local github_configured = GitHubClient.hasAuthToken()
            local token_status_text = github_configured and _("Configured ✓") or _("Not set")
            local token_widget = TextWidget:new{
                text = token_status_text,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, nil, _("GitHub token"), token_widget, function()
                local token_dialog
                token_dialog = InputDialog:new{
                    title = _("GitHub personal access token"),
                    description = _("Optional. Raises GitHub API rate limits."),
                    input = GitHubClient.getToken() or "",
                    input_hint = _("ghp_..."),
                    text_type = "password",
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function() UIManager:close(token_dialog) end,
                            },
                            {
                                text = _("Clear"),
                                callback = function()
                                    GitHubClient.setToken(nil)
                                    UIManager:close(token_dialog)
                                    renderView("catalog")
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    GitHubClient.setToken(token_dialog:getInputText())
                                    UIManager:close(token_dialog)
                                    renderView("catalog")
                                    InfoMessage:new{ text = _("GitHub token saved."), timeout = 2 }:show()
                                end,
                            },
                        },
                    },
                }
                UIManager:show(token_dialog)
                token_dialog:onShowKeyboard()
            end)

        elseif current_view == "screensavers" then
            local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
            local ss_settings = StorefrontScreensaverMgr.getScreensaverSettings() or {}
            local ss_local = StorefrontScreensaverMgr.listLocalScreensavers() or {}

            local mode_display_str = _("Book Cover")
            if ss_settings.effective_mode == "single" then
                local file_str = ss_settings.file or ""
                local fname = (file_str ~= "") and file_str:match("([^/\\]+)$") or _("Single")
                mode_display_str = _("Single") .. " (" .. fname .. ")"
            elseif ss_settings.effective_mode == "shuffle" then
                mode_display_str = string.format(_("Shuffle (%d)"), #ss_local)
            elseif ss_settings.effective_mode == "book_status" then
                mode_display_str = _("Reading Progress")
            elseif ss_settings.effective_mode == "blank" then
                mode_display_str = _("Blank")
            end

            -- Row 1: Mode
            local mode_widget = TextWidget:new{
                text = mode_display_str .. " ›",
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, "image-active.svg", _("Screensaver mode"), mode_widget, function()
                openExternal(function(done)
                    local StorefrontScreensaverConfig = require("storefront_screensaver_config")
                    StorefrontScreensaverConfig.show(Storefront, done)
                end, "screensavers")
            end)

            -- Row 2: Gallery
            local count_widget = TextWidget:new{
                text = string.format(_("%d wallpapers ›"), #ss_local),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, nil, _("My wallpaper collection"), count_widget, function()
                openExternal(function(done)
                    local StorefrontScreensaverGallery = require("storefront_screensaver_gallery")
                    StorefrontScreensaverGallery.show(Storefront, done)
                end, "screensavers")
            end)

        elseif current_view == "notifications" then
            local NotificationMgr = require("storefront_notification_mgr")
            local notif_enabled = NotificationMgr.isEnabled()
            local notif_icon = notif_enabled and "check-square.svg" or "square.svg"

            -- Row 1: Toggle
            add_row(content_vg, notif_icon, _("Update notifications"), nil, function()
                NotificationMgr.setEnabled(not notif_enabled)
                renderView("notifications")
            end)

            -- Row 2: Frequency & Settings
            local freq_labels = {
                hourly = _("Hourly"),
                daily = _("Daily"),
                weekly = _("Weekly"),
                monthly = _("Monthly"),
            }
            local current_freq_label = (freq_labels[NotificationMgr.getFrequency()] or _("Weekly")) .. " ›"
            local freq_widget = TextWidget:new{
                text = current_freq_label,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            }
            add_row(content_vg, nil, _("Notification settings"), freq_widget, function()
                openExternal(function(done)
                    local StorefrontNotificationSettingsDialog = require("storefront_notification_settings_dialog")
                    StorefrontNotificationSettingsDialog.show(Storefront, done)
                end, "notifications")
            end)
        end

        local action_buttons_container
        local action_layout_row = {}
        local back_btn = nil
        local close_btn = nil

        if current_view == "root" then
            close_btn = StorefrontUtils.createButton{
                text = _("Close"),
                text_font_size = ui_font_size,
                bold = true,
                width = dialog_w - sc(20),
                height = sc(36),
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = closeDialog,
            }
            action_buttons_container = CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(36) },
                close_btn,
            }
            action_layout_row = { close_btn }
        else
            local btn_gap = sc(8)
            local sub_btn_w = math.floor((dialog_w - sc(20) - btn_gap) / 2)
            back_btn = StorefrontUtils.createButton{
                text = _("‹ Back"),
                text_font_size = ui_font_size,
                bold = true,
                width = sub_btn_w,
                height = sc(36),
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = function() renderView("root") end,
            }
            close_btn = StorefrontUtils.createButton{
                text = _("Close"),
                text_font_size = ui_font_size,
                bold = true,
                width = sub_btn_w,
                height = sc(36),
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = closeDialog,
            }
            action_buttons_container = HorizontalGroup:new{
                align = "center",
                back_btn,
                HorizontalSpan:new{ width = btn_gap },
                close_btn,
            }
            action_layout_row = { back_btn, close_btn }
        end

        table.insert(content_vg, FrameContainer:new{
            padding = sc(6),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(36) },
                action_buttons_container,
            }
        })

        local layout = {}
        for _, r in ipairs(focusable_rows) do
            table.insert(layout, { r })
        end
        table.insert(layout, action_layout_row)

        if overlay then
            local ov = overlay
            overlay = nil
            card = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg,
            width = dialog_w,
            content_vg,
        }

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

        overlay.onClose = function()
            if current_view ~= "root" then
                renderView("root")
                return true
            end
            closeDialog()
            return true
        end

        for _, r in ipairs(focusable_rows) do
            r.show_parent = overlay
        end
        if back_btn then
            back_btn.show_parent = overlay
        end
        if close_btn then
            close_btn.show_parent = overlay
        end

        UIManager:show(overlay, "ui")
    end

    renderView(current_view)
end

--- Sub-dialog forwarding for backwards compatibility
function StorefrontSettingsCard.showCatalogDialog(Storefront, on_back)
    StorefrontSettingsCard.show(Storefront, "catalog", on_back)
end

function StorefrontSettingsCard.showScreensaversDialog(Storefront, on_back)
    StorefrontSettingsCard.show(Storefront, "screensavers", on_back)
end

function StorefrontSettingsCard.showNotificationsDialog(Storefront, on_back)
    StorefrontSettingsCard.show(Storefront, "notifications", on_back)
end

return StorefrontSettingsCard
