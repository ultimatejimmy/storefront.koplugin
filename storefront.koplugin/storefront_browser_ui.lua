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
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Input = Device.input
local StorefrontListItem = require("storefront_list_item")

-- Resolves a file under this plugin's own assets/ directory, regardless of
-- where the plugin was actually installed (bundled "plugins" dir vs a custom
-- extra_plugin_paths location). IconWidget/Button's "icon" field can't do
-- this itself -- it only resolves bare names against KOReader's built-in
-- resources/icons directories, so a path like
-- "../plugins/storefront.koplugin/assets/zap" silently falls back to
-- KOReader's "icon not found" placeholder instead of raising an error.
local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local StorefrontBrowserDialog = FocusManager:extend{
    covers_fullscreen = true,
    Storefront = nil,
    title = "",
    items = nil,
    width = nil,
    page = 1,
    total_pages = 1,
    scroll_offset = nil,
    on_prev_page = nil,
    on_next_page = nil,
    on_dismiss = nil,
    on_settings_tap = nil,
    current_tab = "Plugins",
    updates_count = 0,
    on_tab_switch = nil,
}

function StorefrontBrowserDialog:buildTabBar()
    local tabs = { "Plugins", "Patches", "Installed", "Updates" }
    local tab_widgets = {}

    local sc = function(val) return Device.screen:scaleBySize(val) end

    for i, tab_name in ipairs(tabs) do
        if i > 1 then
            table.insert(tab_widgets, HorizontalSpan:new{ width = sc(12) })
        end

        local is_active = (self.current_tab == tab_name)
        local font_face = is_active and Font:getFace("smallinfofontbold", 18) or Font:getFace("smallinfofont", 17)
        
        local label = TextWidget:new{
            text = tab_name,
            face = font_face,
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(80),
        }

        local tab_elements = { label }

        if tab_name == "Updates" and self.updates_count > 0 then
            local badge_inner = TextWidget:new{
                text = tostring(self.updates_count),
                face = Font:getFace("smallinfofontbold", 12),
                fgcolor = Blitbuffer.COLOR_WHITE,
            }
            local badge = FrameContainer:new{
                padding = sc(2),
                padding_left = sc(5),
                padding_right = sc(5),
                bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                radius = sc(8),
                badge_inner,
            }
            table.insert(tab_elements, HorizontalSpan:new{ width = sc(3) })
            table.insert(tab_elements, badge)
        end

        local tab_row = HorizontalGroup:new(tab_elements)

        local underline
        if is_active then
            underline = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = tab_row:getSize().w, h = sc(3) },
            }
        else
            underline = VerticalSpan:new{ width = sc(3) }
        end

        local tab_group = VerticalGroup:new{
            tab_row,
            VerticalSpan:new{ width = sc(4) },
            underline,
        }

        local tab_btn = InputContainer:new{
            tab_group,
        }
        tab_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = tab_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        return Geom:new{
                            x = dim.x or 0,
                            y = dim.y or 0,
                            w = dim.w or 0,
                            h = dim.h or 0
                        }
                    end,
                }
            }
        }
        tab_btn.onTap = function()
            if self.on_tab_switch then
                self.on_tab_switch(tab_name)
            end
            return true
        end

        table.insert(tab_widgets, tab_btn)
    end

    local tab_bar_group = HorizontalGroup:new(tab_widgets)
    return FrameContainer:new{
        padding_top = sc(12),
        padding_left = sc(12),
        padding_right = sc(12),
        padding_bottom = 0,
        bordersize = 0,
        tab_bar_group,
    }
end

function StorefrontBrowserDialog:init()
    self.show_parent = self
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
        self.key_events.NextPage = { { Input.group.PgFwd } }
        self.key_events.PrevPage = { { Input.group.PgBack } }
        self.key_events.ShowMenu = { { "Menu" } }
    end
    if Device:hasKeyboard() then
        self.key_events.HotkeyRefresh = { { "R" } }
        self.key_events.HotkeyFilter = { { "F" } }
        self.key_events.HotkeySort = { { "S" } }
        self.key_events.HotkeySwitchTab = { { "T" } }
    end

    local storefront_theme = require("storefront_theme")
    local sc = function(val) return Device.screen:scaleBySize(val) end

    local zap_icon = ImageWidget:new{
        file = getAssetPath("zap.svg"),
        width = sc(24),
        height = sc(24),
        scale_factor = 0,
        alpha = true,
    }

    local title_label = TextWidget:new{
        text = self.title or _("Storefront"),
        face = Font:getFace("NotoSerif-Bold.ttf", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local btn_w = sc(48)
    local btn_h = sc(48)

    local filter_btn = Button:new{
        icon = "appbar.search",
        width = btn_w,
        height = btn_h,
        bordersize = sc(1),
        radius = storefront_theme.radius_spec_btn,
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            if self.on_filter then self.on_filter() end
        end,
    }

    local settings_btn = Button:new{
        icon = "appbar.settings",
        width = btn_w,
        height = btn_h,
        bordersize = sc(1),
        radius = storefront_theme.radius_spec_btn,
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            if self.on_settings_tap then self.on_settings_tap() end
        end,
    }

    -- Use IconButton with allow_flash=false: this is the required KOReader pattern
    -- for any button that closes its container. With allow_flash=true (the default),
    -- KOReader's flash_ui code does UIManager:setDirty and forceRePaint AFTER the
    -- callback fires -- but if the callback already destroyed the widget, it crashes.
    local close_btn = IconButton:new{
        icon = "close",
        width = sc(24),
        height = sc(24),
        padding = sc(12),
        allow_flash = false,
        show_parent = self,
        callback = function()
            self:onClose()
        end,
    }

    local padding_h = sc(12) * 2
    local title_margin_left = sc(12)
    local logo_w = zap_icon:getSize().w
    local logo_gap = sc(8)
    local total_btns_w = btn_w * 3 + sc(16)
    local title_w = title_label:getSize().w
    local spacer_w = math.max(sc(8), self.width - padding_h - title_margin_left - logo_w - logo_gap - title_w - total_btns_w)

    local header_group = HorizontalGroup:new{
        HorizontalSpan:new{ width = title_margin_left },
        zap_icon,
        HorizontalSpan:new{ width = logo_gap },
        title_label,
        HorizontalSpan:new{ width = spacer_w },
        filter_btn,
        HorizontalSpan:new{ width = sc(8) },
        settings_btn,
        HorizontalSpan:new{ width = sc(8) },
        close_btn,
    }

    self.header = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        header_group,
    }

    self._header_filter_btn = filter_btn
    self._header_settings_btn = settings_btn
    self._close_btn = close_btn

    self._focusable_items = {}
    self._focusable_row_offsets = {}

    local list_group = VerticalGroup:new{}
    local entry_width = self:getListEntryWidth()
    local total_items = self.items and #self.items or 0

    if self.items then
        for idx, entry in ipairs(self.items) do
            local item_widget = StorefrontListItem:new{
                entry = entry,
                width = entry_width,
                dialog = self,
                show_parent = self,
            }
            list_group[#list_group + 1] = item_widget
            if item_widget:isFocusable() then
                self._focusable_items[#self._focusable_items + 1] = item_widget
                local fidx = #self._focusable_items
                if entry.is_entry then
                    self._first_entry_index = self._first_entry_index or fidx
                    self._last_entry_index = fidx
                end
                if self.initial_focus and self.initial_focus.id
                        and entry.focus_id == self.initial_focus.id then
                    self._focus_target_index = fidx
                end
            end
            if entry.separator and idx < #self.items then
                list_group[#list_group + 1] = LineWidget:new{
                    background = Blitbuffer.COLOR_DARK_GRAY,
                    dimen = Geom:new{ w = entry_width, h = Size.line.thin },
                }
            else
                list_group[#list_group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
            end
        end
    end

    self.list_container = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        list_group,
    }
    self._list_group = list_group

    local prev_button = Button:new{
        icon = "chevron.left",
        icon_width = sc(24),
        icon_height = sc(24),
        width = sc(48),
        height = sc(48),
        bordersize = 0,
        background = nil,
        callback = function()
            if self.on_prev_page then
                self.on_prev_page()
            end
        end,
    }
    prev_button:enableDisable(self.page > 1)

    local page_label = TextWidget:new{
        text = string.format(_("Page %d of %d"), self.page, math.max(1, self.total_pages)),
        face = Font:getFace("NotoSerif-Regular.ttf", 18),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    
    local page_button = InputContainer:new{
        page_label,
    }
    page_button.ges_events = {
        StorefrontTap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local dim = page_button.dimen or { x = 0, y = 0, w = 0, h = 0 }
                    return Geom:new{
                        x = dim.x or 0,
                        y = dim.y or 0,
                        w = dim.w or 0,
                        h = dim.h or 0
                    }
                end,
            }
        }
    }
    page_button.onStorefrontTap = function()
        if self.total_pages <= 1 then return end
        UIManager:show(SpinWidget:new{
            title_text = _("Go to page"),
            value = self.page,
            value_min = 1,
            value_max = self.total_pages,
            ok_text = _("Go"),
            callback = function(spin)
                if self.on_goto_page then
                    self.on_goto_page(spin.value)
                end
            end,
        })
        return true
    end

    local next_button = Button:new{
        icon = "chevron.right",
        icon_width = sc(24),
        icon_height = sc(24),
        width = sc(48),
        height = sc(48),
        bordersize = 0,
        background = nil,
        callback = function()
            if self.on_next_page then
                self.on_next_page()
            end
        end,
    }
    next_button:enableDisable(self.page < self.total_pages)

    local footer_group = HorizontalGroup:new{
        prev_button,
        HorizontalSpan:new{ width = sc(24) },
        page_button,
        HorizontalSpan:new{ width = sc(24) },
        next_button,
    }

    local CenterContainer = require("ui/widget/container/centercontainer")
    self.footer = FrameContainer:new{
        padding_top = sc(4),
        padding_bottom = sc(4),
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = sc(48) },
            footer_group,
        }
    }

    local toolbar_height = 0
    if self.toolbar_buttons and #self.toolbar_buttons > 0 then
        local tb = HorizontalGroup:new{}
        self._toolbar_widgets = {}
        self._toolbar_ids = {}
        for i, spec in ipairs(self.toolbar_buttons) do
            if i > 1 then
                table.insert(tb, HorizontalSpan:new{ width = sc(4) })
                table.insert(tb, TextWidget:new{
                    text = "·",
                    face = Font:getFace("cfont", 14),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                })
                table.insert(tb, HorizontalSpan:new{ width = sc(4) })
            end
            local btn = Button:new{
                text = spec.text,
                text_font_size = 14,
                padding = sc(8),
                radius = sc(16),
                bordersize = sc(1),
                background = Blitbuffer.COLOR_WHITE,
                callback = spec.callback,
                show_parent = self,
            }
            table.insert(tb, btn)
            self._toolbar_widgets[#self._toolbar_widgets + 1] = btn
            self._toolbar_ids[#self._toolbar_ids + 1] = { id = spec.id }
        end
        self.toolbar = FrameContainer:new{
            padding_left = sc(12),
            padding_right = sc(12),
            padding_top = sc(4),
            padding_bottom = sc(4),
            bordersize = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width - sc(24), h = tb:getSize().h },
                tb,
            },
        }
        toolbar_height = self.toolbar:getSize().h + Size.span.vertical_default
    end

    local tab_bar = self:buildTabBar()
    local title_height = self.header:getSize().h
    local tab_bar_height = tab_bar:getSize().h
    local footer_height = self.footer:getSize().h
    
    local divider_height = Size.line.thin + Size.span.vertical_default
    if self.toolbar then
        divider_height = divider_height + Size.line.thin + Size.span.vertical_default
    end
    local body_height = self.screen_h - title_height - tab_bar_height - footer_height - toolbar_height - divider_height
    if body_height < math.floor(self.screen_h * 0.5) then
        body_height = math.floor(self.screen_h * 0.5)
    end

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    self.list_scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = body_height },
        bordersize = 0,
        padding = 0,
        scroll_bar_width = 0,
        self.list_container,
    }
    self.cropping_widget = self.list_scroller

    self.content = VerticalGroup:new{
        align = "left",
        self.header,
        tab_bar,
        LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = self.width, h = Size.line.thin } },
        VerticalSpan:new{ width = Size.span.vertical_default },
    }
    if self.toolbar then
        table.insert(self.content, self.toolbar)
        table.insert(self.content, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(self.content, LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = self.width, h = Size.line.thin } })
        table.insert(self.content, VerticalSpan:new{ width = Size.span.vertical_default })
    end
    table.insert(self.content, self.list_scroller)
    table.insert(self.content, self.footer)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        width = self.screen_w,
        height = self.screen_h,
        self.content,
    }

    self._prev_button = prev_button
    self._page_button = page_button
    self._next_button = next_button

    do
        local cursor_y = Size.padding.default
        for _, child in ipairs(list_group) do
            local size = child.getSize and child:getSize() or { h = 0 }
            local h = size.h or 0
            if child.isFocusable and child:isFocusable() then
                self._focusable_row_offsets[child] = { y = cursor_y, h = h }
            end
            cursor_y = cursor_y + h
        end
    end

    self.layout = {}
    table.insert(self.layout, { filter_btn, settings_btn, close_btn })
    if self.current_tab == "Updates" then
        table.insert(self.layout, { self._updates_outdated_btn, self._updates_all_btn, self._updates_check_btn })
        self._toolbar_row_index = #self.layout
    elseif self._toolbar_widgets and #self._toolbar_widgets > 0 then
        table.insert(self.layout, self._toolbar_widgets)
        self._toolbar_row_index = #self.layout
    end
    local first_list_row_index = #self.layout + 1
    self._first_list_row_index = first_list_row_index
    for _, item_widget in ipairs(self._focusable_items) do
        table.insert(self.layout, { item_widget })
    end
    local footer_row = {}
    local footer_ids = {}
    if self.page > 1 then
        table.insert(footer_row, prev_button); table.insert(footer_ids, { id = "prev" })
    end
    if self.total_pages > 1 then
        table.insert(footer_row, page_button); table.insert(footer_ids, { id = "page" })
    end
    if self.page < self.total_pages then
        table.insert(footer_row, next_button); table.insert(footer_ids, { id = "next" })
    end
    if #footer_row > 0 then
        table.insert(self.layout, footer_row)
        self._footer_row_index = #self.layout
        self._footer_buttons = footer_ids
    end

    self.selected = self:_resolveInitialFocus(first_list_row_index)

    if self.scroll_offset then
        self:setScrollOffset(self.scroll_offset)
    end

    if Device:hasDPad() and #self.layout > 0 then
        UIManager:nextTick(function()
            self:moveFocusTo(self.selected.x, self.selected.y, FocusManager.FOCUS_ONLY_ON_NT)
            self:_ensureFocusedVisible()
        end)
    end
end

function StorefrontBrowserDialog:getListEntryWidth()
    local width = self.width - 2 * Size.padding.default
    return math.max(width, 0)
end

function StorefrontBrowserDialog:onEntryActivated(entry)
    if not entry or entry.select_enabled == false then
        return
    end
    if entry.callback then
        entry.callback()
    end
end

function StorefrontBrowserDialog:onCloseWidget()
    if self.on_dismiss then
        self.on_dismiss(self:getScrollOffset())
    end
end

function StorefrontBrowserDialog:onClose()
    UIManager:close(self, "ui")
    return true
end

function StorefrontBrowserDialog:_resolveInitialFocus(first_list_row_index)
    local select_y = first_list_row_index
    if self._focus_target_index then
        select_y = first_list_row_index + self._focus_target_index - 1
    elseif self.initial_focus then
        local f = self.initial_focus
        if f.entry == "last" and self._last_entry_index then
            select_y = first_list_row_index + self._last_entry_index - 1
        elseif f.entry == "first" and self._first_entry_index then
            select_y = first_list_row_index + self._first_entry_index - 1
        elseif f.toolbar and self._toolbar_row_index then
            select_y = self._toolbar_row_index
        elseif f.footer and self._footer_row_index then
            select_y = self._footer_row_index
        end
    end
    select_y = math.min(math.max(1, select_y), #self.layout)
    local select_x = 1
    if self.initial_focus and self.initial_focus.footer and self._footer_buttons then
        for idx, btn in ipairs(self._footer_buttons) do
            if btn.id == self.initial_focus.footer then
                select_x = idx
                break
            end
        end
    end
    local row = self.layout[select_y] or {}
    select_x = math.min(math.max(1, select_x), #row)
    return { x = select_x, y = select_y }
end

function StorefrontBrowserDialog:_footerColumnOf(id)
    if not self._footer_buttons then return 1 end
    for idx, btn in ipairs(self._footer_buttons) do
        if btn.id == id then
            return idx
        end
    end
    return 1
end

function StorefrontBrowserDialog:_resolveFooterFocus(which, direction, first_list_row_index)
    if which == "prev" and direction == "backward" then
        if self.page == 1 and self._first_entry_index then
            return { x = 1, y = first_list_row_index + self._first_entry_index - 1 }
        end
        return { x = self:_footerColumnOf("prev"), y = self._footer_row_index }
    elseif which == "next" and direction == "forward" then
        if self.page == self.total_pages and self._last_entry_index then
            return { x = 1, y = first_list_row_index + self._last_entry_index - 1 }
        end
        return { x = self:_footerColumnOf("next"), y = self._footer_row_index }
    end
    return nil
end

function StorefrontBrowserDialog:getFocusContext()
    local sel = self.selected
    if not sel then return {} end
    if sel.y == self._footer_row_index and self._footer_buttons then
        local btn = self._footer_buttons[sel.x]
        return { kind = "footer", which = btn and btn.id }
    elseif sel.y == self._toolbar_row_index and self._toolbar_ids then
        local btn = self._toolbar_ids[sel.x]
        return { kind = "toolbar", which = btn and btn.id }
    elseif sel.y >= self._first_list_row_index then
        local list_idx = sel.y - self._first_list_row_index + 1
        local widget = self._focusable_items[list_idx]
        local entry = widget and widget.entry
        if entry and entry.is_entry then
            return { kind = "entry" }
        elseif entry and entry.focus_id then
            return { kind = "control", focus_id = entry.focus_id }
        end
    end
    return {}
end

function StorefrontBrowserDialog:onNextPage()
    if self.on_next_page then
        self.on_next_page()
    end
    return true
end

function StorefrontBrowserDialog:onPrevPage()
    if self.on_prev_page then
        self.on_prev_page()
    end
    return true
end

function StorefrontBrowserDialog:onShowMenu()
    if self.on_settings_tap then
        self.on_settings_tap()
    end
    return true
end

function StorefrontBrowserDialog:onHotkeyRefresh()
    if self.on_refresh then self.on_refresh() end
    return true
end

function StorefrontBrowserDialog:onHotkeyFilter()
    if self.on_filter then self.on_filter() end
    return true
end

function StorefrontBrowserDialog:onHotkeySort()
    if self.on_sort then self.on_sort() end
    return true
end

function StorefrontBrowserDialog:onHotkeySwitchTab()
    if self.on_tab_switch then
        local next_tab = "Plugins"
        if self.current_tab == "Plugins" then next_tab = "Patches"
        elseif self.current_tab == "Patches" then next_tab = "Updates" end
        self.on_tab_switch(next_tab)
    end
    return true
end

function StorefrontBrowserDialog:_ensureFocusedVisible()
end

function StorefrontBrowserDialog:onFocusMove(args)
    FocusManager.onFocusMove(self, args)
    return true
end

function StorefrontBrowserDialog:getScrollOffset()
    return nil
end

function StorefrontBrowserDialog:setScrollOffset(offset)
end

function StorefrontBrowserDialog:resetScroll()
end

return StorefrontBrowserDialog
