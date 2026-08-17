local Screen = require("device").screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local LineWidget = require("ui/widget/linewidget")
local CheckButton = require("ui/widget/checkbutton")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InputDialog = require("ui/widget/inputdialog")
local ImageWidget = require("ui/widget/imagewidget")
local DataStorage = require("datastorage")
local util = require("util")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local storefront_theme = require("storefront_theme")
local StorefrontUtils = require("storefront_utils")

local StorefrontFilterDialog = {}

local function sc(val)
    return Screen:scaleBySize(val)
end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    local rel_path = dir .. "assets/" .. filename

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    local paths_to_try = {
        rel_path,
        "plugins/storefront.koplugin/assets/" .. filename,
    }

    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local data_dir = DataStorage:getDataDir()
        table.insert(paths_to_try, data_dir .. "/plugins/storefront.koplugin/assets/" .. filename)
    end

    local ok_paths, StorefrontPluginPaths = pcall(require, "storefront_plugin_paths")
    if ok_paths and StorefrontPluginPaths and StorefrontPluginPaths.getLookupPaths then
        for _, root in ipairs(StorefrontPluginPaths.getLookupPaths()) do
            table.insert(paths_to_try, root .. "/storefront.koplugin/assets/" .. filename)
        end
    end

    if ok_lfs and lfs and lfs.attributes then
        for _, p in ipairs(paths_to_try) do
            if lfs.attributes(p, "mode") == "file" then
                return p
            end
        end
    end

    return rel_path
end

function StorefrontFilterDialog.showInstalledFilter(arg1, arg2)
    local Storefront = (arg1 ~= StorefrontFilterDialog and arg1 and arg1.ensureInstalledState) and arg1 or arg2
    if not Storefront or type(Storefront) ~= "table" or not Storefront.ensureInstalledState then
        Storefront = require("main")
    end
    Storefront:ensureInstalledState()
    local state = Storefront.installed_state

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

        local title_label = TextWidget:new{
            text = _("Filter & Sort Installed"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
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

        local function create_setting_row(left_text, right_widget, callback)
            local row_elements = {}
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = 0
            if right_widget then
                right_w = (right_widget.getSize and right_widget:getSize().w) or sc(60)
            end

            local max_left_w = math.max(sc(60), avail_w - right_w - sc(12))

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }
            table.insert(row_elements, txt)

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)
            table.insert(row_elements, HorizontalSpan:new{ width = spacer_w })

            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
                padding = frame_padding,
                width = dialog_w - sc(4),
                HorizontalGroup:new(row_elements),
            }

            if not callback then return frame end

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

        table.insert(content_vg, create_section_header(_("Filters")))

        local type_labels = { all = _("All Types"), plugin = _("Plugins"), patch = _("Patches"), font = _("Fonts"), screensaver = _("Screensavers") }
        local cur_type = state.filter_type or "all"
        local type_widget = TextWidget:new{
            text = type_labels[cur_type] or cur_type,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Type"), type_widget, function()
            if cur_type == "all" then state.filter_type = "plugin"
            elseif cur_type == "plugin" then state.filter_type = "patch"
            elseif cur_type == "patch" then state.filter_type = "font"
            elseif cur_type == "font" then state.filter_type = "screensaver"
            else state.filter_type = "all" end
            Storefront.browser_state.page = 1
            Storefront:saveInstalledState()
            refresh()
        end))

        local origin_labels = { all = _("All"), exclude_default = _("User Installed"), default_only = _("Default only") }
        local cur_origin = state.filter_default or "all"
        local origin_widget = TextWidget:new{
            text = origin_labels[cur_origin] or cur_origin,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Origin"), origin_widget, function()
            if cur_origin == "all" then state.filter_default = "exclude_default"
            elseif cur_origin == "exclude_default" then state.filter_default = "default_only"
            else state.filter_default = "all" end
            Storefront.browser_state.page = 1
            Storefront:saveInstalledState()
            refresh()
        end))

        local status_labels = { all = _("All"), enabled = _("Enabled"), disabled = _("Disabled") }
        local cur_status = state.filter_status or "all"
        local status_widget = TextWidget:new{
            text = status_labels[cur_status] or cur_status,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Status"), status_widget, function()
            if cur_status == "all" then state.filter_status = "enabled"
            elseif cur_status == "enabled" then state.filter_status = "disabled"
            else state.filter_status = "all" end
            Storefront.browser_state.page = 1
            Storefront:saveInstalledState()
            refresh()
        end))

        table.insert(content_vg, create_section_header(_("Sorting")))

        local sort_labels = {
            name_asc = _("Name (A-Z)"),
            name_desc = _("Name (Z-A)"),
            date_desc = _("Last Updated (Newest)"),
            date_asc = _("Last Updated (Oldest)"),
            type = _("Type"),
            status = _("Status"),
        }
        local cur_sort = state.sort_mode or "name_asc"
        local sort_widget = TextWidget:new{
            text = sort_labels[cur_sort] or cur_sort,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Sort mode"), sort_widget, function()
            if cur_sort == "name_asc" then state.sort_mode = "name_desc"
            elseif cur_sort == "name_desc" then state.sort_mode = "date_desc"
            elseif cur_sort == "date_desc" then state.sort_mode = "date_asc"
            elseif cur_sort == "date_asc" then state.sort_mode = "type"
            elseif cur_sort == "type" then state.sort_mode = "status"
            else state.sort_mode = "name_asc" end
            Storefront.browser_state.page = 1
            Storefront:saveInstalledState()
            refresh()
        end))

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
        local reset_widget = TextWidget:new{
            text = _("Reset to defaults"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        table.insert(content_vg, create_setting_row(_("Reset filters"), reset_widget, function()
            state.search_text = ""
            state.filter_type = "all"
            state.filter_default = "all"
            state.filter_status = "all"
            state.sort_mode = "name_asc"
            Storefront.browser_state.page = 1
            Storefront:saveInstalledState()
            refresh()
        end))

        -- Centered Apply button at bottom
        local apply_btn = Button:new{
            text = _("Apply"),
            text_font_size = 18,
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = sc(10),
            radius = sc(4),
            width = dialog_w - sc(36),
            allow_flash = false,
            callback = function()
                if overlay then UIManager:close(overlay, "ui") end
                UIManager:nextTick(function()
                    Storefront:reopenBrowser()
                end)
            end,
        }
        if apply_btn.label_widget then
            apply_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end

        local apply_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = apply_btn:getSize().h },
                apply_btn,
            }
        }
        table.insert(content_vg, apply_container)

        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
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
            Storefront:reopenBrowser()
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

function StorefrontFilterDialog.showCatalogFilter(arg1, arg2)
    local Storefront = (arg1 ~= StorefrontFilterDialog and arg1 and arg1.ensureBrowserState) and arg1 or arg2
    if not Storefront or type(Storefront) ~= "table" or not Storefront.ensureBrowserState then
        Storefront = require("main")
    end
    Storefront:ensureBrowserState()
    local state = Storefront.browser_state

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

        local title_text = (state.tab == "Patches") and _("Filter & Sort Patches") or ((state.tab == "Fonts") and _("Filter & Sort Fonts") or _("Filter & Sort Plugins"))
        local title_label = TextWidget:new{
            text = title_text,
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
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

        local function create_setting_row(left_text, right_widget, callback)
            local row_elements = {}
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = 0
            if right_widget then
                right_w = (right_widget.getSize and right_widget:getSize().w) or sc(60)
            end

            local max_left_w = math.max(sc(60), avail_w - right_w - sc(12))

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }
            table.insert(row_elements, txt)

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)
            table.insert(row_elements, HorizontalSpan:new{ width = spacer_w })

            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
                padding = frame_padding,
                width = dialog_w - sc(4),
                HorizontalGroup:new(row_elements),
            }

            if not callback then return frame end

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

        table.insert(content_vg, create_section_header(_("Filters")))

        if state.tab == "Fonts" or state.kind == "font" then
            local cat_presets = { "all", "serif", "sans-serif", "dyslexia", "slab serif" }
            local cur_cat = state.font_category or "all"
            local cat_label = (cur_cat == "all") and _("All") or cur_cat:lower()
            local cat_widget = TextWidget:new{
                text = cat_label,
                face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
                fgcolor = storefront_theme.color_label_dim,
            }
            table.insert(content_vg, create_setting_row(_("Font style"), cat_widget, function()
                local next_cat = "all"
                for idx, c in ipairs(cat_presets) do
                    if cur_cat:lower() == c:lower() then
                        next_cat = cat_presets[(idx % #cat_presets) + 1]
                        break
                    end
                end
                state.font_category = next_cat
                refresh()
            end))
        end

        -- Min. stars row (presets: 0 -> 10 -> 50 -> 100 -> 500 -> 1000 -> 0)
        local star_presets = { 0, 10, 50, 100, 500, 1000 }
        local cur_stars = tonumber(state.min_stars) or 0
        local stars_label = (cur_stars > 0) and (tostring(cur_stars) .. "+") or _("Any")
        local stars_widget = TextWidget:new{
            text = stars_label,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Minimum stars"), stars_widget, function()
            local next_val = 0
            for idx, p in ipairs(star_presets) do
                if cur_stars == p then
                    next_val = star_presets[(idx % #star_presets) + 1]
                    break
                end
            end
            state.min_stars = next_val
            refresh()
        end))

        table.insert(content_vg, create_section_header(_("Sorting")))

        local sort_opt = Storefront:getSortOption(state.sort_mode)
        local sort_text = sort_opt and sort_opt.summary or _("Sort")
        local sort_widget = TextWidget:new{
            text = sort_text,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Sort mode"), sort_widget, function()
            if overlay then
                UIManager:close(overlay, "ui")
            end
            Storefront:browserAdvanceSort()
        end))

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
        local reset_widget = TextWidget:new{
            text = _("Reset to defaults"),
            face = Font:getFace("cfont", ui_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        table.insert(content_vg, create_setting_row(_("Reset filters"), reset_widget, function()
            state.search_text = ""
            state.owner = ""
            state.font_category = "all"
            state.min_stars = 0
            state.sort_mode = "stars_desc"
            state.page = 1
            Storefront:saveBrowserState()
            refresh()
        end))

        -- Apply button at bottom
        local apply_btn = Button:new{
            text = _("Apply"),
            text_font_size = 18,
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = sc(10),
            radius = sc(4),
            width = dialog_w - sc(36),
            callback = function()
                if overlay then UIManager:close(overlay, "ui") end
                state.page = 1
                Storefront:saveBrowserState()
                Storefront:reopenBrowser()
            end,
        }
        if apply_btn.label_widget then
            apply_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end

        local apply_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = apply_btn:getSize().h },
                apply_btn,
            }
        }
        table.insert(content_vg, apply_container)

        local card = FrameContainer:new{
            padding = 0,
            radius = storefront_theme.radius_window or 0,
            bordersize = sc(2),
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
            state.page = 1
            Storefront:saveBrowserState()
            Storefront:reopenBrowser()
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

function StorefrontFilterDialog.show(arg1, arg2)
    local Storefront = (arg1 ~= StorefrontFilterDialog and arg1 and arg1.ensureBrowserState) and arg1 or arg2
    if not Storefront or type(Storefront) ~= "table" or not Storefront.ensureBrowserState then
        Storefront = require("main")
    end
    Storefront:ensureBrowserState()
    Storefront:ensureInstalledState()

    local active_tab = (Storefront.browser_state and Storefront.browser_state.tab) or "Plugins"
    local filters = Storefront.browser_state
    local dialog
    local check_readme

    local inst_st = Storefront.installed_state and Storefront.installed_state.search_text
    local cur_search = (active_tab == "Installed" and inst_st and inst_st ~= "") and inst_st or (filters.search_text or "")

    dialog = MultiInputDialog:new{
        title = _("Search"),
        fields = {
            {
                description = _("Search text"),
                text = cur_search,
                hint = _("Name, description, topic"),
            },
            {
                description = _("Owner"),
                text = filters.owner or "",
                hint = _("anyone"),
            },
            {
                description = _("Minimum stars"),
                input_type = "number",
                text = (filters.min_stars and filters.min_stars > 0) and tostring(filters.min_stars) or "",
                hint = "0",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    allow_flash = false,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear"),
                    allow_flash = false,
                    callback = function()
                        if active_tab == "Installed" then
                            Storefront.installed_state.search_text = ""
                            Storefront:saveInstalledState()
                        end
                        Storefront.browser_state.search_text = ""
                        Storefront.browser_state.owner = ""
                        Storefront.browser_state.min_stars = 0
                        Storefront.readme_filter = nil
                        Storefront.browser_state.page = 1
                        Storefront.browser_state.scroll_offset = nil
                        Storefront:saveBrowserState()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            Storefront:reopenBrowser()
                        end)
                    end,
                },
                {
                    text = _("Apply"),
                    allow_flash = false,
                    is_enter_default = true,
                    callback = function()
                        local values = dialog:getFields() or {}
                        local search_val = util.trim(values[1] or "")
                        if active_tab == "Installed" then
                            Storefront.installed_state.search_text = search_val
                            Storefront:saveInstalledState()
                        end
                        Storefront.browser_state.search_text = search_val
                        Storefront.browser_state.owner = util.trim(values[2] or "")
                        local stars = tonumber(values[3]) or 0
                        if stars < 0 then
                            stars = 0
                        end
                        Storefront.browser_state.min_stars = math.floor(stars)
                        Storefront.readme_filter = nil
                        Storefront.browser_state.page = 1
                        Storefront.browser_state.scroll_offset = nil
                        Storefront:saveBrowserState()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            Storefront:reopenBrowser()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function StorefrontFilterDialog.showScreensaverFilter(arg1, arg2)
    local Storefront = (arg1 ~= StorefrontFilterDialog and arg1 and arg1.ensureBrowserState) and arg1 or arg2
    if not Storefront or type(Storefront) ~= "table" or not Storefront.ensureBrowserState then
        Storefront = require("main")
    end
    Storefront:ensureBrowserState()
    local state = Storefront.browser_state

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local catalog = Storefront.screensavers_cache or {}
    local cat_counts = {}
    local seen_cats = {}
    local cats = { "all" }
    cat_counts["all"] = #catalog

    for _, entry in ipairs(catalog) do
        local mapped_cats = StorefrontUtils.getMappedScreensaverCategories(entry.category)
        for _, mc in ipairs(mapped_cats) do
            local key = mc:lower()
            cat_counts[key] = (cat_counts[key] or 0) + 1
            if not seen_cats[key] then
                seen_cats[key] = true
                table.insert(cats, mc)
            end
        end
    end
    table.sort(cats, function(a, b)
        if a == "all" then return true end
        if b == "all" then return false end
        return tostring(a):lower() < tostring(b):lower()
    end)

    local sort_order = { "popular", "downloads", "recent", "az", "za" }
    local sort_labels = {
        popular   = _("Most Popular"),
        downloads = _("Most Downloaded"),
        recent    = _("Recently Added"),
        az        = _("A -> Z"),
        za        = _("Z -> A"),
    }

    local function getCategorySummary(set, legacy_cat)
        if type(set) == "table" and next(set) and not set["all"] then
            local selected_list = {}
            for _, c in ipairs(cats) do
                if c ~= "all" and set[c:lower()] then
                    table.insert(selected_list, c)
                end
            end
            if #selected_list == 1 then return selected_list[1] end
            if #selected_list == 2 then return selected_list[1] .. ", " .. selected_list[2] end
            if #selected_list > 2 then return selected_list[1] .. string.format(" (+%d)", #selected_list - 1) end
        end
        if legacy_cat and legacy_cat ~= "" and legacy_cat ~= "all" then
            return legacy_cat
        end
        return _("All")
    end

    -- Shared helpers
    local function make_row_item(frame, callback, row_w, row_h)
        local item = InputContainer:new{ frame }
        item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = item.dimen
                        if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                        return Geom:new{
                            x = dim.x or 0, y = dim.y or 0,
                            w = row_w or (dialog_w - sc(4)), h = row_h or 0,
                        }
                    end
                }
            }
        }
        item.onTap = function() callback(); return true end
        return item
    end

    local function make_section_header(title)
        local label = TextWidget:new{
            text = title:upper(),
            face = Font:getFace("cfont", storefront_theme.section_header_font_size or 16),
            bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        return FrameContainer:new{
            padding = sc(5), padding_left = sc(8), bordersize = 0,
            width = dialog_w - sc(4), background = Blitbuffer.COLOR_LIGHT_GRAY,
            label,
        }
    end

    -- Category picker: full second card that looks like the main filter card
    local function showCategoryOverlay(on_save)
        local cat_overlay
        local cat_set = {}
        if type(state.screensaver_categories) == "table" then
            for k, v in pairs(state.screensaver_categories) do cat_set[k] = v end
        elseif state.screensaver_category and state.screensaver_category ~= "" and state.screensaver_category ~= "all" then
            cat_set[state.screensaver_category:lower()] = true
        end
        if not next(cat_set) then cat_set["all"] = true end

        local function build_cat_overlay()
            if cat_overlay then UIManager:close(cat_overlay, "ui") end

            local title_label = TextWidget:new{
                text = _("Select Categories"),
                face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
                bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local content = VerticalGroup:new{
                align = "left",
                FrameContainer:new{ padding = sc(10), bordersize = 0, title_label },
                LineWidget:new{ dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) }, background = Blitbuffer.COLOR_BLACK },
            }

            -- Select All / Clear buttons row
            local sel_all_btn = Button:new{
                text = _("Select All"), text_font_size = 14,
                bordersize = sc(1), radius = sc(3), padding = sc(4), padding_h = sc(12),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local new_set = {}
                    for _, c in ipairs(cats) do new_set[c:lower()] = true end
                    cat_set = new_set
                    build_cat_overlay()
                end,
            }
            local clear_btn = Button:new{
                text = _("Clear"), text_font_size = 14,
                bordersize = sc(1), radius = sc(3), padding = sc(4), padding_h = sc(12),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    cat_set = { all = true }
                    build_cat_overlay()
                end,
            }
            local done_btn = Button:new{
                text = _("Done"), text_font_size = 14,
                bordersize = 0, radius = sc(3), padding = sc(4), padding_h = sc(16),
                background = Blitbuffer.COLOR_BLACK,
                text_font_color = Blitbuffer.COLOR_WHITE,
                callback = function()
                    if cat_overlay then UIManager:close(cat_overlay, "ui") end
                    on_save(cat_set)
                end,
            }
            if done_btn.label_widget then done_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE end

            local action_row_frame = FrameContainer:new{
                padding = sc(8), bordersize = 0, width = dialog_w - sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = dialog_w - sc(20), h = sc(36) },
                    HorizontalGroup:new{
                        sel_all_btn,
                        HorizontalSpan:new{ width = sc(10) },
                        clear_btn,
                        HorizontalSpan:new{ width = sc(10) },
                        done_btn,
                    }
                }
            }
            table.insert(content, action_row_frame)
            table.insert(content, LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })

            -- All category rows (with generous padding, FeatherIcons, and text)
            for idx, cat_name in ipairs(cats) do
                local key = cat_name:lower()
                local is_checked = (cat_set[key] == true) or (cat_set["all"] and key == "all")
                local display_name = (cat_name == "all") and _("All Categories") or cat_name
                local count_str = cat_counts[key] and string.format(" (%d)", cat_counts[key]) or ""

                local icon_file = getAssetPath(is_checked and "check-square.svg" or "square.svg")
                local icon_widget = ImageWidget:new{
                    file = icon_file,
                    width = sc(22),
                    height = sc(22),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                local row_label = TextBoxWidget:new{
                    text = display_name .. count_str,
                    face = Font:getFace("cfont", ui_font_size - 1),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width = dialog_w - sc(68),
                    alignment = "left",
                }

                local row_group = HorizontalGroup:new{
                    CenterContainer:new{
                        dimen = Geom:new{ w = sc(24), h = sc(24) },
                        icon_widget,
                    },
                    HorizontalSpan:new{ width = sc(12) },
                    row_label,
                }

                local row_frame = FrameContainer:new{
                    bordersize = 0,
                    padding = sc(12),
                    padding_left = sc(16),
                    padding_right = sc(16),
                    width = dialog_w - sc(4),
                    background = Blitbuffer.COLOR_WHITE,
                    row_group,
                }

                local target_key = key
                local row_item = InputContainer:new{ row_frame }
                row_item.ges_events = {
                    Tap = {
                        GestureRange:new{
                            ges = "tap",
                            range = function()
                                return row_item.dimen or row_frame:getSize()
                            end,
                        },
                    },
                }
                row_item.onTap = function()
                    if target_key == "all" then
                        cat_set = { all = true }
                    else
                        cat_set["all"] = nil
                        if cat_set[target_key] then
                            cat_set[target_key] = nil
                        else
                            cat_set[target_key] = true
                        end
                        if not next(cat_set) then cat_set["all"] = true end
                    end
                    build_cat_overlay()
                    return true
                end
                table.insert(content, row_item)

                if idx < #cats then
                    table.insert(content, LineWidget:new{
                        dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                    })
                end
            end

            local card = FrameContainer:new{
                padding = 0,
                radius = storefront_theme.radius_window or 0,
                bordersize = sc(2), color = Blitbuffer.COLOR_BLACK,
                background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
                width = dialog_w,
                content,
            }

            cat_overlay = InputContainer:new{
                align = "center",
                vertical_align = "center",
                dimen = Geom:new{ w = sw, h = sh },
                key_events = { Close = { { "Back" } } },
                card,
            }
            cat_overlay.onClose = function()
                if cat_overlay then UIManager:close(cat_overlay, "ui") end
                on_save(cat_set)
                return true
            end

            UIManager:show(cat_overlay, "ui")
        end

        build_cat_overlay()
    end

    local overlay
    local refresh

    refresh = function()
        if overlay then UIManager:close(overlay, "ui") end

        local title_label = TextWidget:new{
            text = _("Filter & Sort Screensavers"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local content_vg = VerticalGroup:new{
            align = "left",
            FrameContainer:new{ padding = sc(10), bordersize = 0, title_label },
            LineWidget:new{ dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) }, background = Blitbuffer.COLOR_BLACK },
        }

        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or sc(60)) or 0
            local max_left_w = math.max(sc(60), avail_w - right_w - sc(12))

            local txt = TextBoxWidget:new{
                text = left_text, face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK, width = max_left_w, alignment = "left",
            }
            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_children = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then table.insert(row_children, right_widget) end

            local frame = FrameContainer:new{
                bordersize = 0, padding = frame_padding,
                width = dialog_w - sc(4), HorizontalGroup:new(row_children),
            }
            if not callback then return frame end
            return make_row_item(frame, callback, dialog_w - sc(4), (frame:getSize() or { h = 0 }).h)
        end

        table.insert(content_vg, make_section_header(_("Filters")))

        -- Category row
        local cat_display = getCategorySummary(state.screensaver_categories, state.screensaver_category)
        local cat_widget = TextWidget:new{
            text = cat_display,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Categories"), cat_widget, function()
            showCategoryOverlay(function(new_set)
                state.screensaver_categories = new_set
                state.screensaver_category = ""
                refresh()
            end)
        end))

        table.insert(content_vg, make_section_header(_("Sorting")))

        -- Sort row
        local cur_sort = state.screensaver_sort or "popular"
        local sort_widget = TextWidget:new{
            text = sort_labels[cur_sort] or sort_labels.popular,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Sort mode"), sort_widget, function()
            local next_s = "popular"
            for idx, s in ipairs(sort_order) do
                if cur_sort == s then next_s = sort_order[(idx % #sort_order) + 1]; break end
            end
            state.screensaver_sort = next_s
            refresh()
        end))

        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
        local reset_widget = TextWidget:new{
            text = _("Reset to defaults"), face = Font:getFace("cfont", ui_font_size),
            bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        table.insert(content_vg, create_setting_row(_("Reset filters"), reset_widget, function()
            state.screensaver_category = ""
            state.screensaver_categories = nil
            state.screensaver_sort = "popular"
            state.screensaver_search = ""
            state.search_text = ""
            state.owner = ""
            refresh()
        end))

        -- Apply button
        local apply_btn = Button:new{
            text = _("Apply"), text_font_size = 18,
            text_font_color = Blitbuffer.COLOR_WHITE, background = Blitbuffer.COLOR_BLACK,
            bordersize = 0, padding = sc(10), radius = sc(4), width = dialog_w - sc(36),
            callback = function()
                if overlay then UIManager:close(overlay, "ui") end
                state.page = 1
                Storefront:saveBrowserState()
                Storefront:reopenBrowser()
            end,
        }
        if apply_btn.label_widget then apply_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE end

        table.insert(content_vg, FrameContainer:new{
            padding = sc(10), bordersize = 0, width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = apply_btn:getSize().h },
                apply_btn,
            }
        })

        local card = FrameContainer:new{
            padding = 0, radius = storefront_theme.radius_window or 0,
            bordersize = sc(2), color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w, content_vg,
        }

        overlay = InputContainer:new{
            align = "center", vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card,
        }
        overlay.onClose = function()
            state.page = 1
            Storefront:saveBrowserState()
            Storefront:reopenBrowser()
            return true
        end
        UIManager:show(overlay, "ui")
    end

    refresh()
end

return StorefrontFilterDialog
