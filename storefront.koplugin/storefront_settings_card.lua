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
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local Cache = require("storefront_cache")
local GitHubClient = require("storefront_net_github")
local storefront_theme = require("storefront_theme")

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

    local ui_font_size = 16
    local title_font_size = 18

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
        end

        local function span()
            return VerticalSpan:new{ width = storefront_theme.gap }
        end

        -- Title Widget
        local title_label = TextWidget:new{
            text = _("Settings"),
            face = Font:getFace("cfont", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local title_container = FrameContainer:new{
            padding = sc(10),
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
                    icon_widget = ImageWidget:new{
                        file = getAssetPath(icon_arg),
                        width = sc(20),
                        height = sc(20),
                        scale_factor = 0,
                        alpha = true,
                    }
                elseif type(icon_arg) == "string" then
                    icon_widget = TextWidget:new{
                        text = icon_arg,
                        face = Font:getFace("cfont", ui_font_size),
                        fgcolor = callback and Blitbuffer.COLOR_BLACK or storefront_theme.color_label_dim,
                    }
                end
                if icon_widget then
                    icon_w = (icon_widget.getSize and icon_widget:getSize().w) or sc(20)
                    icon_w = icon_w + sc(8)
                    table.insert(row_elements, icon_widget)
                    table.insert(row_elements, HorizontalSpan:new{ width = sc(8) })
                end
            end

            -- Measure right widget and available row width
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = 0
            if right_widget then
                right_w = (right_widget.getSize and right_widget:getSize().w) or sc(60)
            end

            local max_left_w = avail_w - icon_w - right_w - sc(8)
            if max_left_w < sc(60) then
                max_left_w = sc(60)
            end

            -- Left Text
            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = callback and Blitbuffer.COLOR_BLACK or storefront_theme.color_label_dim,
                width = max_left_w,
                alignment = "left",
            }
            table.insert(row_elements, txt)

            -- Flexible Spacer to right-align right_widget
            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = avail_w - icon_w - left_used_w - right_w
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
                padding = frame_padding,
                width = dialog_w - sc(4),
                row_content,
            }

            if not callback then
                return frame
            end

            local item = InputContainer:new{ frame }
            local row_size = frame:getSize() or { w = dialog_w - sc(4), h = 0 }
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
                                w = row_size.w or (dialog_w - sc(4)),
                                h = row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                callback()
                return true
            end
            return item
        end

        local StorefrontSettings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/Storefront.lua")

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", ui_font_size - 3),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(5),
                padding_left = sc(8),
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
            face = Font:getFace("cfont", ui_font_size - 1),
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

        -- Refresh Cache Row
        local ts = Cache.getLastFetched(current_kind)
        local time_str = ts and ts > 0 and formatDateTime(ts) or _("Never")
        local total_repos = #Cache.listRepos(current_kind)
        local meta_text = string.format("%d · %s", total_repos, time_str)
        local meta_widget = TextWidget:new{
            text = meta_text,
            face = Font:getFace("cfont", ui_font_size - 2),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row("rotate-cw.svg", _("Refresh cache"), meta_widget, function()
            UIManager:close(overlay, "ui")
            Storefront:browserRefresh()
        end))

        -- Clear README Cache Row
        table.insert(content_vg, create_setting_row(nil, _("Clear README cache"), nil, function()
            UIManager:close(overlay, "ui")
            Storefront:clearCachedReadmeFiles()
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
            face = Font:getFace("cfont", ui_font_size - 1),
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
                                UIManager:show(InfoMessage:new{
                                    text = _("GitHub token saved."),
                                    timeout = 2,
                                })
                                refresh()
                            end,
                        },
                    },
                },
            }
            UIManager:show(token_dialog)
            token_dialog:onShowKeyboard()
        end))

        -- SECTION 3: ABOUT STOREFRONT
        table.insert(content_vg, create_section_header(_("About Storefront")))

        -- About Storefront Row
        local StorefrontAboutDialog = require("storefront_about_dialog")
        local current_ch = StorefrontAboutDialog.getChannel()
        local version_str = StorefrontAboutDialog.getVersion()
        local ver_widget = TextWidget:new{
            text = string.format("v%s", version_str),
            face = Font:getFace("cfont", ui_font_size - 1),
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
            face = Font:getFace("cfont", ui_font_size - 1),
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

        -- 4. Close Button Row
        local close_text_widget = TextWidget:new{
            text = _("Close"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local close_row_content = HorizontalGroup:new{
            HorizontalSpan:new{ width = (dialog_w - close_text_widget:getSize().w) / 2 - sc(10) },
            close_text_widget,
        }
        local close_frame = FrameContainer:new{
            bordersize = 0,
            padding = sc(10),
            width = dialog_w - sc(4),
            close_row_content,
        }
        local close_btn = InputContainer:new{ close_frame }
        local close_size = close_frame:getSize() or { w = dialog_w - sc(4), h = 0 }
        close_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = close_btn.dimen
                        if not dim then
                            return Geom:new{ x = -1, y = -1, w = 1, h = 1 }
                        end
                        return Geom:new{
                            x = dim.x or 0,
                            y = dim.y or 0,
                            w = close_size.w or (dialog_w - sc(4)),
                            h = close_size.h or 0,
                        }
                    end
                }
            }
        }
        close_btn.onTap = function()
            UIManager:close(overlay, "ui")
            return true
        end
        table.insert(content_vg, close_btn)

        -- Build modal frame
        local card = FrameContainer:new{
            padding = 0,
            radius = sc(12),
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg,
            width = dialog_w,
            content_vg
        }

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = {
                Close = { { "Back" } }
            },
            card
        }

        overlay.onClose = function()
            UIManager:close(overlay, "ui")
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontSettingsCard
