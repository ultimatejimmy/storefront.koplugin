local Screen = require("device").screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
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
local _ = require("gettext")
local storefront_theme = require("storefront_theme")

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
        fullname = "ultimatejimmy",
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
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local GitHub = require("storefront_net_github")

    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Checking for Storefront updates…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local current_version = StorefrontAboutDialog.getVersion()
        local channel = StorefrontAboutDialog.getChannel()

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

        UIManager:close(progress)

        if not target_release then
            local err_msg = (type(err) == "table" and err.body) and tostring(err.body) or tostring(err or _("Unknown error"))
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to check for Storefront updates: %s"), err_msg),
                timeout = 5,
            })
            return
        end

        local latest_tag = target_release.tag_name or target_release.name or ""
        local clean_latest = latest_tag:gsub("^[vV]", "")
        local clean_current = current_version:gsub("^[vV]", "")

        local repo_desc = {
            owner = "ultimatejimmy",
            name = "storefront.koplugin",
            full_name = "ultimatejimmy/storefront.koplugin",
            description = _("Plugin and patch browser for KOReader."),
        }

        if clean_latest ~= "" and clean_latest ~= clean_current then
            UIManager:show(ConfirmBox:new{
                text = string.format(_("Storefront update available: v%s (Current: v%s)\n\nWould you like to install the update now?"), clean_latest, clean_current),
                ok_text = _("Update"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    if Storefront and type(Storefront.promptPluginInstallOptions) == "function" then
                        Storefront:promptPluginInstallOptions(repo_desc, target_release)
                    end
                end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Storefront is up to date (v%s)."), current_version),
                timeout = 4,
            })
        end
    end)
end

function StorefrontAboutDialog.show(Storefront, on_close_cb)
    local meta = loadStorefrontMeta()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = 16
    local title_font_size = 18

    local current_channel = StorefrontAboutDialog.getChannel()
    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
        end

        -- Header
        local title_label = TextWidget:new{
            text = _("About Storefront"),
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

        -- Metadata Info Block
        local name_str = meta.fullname or meta.name or "Storefront"
        local ver_str = meta.version or "1.0.0"
        local author_str = meta.author or "ultimatejimmy"
        local desc_str = meta.description or _("Plugin and patch browser for KOReader.")

        local meta_text = string.format("%s v%s\n%s: %s\n\n%s", name_str, ver_str, _("Author"), author_str, desc_str)

        local meta_box = TextBoxWidget:new{
            text = meta_text,
            face = Font:getFace("cfont", ui_font_size - 1),
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = dialog_w - sc(24),
            alignment = "left",
        }

        local meta_frame = FrameContainer:new{
            bordersize = 0,
            padding = sc(10),
            width = dialog_w - sc(4),
            meta_box,
        }

        table.insert(content_vg, meta_frame)

        -- Section Divider: Update Channel
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        local channel_header = TextWidget:new{
            text = _("Storefront Update Channel"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = storefront_theme.color_label_dim,
        }

        local channel_header_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            channel_header,
        }
        table.insert(content_vg, channel_header_container)

        -- Option Picker Radio Buttons (Stable vs Beta)
        local options = {
            {
                key = "stable",
                label = _("Stable"),
                desc = _("Official stable releases only"),
            },
            {
                key = "beta",
                label = _("Beta"),
                desc = _("Include pre-releases & beta builds"),
            },
        }

        for _, opt in ipairs(options) do
            local is_selected = (current_channel == opt.key)
            local bullet_str = is_selected and "● " or "○ "
            local border_w = is_selected and sc(2) or sc(1)
            local border_col = is_selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY

            local bullet_widget = TextWidget:new{
                text = bullet_str,
                face = Font:getFace("cfont", ui_font_size),
                bold = is_selected,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local label_box = TextBoxWidget:new{
                text = string.format("%s - %s", opt.label, opt.desc),
                face = Font:getFace("cfont", ui_font_size - 1),
                bold = is_selected,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = dialog_w - sc(54),
                alignment = "left",
            }

            local row_content = HorizontalGroup:new{
                bullet_widget,
                HorizontalSpan:new{ width = sc(4) },
                label_box,
            }

            local opt_frame = FrameContainer:new{
                bordersize = border_w,
                color = border_col,
                radius = sc(6),
                padding = sc(8),
                width = dialog_w - sc(16),
                background = storefront_theme.color_bg,
                row_content,
            }

            local item = InputContainer:new{ opt_frame }
            local row_size = opt_frame:getSize() or { w = dialog_w - sc(16), h = 0 }
            local opt_key = opt.key

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
                                w = row_size.w or (dialog_w - sc(16)),
                                h = row_size.h or 0,
                            }
                        end
                    }
                }
            }

            item.onTap = function()
                current_channel = opt_key
                StorefrontAboutDialog.setChannel(opt_key)
                refresh()
                return true
            end

            table.insert(content_vg, FrameContainer:new{
                bordersize = 0,
                padding_left = sc(6),
                padding_right = sc(6),
                padding_bottom = sc(4),
                item,
            })
        end

        -- Check for updates Button
        local check_text_widget = TextWidget:new{
            text = _("Check for updates"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local check_row_content = HorizontalGroup:new{
            HorizontalSpan:new{ width = (dialog_w - check_text_widget:getSize().w) / 2 - sc(10) },
            check_text_widget,
        }
        local check_frame = FrameContainer:new{
            bordersize = 0,
            padding = sc(10),
            width = dialog_w - sc(4),
            check_row_content,
        }
        local check_btn = InputContainer:new{ check_frame }
        local check_size = check_frame:getSize() or { w = dialog_w - sc(4), h = 0 }
        check_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = check_btn.dimen
                        if not dim then
                            return Geom:new{ x = -1, y = -1, w = 1, h = 1 }
                        end
                        return Geom:new{
                            x = dim.x or 0,
                            y = dim.y or 0,
                            w = check_size.w or (dialog_w - sc(4)),
                            h = check_size.h or 0,
                        }
                    end
                }
            }
        }
        check_btn.onTap = function()
            UIManager:close(overlay, "ui")
            StorefrontAboutDialog.checkForUpdates(Storefront)
            return true
        end
        table.insert(content_vg, check_btn)

        -- Bottom Divider line
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        -- Close Button
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
            if on_close_cb then
                on_close_cb()
            end
            return true
        end
        table.insert(content_vg, close_btn)

        -- Build modal card
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
            if on_close_cb then
                on_close_cb()
            end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontAboutDialog
