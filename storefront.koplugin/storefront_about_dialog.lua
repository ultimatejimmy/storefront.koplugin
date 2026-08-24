local Screen = require("device").screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local GestureRange = require("ui/gesturerange")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontToast = require("storefront_toast")

local StorefrontAboutDialog = {}

local function sc(val)
    return Screen:scaleBySize(val)
end

-- Plugin directory resolution
local function getPluginDir()
    local info = debug.getinfo(1, "S")
    local source = info.source or ""
    return source:match("^@(.*[/\\])") or "./"
end

local function loadStorefrontMeta()
    local dir = getPluginDir()
    local meta_path = dir .. "_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" then
        return meta
    end
    return {
        name = "Storefront",
        version = "1.0.0",
        author = "ultimatejimmy",
        description = _("Plugin and patch browser for KOReader."),
    }
end

function StorefrontAboutDialog.getVersion()
    local meta = loadStorefrontMeta()
    return meta and meta.version or "1.0.0"
end

-- Channel Settings Storage
local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront_channel.lua"
local ChannelSettings = LuaSettings:open(SETTINGS_PATH)
local CHANNEL_KEY = "storefront_update_channel"

function StorefrontAboutDialog.getChannel()
    local val = ChannelSettings:readSetting(CHANNEL_KEY)
    if val == "beta" then
        return "beta"
    end
    return "stable"
end

function StorefrontAboutDialog.setChannel(channel)
    if channel == "beta" then
        ChannelSettings:saveSetting(CHANNEL_KEY, "beta")
    else
        ChannelSettings:saveSetting(CHANNEL_KEY, "stable")
    end
    ChannelSettings:flush()
end

function StorefrontAboutDialog.checkForUpdates(Storefront)
    local NetworkMgr = require("ui/network/manager")
    local GitHub = require("storefront_net_github")
    local Trapper = require("ui/trapper")

    NetworkMgr:runWhenOnline(function()
        local current_version = StorefrontAboutDialog.getVersion()
        local channel = StorefrontAboutDialog.getChannel()

        local function doCheckRelease()
            local target_release, err
            if channel == "beta" then
                local releases, rel_err = GitHub.fetchReleases("ultimatejimmy", "storefront.koplugin")
                if releases and #releases > 0 then
                    target_release = releases[1]
                else
                    err = rel_err
                end
            else
                target_release, err = GitHub.fetchLatestRelease("ultimatejimmy", "storefront.koplugin")
            end

            if target_release and type(target_release) == "table" then
                return {
                    ok = true,
                    tag_name = tostring(target_release.tag_name or target_release.name or ""),
                    name = tostring(target_release.name or ""),
                    body = (type(target_release.body) == "string") and target_release.body or "",
                    published_at = tostring(target_release.published_at or ""),
                    stargazers_count = tonumber(target_release.stargazers_count) or tonumber(target_release.stars) or 0,
                }
            else
                return {
                    ok = false,
                    err = (type(err) == "table" and err.body) and tostring(err.body) or tostring(err or "Failed to query release"),
                }
            end
        end

        local progress_toast = StorefrontToast.show(_("Checking for Storefront updates…"), 0)

        Trapper:wrap(function()
            local completed, res = Trapper:dismissableRunInSubprocess(function()
                local ok, result = pcall(doCheckRelease)
                if ok and result then return result end
                return { ok = false, err = tostring(result or "Subprocess error") }
            end, progress_toast)

            if progress_toast and progress_toast.close then
                progress_toast:close()
            end

            if not completed then
                StorefrontToast.show(_("Update check was cancelled."), 3)
                return
            end

            local target_release = (res and res.ok) and res or nil
            local err = res and res.err

            if not target_release then
                local err_msg = tostring(err or _("Unknown error"))
                StorefrontToast.show(string.format(_("Failed to check for Storefront updates: %s"), err_msg), 5)
                return
            end

            local latest_tag = target_release.tag_name or target_release.name or ""
            local clean_latest = latest_tag:gsub("^[vV]", "")
            local clean_current = current_version:gsub("^[vV]", "")

            local Cache = require("storefront_cache")
            local cached_repo = Cache.getRepoByName("ultimatejimmy", "storefront.koplugin")
                or Cache.getRepoByName("ultimatejimmy", "storefront")
            local stars_count = (cached_repo and tonumber(cached_repo.stars))
                or (cached_repo and cached_repo.data and tonumber(cached_repo.data.stargazers_count))
                or (target_release and (tonumber(target_release.stargazers_count) or tonumber(target_release.stars)))
                or 0

            local repo_desc = cached_repo or {
                owner = "ultimatejimmy",
                name = "storefront.koplugin",
                full_name = "ultimatejimmy/storefront.koplugin",
                kind = "plugin",
                stars = stars_count,
                description = _("Plugin and patch browser for KOReader."),
                latest_release = target_release,
                tag_name = latest_tag,
                latest_version = clean_latest,
                data = {
                    owner = { login = "ultimatejimmy" },
                    stargazers_count = stars_count,
                    default_branch = "main",
                }
            }
            if not repo_desc.stars or repo_desc.stars == 0 then
                repo_desc.stars = stars_count
            end
            repo_desc.latest_release = target_release
            repo_desc.latest_version = clean_latest

            if clean_latest ~= "" and clean_latest ~= clean_current then
                local DetailsDialog = require("storefront_details_dialog")
                local details_dialog = DetailsDialog:new{
                    Storefront = Storefront,
                    repo = repo_desc,
                    kind = "update",
                    update_item = {
                        plugin = { dirname = "storefront.koplugin", version = clean_current },
                        remote = target_release,
                        needs_update = true,
                    },
                    default_tab = "release_notes",
                }
                details_dialog:show()
            else
                StorefrontToast.show(string.format(_("Storefront is up to date (v%s)."), current_version), 4)
            end
        end)
    end)
end

function StorefrontAboutDialog.show(Storefront, on_close_cb)
    local meta = loadStorefrontMeta()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local current_channel = StorefrontAboutDialog.getChannel()
    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
        end

        -- Title Header (Matching Settings Card style)
        local StorefrontUtils = require("storefront_utils")
        local title_text = _("About Storefront")
        local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(title_text, dialog_w - sc(24), "NotoSerif-Regular.ttf", title_font_size, 12, true)
        local title_label = TextBoxWidget:new{
            text = title_text,
            face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = dialog_w - sc(24),
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

        -- Helper to create section header (Matching Settings Card style)
        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", storefront_theme.section_header_font_size or 16),
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

        -- Helper to create setting row (Matching Settings Card style)
        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or sc(60)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then
                max_left_w = sc(60)
            end

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = avail_w - left_used_w - right_w
            if spacer_w < sc(8) then
                spacer_w = sc(8)
            end

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
                padding = frame_padding,
                width = dialog_w - sc(4),
                HorizontalGroup:new(row_elements),
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
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
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

        -- SECTION 1: ABOUT
        table.insert(content_vg, create_section_header(_("About")))

        -- Version Row
        local ver_widget = TextWidget:new{
            text = string.format("v%s", meta.version or "1.0.0"),
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Version"), ver_widget, nil))

        -- Author Row
        local author_widget = TextWidget:new{
            text = meta.author or "ultimatejimmy",
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Author"), author_widget, nil))

        -- SECTION 2: UPDATES
        table.insert(content_vg, create_section_header(_("Updates")))

        -- Update Channel Row
        local channel_label = (current_channel == "beta") and _("Beta") or _("Stable")
        local channel_widget = TextWidget:new{
            text = channel_label,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Update channel"), channel_widget, function()
            local next_ch = (current_channel == "beta") and "stable" or "beta"
            StorefrontAboutDialog.setChannel(next_ch)
            current_channel = next_ch
            refresh()
        end))

        -- Check for updates Row
        table.insert(content_vg, create_setting_row(_("Check for updates"), nil, function()
            UIManager:close(overlay, "ui")
            StorefrontAboutDialog.checkForUpdates(Storefront)
        end))

        -- Bottom Divider Line
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
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
                UIManager:close(overlay, "ui")
                if on_close_cb then on_close_cb() end
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

        -- Build modal card (Matching Settings Card style 1:1)
        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
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
            key_events = { Close = { { "Back" } } },
            card
        }

        overlay.onClose = function()
            UIManager:close(overlay, "ui")
            if on_close_cb then on_close_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontAboutDialog
