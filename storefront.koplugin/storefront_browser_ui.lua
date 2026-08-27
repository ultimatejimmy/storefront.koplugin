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
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local Input = Device.input
local StorefrontListItem = require("storefront_list_item")

-- Resolves a file under this plugin's own assets/ directory, regardless of
-- where the plugin was actually installed (bundled "plugins" dir vs a custom
-- extra_plugin_paths location). IconWidget/Button's "icon" field can't do
-- this itself -- it only resolves bare names against KOReader's built-in
-- resources/icons directories, so a path like
-- "../plugins/storefront.koplugin/assets/zap" silently falls back to
-- KOReader's "icon not found" placeholder instead of raising an error.
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    local rel_path = dir .. "assets/" .. filename
    local data_dir = DataStorage:getDataDir()
    local paths_to_try = {
        rel_path,
        data_dir .. "/" .. rel_path,
        data_dir .. "/plugins/" .. rel_path,
    }
    
    local ok_paths, StorefrontPluginPaths = pcall(require, "storefront_plugin_paths")
    if ok_paths and StorefrontPluginPaths and StorefrontPluginPaths.getLookupPaths then
        for _, root in ipairs(StorefrontPluginPaths.getLookupPaths()) do
            table.insert(paths_to_try, root .. "/" .. rel_path)
        end
    end

    for _, p in ipairs(paths_to_try) do
        if ffiutil and ffiutil.realpath then
            local rp = ffiutil.realpath(p)
            if rp and lfs and lfs.attributes and lfs.attributes(rp, "mode") == "file" then
                _asset_path_cache[filename] = rp
                return rp
            end
        end
    end
    local fallback = data_dir .. "/plugins/" .. rel_path
    _asset_path_cache[filename] = fallback
    return fallback
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
    active_search_text = "",
    on_clear_search = nil,
    show_filter_bar_plugins = false,
    show_filter_bar_patches = false,
    show_filter_bar_fonts = false,
    show_filter_bar_screensavers = true,
    show_filter_bar_installed = true,
    on_tab_switch = nil,
    on_toggle_filter_bar = nil,
}

function StorefrontBrowserDialog:hasActiveFilters(tab)
    if not self.Storefront then
        return (self.active_search_text or "") ~= ""
    end
    return self.Storefront:hasActiveFilters(tab)
end

function StorefrontBrowserDialog:buildTabBar()
    local tabs = { "Plugins", "Patches", "Fonts", "Screensavers", "Installed", "Updates" }
    local tab_widgets = {}

    local sc = function(val) return Device.screen:scaleBySize(val) end

    local tab_label_map = {
        Plugins = _("Plugins"),
        Patches = _("Patches"),
        Fonts = _("Fonts"),
        Screensavers = _("Screensavers"),
        Installed = _("Installed"),
        Updates = _("Updates"),
    }

    local tab_icon_active_map = {
        Plugins = "package-active.svg",
        Patches = "code-active.svg",
        Fonts = "type-active.svg",
        Screensavers = "image-active.svg",
        Installed = "tab-installed-active.svg",
        Updates = "refresh-cw-active.svg",
    }

    local tab_icon_inactive_map = {
        Plugins = "package.svg",
        Patches = "code.svg",
        Fonts = "type.svg",
        Screensavers = "image.svg",
        Installed = "tab-installed.svg",
        Updates = "refresh-cw.svg",
    }

    local num_tabs = #tabs
    local tab_gap = sc(6)

    local font_size = 18
    local font_face = Font:getFace("smallinfofont", font_size)

    for i, tab_name in ipairs(tabs) do
        if i > 1 then
            table.insert(tab_widgets, HorizontalSpan:new{ width = tab_gap })
        end

        local is_active = (self.current_tab == tab_name)
        local tab_elements = {}

        if tab_name == "Updates" then
            local label = TextWidget:new{
                text = tab_label_map[tab_name] or tab_name,
                face = font_face,
                bold = is_active,
                fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(80),
            }
            table.insert(tab_elements, label)

            if self.updates_count > 0 then
                local badge_inner = TextWidget:new{
                    text = tostring(self.updates_count),
                    face = Font:getFace("smallinfofont", 12),
                    bold = true,
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
        else
            local icon_file = is_active and (tab_icon_active_map[tab_name] or tab_icon_inactive_map[tab_name]) or (tab_icon_inactive_map[tab_name] or tab_icon_active_map[tab_name])
            local icon_widget = ImageWidget:new{
                file = getAssetPath(icon_file),
                width = sc(22),
                height = sc(22),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }
            table.insert(tab_elements, icon_widget)

            if is_active then
                local label = TextWidget:new{
                    text = tab_label_map[tab_name] or tab_name,
                    face = font_face,
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                table.insert(tab_elements, HorizontalSpan:new{ width = sc(6) })
                table.insert(tab_elements, label)
            end
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

        local tab_frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = 0,
            padding_left = (i == 1) and sc(10) or sc(8),
            padding_right = sc(8),
            bordersize = 0,
            tab_group,
        }

        local tab_btn = InputContainer:new{
            tab_frame,
        }
        tab_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = tab_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        local x = dim.x or 0
                        local y = dim.y or 0
                        local w = dim.w or 0
                        local h = dim.h or 0
                        if i == 1 then
                            -- Extend first tab hit area all the way to the left bezel
                            w = w + x
                            x = 0
                        end
                        return Geom:new{
                            x = x,
                            y = y,
                            w = w,
                            h = h,
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
    local frame_content = tab_bar_group

    if self.current_tab == "Plugins" or self.current_tab == "Patches" or self.current_tab == "Fonts" or self.current_tab == "Screensavers" or self.current_tab == "Installed" then
        local has_active_filters = false
        if type(self.hasActiveFilters) == "function" then
            has_active_filters = self:hasActiveFilters(self.current_tab)
        end

        local filter_icon = ImageWidget:new{
            file = getAssetPath("filter.svg"),
            width = sc(20),
            height = sc(20),
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }

        local icon_elements = { filter_icon }
        if has_active_filters then
            local badge_dot = FrameContainer:new{
                padding = sc(3),
                bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                radius = sc(3),
                VerticalSpan:new{ width = 0 },
            }
            table.insert(icon_elements, HorizontalSpan:new{ width = sc(3) })
            table.insert(icon_elements, badge_dot)
        end

        local filter_btn_content = HorizontalGroup:new(icon_elements)
        local filter_btn = InputContainer:new{
            FrameContainer:new{
                padding = sc(4),
                padding_left = sc(6),
                padding_right = sc(6),
                bordersize = 0,
                filter_btn_content,
            }
        }
        filter_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = filter_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
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
        filter_btn.onTap = function()
            if self.on_toggle_filter_bar then
                self.on_toggle_filter_bar(self.current_tab)
            end
            return true
        end

        local right_container = RightContainer:new{
            dimen = Geom:new{ w = self.width - sc(24), h = tab_bar_group:getSize().h },
            filter_btn,
        }

        frame_content = OverlapGroup:new{
            tab_bar_group,
            right_container,
        }
    end

    return FrameContainer:new{
        padding_top = sc(12),
        padding_left = sc(12),
        padding_right = sc(12),
        padding_bottom = 0,
        bordersize = 0,
        frame_content,
    }
end

-- Build an off-screen dialog with the same chrome as the browser and return
-- the exact vertical space available to list content.  Pagination is decided
-- before the real dialog is created, so keeping this measurement here avoids
-- mirroring the header, tab bar, toolbar, footer, and spacer geometry in the
-- controller.
local _viewport_measurement_cache = {}

function StorefrontBrowserDialog:measureListViewport(options)
    options = options or {}
    local screen_w = Device.screen:getWidth()
    local screen_h = Device.screen:getHeight()
    local has_toolbar = (options.toolbar_buttons and #options.toolbar_buttons > 0) == true
    local cache_key = string.format("%dx%d|tb:%s",
        screen_w, screen_h,
        tostring(has_toolbar)
    )

    if _viewport_measurement_cache[cache_key] then
        local c = _viewport_measurement_cache[cache_key]
        return c[1], c[2]
    end

    local probe = StorefrontBrowserDialog:new{
        title = options.title or _("Storefront"),
        items = {},
        page = 1,
        total_pages = 1,
        toolbar_buttons = options.toolbar_buttons,
        current_tab = options.current_tab or "Plugins",
        updates_count = options.updates_count or 0,
        show_filter_bar_plugins = options.show_filter_bar_plugins == true,
        show_filter_bar_patches = options.show_filter_bar_patches == true,
        show_filter_bar_fonts = options.show_filter_bar_fonts == true,
        show_filter_bar_screensavers = options.show_filter_bar_screensavers ~= false,
        show_filter_bar_installed = options.show_filter_bar_installed ~= false,
        is_probe = true,
    }
    -- KOReader's Widget:new initializes instances, while the lightweight
    -- headless test doubles do not.
    if not probe.list_scroller then
        probe:init()
    end
    local viewport_h = probe.list_scroller:getSize().h
    local viewport_w = probe:getListEntryWidth()
    local res_h = math.max(1, viewport_h - 2 * Size.padding.default)
    local res_w = math.max(1, viewport_w)
    _viewport_measurement_cache[cache_key] = { res_h, res_w }
    return res_h, res_w
end

function StorefrontBrowserDialog:init()
    if not self.is_probe then
        local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")
        if ok_ratings and StorefrontRatings and StorefrontRatings.fetchRatings then
            StorefrontRatings.fetchRatings()
        end
    end

    self.show_parent = self
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    self.key_events = self.key_events or {}
    self.key_events.NextPage = {
        { Input.group.PgFwd },
        { "Right" },
        { "PageDown" },
        { "Down" },
    }
    self.key_events.PrevPage = {
        { Input.group.PgBack },
        { "Left" },
        { "PageUp" },
        { "Up" },
    }
    -- Disable FocusManager D-Pad horizontal movement so Left/Right arrow keys trigger PrevPage/NextPage
    self.key_events.FocusRight = nil
    self.key_events.FocusLeft = nil

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.ShowMenu = { { "Menu" } }
    end
    if Device:hasKeyboard() then
        self.key_events.HotkeyRefresh = { { "R" } }
        self.key_events.HotkeyFilter = { { "F" } }
        self.key_events.HotkeySort = { { "S" } }
        self.key_events.HotkeySwitchTab = { { "T" } }
    end

    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        }
    }

    local storefront_theme = require("storefront_theme")
    local sc = function(val) return Device.screen:scaleBySize(val) end

    local zap_icon = ImageWidget:new{
        file = getAssetPath("zap.svg"),
        width = sc(24),
        height = sc(24),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local title_label = TextWidget:new{
        text = self.title or _("Storefront"),
        face = Font:getFace("NotoSerif-Regular.ttf", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local btn_w = sc(48)
    local btn_h = sc(48)

    local search_btn = Button:new{
        icon = "appbar.search",
        width = btn_w,
        height = btn_h,
        bordersize = 0,
        background = nil,
        callback = function()
            if self.current_tab == "Updates" then
                return
            end
            if self.on_search then
                self.on_search()
            elseif self.on_filter then
                self.on_filter()
            end
        end,
    }

    local settings_btn = Button:new{
        icon = "appbar.settings",
        width = btn_w,
        height = btn_h,
        bordersize = 0,
        background = nil,
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
        bordersize = 0,
        background = nil,
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
        search_btn,
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

    self._header_search_btn = search_btn
    self._header_filter_btn = search_btn
    self._header_settings_btn = settings_btn
    self._close_btn = close_btn

    self._focusable_items = {}
    self._focusable_row_offsets = {}

    local list_group = VerticalGroup:new{}
    local entry_width = self:getListEntryWidth()
    local total_items = self.items and #self.items or 0

    if self.items then
        -- Screensaver tab: render a 3-column portrait-thumbnail grid
        if #self.items == 1 and self.items[1].is_screensaver_grid then
            local grid_widget = self.items[1].grid_widget
            if grid_widget then
                list_group[#list_group + 1] = grid_widget
            end
            if self.items[1].cards then
                for _, card in ipairs(self.items[1].cards) do
                    self._focusable_items[#self._focusable_items + 1] = card
                end
            end
        else
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
            if entry.separator then
                if idx < #self.items then
                    list_group[#list_group + 1] = LineWidget:new{
                        background = Blitbuffer.COLOR_DARK_GRAY,
                        dimen = Geom:new{ w = entry_width, h = Size.line.thin },
                    }
                end
            elseif idx < #self.items then
                list_group[#list_group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
            end
        end
        end -- end else (non-grid)
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
        allow_flash = false,
        callback = function()
            if self.on_prev_page then
                self.on_prev_page()
            end
        end,
    }
    prev_button:enableDisable(self.page > 1)

    local page_label = TextWidget:new{
        text = string.format(_("Page %d of %d"), self.page, math.max(1, self.total_pages)),
        face = Font:getFace("cfont", 18),
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
        allow_flash = false,
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
        -- Split buttons into left and right groups (right_align = true goes to the right side)
        local left_specs, right_specs = {}, {}
        for _, spec in ipairs(self.toolbar_buttons) do
            if spec.right_align then
                table.insert(right_specs, spec)
            else
                table.insert(left_specs, spec)
            end
        end
        local has_split = #left_specs > 0 and #right_specs > 0

        local function buildButtonGroup(specs, force_primary)
            local grp = HorizontalGroup:new{}
            local widgets = {}
            for i, spec in ipairs(specs) do
                if i > 1 then
                    table.insert(grp, HorizontalSpan:new{ width = sc(4) })
                    table.insert(grp, TextWidget:new{
                        text = _("\xC2\xB7"),
                        face = Font:getFace("NotoSerif-Regular.ttf", 14),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    })
                    table.insert(grp, HorizontalSpan:new{ width = sc(4) })
                end
                local use_primary = spec.is_primary or force_primary
                local btn = Button:new{
                    text           = spec.text,
                    text_font_size = 14,
                    text_font_bold = spec.text_font_bold or use_primary or false,
                    padding        = sc(3),
                    padding_h      = sc(6),
                    radius         = use_primary and sc(10) or sc(16),
                    bordersize     = use_primary and 0 or sc(1),
                    background     = use_primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    allow_flash    = false,
                    callback       = spec.callback,
                    show_parent    = self,
                }
                if use_primary and btn.label_widget then
                    btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
                end
                table.insert(grp, btn)
                table.insert(widgets, { btn = btn, id = spec.id })
            end
            return grp, widgets
        end

        self._toolbar_widgets = {}
        self._toolbar_ids = {}

        local tb
        if has_split then
            local left_grp, left_w = buildButtonGroup(left_specs, false)
            local right_grp, right_w = buildButtonGroup(right_specs, false)
            for _, w in ipairs(left_w) do
                self._toolbar_widgets[#self._toolbar_widgets + 1] = w.btn
                self._toolbar_ids[#self._toolbar_ids + 1] = { id = w.id }
            end
            for _, w in ipairs(right_w) do
                self._toolbar_widgets[#self._toolbar_widgets + 1] = w.btn
                self._toolbar_ids[#self._toolbar_ids + 1] = { id = w.id }
            end
            local inner_w = self.width - sc(24)
            local left_sz = left_grp:getSize().w
            local right_sz = right_grp:getSize().w
            local spacer_w = math.max(sc(8), inner_w - left_sz - right_sz)
            tb = HorizontalGroup:new{
                left_grp,
                HorizontalSpan:new{ width = spacer_w },
                right_grp,
            }
        else
            -- No split: centered layout (original behavior)
            local all_grp, all_w = buildButtonGroup(self.toolbar_buttons, false)
            for _, w in ipairs(all_w) do
                self._toolbar_widgets[#self._toolbar_widgets + 1] = w.btn
                self._toolbar_ids[#self._toolbar_ids + 1] = { id = w.id }
            end
            tb = all_grp
        end

        self.toolbar = FrameContainer:new{
            padding_left   = sc(12),
            padding_right  = sc(12),
            padding_top    = sc(2),
            padding_bottom = sc(2),
            bordersize     = 0,
            has_split and tb or CenterContainer:new{
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
        ignore_events = { "swipe", "key_pg_back", "key_pg_fwd" },
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
    if self._toolbar_widgets and #self._toolbar_widgets > 0 then
        table.insert(self.layout, self._toolbar_widgets)
        self._toolbar_row_index = #self.layout
    end
    local first_list_row_index = #self.layout + 1
    self._first_list_row_index = first_list_row_index
    if self.items and #self.items == 1 and self.items[1].is_screensaver_grid and self.items[1].grid_rows then
        for _, row_cards in ipairs(self.items[1].grid_rows) do
            table.insert(self.layout, row_cards)
        end
    else
        for _, item_widget in ipairs(self._focusable_items) do
            table.insert(self.layout, { item_widget })
        end
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

function StorefrontBrowserDialog:onSwipe(arg, ges_ev)
    local ev = (type(arg) == "table" and arg) or (type(ges_ev) == "table" and ges_ev)
    local direction = ev and ev.direction
    if direction == "left" or direction == "west" then
        return self:onNextPage()
    elseif direction == "right" or direction == "east" then
        return self:onPrevPage()
    end
    return false
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
