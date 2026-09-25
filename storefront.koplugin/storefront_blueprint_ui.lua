--- Storefront Blueprint UI Module
--- Presentation layer for exporting, inspecting, importing, and cloud-sharing Blueprints.
---
--- @module StorefrontBlueprintUI

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
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
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")
local StorefrontToast = require("storefront_toast")

local BlueprintMgr = require("storefront_blueprint_mgr")
local BlueprintCloud = require("storefront_blueprint_cloud")

local StorefrontBlueprintUI = {}

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

    local paths_to_try = {
        rel_path,
        "assets/" .. filename,
        "./assets/" .. filename,
        "./storefront.koplugin/assets/" .. filename,
    }
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
    end
    _asset_path_cache[filename] = false
    return nil
end

local function formatDateTime(ts)
    if not ts or ts <= 0 then return _("Unknown") end
    return os.date("%Y-%m-%d %H:%M", ts)
end

--- Shows the Blueprints management submenu.
--- @param Storefront table
--- @param on_close_callback? fun()
function StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(420))

    local ui_font_size = storefront_theme.face_label_size or 16
    local title_font_size = storefront_theme.title_font_size or 20
    local subtext_font_size = storefront_theme.subtext_font_size or 14

    local overlay
    local focusable_rows = {}

    local function dismissMenu()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
    end

    local function closeDialog()
        dismissMenu()
        if on_close_callback then
            on_close_callback()
        end
    end

    local title_label = TextWidget:new{
        text = _("Blueprints"),
        face = Font:getFace("cfont", title_font_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local content_vg = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            padding_v = sc(8),
            padding_h = sc(12),
            bordersize = 0,
            title_label,
        },
        LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }
    }

    local function create_menu_row(title, subtitle, icon_str, callback)
        local left_vg = VerticalGroup:new{ align = "left" }
        table.insert(left_vg, TextWidget:new{
            text = title,
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
        if subtitle and subtitle ~= "" then
            table.insert(left_vg, VerticalSpan:new{ width = sc(2) })
            table.insert(left_vg, TextWidget:new{
                text = subtitle,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = storefront_theme.color_label_dim,
            })
        end

        local right_arrow = TextWidget:new{
            text = "›",
            face = Font:getFace("cfont", ui_font_size + sc(2)),
            fgcolor = storefront_theme.color_label_dim,
        }

        local row_w = dialog_w - sc(24)
        local left_w = (left_vg.getSize and left_vg:getSize().w) or (row_w - sc(30))
        local arrow_w = (right_arrow.getSize and right_arrow:getSize().w) or sc(16)
        local spacer_w = math.max(sc(8), row_w - left_w - arrow_w)

        local row_elements = { left_vg, HorizontalSpan:new{ width = spacer_w }, right_arrow }
        local row_hg = HorizontalGroup:new(row_elements)

        local frame = FrameContainer:new{
            bordersize = 0,
            padding_v = sc(8),
            padding_h = sc(12),
            width = dialog_w - sc(4),
            row_hg,
        }

        local item = InputContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = frame:getSize().h },
            frame,
        }
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

        table.insert(focusable_rows, item)
        table.insert(content_vg, item)
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
    end

    -- Row 1: Export Blueprint
    create_menu_row(_("Export Blueprint…"), _("Save current plugins, patches, fonts & settings"), "📋", function()
        dismissMenu()
        UIManager:nextTick(function()
            StorefrontBlueprintUI.showExportDialog(Storefront, function()
                StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
            end)
        end)
    end)

    -- Row 2: Apply Blueprint from Storage
    create_menu_row(_("Apply Blueprint from Storage…"), _("Browse saved .blueprint files to inspect and install"), "📥", function()
        dismissMenu()
        UIManager:nextTick(function()
            StorefrontBlueprintUI.showFilePickerDialog(Storefront, function(bp)
                if bp then
                    StorefrontBlueprintUI.showDiffDialog(Storefront, bp, function()
                        StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
                    end)
                else
                    StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
                end
            end)
        end)
    end)

    -- Row 3: Share via Cloud Code
    create_menu_row(_("Share via Cloud Shortcode…"), _("Upload blueprint to get a 6-character sharing code"), "☁️", function()
        local bp = BlueprintMgr.generateBlueprint({ Storefront = Storefront })
        StorefrontToast:new{ text = _("Uploading blueprint to cloud…"), timeout = 3 }:show()
        BlueprintCloud.uploadBlueprint(bp, function(ok, res)
            if ok and res then
                dismissMenu()
                StorefrontBlueprintUI.showCloudShareDialog(Storefront, res, bp, function()
                    StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
                end)
            else
                UIManager:nextTick(function()
                    StorefrontToast:new{ text = _("Upload failed: ") .. tostring(res), timeout = 4 }:show()
                end)
            end
        end)
    end)

    -- Row 4: Enter Cloud Code
    create_menu_row(_("Enter Cloud Code to Download…"), _("Type a 6-character code to fetch and install a setup"), "🔑", function()
        dismissMenu()
        UIManager:nextTick(function()
            StorefrontBlueprintUI.showEnterCodeDialog(Storefront, function(bp)
                if bp then
                    StorefrontBlueprintUI.showDiffDialog(Storefront, bp, function()
                        StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
                    end)
                else
                    StorefrontBlueprintUI.showBlueprintsMenu(Storefront, on_close_callback)
                end
            end)
        end)
    end)

    -- Close Button
    local close_btn = StorefrontUtils.createButton{
        text = _("Close"),
        text_font_size = ui_font_size,
        bold = true,
        width = dialog_w - sc(24),
        height = sc(34),
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        callback = closeDialog,
    }

    table.insert(content_vg, FrameContainer:new{
        padding = sc(8),
        bordersize = 0,
        width = dialog_w - sc(4),
        CenterContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(24), h = sc(34) },
            close_btn,
        }
    })

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
    for _, r in ipairs(focusable_rows) do
        table.insert(layout, { r })
    end
    table.insert(layout, { close_btn })

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = layout,
        selected = { x = 1, y = 1 },
        card,
    }

    for _, r in ipairs(focusable_rows) do
        r.show_parent = overlay
    end
    close_btn.show_parent = overlay

    overlay.onClose = function()
        overlay = nil
        if on_close_callback then on_close_callback() end
    end

    UIManager:show(overlay)
end

--- Shows the Export Blueprint dialog with custom options.
--- @param Storefront table
--- @param on_done? fun()
function StorefrontBlueprintUI.showExportDialog(Storefront, on_done)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(440))

    local ui_font_size = storefront_theme.face_label_size or 16
    local title_font_size = storefront_theme.title_font_size or 20
    local subtext_font_size = storefront_theme.subtext_font_size or 14

    local bp_name = "KOReader Setup " .. os.date("%Y-%m-%d")
    local version_strategy = "latest"
    local inc_plugins = true
    local inc_patches = true
    local inc_fonts = true
    local inc_screensavers = true
    local inc_settings = true

    local overlay
    local refresh

    local function dismissDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
    end

    local function closeDialog()
        dismissDialog()
        if on_done then on_done() end
    end

    local saved_focus_x = 1
    local saved_focus_y = 1
    local was_refreshed = false
    local keep_focus_highlight = false

    refresh = function(keep_highlight)
        if overlay then
            saved_focus_x = (overlay.selected and overlay.selected.x) or 1
            saved_focus_y = (overlay.selected and overlay.selected.y) or 1
            was_refreshed = true
            keep_focus_highlight = (keep_highlight == true)
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local content_vg = VerticalGroup:new{ align = "left" }

        -- Title
        table.insert(content_vg, FrameContainer:new{
            padding_v = sc(8),
            padding_h = sc(12),
            bordersize = 0,
            TextWidget:new{
                text = _("Export Blueprint"),
                face = Font:getFace("cfont", title_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        })
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        })

        local focusable_rows = {}

        local function add_toggle_row(label_text, value, on_toggle)
            local get_val = (type(value) == "function") and value or (function() return value end)
            local current_val = get_val()
            local icon_file = getAssetPath(current_val and "check-square.svg" or "square.svg")
            local icon_part
            local check_sz = ui_font_size + sc(2)
            if icon_file then
                icon_part = ImageWidget:new{
                    file = icon_file,
                    width = check_sz,
                    height = check_sz,
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
            else
                local check_indicator = current_val and "☑" or "☐"
                icon_part = TextWidget:new{
                    text = check_indicator,
                    face = Font:getFace("cfont", check_sz),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end
            local label = TextWidget:new{
                text = label_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local row_hg = HorizontalGroup:new{
                align = "center",
                icon_part,
                HorizontalSpan:new{ width = sc(8) },
                label,
            }
            local frame = FrameContainer:new{
                padding_v = sc(6),
                padding_h = sc(12),
                bordersize = 0,
                width = dialog_w - sc(4),
                row_hg,
            }
            local row = InputContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = frame:getSize().h },
                frame,
            }
            row.frame = frame

            local function update_icon(val)
                local new_file = getAssetPath(val and "check-square.svg" or "square.svg")
                local new_icon_part
                if new_file then
                    new_icon_part = ImageWidget:new{
                        file = new_file,
                        width = check_sz,
                        height = check_sz,
                        scale_factor = 0,
                        is_icon = true,
                        alpha = true,
                    }
                else
                    new_icon_part = TextWidget:new{
                        text = val and "☑" or "☐",
                        face = Font:getFace("cfont", check_sz),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end
                icon_part = new_icon_part
                row_hg[1] = icon_part
            end

            row.callback = function(is_key_select)
                if type(value) == "function" then
                    local new_val = not get_val()
                    on_toggle(new_val)
                    update_icon(new_val)
                    if is_key_select == false and row.frame then
                        row.frame.invert = false
                    end
                    UIManager:setDirty(row.show_parent or row, "fast")
                else
                    on_toggle()
                    refresh(is_key_select == true)
                end
            end
            row.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function() return row.dimen or frame:getSize() end,
                    }
                }
            }
            row.onTap = function()
                if row.frame then
                    row.frame.invert = false
                end
                row.callback(false)
                return true
            end
            row.isFocusable = function() return true end
            row.onFocus = function(self)
                if self.frame then
                    self.frame.invert = true
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            row.onUnfocus = function(self)
                if self.frame then
                    self.frame.invert = false
                    UIManager:setDirty(self.show_parent or self, "fast")
                end
                return true
            end
            row.onTapSelect = function(self)
                if self.callback then self.callback(true) end
                return true
            end
            table.insert(focusable_rows, row)
            table.insert(content_vg, row)
        end

        -- Blueprint Name Row
        local name_label = TextWidget:new{
            text = _("Name: ") .. bp_name,
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local name_frame = FrameContainer:new{
            padding_v = sc(6),
            padding_h = sc(12),
            bordersize = 0,
            width = dialog_w - sc(4),
            name_label,
        }
        local name_row = InputContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = name_frame:getSize().h },
            name_frame,
        }
        name_row.frame = name_frame
        name_row.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return name_row.dimen or name_frame:getSize() end,
                }
            }
        }
        name_row.callback = function()
            local input_dlg
            input_dlg = InputDialog:new{
                title = _("Blueprint Name"),
                input = bp_name,
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function() UIManager:close(input_dlg) end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local txt = input_dlg:getInputText()
                                if txt and txt ~= "" then bp_name = txt end
                                UIManager:close(input_dlg)
                                refresh()
                            end,
                        },
                    },
                },
            }
            UIManager:show(input_dlg)
            input_dlg:onShowKeyboard()
        end
        name_row.onTap = function()
            name_row.callback()
            return true
        end
        name_row.isFocusable = function() return true end
        name_row.onFocus = function(self)
            if self.frame then
                self.frame.invert = true
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        name_row.onUnfocus = function(self)
            if self.frame then
                self.frame.invert = false
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        name_row.onTapSelect = function(self)
            if self.callback then self.callback() end
            return true
        end
        table.insert(focusable_rows, name_row)
        table.insert(content_vg, name_row)

        -- Version Strategy Row
        local strat_label = (version_strategy == "latest")
            and _("Versions: Latest Releases (Recommended)")
            or _("Versions: Pin Current Installed Versions")
        local strat_widget = TextWidget:new{
            text = strat_label,
            face = Font:getFace("cfont", ui_font_size),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local strat_frame = FrameContainer:new{
            padding_v = sc(6),
            padding_h = sc(12),
            bordersize = 0,
            width = dialog_w - sc(4),
            strat_widget,
        }
        local strat_row = InputContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = strat_frame:getSize().h },
            strat_frame,
        }
        strat_row.frame = strat_frame
        strat_row.strat_widget = strat_widget
        strat_row.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return strat_row.dimen or strat_frame:getSize() end,
                }
            }
        }
        strat_row.callback = function(is_key_select)
            version_strategy = (version_strategy == "latest") and "pinned" or "latest"
            local new_label = (version_strategy == "latest")
                and _("Versions: Latest Releases (Recommended)")
                or _("Versions: Pin Current Installed Versions")
            if strat_widget.setText then
                strat_widget:setText(new_label)
            else
                strat_widget.text = new_label
                if strat_widget.args then strat_widget.args.text = new_label end
            end
            if is_key_select == false and strat_row.frame then
                strat_row.frame.invert = false
            end
            UIManager:setDirty(strat_row.show_parent or strat_row, "fast")
        end
        strat_row.onTap = function()
            if strat_row.frame then
                strat_row.frame.invert = false
            end
            strat_row.callback(false)
            return true
        end
        strat_row.isFocusable = function() return true end
        strat_row.onFocus = function(self)
            if self.frame then
                self.frame.invert = true
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        strat_row.onUnfocus = function(self)
            if self.frame then
                self.frame.invert = false
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        strat_row.onTapSelect = function(self)
            if self.callback then self.callback(true) end
            return true
        end
        table.insert(focusable_rows, strat_row)
        table.insert(content_vg, strat_row)

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Component toggles
        add_toggle_row(_("Include Plugins"), function() return inc_plugins end, function(v) inc_plugins = v end)
        add_toggle_row(_("Include User Patches"), function() return inc_patches end, function(v) inc_patches = v end)
        add_toggle_row(_("Include Fonts"), function() return inc_fonts end, function(v) inc_fonts = v end)
        add_toggle_row(_("Include Wallpaper/Screensavers"), function() return inc_screensavers end, function(v) inc_screensavers = v end)
        add_toggle_row(_("Include Storefront Settings"), function() return inc_settings end, function(v) inc_settings = v end)

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })

        -- Action Buttons: [ Save File ] [ Share Cloud ] [ Cancel ]
        local btn_w = math.floor((dialog_w - sc(36)) / 3)
        local btn_h = sc(34)

        local save_btn = StorefrontUtils.createButton{
            text = _("Save File"),
            text_font_size = subtext_font_size,
            bold = true,
            width = btn_w,
            height = btn_h,
            background = Blitbuffer.COLOR_BLACK,
            text_font_color = Blitbuffer.COLOR_WHITE,
            callback = function()
                local bp = BlueprintMgr.generateBlueprint{
                    name = bp_name,
                    version_strategy = version_strategy,
                    include_plugins = inc_plugins,
                    include_patches = inc_patches,
                    include_fonts = inc_fonts,
                    include_screensavers = inc_screensavers,
                    include_settings = inc_settings,
                    Storefront = Storefront,
                }
                local ok, out_path = BlueprintMgr.saveToFile(bp)
                closeDialog()
                UIManager:nextTick(function()
                    if ok then
                        local short_name = out_path:match("([^/\\]+)$") or out_path
                        StorefrontToast:new{
                            text = string.format(_("Saved blueprint to %s"), short_name),
                            timeout = 3,
                        }:show()
                    else
                        StorefrontToast:new{
                            text = string.format(_("Failed to save: %s"), tostring(out_path)),
                            timeout = 4,
                        }:show()
                    end
                end)
            end,
        }

        local share_btn = StorefrontUtils.createButton{
            text = _("Share Cloud"),
            text_font_size = subtext_font_size,
            bold = true,
            width = btn_w,
            height = btn_h,
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                local bp = BlueprintMgr.generateBlueprint{
                    name = bp_name,
                    version_strategy = version_strategy,
                    include_plugins = inc_plugins,
                    include_patches = inc_patches,
                    include_fonts = inc_fonts,
                    include_screensavers = inc_screensavers,
                    include_settings = inc_settings,
                    Storefront = Storefront,
                }
                dismissDialog()
                StorefrontToast:new{ text = _("Uploading to Cloudflare…"), timeout = 3 }:show()
                BlueprintCloud.uploadBlueprint(bp, function(ok, res)
                    if ok and res then
                        StorefrontBlueprintUI.showCloudShareDialog(Storefront, res, bp, on_done)
                    else
                        if on_done then on_done() end
                        UIManager:nextTick(function()
                            StorefrontToast:new{ text = _("Cloud upload failed: ") .. tostring(res), timeout = 4 }:show()
                        end)
                    end
                end)
            end,
        }

        local cancel_btn = StorefrontUtils.createButton{
            text = _("Cancel"),
            text_font_size = subtext_font_size,
            width = btn_w,
            height = btn_h,
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = closeDialog,
        }

        local btns_hg = HorizontalGroup:new{
            save_btn,
            HorizontalSpan:new{ width = sc(6) },
            share_btn,
            HorizontalSpan:new{ width = sc(6) },
            cancel_btn,
        }

        table.insert(content_vg, FrameContainer:new{
            padding = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(24), h = btn_h },
                btns_hg,
            },
        })

        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg,
            width = dialog_w,
            content_vg,
        }

        local layout = {}
        for _, r in ipairs(focusable_rows) do
            table.insert(layout, { r })
        end
        table.insert(layout, { save_btn, share_btn, cancel_btn })

        if saved_focus_y > #layout then saved_focus_y = #layout end
        if saved_focus_x > #layout[saved_focus_y] then saved_focus_x = #layout[saved_focus_y] end

        overlay = FocusManager:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            layout = layout,
            selected = { x = saved_focus_x, y = saved_focus_y },
            card,
        }

        for _, r in ipairs(focusable_rows) do
            r.show_parent = overlay
        end
        save_btn.show_parent = overlay
        share_btn.show_parent = overlay
        cancel_btn.show_parent = overlay

        if keep_focus_highlight then
            local cur_item = layout[saved_focus_y] and layout[saved_focus_y][saved_focus_x]
            if cur_item and cur_item.frame then
                cur_item.frame.invert = true
            end
        end

        overlay.onClose = function()
            overlay = nil
            if on_done then on_done() end
        end

        UIManager:show(overlay)
    end

    refresh()
end

--- Shows the Cloud Share Dialog displaying the 6-character shortcode.
--- @param Storefront table
--- @param result table { code = string, url = string, expires_at = number }
--- @param blueprint table
--- @param on_done? fun()
function StorefrontBlueprintUI.showCloudShareDialog(Storefront, result, blueprint, on_done)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(400))

    local code_str = result.code or result.shortcode or "------"
    local web_url = result.url or (BlueprintCloud.BASE_URL .. "/blueprint/" .. code_str)

    local overlay
    local function closeDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_done then on_done() end
    end

    local title_label = TextWidget:new{
        text = _("Blueprint Shared!"),
        face = Font:getFace("cfont", 20),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local code_label = TextWidget:new{
        text = code_str,
        face = Font:getFace("cfont", 28),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local code_container = FrameContainer:new{
        padding_v = sc(12),
        padding_h = sc(20),
        bordersize = sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        code_label,
    }

    local subtext = TextBoxWidget:new{
        text = _("Enter this 6-character code on any device in Storefront to instantly download and install this setup."),
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = dialog_w - sc(36),
        alignment = "center",
    }

    local content_vg = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sc(10) },
        title_label,
        VerticalSpan:new{ width = sc(12) },
        code_container,
        VerticalSpan:new{ width = sc(12) },
        subtext,
        VerticalSpan:new{ width = sc(16) },
    }

    -- Optional QR Code Button if QRDialog is supported
    local ok_qr, QRDialog = pcall(require, "ui/widget/qrdialog")
    local btns = {}

    if ok_qr and QRDialog and QRDialog.new then
        local qr_btn = StorefrontUtils.createButton{
            text = _("View QR Code"),
            text_font_size = 14,
            width = math.floor((dialog_w - sc(36)) / 2),
            height = sc(34),
            background = Blitbuffer.COLOR_WHITE,
            text_font_color = Blitbuffer.COLOR_BLACK,
            callback = function()
                local qr_dlg = QRDialog:new{
                    title = _("Scan Blueprint QR Code"),
                    text = web_url,
                }
                UIManager:show(qr_dlg)
            end,
        }
        table.insert(btns, qr_btn)
    end

    local done_btn_w = (#btns > 0) and math.floor((dialog_w - sc(36)) / 2) or (dialog_w - sc(36))
    local done_btn = StorefrontUtils.createButton{
        text = _("Done"),
        text_font_size = 14,
        bold = true,
        width = done_btn_w,
        height = sc(34),
        background = Blitbuffer.COLOR_BLACK,
        text_font_color = Blitbuffer.COLOR_WHITE,
        callback = closeDialog,
    }
    table.insert(btns, done_btn)

    local btn_group
    if #btns == 2 then
        btn_group = HorizontalGroup:new{
            btns[1],
            HorizontalSpan:new{ width = sc(8) },
            btns[2],
        }
    else
        btn_group = HorizontalGroup:new{ btns[1] }
    end

    table.insert(content_vg, CenterContainer:new{
        dimen = Geom:new{ w = dialog_w - sc(20), h = sc(34) },
        btn_group,
    })
    table.insert(content_vg, VerticalSpan:new{ width = sc(10) })

    local card = FrameContainer:new{
        padding = sc(8),
        radius = storefront_theme.radius_window or 0,
        bordersize = sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg,
        width = dialog_w,
        content_vg,
    }

    local layout = {}
    if #btns == 2 then
        table.insert(layout, { btns[1], btns[2] })
    else
        table.insert(layout, { btns[1] })
    end

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = layout,
        selected = { x = 1, y = 1 },
        card,
    }

    for _, b in ipairs(btns) do b.show_parent = overlay end
    overlay.onClose = function()
        overlay = nil
        if on_done then on_done() end
    end

    UIManager:show(overlay)
end

--- Shows the Enter Code Dialog to fetch a blueprint from the cloud.
--- @param Storefront table
--- @param callback fun(blueprint: table?)
function StorefrontBlueprintUI.showEnterCodeDialog(Storefront, callback)
    local input_dlg
    input_dlg = InputDialog:new{
        title = _("Enter Blueprint Code"),
        description = _("Enter the 6-character shortcode (e.g. A8K2M9) to download the setup:"),
        input = "",
        input_hint = "A8K2M9",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dlg)
                        if callback then callback(nil) end
                    end,
                },
                {
                    text = _("Download"),
                    is_enter_default = true,
                    callback = function()
                        local code = input_dlg:getInputText()
                        UIManager:close(input_dlg)
                        if not code or code == "" then
                            if callback then callback(nil) end
                            UIManager:nextTick(function()
                                StorefrontToast:new{ text = _("Please enter a valid code"), timeout = 2 }:show()
                            end)
                            return
                        end
                        StorefrontToast:new{ text = _("Fetching blueprint…"), timeout = 3 }:show()
                        BlueprintCloud.fetchBlueprint(code, function(ok, res)
                            if ok and res then
                                if callback then callback(res) end
                            else
                                if callback then callback(nil) end
                                UIManager:nextTick(function()
                                    StorefrontToast:new{ text = _("Download failed: ") .. tostring(res), timeout = 4 }:show()
                                end)
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dlg)
    input_dlg:onShowKeyboard()
end

--- Shows the File Picker Dialog for local blueprints.
--- @param Storefront table
--- @param callback fun(blueprint: table?)
function StorefrontBlueprintUI.showFilePickerDialog(Storefront, callback)
    local saved = BlueprintMgr.listSavedBlueprints()
    if not saved or #saved == 0 then
        if callback then callback(nil) end
        UIManager:nextTick(function()
            StorefrontToast:new{ text = _("No saved blueprints found in koreader/blueprints/"), timeout = 3 }:show()
        end)
        return
    end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(420))

    local overlay
    local focusable_rows = {}

    local function closeDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
    end

    local content_vg = VerticalGroup:new{ align = "left" }
    table.insert(content_vg, FrameContainer:new{
        padding_v = sc(8),
        padding_h = sc(12),
        bordersize = 0,
        TextWidget:new{
            text = _("Select a Blueprint"),
            face = Font:getFace("cfont", 20),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    })
    table.insert(content_vg, LineWidget:new{
        dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
        background = Blitbuffer.COLOR_BLACK,
    })

    for _, item in ipairs(saved) do
        local display_name = item.filename:gsub("%.blueprint$", "")
        local date_str = item.modification > 0 and formatDateTime(item.modification) or ""

        local row_vg = VerticalGroup:new{ align = "left" }
        table.insert(row_vg, TextWidget:new{
            text = display_name,
            face = Font:getFace("cfont", 16),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
        if date_str ~= "" then
            table.insert(row_vg, TextWidget:new{
                text = date_str,
                face = Font:getFace("cfont", 12),
                fgcolor = storefront_theme.color_label_dim,
            })
        end

        local frame = FrameContainer:new{
            padding_v = sc(6),
            padding_h = sc(12),
            bordersize = 0,
            width = dialog_w - sc(4),
            row_vg,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = frame:getSize().h },
            frame,
        }
        ic.frame = frame
        ic.callback = function()
            closeDialog()
            local ok, bp = BlueprintMgr.loadFromFile(item.path)
            if ok and bp then
                if callback then callback(bp) end
            else
                if callback then callback(nil) end
                UIManager:nextTick(function()
                    StorefrontToast:new{ text = _("Failed to load blueprint: ") .. tostring(bp), timeout = 3 }:show()
                end)
            end
        end
        ic.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return ic.dimen or frame:getSize() end,
                }
            }
        }
        ic.onTap = function()
            ic.callback()
            return true
        end
        ic.isFocusable = function() return true end
        ic.onFocus = function(self)
            if self.frame then
                self.frame.invert = true
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        ic.onUnfocus = function(self)
            if self.frame then
                self.frame.invert = false
                UIManager:setDirty(self.show_parent or self, "fast")
            end
            return true
        end
        ic.onTapSelect = function(self)
            if self.callback then self.callback() end
            return true
        end

        table.insert(focusable_rows, ic)
        table.insert(content_vg, ic)
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
    end

    local cancel_btn = StorefrontUtils.createButton{
        text = _("Cancel"),
        text_font_size = 14,
        width = dialog_w - sc(24),
        height = sc(34),
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        callback = function()
            closeDialog()
            if callback then callback(nil) end
        end,
    }

    table.insert(content_vg, FrameContainer:new{
        padding = sc(8),
        bordersize = 0,
        width = dialog_w - sc(4),
        CenterContainer:new{
            dimen = Geom:new{ w = dialog_w - sc(24), h = sc(34) },
            cancel_btn,
        }
    })

    local card = FrameContainer:new{
        padding = 0,
        radius = storefront_theme.radius_window or 0,
        bordersize = sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg,
        width = dialog_w,
        content_vg,
    }

    local layout = {}
    for _, r in ipairs(focusable_rows) do
        table.insert(layout, { r })
    end
    table.insert(layout, { cancel_btn })

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = layout,
        selected = { x = 1, y = 1 },
        card,
    }

    for _, r in ipairs(focusable_rows) do r.show_parent = overlay end
    cancel_btn.show_parent = overlay

    UIManager:show(overlay)
end

--- Shows the Diff & Batch Install Review Dialog.
--- @param Storefront table
--- @param blueprint table
--- @param on_done? fun()
function StorefrontBlueprintUI.showDiffDialog(Storefront, blueprint, on_done)
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(540))
    local dialog_h = math.min(sh - sc(30), sc(660))
    local ITEMS_PER_PAGE = (sh < sc(700)) and 6 or 8

    local diff = BlueprintMgr.diffBlueprint(blueprint, Storefront)

    local overlay
    local function closeDialog()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_done then on_done() end
    end

    local title_label = TextWidget:new{
        text = blueprint.name or _("Blueprint Setup"),
        face = Font:getFace("cfont", 20),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local subtitle_text = string.format(_("Created by %s · %s items"), blueprint.author or _("User"), tostring(diff.summary.total))
    local subtitle_label = TextWidget:new{
        text = subtitle_text,
        face = Font:getFace("cfont", 13),
        fgcolor = storefront_theme.color_label_dim,
    }

    local summary_text = string.format(_("%d missing · %d updates · %d installed"), diff.summary.missing, diff.summary.updates, diff.summary.installed)
    local summary_label = TextWidget:new{
        text = summary_text,
        face = Font:getFace("cfont", 14),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local header_vg = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            padding_v = sc(8),
            padding_h = sc(14),
            bordersize = 0,
            VerticalGroup:new{
                align = "left",
                title_label,
                VerticalSpan:new{ width = sc(3) },
                subtitle_label,
                VerticalSpan:new{ width = sc(4) },
                summary_label,
            }
        },
        LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }
    }

    -- Build unified items array across plugins, patches, fonts, and screensavers
    local all_items = {}
    for i, p in ipairs(diff.plugins) do
        table.insert(all_items, { kind = "plugin", kind_label = _("Plugin"), icon = "package.svg", item = p })
    end
    for i, p in ipairs(diff.patches) do
        table.insert(all_items, { kind = "patch", kind_label = _("Patch"), icon = "code.svg", item = p })
    end
    for i, f in ipairs(diff.fonts) do
        table.insert(all_items, { kind = "font", kind_label = _("Font"), icon = "type.svg", item = f })
    end
    for i, s in ipairs(diff.screensavers) do
        table.insert(all_items, { kind = "screensaver", kind_label = _("Screensaver"), icon = "image.svg", item = s })
    end

    local total_items = #all_items
    local total_pages = math.max(1, math.ceil(total_items / ITEMS_PER_PAGE))
    local current_page = 1

    -- Action Buttons: [ Apply Selected ] [ Cancel ]
    local btn_w = math.floor((dialog_w - sc(30)) / 2)
    local apply_btn = StorefrontUtils.createButton{
        text = _("Apply Selected"),
        text_font_size = 15,
        bold = true,
        width = btn_w,
        height = sc(38),
        background = Blitbuffer.COLOR_BLACK,
        text_font_color = Blitbuffer.COLOR_WHITE,
        callback = function()
            local items_to_install = {}
            for i, p in ipairs(diff.plugins) do
                if p.selected then
                    table.insert(items_to_install, { kind = "plugin", item = p })
                end
            end
            for i, p in ipairs(diff.patches) do
                if p.selected then
                    table.insert(items_to_install, { kind = "patch", item = p })
                end
            end
            for i, f in ipairs(diff.fonts) do
                if f.selected then
                    table.insert(items_to_install, { kind = "font", item = f })
                end
            end
            for i, s in ipairs(diff.screensavers) do
                if s.selected then
                    table.insert(items_to_install, { kind = "screensaver", item = s })
                end
            end

            closeDialog()
            if #items_to_install == 0 then
                if on_done then on_done() end
                UIManager:nextTick(function()
                    StorefrontToast:new{ text = _("All selected items are already installed."), timeout = 3 }:show()
                end)
            else
                StorefrontBlueprintUI.batchInstall(Storefront, items_to_install, on_done)
            end
        end,
    }

    local cancel_btn = StorefrontUtils.createButton{
        text = _("Cancel"),
        text_font_size = 15,
        width = btn_w,
        height = sc(38),
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        callback = closeDialog,
    }

    local btns_hg = HorizontalGroup:new{
        apply_btn,
        HorizontalSpan:new{ width = sc(8) },
        cancel_btn,
    }

    local card
    local renderPage

    renderPage = function(reset_focus, keep_focus_highlight)
        local saved_focus_x = (not reset_focus and overlay and overlay.selected and overlay.selected.x) or 1
        local saved_focus_y = (not reset_focus and overlay and overlay.selected and overlay.selected.y) or 1

        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        local focusable_items = {}
        local list_vg = VerticalGroup:new{ align = "left" }
        local row_h = sc(40)
        local icon_size = sc(22)

        if total_items == 0 then
            table.insert(list_vg, CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = ITEMS_PER_PAGE * row_h },
                TextWidget:new{
                    text = _("No items found in this blueprint."),
                    face = Font:getFace("cfont", 16),
                    fgcolor = storefront_theme.color_label_dim,
                }
            })
        else
            local start_idx = (current_page - 1) * ITEMS_PER_PAGE + 1
            local end_idx = math.min(total_items, current_page * ITEMS_PER_PAGE)

            for i = start_idx, end_idx do
                local entry = all_items[i]
                local item = entry.item

                local status_tag = ""
                local tag_color = Blitbuffer.COLOR_BLACK
                if item.status == "missing" then
                    status_tag = _("[NEW]")
                    tag_color = Blitbuffer.COLOR_BLACK
                elseif item.status == "update" then
                    status_tag = _("[UPDATE]")
                    tag_color = Blitbuffer.COLOR_BLACK
                else
                    status_tag = _("[INSTALLED]")
                    tag_color = storefront_theme.color_label_dim
                end

                -- Checkbox icon (check-square.svg / square.svg)
                local check_icon_file = getAssetPath(item.selected and "check-square.svg" or "square.svg")
                local check_part
                if check_icon_file then
                    check_part = CenterContainer:new{
                        dimen = Geom:new{ w = icon_size + sc(4), h = icon_size + sc(4) },
                        ImageWidget:new{
                            file = check_icon_file,
                            width = icon_size,
                            height = icon_size,
                            scale_factor = 0,
                            is_icon = true,
                            alpha = true,
                        }
                    }
                else
                    check_part = TextWidget:new{
                        text = item.selected and "☑ " or "☐ ",
                        face = Font:getFace("cfont", 16),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end

                -- Feature kind icon (package.svg, code.svg, type.svg, image.svg)
                local feat_icon_file = getAssetPath(entry.icon)
                local feat_part
                if feat_icon_file then
                    feat_part = CenterContainer:new{
                        dimen = Geom:new{ w = icon_size + sc(4), h = icon_size + sc(4) },
                        ImageWidget:new{
                            file = feat_icon_file,
                            width = icon_size,
                            height = icon_size,
                            scale_factor = 0,
                            is_icon = true,
                            alpha = true,
                        }
                    }
                end

                local title_tw = TextWidget:new{
                    text = item.name or item.filename or item.id,
                    face = Font:getFace("cfont", 16),
                    bold = item.status ~= "installed",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local tag_tw = TextWidget:new{
                    text = status_tag,
                    face = Font:getFace("cfont", 13),
                    bold = true,
                    fgcolor = tag_color,
                }

                local avail_w = dialog_w - sc(36)
                local tag_w = (tag_tw.getSize and tag_tw:getSize().w) or sc(80)
                local left_icons_w = (icon_size + sc(4) + sc(8)) + (feat_part and (icon_size + sc(4) + sc(8)) or 0)
                local max_title_w = math.max(sc(120), avail_w - tag_w - left_icons_w - sc(12))

                if title_tw:getSize().w > max_title_w then
                    local display_title = item.name or item.filename or item.id
                    title_tw.face = Font:getFace("cfont", 14)
                    while #display_title > 6 and title_tw:getSize().w > max_title_w do
                        display_title = display_title:sub(1, -2)
                        title_tw:setText(display_title .. "…")
                    end
                end

                local title_w = (title_tw.getSize and title_tw:getSize().w) or sc(160)
                local spacer_w = math.max(sc(8), avail_w - left_icons_w - title_w - tag_w)

                local row_elements = {
                    check_part,
                    HorizontalSpan:new{ width = sc(8) },
                }
                if feat_part then
                    table.insert(row_elements, feat_part)
                    table.insert(row_elements, HorizontalSpan:new{ width = sc(8) })
                end
                table.insert(row_elements, title_tw)
                table.insert(row_elements, HorizontalSpan:new{ width = spacer_w })
                table.insert(row_elements, tag_tw)

                local row_hg = HorizontalGroup:new(row_elements)

                local row_inner = CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(40), h = row_h - sc(8) },
                    row_hg,
                }

                local frame = FrameContainer:new{
                    padding_v = sc(4),
                    padding_h = sc(10),
                    bordersize = 0,
                    width = dialog_w - sc(20),
                    row_inner,
                }

                local ic = InputContainer:new{ frame }
                ic.dimen = Geom:new{ w = dialog_w - sc(20), h = row_h }
                ic.frame = frame
                ic.item = item
                local row_layout_idx = #focusable_items + 1
                local toggle_item = function(is_key_select)
                    item.selected = not item.selected
                    if overlay then
                        overlay.selected = { x = 1, y = row_layout_idx }
                    end
                    renderPage(false, is_key_select == true)
                    return true
                end
                ic.callback = function() return toggle_item(true) end
                ic.ges_events = {
                    Tap = {
                        GestureRange:new{
                            ges = "tap",
                            range = function() return ic.dimen or frame:getSize() end,
                        }
                    }
                }
                ic.onTap = function()
                    return toggle_item(false)
                end
                ic.onTapSelect = function()
                    return toggle_item(true)
                end
                ic.isFocusable = function() return true end
                ic.onFocus = function(self)
                    if self.frame then
                        self.frame.invert = true
                        UIManager:setDirty(self.show_parent or self, "fast")
                    end
                    return true
                end
                ic.onUnfocus = function(self)
                    if self.frame then
                        self.frame.invert = false
                        UIManager:setDirty(self.show_parent or self, "fast")
                    end
                    return true
                end

                table.insert(focusable_items, ic)
                table.insert(list_vg, ic)
            end

            -- Pad remaining slots on last page so dialog height stays fixed
            local items_on_page = end_idx - start_idx + 1
            local empty_slots = ITEMS_PER_PAGE - items_on_page
            if empty_slots > 0 then
                table.insert(list_vg, VerticalSpan:new{ width = empty_slots * row_h })
            end
        end

        -- Pagination Controls
        local pag_btn_w = sc(42)
        local is_prev_active = (current_page > 1)
        local is_next_active = (current_page < total_pages)

        local prev_btn = Button:new{
            text = "‹",
            text_font_size = 20,
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
                    renderPage(true)
                end
            end,
        }

        local page_text = TextWidget:new{
            text = string.format(_("Page %d of %d"), current_page, total_pages),
            face = Font:getFace("cfont", 15),
            bold = true,
            fgcolor = (total_pages > 1) and Blitbuffer.COLOR_BLACK or storefront_theme.color_label_dim,
        }

        local next_btn = Button:new{
            text = "›",
            text_font_size = 20,
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
                    renderPage(true)
                end
            end,
        }

        local pag_hg = HorizontalGroup:new{
            align = "center",
            prev_btn,
            HorizontalSpan:new{ width = sc(20) },
            page_text,
            HorizontalSpan:new{ width = sc(20) },
            next_btn,
        }

        local pag_frame = FrameContainer:new{
            padding = sc(6),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(36) },
                pag_hg,
            }
        }

        local list_frame = FrameContainer:new{
            padding_v = sc(4),
            padding_h = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            list_vg,
        }

        local content_vg = VerticalGroup:new{
            header_vg,
            list_frame,
            pag_frame,
            LineWidget:new{ dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) }, background = Blitbuffer.COLOR_LIGHT_GRAY },
            FrameContainer:new{
                padding = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(20), h = sc(38) },
                    btns_hg,
                },
            },
        }

        local layout = {}
        for i, item in ipairs(focusable_items) do
            table.insert(layout, { item })
        end
        if total_pages > 1 then
            table.insert(layout, { prev_btn, next_btn })
        end
        table.insert(layout, { apply_btn, cancel_btn })

        if not overlay then
            card = FrameContainer:new{
                padding = 0,
                radius = storefront_theme.radius_window or 0,
                bordersize = sc(2),
                color = Blitbuffer.COLOR_BLACK,
                background = storefront_theme.color_bg,
                width = dialog_w,
                content_vg,
            }

            local Device_input = require("device").input

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
                ges_events = ges_events,
                card,
            }

            -- CRITICAL: FocusManager:_init() unconditionally resets self.key_events = util.tableDeepCopy(KEY_EVENTS).
            -- Passing key_events inside FocusManager:new{ key_events = ... } is wiped out by _init().
            -- Custom key_events MUST be assigned directly onto the instance after creation.
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
            if Device_input and Device_input.group then
                if Device_input.group.Back then
                    table.insert(overlay.key_events.Close, { Device_input.group.Back })
                end
                if Device_input.group.PgFwd then
                    table.insert(overlay.key_events.NextPage, { Device_input.group.PgFwd })
                end
                if Device_input.group.PgBack then
                    table.insert(overlay.key_events.PrevPage, { Device_input.group.PgBack })
                end
            end

            overlay.onNextPage = function(self)
                if current_page < total_pages then
                    current_page = current_page + 1
                    renderPage(true)
                end
                return true
            end

            overlay.onPrevPage = function(self)
                if current_page > 1 then
                    current_page = current_page - 1
                    renderPage(true)
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
                    return overlay:onNextPage()
                elseif direction == "right" or direction == "east" then
                    return overlay:onPrevPage()
                end
                return false
            end

            overlay.onClose = function()
                overlay = nil
                if on_done then on_done() end
            end

            for i, item in ipairs(focusable_items) do item.show_parent = overlay end
            prev_btn.show_parent = overlay
            next_btn.show_parent = overlay
            apply_btn.show_parent = overlay
            cancel_btn.show_parent = overlay

            UIManager:show(overlay, "ui")
        else
            card[1] = content_vg
            overlay.layout = layout
            if reset_focus then
                overlay.selected = { x = 1, y = 1 }
            else
                if saved_focus_y > #layout then saved_focus_y = #layout end
                if saved_focus_x > #layout[saved_focus_y] then saved_focus_x = #layout[saved_focus_y] end
                overlay.selected = { x = saved_focus_x, y = saved_focus_y }
                if keep_focus_highlight then
                    local cur_item = layout[saved_focus_y] and layout[saved_focus_y][saved_focus_x]
                    if cur_item and cur_item.frame then
                        cur_item.frame.invert = true
                    end
                end
            end
            for i, item in ipairs(focusable_items) do item.show_parent = overlay end
            prev_btn.show_parent = overlay
            next_btn.show_parent = overlay
            apply_btn.show_parent = overlay
            cancel_btn.show_parent = overlay
            UIManager:setDirty("all", "ui")
        end
    end

    renderPage()
end

--- Runs sequential batch installation of blueprint items.
--- @param Storefront table
--- @param queue table array of { kind = string, item = table }
--- @param on_complete? fun()
function StorefrontBlueprintUI.batchInstall(Storefront, queue, on_complete)
    if not queue or #queue == 0 then
        if on_complete then on_complete() end
        return
    end

    local total = #queue
    local current_index = 1
    local success_count = 0
    local fail_count = 0

    local function install_next()
        if current_index > total then
            -- Finished!
            if Storefront and Storefront.invalidateInstalledPluginsCache then
                pcall(Storefront.invalidateInstalledPluginsCache, Storefront)
            end

            local msg = string.format(_("Blueprint applied: %d installed, %d failed."), success_count, fail_count)
            StorefrontUtils.showConfirmDialog{
                title = _("Installation Complete"),
                text = msg .. "\n\n" .. _("Restart KOReader now to activate the new plugins and patches?"),
                ok_text = _("Restart Now"),
                ok_callback = function()
                    local sf = (Storefront and (Storefront.instance or Storefront))
                    if sf then
                        if sf.closeBrowserMenu then pcall(function() sf:closeBrowserMenu() end) end
                        if sf.closeUpdatesDialog then pcall(function() sf:closeUpdatesDialog(true) end) end
                        if sf.closePatchUpdatesDialog then pcall(function() sf:closePatchUpdatesDialog(true) end) end
                    end

                    local Event = require("ui/event")
                    UIManager:nextTick(function()
                        if UIManager.broadcastEvent then
                            UIManager:broadcastEvent(Event:new("Restart"))
                        elseif UIManager.restartKOReader then
                            UIManager:restartKOReader()
                        end
                    end)
                end,
                cancel_callback = function()
                    if on_complete then on_complete() end
                end,
            }
            return
        end

        local entry = queue[current_index]
        local item = entry.item
        local kind = entry.kind

        StorefrontToast:new{
            text = string.format(_("Installing %d of %d: %s…"), current_index, total, item.name or item.id or item.filename),
            timeout = 3,
        }:show()

        local function step_done(ok)
            if ok then
                success_count = success_count + 1
            else
                fail_count = fail_count + 1
            end
            current_index = current_index + 1
            UIManager:scheduleIn(0.5, install_next)
        end

        if kind == "plugin" then
            if Storefront and type(Storefront.installPluginFromRelease) == "function" and item.repo then
                local owner, repo_name = item.repo:match("([^/]+)/([^/]+)")
                local descriptor = { owner = owner, name = repo_name, repo_id = item.repo, tag = item.pinned_tag }
                Storefront:installPluginFromRelease(descriptor, { tag_name = item.pinned_tag }, function(ok)
                    step_done(ok ~= false)
                end)
            else
                step_done(false)
            end
        elseif kind == "patch" then
            if Storefront and type(Storefront.installPatchFromRepo) == "function" and item.repo then
                local owner, repo_name = item.repo:match("([^/]+)/([^/]+)")
                local patch_rec = { filename = item.filename, sha = item.pinned_sha }
                Storefront:installPatchFromRepo({ owner = owner, name = repo_name }, patch_rec, function(ok)
                    step_done(ok ~= false)
                end)
            else
                step_done(false)
            end
        elseif kind == "font" then
            local ok_fm, font_mgr = pcall(require, "storefront_font_mgr")
            if ok_fm and font_mgr and type(font_mgr.installFont) == "function" then
                font_mgr.installFont(item, function(ok)
                    step_done(ok ~= false)
                end)
            else
                step_done(false)
            end
        else
            step_done(true)
        end
    end

    install_next()
end

return StorefrontBlueprintUI
