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
local util = require("util")
local _ = require("gettext")
local storefront_theme = require("storefront_theme")

local StorefrontFilterDialog = {}

local function sc(val)
    return Screen:scaleBySize(val)
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

        local type_labels = { all = _("All"), plugin = _("Plugins"), patch = _("Patches") }
        local cur_type = state.filter_type or "all"
        local type_widget = TextWidget:new{
            text = type_labels[cur_type] or cur_type,
            face = Font:getFace("cfont", storefront_theme.subtext_font_size or 16),
            fgcolor = storefront_theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Type"), type_widget, function()
            if cur_type == "all" then state.filter_type = "plugin"
            elseif cur_type == "plugin" then state.filter_type = "patch"
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
            callback = function()
                if overlay then UIManager:close(overlay, "ui") end
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
            radius = sc(12),
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

    local cur_search = (active_tab == "Installed") and (Storefront.installed_state.search_text or "") or (filters.search_text or "")

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
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear"),
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
                        Storefront:reopenBrowser()
                    end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local values = dialog:getFields()
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
                        Storefront:reopenBrowser()
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        pcall(function() dialog:onShowKeyboard() end)
    end
end

return StorefrontFilterDialog
