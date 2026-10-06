--- storefront_notification_settings_dialog.lua
--- Dedicated settings sub-dialog for configuring notification frequency and viewing snooze options.

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
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")
local NotificationMgr = require("storefront_notification_mgr")

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

local StorefrontNotificationSettingsDialog = {}

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function getFrequencies()
    return {
        { key = "hourly", label = _("Every hour") },
        { key = "daily",  label = _("Every day") },
        { key = "weekly", label = _("Every week") },
        { key = "monthly", label = _("Every month") },
    }
end

--- Shows the notification settings sub-dialog.
---@param Storefront table Storefront instance
---@param on_close_callback? function callback when dialog closes
function StorefrontNotificationSettingsDialog.show(Storefront, on_close_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = storefront_theme.face_label_size or 16
    local header_font_size = storefront_theme.section_header_font_size or 14
    local subtext_font_size = storefront_theme.subtext_font_size or 14
    local title_font_size = 18

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

        local current_freq = NotificationMgr.getFrequency()

        -- Title
        local title_label = TextBoxWidget:new{
            text = _("Notification Settings"),
            face = StorefrontUtils.getTitleFace(title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = dialog_w - sc(24),
        }

        local title_container = FrameContainer:new{
            padding_top = sc(8),
            padding_bottom = sc(8),
            padding_left = sc(14),
            padding_right = sc(14),
            bordersize = 0,
            title_label,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_container,
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            },
        }

        local focusable_rows = {}

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", header_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding_top = sc(4),
                padding_bottom = sc(4),
                padding_left = sc(12),
                padding_right = sc(12),
                bordersize = 0,
                width = dialog_w - sc(4),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        -- SECTION 1: FREQUENCY
        table.insert(content_vg, create_section_header(_("Frequency")))

        for _, item in ipairs(getFrequencies()) do
            local is_selected = (item.key == current_freq)
            local radio_symbol = is_selected and "●" or "○"

            local radio_widget = TextWidget:new{
                text = radio_symbol,
                face = Font:getFace("cfont", ui_font_size + sc(2)),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local label_widget = TextWidget:new{
                text = item.label,
                face = Font:getFace("cfont", ui_font_size),
                bold = is_selected,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local row_content = HorizontalGroup:new{
                align = "center",
                radio_widget,
                HorizontalSpan:new{ width = sc(10) },
                label_widget,
            }

            local frame = FrameContainer:new{
                bordersize = 0,
                padding_top = sc(6),
                padding_bottom = sc(6),
                padding_left = sc(14),
                padding_right = sc(14),
                width = dialog_w - sc(4),
                row_content,
            }

            local row_item = InputContainer:new{ frame }
            row_item.frame = frame
            row_item.callback = function()
                NotificationMgr.setFrequency(item.key)
                if Storefront and Storefront.scheduleNotificationTimer then
                    Storefront:scheduleNotificationTimer()
                end
                refresh()
            end
            row_item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            return row_item.dimen or frame:getSize()
                        end,
                    },
                },
            }
            row_item.onTap = function()
                row_item.callback()
                return true
            end
            row_item.isFocusable = function() return true end
            row_item.onFocus = function(self)
                if self.frame then
                    self.frame.invert = true
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            row_item.onUnfocus = function(self)
                if self.frame then
                    self.frame.invert = false
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            row_item.onTapSelect = function(self)
                if self.callback then self.callback() end
                return true
            end

            table.insert(focusable_rows, row_item)
            table.insert(content_vg, row_item)
        end

        -- Divider
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        -- SECTION 2: SNOOZE OPTIONS
        table.insert(content_vg, create_section_header(_("Snooze Options")))

        local desc_widget = TextBoxWidget:new{
            text = _("When tapping 'Remind Me Later' on an update notification, you can choose:"),
            face = Font:getFace("cfont", subtext_font_size),
            fgcolor = storefront_theme.color_label_dim,
            width = dialog_w - sc(28),
            alignment = "left",
        }

        local snooze_vg = VerticalGroup:new{
            align = "left",
            desc_widget,
            VerticalSpan:new{ width = sc(4) },
            TextWidget:new{
                text = "• " .. _("1 hour"),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = sc(2) },
            TextWidget:new{
                text = "• " .. _("4 hours"),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = sc(2) },
            TextWidget:new{
                text = "• " .. _("Tomorrow"),
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }

        table.insert(content_vg, FrameContainer:new{
            padding_top = sc(6),
            padding_bottom = sc(6),
            padding_left = sc(14),
            padding_right = sc(14),
            bordersize = 0,
            snooze_vg,
        })

        -- SECTION 3: TESTING & PREVIEW (Only shown if config has debug/testing enabled)
        if NotificationMgr.isTestingConfigured() then
            -- Divider
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_DARK_GRAY,
            })

            table.insert(content_vg, create_section_header(_("Testing & Preview")))

            local is_debug_active = NotificationMgr.isDebugAlwaysTrigger()
            local icon_file = getAssetPath(is_debug_active and "check-square.svg" or "square.svg")
            local check_widget
            local check_sz = ui_font_size + sc(2)
            if icon_file then
                check_widget = ImageWidget:new{
                    file = icon_file,
                    width = check_sz,
                    height = check_sz,
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
            else
                local debug_check_sym = is_debug_active and "☑" or "☐"
                check_widget = TextWidget:new{
                    text = debug_check_sym,
                    face = Font:getFace("cfont", check_sz),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end

            local debug_label = TextWidget:new{
                text = _("Trigger on every startup (testing)"),
                face = Font:getFace("cfont", subtext_font_size),
                bold = is_debug_active,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local debug_row_content = HorizontalGroup:new{
                align = "center",
                check_widget,
                HorizontalSpan:new{ width = sc(10) },
                debug_label,
            }

            local debug_frame = FrameContainer:new{
                bordersize = 0,
                padding_top = sc(6),
                padding_bottom = sc(6),
                padding_left = sc(14),
                padding_right = sc(14),
                width = dialog_w - sc(4),
                debug_row_content,
            }

            local debug_row_item = InputContainer:new{ debug_frame }
            debug_row_item.frame = debug_frame
            debug_row_item.callback = function()
                NotificationMgr.setDebugAlwaysTrigger(not is_debug_active)
                refresh()
            end
            debug_row_item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            return debug_row_item.dimen or debug_frame:getSize()
                        end,
                    },
                },
            }
            debug_row_item.onTap = function()
                debug_row_item.callback()
                return true
            end
            debug_row_item.isFocusable = function() return true end
            debug_row_item.onFocus = function(self)
                if self.frame then
                    self.frame.invert = true
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            debug_row_item.onUnfocus = function(self)
                if self.frame then
                    self.frame.invert = false
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            debug_row_item.onTapSelect = function(self)
                if self.callback then self.callback() end
                return true
            end

            table.insert(focusable_rows, debug_row_item)
            table.insert(content_vg, debug_row_item)

            -- Preview button
            local preview_btn = StorefrontUtils.createButton{
                text = _("Preview Notification Now"),
                text_font_size = subtext_font_size,
                bold = false,
                width = dialog_w - sc(24),
                height = sc(32),
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                bordersize = sc(1),
                callback = function()
                    closeDialog()
                    local NotificationUI = require("storefront_notification_ui")
                    local test_items = (Storefront and Storefront.collectUpdatesForNotification and Storefront:collectUpdatesForNotification()) or {}
                    if #test_items == 0 then
                        test_items = {
                            { name = "Libbee", version = "v26.9.13-beta", kind = "plugin" },
                        }
                    end
                    NotificationUI.show(Storefront, test_items)
                end,
            }

            table.insert(content_vg, FrameContainer:new{
                padding_top = sc(4),
                padding_bottom = sc(4),
                padding_left = sc(10),
                padding_right = sc(10),
                bordersize = 0,
                width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(20), h = sc(32) },
                    preview_btn,
                },
            })
            table.insert(focusable_rows, preview_btn)
        end

        -- Divider
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        -- Close Button
        local close_btn = StorefrontUtils.createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = storefront_theme.border_btn or sc(1),
            radius = storefront_theme.radius_btn or sc(4),
            width = dialog_w - sc(20),
            height = sc(36),
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                closeDialog()
            end,
        }

        table.insert(content_vg, FrameContainer:new{
            padding = sc(6),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(36) },
                close_btn,
            },
        })

        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = storefront_theme.border_window or sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg,
        }

        local layout = {}
        for _, r in ipairs(focusable_rows) do
            table.insert(layout, { r })
        end
        table.insert(layout, { close_btn })

        local Input = Device and Device.input
        local key_events = {
            Close = { { "Back" }, { "Escape" } },
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

        for _, r in ipairs(focusable_rows) do
            r.show_parent = overlay
        end
        close_btn.show_parent = overlay

        overlay.onClose = function()
            closeDialog()
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontNotificationSettingsDialog
