local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local lfs = require("libs/libkoreader-lfs")

local PluginPaths = require("storefront_plugin_paths")
local InstallStore = require("storefront_installs")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = { action = function() end, err = function() end } end

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)

local DeleteUI = {}

local function deleteDirectoryRecursive(path)
    if not path or path == "" then return false, "invalid path" end
    if lfs.attributes(path, "mode") ~= "directory" then return false, "not a directory" end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = path .. "/" .. entry
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                local ok, err = deleteDirectoryRecursive(full_path)
                if not ok then return false, err end
            elseif mode == "file" then
                local ok, err = os.remove(full_path)
                if not ok then return false, err end
            end
        end
    end
    return lfs.rmdir(path)
end

function DeleteUI.showDeleteConfirmationDialog(display_name, is_plugin, plugin_instance, on_confirm)
    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local sc = function(val) return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local card_padding = sc(12)
    local card_border = storefront_theme.border_window or sc(2)
    local dialog_w = math.min(sw - sc(20), sc(360))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local title_text
    if is_plugin == "font" or is_plugin == "fonts" then
        title_text = string.format(_("Delete font '%s'?"), display_name)
    elseif is_plugin == "patch" or is_plugin == "patches" or is_plugin == false then
        title_text = string.format(_("Delete patch '%s'?"), display_name)
    else
        title_text = string.format(_("Delete plugin '%s'?"), display_name)
    end
    local StorefrontUtils = require("storefront_utils")
    local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(title_text, inner_w, "NotoSerif-Regular.ttf", title_font_size, 12, true)
    local title_label = TextBoxWidget:new{
        text = title_text,
        face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local title_container = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        title_label,
    }

    local body_text = _("This action cannot be undone.\n\nChanges will take effect after restart.")
    local body_widget = TextBoxWidget:new{
        text = body_text,
        face = Font:getFace("cfont", ui_font_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local body_container = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        body_widget,
    }

    local delete_settings = false
    local check_item = nil
    local overlay

    if is_plugin == true then
        local function get_check_text()
            local icon = delete_settings and "☑ " or "☐ "
            return icon .. _("Also delete plugin settings")
        end

        local check_text_widget = TextBoxWidget:new{
            text = get_check_text(),
            face = Font:getFace("cfont", ui_font_size),
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = inner_w,
            alignment = "center",
        }

        local check_frame = FrameContainer:new{
            padding = sc(4),
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            check_text_widget,
        }

        check_item = InputContainer:new{
            align = "center",
            check_frame,
        }

        check_item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = check_item.dimen
                        if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                        return Geom:new{
                            x = dim.x or 0,
                            y = dim.y or 0,
                            w = check_frame:getSize().w or inner_w,
                            h = check_frame:getSize().h or 0,
                        }
                    end
                }
            }
        }

        check_item.onTap = function()
            delete_settings = not delete_settings
            check_text_widget:setText(get_check_text())
            UIManager:setDirty(overlay, "ui")
            if delete_settings and not plugin_instance then
                UIManager:show(InfoMessage:new{
                    text = _("Plugin is not currently loaded, so settings cannot be deleted."),
                    timeout = 6,
                })
            end
            return true
        end
    end

    local btn_gap = sc(12)
    local StorefrontUtils = require("storefront_utils")
    local cancel_text = _("Cancel")
    local delete_text = _("Delete")
    local btn_font_size = StorefrontUtils.calcGroupFontSize({ cancel_text, delete_text }, inner_w, btn_gap, "cfont", sc(16))
    local btn_widths = StorefrontUtils.calcProportionalBtnWidths({ cancel_text, delete_text }, inner_w, btn_gap, btn_font_size, "cfont")

    local cancel_btn = StorefrontUtils.createButton{
        text = cancel_text,
        text_font_size = btn_font_size,
        bold = true,
        bordersize = storefront_theme.border_btn or sc(1),
        radius = storefront_theme.radius_btn or sc(4),
        width = btn_widths[1],
        height = sc(38),
        background = Blitbuffer.COLOR_WHITE,
        text_font_color = Blitbuffer.COLOR_BLACK,
        callback = function()
            UIManager:close(overlay, "ui")
        end,
    }

    local delete_btn = StorefrontUtils.createButton{
        text = delete_text,
        text_font_size = btn_font_size,
        bold = true,
        bordersize = storefront_theme.border_btn or sc(1),
        radius = storefront_theme.radius_btn or sc(4),
        width = btn_widths[2],
        height = sc(38),
        background = Blitbuffer.COLOR_BLACK,
        text_font_color = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(overlay, "ui")
            UIManager:nextTick(function()
                on_confirm(delete_settings)
            end)
        end,
    }

    local btn_row = HorizontalGroup:new{
        align = "center",
        cancel_btn,
        HorizontalSpan:new{ width = btn_gap },
        delete_btn,
    }

    local content_items = {
        title_container,
        VerticalSpan:new{ width = sc(10) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = sc(14) },
        body_container,
    }

    if check_item then
        table.insert(content_items, VerticalSpan:new{ width = sc(12) })
        table.insert(content_items, check_item)
    end

    table.insert(content_items, VerticalSpan:new{ width = sc(16) })
    table.insert(content_items, FrameContainer:new{ padding = 0, bordersize = 0, btn_row })

    local content_vg = VerticalGroup:new{
        align = "center",
        unpack(content_items)
    }

    local card = FrameContainer:new{
        padding = card_padding,
        radius = storefront_theme.radius_window or 0,
        bordersize = card_border,
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        content_vg,
    }

    overlay = InputContainer:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        key_events = {
            Close = { { "Back" } }
        },
        card,
    }

    overlay.onClose = function()
        UIManager:close(overlay, "ui")
        return true
    end

    UIManager:show(overlay, "ui")
end

function DeleteUI:init(Storefront)
    Storefront.showDeleteConfirmationDialog = function(sf, display_name, is_plugin, plugin_instance, on_confirm)
        return DeleteUI.showDeleteConfirmationDialog(display_name, is_plugin, plugin_instance, on_confirm)
    end

    Storefront.disablePlugin = function(sf, dirname)
        if not dirname or dirname == "" then
            return false
        end
        local G_reader_settings = _G.G_reader_settings
        local plugins_disabled = (G_reader_settings and G_reader_settings:readSetting("plugins_disabled")) or {}
        local plugin_name = dirname:gsub("%.koplugin$", "")
        plugins_disabled[plugin_name] = true
        if G_reader_settings then
            G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
        end
        return true
    end

    Storefront.enablePlugin = function(sf, dirname)
        if not dirname or dirname == "" then
            return false
        end
        local G_reader_settings = _G.G_reader_settings
        local plugins_disabled = (G_reader_settings and G_reader_settings:readSetting("plugins_disabled")) or {}
        local plugin_name = dirname:gsub("%.koplugin$", "")
        plugins_disabled[plugin_name] = nil
        if G_reader_settings then
            G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
        end
        return true
    end

    Storefront.performPluginDeletion = function(sf, dirname, record, plugin_instance_for_settings)
        StorefrontLogger.action(string.format("DELETE starting: plugin %s", tostring(dirname)))
        local plugin = sf.listInstalledPlugins and sf:listInstalledPlugins()
        local matched_plugin
        local clean_dir = dirname:gsub("%.koplugin$", "")
        local dir_with_ext = clean_dir .. ".koplugin"

        if plugin then
            for _, p in ipairs(plugin) do
                if p.dirname == dirname or p.dirname == clean_dir or p.dirname == dir_with_ext
                    or (p.dirname and p.dirname:lower() == clean_dir:lower())
                    or (p.dirname and p.dirname:lower() == dir_with_ext:lower())
                    or (p.name and p.name:lower() == clean_dir:lower()) then
                    matched_plugin = p
                    break
                end
            end
        end

        local display_name = matched_plugin and (matched_plugin.name or matched_plugin.dirname) or clean_dir
        local plugin_path = matched_plugin and matched_plugin.path

        if not plugin_path or lfs.attributes(plugin_path, "mode") ~= "directory" then
            local roots = PluginPaths.getLookupPaths() or {}
            table.insert(roots, PluginPaths.getDefaultPluginsRoot())
            local candidates = {
                dir_with_ext,
                clean_dir,
                dirname,
            }
            for _, root in ipairs(roots) do
                if root and root ~= "" then
                    for _, cand in ipairs(candidates) do
                        local p_cand = root .. "/" .. cand
                        if lfs.attributes(p_cand, "mode") == "directory" then
                            plugin_path = p_cand
                            break
                        end
                    end
                end
                if plugin_path then break end
            end
        end

        if not plugin_path then
            plugin_path = PluginPaths.getDefaultPluginsRoot() .. "/" .. dir_with_ext
        end

        local ok, err = deleteDirectoryRecursive(plugin_path)
        if ok then
            local G_reader_settings = _G.G_reader_settings
            if plugin_instance_for_settings then
                if type(plugin_instance_for_settings.deletePluginSettings) == "function" then
                    pcall(plugin_instance_for_settings.deletePluginSettings, plugin_instance_for_settings)
                end
                
                if plugin_instance_for_settings.settings_file then
                    os.remove(plugin_instance_for_settings.settings_file)
                    os.remove(plugin_instance_for_settings.settings_file .. ".old")
                end
                
                if plugin_instance_for_settings.settings_key and G_reader_settings then
                    G_reader_settings:delSetting(plugin_instance_for_settings.settings_key)
                end
                
                if G_reader_settings then
                    G_reader_settings:flush()
                end
            end
            
            if record then
                InstallStore.remove(dirname)
                InstallStore.remove(clean_dir)
                InstallStore.remove(dir_with_ext)
            end
            StorefrontLogger.action(string.format("DELETED plugin %s from disk (%s)", tostring(dirname), plugin_path))
            if sf.showRestartConfirmation then
                sf:showRestartConfirmation(string.format(_("Plugin '%s' deleted."), display_name))
            end
            if sf.updates_menu then
                sf:updateUpdatesDialog()
            end
        else
            StorefrontLogger.err(string.format("DELETE failed for plugin %s: %s", tostring(dirname), tostring(err)))
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to delete plugin: %s"), tostring(err)),
                timeout = 5,
            })
        end
    end

    Storefront.deletePlugin = function(sf, dirname, record)
        if not dirname or dirname == "" then
            return
        end
        local installed = sf.listInstalledPlugins and sf:listInstalledPlugins() or {}
        local plugin
        for _, p in ipairs(installed) do
            if p.dirname == dirname then
                plugin = p
                break
            end
        end
        local display_name = plugin and (plugin.name or plugin.dirname) or dirname

        local PluginLoader = require("pluginloader")
        local plugin_name = dirname:gsub("%.koplugin$", "")
        local plugin_instance = PluginLoader:getPluginInstance(plugin_name)

        DeleteUI.showDeleteConfirmationDialog(display_name, true, plugin_instance, function(delete_settings)
            sf:performPluginDeletion(dirname, record, delete_settings and plugin_instance)
        end)
    end

    Storefront.deletePatch = function(sf, patch_filename)
        if not patch_filename or patch_filename == "" then
            return
        end
        local display_name = patch_filename
        DeleteUI.showDeleteConfirmationDialog(display_name, "patch", nil, function()
            local PATCHES_ROOT = DataStorage:getDataDir() .. "/patches"
            local patch_path = PATCHES_ROOT .. "/" .. patch_filename
            local ok, err = os.remove(patch_path)
            if not ok and not patch_filename:match("%.disabled$") then
                ok, err = os.remove(patch_path .. ".disabled")
            end
            InstallStore.removePatch(patch_filename)
            if sf.invalidateInstalledPatchesCache then
                sf:invalidateInstalledPatchesCache()
            end
            StorefrontLogger.action(string.format("DELETED patch %s from disk", tostring(patch_filename)))
            if sf.showRestartConfirmation then
                sf:showRestartConfirmation(string.format(_("Patch '%s' deleted."), display_name))
            end
            if sf.updates_menu then
                sf:updateUpdatesDialog()
            end
            if sf.softRefreshCurrentBrowserView then
                sf:softRefreshCurrentBrowserView()
            end
        end)
    end
end

DeleteUI.deleteDirectoryRecursive = deleteDirectoryRecursive

return DeleteUI
