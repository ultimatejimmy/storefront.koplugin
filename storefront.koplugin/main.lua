local Localization = require("localization_storefront")
local R = {
    Device = require("device"),
    DataStorage = require("datastorage"),
    LuaSettings = require("luasettings"),
    UIManager = require("ui/uimanager"),
    WidgetContainer = require("ui/widget/container/widgetcontainer"),
    InputContainer = require("ui/widget/container/inputcontainer"),
    FocusManager = require("ui/widget/focusmanager"),
    ScrollableContainer = require("ui/widget/container/scrollablecontainer"),
    Geom = require("ui/geometry"),
    GestureRange = require("ui/gesturerange"),
    TitleBar = require("ui/widget/titlebar"),
    Button = require("ui/widget/button"),
    HorizontalGroup = require("ui/widget/horizontalgroup"),
    HorizontalSpan = require("ui/widget/horizontalspan"),
    VerticalSpan = require("ui/widget/verticalspan"),
    LineWidget = require("ui/widget/linewidget"),
    Size = require("ui/size"),
    Blitbuffer = require("ffi/blitbuffer"),
    ConfirmBox = require("ui/widget/confirmbox"),
    InfoMessage = require("ui/widget/infomessage"),
    TextViewer = require("ui/widget/textviewer"),
    TextWidget = require("ui/widget/textwidget"),
    TextBoxWidget = require("ui/widget/textboxwidget"),
    MultiInputDialog = require("ui/widget/multiinputdialog"),
    CheckButton = require("ui/widget/checkbutton"),
    ButtonDialog = require("ui/widget/buttondialog"),
    SpinWidget = require("ui/widget/spinwidget"),
    Font = require("ui/font"),
    Dispatcher = require("dispatcher"),
    InputDialog = require("ui/widget/inputdialog"),
    VerticalGroup = require("ui/widget/verticalgroup"),
    FrameContainer = require("ui/widget/container/framecontainer"),
    CenterContainer = require("ui/widget/container/centercontainer"),
    RightContainer = require("ui/widget/container/rightcontainer"),
    OverlapGroup = require("ui/widget/overlapgroup"),
    Localization = Localization,
    _ = function(key, ...) return Localization:t(key, ...) end,
    Cache = require("storefront_cache"),
    GitHub = require("storefront_net_github"),
    RepoContent = require("storefront_repo_content"),
    InstallStore = require("storefront_installs"),
    util = require("util"),
    NetworkMgr = require("ui/network/manager"),
    socketutil = require("socketutil"),
    socket = require("socket"),
    http = require("socket.http"),
    ltn12 = require("ltn12"),
    Archiver = require("ffi/archiver"),
    sha2 = require("ffi/sha2"),
    lfs = require("libs/libkoreader-lfs"),
    json = require("json"),
    logger = require("logger"),
    StorefrontListItem = require("storefront_list_item"),
    StorefrontLogger = require("storefront_logger"),
}
R.Input = R.Device.input

local StorefrontUtils = require("storefront_utils")
R.StorefrontUtils = StorefrontUtils
local Archiver = require("ffi/archiver")

local softWrapLongTokens = StorefrontUtils.softWrapLongTokens
local normalizeMetaPath = StorefrontUtils.normalizeMetaPath
local sanitizeMetaPath = StorefrontUtils.sanitizeMetaPath
local firstNonEmpty = StorefrontUtils.firstNonEmpty
local isVersionNewer = StorefrontUtils.isVersionNewer
local normalizeDescription = StorefrontUtils.normalizeDescription
local parseGitHubTimestamp = StorefrontUtils.parseGitHubTimestamp
local repoStarsValue = StorefrontUtils.repoStarsValue
local repoIsFork = StorefrontUtils.repoIsFork

local env = setmetatable({}, { __index = _G })
for k, v in pairs(R) do
    env[k] = v
end
setfenv(1, env)

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)

local IGNORED_RELEASES_KEY = "ignored_releases"

local STALE_WARNING_SECONDS = 7 * 24 * 3600
local DEFAULT_BROWSER_PAGE_SIZE = 5
local MIN_BROWSER_PAGE_SIZE = 4
local MAX_BROWSER_PAGE_SIZE = 100
-- Installed/manage lists hold taller multi-line entries (name + version +
-- update status), so they get their own page-size setting, defaulting smaller
-- than the compact available-browser list.
local DEFAULT_MANAGE_PAGE_SIZE = 5
local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin"' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches"' }
local BROWSER_STATE_KEY = "browser_state"
local BROWSER_PAGE_SIZE_KEY = "browser_page_size"
local MANAGE_PAGE_SIZE_KEY = "manage_page_size"
local INCLUDE_ZERO_STAR_FORKS_KEY = "include_zero_star_forks"
local PATCH_CACHE_TTL = 10 * 60
local MIN_CATALOG_CHECK_INTERVAL = 300
local DEFAULT_SORT_MODE = "stars_desc"

local PluginPaths = require("storefront_plugin_paths")
local PATCHES_ROOT = DataStorage:getDataDir() .. "/patches"

local Storefront = WidgetContainer:extend{
    name = "storefront",
    is_doc_only = false,
    is_refreshing = false,
    browser_state = nil,
    browser_menu = nil,
    patch_cache = {},
    updates_state = nil,
    updates_menu = nil,
    patch_updates_state = nil,
    patch_updates_menu = nil,
    match_context = nil,
    pending_install_context = nil,
    pending_patch_install = nil,
    readme_filter = nil,
}

require("storefront_updates_ui"):init(Storefront)
require("storefront_font_mgr"):init(Storefront)
require("storefront_installer"):init(Storefront)
require("storefront_delete_ui"):init(Storefront)
require("storefront_match"):init(Storefront)
require("storefront_search_net"):init(Storefront)
require("storefront_updates_mgr"):init(Storefront)
local storefront_patch_mgr = require("storefront_patch_mgr")
storefront_patch_mgr:init(Storefront)




-- Filter KOReader's FontList:getFontNames() so preview asset files in
-- storefront.koplugin/assets/ never bleed into the reader's Book Font Settings Menu.
local ok_fl, FontList = pcall(require, "fontlist")
if ok_fl and FontList and not FontList._storefront_filter_installed then
    FontList._storefront_filter_installed = true
    local orig_getFontNames = FontList.getFontNames
    if type(orig_getFontNames) == "function" then
        FontList.getFontNames = function(self, ...)
            local names = orig_getFontNames(self, ...)
            if type(names) == "table" and self.fontinfo then
                for family in pairs(names) do
                    local is_only_asset = true
                    for path, info in pairs(self.fontinfo) do
                        if info and info.family == family then
                            if not path:find("storefront.koplugin", 1, true) then
                                is_only_asset = false
                                break
                            end
                        end
                    end
                    if is_only_asset then
                        names[family] = nil
                    end
                end
            end
            return names
        end
    end

    local orig_saveFontList = FontList.saveFontList
    if type(orig_saveFontList) == "function" then
        FontList.saveFontList = function(self, ...)
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.attributes then
                if self.fontinfo then
                    for path in pairs(self.fontinfo) do
                        if path:find("storefront.koplugin", 1, true) or lfs.attributes(path, "mode") ~= "file" then
                            self.fontinfo[path] = nil
                        end
                    end
                end
                if self.fontlist then
                    for i = #self.fontlist, 1, -1 do
                        local path = self.fontlist[i]
                        if path:find("storefront.koplugin", 1, true) or lfs.attributes(path, "mode") ~= "file" then
                            table.remove(self.fontlist, i)
                        end
                    end
                end
                if self.fontnames and self.fontinfo then
                    local valid_families = {}
                    for path, info in pairs(self.fontinfo) do
                        if info and info.family then
                            valid_families[info.family] = true
                        end
                    end
                    for family in pairs(self.fontnames) do
                        if not valid_families[family] then
                            self.fontnames[family] = nil
                        end
                    end
                end
            end
            return orig_saveFontList(self, ...)
        end
    end
end

local StorefrontListItem = require("storefront_list_item")
local StorefrontBrowserDialog = require("storefront_browser_ui")

local function getBrowserPageSize()
    local v = StorefrontSettings:readSetting(BROWSER_PAGE_SIZE_KEY)
    if type(v) == "number" and v >= MIN_BROWSER_PAGE_SIZE then
        return math.min(math.floor(v), MAX_BROWSER_PAGE_SIZE)
    end
    return DEFAULT_BROWSER_PAGE_SIZE
end

local function getManagePageSize()
    local v = StorefrontSettings:readSetting(MANAGE_PAGE_SIZE_KEY)
    if type(v) == "number" and v >= MIN_BROWSER_PAGE_SIZE then
        return math.min(math.floor(v), MAX_BROWSER_PAGE_SIZE)
    end
    return DEFAULT_MANAGE_PAGE_SIZE
end

local function showRestartConfirmation(message, force)
    if _G.G_storefront_batch_updating and not force then
        return
    end

    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local Button = package.loaded["ui/widget/button"] or require("ui/widget/button")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local Geom = require("ui/geometry")
    local UIManager = require("ui/uimanager")
    local _ = function(key, ...)
        local loc = package.loaded["localization_storefront"] or require("localization_storefront")
        return loc:t(key, ...)
    end
    local sc = function(val) return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local card_padding = sc(12)
    local card_border = storefront_theme.border_window or sc(2)
    local dialog_w = math.min(sw - sc(20), sc(380))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size  = storefront_theme.face_label_size or 18

    local body_text = string.format("%s\n\n%s", message or "", _("This will take effect on next restart."))

    local body_widget = TextBoxWidget:new{
        text = body_text,
        face = Font:getFace("cfont", ui_font_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local overlay

    local cancel_text = _("Restart later")
    local ok_text = _("Restart now")
    local btn_texts = { cancel_text, ok_text }

    local btn_gap = sc(8)
    local padding_per_btn = sc(12)

    local function getTextWidth(text, sz)
        sz = sz or 16
        local face = Font:getFace("cfont", sz)
        if face and type(face.getLineWidth) == "function" then
            local ok_lw, w = pcall(function() return face:getLineWidth(text) end)
            if ok_lw and type(w) == "number" and w > 0 then
                return w
            end
        end
        local ok_tw, tw = pcall(function()
            return TextWidget:new{
                text = text or "",
                face = face,
                bold = true,
            }
        end)
        if ok_tw and tw and type(tw.getSize) == "function" then
            local ok_sz, sz_res = pcall(function() return tw:getSize() end)
            if ok_sz and sz_res and type(sz_res.w) == "number" then
                return sz_res.w
            end
        end
        local char_count = select(2, (text or ""):gsub("[%z\1-\127\194-\244][\128-\191]*", ""))
        if char_count == 0 then char_count = #(text or "") end
        return math.floor(char_count * sz * 0.6)
    end

    local function calcRestartBtnFontSize(texts, total_avail_width, gap, padding_per_item)
        local num = #texts
        if num == 0 then return 18 end
        local gaps_total = gap * math.max(0, num - 1)
        for _, sz in ipairs({ 18, 17, 16, 15, 14, 13, 12, 11, 10 }) do
            local total_w = gaps_total
            for _, text in ipairs(texts) do
                total_w = total_w + getTextWidth(text, sz) + padding_per_item
            end
            if total_w <= total_avail_width then
                return sz
            end
        end
        return 10
    end

    local function calcProportionalWidths(button_texts, total_avail_width, gap, font_size, padding_per_item)
        local num_btns = #button_texts
        if num_btns == 0 then return {} end
        if num_btns == 1 then return { total_avail_width } end

        local usable_width = total_avail_width - gap * (num_btns - 1)
        local ideal_widths = {}
        local total_ideal = 0
        local sz = font_size or 16

        for i, text in ipairs(button_texts) do
            local ideal = getTextWidth(text, sz) + padding_per_item
            ideal_widths[i] = ideal
            total_ideal = total_ideal + ideal
        end

        local widths = {}
        local sum = 0
        for i = 1, num_btns do
            if i == num_btns then
                widths[i] = usable_width - sum
            else
                local w = math.floor(usable_width * (ideal_widths[i] / total_ideal))
                widths[i] = w
                sum = sum + w
            end
        end
        return widths
    end

    local btn_font_size = calcRestartBtnFontSize(btn_texts, inner_w, btn_gap, padding_per_btn)
    local btn_widths = calcProportionalWidths(btn_texts, inner_w, btn_gap, btn_font_size, padding_per_btn)
    local btn_h = sc(58)

    local cancel_btn = Button:new{
        text = cancel_text,
        text_font_size = btn_font_size,
        text_font_bold = true,
        bordersize = sc(1),
        border_color = Blitbuffer.COLOR_BLACK,
        radius = storefront_theme.radius_btn or sc(4),
        padding = 0,
        height = btn_h,
        width = btn_widths[1],
        callback = function()
            if overlay then UIManager:close(overlay, "ui") end
        end,
    }

    local ok_btn = Button:new{
        text = ok_text,
        text_font_size = btn_font_size,
        text_font_bold = true,
        text_font_color = Blitbuffer.COLOR_WHITE,
        fgcolor = Blitbuffer.COLOR_WHITE,
        background = Blitbuffer.COLOR_BLACK,
        bordersize = sc(1),
        border_color = Blitbuffer.COLOR_BLACK,
        radius = storefront_theme.radius_btn or sc(4),
        padding = 0,
        height = btn_h,
        width = btn_widths[2],
        callback = function()
            if overlay then UIManager:close(overlay, "ui") end
            UIManager:restartKOReader()
        end,
    }
    if ok_btn.label_widget then
        ok_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    local btn_row = HorizontalGroup:new{
        align = "center",
        cancel_btn,
        HorizontalSpan:new{ width = btn_gap },
        ok_btn,
    }

    local content_vg = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sc(14) },
        FrameContainer:new{ padding = 0, bordersize = 0, body_widget },
        VerticalSpan:new{ width = sc(14) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        VerticalSpan:new{ width = sc(14) },
        FrameContainer:new{ padding = 0, bordersize = 0, btn_row },
        VerticalSpan:new{ width = sc(8) },
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
        dimen = Geom:new{ w = sw, h = sh },
        key_events = { Close = { { "Back" } } },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        },
    }

    cancel_btn.show_parent = overlay
    ok_btn.show_parent     = overlay

    overlay.onClose = function()
        UIManager:close(overlay, "ui")
        return true
    end

    UIManager:show(overlay, "ui")
end

function Storefront:showConfirmDialog(opts)
    opts = opts or {}
    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local sc = function(val) return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local card_padding = sc(12)
    local card_border = storefront_theme.border_window or sc(2)
    local dialog_w = math.min(sw - sc(20), sc(380))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local overlay
    local StorefrontUtils = require("storefront_utils")

    local title_text = opts.title or _("Confirm Update")
    local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(title_text, inner_w, "cfont", title_font_size, 12, true)
    local title_label = TextBoxWidget:new{
        text = title_text,
        face = Font:getFace("cfont", dynamic_title_size),
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

    local body_widget = TextBoxWidget:new{
        text = opts.text or "",
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

    local btn_gap = sc(12)
    local cancel_text = opts.cancel_text or _("Cancel")
    local ok_text = opts.ok_text or _("Update All")
    local btn_font_size = StorefrontUtils.calcGroupFontSize({ cancel_text, ok_text }, inner_w, btn_gap, "cfont", sc(16), 18, 10)
    local btn_widths = StorefrontUtils.calcProportionalBtnWidths({ cancel_text, ok_text }, inner_w, btn_gap, btn_font_size, "cfont")

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
            if overlay then UIManager:close(overlay, "ui") end
            if opts.cancel_callback then opts.cancel_callback() end
        end,
    }

    local ok_btn = StorefrontUtils.createButton{
        text = ok_text,
        text_font_size = btn_font_size,
        bold = true,
        bordersize = storefront_theme.border_btn or sc(1),
        radius = storefront_theme.radius_btn or sc(4),
        width = btn_widths[2],
        height = sc(38),
        background = Blitbuffer.COLOR_BLACK,
        text_font_color = Blitbuffer.COLOR_WHITE,
        callback = function()
            if overlay then UIManager:close(overlay, "ui") end
            if opts.ok_callback then opts.ok_callback() end
        end,
    }

    local btn_row = HorizontalGroup:new{
        align = "center",
        cancel_btn,
        HorizontalSpan:new{ width = btn_gap },
        ok_btn,
    }

    local content_vg = VerticalGroup:new{
        align = "center",
        title_container,
        VerticalSpan:new{ width = sc(10) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = sc(14) },
        body_container,
        VerticalSpan:new{ width = sc(16) },
        FrameContainer:new{ padding = 0, bordersize = 0, btn_row },
        VerticalSpan:new{ width = sc(8) },
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

    cancel_btn.show_parent = overlay
    ok_btn.show_parent = overlay

    overlay.onClose = function()
        UIManager:close(overlay, "ui")
        if opts.cancel_callback then opts.cancel_callback() end
        return true
    end

    UIManager:show(overlay, "ui")
end

local function showFetchingProgress(message)
    if G_storefront_batch_updating then
        return {
            close = function() end
        }
    end
    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local sc = function(val) return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(360))
    local card_padding = sc(6)
    local card_border = storefront_theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22
    local progress_title = _("progress_please_wait")
    local StorefrontUtils = require("storefront_utils")
    local dynamic_title_size = StorefrontUtils.calcDynamicFontSize(progress_title, inner_w, "NotoSerif-Regular.ttf", title_font_size, 12, true)

    local title_label = TextBoxWidget:new{
        text = progress_title,
        face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local title_container = FrameContainer:new{
        padding = sc(12),
        bordersize = 0,
        title_label,
    }

    local body_widget = TextBoxWidget:new{
        text = message or _("Connecting to GitHub…\n\nPlease wait."),
        face = Font:getFace("NotoSerif-Regular.ttf", ui_font_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = dialog_w - sc(40),
        alignment = "center",
    }

    local body_container = FrameContainer:new{
        padding = sc(16),
        bordersize = 0,
        body_widget,
    }

    local card_padding = sc(6)
    local card_border = storefront_theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local content_vg = VerticalGroup:new{
        align = "center",
        title_container,
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = sc(8) },
        body_container,
        VerticalSpan:new{ width = sc(8) },
    }

    local card = FrameContainer:new{
        padding = sc(6),
        radius = storefront_theme.radius_window or 0,
        bordersize = storefront_theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        content_vg,
    }

    local overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        },
    }

    UIManager:show(overlay, "ui")
    UIManager:forceRePaint()

    return {
        close = function()
            UIManager:close(overlay, "ui")
        end
    }
end

function Storefront:showRestartConfirmation(message)
    return showRestartConfirmation(message, true)
end

function Storefront:showFetchingProgress(message)
    return showFetchingProgress(message)
end


local function getIgnoredReleases()
    return StorefrontSettings:readSetting(IGNORED_RELEASES_KEY) or {}
end

local function saveIgnoredReleases(ignored_releases)
    StorefrontSettings:saveSetting(IGNORED_RELEASES_KEY, ignored_releases)
    StorefrontSettings:flush()
end

local function ignoreRelease(owner, repo_name, version)
    if not owner or not repo_name or not version then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    ignored[key] = version
    saveIgnoredReleases(ignored)
end

local function clearIgnoredRelease(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    if ignored[key] then
        ignored[key] = nil
        saveIgnoredReleases(ignored)
    end
end

local function getIgnoredVersion(owner, repo_name)
    if not owner or not repo_name then
        return nil
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    return ignored[key]
end

local function isReleaseIgnored(owner, repo_name, version)
    local ignored_version = getIgnoredVersion(owner, repo_name)
    return ignored_version == version
end


local extractRepoOwner, ensureCacheDir, ensurePatchesDir, downloadToFile, buildPatchDownloadUrl, derivePluginRepoPath, fetchGitHubRaw, formatTimestamp, buildRepoDescriptorFromRecord, buildBranchCandidates, getRepoDefaultBranch, extractMetaField, getInstallRecordsMap, getPatchRecordsMap, listInstalledPatches, buildPatchRecordFields, buildPatchSummary, extractPluginToUserDir, extractReleaseNameFallback, detectPluginFromArchiveWithFallback, renderReleaseNotesText

getPatchRecordsMap = storefront_patch_mgr.getPatchRecordsMap
listInstalledPatches = storefront_patch_mgr.listInstalledPatches
buildPatchRecordFields = storefront_patch_mgr.buildPatchRecordFields
buildPatchSummary = storefront_patch_mgr.buildPatchSummary


local function buildPatchRepoDescriptor(record)
    if not record or not record.owner or not record.repo then
        return nil
    end

    local owner = record.owner
    return {
        kind = "patch",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end

local function makeScrollableTextBoxForDialog(dialog, text)
    local width = dialog and dialog.getAddedWidgetAvailableWidth and dialog:getAddedWidgetAvailableWidth()
    width = tonumber(width) or math.floor(Device.screen:getWidth() * 0.8)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local scrollbar_slack = 3 * Device.screen:scaleBySize(6)
    local content_width = math.max(width - scrollbar_slack, 200)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end

    local box = TextBoxWidget:new{
        text = text,
        width = math.max(content_width - 2 * Size.padding.default, 160),
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        show_parent = dialog,
        frame,
    }
end
local function makeTextBox(text)
    local args = {
        text = text,
        width = math.floor(Device.screen:getWidth() * 0.8),
    }
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if not face and Font and Font.getFace then
        face = Font:getFace("infofont")
    end
    if face then
        args.face = face
    end
    return TextBoxWidget:new(args)
end

local function makeScrollableTextBox(text)
    local width = math.floor(Device.screen:getWidth() * 0.9)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end
    local box = TextBoxWidget:new{
        text = text,
        width = width - 2 * Size.padding.default,
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        frame,
    }
end

function Storefront:refreshPatchUpdates()
    local records = getPatchRecordsMap()
    local tracked = {}
    local installed = listInstalledPatches()
    local installed_map = {}
    for _, patch in ipairs(installed) do
        if patch.filename then
            installed_map[patch.filename] = true
        end
    end
    for filename, record in pairs(records) do
        if installed_map[filename] and record.owner and record.repo and record.path then
            local copy = util.tableDeepCopy(record)
            copy.filename = filename
            table.insert(tracked, copy)
        end
    end
    if #tracked == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matched patches to check."), timeout = 4 })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Checking patch updates…"),
        timeout = 5,
    })
    NetworkMgr:runWhenOnline(function()
        self:_refreshPatchUpdatesInternal(tracked)
    end)
end

function Storefront:_refreshPatchUpdatesInternal(records)
    if not self.browser_menu then return end
    records = records or {}
    self:ensurePatchUpdatesState()
    local single_context = self.patch_updates_state.single_check_context
        and self.patch_updates_state.single_check_context.filename
    self.patch_updates_state.single_check_context = nil
    local progress = self:showProgressMessage(_("Checking patch updates…"))
    UIManager:forceRePaint()
    local remote_info = self.patch_updates_state.remote_info or {}
    local repo_cache = {}

    local function getRepoKey(repo)
        return repo.repo_id or repo.full_name or repo.name
    end

    local function ensureRepoEntries(repo)
        local key = getRepoKey(repo)
        if repo_cache[key] then
            return repo_cache[key].map, repo_cache[key].err
        end
        local entries = self:fetchPatchEntriesFromGitHub(repo)
        local map = {}
        if entries and #entries > 0 then
            for _, entry in ipairs(entries) do
                if entry.path then
                    map[entry.path] = entry
                end
            end
            repo_cache[key] = { map = map }
            return map, nil
        end
        local err = _("Failed to fetch patch list.")
        repo_cache[key] = { map = nil, err = err }
        return nil, err
    end

    for _idx, record in ipairs(records) do
        if not self.browser_menu then break end
        local repo = buildPatchRepoDescriptor(record)
        local entry
        local err
        if repo then
            local map
            map, err = ensureRepoEntries(repo)
            if map then
                entry = map[record.path]
                if not entry then
                    err = _("Patch file not found in repository.")
                end
            end
        else
            err = _("Missing repository metadata for patch.")
        end
        remote_info[record.filename] = {
            remote_sha = entry and entry.sha or nil,
            download_url = entry and entry.download_url or record.download_url,
            error = err,
            last_checked = os.time(),
        }
    end

    self:dismissProgressMessage(progress)
    if not self.browser_menu then return end
    self.patch_updates_state.remote_info = remote_info

    local summary = self:collectPatchUpdateSummary()
    local summary_tracked = summary.tracked or 0
    local summary_map = {}
    for _, item in ipairs(summary.data or {}) do
        if item.patch and item.patch.filename then
            summary_map[item.patch.filename] = item
        end
    end

    local processed_count = #records
    local processed_updates = 0
    for _, record in ipairs(records) do
        local filename = record and record.filename
        local entry = filename and summary_map[filename]
        if entry and entry.needs_update then
            processed_updates = processed_updates + 1
        end
    end
    local processed_up_to_date = math.max(processed_count - processed_updates, 0)

    local processed_all = processed_count > 0 and processed_count == summary_tracked
    if processed_all then
        self.patch_updates_state.last_checked = os.time()
    end

    local message
    if processed_count == 1 then
        local record = records[1]
        local display = record and (record.filename or record.path) or _("patch")
        if processed_updates == 1 then
            message = string.format(_("%s needs an update."), display)
        else
            message = string.format(_("%s is up to date."), display)
        end
    else
        message = string.format(_("Checked %d patches: %d need updates, %d up to date."), processed_count, processed_updates, processed_up_to_date)
    end

    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    end
    self:savePatchUpdatesState()
    self:refreshCurrentBrowserTab()  -- rebuilds browser if on Updates tab

    UIManager:setDirty(nil, "full")
end

local function formatPatchRemoteStatus(remote_entry)
    if not remote_entry then
        return _("Remote: (not checked)")
    end
    if remote_entry.error then
        return _("Remote check failed: ") .. tostring(remote_entry.error)
    end
    if remote_entry.remote_sha then
        local sha = remote_entry.remote_sha
        local short = sha and sha:sub(1, 8) or _("unknown")
        local ts = remote_entry.last_checked and formatTimestamp(remote_entry.last_checked)
        if ts then
            return string.format(_("Remote SHA: %s (checked %s)"), short, ts)
        end
        return string.format(_("Remote SHA: %s"), short)
    end
    return _("Remote: (not checked)")
end

local function buildPatchEntryFromRecord(record)
    if not record or not record.path then
        return nil
    end
    local download_url = record.download_url
        or (record.owner and record.repo and buildPatchDownloadUrl(record.owner, record.repo, record.branch or "HEAD", record.path))
    if not download_url then
        return nil
    end
    return {
        filename = record.filename,
        path = record.path,
        display_path = record.path,
        download_url = download_url,
        branch = record.branch or "HEAD",
        sha = record.sha,
    }
end

local function computeFileSha1(path)
    if not path or path == "" then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content then
        return nil
    end
    local header = string.format("blob %d", #content)
    return sha2.sha1(header .. "\0" .. content)
end

local function isPluginDisabled(dirname)
    if not dirname or dirname == "" then
        return false
    end
    if not G_reader_settings then
        return false
    end
    local plugins_disabled = (type(G_reader_settings.readSetting) == "function" and G_reader_settings:readSetting("plugins_disabled")) or {}
    local plugin_name = dirname:gsub("%.koplugin$", "")
    return plugins_disabled[plugin_name] == true
end

local function isPatchDisabled(filename)
    if not filename or filename == "" then
        return false
    end
    return filename:match("%.disabled$") ~= nil
end

local function isDefaultPlugin(plugin, maybe_plugin)
    return Storefront:isDefaultPlugin(plugin, maybe_plugin)
end

local function isDefaultPatch(patch)
    return Storefront:isDefaultPatch(patch)
end


function Storefront:togglePluginDisabled(dirname, skip_prompt)
    if not dirname or dirname == "" then return false, "" end
    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local plugin_name = dirname:gsub("%.koplugin$", "")
    local currently_disabled = plugins_disabled[plugin_name] == true
    if currently_disabled then
        plugins_disabled[plugin_name] = nil
    else
        plugins_disabled[plugin_name] = true
    end
    G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
    G_reader_settings:flush()

    local is_now_disabled = not currently_disabled
    if not skip_prompt then
        self:reopenBrowser(nil, function()
            local action_str = currently_disabled and _("enabled") or _("disabled")
            showRestartConfirmation(string.format(_("Plugin %s has been %s."), plugin_name, action_str))
        end)
    end
    return is_now_disabled, plugin_name
end

function Storefront:togglePatchDisabled(filename, skip_prompt)
    if not filename or filename == "" then return false, "" end
    local old_path = PATCHES_ROOT .. "/" .. filename
    if lfs.attributes(old_path, "mode") ~= "file" then return false, "" end

    local new_filename
    local is_disabled = isPatchDisabled(filename)
    if is_disabled then
        new_filename = filename:gsub("%.disabled$", "")
    else
        new_filename = filename .. ".disabled"
    end
    local new_path = PATCHES_ROOT .. "/" .. new_filename

    local ok, err = os.rename(old_path, new_path)
    if ok then
        local records = getPatchRecordsMap()
        local rec = records[filename]
        if rec then
            InstallStore.removePatch(filename)
            rec.filename = new_filename
            InstallStore.upsertPatch(new_filename, rec)
        end
        local is_now_disabled = not is_disabled
        if not skip_prompt then
            self:reopenBrowser(nil, function()
                local status_str = is_disabled and _("enabled") or _("disabled")
                showRestartConfirmation(string.format(_("Patch %s has been %s."), new_filename, status_str))
            end)
        end
        return is_now_disabled, new_filename
    else
        logger.warn("Storefront: failed to rename patch file", err)
        UIManager:show(InfoMessage:new{
            text = _("Failed to toggle patch status."),
            timeout = 3,
        })
        return is_disabled, filename
    end
end

local function deleteDirectoryRecursive(path)
    if not path or path == "" then
        return false, "Invalid path"
    end
    local attr = lfs.attributes(path)
    if not attr then
        return false, "Path does not exist"
    end
    if attr.mode ~= "directory" then
        return os.remove(path), "Not a directory"
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = path .. "/" .. entry
            local entry_attr = lfs.attributes(full_path)
            if entry_attr then
                if entry_attr.mode == "directory" then
                    local ok, err = deleteDirectoryRecursive(full_path)
                    if not ok then
                        return false, err
                    end
                else
                    local ok, err = os.remove(full_path)
                    if not ok then
                        return false, err
                    end
                end
            end
        end
    end
    return lfs.rmdir(path)
end



buildBranchCandidates = function(record)
    local seen = {}
    local candidates = {}
    local function add(branch)
        if not branch or branch == "" then
            return
        end
        if seen[branch] then
            return
        end
        seen[branch] = true
        table.insert(candidates, branch)
    end

    if record then
        add(record.branch)
    end
    add("HEAD")
    add("main")
    add("master")

    return candidates
end


local function buildMetaPathCandidates(record)
    if not record then
        return {}
    end
    local seen = {}
    local candidates = {}
    local function add(path)
        if not path or path == "" then
            return
        end
        local normalized = normalizeMetaPath(path)
        if not normalized or seen[normalized] then
            return
        end
        seen[normalized] = true
        table.insert(candidates, normalized)
    end

    add(record.meta_path)
    if record.meta_path and derivePluginRepoPath then
        add(derivePluginRepoPath(record.meta_path))
    end
    add(record.meta_path_hint)

    if record.meta_path then
        local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
        if derivePluginRepoPath then
            add(derivePluginRepoPath(trimmed))
        end
    end
    if record.meta_path_hint then
        local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end

    if record.dirname and record.dirname ~= "" then
        add("plugins/" .. record.dirname .. "/_meta.lua")
        add(record.dirname .. "/_meta.lua")
        if record.dirname:match("%.koplugin$") then
            local without_suffix = record.dirname:gsub("%.koplugin$", "")
            add("plugins/" .. without_suffix .. "/_meta.lua")
            add(without_suffix .. "/_meta.lua")
        end
    end

    add("plugins/_meta.lua")
    add("_meta.lua")

    return candidates
end

local function formatRemoteStatus(remote)
    if not remote then
        return _("Remote: (not checked)")
    end
    if remote.remote_version then
        local ts = remote.last_checked and formatTimestamp(remote.last_checked)
        if ts then
            return string.format(_("Remote: %s (checked %s)"), remote.remote_version, ts)
        end
        return string.format(_("Remote: %s"), remote.remote_version)
    end
    if remote.error then
        return _("Remote check failed: ") .. tostring(remote.error)
    end
    return _("Remote: (not checked)")
end


local function isPreReleaseTag(tag_name)
    if not tag_name then
        return false
    end
    
    local lower = tag_name:lower()
    local prerelease_keywords = {
        "alpha",
        "beta",
        "rc",
        "dev",
        "preview",
        "pre",
        "test",
    }
    
    for _, keyword in ipairs(prerelease_keywords) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end
    
    return false
end

local function isDateBasedVersion(version_str)
    if not version_str then
        return false
    end
    
    local year, month, day = version_str:match("^(%d%d%d%d)%.(%d+)%.(%d+)$")
    if year then
        local y = tonumber(year)
        local m = tonumber(month)
        local d = tonumber(day)
        
        if y >= 2000 and y <= 2100 and m >= 1 and m <= 12 and d >= 1 and d <= 31 then
            return true
        end
    end
    
    return false
end

local function parseVersionFromTag(tag_name)
    if not tag_name then
        return nil
    end

    local cleaned = tag_name:gsub("^[vV]", "")
    cleaned = cleaned:gsub("^release%-?", "")
    cleaned = cleaned:gsub("^version%-?", "")
    cleaned = cleaned:gsub("^plugin%-?", "")

    -- Must start with a digit to be a valid version
    if not cleaned:match("^%d") then
        return nil
    end

    -- Return the full cleaned string (including any prerelease suffix like -beta2, -rc1)
    -- so that isVersionNewer() can correctly compare prerelease numbers.
    -- e.g. "v26.7.31-beta2" -> "26.7.31-beta2"  (NOT just "26.7.31")
    return cleaned
end


local function getRepoOwner(repo)
    if not repo then
        return nil
    end
    if repo.owner and repo.owner ~= "" then
        return repo.owner
    end
    if repo.data and repo.data.owner and repo.data.owner.login then
        return repo.data.owner.login
    end
end

local function getRepoDefaultBranch(repo)
    return (repo and repo.data and repo.data.default_branch)
        or (repo and repo.default_branch)
        or "HEAD"
end

local function buildInstallRecordFields(dirname, plugin_name, installed_version, repo, meta_path, installed_tag)
    if not dirname or dirname == "" then
        return nil
    end
    local owner = getRepoOwner(repo)
    local repo_name = repo and repo.name
    local record = {
        dirname = dirname,
        plugin_name = plugin_name,
        installed_version = installed_version,
        installed_tag = installed_tag or nil,
        owner = owner,
        repo = repo_name,
        repo_full_name = repo and (repo.full_name or (owner and repo_name and (owner .. "/" .. repo_name))) or nil,
        repo_id = repo and (repo.repo_id or repo.id) or nil,
        repo_description = repo and repo.description or nil,
        branch = getRepoDefaultBranch(repo),
        meta_path = meta_path,
        matched_at = os.time(),
    }
    return record
end

local function getPluginMetaPath(root, dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return string.format("%s/%s/_meta.lua", root, dirname)
end

local G_plugin_meta_cache = {}

local function loadPluginMeta(root, dirname)
    local meta_path = getPluginMetaPath(root, dirname)
    if not meta_path then
        return nil
    end
    local attr = lfs.attributes(meta_path)
    if not attr or attr.mode ~= "file" then
        return nil
    end
    local mtime = attr.modification or 0
    local cached = G_plugin_meta_cache[meta_path]
    if cached and cached.mtime == mtime then
        return cached.meta
    end
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" then
        G_plugin_meta_cache[meta_path] = { mtime = mtime, meta = meta }
        return meta
    end
end

local function getPluginDisplayName(meta, dirname)
    if meta then
        if meta.fullname and meta.fullname ~= "" then
            return meta.fullname
        end
        if meta.name and meta.name ~= "" then
            return meta.name
        end
    end
    if dirname and dirname ~= "" then
        return dirname:gsub("%.koplugin$", "")
    end
    return "plugin"
end

local G_installed_plugins_cache = nil
local G_installed_patches_cache = nil
local G_installed_fonts_cache = nil

local function invalidateInstalledPluginsCache()
    G_installed_plugins_cache = nil
    G_installed_patches_cache = nil
    G_installed_fonts_cache = nil
    if Storefront and type(Storefront) == "table" then
        Storefront._tab_menu_items_cache = nil
        Storefront._installed_tab_items_cache = nil
        Storefront._installed_lookup_cache = nil
    end
    local ok_fm, font_mgr = pcall(require, "storefront_font_mgr")
    if ok_fm and font_mgr and type(font_mgr.invalidateInstalledFontsCache) == "function" then
        font_mgr.invalidateInstalledFontsCache()
    end
end

function Storefront:invalidateInstalledPluginsCache()
    self._tab_menu_items_cache = nil
    self._installed_tab_items_cache = nil
    self._installed_lookup_cache = nil
    invalidateInstalledPluginsCache()
end

local function getLatestModificationTimestamp(path)
    if not path or path == "" then
        return 0
    end
    local attr = lfs.attributes(path)
    return attr and (attr.modification or 0) or 0
end

local function listInstalledPlugins()
    local generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    if G_installed_plugins_cache and G_installed_plugins_cache.generation == generation then
        return G_installed_plugins_cache.plugins
    end
    local plugins = {}
    local hidden_paths = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
    for _, root in ipairs(PluginPaths.getLookupPaths()) do
        if lfs.attributes(root, "mode") == "directory" and not PluginPaths.isPathHidden(root, hidden_paths) then
            for entry in lfs.dir(root) do
                if entry ~= "." and entry ~= ".." and entry:match("%.koplugin$") then
                    local meta = loadPluginMeta(root, entry)
                    local plugin_path = root .. "/" .. entry
                    local attr = lfs.attributes(plugin_path)
                    local install_map = (InstallStore and InstallStore.list and InstallStore.list()) or {}
                    local rec = install_map[entry] or install_map[entry:gsub("%.koplugin$", "")]
                    local rec_ver = rec and (rec.version or rec.installed_version or (rec.installed_tag and rec.installed_tag:gsub("^[vV]", "")))
                    local plugin = {
                        dirname = entry,
                        meta = meta,
                        fullname = meta and (meta.fullname or meta.name),
                        shortname = meta and meta.name,
                        name = getPluginDisplayName(meta, entry),
                        version = (meta and meta.version and meta.version ~= "") and meta.version or rec_ver,
                        root = root,
                        path = plugin_path,
                        meta_path_hint = entry .. "/_meta.lua",
                        latest_mtime = attr and (attr.modification or 0) or 0,
                    }
                    table.insert(plugins, plugin)
                end
            end
        end
    end
    table.sort(plugins, function(a, b)
        local na = tostring(a and (a.name or a.dirname) or ""):lower()
        local nb = tostring(b and (b.name or b.dirname) or ""):lower()
        return na < nb
    end)
    G_installed_plugins_cache = {
        generation = generation,
        plugins = plugins,
    }
    return plugins
end

function Storefront:listInstalledPlugins()
    return listInstalledPlugins()
end

local function listInstalledFonts()
    return Storefront:listInstalledFonts()
end

local function findInstalledPlugin(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    local installed = listInstalledPlugins()
    for _, plugin in ipairs(installed) do
        if plugin.dirname == dirname then
            return plugin
        end
    end
end

local function findInstalledPatch(filename)
    if not filename or filename == "" then
        return nil
    end
    local patches = listInstalledPatches()
    for _, patch in ipairs(patches) do
        if patch.filename == filename then
            return patch
        end
    end
end

local function getInstallRecordsMap(sf)
    if sf and type(sf) == "table" and type(sf.getInstallRecordsMap) == "function" and sf.getInstallRecordsMap ~= Storefront.getInstallRecordsMap then
        return sf:getInstallRecordsMap()
    end
    local ok, records = pcall(function()
        return InstallStore.list()
    end)
    if not ok or type(records) ~= "table" then
        return {}
    end
    return records
end

function Storefront:getInstallRecordsMap()
    local ok, records = pcall(function()
        return InstallStore.list()
    end)
    if not ok or type(records) ~= "table" then
        return {}
    end
    return records
end

function Storefront:saveUpdatesState()
    if self.updates_state then
        StorefrontSettings:saveSetting("updates_state", self.updates_state)
        StorefrontSettings:flush()
    end
end

function Storefront:savePatchUpdatesState()
    if self.patch_updates_state then
        StorefrontSettings:saveSetting("patch_updates_state", self.patch_updates_state)
        StorefrontSettings:flush()
    end
end

function Storefront:ensureUpdatesState()
    if not self.updates_state then
        self.updates_state = StorefrontSettings:readSetting("updates_state") or {}
    end
    self.updates_state.filter_only_linked = self.updates_state.filter_only_linked or false
    self.updates_state.filter_only_outdated = self.updates_state.filter_only_outdated or false
    self.updates_state.page = self.updates_state.page or 1
    self.updates_state.remote_info = self.updates_state.remote_info or {}
    self.patch_updates_state = self.patch_updates_state or {}
    self.patch_updates_state.filter_only_linked = self.patch_updates_state.filter_only_linked or false
    self.patch_updates_state.filter_only_outdated = self.patch_updates_state.filter_only_outdated or false
    self.patch_updates_state.page = self.patch_updates_state.page or 1
    self.patch_updates_state.remote_info = self.patch_updates_state.remote_info or {}
    self:sanitizeRemoteInfo()
    self:checkAndRecoverLegacyCache()
end

function Storefront:sanitizeRemoteInfo()
    if not self.updates_state or not self.updates_state.remote_info then return end
    local remote_info = self.updates_state.remote_info
    for dirname, entry in pairs(remote_info) do
        if type(entry) == "table" and entry.error then
            entry.error = nil
        end
    end
end

function Storefront:populateRemoteInfoFromCatalog()
    self:ensureUpdatesState()
    local installed = listInstalledPlugins()
    local records = InstallStore.getRecords()
    local remote_info = self.updates_state.remote_info or {}
    local updated_count = 0

    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        if record and (record.repo_id or (record.owner and record.repo)) then
            local cached_repo
            if record.repo_id then
                cached_repo = Cache.getRepo(record.repo_id)
            end
            if not cached_repo and record.owner and record.repo then
                cached_repo = Cache.getRepoByName(record.owner, record.repo)
            end
            if cached_repo then
                local cat_rel = cached_repo.latest_release or (cached_repo.data and cached_repo.data.latest_release)
                local cat_tag = (cat_rel and cat_rel.tag_name)
                    or cached_repo.version
                    or (cached_repo.data and (cached_repo.data.version or cached_repo.data.tag_name or cached_repo.data.latest_version))
                local cat_published = cat_rel and cat_rel.published_at

                if cat_tag then
                    remote_info[plugin.dirname] = {
                        remote_version = cat_tag:gsub("^[vV]", ""),
                        release_tag_name = cat_tag,
                        release_published_at = cat_published and parseGitHubTimestamp(cat_published) or 0,
                        last_checked = os.time(),
                        is_cached_fallback = true,
                    }
                    updated_count = updated_count + 1
                else
                    if remote_info[plugin.dirname] and remote_info[plugin.dirname].is_cached_fallback then
                        remote_info[plugin.dirname] = nil
                        updated_count = updated_count + 1
                    end
                end
            end
        end
    end

    self.updates_state.remote_info = remote_info
    self.updates_state.last_checked = os.time()
    self:saveUpdatesState()
    self._cached_plugin_summary = nil
    self._merged_updates_cache = nil
    if updated_count > 0 then
        if StorefrontLogger then
            StorefrontLogger.info(string.format("Populated remote_info from catalog for %d plugins", updated_count))
        end
    end
end

function Storefront:checkAndRecoverLegacyCache()
    if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
        return
    end
    if self._recovery_attempted then
        return
    end
    if Cache and Cache.isLegacyFormat and Cache.isLegacyFormat("plugin") then
        self._recovery_attempted = true
        if StorefrontLogger then
            StorefrontLogger.info("Legacy cache format detected without latest_release; triggering automatic recovery catalog refresh")
        end
        local CatalogClient = require("storefront_net_catalog")
        CatalogClient.fetchAndUpdateCacheAsync(nil, function(success, err)
            if success then
                self:populateRemoteInfoFromCatalog()
            end
        end)
    end
end

function Storefront:ensurePatchUpdatesState()
    if not self.patch_updates_state then
        self.patch_updates_state = StorefrontSettings:readSetting("patch_updates_state") or {}
    end
    self.patch_updates_state.filter_only_outdated = self.patch_updates_state.filter_only_outdated or false
    self.patch_updates_state.filter_only_linked = self.patch_updates_state.filter_only_linked or false
    self.patch_updates_state.remote_info = self.patch_updates_state.remote_info or {}
    self.patch_updates_state.page = self.patch_updates_state.page or 1
end

-- Reset a paginated dialog's state to "top of list" (page 1, no saved scroll
-- offset) and reset its live scroller. Both steps are needed: otherwise the
-- dialog's on_dismiss would write the current (old) live offset back over the
-- nil just set here, and the rebuilt list would reopen scrolled past its
-- first rows. Used whenever a filter/sort/page-size change invalidates the
-- current view (see call sites in showPluginFilterDialog/showPatchFilterDialog).
function Storefront:resetPageAndScroll(state, menu)
    state.page = 1
    state.scroll_offset = nil
    if menu and menu.resetScroll then
        menu:resetScroll()
    end
end

local function extractAuthorFromPlugin(plugin)
    if not plugin then return nil end
    local meta = plugin.meta
    if meta then
        if meta.owner and type(meta.owner) == "string" and meta.owner ~= "" then return meta.owner end
        if meta.author and type(meta.author) == "string" and meta.author ~= "" then return meta.author end
        if meta.developer and type(meta.developer) == "string" and meta.developer ~= "" then return meta.developer end
        if meta.by and type(meta.by) == "string" and meta.by ~= "" then return meta.by end
        
        local url = meta.url or meta.homepage or meta.repository or meta.repo or meta.fullname
        if url and type(url) == "string" then
            local owner = url:match("github%.com[:/]([^/]+)")
            if owner then return owner end
        end
    end
    
    if plugin.path then
        local meta_path = plugin.path .. "/_meta.lua"
        local mf = io.open(meta_path, "r")
        if mf then
            local mcontent = mf:read("*a")
            mf:close()
            if mcontent then
                local owner = mcontent:match("github%.com[:/]([^/\"']+)")
                if owner then return owner end
                local author = mcontent:match("author%s*=%s*[\"']([^\"']+)[\"']") or mcontent:match("owner%s*=%s*[\"']([^\"']+)[\"']")
                if author and author ~= "" then return author end
            end
        end

        local git_cfg_path = plugin.path .. "/.git/config"
        local f = io.open(git_cfg_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content then
                local owner = content:match("github%.com[:/]([^/]+)")
                if owner then return owner end
            end
        end
    end
    
    return nil
end



function Storefront:collectPatchUpdateSummary()
    self:ensurePatchUpdatesState()
    local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local remote_info_key = self.patch_updates_state and self.patch_updates_state.last_checked
    
    if self._cached_patch_summary
       and self._cached_patch_summary_gen == current_generation
       and self._cached_patch_summary_remote == remote_info_key then
        return self._cached_patch_summary
    end

    self:autoMatchInstalled()
    local summary = buildPatchSummary(self.patch_updates_state.remote_info)
    
    StorefrontLogger.info(string.format(
        "PATCH UPDATE SCAN COMPLETE: %d patches total, %d tracked, %d with updates",
        summary and summary.total or 0, summary and summary.tracked or 0, summary and summary.updates or 0
    ))

    self._cached_patch_summary = summary
    self._cached_patch_summary_gen = current_generation
    self._cached_patch_summary_remote = remote_info_key
    return summary
end

function Storefront:getPatchUpdatesSummaryText(summary)
    summary = summary or self:collectPatchUpdateSummary()
    local parts = {
        string.format(_("Tracked: %d"), summary.tracked or 0),
        string.format(_("Unmatched: %d"), summary.unmatched or 0),
        string.format(_("Needs update: %d"), summary.updates or 0),
    }
    if self.patch_updates_state and self.patch_updates_state.last_checked then
        table.insert(parts, string.format(_("Last check: %s"), formatTimestamp(self.patch_updates_state.last_checked)))
    end
    return table.concat(parts, " • ")
end

local function isPreReleaseAllowedForPlugin(repo, record, dirname)
    local keys = {}
    if repo then
        if repo.name then table.insert(keys, repo.name) end
        if repo.full_name then table.insert(keys, repo.full_name) end
    end
    if record then
        if record.repo then table.insert(keys, record.repo) end
        if record.repo_full_name then table.insert(keys, record.repo_full_name) end
        if record.dirname then table.insert(keys, record.dirname) end
    end
    if dirname then table.insert(keys, dirname) end
    for _, key in ipairs(keys) do
        if InstallStore.isPreReleaseAllowed(key) then
            return true
        end
    end
    return false
end

function Storefront:isPreReleaseAllowedForPlugin(repo, record, dirname)
    return isPreReleaseAllowedForPlugin(repo, record, dirname)
end

function Storefront:collectUpdateSummary()
    self:ensureUpdatesState()
    local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local remote_info_key = self.updates_state and self.updates_state.last_checked

    if self._cached_plugin_summary
       and self._cached_plugin_summary_gen == current_generation
       and self._cached_plugin_summary_remote == remote_info_key then
        return self._cached_plugin_summary
    end

    self:autoMatchInstalled()
    self:ensureUpdatesState()
    local records = getInstallRecordsMap(self)
    local installed = self:listInstalledPlugins()
    local remote_info = self.updates_state.remote_info or {}
    local data = {}
    local summary = {
        total = #installed,
        tracked = 0,
        unmatched = 0,
        updates = 0,
    }

    if StorefrontLogger and StorefrontLogger.debug then
        StorefrontLogger.debug(string.format("UPDATE SCAN: checking %d installed plugins", #installed))
    end

    local repo_map = {}

    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        local tracked = record and record.owner and record.repo
        local repo_key = tracked and (record.owner:lower() .. "/" .. record.repo:lower()) or nil
        local is_duplicate = false

        if repo_key then
            if repo_map[repo_key] then
                local existing_index = repo_map[repo_key]
                local existing_item = data[existing_index]
                local existing_plugin = existing_item.plugin

                local current_matches_repo = (plugin.dirname:lower() == (record.repo:lower() .. ".koplugin"))
                local existing_matches_repo = (existing_plugin.dirname:lower() == (existing_item.record.repo:lower() .. ".koplugin"))

                local current_is_primary = false
                if current_matches_repo and not existing_matches_repo then
                    current_is_primary = true
                elseif not current_matches_repo and existing_matches_repo then
                    current_is_primary = false
                else
                    current_is_primary = (plugin.latest_mtime or 0) > (existing_plugin.latest_mtime or 0)
                end

                summary.total = summary.total - 1
                if current_is_primary then
                    existing_item.duplicates = existing_item.duplicates or {}
                    table.insert(existing_item.duplicates, existing_plugin)

                    existing_item.plugin = plugin
                    existing_item.record = record
                    existing_item.remote = remote_info[plugin.dirname]
                else
                    existing_item.duplicates = existing_item.duplicates or {}
                    table.insert(existing_item.duplicates, plugin)
                    is_duplicate = true
                end
            end
        end

        if not is_duplicate then
            if tracked then
                summary.tracked = summary.tracked + 1
            else
                summary.unmatched = summary.unmatched + 1
            end

            local remote = remote_info[plugin.dirname]
            if not remote and record and record.repo then
                remote = remote_info[record.repo]
                    or remote_info[record.repo .. ".koplugin"]
                    or remote_info[record.repo:lower()]
                    or remote_info[record.repo:lower() .. ".koplugin"]
            end
        -- A remote entry with an error is still usable if it has a release_tag_name.
        -- Only treat it as unchecked if it has NO version info at all.
        local has_checked_info = remote and (remote.release_tag_name or remote.remote_version) and not (remote.error and not remote.release_tag_name)

        -- Always check the catalog cache for a fresh release tag, and prefer it
        -- if it's newer than what's in the (possibly stale) remote_info.
        if tracked then
            local cached_repo
            if record.repo_id then
                cached_repo = Cache.getRepo(record.repo_id)
            end
            if not cached_repo and record.owner and record.repo and Cache and Cache.getRepoByName then
                cached_repo = Cache.getRepoByName(record.owner, record.repo)
            end
            if cached_repo then
                -- Pull release tag from catalog: prefer top-level latest_release, then data.latest_release, then version fields
                local cat_rel = cached_repo.latest_release or (cached_repo.data and cached_repo.data.latest_release)
                local cat_tag = (cat_rel and cat_rel.tag_name)
                    or cached_repo.version
                    or (cached_repo.data and (cached_repo.data.version or cached_repo.data.tag_name or cached_repo.data.latest_version))
                local cat_published = cat_rel and cat_rel.published_at

                local pushed_at_str = (cached_repo.data and (cached_repo.data.pushed_at or cached_repo.data.updated_at))
                local remote_repo_ts = pushed_at_str and parseGitHubTimestamp(pushed_at_str) or 0

                if cat_tag then
                    -- Use catalog data if remote_info is missing, errored, or has an older tag.
                    -- But never override a stable live-scanned tag with a prerelease catalog tag
                    -- unless the plugin explicitly allows prereleases.
                    local existing_tag = remote and remote.release_tag_name
                    local cat_is_prerelease = isPreReleaseTag(cat_tag)
                    local allow_pre_for_plugin = isPreReleaseAllowedForPlugin(nil, record, plugin.dirname)
                    local catalog_tag_is_usable = not cat_is_prerelease or allow_pre_for_plugin

                    local should_use_catalog = catalog_tag_is_usable and (
                        not existing_tag
                        or (remote and remote.error ~= nil)
                        or isVersionNewer(cat_tag, existing_tag)
                    )

                    if should_use_catalog then
                        if StorefrontLogger and StorefrontLogger.debug then
                            StorefrontLogger.debug(string.format(
                                "UPDATE SCAN catalog override: %s  old_tag=%s  cat_tag=%s",
                                tostring(plugin.dirname), tostring(existing_tag), tostring(cat_tag)
                            ))
                        end
                        remote = {
                            remote_version = remote and remote.remote_version,
                            remote_repo_ts = remote_repo_ts,
                            release_tag_name = cat_tag,
                            release_published_at = cat_published and parseGitHubTimestamp(cat_published) or 0,
                            is_cached_fallback = true,
                        }
                        has_checked_info = true
                    end
                elseif not has_checked_info then
                    -- No release tag from catalog either; use timestamp-based fallback
                    local prev_version = remote and (remote.release_tag_name or remote.remote_version)
                    remote = {
                        remote_version = prev_version,
                        remote_repo_ts = remote_repo_ts,
                        release_tag_name = remote and remote.release_tag_name,
                        is_cached_fallback = true,
                    }
                end
            end
        end
        local local_version = plugin.version
        if (not local_version or local_version == "") and record then
            local_version = record.installed_version or record.version or record.tag_name
        end
        local local_latest_ts = plugin.latest_mtime
        if not local_latest_ts or local_latest_ts == 0 then
            local_latest_ts = getLatestModificationTimestamp(plugin.path)
            plugin.latest_mtime = local_latest_ts
        end
        
        local has_update = false

        if tracked and remote then
            local release_tag = remote.release_tag_name
            local release_ts = remote.release_published_at or 0

            if release_tag then
                local release_version = parseVersionFromTag(release_tag)

                if StorefrontLogger and StorefrontLogger.debug then
                    StorefrontLogger.debug(string.format(
                        "UPDATE SCAN plugin: %s  local=%s  tag=%s  parsed_remote=%s",
                        tostring(plugin.dirname),
                        tostring(local_version),
                        tostring(release_tag),
                        tostring(release_version)
                    ))
                end

                if release_version and local_version then
                    has_update = isVersionNewer(release_version, local_version)
                elseif release_version then
                    has_update = release_ts > local_latest_ts
                else
                    local raw_tag = release_tag:gsub("^[vV]", "")
                    local raw_local = local_version and tostring(local_version):gsub("^[vV]", "") or nil
                    if raw_tag ~= "" and raw_local then
                        if raw_tag == raw_local then
                            has_update = false
                        else
                            has_update = isVersionNewer(raw_tag, raw_local)
                        end
                    elseif release_ts > 0 and local_latest_ts > 0 then
                        has_update = release_ts > local_latest_ts
                    end
                end

                if has_update then
                    local item_k = plugin.dirname or (record and (record.owner and record.repo and (record.owner .. "/" .. record.repo) or record.repo))
                    if item_k and InstallStore.isAllUpdatesIgnored(item_k) then
                        has_update = false
                    elseif record and record.owner and record.repo then
                        if InstallStore.isReleaseIgnoredByRepo(record.owner, record.repo, release_tag) then
                            has_update = false
                        end
                    end
                end
            else
                local remote_version = remote.remote_version
                local remote_repo_ts = remote.remote_repo_ts or 0

                if StorefrontLogger and StorefrontLogger.debug then
                    StorefrontLogger.debug(string.format(
                        "UPDATE SCAN plugin: %s  local=%s  remote_version=%s  (no tag)",
                        tostring(plugin.dirname),
                        tostring(local_version),
                        tostring(remote_version)
                    ))
                end

                if remote_version and local_version then
                    has_update = isVersionNewer(remote_version, local_version)
                else
                    has_update = false
                end
            end
        else
            if StorefrontLogger and StorefrontLogger.debug then
                StorefrontLogger.debug(string.format(
                    "UPDATE SCAN plugin: %s  local=%s  tracked=%s  has_remote=%s",
                    tostring(plugin.dirname),
                    tostring(local_version),
                    tostring(tracked and (record.owner .. "/" .. record.repo) or "no"),
                    tostring(remote ~= nil)
                ))
            end
        end

        if has_update then
            summary.updates = summary.updates + 1
            StorefrontLogger.info(string.format(
                "UPDATE AVAILABLE: %s  (%s → %s)",
                tostring(plugin.dirname),
                tostring(local_version),
                tostring(remote and (remote.release_tag_name or remote.remote_version) or "?")
            ))
        end

        data[#data + 1] = {
            plugin = plugin,
            record = record,
            remote = remote,
            has_update = has_update,
        }
        if repo_key then
            repo_map[repo_key] = #data
        end
    end
end

    summary.data = data
    summary.records = records

    StorefrontLogger.info(string.format(
        "UPDATE SCAN COMPLETE: %d plugins total, %d tracked, %d with updates",
        summary.total or 0, summary.tracked or 0, summary.updates or 0
    ))

    self._cached_plugin_summary = summary
    self._cached_plugin_summary_gen = current_generation
    self._cached_plugin_summary_remote = remote_info_key
    return summary
end

function Storefront:getUpdatesSummaryText(summary)
    summary = summary or self:collectUpdateSummary()
    local parts = {
        string.format(_("Tracked: %d"), summary.tracked or 0),
        string.format(_("Unmatched: %d"), summary.unmatched or 0),
        string.format(_("Needs update: %d"), summary.updates or 0),
    }
    if self.updates_state and self.updates_state.last_checked then
        table.insert(parts, string.format(_("Last check: %s"), formatTimestamp(self.updates_state.last_checked)))
    end
    return table.concat(parts, " • ")
end

function Storefront:buildUpdateItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local entries = {}
    local filter_updates = self.updates_state.filter_only_outdated
    local filter_linked = self.updates_state.filter_only_linked
    for idx, item in ipairs(summary.data or {}) do
        local is_linked = item.record and item.record.owner and item.record.repo
        if ((not filter_updates) or item.has_update) and ((not filter_linked) or is_linked) then
            local plugin = item.plugin
            local record = item.record
            local remote = item.remote
            local disabled_label = isPluginDisabled(plugin.dirname) and "[DISABLED] " or ""
            local lines = {
                string.format("• %s%s (%s)", disabled_label, plugin.name or plugin.dirname, plugin.dirname),
            }

            local local_version_str = plugin.version or _("unknown")
            local remote_version_str = nil
            local update_reason = nil
            
            if remote then
                if remote.release_tag_name then
                    local release_version = parseVersionFromTag(remote.release_tag_name)
                    if release_version then
                        remote_version_str = release_version
                    else
                        remote_version_str = remote.release_tag_name
                    end
                    
                    if item.has_update then
                        if release_version and plugin.version then
                            if isVersionNewer(release_version, plugin.version) then
                                update_reason = nil
                            else
                                update_reason = _("release is newer by date")
                            end
                        else
                            update_reason = _("release is newer by date")
                        end
                    end
                else
                    if remote.remote_version then
                        remote_version_str = remote.remote_version
                    end
                    
                    if item.has_update then
                        local local_latest_ts = plugin.latest_mtime or 0
                        local remote_repo_ts = remote.remote_repo_ts or 0
                        
                        if remote_repo_ts > local_latest_ts then
                            update_reason = _("remote is newer by date")
                        elseif plugin.version and remote.remote_version then
                            if isVersionNewer(remote.remote_version, plugin.version) then
                                update_reason = nil
                            else
                                update_reason = _("remote is newer by date")
                            end
                        else
                            update_reason = _("remote is newer by date")
                        end
                    end
                end
            end
            
            local version_line
            if remote_version_str then
                version_line = string.format(_("Local: %s → Remote: %s"), local_version_str, remote_version_str)
            else
                version_line = string.format(_("Local: %s"), local_version_str)
            end
            if update_reason then
                version_line = version_line .. " (" .. update_reason .. ")"
            end
            table.insert(lines, version_line)

            if record and record.owner and record.repo then
                table.insert(lines, string.format(_("Repo: %s/%s"), record.owner, record.repo))
            else
                table.insert(lines, _("Repo: (not matched)"))
            end

            if remote and remote.remote_version then
                table.insert(lines, formatRemoteStatus(remote))
            elseif remote and remote.error then
                table.insert(lines, formatRemoteStatus(remote))
            else
                table.insert(lines, _("Remote: (not checked)"))
            end

            if item.has_update then
                table.insert(lines, _("Status: Update available"))
            elseif record and record.owner and record.repo then
                table.insert(lines, _("Status: Up to date"))
            else
                table.insert(lines, _("Status: Needs matching"))
            end

            local text = table.concat(lines, "\n")
            local entry = {
                text = text,
                dim = not item.has_update,
                is_entry = true,
                keep_menu_open = true,
            }
            entry.callback = function()
                self:promptUpdateAction(plugin, record)
            end
            entries[#entries + 1] = entry
        end
    end

    if #entries == 0 then
        if self.updates_state.filter_only_outdated then
            entries[#entries + 1] = { text = _("No plugins need updates."), select_enabled = false }
        else
            entries[#entries + 1] = { text = _("No plugins to display."), select_enabled = false }
        end
    end

    if util.trim(self.browser_state and self.browser_state.search_text or "") ~= "" then
        table.insert(entries, 1, {
            text = "ℹ " .. string.format(_("Search filter (\"%s\") is not applied to Updates."), self.browser_state.search_text),
            select_enabled = false,
            separator = true,
        })
    end

    return entries
end

function Storefront:buildUpdateBrowserItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text = "⮤ " .. _("Switch to plugin list"),
        keep_menu_open = true,
        focus_id = "switch_list",
        callback = function()
            self:closeUpdatesDialog(true)
            self:showBrowser("plugin")
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = "↔ " .. _("Switch to installed patches"),
        keep_menu_open = true,
        focus_id = "switch_installed",
        callback = function()
            self:closeUpdatesDialog(true)
            self:showPatchUpdatesDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        focus_id = "check_all",
        callback = function()
            self:checkAllUpdates()
        end,
    }
    items[#items].separator = true

    local current_filter
    if self.updates_state.filter_only_outdated then
        current_filter = _("Needs update")
    elseif self.updates_state.filter_only_linked then
        current_filter = _("Linked only")
    else
        current_filter = _("All plugins")
    end

    items[#items + 1] = {
        text = _("Filter: ") .. current_filter,
        keep_menu_open = true,
        focus_id = "filter",
        callback = function()
            self:showPluginFilterDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = self:getUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    -- Paginate the installed-plugin entries the same way the browser paginates
    -- its available list. Without this the whole list (dozens of multi-line
    -- widgets) lives on one page, so every cursor move triggers a full-dialog
    -- repaint that takes tens of seconds on e-ink. The informational header
    -- items above are kept on every page (cheap single-line widgets).
    local plugin_items = self:buildUpdateItems(summary)
    local page_size = getManagePageSize()
    local display_total = #plugin_items
    local total_pages = math.max(1, math.ceil(display_total / page_size))
    local page = math.min(math.max(self.updates_state.page or 1, 1), total_pages)
    if self.updates_state.page ~= page then
        self.updates_state.page = page
    end
    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(display_total, start_index + page_size - 1)
    for i = start_index, end_index do
        items[#items + 1] = plugin_items[i]
        items[#items].separator = true
    end

    return items, total_pages
end

function Storefront:buildPatchUpdateBrowserItems(summary)
    self:ensurePatchUpdatesState()
    summary = summary or self:collectPatchUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text ="⮤ " .. _("Switch to patch list"),
        keep_menu_open = true,
        focus_id = "switch_list",
        callback = function()
            self:closePatchUpdatesDialog(true)
            self:showBrowser("patch")
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = "↔ " .. _("Switch to installed plugins"),
        keep_menu_open = true,
        focus_id = "switch_installed",
        callback = function()
            self:closePatchUpdatesDialog(true)
            self:showUpdatesDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        focus_id = "check_all",
        callback = function()
            self:refreshPatchUpdates()
        end,
    }
    items[#items].separator = true

    local current_filter
    if self.patch_updates_state.filter_only_outdated then
        current_filter = _("Needs update")
    elseif self.patch_updates_state.filter_only_linked then
        current_filter = _("Linked only")
    else
        current_filter = _("All patches")
    end

    items[#items + 1] = {
        text = _("Filter: ") .. current_filter,
        keep_menu_open = true,
        focus_id = "filter",
        callback = function()
            self:showPatchFilterDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = self:getPatchUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    -- Paginate installed-patch entries (see buildUpdateBrowserItems for why).
    local patch_items = self:buildPatchUpdateItems(summary)
    local page_size = getManagePageSize()
    local display_total = #patch_items
    local total_pages = math.max(1, math.ceil(display_total / page_size))
    local page = math.min(math.max(self.patch_updates_state.page or 1, 1), total_pages)
    if self.patch_updates_state.page ~= page then
        self.patch_updates_state.page = page
    end
    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(display_total, start_index + page_size - 1)
    for i = start_index, end_index do
        items[#items + 1] = patch_items[i]
        items[#items].separator = true
    end

    return items, total_pages
end

function Storefront:updateUpdatesDialog()
    if not self.updates_menu then
        return
    end
    if self.updates_menu.getScrollOffset then
        self:ensureUpdatesState()
        self.updates_state.scroll_offset = self.updates_menu:getScrollOffset()
    end
    self:closeUpdatesDialog(true)
    self:showUpdatesDialog()
end

-- Flip the installed-plugins dialog to another page: reset scroll to the top
-- (do not save the current offset) and rebuild. The builder clamps the page to
-- the valid range, so out-of-range requests settle on the nearest edge.
function Storefront:gotoUpdatesPage(page_num)
    self:ensureUpdatesState()
    local target = math.max(1, page_num or 1)
    if target == self.updates_state.page then
        return
    end
    self.updates_focus_hint = self:computePageFlipFocus(self.updates_menu, target > self.updates_state.page)
    self.updates_state.page = target
    self.updates_state.scroll_offset = nil
    -- Reset the live scroller to the top before closing: otherwise onCloseWidget's
    -- on_dismiss writes the current (old) offset back over the nil above, and the
    -- new page would open scrolled down, hiding its first rows.
    if self.updates_menu and self.updates_menu.resetScroll then
        self.updates_menu:resetScroll()
    end
    self:closeUpdatesDialog(true)
    -- A page flip doesn't change the dialog's title or overall chrome, only the
    -- list body, so it doesn't need the full flashing refresh that a genuine
    -- dialog-identity change (open/switch-tab/filter) uses to avoid ghosting.
    self._updates_refresh_mode_hint = "partial"
    self:showUpdatesDialog()
end

function Storefront:closeUpdatesDialog(skip_scroll_save)
    if self.updates_menu then
        if not skip_scroll_save and self.updates_menu.getScrollOffset then
            self:ensureUpdatesState()
            self.updates_state.scroll_offset = self.updates_menu:getScrollOffset()
        end
        UIManager:close(self.updates_menu)
        self.updates_menu = nil
    end
end

function Storefront:closePatchUpdatesDialog(skip_scroll_save)
    if self.patch_updates_menu then
        if not skip_scroll_save and self.patch_updates_menu.getScrollOffset then
            self:ensurePatchUpdatesState()
            self.patch_updates_state.scroll_offset = self.patch_updates_menu:getScrollOffset()
        end
        UIManager:close(self.patch_updates_menu)
        self.patch_updates_menu = nil
    end
end

function Storefront:showManagePluginPathsDialog()
    local hidden_paths = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
    local lookup_paths = PluginPaths.getLookupPaths()

    local button_dialog
    local buttons = {}
    for _, path in ipairs(lookup_paths) do
        local this_path = path -- upvalue capture per row
        local is_hidden = PluginPaths.isPathHidden(this_path, hidden_paths)
        local checkbox_text = is_hidden and "☐ " or "☑ "
        table.insert(buttons, {
            {
                text = checkbox_text .. this_path,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local current_hidden = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
                    local new_hidden = {}
                    local was_hidden = false
                    for _, h in ipairs(current_hidden) do
                        if PluginPaths.isPathHidden(this_path, { h }) then
                            was_hidden = true
                        else
                            table.insert(new_hidden, h)
                        end
                    end
                    if not was_hidden then
                        table.insert(new_hidden, this_path)
                    end
                    StorefrontSettings:saveSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY, new_hidden)
                    StorefrontSettings:flush()
                    UIManager:close(button_dialog)
                    UIManager:nextTick(function()
                        self:showManagePluginPathsDialog()
                    end)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
                self:closeUpdatesDialog(true)
                self:showUpdatesDialog()
            end,
        },
    })

    button_dialog = ButtonDialog:new{
        title = _("Manage plugin paths\n\nHiding a path only affects what Storefront shows/manages here. KOReader will still load plugins from it."),
        title_align = "center",
        buttons = buttons,
        -- Back-key / tap-outside dismissal doesn't go through the "Close"
        -- button's callback above, so refresh here too -- otherwise the
        -- installed-plugins list behind this dialog can look unchanged
        -- even though hide/show state was just toggled.
        tap_close_callback = function()
            self:closeUpdatesDialog(true)
            self:showUpdatesDialog()
        end,
    }
    UIManager:show(button_dialog)
end

function Storefront:showPluginUpdatesSettings()
    local button_dialog
    local buttons = {}

    if #PluginPaths.getLookupPaths() > 1 then
        table.insert(buttons, {
            {
                text = _("Manage plugin paths"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                    self:showManagePluginPathsDialog()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = string.format(_("Items per page: %d"), getManagePageSize()),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
                UIManager:show(SpinWidget:new{
                    title_text = _("Items per page"),
                    value = getManagePageSize(),
                    value_min = MIN_BROWSER_PAGE_SIZE,
                    value_max = MAX_BROWSER_PAGE_SIZE,
                    ok_text = _("Set"),
                    callback = function(spin)
                        StorefrontSettings:saveSetting(MANAGE_PAGE_SIZE_KEY, spin.value)
                        StorefrontSettings:flush()
                        self:ensureUpdatesState()
                        self.updates_state.page = 1
                        self.updates_state.scroll_offset = nil
                        -- Reset the open scroller before closing, else
                        -- on_dismiss saves the old offset back over the nil.
                        if self.updates_menu and self.updates_menu.resetScroll then
                            self.updates_menu:resetScroll()
                        end
                        self:closeUpdatesDialog(true)
                        self:showUpdatesDialog()
                    end,
                })
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
            end,
        },
    })

    button_dialog = ButtonDialog:new{
        title = _("Installed Plugins Settings"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

function Storefront:showUpdatesDialog()
    self:ensureUpdatesState()
    local summary = self:collectUpdateSummary()
    local entries, total_pages = self:buildUpdateBrowserItems(summary)
    local initial_focus = self.updates_focus_hint
    self.updates_focus_hint = nil
    local dialog = StorefrontBrowserDialog:new{
        title = _("App Store · Installed plugins"),
        items = entries,
        Storefront = self,
        page = self.updates_state.page or 1,
        total_pages = total_pages,
        initial_focus = initial_focus,
        on_settings_tap = function()
            self:showPluginUpdatesSettings()
        end,
        -- Hardware-keyboard hotkeys (r/f/t; no "s" here, this dialog has no sort).
        on_refresh = function() self:checkAllUpdates() end,
        on_filter = function() self:showPluginFilterDialog() end,
        on_switch_tab = function() self:showPatchUpdatesDialog() end,
        on_first_page = function() self:gotoUpdatesPage(1) end,
        on_prev_page = function() self:gotoUpdatesPage((self.updates_state.page or 1) - 1) end,
        on_next_page = function() self:gotoUpdatesPage((self.updates_state.page or 1) + 1) end,
        on_last_page = function() self:gotoUpdatesPage(total_pages) end,
        on_goto_page = function(page_num) self:gotoUpdatesPage(page_num) end,
        on_dismiss = function(scroll_offset)
            self.updates_menu = nil
            self:ensureUpdatesState()
            self.updates_state.scroll_offset = scroll_offset
        end,
    }
    self.updates_menu = dialog
    UIManager:show(dialog)
    if self.updates_state.scroll_offset then
        dialog:setScrollOffset(self.updates_state.scroll_offset)
    end
    -- Full (flashing) e-ink refresh by default: this dialog usually replaces
    -- another full-screen Storefront dialog (the browser, settings) and on devices
    -- that default to partial refresh (e.g. Kobo) the old frame ghosts through
    -- otherwise. Old Kindle controllers flash on every update, so this is
    -- effectively a no-op there. gotoUpdatesPage narrows this to a lighter
    -- "partial" refresh for plain page flips, where the title/chrome don't change.
    local refresh_mode = self._updates_refresh_mode_hint or "full"
    self._updates_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
end

function Storefront:showPatchUpdatesSettings()
    local button_dialog
    local buttons = {
        {
            {
                text = string.format(_("Items per page: %d"), getManagePageSize()),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Items per page"),
                        value = getManagePageSize(),
                        value_min = MIN_BROWSER_PAGE_SIZE,
                        value_max = MAX_BROWSER_PAGE_SIZE,
                        ok_text = _("Set"),
                        callback = function(spin)
                            StorefrontSettings:saveSetting(MANAGE_PAGE_SIZE_KEY, spin.value)
                            StorefrontSettings:flush()
                            self:ensurePatchUpdatesState()
                            self.patch_updates_state.page = 1
                            self.patch_updates_state.scroll_offset = nil
                            -- Reset the open scroller before closing, else
                            -- on_dismiss saves the old offset back over the nil.
                            if self.patch_updates_menu and self.patch_updates_menu.resetScroll then
                                self.patch_updates_menu:resetScroll()
                            end
                            self:closePatchUpdatesDialog(true)
                            self:showPatchUpdatesDialog()
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                end,
            },
        },
    }

    button_dialog = ButtonDialog:new{
        title = _("Installed Patches Settings"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

function Storefront:showPatchUpdatesDialog()
    self:ensurePatchUpdatesState()
    local prev_scroll = self.patch_updates_state.scroll_offset
    if self.patch_updates_menu and self.patch_updates_menu.getScrollOffset then
        prev_scroll = self.patch_updates_menu:getScrollOffset()
    end
    self.patch_updates_state.scroll_offset = prev_scroll
    self:closePatchUpdatesDialog(true)
    local summary = self:collectPatchUpdateSummary()
    local entries, total_pages = self:buildPatchUpdateBrowserItems(summary)
    local initial_focus = self.patch_updates_focus_hint
    self.patch_updates_focus_hint = nil
    local dialog = StorefrontBrowserDialog:new{
        title = _("App Store · Installed patches"),
        items = entries,
        Storefront = self,
        page = self.patch_updates_state.page or 1,
        total_pages = total_pages,
        initial_focus = initial_focus,
        on_settings_tap = function()
            self:showPatchUpdatesSettings()
        end,
        -- Hardware-keyboard hotkeys (r/f/t; no "s" here, this dialog has no sort).
        on_refresh = function() self:refreshPatchUpdates() end,
        on_filter = function() self:showPatchFilterDialog() end,
        on_switch_tab = function() self:showUpdatesDialog() end,
        on_first_page = function() self:gotoPatchUpdatesPage(1) end,
        on_prev_page = function() self:gotoPatchUpdatesPage((self.patch_updates_state.page or 1) - 1) end,
        on_next_page = function() self:gotoPatchUpdatesPage((self.patch_updates_state.page or 1) + 1) end,
        on_last_page = function() self:gotoPatchUpdatesPage(total_pages) end,
        on_goto_page = function(page_num) self:gotoPatchUpdatesPage(page_num) end,
        on_dismiss = function(scroll_offset)
            self.patch_updates_menu = nil
            self:ensurePatchUpdatesState()
            self.patch_updates_state.scroll_offset = scroll_offset
        end,
    }
    self.patch_updates_menu = dialog
    UIManager:show(dialog)
    if self.patch_updates_state.scroll_offset then
        dialog:setScrollOffset(self.patch_updates_state.scroll_offset)
    end
    -- Full refresh by default so the previous dialog does not ghost through on
    -- partial-refresh devices; narrowed to "partial" for plain page flips. See
    -- showUpdatesDialog for the rationale.
    local refresh_mode = self._patch_updates_refresh_mode_hint or "full"
    self._patch_updates_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
end

function Storefront:updatePatchUpdatesDialog()
    if not self.patch_updates_menu then
        return
    end
    if self.patch_updates_menu.getScrollOffset then
        self:ensurePatchUpdatesState()
        self.patch_updates_state.scroll_offset = self.patch_updates_menu:getScrollOffset()
    end
    self:closePatchUpdatesDialog(true)
    self:showPatchUpdatesDialog()
end

function Storefront:gotoPatchUpdatesPage(page_num)
    self:ensurePatchUpdatesState()
    local target = math.max(1, page_num or 1)
    if target == self.patch_updates_state.page then
        return
    end
    self.patch_updates_focus_hint = self:computePageFlipFocus(self.patch_updates_menu, target > self.patch_updates_state.page)
    self.patch_updates_state.page = target
    self.patch_updates_state.scroll_offset = nil
    -- Reset the live scroller to the top before closing (see gotoUpdatesPage):
    -- otherwise on_dismiss writes the old offset back over the nil above.
    if self.patch_updates_menu and self.patch_updates_menu.resetScroll then
        self.patch_updates_menu:resetScroll()
    end
    self:closePatchUpdatesDialog(true)
    -- See gotoUpdatesPage: a page flip doesn't change the dialog's title/chrome,
    -- so it doesn't need the full flashing refresh used elsewhere to avoid
    -- ghosting on a genuine dialog-identity change.
    self._patch_updates_refresh_mode_hint = "partial"
    self:showPatchUpdatesDialog()
end

function Storefront:toggleUpdatesFilter()
    self:ensureUpdatesState()
    self.updates_state.filter_only_outdated = not self.updates_state.filter_only_outdated
    self:updateUpdatesDialog()
end

function Storefront:toggleLinkedFilter()
    self:ensureUpdatesState()
    self.updates_state.filter_only_linked = not self.updates_state.filter_only_linked
    self:updateUpdatesDialog()
end

function Storefront:showPluginFilterDialog()
    self:ensureUpdatesState()
    local current_outdated = self.updates_state.filter_only_outdated
    local current_linked = self.updates_state.filter_only_linked

    local function makeCheckbox(enabled)
        return enabled and "☑ " or "☐ "
    end

    local buttons = {
        {
            {
                text = makeCheckbox(not current_outdated and not current_linked) .. _("All plugins"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = false
                    self.updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_outdated) .. _("Needs update"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = true
                    self.updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_linked) .. _("Linked only"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = false
                    self.updates_state.filter_only_linked = true
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                end,
            },
        },
    }

    self.plugin_filter_dialog = ButtonDialog:new{
        title = _("Filter Installed Plugins"),
        buttons = buttons,
    }
    UIManager:show(self.plugin_filter_dialog)
end

function Storefront:togglePatchUpdatesFilter()
    self:ensurePatchUpdatesState()
    self.patch_updates_state.filter_only_outdated = not self.patch_updates_state.filter_only_outdated
    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:togglePatchLinkedFilter()
    self:ensurePatchUpdatesState()
    self.patch_updates_state.filter_only_linked = not self.patch_updates_state.filter_only_linked
    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:showPatchFilterDialog()
    self:ensurePatchUpdatesState()
    local current_outdated = self.patch_updates_state.filter_only_outdated
    local current_linked = self.patch_updates_state.filter_only_linked

    local function makeCheckbox(enabled)
        return enabled and "☑ " or "☐ "
    end

    local buttons = {
        {
            {
                text = makeCheckbox(not current_outdated and not current_linked) .. _("All patches"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = false
                    self.patch_updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_outdated) .. _("Needs update"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = true
                    self.patch_updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_linked) .. _("Linked only"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = false
                    self.patch_updates_state.filter_only_linked = true
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                end,
            },
        },
    }

    self.patch_filter_dialog = ButtonDialog:new{
        title = _("Filter Installed Patches"),
        buttons = buttons,
    }
    UIManager:show(self.patch_filter_dialog)
end



function Storefront:_scanUpdatesForDirectApi(tracked)
    NetworkMgr:runWhenOnline(function()
        local CatalogClient = require("storefront_net_catalog")
        CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
            if ok then
                self:softRefreshCurrentBrowserView()
            end
        end)

        local Trapper = require("ui/trapper")
        local ltn12 = require("ltn12")
        local GitHub = require("storefront_net_github")
        local ok_su, socketutil = pcall(require, "socketutil")
        if not ok_su or not socketutil then
            socketutil = {
                FILE_BLOCK_TIMEOUT = 15,
                FILE_TOTAL_TIMEOUT = 30,
                set_timeout = function() end,
                reset_timeout = function() end,
            }
        end

        local function getHttpModule(url_str)
            if url_str and url_str:match("^https://") then
                local ok_https, https = pcall(require, "ssl.https")
                if ok_https and https then return https end
            end
            return require("socket.http")
        end

        local function parseGitHubTimestampWorker(ts)
            if type(ts) ~= "string" or ts == "" then
                return 0
            end
            local year, month, day, hour, min, sec = ts:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
            if not year then
                return 0
            end
            return os.time{
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec),
            }
        end

        local function fetchGitHubRawWorker(owner, repo_name, branch, path)
            if not owner or not repo_name or not path or path == "" then
                return nil, "Missing repository metadata for remote fetch."
            end
            branch = branch or "HEAD"
            local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo_name, branch, path)
            local response = {}
            local http_mod = getHttpModule(url)
            local code
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            pcall(function()
                _, code = http_mod.request{
                    url = url,
                    sink = ltn12.sink.table(response),
                    headers = {
                        ["User-Agent"] = "KOReader-Storefront",
                        ["Accept"] = "text/plain",
                    },
                }
            end)
            socketutil:reset_timeout()
            code = tonumber(code)
            if code ~= 200 then
                return nil, string.format("HTTP %s", tostring(code))
            end
            return table.concat(response)
        end

        local function extractMetaFieldWorker(source, field)
            if type(source) ~= "string" or source == "" or type(field) ~= "string" then
                return nil
            end
            -- Match lines like: field = "value" or field='value'
            local pattern = field .. "%s*=%s*['\"]([^'\"]+)['\"]"
            return source:match(pattern)
        end

        local function derivePluginRepoPathWorker(plugin_root)
            if not plugin_root or plugin_root == "" then
                return nil
            end
            local plugins_match = plugin_root:match("(plugins/.*)")
            if plugins_match and plugins_match ~= "" then
                return plugins_match
            end
            local koplugin_match = plugin_root:match("(%w[%w_%-%.]*%.koplugin.*)") or plugin_root:match("([^/]+%.koplugin.*)")
            if koplugin_match and koplugin_match ~= "" then
                return koplugin_match
            end
            local without_root = plugin_root
            local slash = without_root:find("/")
            if slash then
                without_root = without_root:sub(slash + 1)
            end
            if without_root and without_root ~= "" then
                return without_root
            end
            return plugin_root
        end

        local function normalizeMetaPathWorker(path)
            if not path or path == "" then
                return nil
            end
            local normalized = path:gsub("^/+", "")
            if normalized:match("/_meta%.lua$") then
                return normalized
            end
            if not normalized:match("%.koplugin$") then
                normalized = normalized .. ".koplugin"
            end
            return normalized .. "/_meta.lua"
        end

        local function buildMetaPathCandidatesWorker(record)
            if not record then
                return {}
            end
            local seen = {}
            local candidates = {}
            local function add(path)
                if not path or path == "" then
                    return
                end
                local normalized = normalizeMetaPathWorker(path)
                if not normalized or seen[normalized] then
                    return
                end
                seen[normalized] = true
                table.insert(candidates, normalized)
            end

            add(record.meta_path)
            if record.meta_path then
                add(derivePluginRepoPathWorker(record.meta_path))
            end
            add(record.meta_path_hint)

            if record.meta_path then
                local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
                add(trimmed)
                add(derivePluginRepoPathWorker(trimmed))
            end
            if record.meta_path_hint then
                local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
                add(trimmed)
            end

            if record.dirname and record.dirname ~= "" then
                add("plugins/" .. record.dirname .. "/_meta.lua")
                add(record.dirname .. "/_meta.lua")
                if record.dirname:match("%.koplugin$") then
                    local without_suffix = record.dirname:gsub("%.koplugin$", "")
                    add("plugins/" .. without_suffix .. "/_meta.lua")
                    add(without_suffix .. "/_meta.lua")
                end
            end

            add("plugins/_meta.lua")
            add("_meta.lua")

            return candidates
        end

        local function runCheckAllUpdatesWorker(records_worker)
            local result = {}
            for _, record in ipairs(records_worker or {}) do
                local dirname = record.dirname
                local owner = record.owner
                local repo_name = record.repo
                local remote_version
                local remote_repo_ts = 0
                local release_tag_name
                local release_published_at
                local last_err

                if not owner or not repo_name then
                    last_err = "Missing repository info."
                else
                    local is_storefront_worker = dirname == "storefront.koplugin"
                        or (repo_name and repo_name:lower():match("storefront%.koplugin"))
                    local allow_beta_worker = false
                    if is_storefront_worker then
                        local ok_ab, about_dialog = pcall(require, "storefront_about_dialog")
                        if ok_ab and about_dialog and type(about_dialog.getChannel) == "function" then
                            allow_beta_worker = about_dialog.getChannel() == "beta"
                        end
                    end
                    local allow_prerelease = allow_beta_worker or isPreReleaseAllowedForPlugin(nil, record, dirname)
                    if allow_prerelease then
                        local releases, fetch_err = GitHub.fetchReleases(owner, repo_name, {
                            per_page = 10,
                            max_pages = 1,
                        })
                        if releases and #releases > 0 then
                            for _, release in ipairs(releases) do
                                if not release.draft then
                                    release_tag_name = release.tag_name
                                    release_published_at = parseGitHubTimestampWorker(release.published_at)
                                    break
                                end
                            end
                        end
                    end

                    -- Check live GitHub release if not found via prerelease check
                    if not release_tag_name then
                        local latest_release, release_err = GitHub.fetchLatestRelease(owner, repo_name)
                        if latest_release and latest_release.tag_name then
                            if not latest_release.prerelease and not latest_release.draft then
                                local tag_lower = latest_release.tag_name:lower()
                                local is_prerelease_tag = tag_lower:find("alpha", 1, true) or 
                                                          tag_lower:find("beta", 1, true) or 
                                                          tag_lower:find("rc", 1, true) or 
                                                          tag_lower:find("dev", 1, true) or 
                                                          tag_lower:find("preview", 1, true) or 
                                                          tag_lower:find("test", 1, true)
                                if not is_prerelease_tag then
                                    release_tag_name = latest_release.tag_name
                                    release_published_at = parseGitHubTimestampWorker(latest_release.published_at)
                                end
                            end
                        end
                    end

                    if not release_tag_name then
                        local releases, fetch_err = GitHub.fetchReleases(owner, repo_name, {
                            per_page = 30,
                            max_pages = 1,
                        })
                        if releases and #releases > 0 then
                            for _, release in ipairs(releases) do
                                if not release.draft and not release.prerelease then
                                    local tag_lower = release.tag_name:lower()
                                    local is_prerelease_tag = tag_lower:find("alpha", 1, true) or 
                                                              tag_lower:find("beta", 1, true) or 
                                                              tag_lower:find("rc", 1, true) or 
                                                              tag_lower:find("dev", 1, true) or 
                                                              tag_lower:find("preview", 1, true) or 
                                                              tag_lower:find("test", 1, true)
                                    if not is_prerelease_tag then
                                        release_tag_name = release.tag_name
                                        release_published_at = parseGitHubTimestampWorker(release.published_at)
                                        break
                                    end
                                end
                            end
                        end
                    end

                    -- Fallback to static catalog cache if live GitHub releases fetch returned nothing
                    if not release_tag_name then
                        local cached_repo = Cache.getRepoByName(owner, repo_name) or (record.repo_id and Cache.getRepo(record.repo_id))
                        if cached_repo then
                            local rel = cached_repo.latest_release or (cached_repo.data and cached_repo.data.latest_release)
                            if rel and rel.tag_name then
                                release_tag_name = rel.tag_name
                                release_published_at = parseGitHubTimestampWorker(rel.published_at)
                            end
                            if not release_tag_name and cached_repo.version then
                                release_tag_name = cached_repo.version
                            end
                            local ts = cached_repo.data and (cached_repo.data.pushed_at or cached_repo.data.created_at)
                            remote_repo_ts = parseGitHubTimestampWorker(ts)
                        end
                    end

                    local metadata, metadata_err = GitHub.fetchRepoMetadata(owner, repo_name)
                    if metadata and type(metadata) == "table" then
                        local ts = metadata.pushed_at or metadata.created_at
                        remote_repo_ts = parseGitHubTimestampWorker(ts)
                    end

                    if release_tag_name then
                        last_err = nil
                    else
                        local meta_path = record.meta_path
                        if (not meta_path or meta_path == "") and dirname and dirname ~= "" then
                            meta_path = dirname .. "/_meta.lua"
                        end

                        local branch = record.branch
                        if (not branch or branch == "") and metadata and type(metadata) == "table" then
                            branch = metadata.default_branch or metadata.master_branch or "HEAD"
                        end

                        local candidates = buildMetaPathCandidatesWorker and buildMetaPathCandidatesWorker(record) or {}
                        if #candidates == 0 and meta_path then
                            table.insert(candidates, meta_path)
                        end

                        local found_body = nil
                        local working_meta_path = nil
                        for _, candidate in ipairs(candidates) do
                            local body, err = fetchGitHubRawWorker(owner, repo_name, branch, candidate)
                            if body then
                                found_body = body
                                working_meta_path = candidate
                                last_err = nil
                                break
                            else
                                last_err = err or last_err
                            end
                        end

                        if found_body then
                            local version = extractMetaFieldWorker(found_body, "version")
                            if version then
                                remote_version = version
                                last_err = nil
                                if working_meta_path and working_meta_path ~= record.meta_path then
                                    record.meta_path = working_meta_path
                                    pcall(function() InstallStore.upsert(dirname, record) end)
                                end
                            else
                                last_err = "Remote version not found."
                            end
                        else
                            last_err = last_err or "Missing meta path in record."
                        end
                    end
                end

                if dirname and dirname ~= "" then
                    result[dirname] = {
                        remote_version = (type(remote_version) == "string") and remote_version or nil,
                        remote_repo_ts = tonumber(remote_repo_ts) or 0,
                        release_tag_name = (type(release_tag_name) == "string") and release_tag_name or nil,
                        release_published_at = (type(release_published_at) == "string") and release_published_at or nil,
                        error = (type(last_err) == "string") and last_err or (last_err and tostring(last_err) or nil),
                        last_checked = os.time(),
                    }
                end
            end
            return result
        end

        local Toast = require("storefront_toast")
        local progress_toast = Toast.show(_("Checking plugin updates…"), 0)

        Trapper:wrap(function()
            local completed, remote_info_result = Trapper:dismissableRunInSubprocess(function()
                local ok, res = pcall(runCheckAllUpdatesWorker, tracked)
                if ok and type(res) == "table" then
                    return res
                end
                return {}
            end, progress_toast)

            if progress_toast and progress_toast.close then
                progress_toast:close()
            end

            if not completed then
                Toast.show(_("Update check was cancelled."), 3)
                return
            end

            self:ensureUpdatesState()
            local remote_info = self.updates_state.remote_info or {}
            for dirname, data in pairs(remote_info_result or {}) do
                remote_info[dirname] = data
            end
            self.updates_state.remote_info = remote_info
            self.updates_state.last_checked = os.time()
            
            StorefrontLogger.action(string.format("REMOTE UPDATE CHECK FINISHED: %d records processed", #tracked))
            for dirname, data in pairs(remote_info_result or {}) do
                local msg = string.format(
                    "REMOTE UPDATE CHECK RECORD: %s -> tag=%s, remote_version=%s, err=%s",
                    tostring(dirname),
                    tostring(data.release_tag_name or "-"),
                    tostring(data.remote_version or "-"),
                    tostring(data.error or "none")
                )
                if data.error then
                    StorefrontLogger.warn(msg)
                else
                    StorefrontLogger.debug(msg)
                end
            end

            invalidateInstalledPluginsCache()
            self._cached_plugin_summary = nil
            self._merged_updates_cache = nil
            self:updateUpdatesDialog()
            self:refreshCurrentBrowserTab()
            self:saveUpdatesState()
            
            local checked_count = #tracked
            Toast.show(string.format(_("Checked %d plugin(s) for updates."), checked_count), 3)
        end)
    end)
end

function Storefront:_checkAllUpdatesInternal(records)
    if not self.browser_menu then return end
    return self:_scanUpdatesForDirectApi(records)
end



local function findLatestRelease(owner, repo, allow_prerelease)
    local GitHub = require("storefront_net_github")

    if allow_prerelease then
        local releases, fetch_err = GitHub.fetchReleases(owner, repo, {
            per_page = 10,
            max_pages = 1,
        })
        if releases and #releases > 0 then
            for _, release in ipairs(releases) do
                if not release.draft then
                    return release, nil
                end
            end
        end
    end

    local latest, err = GitHub.fetchLatestRelease(owner, repo)

    if latest and latest.tag_name then
        if not latest.prerelease and not latest.draft then
            if not isPreReleaseTag(latest.tag_name) then
                return latest, nil
            end
        end
    end

    local releases, fetch_err = GitHub.fetchReleases(owner, repo, {
        per_page = 30,
        max_pages = 1,
    })

    if not releases or #releases == 0 then
        return nil, fetch_err or err or "No releases found"
    end

    for _, release in ipairs(releases) do
        if not release.draft and not release.prerelease then
            if not isPreReleaseTag(release.tag_name) then
                return release, nil
            end
        end
    end

    return nil, "No stable release found"
end

-- Pure network-fetching core of fetchRemoteVersionForRecord below -- touches
-- no `self` state, so it's safe to run inside a forked subprocess (see
-- Storefront:_checkSinglePluginInternal, which does exactly that so a slow
-- or unreachable repo can't block the UI thread for several seconds).
-- Returns remote_version, remote_repo_ts, err, release_tag_name,
-- updated_meta_path, updated_branch -- the last two are only set when a
-- meta_path/branch different from the record's own is the one that worked.
local function fetchRemoteVersionCore(record)
    if not record or not record.owner or not record.repo then
        return nil, 0, _("Not matched with a repository.")
    end

    local owner = record.owner
    local repo_name = record.repo
    local last_err

    local is_storefront = record.dirname == "storefront.koplugin"
        or (record.repo and record.repo:lower():match("storefront%.koplugin"))
    local allow_beta = is_storefront and (require("storefront_about_dialog").getChannel() == "beta")
    local allow_prerelease = allow_beta or isPreReleaseAllowedForPlugin(nil, record, record and record.dirname)

    local latest_release = findLatestRelease(owner, repo_name, allow_prerelease)

    if latest_release and latest_release.tag_name then
        local release_version = parseVersionFromTag(latest_release.tag_name)
        local release_ts = parseGitHubTimestamp(latest_release.published_at)
        return release_version, release_ts, nil, latest_release.tag_name
    end

    local meta_candidates = buildMetaPathCandidates(record)
    if #meta_candidates == 0 then
        return nil, 0, _("Missing meta path in record.")
    end

    local branch_candidates = buildBranchCandidates(record)
    local remote_repo_ts = 0
    local metadata, metadata_err = GitHub.fetchRepoMetadata(owner, repo_name)
    if metadata and type(metadata) == "table" then
        local ts = metadata.pushed_at or metadata.created_at
        remote_repo_ts = parseGitHubTimestamp(ts)
    else
        last_err = metadata_err or last_err
    end

    for _idx, meta_path in ipairs(meta_candidates) do
        for _bidx, branch in ipairs(branch_candidates) do
            local body, err = fetchGitHubRaw(owner, repo_name, branch, meta_path)
            if body then
                local version = extractMetaField(body, "version")
                if version then
                    local updated_meta_path, updated_branch
                    if record.dirname and (record.meta_path ~= meta_path or record.branch ~= branch) then
                        updated_meta_path, updated_branch = meta_path, branch
                    end
                    return version, remote_repo_ts, nil, nil, updated_meta_path, updated_branch
                end
                last_err = _("Remote version not found.")
            else
                last_err = err or _("HTTP error")
                if not (err and tostring(err):find("404", 1, true)) then
                    return nil, remote_repo_ts, last_err
                end
            end
        end
    end

    if last_err then
        local msg = tostring(last_err)
        if msg:find("404", 1, true) or msg == _("Remote version not found.") then
            return nil, remote_repo_ts, nil
        end
    end

    return nil, remote_repo_ts, last_err or _("Remote version not found.")
end

-- Applies the `self`-touching side effects that fetchRemoteVersionCore
-- itself can't (see its comment) -- shared by fetchRemoteVersionForRecord
-- and _checkSinglePluginInternal, the latter calling it on the parent
-- process only after its subprocess worker has already returned.
function Storefront:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, updated_meta_path, updated_branch)
    if release_tag_name then
        self:ensureUpdatesState()
        local dirname = record.dirname
        if dirname then
            local cached = self.updates_state.remote_info[dirname] or {}
            cached.release_tag_name = release_tag_name
            cached.release_published_at = remote_repo_ts
            self.updates_state.remote_info[dirname] = cached
        end
    elseif updated_meta_path then
        self:updateInstallRecord(record.dirname, { meta_path = updated_meta_path, branch = updated_branch })
        record.meta_path = updated_meta_path
        record.branch = updated_branch
    end
end

function Storefront:fetchRemoteVersionForRecord(record)
    local remote_version, remote_repo_ts, err, release_tag_name, updated_meta_path, updated_branch =
        fetchRemoteVersionCore(record)
    self:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, updated_meta_path, updated_branch)
    return remote_version, remote_repo_ts, err, release_tag_name
end

function Storefront:getUnmatchedPlugins()
    local records = getInstallRecordsMap()
    local installed = listInstalledPlugins()
    local unmatched = {}
    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        if not (record and record.owner and record.repo) then
            table.insert(unmatched, plugin)
        end
    end
    return unmatched
end

function Storefront:startMatchFlow()
    local unmatched = self:getUnmatchedPlugins()
    if #unmatched == 0 then
        UIManager:show(InfoMessage:new{ text = _("All plugins are already matched."), timeout = 4 })
        return
    end
    local lines = {}
    for idx, plugin in ipairs(unmatched) do
        lines[#lines + 1] = string.format("%d. %s (%s)", idx, plugin.name or plugin.dirname, plugin.dirname)
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Select plugin to match"),
        description = table.concat(lines, "\n"),
        input_hint = _("Enter plugin number"),
        input_type = "number",
        buttons = {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    if not value or value < 1 or value > #unmatched then
                        UIManager:show(InfoMessage:new{ text = _("Invalid selection."), timeout = 3 })
                        return
                    end
                    UIManager:close(dialog)
                    self:startMatchFlowForPlugin(unmatched[value])
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:startMatchFlowForPlugin(plugin)
    if not plugin then
        return
    end
    self.match_context = { kind = "plugin", plugin = plugin }
    self:ensureBrowserState()
    self.browser_state.kind = "plugin"
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    
    local search_text = plugin.dirname or ""
    if search_text ~= "" then
        search_text = search_text:gsub("%.koplugin$", "")
        self.browser_state.search_text = search_text
    end
    
    self:saveBrowserState()
    self:closeUpdatesDialog()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{ text = _("Select a repository to match with the chosen plugin."), timeout = 4 })
    self:showBrowser("plugin")
end

function Storefront:matchPluginWithRepo(plugin, repo)
    if not plugin or not repo then
        return
    end
    StorefrontLogger.action(string.format("MATCH plugin: %s matched with repo %s", tostring(plugin.dirname), tostring(repo.full_name or repo.name)))
    local record = buildInstallRecordFields(
        plugin.dirname,
        plugin.name,
        plugin.version,
        repo,
        sanitizeMetaPath(plugin.meta_path_hint or (plugin.dirname .. "/_meta.lua"), plugin.dirname)
    )
    if not record then
        UIManager:show(InfoMessage:new{ text = _("Unable to store match for plugin."), timeout = 4 })
        return
    end
    InstallStore.upsert(plugin.dirname, record)
    self.match_context = nil
    self:closeBrowserMenu()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Matched %s with %s."), plugin.name or plugin.dirname, repo.full_name or repo.name or _("repository")),
        timeout = 5,
    })
    if self.updates_menu then
        self:updateUpdatesDialog()
    else
        self:showUpdatesDialog()
    end
end

function Storefront:promptManualMatchForPlugin(plugin)
    if not plugin then
        return
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Match plugin with GitHub repository"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Match"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:verifyAndMatchPluginWithManualRepo(plugin, owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:verifyAndMatchPluginWithManualRepo(plugin, owner, repo_name)
    if not plugin or not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Verifying repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        UIManager:close(progress)
        
        if not repo_data or not repo_data.id then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "plugin",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        self:matchPluginWithRepo(plugin, repo)
    end)
end

function Storefront:promptUpdateAction(plugin, record)
    local lines = {
        string.format("%s (%s)", plugin.name or plugin.dirname, plugin.dirname),
        string.format(_("Local version: %s"), plugin.version or _("unknown")),
    }
    if record and record.owner and record.repo then
        table.insert(lines, string.format(_("Matched repo: %s/%s"), record.owner, record.repo))
    else
        table.insert(lines, _("Not matched with a repository."))
    end
    local info_box
    local other_buttons = {}
    local other_buttons_row2 = {}
    
    if record and record.owner and record.repo then
        table.insert(other_buttons, {
            text = _("Check this plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePlugin(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:updatePluginFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Unlink the repo"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                -- Clear repo info but preserve installed_version for future re-matching
                local existing = InstallStore.get(plugin.dirname)
                local preserved_version = existing and existing.installed_version
                
                -- Clear ignored release for this repo
                if record.owner and record.repo then
                    clearIgnoredRelease(record.owner, record.repo)
                end
                
                InstallStore.remove(plugin.dirname)
                if preserved_version then
                    -- Store minimal record with just dirname and version
                    InstallStore.upsert(plugin.dirname, {
                        dirname = plugin.dirname,
                        plugin_name = plugin.name,
                        installed_version = preserved_version,
                    })
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Unlinked %s from repository."), plugin.name or plugin.dirname),
                    timeout = 3,
                })
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
                self:promptUpdateAction(plugin, nil)
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match from List"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:startMatchFlowForPlugin(plugin)
            end,
        })
        table.insert(other_buttons, {
            text = _("Match with URL"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:promptManualMatchForPlugin(plugin)
            end,
        })
    end
    
    local is_disabled = isPluginDisabled(plugin.dirname)
    if is_disabled then
        table.insert(other_buttons_row2, {
            text = _("Enable plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:enablePlugin(plugin.dirname)
                showRestartConfirmation(string.format(_("Plugin '%s' enabled."), plugin.name or plugin.dirname))
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end,
        })
    else
        table.insert(other_buttons_row2, {
            text = _("Disable plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:disablePlugin(plugin.dirname)
                showRestartConfirmation(string.format(_("Plugin '%s' disabled."), plugin.name or plugin.dirname))
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end,
        })
    end
    
    table.insert(other_buttons_row2, {
        text = _("Modify Plugin"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:modifyPlugin(plugin)
        end,
    })

    table.insert(other_buttons_row2, {
        text = _("Delete plugin"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:deletePlugin(plugin.dirname, record)
        end,
    })

    info_box = ConfirmBox:new{
        text = plugin.name or plugin.dirname,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons, other_buttons_row2 },
    }
    UIManager:show(info_box)
end

function Storefront:promptPatchUpdateAction(patch_item)
    if not patch_item or not patch_item.patch then
        return
    end
    local patch = patch_item.patch
    local record = patch_item.record
    local remote_entry = patch_item.remote_entry
    local lines = {
        string.format("• %s", patch.filename or patch.path or _("patch")),
    }
    if record and record.owner and record.repo then
        table.insert(lines, string.format(_("Matched repo: %s/%s"), record.owner, record.repo))
        if record.path then
            table.insert(lines, string.format(_("Path: %s"), record.path))
        end
        if record.branch then
            table.insert(lines, string.format(_("Branch: %s"), record.branch))
        end
    else
        table.insert(lines, _("Not matched with a repository."))
    end
    if patch_item.local_sha then
        table.insert(lines, string.format(_("Local SHA: %s"), patch_item.local_sha:sub(1, 8)))
    end
    table.insert(lines, formatPatchRemoteStatus(remote_entry))
    if patch_item.needs_update then
        table.insert(lines, _("Status: Update available"))
    elseif record and record.owner and record.repo then
        table.insert(lines, _("Status: Up to date"))
    else
        table.insert(lines, _("Status: Needs matching"))
    end

    local info_box
    local other_buttons = {}
    local other_buttons_row2 = {}
    
    if record and record.owner and record.repo and record.path then
        table.insert(other_buttons, {
            text = _("Check this patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePatch(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:updatePatchFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Unlink the repo"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                -- Clear repo info but preserve SHA so it can be used when re-matching
                local existing = InstallStore.getPatch(patch.filename)
                local preserved_sha = existing and existing.sha
                InstallStore.removePatch(patch.filename)
                if preserved_sha then
                    -- Store minimal record with just filename and SHA
                    InstallStore.upsertPatch(patch.filename, {
                        filename = patch.filename,
                        sha = preserved_sha,
                    })
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Unlinked %s from repository."), patch.filename),
                    timeout = 3,
                })
                if self.patch_updates_menu then
                    self:updatePatchUpdatesDialog()
                end
                self:promptPatchUpdateAction({ patch = patch, record = nil, remote_entry = nil, needs_update = false })
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match from List"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:startPatchMatchFlow(patch)
            end,
        })
        table.insert(other_buttons, {
            text = _("Match with URL"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:promptManualMatchForPatch(patch)
            end,
        })
    end
    
    local is_disabled = patch.disabled or isPatchDisabled(patch.filename)
    if is_disabled then
        table.insert(other_buttons_row2, {
            text = _("Enable patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                local ok = self:enablePatch(patch.filename)
                if ok then
                    showRestartConfirmation(string.format(_("Patch '%s' enabled."), patch.filename))
                    if self.patch_updates_menu then
                        self:updatePatchUpdatesDialog()
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to enable patch '%s'."), patch.filename),
                        timeout = 4,
                    })
                end
            end,
        })
    else
        table.insert(other_buttons_row2, {
            text = _("Disable patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                local ok = self:disablePatch(patch.filename)
                if ok then
                    showRestartConfirmation(string.format(_("Patch '%s' disabled."), patch.filename))
                    if self.patch_updates_menu then
                        self:updatePatchUpdatesDialog()
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to disable patch '%s'."), patch.filename),
                        timeout = 4,
                    })
                end
            end,
        })
    end
    
    table.insert(other_buttons_row2, {
        text = _("Modify Patch"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            local patch_path = PATCHES_ROOT .. "/" .. patch.filename
            local PluginLoader = require("pluginloader")
            local te = PluginLoader:getPluginInstance("texteditor")
            if te and te.checkEditFile then
                te:checkEditFile(patch_path)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Text editor plugin is not available."),
                    timeout = 4,
                })
            end
        end,
    })

    table.insert(other_buttons_row2, {
        text = _("Delete patch"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:deletePatch(patch.filename, record)
        end,
    })

    info_box = ConfirmBox:new{
        text = patch.filename or patch.path or _("Patch"),
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons, other_buttons_row2 },
    }
    UIManager:show(info_box)
end

-- ─── Modify Plugin ────────────────────────────────────────────────────────────

function Storefront:modifyPlugin(plugin)
    if not plugin or not plugin.dirname then
        return
    end
    self:showPluginFilesDialog(plugin, true)
end

function Storefront:showPluginFilesDialog(plugin, filter_config_only)
    local plugin_path = plugin.path
    if lfs.attributes(plugin_path, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Plugin directory not found."),
            timeout = 3,
        })
        return
    end

    -- Collect all .lua files recursively
    local all_files = {}
    local function scan_dir(dir, prefix)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local rel  = (prefix == "") and entry or (prefix .. "/" .. entry)
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    scan_dir(full, rel)
                elseif mode == "file" and entry:match("%.lua$") then
                    table.insert(all_files, { path = full, name = entry, rel = rel })
                end
            end
        end
    end
    scan_dir(plugin_path, "")
    table.sort(all_files, function(a, b) return a.rel < b.rel end)

    -- Apply filter
    local filtered = {}
    if filter_config_only then
        for _, f in ipairs(all_files) do
            if f.name:lower():find("config", 1, true) then
                table.insert(filtered, f)
            end
        end
    else
        filtered = all_files
    end

    local dialog
    local buttons = {}

    -- Toggle filter checkbox row
    local filter_label = filter_config_only
        and ("\xE2\x98\x91 " .. _("Config files only"))
        or  ("\xE2\x98\x90 " .. _("Config files only"))
    table.insert(buttons, {
        {
            text = filter_label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showPluginFilesDialog(plugin, not filter_config_only)
            end,
        },
    })

    if #filtered == 0 then
        local msg = filter_config_only
            and _("No config files found — uncheck filter to show all files")
            or  _("No Lua files found in plugin directory")
        table.insert(buttons, {
            {
                text = msg,
                background = Blitbuffer.COLOR_WHITE,
                callback = function() end,
            },
        })
    else
        for _, f in ipairs(filtered) do
            local file = f  -- upvalue capture
            table.insert(buttons, {
                {
                    text = file.rel,
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                        self:showPluginFileActionDialog(plugin, file.path, file.name, filter_config_only)
                    end,
                },
            })
        end
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = string.format(_("Modify Plugin: %s"), plugin.name or plugin.dirname),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Storefront:showPluginFileActionDialog(plugin, filepath, filename, filter_config_only)
    local dialog
    local buttons = {}

    -- Edit
    table.insert(buttons, {
        {
            text = _("Edit"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local PluginLoader = require("pluginloader")
                local te = PluginLoader:getPluginInstance("texteditor")
                if te and te.checkEditFile then
                    te:checkEditFile(filepath)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Text editor plugin is not available."),
                        timeout = 4,
                    })
                end
            end,
        },
    })

    -- Copy
    table.insert(buttons, {
        {
            text = _("Copy"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local copy_dialog
                copy_dialog = InputDialog:new{
                    title = _("Copy file as"),
                    input = filename,
                    input_hint = _("New filename"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(copy_dialog)
                                end,
                            },
                            {
                                text = _("Copy"),
                                is_enter_default = true,
                                callback = function()
                                    local new_name = util.trim(copy_dialog:getInputText() or "")
                                    if new_name == "" then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Filename cannot be empty."),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    local dir = filepath:match("^(.*)[\\/]")
                                    local new_path = dir .. "/" .. new_name
                                    local src = io.open(filepath, "rb")
                                    if not src then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Cannot read source file."),
                                            timeout = 3,
                                        })
                                        UIManager:close(copy_dialog)
                                        return
                                    end
                                    local content = src:read("*all")
                                    src:close()
                                    local dst = io.open(new_path, "wb")
                                    if not dst then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Cannot write destination file."),
                                            timeout = 3,
                                        })
                                        UIManager:close(copy_dialog)
                                        return
                                    end
                                    dst:write(content)
                                    dst:close()
                                    UIManager:close(copy_dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("Copied to '%s'."), new_name),
                                        timeout = 3,
                                    })
                                    self:showPluginFilesDialog(plugin, filter_config_only)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(copy_dialog)
                copy_dialog:onShowKeyboard()
            end,
        },
    })

    -- Rename
    table.insert(buttons, {
        {
            text = _("Rename"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local rename_dialog
                rename_dialog = InputDialog:new{
                    title = _("Rename file"),
                    input = filename,
                    input_hint = _("New filename"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(rename_dialog)
                                end,
                            },
                            {
                                text = _("Rename"),
                                is_enter_default = true,
                                callback = function()
                                    local new_name = util.trim(rename_dialog:getInputText() or "")
                                    if new_name == "" then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Filename cannot be empty."),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    local dir = filepath:match("^(.*)[\\/]")
                                    local new_path = dir .. "/" .. new_name
                                    local ok, err = os.rename(filepath, new_path)
                                    if not ok then
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Rename failed: %s"), tostring(err)),
                                            timeout = 4,
                                        })
                                    else
                                        UIManager:close(rename_dialog)
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Renamed to '%s'."), new_name),
                                            timeout = 3,
                                        })
                                        self:showPluginFilesDialog(plugin, filter_config_only)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(rename_dialog)
                rename_dialog:onShowKeyboard()
            end,
        },
    })

    -- Delete
    table.insert(buttons, {
        {
            text = _("Delete"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showConfirmDialog{
                    title = _("Delete File?"),
                    text = string.format(_("Delete file '%s'?\n\nThis cannot be undone."), filename),
                    ok_text = _("Delete"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local ok, err = os.remove(filepath)
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Deleted '%s'."), filename),
                                timeout = 3,
                            })
                            self:showPluginFilesDialog(plugin, filter_config_only)
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to delete: %s"), tostring(err)),
                                timeout = 4,
                            })
                        end
                    end,
                }
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = filename,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ─── End Modify Plugin ────────────────────────────────────────────────────────




function Storefront:checkSinglePlugin(record)
    if not record then
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:_checkSinglePluginInternal(record)
    end)
end

function Storefront:checkSinglePatch(record)
    if not record then
        return
    end
    local patch_name = record.filename or record.path or _("patch")
    local copy = util.tableDeepCopy(record)
    copy.filename = record.filename
    copy.owner = record.owner
    copy.repo = record.repo
    copy.path = record.path
    copy.branch = record.branch
    NetworkMgr:runWhenOnline(function()
        self:_refreshPatchUpdatesInternal({ copy })
    end)
    UIManager:show(InfoMessage:new{ text = string.format(_("Checking %s…"), patch_name), timeout = 3 })
end

function Storefront:_checkSinglePluginInternal(record)
    self:ensureUpdatesState()
    local plugin_name = record.dirname or _("plugin")
    local Trapper = require("ui/trapper")
    local Toast = require("storefront_toast")
    local progress_toast = Toast.show(string.format(_("Checking %s…"), plugin_name), 0)

    Trapper:wrap(function()
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            local remote_version, remote_repo_ts, err, release_tag_name, updated_meta_path, updated_branch =
                fetchRemoteVersionCore(record)
            return {
                remote_version = (type(remote_version) == "string") and remote_version or nil,
                remote_repo_ts = tonumber(remote_repo_ts) or 0,
                err = (type(err) == "string") and err or (err and tostring(err) or nil),
                release_tag_name = (type(release_tag_name) == "string") and release_tag_name or nil,
                updated_meta_path = (type(updated_meta_path) == "string") and updated_meta_path or nil,
                updated_branch = (type(updated_branch) == "string") and updated_branch or nil,
            }
        end, progress_toast)

        if progress_toast and progress_toast.close then
            progress_toast:close()
        end

        if not completed then
            Toast.show(_("Update check was cancelled."), 3)
            return
        end
        if type(result) ~= "table" then
            return
        end

        local remote_version = result.remote_version
        local remote_repo_ts = result.remote_repo_ts
        local err = result.err
        local release_tag_name = result.release_tag_name
        self:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, result.updated_meta_path, result.updated_branch)

        local cached = self.updates_state.remote_info[record.dirname] or {}
        cached.remote_version = remote_version
        cached.remote_repo_ts = remote_repo_ts
        cached.release_tag_name = release_tag_name
        cached.error = err
        cached.last_checked = os.time()
        self.updates_state.remote_info[record.dirname] = cached
        -- Fix 4: bust summary cache (remote_info mutated in-place; reference unchanged)
        self._cached_plugin_summary = nil
        self:updateUpdatesDialog()
        self:saveUpdatesState()

        local message
        local plugin = findInstalledPlugin(record.dirname)
        local display_name = (plugin and (plugin.name or plugin.dirname)) or record.plugin_name or plugin_name
        local installed_version = plugin and plugin.version

        if err then
            message = string.format(_("Failed to check %s: %s"), display_name, err)
        elseif remote_version and installed_version then
            if isVersionNewer(remote_version, installed_version) then
                message = string.format(_("Update available for %s: remote %s, installed %s."), display_name, remote_version, installed_version)
            else
                message = string.format(_("%s is up to date (version %s)."), display_name, installed_version)
            end
        elseif remote_version then
            message = string.format(_("Remote version for %s: %s."), display_name, remote_version)
        else
            message = string.format(_("No remote version info for %s."), display_name)
        end

        if message then
            UIManager:show(InfoMessage:new{ text = message, timeout = 5 })
        end
    end)
end

function Storefront:updatePluginFromRecord(record)
    if record then
        StorefrontLogger.action(string.format("UPDATE plugin starting: dirname=%s (repo=%s/%s, version=%s)", tostring(record.dirname), tostring(record.owner), tostring(record.repo), tostring(record.installed_version)))
    end
    local descriptor = buildRepoDescriptorFromRecord(record)
    if not descriptor then
        UIManager:show(InfoMessage:new{ text = _("Missing repository info for update."), timeout = 4 })
        return
    end
    local plugin = findInstalledPlugin(record.dirname)
    if not plugin then
        UIManager:show(InfoMessage:new{ text = _("Plugin folder not found."), timeout = 4 })
        return
    end
    self.pending_install_context = {
        mode = "update",
        plugin = plugin,
    }
    self:promptPluginInstallOptions(descriptor)
end


local function getRecordedInstall(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return InstallStore.get(dirname)
end

function Storefront:updateInstallRecord(dirname, fields)
    if not dirname or dirname == "" or type(fields) ~= "table" then
        return
    end
    local record = getRecordedInstall(dirname) or { dirname = dirname }
    for key, value in pairs(fields) do
        if value ~= nil then
            record[key] = value
        end
    end
    InstallStore.upsert(dirname, record)
end

function Storefront:updatePatchRecord(filename, fields)
    if not filename or filename == "" or type(fields) ~= "table" then
        return
    end
    local records = getPatchRecordsMap()
    local record = records[filename] or { filename = filename }
    for key, value in pairs(fields) do
        if value ~= nil then
            record[key] = value
        end
    end
    InstallStore.upsertPatch(filename, record)
end

function Storefront:rememberPatchInstall(filename, repo, patch_info)
    if not filename or filename == "" then
        return
    end
    -- Include SHA during install/update (include_sha=true) so we can track the
    -- installed version and detect future updates correctly.
    local record = buildPatchRecordFields(filename, repo, patch_info, true)
    if record then
        InstallStore.upsertPatch(filename, record)
        return record
    end
end

function Storefront:updateSinglePatchStatus(filename, record)
    if not filename or filename == "" then
        return
    end
    record = record or (getPatchRecordsMap()[filename])
    if not record then
        return
    end
    self:ensurePatchUpdatesState()
    local remote_info = self.patch_updates_state.remote_info or {}
    local download_url = record.download_url
        or buildPatchDownloadUrl(record.owner, record.repo, record.branch or "HEAD", record.path)
    remote_info[filename] = {
        remote_sha = record.sha,
        download_url = download_url,
        error = nil,
        last_checked = os.time(),
    }
    self.patch_updates_state.remote_info = remote_info

    if self.patch_updates_menu then
        local scroll = self.patch_updates_menu.getScrollOffset and self.patch_updates_menu:getScrollOffset()
        self:showPatchUpdatesDialog()
        if scroll then
            self.patch_updates_menu:setScrollOffset(scroll)
        end
    end
end

local derivePluginRepoPath

function Storefront:rememberInstall(info, repo)
    if not info or not info.plugin_dirname then
        return
    end
    local meta_path
    if info.plugin_root then
        meta_path = sanitizeMetaPath(derivePluginRepoPath(info.plugin_root), info.plugin_dirname)
    end
    meta_path = meta_path or (info.plugin_dirname .. "/_meta.lua")
    local version = info.plugin_version
    if (not version or version == "") and info.plugin_release_tag then
        version = info.plugin_release_tag:gsub("^[vV]", "")
    end
    local record = buildInstallRecordFields(
        info.plugin_dirname,
        info.plugin_name,
        version,
        repo,
        meta_path,
        info.plugin_release_tag
    )
    if record then
        InstallStore.upsert(info.plugin_dirname, record)
        
        -- Clear ignored release if user installed the ignored version
        if repo and repo.owner and repo.name and info.plugin_release_tag then
            local owner = repo.owner
            local repo_name = repo.name
            if isReleaseIgnored(owner, repo_name, info.plugin_release_tag) then
                clearIgnoredRelease(owner, repo_name)
            end
        end
    end
end

derivePluginRepoPath = function(plugin_root)
    if not plugin_root or plugin_root == "" then
        return nil
    end
    local plugins_match = plugin_root:match("(plugins/.*)")
    if plugins_match and plugins_match ~= "" then
        return plugins_match
    end
    local koplugin_match = plugin_root:match("(%w[%w_%-%.]*%.koplugin.*)") or plugin_root:match("([^/]+%.koplugin.*)")
    if koplugin_match and koplugin_match ~= "" then
        return koplugin_match
    end
    local without_root = plugin_root
    local slash = without_root:find("/")
    if slash then
        without_root = without_root:sub(slash + 1)
    end
    if without_root and without_root ~= "" then
        return without_root
    end
    return plugin_root
end

fetchGitHubRaw = function(owner, repo_name, branch, path)
    if not owner or not repo_name or not path or path == "" then
        return nil, _("Missing repository metadata for remote fetch.")
    end
    branch = branch or "HEAD"
    local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo_name, branch, path)
    local response = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = {
            ["User-Agent"] = "KOReader-Storefront",
            ["Accept"] = "text/plain",
        },
    }
    code = tonumber(code)
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    return table.concat(response)
end

extractMetaField = function(source, field)
    if type(source) ~= "string" or source == "" or type(field) ~= "string" then
        return nil
    end
    local pattern = field .. "%s*=%s*[%\"']([^%\"']+)[%\"']"
    return source:match(pattern)
end

buildRepoDescriptorFromRecord = function(record)
    if not record or not record.owner or not record.repo then
        return nil
    end
    local owner = record.owner
    return {
        kind = "plugin",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end


function Storefront:resetFiltersForRefresh()
    self:ensureBrowserState()
    self.browser_state.search_text = ""
    self.browser_state.owner = ""
    self.browser_state.min_stars = 0
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self.browser_state.search_in_readme = false
    self.readme_filter = nil
    self:saveBrowserState()
end

function Storefront:promptPatchAction(repo, patch)
    local repo_title = repo.full_name or repo.name or _("Repository")
    local details = {
        string.format(_("Patch: %s"), patch.filename),
        string.format(_("Repository: %s"), repo_title),
    }
    if patch.display_path and patch.display_path ~= patch.filename then
        table.insert(details, string.format(_("Path: %s"), patch.display_path))
    end
    table.insert(details, string.format(_("Branch: %s"), patch.branch or "HEAD"))

    local dialog
    local other_buttons
    local is_matching_patch = self.match_context and self.match_context.kind == "patch" and self.match_context.patch
    if is_matching_patch then
        other_buttons = {
            {
                {
                    text = _("Match this remote patch"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self:matchPatchWithRepo(self.match_context.patch, repo, patch)
                    end,
                },
                {
                    text = _("Cancel matching"),
                    callback = function()
                        UIManager:close(dialog)
                        --local had_patch_updates = self.patch_updates_menu ~= nil
                        --self:cancelMatchContext()
                        --UIManager:show(InfoMessage:new{ text = _("Patch matching cancelled."), timeout = 3 })
                        --if had_patch_updates then
                        --    self:showPatchUpdatesDialog()
                        --else
                        --    self:showBrowser("patch")
                        --end
                    end,
                },
            },
        }
    else
        local DetailsDialog = require("storefront_details_dialog")
        local details_dialog = DetailsDialog:new{
            Storefront = self,
            repo = repo,
            patch = patch,
            kind = "patch",
        }
        details_dialog:show()
    end
end

function StorefrontBrowserDialog:resetScroll()
    if self.list_scroller then
        self.list_scroller:setScrolledOffset({ x = 0, y = 0 })
    end
end

ensureCacheDir = function()
    local lfs = require("libs/libkoreader-lfs")
    local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    return cache_dir
end

-- Format the published date of a GitHub release for display next to its tag.
-- Falls back to created_at when published_at is missing.
local function formatReleaseDate(release)
    if not release then
        return nil
    end
    local raw = release.published_at or release.created_at
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local ts = parseGitHubTimestamp(raw)
    if not ts or ts <= 0 then
        return nil
    end
    return os.date("%Y-%m-%d", ts)
end

local function getReleaseLabel(release)
    if not release then
        return nil
    end
    local tag = release.tag_name
    if not tag or tag == "" then
        tag = release.name
    end
    if not tag or tag == "" then
        return nil
    end
    return tostring(tag)
end

-- Fetch commits between two tags via the GitHub compare API and show them
-- in a scrollable dialog.  Called from inside the Full changelog dialog.
function Storefront:showCommitCompare(owner, repo_desc, base_tag, head_tag)
    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching commits…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local result, err = GitHub.fetchCompareCommits(owner, repo_desc.name, base_tag, head_tag)
        UIManager:close(progress)

        if not result then
            local msg = (type(err) == "table" and err.code == 404)
                and string.format(_("Tag not found on GitHub (%s or %s)."), base_tag, head_tag)
                or  _("Could not fetch commit comparison.")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
            return
        end

        local commits = result.commits or {}
        local total   = result.total_commits or #commits
        local repo_name = repo_desc.full_name or repo_desc.name or owner

        local lines = {
            string.format(_("Commit diff: %s → %s"), base_tag, head_tag),
            string.format(_("Repository: %s"), repo_name),
            string.format(_("Total commits: %d"), total),
            "",
        }

        if #commits == 0 then
            table.insert(lines, _("No commits found in this range."))
        else
            -- GitHub returns oldest-first in the commits array; keep that order
            -- (chronological = natural reading order for a changelog).
            for _, commit in ipairs(commits) do
                local msg   = commit.commit and commit.commit.message or ""
                local title = msg:match("^([^\n\r]+)") or msg
                title = util.trim(title)
                title = softWrapLongTokens(title, 55)
                local sha   = commit.sha and commit.sha:sub(1, 7) or "???????"
                table.insert(lines, string.format("\xE2\x80\xA2 %s  [%s]", title, sha))
            end
            if total > #commits then
                table.insert(lines, "")
                table.insert(lines, string.format(
                    _("(showing %d of %d commits)"), #commits, total))
            end
        end

        local text = table.concat(lines, "\n")
        UIManager:show(TextViewer:new{
            title = string.format(_("Commits: %s \xE2\x86\x92 %s"), base_tag, head_tag),
            text  = text,
            add_default_buttons = true,
        })
    end)
end

-- Show a scrollable dialog with all release notes between the installed
-- version and `target_release`, fetched from the GitHub releases list.
-- `installed_tag` is the exact GitHub release tag of the installed version;
-- when present it is used as the range boundary directly (no version parsing).
-- Only shown when the target release is strictly newer than what is installed.
function Storefront:showFullChangelog(owner, repo_desc, installed_version, target_release, installed_tag)
    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching changelog…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local releases, err = GitHub.fetchReleases(owner, repo_desc.name)
        UIManager:close(progress)

        if not releases or #releases == 0 then
            UIManager:show(InfoMessage:new{
                text = err
                    and _("Could not fetch releases for changelog.")
                    or  _("No releases found for this repository."),
                timeout = 4,
            })
            return
        end

        local target_tag = target_release and target_release.tag_name
        local sections   = {}
        -- `base_tag` is the known installed release tag used for commit-compare.
        -- Prefer the recorded installed_tag; fall back to version-based detection.
        local base_tag   = installed_tag or nil
        local collecting = (target_tag == nil)
        local is_downgrade = false

        for _idx, rel in ipairs(releases) do
            local rel_tag = rel.tag_name

            -- Downgrade detection: if we hit the installed tag before the
            -- target tag the user is going backwards.
            if installed_tag and not collecting and rel_tag == installed_tag then
                is_downgrade = true
                break
            end

            -- Start collecting at the target release tag.
            if not collecting and rel_tag == target_tag then
                collecting = true
            end

            if collecting then
                -- Stop when we reach the installed tag (exact match).
                if installed_tag and rel_tag == installed_tag then
                    break
                end

                -- Fallback stop: version-string comparison when no installed_tag.
                if not installed_tag then
                    local rel_version = parseVersionFromTag(rel_tag)
                    if rel_version and not isVersionNewer(rel_version, installed_version) then
                        base_tag = rel_tag
                        break
                    end
                end

                local label  = getReleaseLabel(rel) or rel_tag or _("Release")
                local date   = formatReleaseDate(rel)
                local header = date
                    and string.format("=== %s (%s) ===", label, date)
                    or  string.format("=== %s ===", label)
                local body = rel.body
                if not body or body == json.null or body == "" then
                    body = _("No release notes.")
                else
                    -- Trim leading/trailing blank lines and collapse any run of
                    -- 3+ newlines down to a single blank line. GitHub release
                    -- bodies commonly end with (or contain) extra blank lines;
                    -- left as-is, these stack with our own "\n\n" separators
                    -- between sections and can push an entire page of the
                    -- changelog viewer to be blank when paging through it.
                    body = util.trim(tostring(body))
                    if body == "" then
                        body = _("No release notes.")
                    else
                        body = body:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
                        body = softWrapLongTokens(body, 60)
                    end
                end
                table.insert(sections, header .. "\n\n" .. body)
            end
        end

        -- Fallback base_tag from version string when not found in releases list.
        if not base_tag and installed_version then
            base_tag = "v" .. installed_version
        end

        -- Reverse so oldest release appears first (chronological reading order).
        local reversed = {}
        for i = #sections, 1, -1 do
            reversed[#reversed + 1] = sections[i]
        end

        local downgrade_notice = ""
        if is_downgrade then
            downgrade_notice = string.format(
                "\xE2\x9A\xA0 %s\n\n",
                _("Warning: the selected version is older than what is currently installed. You are downgrading.")
            )
        end

        local text
        if is_downgrade or #sections == 0 then
            local repo_name = repo_desc.full_name or repo_desc.name or owner
            text = string.format(
                _("Changelog for %s\n%s \xE2\x86\x92 %s"),
                repo_name,
                installed_version or _("?"),
                target_tag        or _("latest")
            ) .. "\n\n" .. downgrade_notice .. _("No changelog entries found for this range.")
        else
            local repo_name = repo_desc.full_name or repo_desc.name or owner
            text = string.format(
                _("Changelog for %s\n%s \xE2\x86\x92 %s"),
                repo_name,
                installed_version or _("?"),
                target_tag        or _("latest")
            ) .. "\n\n" .. table.concat(reversed, "\n\n")
        end

        -- "View commits" button: only available when we have both tag bounds.
        local buttons_table = nil
        if base_tag and target_tag then
            local self_ref = self
            local b_label = is_downgrade
                and string.format(_("View commits (%s \xE2\x86\x92 %s)"), target_tag, base_tag)
                or  string.format(_("View commits (%s \xE2\x86\x92 %s)"), base_tag, target_tag)
            local b_base = is_downgrade and target_tag or base_tag
            local b_head = is_downgrade and base_tag  or target_tag
            buttons_table = {
                {
                    {
                        text = b_label,
                        callback = function()
                            self_ref:showCommitCompare(owner, repo_desc, b_base, b_head)
                        end,
                    },
                },
            }
        end

        UIManager:show(TextViewer:new{
            title               = string.format(_("Changelog: %s"), repo_desc.full_name or repo_desc.name or owner),
            text                = text,
            buttons_table       = buttons_table,
            add_default_buttons = true,
        })
    end)
end

local ASSETS_PAGE_SIZE = 8

local function buildDownloadOptionsTitle(release, owner, repo_name)
    local tag = release and release.tag_name and release.tag_name ~= "" and release.tag_name or nil
    local title = release and release.name and release.name ~= "" and release.name or nil
    local has_distinct_title = title and tag
        and title:lower():gsub("^%s*(.-)%s*$", "%1") ~= tag:lower():gsub("^%s*(.-)%s*$", "%1")
    local label
    if has_distinct_title then
        label = string.format("%s \xE2\x80\x94 %s", title, tag)
    else
        label = getReleaseLabel(release)
    end
    local repo_prefix = (owner and repo_name) and string.format("[%s/%s] ", owner, repo_name) or ""
    local result
    if not label then
        result = repo_prefix .. _("Download options")
    else
        local date = formatReleaseDate(release)
        if date then
            result = repo_prefix .. string.format(_("Download options — %s (%s)"), label, date)
        else
            result = repo_prefix .. string.format(_("Download options — %s"), label)
        end
    end
    
    if owner and repo_name and tag and InstallStore.isReleaseIgnoredByRepo(owner, repo_name, tag) then
        result = result .. " " .. _("[Ignored]")
    end
    
    return result
end

-- Display a paginated list of release assets. `on_select` is called with the
-- chosen asset table when the user taps an entry.
function Storefront:renderAssetListPage(repo, release, assets, page, on_select)
    page = page or 1
    local total = #assets
    local total_pages = math.max(1, math.ceil(total / ASSETS_PAGE_SIZE))
    if page < 1 then page = 1 end
    if page > total_pages then page = total_pages end

    local dialog
    local button_rows = {}

    local first = (page - 1) * ASSETS_PAGE_SIZE + 1
    local last = math.min(first + ASSETS_PAGE_SIZE - 1, total)
    for i = first, last do
        local asset = assets[i]
        table.insert(button_rows, {
            {
                text = asset.name,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    on_select(asset)
                end,
            },
        })
    end

    if total_pages > 1 then
        local nav_row = {}
        if page > 1 then
            table.insert(nav_row, {
                text = "\xE2\x97\x80  " .. _("Prev"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderAssetListPage(repo, release, assets, page - 1, on_select)
                end,
            })
        end
        table.insert(nav_row, {
            text = string.format(_("Page %d/%d"), page, total_pages),
            background = Blitbuffer.COLOR_WHITE,
            callback = function() end,
        })
        if page < total_pages then
            table.insert(nav_row, {
                text = _("Next") .. "  \xE2\x96\xB6",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderAssetListPage(repo, release, assets, page + 1, on_select)
                end,
            })
        end
        table.insert(button_rows, nav_row)
    end

    table.insert(button_rows, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    local tag_label = release and (release.tag_name or release.name) or (repo.full_name or repo.name or "")
    dialog = ButtonDialog:new{
        title = string.format(_("Assets — %s"), tag_label),
        title_align = "center",
        buttons = button_rows,
    }
    UIManager:show(dialog)
end


local RELEASES_PAGE_SIZE = 10

-- Display a paginated list of every release published by `repo`. Selecting a
-- release closes this dialog and reopens the Download options popup for that
-- release; this avoids stacking popups on top of each other.
function Storefront:showReleaseListDialog(repo, current_release)
    if not repo then
        return
    end
    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for releases."), timeout = 4 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching releases…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local releases, err = GitHub.fetchReleases(owner, repo.name)

        UIManager:close(progress)

        if not releases or #releases == 0 then
            local message
            if err then
                message = _("Could not fetch releases for this repository.")
            else
                message = _("No releases found for this repository.")
            end
            UIManager:show(InfoMessage:new{ text = message, timeout = 4 })
            return
        end

        self:renderReleaseListPage(repo, releases, 1, current_release, true)
    end)
end

local RELEASES_PAGE_SIZE = 10

local function isPreRelease(release)
    if release.prerelease then return true end
    local tag = (release.tag_name or release.name or ""):lower()
    -- Check common pre-release suffixes in version tags (e.g. v1.2.3-rc1, v1.0.0-beta.2)
    if tag:find("[%-.]alpha") or tag:find("[%-.]beta")
        or tag:find("[%-.]rc%d") or tag:find("[%-.]rc$") or tag:find("[%-.]rc%-")
        or tag:find("[%-.]pre%d") or tag:find("[%-.]preview") or tag:find("%-pre%-")
        or tag:find("[%-.]dev%d") or tag:find("[%-.]dev$")
        or tag:find("nightly") then
        return true
    end
    return false
end

function Storefront:renderReleaseListPage(repo, releases, page, current_release, filter_pre_releases)
    if filter_pre_releases == nil then filter_pre_releases = true end
    page = page or 1

    -- Apply pre-release filter, keeping the original list for toggling
    local visible_releases = releases
    if filter_pre_releases then
        visible_releases = {}
        for _, r in ipairs(releases) do
            if not isPreRelease(r) then
                table.insert(visible_releases, r)
            end
        end
    end

    local total = #visible_releases
    local total_pages = math.max(1, math.ceil(total / RELEASES_PAGE_SIZE))
    if page < 1 then page = 1 end
    if page > total_pages then page = total_pages end

    local current_tag = getReleaseLabel(current_release)

    local dialog
    local button_rows = {}

    -- Filter toggle checkbox row (always first)
    local filter_label = filter_pre_releases
        and ("\xE2\x98\x91 " .. _("Filter pre-releases"))
        or  ("\xE2\x98\x90 " .. _("Filter pre-releases"))
    table.insert(button_rows, {
        {
            text = filter_label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:renderReleaseListPage(repo, releases, 1, current_release, not filter_pre_releases)
            end,
        },
    })

    if total == 0 then
        local msg = filter_pre_releases
            and _("No stable releases found — uncheck filter to show all releases")
            or  _("No releases found for this repository.")
        table.insert(button_rows, {
            {
                text = msg,
                background = Blitbuffer.COLOR_WHITE,
                callback = function() end,
            },
        })
    else

    local first = (page - 1) * RELEASES_PAGE_SIZE + 1
    local last = math.min(first + RELEASES_PAGE_SIZE - 1, total)
    for i = first, last do
        local release = visible_releases[i]
        local tag = release.tag_name and release.tag_name ~= "" and release.tag_name or nil
        local title = release.name and release.name ~= "" and release.name or nil
        -- Show "Title — tag" when title exists and differs from tag (case-insensitive trim)
        local has_distinct_title = title and tag
            and title:lower():gsub("^%s*(.-)%s*$", "%1") ~= tag:lower():gsub("^%s*(.-)%s*$", "%1")
        local label
        if has_distinct_title then
            label = string.format("%s \xE2\x80\x94 %s", title, tag)  -- "Title — tag"
        else
            label = getReleaseLabel(release) or _("Unnamed release")
        end
        local date = formatReleaseDate(release)
        local prefix = ""
        if current_tag and getReleaseLabel(release) == current_tag then
            prefix = "\xE2\x80\xA2 " -- bullet to mark currently shown release
        end
        local text
        if date then
            text = string.format("%s%s (%s)", prefix, label, date)
        else
            text = string.format("%s%s", prefix, label)
        end
        if release.prerelease then
            text = text .. " " .. _("[pre]")
        elseif release.draft then
            text = text .. " " .. _("[draft]")
        end
        
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if owner and repo.name and tag and InstallStore.isReleaseIgnoredByRepo(owner, repo.name, tag) then
            text = text .. " " .. _("[Ignored]")
        end
        table.insert(button_rows, {
            {
                text = text,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    -- Close the release list, then reopen Download options for the chosen release.
                    self:promptPluginInstallOptions(repo, release, true)
                end,
            },
        })
    end

    if total_pages > 1 then
        local nav_row = {}
        if page > 1 then
            table.insert(nav_row, {
                text = "◀  " .. _("Prev"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderReleaseListPage(repo, releases, page - 1, current_release, filter_pre_releases)
                end,
            })
        end
        table.insert(nav_row, {
            text = string.format(_("Page %d/%d"), page, total_pages),
            background = Blitbuffer.COLOR_WHITE,
            callback = function() end,
        })
        if page < total_pages then
            table.insert(nav_row, {
                text = _("Next") .. "  ▶",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderReleaseListPage(repo, releases, page + 1, current_release, filter_pre_releases)
                end,
            })
        end
        table.insert(button_rows, nav_row)
    end

    end -- end else (total > 0)

    table.insert(button_rows, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                if self.pending_install_context and not self.pending_install_context.batch_callback then
                    self.pending_install_context = nil
                end
            end,
        },
    })

    local title_label = repo.full_name or repo.name or _("Releases")
    dialog = ButtonDialog:new{
        title = string.format(_("Releases — %s"), title_label),
        title_align = "center",
        buttons = button_rows,
    }
    UIManager:show(dialog)
end

local function sanitizePluginDirname(name)
    name = name or "plugin"
    name = util.trim(name)
    if name == "" then
        name = "plugin"
    end
    name = name:gsub("[^%w_%-%.]", "_")
    if not name:match("%.koplugin$") then
        name = name .. ".koplugin"
    end
    return name
end

extractReleaseNameFallback = function(repo, release, asset, meta_source)
    local repo_name = repo and repo.name
    local asset_name = asset and asset.name
    local plugin_name
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
    end

    local asset_plugin_dir = asset_name and asset_name:match("([%w_%-%.]+%.koplugin)%.zip$")
    if asset_plugin_dir then
        return asset_plugin_dir
    end
    
    local is_source_code = asset_name and asset_name:match("^Source code") ~= nil
    if is_source_code and repo_name then
        local repo_is_plugin_dir = repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        if repo_is_plugin_dir then
            return repo_name
        end
    end

    local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
    if repo_is_plugin_dir then
        return repo_name
    end

    if repo_name and repo_name:match("^[%w_%-%.]+$") then
        return repo_name .. ".koplugin"
    end

    if plugin_name and plugin_name ~= "" then
        return sanitizePluginDirname(plugin_name)
    end

    return sanitizePluginDirname("plugin")
end

local function truncateText(text, max_len)
    max_len = max_len or 140
    if not text or text == "" then
        return ""
    end
    local trimmed = util.trim(text)
    if #trimmed <= max_len then
        return trimmed
    end
    return trimmed:sub(1, max_len - 1) .. "…"
end

formatTimestamp = function(ts)
    if not ts or ts <= 0 then
        return _("Never")
    end
    return os.date("%Y-%m-%d", ts)
end

local function isPatchFilename(filename)
    if not filename or filename == "" then
        return false
    end
    return filename:match("^%d+%-.+%.lua$") ~= nil
end

local function buildPatchDownloadUrl(owner, repo_name, branch, path)
    if not owner or not repo_name or not path then
        return nil
    end
    branch = branch or "HEAD"
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s",
        owner,
        repo_name,
        branch,
        path
    )
end

ensurePatchesDir = function()
    local dir = DataStorage:getDataDir() .. "/patches"
    local ok, err = util.makePath(dir)
    if not ok then
        logger.warn("Storefront patches dir create failed", err)
        return nil, err or "mkdir"
    end
    return dir
end

extractRepoOwner = function(repo)
    if repo.owner and repo.owner ~= "" then
        return repo.owner
    end
    if repo.data and repo.data.owner and repo.data.owner.login then
        return repo.data.owner.login
    end
end

local function normalizedLower(value)
    if not value then
        return ""
    end
    if type(value) ~= "string" then
        value = tostring(value)
    end
    local trimmed = util.trim(value)
    if trimmed == "" then
        return ""
    end
    if util.lower then
        return util.lower(trimmed)
    end
    return trimmed:lower()
end

local function extractSearchTerms(search)
    if not search or search == "" then
        return nil
    end
    local normalized = normalizedLower(search)
    if normalized == "" then
        return nil
    end
    local terms = {}
    for term in normalized:gmatch("%S+") do
        terms[#terms + 1] = term
    end
    if #terms == 0 then
        return nil
    end
    return terms
end

function Storefront:repoMatchesSearch(repo, search)
    local terms = extractSearchTerms(search)
    if not terms then
        return true
    end
    local haystacks = {}
    local function addField(value)
        local normalized = normalizedLower(value)
        if normalized ~= "" then
            haystacks[#haystacks + 1] = normalized
        end
    end
    addField(repo.full_name)
    addField(repo.name)
    addField(repo.font_family)
    addField(repo.font_name)
    addField(repo.owner)
    addField(repo.author)
    addField(repo.category)
    addField(repo.description)
    addField(repo.language)
    if repo.data and type(repo.data.topics) == "table" then
        for _, topic in ipairs(repo.data.topics) do
            addField(topic)
        end
    end
    if #haystacks == 0 then
        return false
    end
    for _, term in ipairs(terms) do
        local matched = false
        for _, hay in ipairs(haystacks) do
            if hay:find(term, 1, true) then
                matched = true
                break
            end
        end
        if not matched then
            return false
        end
    end
    return true
end

function Storefront:patchMatchesSearch(patch, search)
    local terms = extractSearchTerms(search)
    if not terms then
        return true
    end
    local haystacks = {}
    local function addField(value)
        local normalized = normalizedLower(value)
        if normalized ~= "" then
            haystacks[#haystacks + 1] = normalized
        end
    end
    addField(patch.filename)
    addField(patch.display_path)
    addField(patch.path)
    if #haystacks == 0 then
        return false
    end
    for _, term in ipairs(terms) do
        local matched = false
        for _, hay in ipairs(haystacks) do
            if hay:find(term, 1, true) then
                matched = true
                break
            end
        end
        if not matched then
            return false
        end
    end
    return true
end

function Storefront:repoHasMatchingPatch(repo, search)
    if not search or search == "" then
        return true
    end
    local patches = self:getPatchEntriesForRepo(repo)
    for _, patch in ipairs(patches) do
        if self:patchMatchesSearch(patch, search) then
            return true
        end
    end
    return false
end


local function repoUpdatedValue(repo)
    -- For ordering, only consider pushed_at (last pushed commit).
    -- Repos with no pushes get value 0 and sink to the bottom.
    if repo.data and repo.data.pushed_at then
        return parseGitHubTimestamp(repo.data.pushed_at)
    end
    return 0
end

local function repoCreatedValue(repo)
    if repo.data and repo.data.created_at then
        return parseGitHubTimestamp(repo.data.created_at)
    end
    return 0
end

local function repoNameKey(repo)
    return normalizedLower(repo.name or repo.full_name or "")
end

local function patchNameKey(entry)
    return normalizedLower(entry.patch and entry.patch.filename or "")
end

local function compareRepoStarsDesc(a, b)
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    local ua = repoUpdatedValue(a)
    local ub = repoUpdatedValue(b)
    if ua ~= ub then
        return ua > ub
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function compareRepoUpdatedDesc(a, b)
    local ua = repoUpdatedValue(a)
    local ub = repoUpdatedValue(b)
    if ua ~= ub then
        return ua > ub
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function compareRepoNameAsc(a, b)
    local na = repoNameKey(a)
    local nb = repoNameKey(b)
    if na ~= nb then
        return na < nb
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoUpdatedValue(a) > repoUpdatedValue(b)
end

local function compareRepoNameDesc(a, b)
    local na = repoNameKey(a)
    local nb = repoNameKey(b)
    if na ~= nb then
        return na > nb
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoUpdatedValue(a) > repoUpdatedValue(b)
end

local function compareRepoCreatedDesc(a, b)
    local ca = repoCreatedValue(a)
    local cb = repoCreatedValue(b)
    if ca ~= cb then
        return ca > cb
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function comparePatchStarsDesc(a, b)
    if a.stars ~= b.stars then
        return a.stars > b.stars
    end
    local na = repoNameKey(a.repo)
    local nb = repoNameKey(b.repo)
    if na ~= nb then
        return na < nb
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchUpdatedDesc(a, b)
    local ua = repoUpdatedValue(a.repo)
    local ub = repoUpdatedValue(b.repo)
    if ua ~= ub then
        return ua > ub
    end
    if a.stars ~= b.stars then
        return a.stars > b.stars
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchNameAsc(a, b)
    local na = repoNameKey(a.repo)
    local nb = repoNameKey(b.repo)
    if na ~= nb then
        return na < nb
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchNameDesc(a, b)
    local na = repoNameKey(a.repo)
    local nb = repoNameKey(b.repo)
    if na ~= nb then
        return na > nb
    end
    return patchNameKey(a) > patchNameKey(b)
end

local function comparePatchRepoCreatedDesc(a, b)
    local ca = repoCreatedValue(a.repo)
    local cb = repoCreatedValue(b.repo)
    if ca ~= cb then
        return ca > cb
    end
    return comparePatchStarsDesc(a, b)
end

local function compareRepoWilsonScoreDesc(a, b)
    local StorefrontRatings = require("storefront_ratings")
    local id_a = a and (a.id or a.repo_id)
    local id_b = b and (b.id or b.repo_id)
    local r_a = id_a and StorefrontRatings.getRating(id_a)
    local r_b = id_b and StorefrontRatings.getRating(id_b)

    local sa = r_a and r_a.wilson or 0
    local sb = r_b and r_b.wilson or 0
    if sa ~= sb then
        return sa > sb
    end
    return compareRepoStarsDesc(a, b)
end

local function comparePatchWilsonScoreDesc(a, b)
    local StorefrontRatings = require("storefront_ratings")
    local r_item_a = a and (a.repo or a)
    local r_item_b = b and (b.repo or b)
    local id_a = r_item_a and (r_item_a.id or r_item_a.repo_id)
    local id_b = r_item_b and (r_item_b.id or r_item_b.repo_id)

    local r_a = id_a and StorefrontRatings.getRating(id_a)
    local r_b = id_b and StorefrontRatings.getRating(id_b)

    local sa = r_a and r_a.wilson or 0
    local sb = r_b and r_b.wilson or 0
    if sa ~= sb then
        return sa > sb
    end
    return comparePatchStarsDesc(a, b)
end

local SORT_OPTIONS = {
    {
        id = "rating_desc",
        summary = _("Sort: Most Liked"),
        repo_comparator = compareRepoWilsonScoreDesc,
        patch_comparator = comparePatchWilsonScoreDesc,
    },
    {
        id = "stars_desc",
        summary = _("Sort: Stars (high → low)"),
        repo_comparator = compareRepoStarsDesc,
        patch_comparator = comparePatchStarsDesc,
    },
    {
        id = "updated_desc",
        summary = _("Sort: Recently updated"),
        repo_comparator = compareRepoUpdatedDesc,
        patch_comparator = comparePatchUpdatedDesc,
    },
    {
        id = "name_asc",
        summary = _("Sort: Name (A → Z)"),
        repo_comparator = compareRepoNameAsc,
        patch_comparator = comparePatchNameAsc,
    },
    {
        id = "name_desc",
        summary = _("Sort: Name (Z → A)"),
        repo_comparator = compareRepoNameDesc,
        patch_comparator = comparePatchNameDesc,
    },
}

local SORT_OPTION_LOOKUP = {}
for _, option in ipairs(SORT_OPTIONS) do
    SORT_OPTION_LOOKUP[option.id] = option
end

function Storefront:getSortOption(mode)
    return SORT_OPTION_LOOKUP[mode] or SORT_OPTION_LOOKUP[DEFAULT_SORT_MODE]
end

function Storefront:getSortSummary()
    local option = self:getSortOption(self.browser_state.sort_mode)
    return option and option.summary or ""
end

function Storefront:advanceSortMode()
    local current = self.browser_state.sort_mode or DEFAULT_SORT_MODE
    local next_index = 1
    for idx, option in ipairs(SORT_OPTIONS) do
        if option.id == current then
            next_index = idx % #SORT_OPTIONS + 1
            break
        end
    end
    self.browser_state.sort_mode = SORT_OPTIONS[next_index].id
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:saveBrowserState()
    -- Keep focus on the Sort row after the rebuild so repeated presses cycle
    -- through the sort modes in place.
    self.browser_focus_hint = { id = "sort" }
    self:reopenBrowser()
end

function Storefront:sortRepoList(list)
    if not list or #list <= 1 then
        return
    end
    local option = self:getSortOption(self.browser_state.sort_mode)
    local comparator = option and option.repo_comparator or compareRepoStarsDesc
    table.sort(list, comparator)
end

function Storefront:sortPatchEntries(entries)
    if not entries or #entries <= 1 then
        return entries
    end
    local option = self:getSortOption(self.browser_state.sort_mode)
    local comparator = option and option.patch_comparator or comparePatchStarsDesc
    table.sort(entries, comparator)
    return entries
end

local function normalizeScrollOffset(offset)
    if type(offset) ~= "table" then
        return nil
    end
    local x = tonumber(offset.x)
    local y = tonumber(offset.y)
    if not x or not y then
        return nil
    end
    return { x = x, y = y }
end

function Storefront:loadBrowserStateFromSettings()
    if self._browser_state_loaded then
        return
    end
    self._browser_state_loaded = true
    local encoded = StorefrontSettings:readSetting(BROWSER_STATE_KEY)
    if type(encoded) ~= "string" or encoded == "" then
        return
    end
    local ok, decoded = pcall(json.decode, encoded)
    if not ok or type(decoded) ~= "table" then
        return
    end
    self.browser_state = {
        kind = (decoded.kind == "patch" and "patch") or (decoded.kind == "font" and "font") or "plugin",
        -- Never restore Screensavers tab from session — it triggers a synchronous
        -- network fetch on open which can exhaust memory on low-RAM devices (Kindle).
        tab = (decoded.tab == "Screensavers") and "Plugins" or (decoded.tab or (decoded.kind == "patch" and "Patches" or (decoded.kind == "font" and "Fonts" or "Plugins"))),
        search_text = decoded.search_text or "",
        owner = decoded.owner or "",
        font_category = decoded.font_category or "all",
        min_stars = tonumber(decoded.min_stars) or 0,
        page = math.max(1, tonumber(decoded.page) or 1),
        scroll_offset = normalizeScrollOffset(decoded.scroll_offset),
        sort_mode = decoded.sort_mode or DEFAULT_SORT_MODE,
        search_in_readme = decoded.search_in_readme == true,
        show_filter_bar_plugins = decoded.show_filter_bar_plugins == true,
        show_filter_bar_patches = decoded.show_filter_bar_patches == true,
        show_filter_bar_fonts = decoded.show_filter_bar_fonts == true,
        show_filter_bar_installed = decoded.show_filter_bar_installed ~= false,
    }
end

function Storefront:saveBrowserState(skip_flush)
    if not self.browser_state then
        return
    end
    local state = {
        kind = (self.browser_state.kind == "patch" and "patch") or (self.browser_state.kind == "font" and "font") or "plugin",
        tab = self.browser_state.tab or (self.browser_state.kind == "patch" and "Patches" or (self.browser_state.kind == "font" and "Fonts" or "Plugins")),
        search_text = self.browser_state.search_text or "",
        owner = self.browser_state.owner or "",
        font_category = self.browser_state.font_category or "all",
        min_stars = tonumber(self.browser_state.min_stars) or 0,
        page = math.max(1, tonumber(self.browser_state.page) or 1),
        scroll_offset = normalizeScrollOffset(self.browser_state.scroll_offset),
        sort_mode = self.browser_state.sort_mode or DEFAULT_SORT_MODE,
        search_in_readme = self.browser_state.search_in_readme == true,
        show_filter_bar_plugins = self.browser_state.show_filter_bar_plugins == true,
        show_filter_bar_patches = self.browser_state.show_filter_bar_patches == true,
        show_filter_bar_fonts = self.browser_state.show_filter_bar_fonts == true,
        show_filter_bar_installed = self.browser_state.show_filter_bar_installed ~= false,
    }
    self.browser_state.scroll_offset = state.scroll_offset
    local ok, encoded = pcall(json.encode, state)
    if ok then
        StorefrontSettings:saveSetting(BROWSER_STATE_KEY, encoded)
        if not skip_flush then
            StorefrontSettings:flush()
        end
    end
end

function Storefront:ensureBrowserState()
    if not self.browser_state then
        self:loadBrowserStateFromSettings()
    end
    if not self.browser_state then
        self.browser_state = {
            kind = "plugin",
            tab = "Plugins",
            search_text = "",
            owner = "",
            font_category = "all",
            min_stars = 0,
            page = 1,
            scroll_offset = nil,
            sort_mode = DEFAULT_SORT_MODE,
            search_in_readme = false,
            show_filter_bar_plugins = false,
            show_filter_bar_patches = false,
            show_filter_bar_fonts = false,
            show_filter_bar_installed = true,
        }
        self:saveBrowserState()
        return
    end
    self.browser_state.kind = (self.browser_state.kind == "patch" and "patch") or (self.browser_state.kind == "font" and "font") or "plugin"
    self.browser_state.tab = self.browser_state.tab or (self.browser_state.kind == "patch" and "Patches" or (self.browser_state.kind == "font" and "Fonts" or "Plugins"))
    if type(self.browser_state.search_text) ~= "string" then
        self.browser_state.search_text = ""
    end
    if type(self.browser_state.owner) ~= "string" then
        self.browser_state.owner = ""
    end
    if type(self.browser_state.font_category) ~= "string" then
        self.browser_state.font_category = "all"
    end
    self.browser_state.min_stars = tonumber(self.browser_state.min_stars) or 0
    self.browser_state.page = math.max(1, tonumber(self.browser_state.page) or 1)
    self.browser_state.scroll_offset = normalizeScrollOffset(self.browser_state.scroll_offset)
    if type(self.browser_state.sort_mode) ~= "string" or not SORT_OPTION_LOOKUP[self.browser_state.sort_mode] then
        self.browser_state.sort_mode = DEFAULT_SORT_MODE
    end
    if type(self.browser_state.search_in_readme) ~= "boolean" then
        self.browser_state.search_in_readme = false
    end
    if type(self.browser_state.show_filter_bar_plugins) ~= "boolean" then
        self.browser_state.show_filter_bar_plugins = false
    end
    if type(self.browser_state.show_filter_bar_patches) ~= "boolean" then
        self.browser_state.show_filter_bar_patches = false
    end
    if type(self.browser_state.show_filter_bar_fonts) ~= "boolean" then
        self.browser_state.show_filter_bar_fonts = false
    end
    if type(self.browser_state.show_filter_bar_installed) ~= "boolean" then
        self.browser_state.show_filter_bar_installed = true
    end
end

function Storefront:updateReadmeFilter()
    self.readme_filter = nil
end

function Storefront:getOwners(kind)
    local descriptors = self:getRepoDescriptors(kind)
    local seen = {}
    local owners = {}
    for _, repo in ipairs(descriptors) do
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if owner and owner ~= "" then
            if not seen[owner] then
                seen[owner] = true
                table.insert(owners, owner)
            end
        end
    end
    table.sort(owners, function(a, b)
        return a:lower() < b:lower()
    end)
    return owners
end

function Storefront:matchesGeneralFilters(repo, filters)
    filters = filters or self.browser_state or {}

    local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
        or (self.browser_state and self.browser_state.include_zero_star_forks == true)
    if not include_zero then
        local is_fork = repoIsFork(repo) or repo.fork == true or (repo.data and repo.data.fork == true)
        local stars = repoStarsValue(repo)
        if is_fork and stars == 0 then
            return false
        end
    end

    local owner_filter = normalizedLower(filters.owner)
    if owner_filter ~= "" then
        local owner_value = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        owner_value = normalizedLower(owner_value)
        if owner_value == "" or not owner_value:find(owner_filter, 1, true) then
            return false
        end
    end

    local font_cat_filter = normalizedLower(filters.font_category or "")
    if font_cat_filter ~= "" and font_cat_filter ~= "all" then
        local repo_cat = normalizedLower(repo.category or "")
        if repo_cat ~= font_cat_filter then
            return false
        end
    end

    local min_stars = tonumber(filters.min_stars) or 0
    if min_stars > 0 then
        local stars = repoStarsValue(repo)
        if stars < min_stars then
            return false
        end
    end

    return true
end

function Storefront:descriptorMatches(repo, filters)
    if not self:matchesGeneralFilters(repo, filters) then
        return false
    end
    local search = normalizedLower(filters.search_text)
    if search ~= "" then
        return self:repoMatchesSearch(repo, search)
    end
    return true
end

function Storefront:getFilteredDescriptors(kind)
    self:ensureBrowserState()
    local descriptors = self:getRepoDescriptors(kind)
    
    local search = normalizedLower(self.browser_state.search_text)
    local search_active = search ~= ""
    local rf = self.readme_filter
    local rf_key = rf and (rf.kind .. "_" .. (rf.matches_count or 0)) or ""
    local fetched = Cache.getLastFetched and Cache.getLastFetched(kind) or 0
    local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local cache_key = string.format("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
        tostring(kind), tostring(search), tostring(self.browser_state.search_in_readme),
        tostring(self.browser_state.min_stars), tostring(self.browser_state.owner),
        tostring(self.browser_state.font_category),
        tostring(self.browser_state.sort_mode),
        tostring(self.browser_state.include_zero_star_forks), rf_key, tostring(fetched), tostring(gen))
        
    if self._filtered_descriptors_cache and self._filtered_descriptors_cache.key == cache_key then
        return self._filtered_descriptors_cache.filtered, self._filtered_descriptors_cache.total
    end

    local filtered = {}
    for _, repo in ipairs(descriptors) do
        if kind == "patch" then
            if self:matchesGeneralFilters(repo, self.browser_state) then
                local repo_match = (not search_active) or self:repoMatchesSearch(repo, search)
                local patch_match = search_active and not repo_match and self:repoHasMatchingPatch(repo, search)

                local remote_match = false
                local rf = self.readme_filter
                if rf and rf.kind == "patch" and rf.matches and self.browser_state.search_in_readme and search_active then
                    local key = repo.full_name
                    if not key then
                        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                        if owner and repo.name then
                            key = tostring(owner) .. "/" .. tostring(repo.name)
                        else
                            key = repo.name
                        end
                    end
                    if key and rf.matches[tostring(key)] then
                        remote_match = true
                    end
                end

                if repo_match or patch_match or remote_match then
                    table.insert(filtered, repo)
                end
            end
        else
            local passes_general = self:matchesGeneralFilters(repo, self.browser_state)
            if passes_general then
                local local_match
                if search_active then
                    local_match = self:repoMatchesSearch(repo, search)
                else
                    local_match = true
                end

                local remote_match = false
                local rf = self.readme_filter
                if rf and rf.kind == "plugin" and rf.matches and self.browser_state.search_in_readme and search_active then
                    local key = repo.full_name
                    if not key then
                        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                        if owner and repo.name then
                            key = tostring(owner) .. "/" .. tostring(repo.name)
                        else
                            key = repo.name
                        end
                    end
                    if key and rf.matches[tostring(key)] then
                        remote_match = true
                    end
                end

                if local_match or remote_match then
                    table.insert(filtered, repo)
                end
            end
        end
    end
    self:sortRepoList(filtered)
    self._filtered_descriptors_cache = {
        key = cache_key,
        filtered = filtered,
        total = #descriptors
    }
    return filtered, #descriptors
end

function Storefront:getFilterSummary()
    self:ensureBrowserState()
    local filters = self.browser_state
    local parts = {}
    if filters.search_text and filters.search_text ~= "" then
        table.insert(parts, string.format(_([[Search "%s"]]), filters.search_text))
    end
    if filters.owner and filters.owner ~= "" then
        table.insert(parts, string.format(_([[Owner %s]]), filters.owner))
    end
    local stars = tonumber(filters.min_stars) or 0
    if stars > 0 then
        table.insert(parts, string.format(_([[≥ %s ⭐]]), tostring(stars)))
    end
    if #parts == 0 then
        return _([[Filters: (none)]])
    end
    return _([[Filters: ]]) .. table.concat(parts, ", ")
end

function Storefront:getCacheStatusLine(kind, total_count)
    local ts = Cache.getLastFetched(kind)
    local ts_text = ts and ts > 0 and formatTimestamp(ts) or _("Never")
    local label = kind == "plugin" and _("Plugins cached: %s (last update: %s)") or _("Patches cached: %s (last update: %s)")
    return string.format(label, tostring(total_count or 0), ts_text)
end

function Storefront:getCacheWarning(kind)
    local total = Cache.countRepos and Cache.countRepos(kind) or 0
    if total == 0 then
        return _("Cache empty. Refresh to retrieve repositories."), true
    end
    local ts = Cache.getLastFetched(kind)
    if ts and ts > 0 then
        local age = os.time() - ts
        if age > STALE_WARNING_SECONDS then
            return _("Cache is older than a week, consider refreshing."), false
        end
    end
    return nil, false
end

-- Returns true when the raw GitHub repo payload marks this entry as a fork.
-- The full API response is cached as `repo.data`, so no extra request is needed.
local function repoIsFork(repo)
    if not repo then return false end
    if repo.fork == true then return true end
    return repo.data and repo.data.fork == true or false
end

local function formatRepoEntry(repo, opts)
    opts = opts or {}
    local include_description = opts.include_description ~= false
    local include_updated = opts.include_updated ~= false
    local lines = {}
    local title = repo.full_name or repo.name or _("Repository")
    local stars = tonumber(repo.stars) or 0
    local meta = string.format("⭐ %d", stars)
    if repoIsFork(repo) then
        -- Keep the badge short; the browser list has limited horizontal room.
        meta = meta .. " · " .. _("(fork)")
    end
    table.insert(lines, string.format("• %s — %s", title, meta))
    local description = normalizeDescription(repo.description)
    if include_description and description ~= "" then
        table.insert(lines, "  " .. truncateText(description, 200))
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.created_at)
    if include_updated and ts and type(ts) == "string" then
        table.insert(lines, "  " .. string.format(_("Updated: %s"), ts:sub(1, 10)))
    end
    return table.concat(lines, "\n")
end

function Storefront:fetchPatchEntriesFromGitHub(repo)
    local owner = extractRepoOwner(repo)
    if not owner or not repo.name then
        return {}
    end
    local branch = (repo.data and repo.data.default_branch)
        or repo.default_branch
        or "HEAD"
    local tree, err = GitHub.fetchRepoTree(owner, repo.name, branch)
    if not tree or type(tree.tree) ~= "table" then
        logger.warn("Storefront patch tree fetch failed", repo.full_name or repo.name, err)
        return {}
    end
    local entries = {}
    for _, node in ipairs(tree.tree) do
        if node.type == "blob" then
            local filename = node.path and node.path:match("([^/]+)$")
            if isPatchFilename(filename) then
                table.insert(entries, {
                    filename = filename,
                    path = node.path,
                    display_path = node.path,
                    download_url = buildPatchDownloadUrl(owner, repo.name, branch, node.path),
                    branch = branch,
                    sha = node.sha,
                    size = node.size,
                })
            end
        end
    end
    table.sort(entries, function(a, b)
        return a.filename < b.filename
    end)
    return entries
end

function Storefront:storePatchEntriesForRepo(repo, source_pushed_at)
    local repo_id = repo.repo_id or repo.id
    if not repo_id then
        return
    end
    local entries = self:fetchPatchEntriesFromGitHub(repo)
    Cache.storePatchFiles(repo_id, entries, source_pushed_at)
end

-- Incremental refresh of every patch repository's patch_files rows.
-- For each repo we compare the freshly fetched pushed_at (from the search
-- result stored in `repo.data`) against the pushed_at recorded the last time
-- we successfully downloaded the tree. Unchanged repos skip the git/trees
-- API call entirely. Repos that dropped out of the search results are pruned
-- so that stale rows never survive across refreshes.
function Storefront:refreshPatchFileListings()
    local patch_repos = self:getRepoDescriptors("patch")

    local valid_repo_ids = {}
    for _, repo in ipairs(patch_repos) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        if repo_id then
            table.insert(valid_repo_ids, repo_id)
        end
    end
    if Cache.pruneOrphanPatchFiles then
        Cache.pruneOrphanPatchFiles(valid_repo_ids)
    end

    local refreshed, skipped = 0, 0
    for _, repo in ipairs(patch_repos) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        local remote_pushed_at = repo.data and repo.data.pushed_at
        if type(remote_pushed_at) ~= "string" or remote_pushed_at == "" then
            remote_pushed_at = nil
        end

        local cached_pushed_at = repo_id and Cache.getPatchFilePushedAt
            and Cache.getPatchFilePushedAt(repo_id) or nil
        local cached_count = (repo_id and Cache.countPatchFiles)
            and Cache.countPatchFiles(repo_id) or 0

        -- A tree fetch is required when any of the following is true:
        --   * We have no recorded pushed_at for this repo (first run after the
        --     schema bump, a prior failure, or a brand-new repo).
        --   * The remote pushed_at differs from the cached value.
        --   * Cache has zero rows AND the remote repo has commits: a previous
        --     attempt likely failed, so retry even if timestamps match.
        local must_refetch = (not cached_pushed_at)
            or (remote_pushed_at and cached_pushed_at ~= remote_pushed_at)
            or (cached_count == 0)

        if must_refetch then
            self:storePatchEntriesForRepo(repo, remote_pushed_at)
            refreshed = refreshed + 1
        else
            skipped = skipped + 1
        end
    end
    logger.dbg("Storefront patch tree refresh: refreshed=", refreshed, "skipped=", skipped)
end

function Storefront:getPatchEntriesForRepo(repo)
    self.patch_cache = self.patch_cache or {}
    local repo_id = repo.repo_id or repo.id
    local key = repo_id or repo.full_name or repo.name or "repo"
    local cache = self.patch_cache[key]
    local now = os.time()
    if cache and cache.entries and cache.timestamp and (now - cache.timestamp) < PATCH_CACHE_TTL then
        return cache.entries
    end

    local entries = {}
    if repo_id then
        local rows = Cache.listPatchFiles(repo_id)
        for _, row in ipairs(rows) do
            local filename = row.filename or (row.path and row.path:match("([^/]+)$"))
            if filename then
                table.insert(entries, {
                    filename = filename,
                    path = row.path,
                    display_path = row.path,
                    download_url = row.download_url,
                    branch = row.branch or "HEAD",
                    sha = row.sha,
                    size = row.size,
                })
            end
        end
    end

    table.sort(entries, function(a, b)
        return (a.filename or "") < (b.filename or "")
    end)
    self.patch_cache[key] = {
        entries = entries,
        timestamp = now,
    }
    return entries
end

function Storefront:collectPatchEntries(repos)
    local search = normalizedLower(self.browser_state.search_text)
    local sort_mode = tostring(self.browser_state.sort_mode)
    local cache_key = tostring(#repos) .. "_" .. search .. "_" .. (self.browser_state.search_in_readme and "1" or "0") .. "_" .. sort_mode
    if self._cached_patch_entries and self._cached_patch_entries_key == cache_key then
        return self._cached_patch_entries
    end

    local aggregated = {}
    local search_active = search ~= ""
    local rf = self.readme_filter
    for _, repo in ipairs(repos) do
        local patches = self:getPatchEntriesForRepo(repo)
        local stars = tonumber(repo.stars) or (repo.data and tonumber(repo.data.stargazers_count)) or 0
        local readme_repo_match = false
        if rf and rf.kind == "patch" and rf.matches and self.browser_state.search_in_readme and search_active then
            local key = repo.full_name
            if not key then
                local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                if owner and repo.name then
                    key = tostring(owner) .. "/" .. tostring(repo.name)
                else
                    key = repo.name
                end
            end
            if key and rf.matches[tostring(key)] then
                readme_repo_match = true
            end
        end
        local repo_matches_search = (not search_active)
            or self:repoMatchesSearch(repo, search)
            or readme_repo_match
        for _, patch in ipairs(patches) do
            local keep = true
            if search_active and not repo_matches_search then
                keep = self:patchMatchesSearch(patch, search)
            end
            if keep then
                aggregated[#aggregated + 1] = {
                    repo = repo,
                    patch = patch,
                    stars = stars,
                }
            end
        end
    end
    local result = self:sortPatchEntries(aggregated)
    self._cached_patch_entries = result
    self._cached_patch_entries_key = cache_key
    return result
end

local function getRepoVersionOrDate(repo, installed_lookup)
    local ver = repo.latest_version or repo.version or repo.tag_name or repo.release_tag
    if not ver and repo.data then
        ver = repo.data.tag_name or repo.data.latest_version or repo.data.version
    end
    if not ver and installed_lookup then
        local inst = (repo.full_name and installed_lookup[repo.full_name]) or (repo.id and installed_lookup["id:" .. tostring(repo.id)])
        if type(inst) == "table" then
            ver = inst.version or inst.tag_name or inst.latest_version
        end
    end
    if ver and type(ver) == "string" and ver ~= "" then
        if not ver:match("^v") and ver:match("^%d") then
            return "v" .. ver
        end
        return ver
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.created_at)
    return (ts and type(ts) == "string") and ts:sub(1, 10) or ""
end

function Storefront:makeRepoMenuItem(repo, installed_lookup, installed_fonts_map)
    local is_installed = false
    local kind = repo.kind or (self.browser_state and self.browser_state.kind)
    if kind == "font" then
        if self.isFontInstalled then
            is_installed = self:isFontInstalled(repo, installed_fonts_map)
        else
            local ok_fm, font_mgr = pcall(require, "storefront_font_mgr")
            if ok_fm and font_mgr and font_mgr.isFontInstalled then
                is_installed = font_mgr.isFontInstalled(repo, installed_fonts_map)
            else
                local font_name = repo.name or repo.font_family or repo.full_name or ""
                local clean_name = font_name:lower():gsub("[%s%-_]+", "")
                if installed_fonts_map then
                    is_installed = installed_fonts_map[clean_name] == true or installed_fonts_map[font_name] == true or installed_fonts_map[font_name:lower()] == true
                end
            end
        end
    elseif installed_lookup then
        if repo.full_name and (installed_lookup[repo.full_name] or installed_lookup[repo.full_name:lower()]) then
            is_installed = true
        elseif repo.id and installed_lookup["id:" .. tostring(repo.id)] then
            is_installed = true
        elseif installed_lookup.unmatched and repo.name then
            local low_name = repo.name:lower()
            local base_name = low_name:gsub("%.koplugin$", "")
            if installed_lookup.unmatched[low_name] or installed_lookup.unmatched[base_name] then
                is_installed = true
            end
        end
    end
    local stars = repoStarsValue(repo)
    local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)
    local badge = is_installed and _("Installed") or nil
    local description = normalizeDescription(repo.description)
    local kind_label
    if (repo.kind or (self.browser_state and self.browser_state.kind)) == "font" then
        kind_label = repo.category and repo.category:lower() or _("font")
    end

    local owner = repo.owner or (repo.data and repo.data.owner and (type(repo.data.owner) == "table" and repo.data.owner.login or tostring(repo.data.owner))) or ""
    local updated = getRepoVersionOrDate(repo, installed_lookup)

    local user_thumbs_up = tonumber(repo.user_thumbs_up) or (repo.data and tonumber(repo.data.user_thumbs_up)) or 0
    local user_thumbs_down = tonumber(repo.user_thumbs_down) or (repo.data and tonumber(repo.data.user_thumbs_down)) or 0

    local extracted_id = repo.id or repo.repo_id or (repo.data and (repo.data.id or repo.data.repo_id))
    return {
        id = extracted_id,
        repo_id = extracted_id,
        repo = repo,
        name = repo.name or repo.full_name or _("Repository"),
        kind = repo.kind or (self.browser_state and self.browser_state.kind),
        font_family = repo.font_family,
        font_file = repo.font_file,
        repo_name = repo.name,
        category = repo.category,
        license = repo.license,
        download_url = repo.download_url,
        owner = owner,
        stars_fmt = stars_fmt,
        user_thumbs_up = user_thumbs_up,
        user_thumbs_down = user_thumbs_down,
        updated = updated,
        description = description,
        kind_label = kind_label,
        badge = badge,
        text = formatRepoEntry(repo),
        installed = is_installed,
        is_entry = true,
        keep_menu_open = true,
        callback = function()
            self:promptRepoAction(repo)
        end,
        hold_callback = function()
            self:showReadme(repo)
        end,
    }
end

function Storefront:makePatchMenuItem(repo, patch)
    local stars = tonumber(repo.stars) or (repo.data and tonumber(repo.data.stargazers_count)) or 0
    local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)
    local lines = { string.format("• %s — ⭐ %d", patch.filename, stars) }
    if patch.display_path and patch.display_path ~= patch.filename then
        table.insert(lines, "  " .. patch.display_path)
    end
    local repo_title = repo.full_name or repo.name or ""
    if repo_title ~= "" then
        if repoIsFork(repo) then
            repo_title = repo_title .. " " .. _("(fork)")
        end
        table.insert(lines, "  " .. repo_title)
    end
    local extracted_patch_id = repo.id or repo.repo_id or (repo.data and (repo.data.id or repo.data.repo_id)) or patch.repo_id or patch.id
    return {
        id = extracted_patch_id,
        repo_id = extracted_patch_id,
        repo = repo,
        name = patch.filename,
        owner = getRepoOwner(repo) or "",
        stars_fmt = stars_fmt,
        updated = "",
        description = patch.display_path or "",
        badge = nil,
        text = table.concat(lines, "\n"),
        is_entry = true,
        keep_menu_open = true,
        callback = function()
            self:promptPatchAction(repo, patch)
        end,
        hold_callback = function()
            self:promptPatchAction(repo, patch)
        end,
    }
end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local _sample_height_cache = {}

local function getSampleHeights(item_w)
    local cached = _sample_height_cache[item_w]
    if cached then return cached end

    local pad = Size.padding.default
    local sc = function(val) return Device.screen:scaleBySize(val) end

    local thumb_h
    local ok_t, widget_t = pcall(function()
        return StorefrontListItem:new{
            entry = {
                name = "Sample Screensaver",
                owner = "author",
                updated = "2026-08-01",
                kind_label = "Screensaver",
                description = "Sample Description",
                thumbnail_file = "sample.jpg",
                is_entry = true,
            },
            width = item_w,
        }
    end)
    thumb_h = (ok_t and widget_t and widget_t.getSize) and widget_t:getSize().h or (sc(80) + 2 * pad)

    local update_h
    local ok_u, widget_u = pcall(function()
        return StorefrontListItem:new{
            entry = {
                name = "Sample Plugin",
                updated = "2026-08-01",
                kind_label = "Plugin · Default",
                version_transition = "1.0.0 -> 2.0.0",
                badge = _("Update"),
                is_entry = true,
                is_update_item = true,
            },
            width = item_w,
        }
    end)
    update_h = (ok_u and widget_u and widget_u.getSize) and widget_u:getSize().h or sc(60)

    local desc_3line_h
    local ok_3, widget_3 = pcall(function()
        return StorefrontListItem:new{
            entry = {
                name = "Sample Plugin",
                owner = "sample_author",
                stars_fmt = "100",
                updated = "2026-08-01",
                kind_label = "Plugin",
                description = "Sample plugin description text for measuring widget height",
                is_entry = true,
            },
            width = item_w,
        }
    end)
    desc_3line_h = (ok_3 and widget_3 and widget_3.getSize) and widget_3:getSize().h or sc(80)

    local desc_2line_h
    local ok_2, widget_2 = pcall(function()
        return StorefrontListItem:new{
            entry = {
                name = "Sample Plugin",
                owner = "sample_author",
                stars_fmt = "100",
                updated = "2026-08-01",
                kind_label = "Plugin",
                description = "",
                is_entry = true,
            },
            width = item_w,
        }
    end)
    desc_2line_h = (ok_2 and widget_2 and widget_2.getSize) and widget_2:getSize().h or sc(56)

    local clear_h
    local ok_c, widget_c = pcall(function()
        return StorefrontListItem:new{
            entry = {
                text = _("Clear search/filters"),
                is_clear_button = true,
            },
            width = item_w,
        }
    end)
    clear_h = (ok_c and widget_c and widget_c.getSize) and widget_c:getSize().h or sc(36)

    cached = {
        thumb = thumb_h,
        update = update_h,
        three_line = desc_3line_h,
        two_line = desc_2line_h,
        clear = clear_h,
    }
    _sample_height_cache[item_w] = cached
    return cached
end

function Storefront:calculateAvailableListHeight(tab_name)
    local screen_h = Device.screen:getHeight()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    
    local pad = Size.padding.default
    local thin = Size.line.thin
    local span = Size.span.vertical_default

    -- Header height: header_group buttons are sc(48) high inside FrameContainer with pad top & bottom
    local title_height = sc(48) + 2 * pad

    -- Tab bar height: text font 18 (~sc(22)) + VerticalSpan(sc(4)) + underline(sc(3)) + padding_top(sc(12))
    local tab_font_h = sc(22)
    local tab_bar_height = sc(12) + tab_font_h + sc(4) + sc(3)

    -- Footer height: CenterContainer h=sc(48) + padding_top(sc(4)) + padding_bottom(sc(4))
    local footer_height = sc(48) + sc(8)

    local has_toolbar = (tab_name == "Installed" and self.browser_state and self.browser_state.show_filter_bar_installed ~= false)
        or (tab_name == "Plugins" and self.browser_state and self.browser_state.show_filter_bar_plugins == true)
        or (tab_name == "Patches" and self.browser_state and self.browser_state.show_filter_bar_patches == true)
        or (tab_name == "Fonts" and self.browser_state and self.browser_state.show_filter_bar_fonts == true)
        or (tab_name == "Screensavers" and self.browser_state and self.browser_state.show_filter_bar_screensavers ~= false)

    local toolbar_height = 0
    local divider_height = thin + span
    if has_toolbar then
        local btn_font_h = sc(18)
        toolbar_height = (btn_font_h + sc(26)) + span
        divider_height = divider_height + thin + span
    end

    local body_height = screen_h - title_height - tab_bar_height - footer_height - toolbar_height - divider_height
    if body_height < math.floor(screen_h * 0.5) then
        body_height = math.floor(screen_h * 0.5)
    end

    local container_padding = 2 * pad
    return body_height - container_padding + thin
end

function Storefront:paginateEntries(items, tab_name, available_list_height)
    if not items or #items == 0 then
        return {}, 1
    end

    -- The browser dialog owns its chrome.  Its measured viewport is passed in
    -- by showBrowser so this pagination cannot drift when a tab gains a
    -- toolbar, a larger button label, or a different screen scale.
    local avail_height = available_list_height or self:calculateAvailableListHeight(tab_name)
    local screen_w = Device.screen:getWidth()
    local pad = Size.padding.default
    local thin = Size.line.thin
    local item_w = screen_w - 2 * pad
    local samples = getSampleHeights(item_w)

    local pages = {}
    local current_page = {}
    local current_h = 0

    for i, entry in ipairs(items) do
        local item_h = entry._measured_h
        if not item_h then
            if entry.is_entry then
                if entry.thumbnail_file then
                    item_h = samples.thumb
                elseif entry.is_update_item then
                    item_h = samples.update
                elseif entry.description and entry.description ~= "" then
                    item_h = samples.three_line
                else
                    item_h = samples.two_line
                end
                entry._measured_h = item_h
            elseif entry.is_clear_button then
                item_h = samples.clear
                entry._measured_h = item_h
            else
                local face = Font:getFace("smallinfofont")
                local text_box = TextBoxWidget:new{
                    text = entry.text or "",
                    width = item_w - 2 * pad,
                    face = face,
                    alignment = "left",
                    justified = false,
                    height_adjust = true,
                }
                item_h = text_box:getSize().h + 2 * pad
                entry._measured_h = item_h
            end
        end

        local slot_h = (item_h and item_h > 0 and item_h or Device.screen:scaleBySize(60)) + thin

        if #current_page > 0 and (current_h + slot_h > avail_height) then
            table.insert(pages, current_page)
            current_page = {}
            current_h = 0
        end

        table.insert(current_page, entry)
        current_h = current_h + slot_h
    end

    if #current_page > 0 then
        table.insert(pages, current_page)
    end

    local total_pages = math.max(1, #pages)
    local page_num = math.min(math.max(self.browser_state and self.browser_state.page or 1, 1), total_pages)
    if self.browser_state and self.browser_state.page ~= page_num then
        self.browser_state.page = page_num
        self:saveBrowserState()
    end

    local page_items = pages[page_num] or {}
    for _, entry in ipairs(page_items) do
        entry.separator = true
    end

    return page_items, total_pages
end



function Storefront:ensureInstalledState()
    if not self.installed_state then
        self.installed_state = StorefrontSettings:readSetting("installed_state") or {}
    end
    self.installed_state.filter_type = self.installed_state.filter_type or "all"
    self.installed_state.filter_default = self.installed_state.filter_default or "all"
    self.installed_state.filter_status = self.installed_state.filter_status or "all"
    self.installed_state.search_text = self.installed_state.search_text or ""
    self.installed_state.sort_mode = self.installed_state.sort_mode or "name_asc"
end

function Storefront:saveInstalledState()
    if self.installed_state then
        StorefrontSettings:saveSetting("installed_state", self.installed_state)
        StorefrontSettings:flush()
    end
end

function Storefront:buildInstalledEntries(available_list_height)
    self:ensureBrowserState()
    self:ensureInstalledState()

    local filter_type = self.installed_state.filter_type or "all"
    local filter_default = self.installed_state.filter_default or "all"
    local filter_status = self.installed_state.filter_status or "all"
    local raw_search = (self.installed_state and self.installed_state.search_text ~= "" and self.installed_state.search_text) or (self.browser_state and self.browser_state.search_text) or ""
    local search_text = util.trim(raw_search):lower()
    local filter_owner = util.trim(self.browser_state and self.browser_state.owner or ""):lower()
    local filter_min_stars = tonumber(self.browser_state and self.browser_state.min_stars) or 0
    local sort_mode = self.installed_state.sort_mode or "name_asc"

    local installed_plugins = self:listInstalledPlugins()
    local installed_patches = self:listInstalledPatches()
    local p_count = #installed_plugins
    local pt_count = #installed_patches
    local p_sample = (p_count > 0 and (installed_plugins[1].fullname or installed_plugins[1].name or installed_plugins[1].dirname)) or ""

    local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local p_last_checked = tostring(self.updates_state and self.updates_state.last_checked or 0)
    local pt_last_checked = tostring(self.patch_updates_state and self.patch_updates_state.last_checked or 0)
    local cache_key = string.format("%s|%s|%s|%s|%s|%d|%s|%d|%s|%s|%d|%d|%s",
        filter_type, filter_default, filter_status, search_text, filter_owner, filter_min_stars, sort_mode, gen, p_last_checked, pt_last_checked, p_count, pt_count, p_sample
    )

    local items
    if self._installed_tab_items_cache and self._installed_tab_items_cache.key == cache_key then
        items = self._installed_tab_items_cache.items
    else
        local plugin_records = getInstallRecordsMap()
        local patch_records = getPatchRecordsMap()

        local update_summary = self:collectUpdateSummary()
        local patch_update_summary = self:collectPatchUpdateSummary()
        local plugin_updates_map = {}
        for i, item in ipairs(update_summary.data or {}) do
            if item.plugin and item.plugin.dirname then
                plugin_updates_map[item.plugin.dirname] = item.has_update
            end
        end
        local patch_updates_map = {}
        for i, item in ipairs(patch_update_summary.data or {}) do
            if item.patch and item.patch.filename then
                patch_updates_map[item.patch.filename] = item.needs_update
            end
        end

        items = {}

        local getAssetPath = function(filename)
            local info = debug.getinfo(1, "S")
            local dir = info.source:match("^@(.*[/\\])") or ""
            return dir .. "assets/" .. filename
        end

    -- 1. Plugins
    if filter_type == "all" or filter_type == "plugin" then
        for i, plugin in ipairs(installed_plugins) do
            local disabled = isPluginDisabled(plugin.dirname)
            local is_default = isDefaultPlugin(plugin)
            local has_update = plugin_updates_map[plugin.dirname] == true

            local match_type = true
            if filter_default == "exclude_default" and is_default then match_type = false end
            if filter_default == "default_only" and not is_default then match_type = false end

            local match_status = true
            if filter_status == "enabled" and disabled then match_status = false end
            if filter_status == "disabled" and not disabled then match_status = false end

            local match_search = true
            local fullname = (plugin.meta and plugin.meta.fullname) or plugin.fullname
            local shortname = (plugin.meta and plugin.meta.name) or plugin.shortname
            local display_name = (fullname and fullname ~= "") and fullname or (plugin.name or plugin.dirname)

            if search_text ~= "" then
                local full_lower = (fullname or ""):lower()
                local short_lower = (shortname or plugin.name or ""):lower()
                local dirname = (plugin.dirname or ""):lower():gsub("%.koplugin$", "")
                local record = plugin_records[plugin.dirname]
                local owner = (record and record.owner or ""):lower()
                local desc = (record and record.repo_description or ""):lower()
                local repo = (record and record.repo or ""):lower()
                if not (full_lower:find(search_text, 1, true) or short_lower:find(search_text, 1, true) or dirname:find(search_text, 1, true) or owner:find(search_text, 1, true) or desc:find(search_text, 1, true) or repo:find(search_text, 1, true)) then
                    match_search = false
                end
            end

            if filter_owner ~= "" then
                local record = plugin_records[plugin.dirname]
                local owner = (record and record.owner or ""):lower()
                if not owner:find(filter_owner, 1, true) then
                    match_search = false
                end
            end

            if filter_min_stars > 0 then
                local record = plugin_records[plugin.dirname]
                local stars = (record and tonumber(record.stars)) or 0
                if stars < filter_min_stars then
                    match_search = false
                end
            end

            if match_type and match_status and match_search then
                local record = plugin_records[plugin.dirname]
                local kind_parts = { _("Plugin") }
                if is_default then
                    table.insert(kind_parts, _("Default"))
                end
                local meta_kind = table.concat(kind_parts, " · ")

                table.insert(items, {
                    name = display_name,
                    owner = record and record.owner or "",
                    stars_fmt = (record and record.stars) and tostring(record.stars) or "0",
                    updated = formatTimestamp(plugin.latest_mtime),
                    mtime = plugin.latest_mtime or 0,
                    kind_label = meta_kind,
                    description = record and record.repo_description or "",
                    badge_icon = getAssetPath(disabled and "square.svg" or "check-square.svg"),
                    badge = has_update and _("Update") or nil,
                    is_entry = true,
                    is_installed_item = true,
                    is_plugin = true,
                    is_disabled = disabled,
                    is_default = is_default,
                    dirname = plugin.dirname,
                    on_badge_tap = function()
                        self:togglePluginDisabled(plugin.dirname)
                    end,
                    callback = function()
                        local DetailsDialog = require("storefront_details_dialog")
                        local cached_repo
                        if record then
                            if record.repo_id then cached_repo = Cache.getRepo(record.repo_id) end
                            if not cached_repo and record.owner and record.repo then cached_repo = Cache.getRepoByName(record.owner, record.repo) end
                        end
                        local repo = cached_repo or {
                            name = record and record.repo or plugin.dirname,
                            owner = record and record.owner or "",
                            full_name = record and record.repo_full_name or "",
                            id = record and record.repo_id or nil,
                            description = record and record.repo_description or "",
                            stars = 0,
                        }
                        local details_dialog = DetailsDialog:new{
                            Storefront = self,
                            repo = repo,
                            kind = "plugin",
                            update_item = { plugin = plugin, record = record, needs_update = has_update },
                        }
                        details_dialog:show()
                    end,
                })
            end
        end
    end

    -- 2. Patches
    if filter_type == "all" or filter_type == "patch" then
        for i, patch in ipairs(installed_patches) do
            local disabled = patch.disabled or isPatchDisabled(patch.filename)
            local is_default = false
            local has_update = patch_updates_map[patch.filename] == true

            local match_type = true
            if filter_default == "exclude_default" and is_default then match_type = false end
            if filter_default == "default_only" and not is_default then match_type = false end

            local match_status = true
            if filter_status == "enabled" and disabled then match_status = false end
            if filter_status == "disabled" and not disabled then match_status = false end

            local record = patch_records[patch.filename]
            local match_search = true
            if search_text ~= "" then
                local filename = (patch.filename or ""):lower()
                local owner = (record and record.owner or ""):lower()
                local desc = (record and record.repo_description or ""):lower()
                local repo = (record and record.repo or ""):lower()
                if not (filename:find(search_text, 1, true) or owner:find(search_text, 1, true) or desc:find(search_text, 1, true) or repo:find(search_text, 1, true)) then
                    match_search = false
                end
            end

            if filter_owner ~= "" then
                local owner = (record and record.owner or ""):lower()
                if not owner:find(filter_owner, 1, true) then
                    match_search = false
                end
            end

            if filter_min_stars > 0 then
                local stars = (record and tonumber(record.stars)) or 0
                if stars < filter_min_stars then
                    match_search = false
                end
            end

            if match_type and match_status and match_search then
                table.insert(items, {
                    name = patch.filename,
                    owner = record and record.owner or "",
                    stars_fmt = (record and record.stars and tonumber(record.stars) and tonumber(record.stars) > 0) and tostring(record.stars) or "0",
                    updated = formatTimestamp(patch.latest_mtime),
                    mtime = patch.latest_mtime or 0,
                    kind_label = _("Patch"),
                    description = record and record.repo_description or "",
                    badge_icon = getAssetPath(disabled and "square.svg" or "check-square.svg"),
                    badge = has_update and _("Update") or nil,
                    is_entry = true,
                    is_installed_item = true,
                    is_plugin = false,
                    is_disabled = disabled,
                    is_default = false,
                    filename = patch.filename,
                    on_badge_tap = function()
                        self:togglePatchDisabled(patch.filename)
                    end,
                    callback = function()
                        local DetailsDialog = require("storefront_details_dialog")
                        local cached_repo
                        if record then
                            if record.repo_id then cached_repo = Cache.getRepo(record.repo_id) end
                            if not cached_repo and record.owner and record.repo then cached_repo = Cache.getRepoByName(record.owner, record.repo) end
                        end
                        local repo = cached_repo or {
                            name = record and record.repo or patch.filename,
                            owner = record and record.owner or "",
                            full_name = record and record.repo_full_name or "",
                            id = record and record.repo_id or nil,
                            description = record and record.repo_description or "",
                            stars = 0,
                        }
                        local patch_entry = {
                            filename = patch.filename,
                            path = patch.path,
                            display_path = record and record.path or patch.path,
                        }
                        local details_dialog = DetailsDialog:new{
                            Storefront = self,
                            repo = repo,
                            patch = patch_entry,
                            kind = "patch",
                            update_item = { patch = patch, record = record, needs_update = has_update },
                        }
                        details_dialog:show()
                    end,
                })
            end
        end
    end

    -- 3. Fonts
    if filter_type == "all" or filter_type == "font" then
        local installed_fonts = listInstalledFonts()
        for i, font_rec in ipairs(installed_fonts) do
            local font_name = font_rec.font_name or font_rec.repo or ""
            if font_name ~= "" then
                local catalog_repo = nil
                local ok_cache, Cache2 = pcall(require, "storefront_cache")
                if ok_cache and Cache2 then
                    catalog_repo = Cache2.getRepoByName(font_rec.owner or "", font_name)
                        or Cache2.getRepoByName("", font_name)
                end

                local match_search = true
                if search_text ~= "" then
                    local f_name = font_name:lower()
                    local f_owner = (font_rec.owner or (catalog_repo and catalog_repo.owner) or ""):lower()
                    local f_family = (catalog_repo and catalog_repo.font_family or ""):lower()
                    local f_desc = (catalog_repo and catalog_repo.description or ""):lower()
                    local f_full = (font_rec.full_name or (catalog_repo and catalog_repo.full_name) or ""):lower()
                    if not (f_name:find(search_text, 1, true) or f_owner:find(search_text, 1, true) or f_family:find(search_text, 1, true) or f_desc:find(search_text, 1, true) or f_full:find(search_text, 1, true)) then
                        match_search = false
                    end
                end

                if filter_owner ~= "" then
                    local f_owner = (font_rec.owner or (catalog_repo and catalog_repo.owner) or ""):lower()
                    if not f_owner:find(filter_owner, 1, true) then
                        match_search = false
                    end
                end

                if filter_min_stars > 0 then
                    local stars = (catalog_repo and tonumber(catalog_repo.stars)) or 0
                    if stars < filter_min_stars then
                        match_search = false
                    end
                end

                if match_search then

                    table.insert(items, {
                        name = font_name,
                        owner = font_rec.owner or "",
                        stars_fmt = (catalog_repo and catalog_repo.stars and tonumber(catalog_repo.stars) and tonumber(catalog_repo.stars) > 0) and tostring(catalog_repo.stars) or nil,
                        updated = formatTimestamp(font_rec.installed_at),
                        mtime = font_rec.installed_at or 0,
                        kind_label = _("Font"),
                        description = (catalog_repo and catalog_repo.description) or "",
                        badge = font_rec.pending_download and _("Offline Regular") or nil,
                        is_entry = true,
                        is_installed_item = true,
                        is_font = true,
                        kind = "font",
                        font_name = font_name,
                        font_family = catalog_repo and catalog_repo.font_family or font_name,
                        font_file = catalog_repo and catalog_repo.font_file or font_rec.font_file,
                        callback = function()
                            local DetailsDialog = require("storefront_details_dialog")
                            local repo = catalog_repo or {
                                name = font_name,
                                owner = font_rec.owner or "",
                                full_name = font_rec.full_name or font_name,
                                download_url = font_rec.download_url,
                                description = "",
                                stars = 0,
                                font_family = font_name,
                            }
                            if not repo.download_url and catalog_repo then
                                repo.download_url = catalog_repo.download_url
                            end
                            local details_dialog = DetailsDialog:new{
                                Storefront = self,
                                repo = repo,
                                kind = "font",
                            }
                            details_dialog:show()
                        end,
                    })
                end
            end
        end
    end

    -- 4. Screensavers
    if filter_type == "all" or filter_type == "screensaver" then
        local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
        local local_ss = StorefrontScreensaverMgr.listLocalScreensavers()
        local ss_settings = StorefrontScreensaverMgr.getScreensaverSettings()

        for i, ss_item in ipairs(local_ss) do
            local is_active_single = ss_item.is_active_single and ss_settings.effective_mode == "single"
            local is_in_shuffle = ss_settings.effective_mode == "shuffle"
            local badge_str = is_active_single and _("Active Single") or (is_in_shuffle and _("Shuffle Pool") or nil)

            local match_search = true
            if search_text ~= "" then
                local s_title = (ss_item.title or ""):lower()
                local s_fname = (ss_item.filename or ""):lower()
                if not (s_title:find(search_text, 1, true) or s_fname:find(search_text, 1, true)) then
                    match_search = false
                end
            end

            if match_search then
                local desc_str = (ss_item.author and ss_item.author ~= "") and (_("By ") .. ss_item.author) or ss_item.filename
                table.insert(items, {
                    name = ss_item.title or ss_item.filename,
                    owner = ss_item.author or "",
                    updated = formatTimestamp(ss_item.mtime),
                    mtime = ss_item.mtime or 0,
                    kind_label = _("Screensaver"),
                    description = desc_str,
                    badge = badge_str,
                    thumbnail_file = ss_item.thumbnail_file or ss_item.filepath,
                    is_entry = true,
                    is_installed_item = true,
                    is_screensaver = true,
                    kind = "screensaver",
                    filepath = ss_item.filepath,
                    callback = function()
                        local detail_entry = ss_item
                        local StorefrontScreensaversUI = require("storefront_screensavers_ui")
                        if StorefrontScreensaversUI and StorefrontScreensaversUI.getCachedCatalog then
                            local cat = StorefrontScreensaversUI.getCachedCatalog()
                            if type(cat) == "table" then
                                for _, cat_entry in ipairs(cat) do
                                    if (ss_item.id and cat_entry.id == ss_item.id) or
                                       (cat_entry.filename and cat_entry.filename == ss_item.filename) or
                                       (ss_item.filepath and cat_entry.filename and ss_item.filepath:find(cat_entry.filename, 1, true)) then
                                        detail_entry = cat_entry
                                        break
                                    end
                                end
                            end
                        end
                        local ok_det, StorefrontScreensaverDetail = pcall(require, "storefront_screensaver_detail")
                        if ok_det and StorefrontScreensaverDetail then
                            local detail = StorefrontScreensaverDetail:new{
                                item   = detail_entry,
                                parent = self,
                            }
                            detail:show()
                        end
                    end,
                })
            end
        end
    end

    table.sort(items, function(a, b)
        local na = tostring(a and a.name or ""):lower()
        local nb = tostring(b and b.name or ""):lower()
        if sort_mode == "name_desc" then
            if na ~= nb then return na > nb end
        elseif sort_mode == "date_desc" then
            local ma = tonumber(a and a.mtime) or 0
            local mb = tonumber(b and b.mtime) or 0
            if ma ~= mb then return ma > mb end
        elseif sort_mode == "date_asc" then
            local ma = tonumber(a and a.mtime) or 0
            local mb = tonumber(b and b.mtime) or 0
            if ma ~= mb then return ma < mb end
        elseif sort_mode == "type" then
            local ka = tostring(a and a.kind_label or "")
            local kb = tostring(b and b.kind_label or "")
            if ka ~= kb then return ka < kb end
        elseif sort_mode == "status" then
            local da = (a and a.is_disabled) and true or false
            local db = (b and b.is_disabled) and true or false
            if da ~= db then return not da end
        end
        return na < nb
    end)
        self._installed_tab_items_cache = { key = cache_key, items = items }
    end

    if #items == 0 then
        local page_items = {}
        table.insert(page_items, {
            text = _("No installed items found."),
            select_enabled = false,
        })
        table.insert(page_items, {
            text = _("Clear search/filters"),
            is_clear_button = true,
            callback = function()
                self:clearSearchAndFilters()
            end,
        })
        return page_items, 1
    end

    return self:paginateEntries(items, "Installed", available_list_height)
end

function Storefront:hasActiveFilters(tab)
    self:ensureBrowserState()
    self:ensureInstalledState()
    tab = tab or self.browser_state.tab or "Plugins"

    if tab == "Installed" then
        local raw_st = (self.installed_state and self.installed_state.search_text ~= "" and self.installed_state.search_text) or (self.browser_state and self.browser_state.search_text) or ""
        local st = util.trim(raw_st)
        local ft = self.installed_state.filter_type or "all"
        local fd = self.installed_state.filter_default or "all"
        local fs = self.installed_state.filter_status or "all"
        local sm = self.installed_state.sort_mode or "name_asc"
        return st ~= "" or ft ~= "all" or fd ~= "all" or fs ~= "all" or sm ~= "name_asc"
    elseif tab == "Screensavers" then
        local cat = (self.browser_state and self.browser_state.screensaver_category or ""):lower()
        local cats = self.browser_state and self.browser_state.screensaver_categories
        local has_cats = type(cats) == "table" and next(cats) and not cats["all"]
        local sort = self.browser_state and self.browser_state.screensaver_sort or "downloads"
        local st = util.trim(self.browser_state and self.browser_state.search_text or "")
        local ow = util.trim(self.browser_state and self.browser_state.owner or "")
        local srch = (self.browser_state and self.browser_state.screensaver_search or ""):lower()
        return has_cats or (cat ~= "" and cat ~= "all") or (sort ~= "downloads") or (st ~= "") or (ow ~= "") or (srch ~= "")
    elseif tab == "Updates" then
        return false
    else
        local st = util.trim(self.browser_state.search_text or "")
        local ow = util.trim(self.browser_state.owner or "")
        local ms = tonumber(self.browser_state.min_stars) or 0
        local fc = self.browser_state.font_category or "all"
        local sm = self.browser_state.sort_mode or "stars_desc"
        return st ~= "" or ow ~= "" or ms > 0 or (tab == "Fonts" and fc ~= "all") or sm ~= "stars_desc"
    end
end

function Storefront:clearSearchText()
    self:ensureBrowserState()
    self:ensureInstalledState()
    self.browser_state.search_text = ""
    self.installed_state.search_text = ""
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:saveBrowserState()
    self:saveInstalledState()
    self:reopenBrowser()
end

function Storefront:clearSearchAndFilters()
    self:ensureBrowserState()
    self:ensureInstalledState()

    self.browser_state.search_text = ""
    self.browser_state.owner = ""
    self.browser_state.min_stars = 0
    self.browser_state.font_category = "all"
    self.browser_state.sort_mode = "stars_desc"
    self.browser_state.screensaver_category = ""
    self.browser_state.screensaver_categories = nil
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil

    self.installed_state.search_text = ""
    self.installed_state.filter_type = "all"
    self.installed_state.filter_default = "all"
    self.installed_state.filter_status = "all"
    self.installed_state.sort_mode = "name_asc"

    if self.updates_state then
        self.updates_state.filter_only_outdated = false
    end
    if self.patch_updates_state then
        self.patch_updates_state.filter_only_outdated = false
    end

    self:saveBrowserState()
    self:saveInstalledState()
    self:reopenBrowser()
end

function Storefront:buildScreensaverEntries(available_list_height, available_list_width)
    local StorefrontScreensavers = require("storefront_screensavers_ui")
    local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")

    -- Fetch catalog (cached after first call)
    if not self.screensavers_cache then
        pcall(function()
            StorefrontScreensavers.fetchCatalog(function(ok, catalog)
                self.screensavers_cache = catalog
            end)
        end)
    end
    local catalog = self.screensavers_cache or {}

    -- ---- Widget helpers ---------------------------------------------------
    local sc       = function(val) return Device.screen:scaleBySize(val) end
    local sw       = Device.screen:getWidth()
    local gap      = sc(10)
    local card_pad = sc(5)
    local usable_w = available_list_width or (sw - sc(24))

    -- Accurate card overhead: padding (top+bottom), card border (top+bottom), image border (top+bottom), vertical spans, title text, and meta text
    local card_overhead = (card_pad * 2) + sc(46)

    -- Determine rows: always at least 2 rows; 3 rows on taller screens
    local usable_h = available_list_height or (sh - sc(210))
    local target_rows = 2
    local available_for_3 = usable_h - (gap * 2) - sc(16)
    local max_card_h_3 = math.floor(available_for_3 / 3)
    local inner_img_h_3 = max_card_h_3 - card_overhead
    if usable_h >= sc(680) and inner_img_h_3 >= sc(140) then
        target_rows = 3
    end

    local rows_per_page = target_rows
    local available_for_cards = usable_h - (gap * (target_rows - 1)) - sc(16)
    local card_h = math.floor(available_for_cards / target_rows)
    local img_h  = math.max(sc(60), card_h - card_overhead)

    -- Calculate columns based on natural 3:4 portrait image aspect ratio scaled from height
    local ideal_img_w = math.floor(img_h * 3 / 4)
    local ideal_card_w = ideal_img_w + (card_pad * 2)
    local candidate_cols = math.floor((usable_w + gap) / (ideal_card_w + gap))
    local cols = math.max(3, math.min(6, candidate_cols))

    local card_w   = math.floor((usable_w - gap * (cols - 1)) / cols)
    local inner_w  = card_w - (card_pad * 2)
    local page_size = rows_per_page * cols

    -- ---- Filter & sort the catalog ----------------------------------------
    self:ensureBrowserState()
    local ss_cat  = (self.browser_state.screensaver_category or ""):lower()
    local ss_cats = self.browser_state.screensaver_categories
    local ss_sort = self.browser_state.screensaver_sort or "downloads"  -- "downloads" | "recent" | "popular" | "az" | "za"
    local raw_search = util.trim((self.browser_state.search_text and self.browser_state.search_text ~= "") and self.browser_state.search_text or (self.browser_state.screensaver_search or ""))
    local raw_owner  = util.trim(self.browser_state.owner or "")
    local search_terms = extractSearchTerms(raw_search)
    local owner_term   = normalizedLower(raw_owner)

    local cats_key = ""
    if type(ss_cats) == "table" then
        local cat_keys = {}
        for k, v in pairs(ss_cats) do
            if v then table.insert(cat_keys, k) end
        end
        table.sort(cat_keys)
        cats_key = table.concat(cat_keys, ",")
    end
    local ss_cache_key = string.format("%s|%s|%s|%s|%s|%d",
        tostring(ss_cat), cats_key, tostring(ss_sort),
        tostring(raw_search), tostring(raw_owner), #catalog)

    local filtered
    if self._filtered_screensavers_cache and self._filtered_screensavers_cache.key == ss_cache_key then
        filtered = self._filtered_screensavers_cache.filtered
    else
        filtered = {}
        for cat_idx, entry in ipairs(catalog) do
            entry._catalog_index = entry._catalog_index or cat_idx
            local pass = true
            -- 1. Category filter
            if type(ss_cats) == "table" and next(ss_cats) and not ss_cats["all"] then
                local mapped_cats = StorefrontUtils.getMappedScreensaverCategories(entry.category)
                local match_found = false
                for _, mc in ipairs(mapped_cats) do
                    if ss_cats[mc:lower()] then
                        match_found = true
                        break
                    end
                end
                if not match_found then pass = false end
            elseif ss_cat ~= "" and ss_cat ~= "all" then
                local mapped_cats = StorefrontUtils.getMappedScreensaverCategories(entry.category)
                local match_found = false
                for _, mc in ipairs(mapped_cats) do
                    if mc:lower() == ss_cat then
                        match_found = true
                        break
                    end
                end
                if not match_found then pass = false end
            end

            -- 2. Main search bar: matches titles and tags
            if pass and search_terms then
                local title_val = normalizedLower(entry.title or entry.name or "")
                local tag_haystacks = {}
                if type(entry.tags) == "table" then
                    for _, tag in ipairs(entry.tags) do
                        local t_norm = normalizedLower(tag)
                        if t_norm ~= "" then
                            table.insert(tag_haystacks, t_norm)
                        end
                    end
                elseif type(entry.tags) == "string" and entry.tags ~= "" then
                    for tag in entry.tags:gmatch("[^,]+") do
                        local t_norm = normalizedLower(tag)
                        if t_norm ~= "" then
                            table.insert(tag_haystacks, t_norm)
                        end
                    end
                end

                for _, term in ipairs(search_terms) do
                    local term_match = false
                    if title_val:find(term, 1, true) then
                        term_match = true
                    else
                        for _, tag_val in ipairs(tag_haystacks) do
                            if tag_val:find(term, 1, true) then
                                term_match = true
                                break
                            end
                        end
                    end
                    if not term_match then
                        pass = false
                        break
                    end
                end
            end

            -- 3. Owner bar: matches submitter / author / attribution
            if pass and owner_term ~= "" then
                local owner_match = false
                local author_val = normalizedLower(entry.author)
                local submitter_val = normalizedLower(entry.submitter)
                local attribution_val = normalizedLower(entry.attribution)

                if (author_val ~= "" and author_val:find(owner_term, 1, true)) or
                   (submitter_val ~= "" and submitter_val:find(owner_term, 1, true)) or
                   (attribution_val ~= "" and attribution_val:find(owner_term, 1, true)) then
                    owner_match = true
                end

                if not owner_match then
                    pass = false
                end
            end

            if pass then table.insert(filtered, entry) end
        end

        if ss_sort == "popular" then
            local scores = {}
            local dl_scores = {}
            if ok_ratings and StorefrontRatings and StorefrontRatings.getRating then
                for _, entry in ipairs(filtered) do
                    local live_r = StorefrontRatings.getRating(entry)
                    scores[entry] = (live_r and (live_r.up - live_r.down)) or entry.likes or 0
                    dl_scores[entry] = (live_r and live_r.downloads) or entry.downloads or entry.download_count or entry.downloads_count or entry.installs or 0
                end
            else
                for _, entry in ipairs(filtered) do
                    scores[entry] = entry.likes or 0
                    dl_scores[entry] = entry.downloads or entry.download_count or entry.downloads_count or entry.installs or 0
                end
            end
            table.sort(filtered, function(a, b)
                local sa = scores[a] or 0
                local sb = scores[b] or 0
                if sa ~= sb then return sa > sb end
                local dla = dl_scores[a] or 0
                local dlb = dl_scores[b] or 0
                if dla ~= dlb then return dla > dlb end
                local ca = a._catalog_index or 0
                local cb = b._catalog_index or 0
                if ca ~= cb then return ca > cb end
                return (a.title or a.name or "") < (b.title or b.name or "")
            end)
        elseif ss_sort == "downloads" then
            local dl_scores = {}
            local scores = {}
            if ok_ratings and StorefrontRatings and StorefrontRatings.getRating then
                for _, entry in ipairs(filtered) do
                    local live_r = StorefrontRatings.getRating(entry)
                    dl_scores[entry] = (live_r and live_r.downloads) or entry.downloads or entry.download_count or entry.downloads_count or entry.installs or 0
                    scores[entry] = (live_r and (live_r.up - live_r.down)) or entry.likes or 0
                end
            else
                for _, entry in ipairs(filtered) do
                    dl_scores[entry] = entry.downloads or entry.download_count or entry.downloads_count or entry.installs or 0
                    scores[entry] = entry.likes or 0
                end
            end
            table.sort(filtered, function(a, b)
                local dla = dl_scores[a] or 0
                local dlb = dl_scores[b] or 0
                if dla ~= dlb then return dla > dlb end
                local sa = scores[a] or 0
                local sb = scores[b] or 0
                if sa ~= sb then return sa > sb end
                local ca = a._catalog_index or 0
                local cb = b._catalog_index or 0
                if ca ~= cb then return ca > cb end
                return (a.title or a.name or "") < (b.title or b.name or "")
            end)
        elseif ss_sort == "recent" or ss_sort == "newest" then
            table.sort(filtered, function(a, b)
                local da = a.dateAdded or a.date_added or a.added or a.created_at
                local db = b.dateAdded or b.date_added or b.added or b.created_at
                if da and db and da ~= db then return da > db end
                local ca = a._catalog_index or 0
                local cb = b._catalog_index or 0
                if ca ~= cb then return ca > cb end
                return (a.title or a.name or "") < (b.title or b.name or "")
            end)
        elseif ss_sort == "az" then
            local titles = {}
            for _, entry in ipairs(filtered) do
                titles[entry] = (entry.title or entry.name or ""):lower()
            end
            table.sort(filtered, function(a, b)
                return (titles[a] or "") < (titles[b] or "")
            end)
        elseif ss_sort == "za" then
            local titles = {}
            for _, entry in ipairs(filtered) do
                titles[entry] = (entry.title or entry.name or ""):lower()
            end
            table.sort(filtered, function(a, b)
                return (titles[a] or "") > (titles[b] or "")
            end)
        end

        self._filtered_screensavers_cache = {
            key = ss_cache_key,
            filtered = filtered,
        }
    end

    local total_pages  = math.max(1, math.ceil(#filtered / page_size))
    local current_page = math.min(self.browser_state.page or 1, total_pages)
    local start_idx    = (current_page - 1) * page_size + 1
    local end_idx      = math.min(#filtered, start_idx + page_size - 1)

    -- ---- Build each card --------------------------------------------------
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local GestureRange    = require("ui/gesturerange")
    local ImageWidget     = require("ui/widget/imagewidget")
    local TextWidget      = require("ui/widget/textwidget")
    local Geom            = require("ui/geometry")
    local Blitbuffer      = require("ffi/blitbuffer")
    local Font            = require("ui/font")
    local ok_lfs, lfs    = pcall(require, "libs/libkoreader-lfs")

    local name_face  = Font:getFace("cfont", 13)
    local meta_face  = Font:getFace("cfont", 11)

    self._ss_thumb_task_id = (self._ss_thumb_task_id or 0) + 1
    local task_id = self._ss_thumb_task_id

    local self_ref = self
    local missing_cards = {}
    local _ss_local_asset_cache = {}

    local function makeCard(entry)
        -- Thumbnail image (or grey placeholder)
        local thumb_file = nil
        pcall(function()
            local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
            local cat_str = type(entry.category) == "table" and table.concat(entry.category, " ") or tostring(entry.category or "")
            local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil
            local raw_url = tostring(entry.thumbnailUrl or ""):lower()
            local ext = (is_transparent or raw_url:find("%.png")) and ".png" or ".jpg"
            local p = cache_dir .. "/" .. tostring(entry.id) .. ext
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
                thumb_file = p
            end
        end)

        local raw_img = nil
        local placeholder_frame = nil
        local placeholder_txt = nil

        if thumb_file then
            local ok_cov, res_cov = pcall(function()
                return StorefrontScreensavers.createCoverImageWidget(thumb_file, inner_w, img_h)
            end)
            if ok_cov and res_cov then
                raw_img = res_cov
            else
                pcall(os.remove, thumb_file)
            end
        end

        if not raw_img then
            placeholder_frame = FrameContainer:new{
                bordersize = 0,
                background = Blitbuffer.Color8(235),
                padding    = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = img_h },
                    TextWidget:new{
                        text    = "…",
                        face    = meta_face,
                        fgcolor = Blitbuffer.Color8(150),
                    },
                }
            }
            raw_img = placeholder_frame
        end

        local img_widget = FrameContainer:new{
            bordersize = sc(1),
            color      = Blitbuffer.Color8(220),
            radius     = sc(3),
            padding    = 0,
            background = Blitbuffer.COLOR_WHITE,
            raw_img,
        }

        local getAssetPath = function(filename)
            if _ss_local_asset_cache[filename] then
                return _ss_local_asset_cache[filename]
            end
            local info = debug.getinfo(1, "S")
            local dir = info.source:match("^@(.*[/\\])") or ""
            local p1 = dir .. "assets/" .. filename
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(p1, "mode") == "file" then
                _ss_local_asset_cache[filename] = p1
                return p1
            end
            local p2 = dir .. "../assets/" .. filename
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(p2, "mode") == "file" then
                _ss_local_asset_cache[filename] = p2
                return p2
            end
            _ss_local_asset_cache[filename] = p1
            return p1
        end

        -- Title (truncated)
        local title_w = TextWidget:new{
            text      = entry.title or entry.name or "",
            face      = name_face,
            bold      = true,
            fgcolor   = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        }

        -- In-app ratings (thumbs up + net score) and downloads count
        local live_r = (ok_ratings and StorefrontRatings and StorefrontRatings.getRating) and StorefrontRatings.getRating(entry) or nil
        local user_vote = (ok_ratings and StorefrontRatings and StorefrontRatings.getUserVote) and StorefrontRatings.getUserVote(entry) or nil
        local has_rating = (live_r and (live_r.up > 0 or live_r.down > 0)) or (user_vote == "up" or user_vote == "down")
        local net_score = live_r and (live_r.up - live_r.down) or 0
        local score_str = net_score >= 1000
            and string.format("%.1fk", net_score / 1000):gsub("%.0k", "k")
            or tostring(net_score)

        local dl_count = (live_r and live_r.downloads) or entry.downloads or entry.download_count or entry.downloads_count or entry.installs or 0
        local dl_str = dl_count >= 1000
            and string.format("%.1fk", dl_count / 1000):gsub("%.0k", "k")
            or tostring(dl_count)

        local display_cat = table.concat(StorefrontUtils.getMappedScreensaverCategories(entry.category), ", ")
        local meta_items = {
            TextWidget:new{
                text      = display_cat,
                face      = meta_face,
                fgcolor   = Blitbuffer.Color8(110),
                max_width = math.floor(inner_w * 0.40),
            },
        }

        if has_rating then
            local icon_file = (user_vote == "down") and getAssetPath("thumbs-down-filled.svg")
                or ((user_vote == "up") and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg"))
            table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
            table.insert(meta_items, TextWidget:new{ text = "·", face = meta_face, fgcolor = Blitbuffer.Color8(140) })
            table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
            table.insert(meta_items, ImageWidget:new{
                file = icon_file,
                width = sc(12), height = sc(12),
                scale_factor = 0, is_icon = true, alpha = true,
            })
            table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
            table.insert(meta_items, TextWidget:new{ text = score_str, face = meta_face, fgcolor = Blitbuffer.Color8(90) })
        end

        table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
        table.insert(meta_items, TextWidget:new{ text = "·", face = meta_face, fgcolor = Blitbuffer.Color8(140) })
        table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
        table.insert(meta_items, ImageWidget:new{
            file = getAssetPath("download.svg"),
            width = sc(12), height = sc(12),
            scale_factor = 0, is_icon = true, alpha = true,
        })
        table.insert(meta_items, HorizontalSpan:new{ width = sc(2) })
        table.insert(meta_items, TextWidget:new{ text = dl_str, face = meta_face, fgcolor = Blitbuffer.Color8(90) })

        local meta_w = HorizontalGroup:new(meta_items)

        local card_inner = VerticalGroup:new{
            align = "left",
            img_widget,
            VerticalSpan:new{ width = sc(4) },
            title_w,
            VerticalSpan:new{ width = sc(2) },
            meta_w,
        }

        local card_frame = FrameContainer:new{
            bordersize = sc(1),
            color      = Blitbuffer.Color8(180),
            radius     = sc(6),
            padding    = card_pad,
            background = Blitbuffer.COLOR_WHITE,
            card_inner,
        }

        local card_ic = InputContainer:new{ card_frame }
        card_ic.dimen = Geom:new{ w = card_w, h = card_h }
        card_ic._entry = entry
        card_ic._img_widget = img_widget
        card_ic._inner_w = inner_w
        card_ic._img_h = img_h

        if placeholder_frame and not entry._thumb_failed then
            table.insert(missing_cards, card_ic)
        end

        local captured_entry = entry
        card_ic.ges_events = {
            SfssCardTap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local d = card_ic.dimen
                        if not d then return nil end
                        return Geom:new{ x = d.x or 0, y = d.y or 0, w = card_w, h = card_h }
                    end,
                },
            },
        }
        function card_ic:onSfssCardTap()
            local ok_det, StorefrontScreensaverDetail = pcall(require, "storefront_screensaver_detail")
            if ok_det and StorefrontScreensaverDetail then
                local detail = StorefrontScreensaverDetail:new{
                    item   = captured_entry,
                    parent = self_ref,
                }
                detail:show()
            end
            return true
        end

        return card_ic
    end

    -- ---- Assemble rows ----------------------------------------------------
    local page_entries = {}
    for i = start_idx, end_idx do
        if filtered[i] then table.insert(page_entries, filtered[i]) end
    end

    local rows_group = VerticalGroup:new{ align = "left" }
    local all_cards = {}
    local grid_rows = {}

    local i = 1
    while i <= #page_entries do
        local row = HorizontalGroup:new{}
        local row_cards = {}
        for c = 1, cols do
            if c > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            if page_entries[i] then
                local card = makeCard(page_entries[i])
                table.insert(row, card)
                table.insert(row_cards, card)
                table.insert(all_cards, card)
                i = i + 1
            else
                -- Empty filler to keep the last row aligned
                local Widget = require("ui/widget/widget")
                table.insert(row, Widget:new{
                    dimen = Geom:new{ w = card_w, h = card_h },
                })
            end
        end
        table.insert(rows_group, row)
        table.insert(grid_rows, row_cards)
        table.insert(rows_group, VerticalSpan:new{ width = gap })
    end

    -- Show "no results" message when filter leaves nothing
    if #page_entries == 0 then
        table.insert(rows_group, CenterContainer:new{
            dimen = Geom:new{ w = usable_w, h = sc(60) },
            TextWidget:new{
                text    = _("No screensavers match this filter."),
                face    = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.Color8(100),
            },
        })
    end

    local grid_container = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = sc(6),
        rows_group,
    }

    if #missing_cards > 0 then
        local UIManager = require("ui/uimanager")
        local function processQueue(idx)
            if self_ref._ss_thumb_task_id ~= task_id then return end
            if not self_ref.browser_menu or (self_ref.browser_state and self_ref.browser_state.tab ~= "Screensavers") then return end
            if idx > #missing_cards then return end

            local card = missing_cards[idx]
            local entry = card._entry
            local c_inner_w = card._inner_w
            local c_img_h = card._img_h

            -- Download thumbnail on next tick
            UIManager:nextTick(function()
                if self_ref._ss_thumb_task_id ~= task_id then return end
                if not self_ref.browser_menu or (self_ref.browser_state and self_ref.browser_state.tab ~= "Screensavers") then return end

                local thumb_path = nil
                local ok_fetch, res = pcall(function()
                    return StorefrontScreensavers.fetchThumbnail(entry)
                end)
                if ok_fetch and res then
                    thumb_path = res
                end

                if self_ref._ss_thumb_task_id ~= task_id then return end
                if not self_ref.browser_menu or (self_ref.browser_state and self_ref.browser_state.tab ~= "Screensavers") then return end

                if thumb_path and card and card._img_widget then
                    local ok_cov, res_cov = pcall(function()
                        return StorefrontScreensavers.createCoverImageWidget(thumb_path, c_inner_w, c_img_h)
                    end)
                    if ok_cov and res_cov then
                        card._img_widget[1] = res_cov
                        if self_ref.browser_menu then
                            UIManager:setDirty(self_ref.browser_menu, "ui")
                        end
                    else
                        pcall(os.remove, thumb_path)
                    end
                end

                -- Proceed sequentially to the next card in queue
                UIManager:nextTick(function()
                    processQueue(idx + 1)
                end)
            end)
        end

        -- Start queue
        UIManager:nextTick(function()
            processQueue(1)
        end)
    end

    return {
        {
            is_screensaver_grid = true,
            grid_widget = grid_container,
            cards = all_cards,
            grid_rows = grid_rows,
        }
    }, total_pages
end

function Storefront:buildBrowserEntries(available_list_height, available_list_width)
    self:ensureBrowserState()
    local tab = self.browser_state.tab or "Plugins"
    if tab == "Updates" then
        local items, total_pages = self:buildUpdatesEntries()
        self._last_total_pages = total_pages
        self._last_total_kind = self.browser_state.kind or "plugin"
        return items, total_pages
    elseif tab == "Installed" then
        local items, total_pages = self:buildInstalledEntries(available_list_height)
        self._last_total_pages = total_pages
        self._last_total_kind = "installed"
        return items, total_pages
    elseif tab == "Screensavers" then
        local items, total_pages = self:buildScreensaverEntries(available_list_height, available_list_width)
        self._last_total_pages = total_pages
        self._last_total_kind = "screensaver"
        return items, total_pages
    end

    local kind = (tab == "Plugins" and "plugin") or (tab == "Fonts" and "font") or "patch"
    self.browser_state.kind = kind
    local items = {}

    if self.match_context then
        if self.match_context.kind == "plugin" and self.match_context.plugin then
            local plugin = self.match_context.plugin
            table.insert(items, {
                text = string.format(_("Matching plugin: %s — tap to cancel"), plugin.name or plugin.dirname or _("plugin")),
                callback = function()
                    self:cancelMatchContext()
                    self:closeBrowserMenu()
                    self:showBrowser(kind)
                end,
                keep_menu_open = true,
            })
            items[#items].separator = true
        elseif self.match_context.kind == "patch" and self.match_context.patch and kind == "patch" then
            local patch = self.match_context.patch
            table.insert(items, {
                text = string.format(_("Matching patch: %s — tap to cancel"), patch.filename or patch.path or _("patch")),
                callback = function()
                    self:cancelMatchContext()
                    self:closeBrowserMenu()
                    self:showBrowser(kind)
                end,
                keep_menu_open = true,
            })
            items[#items].separator = true
        end
    end

    local filtered, total = self:getFilteredDescriptors(kind)
    -- table.insert(items, {
    --     text = self:getCacheStatusLine(kind, total),
    --     select_enabled = false,
    -- })
    local warning = self:getCacheWarning(kind)
    if warning then
        table.insert(items, {
            text = warning,
            select_enabled = false,
        })
    end
    local patch_display_entries
    if kind == "patch" then
        patch_display_entries = self:collectPatchEntries(filtered)
    end
    local display_total = kind == "patch" and #patch_display_entries or #filtered
    local match_line
    if kind == "patch" then
        match_line = string.format(_("Matching patches: %s (repos: %s / %s)"), tostring(display_total), tostring(#filtered), tostring(total))
    else
        match_line = string.format(_("Matching entries: %s / %s"), tostring(#filtered), tostring(total))
    end
    -- table.insert(items, {
    --     text = match_line,
    --     select_enabled = false,
    -- })
    -- items[#items].separator = true

    local installed_lookup
    if kind == "plugin" then
        installed_lookup = self:getInstalledLookup()
    end

    local installed_fonts_map
    if kind == "font" then
        if self.getInstalledFontsMap then
            installed_fonts_map = self:getInstalledFontsMap()
        else
            local ok_fm, font_mgr = pcall(require, "storefront_font_mgr")
            if ok_fm and font_mgr and font_mgr.getInstalledFontsMap then
                installed_fonts_map = font_mgr.getInstalledFontsMap()
            else
                installed_fonts_map = {}
            end
        end
    end

    if display_total == 0 then
        local empty_text = kind == "patch" and _("No patches found in matching repositories.") or _("No entries match current filters.")
        local active_summary_parts = {}
        if util.trim(self.browser_state.search_text or "") ~= "" then
            table.insert(active_summary_parts, "search: \"" .. self.browser_state.search_text .. "\"")
        end
        if util.trim(self.browser_state.owner or "") ~= "" then
            table.insert(active_summary_parts, "owner: " .. self.browser_state.owner)
        end
        if (self.browser_state.min_stars or 0) > 0 then
            table.insert(active_summary_parts, "min stars: " .. tostring(self.browser_state.min_stars))
        end
        if kind == "font" and self.browser_state.font_category and self.browser_state.font_category ~= "all" then
            table.insert(active_summary_parts, "style: " .. self.browser_state.font_category)
        end
        if #active_summary_parts > 0 then
            empty_text = empty_text .. "\n(" .. table.concat(active_summary_parts, ", ") .. ")"
        end

        table.insert(items, {
            text = empty_text,
            select_enabled = false,
        })
        table.insert(items, {
            text = _("Clear search & filters"),
            is_clear_button = true,
            is_entry = true,
            keep_menu_open = true,
            callback = function()
                self:clearSearchAndFilters()
            end,
        })
        return items, 1
    else
        local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
        local fetched = Cache.getLastFetched and Cache.getLastFetched(kind) or 0
        local items_cache_key = string.format("%s|%d|%d|%s|%s|%s|%s|%s|%d|%d",
            kind, total, display_total,
            tostring(self.browser_state.search_text or ""),
            tostring(self.browser_state.owner or ""),
            tostring(self.browser_state.min_stars or 0),
            tostring(self.browser_state.font_category or ""),
            tostring(self.browser_state.sort_mode or ""),
            gen, fetched
        )

        local cached_tab = self._tab_menu_items_cache and self._tab_menu_items_cache[kind]
        if cached_tab and cached_tab.key == items_cache_key and not self.match_context and not warning then
            items = cached_tab.items
        else
            if kind == "patch" then
                for i = 1, display_total do
                    table.insert(items, self:makePatchMenuItem(patch_display_entries[i].repo, patch_display_entries[i].patch))
                end
            else
                for i = 1, display_total do
                    table.insert(items, self:makeRepoMenuItem(filtered[i], installed_lookup, installed_fonts_map))
                end
            end
            if not self.match_context and not warning then
                self._tab_menu_items_cache = self._tab_menu_items_cache or {}
                self._tab_menu_items_cache[kind] = { key = items_cache_key, items = items }
            end
        end
    end

    local page_items, total_pages = self:paginateEntries(items, tab, available_list_height)

    self._last_total_kind = kind
    self._last_total_pages = total_pages
    if kind == "patch" then
        self._last_patch_display_total = display_total
    end
    return page_items, total_pages
end

function Storefront:showProgressMessage(text, args)
    self:dismissProgressMessage()
    args = args or {}
    args.text = text
    args.timeout = args.timeout or 0
    local progress = InfoMessage:new(args)
    self._active_progress_info = progress
    UIManager:show(progress)
    UIManager:forceRePaint()  -- ensure overlay renders before blocking calls
    return progress
end

function Storefront:dismissProgressMessage(target)
    if target and target ~= self._active_progress_info then
        pcall(function() UIManager:close(target) end)
    end
    if self._active_progress_info then
        local p = self._active_progress_info
        self._active_progress_info = nil
        pcall(function() UIManager:close(p) end)
    end
end

function Storefront:closeBrowserMenu()
    self:dismissProgressMessage()
    if self.browser_menu then
        UIManager:close(self.browser_menu)
        self.browser_menu = nil
    end
end

function Storefront:resetBrowserScrollState()
    if self.browser_menu and self.browser_menu.resetScroll then
        self.browser_menu:resetScroll()
    end
    self.skip_scroll_save = true
end

-- Given the live browser/manager dialog and a flip direction, return the focus
-- hint for the rebuilt dialog so the cursor stays where the user expects:
--   on a list entry  -> top entry when flipping forward, bottom when backward
--   on a control row -> the same control row
--   on a footer page-control -> the same footer control (with fallback)
function Storefront:computePageFlipFocus(dialog, forward)
    if not dialog or not dialog.getFocusContext then return nil end
    local ctx = dialog:getFocusContext()
    if ctx.kind == "entry" then
        return { entry = forward and "first" or "last" }
    elseif ctx.kind == "control" and ctx.focus_id then
        return { id = ctx.focus_id }
    elseif ctx.kind == "toolbar" and ctx.which then
        return { toolbar = ctx.which }
    elseif ctx.kind == "footer" and ctx.which then
        return { footer = ctx.which, direction = forward and "forward" or "backward" }
    end
    return nil
end

function Storefront:reopenBrowser(kind, callback)
    if self.browser_state and self.browser_state.scroll_offset == nil then
        self:resetBrowserScrollState()
    end
    self._browser_refresh_mode_hint = self._browser_refresh_mode_hint or "partial"
    UIManager:nextTick(function()
        self:showBrowser(kind)
        if callback then
            UIManager:nextTick(callback)
        end
    end)
end

-- Browser actions, shared by the gear menu, the Menu hardware key and the
-- r/f/s/t hotkeys. Kept out of the list body so they are reachable from any
-- scroll position / page without scrolling back to the top.
function Storefront:browserSwitchTab(tab_name)
    self:ensureBrowserState()
    if not tab_name then
        local current = self.browser_state.tab or "Plugins"
        if current == "Plugins" then
            tab_name = "Patches"
        elseif current == "Patches" then
            tab_name = "Fonts"
        elseif current == "Fonts" then
            tab_name = "Installed"
        elseif current == "Installed" then
            tab_name = "Updates"
        else
            tab_name = "Plugins"
        end
    end
    self.browser_state.tab = tab_name
    self.browser_state.kind = (tab_name == "Patches" and "patch") or (tab_name == "Fonts" and "font") or "plugin"
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:resetFiltersForRefresh()
    self:saveBrowserState(true)
    self:resetBrowserScrollState()
    self:closeBrowserMenu()
    self._browser_refresh_mode_hint = "partial"
    self:showBrowser()
end

function Storefront:browserRefresh()
    self:ensureBrowserState()
    if self.isRefreshing and self:isRefreshing() then
        local Toast = require("storefront_toast")
        Toast.show(_("Catalog refresh is already in progress in the background."), 3)
        return
    end
    local kind = self.browser_state.kind or "plugin"
    self:resetBrowserScrollState()
    self:resetFiltersForRefresh()
    NetworkMgr:runWhenOnline(function()
        self:refreshCache(kind, function(ok)
            self:softRefreshCurrentBrowserView()
        end)
    end)
end

function Storefront:browserManageInstalled()
    self:ensureBrowserState()
    local kind = self.browser_state.kind or "plugin"
    self:closeBrowserMenu()
    if kind == "plugin" then
        self:showUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:browserOpenFilter()
    self:ensureBrowserState()
    local tab = self.browser_state.tab or "Plugins"
    if tab == "Installed" then
        self:showInstalledFilter()
    else
        self:showCatalogFilter()
    end
end

function Storefront:browserAdvanceSort()
    if self.browser_state and self.browser_state.tab == "Installed" then
        self:ensureInstalledState()
        local current = self.installed_state.sort_mode or "name_asc"
        local sort_modes = { "name_asc", "name_desc", "date_desc", "date_asc", "type", "status" }
        local next_idx = 1
        for i, mode in ipairs(sort_modes) do
            if mode == current then
                next_idx = (i % #sort_modes) + 1
                break
            end
        end
        self.installed_state.sort_mode = sort_modes[next_idx]
        self:saveInstalledState()
        self:reopenBrowser()
        return
    end
    self:advanceSortMode()
end

function Storefront:softRefreshCurrentBrowserView()
    invalidateInstalledPluginsCache()
    self._cached_plugin_summary = nil
    self._cached_patch_summary = nil
    self._merged_updates_cache = nil
    self._repo_descriptors_cache = nil
    self._filtered_descriptors_cache = nil
    self._filtered_screensavers_cache = nil
    self._cached_updates_count = nil
    self._cached_updates_gen = nil
    self._tab_menu_items_cache = nil
    self._installed_tab_items_cache = nil
    self._installed_lookup_cache = nil

    if self.browser_menu then
        UIManager:setDirty(self.browser_menu)
    end
end

-- Rebuilds the browser list in-place if the browser is open.
-- On the Updates or Installed tab, closes and reopens the browser so the
-- item list is rebuilt from fresh data (a dirty mark alone is not enough
-- since those tabs build their items inside showBrowser).
-- On other tabs, falls back to softRefreshCurrentBrowserView — just
-- marking the frame dirty is sufficient because catalog-tab content
-- is rebuilt from the cache which is already invalidated.
function Storefront:refreshCurrentBrowserTab()
    self:softRefreshCurrentBrowserView()
    self._browser_refresh_mode_hint = "partial"
    self:reopenBrowser()
end

function Storefront:maybeCheckCatalogBackground()
    local now = os.time()

    local GitHub = require("storefront_net_github")
    if GitHub.isDirectApiEnabled() then
        return
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not (ok_nm and NetworkMgr) then
        return
    end

    local is_online = false
    if type(NetworkMgr.isOnline) == "function" then
        is_online = NetworkMgr:isOnline()
    elseif type(NetworkMgr.isWifiOn) == "function" then
        is_online = NetworkMgr:isWifiOn()
    elseif type(NetworkMgr.isConnected) == "function" then
        is_online = NetworkMgr:isConnected()
    end

    if not is_online then
        return
    end

    local Cache = require("storefront_cache")
    local current_tab = (self.browser_state and self.browser_state.tab) or "Plugins"
    local check_kind = (current_tab == "Patches") and "patch" or "plugin"
    local repo_count = Cache.countRepos(check_kind) or 0
    local last_fetched = Cache.getLastFetched(check_kind) or 0
    local age = (last_fetched > 0) and (now - last_fetched) or 999999

    local needs_fetch = (last_fetched == 0 or repo_count == 0 or age > 3600)
    if not needs_fetch and self._last_catalog_check_time and (now - self._last_catalog_check_time) < MIN_CATALOG_CHECK_INTERVAL then
        return
    end

    pcall(function() self:syncPendingFontDownloads() end)

    self._last_catalog_check_time = now

    if needs_fetch then
        local msg = string.format("Storefront: catalog cache is stale/unfetched (count: %d, %ds old), triggering background fetch", repo_count, age)
        logger.info(msg)
        StorefrontLogger.info(msg)

        local CatalogClient = require("storefront_net_catalog")
        CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
            if ok then
                logger.info("Storefront: background catalog update finished")
                StorefrontLogger.info("Storefront: background catalog update finished")
                self:softRefreshCurrentBrowserView()
            else
                logger.warn("Storefront: background catalog update failed: " .. tostring(err))
                StorefrontLogger.warn("Storefront: background catalog update failed: " .. tostring(err))
            end
        end)
    else
        local msg = string.format("Storefront: catalog cache is fresh (%ds old <= 3600s), skipping background fetch", age)
        logger.info(msg)
        StorefrontLogger.info(msg)
    end
end

function Storefront:showBrowser(kind)
    self:ensureBrowserState()
    self:ensureUpdatesState()
    self:ensurePatchUpdatesState()
    self:ensureInstalledState()
    if self.browser_menu then
        self:closeBrowserMenu()
    end
    local current_tab = self.browser_state.tab or "Plugins"
    
    -- Schedule deferred update and catalog background checks ONCE per session on launch (zero launch delay)
    if not self._session_bg_checks_done then
        self._session_bg_checks_done = true
        UIManager:nextTick(function()
            pcall(function() self:syncPendingFontDownloads() end)
            pcall(function() self:maybeAutoCheckUpdates() end)
        end)

        local now = os.time()
        if not self._last_catalog_check_time or (now - self._last_catalog_check_time) >= MIN_CATALOG_CHECK_INTERVAL then
            UIManager:scheduleIn(1.5, function()
                pcall(function() self:maybeCheckCatalogBackground() end)
            end)
        end
    end

    local title = _("Storefront")
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local ok, err = pcall(function()
            local initial_focus = self.browser_focus_hint
            self.browser_focus_hint = nil

            local is_catalog_search_active = util.trim(self.browser_state and self.browser_state.search_text or "") ~= ""
            local raw_installed_st = (self.installed_state and self.installed_state.search_text ~= "" and self.installed_state.search_text) or (self.browser_state and self.browser_state.search_text) or ""
            local is_installed_search_active = util.trim(raw_installed_st) ~= ""
            local is_ss_filter_active = self:hasActiveFilters("Screensavers")

            local toolbar_buttons
            local show_plugins_bar = (current_tab == "Plugins" and ((self.browser_state and self.browser_state.show_filter_bar_plugins == true) or is_catalog_search_active))
            local show_patches_bar = (current_tab == "Patches" and ((self.browser_state and self.browser_state.show_filter_bar_patches == true) or is_catalog_search_active))
            local show_fonts_bar = (current_tab == "Fonts" and ((self.browser_state and self.browser_state.show_filter_bar_fonts == true) or is_catalog_search_active))
            if show_plugins_bar or show_patches_bar or show_fonts_bar then
                toolbar_buttons = {}
                if (self.browser_state.search_text or "") ~= "" then
                    table.insert(toolbar_buttons, {
                        id = "search",
                        text = _("Search: ") .. self.browser_state.search_text,
                        callback = function() self:showFilterDialog() end
                    })
                end
                if (self.browser_state.owner or "") ~= "" then
                    table.insert(toolbar_buttons, {
                        id = "owner",
                        text = _("Owner: ") .. self.browser_state.owner,
                        callback = function() self:showFilterDialog() end
                    })
                end
                if current_tab == "Fonts" and self.browser_state.font_category and self.browser_state.font_category ~= "all" then
                    table.insert(toolbar_buttons, {
                        id = "font_style",
                        text = _("Style: ") .. self.browser_state.font_category:lower(),
                        callback = function() self:showCatalogFilter() end
                    })
                end
                if (self.browser_state.min_stars or 0) > 0 then
                    table.insert(toolbar_buttons, {
                        id = "stars",
                        text = "★ " .. tostring(self.browser_state.min_stars) .. "+",
                        callback = function() self:showCatalogFilter() end
                    })
                end
                local sort_opt = self:getSortOption(self.browser_state.sort_mode)
                table.insert(toolbar_buttons, {
                    id = "sort",
                    text = sort_opt and sort_opt.summary or _("Sort"),
                    callback = function() self:browserAdvanceSort() end
                })
                table.insert(toolbar_buttons, {
                    id = "filter_dialog",
                    text = _("Filter..."),
                    callback = function() self:showCatalogFilter() end
                })
            elseif current_tab == "Updates" then
                toolbar_buttons = {}
                table.insert(toolbar_buttons, {
                    id = "check_updates",
                    text = _("Check Updates"),
                    text_font_bold = true,
                    callback = function()
                        local installed_plugins = listInstalledPlugins()
                        local records = getInstallRecordsMap()
                        local plugin_repos = {}
                        for _, plugin in ipairs(installed_plugins) do
                            local record = records[plugin.dirname]
                            if record and record.owner and record.repo then
                                record.dirname = plugin.dirname
                                table.insert(plugin_repos, record)
                            end
                        end
                        if #plugin_repos > 0 then
                            self:_checkAllUpdatesInternal(plugin_repos)
                        else
                            UIManager:show(InfoMessage:new{ text = _("No tracked plugins to check."), timeout = 4 })
                        end
                    end,
                })
                table.insert(toolbar_buttons, {
                    id = "update_all",
                    text = _("Update All"),
                    right_align = true,
                    is_primary = true,
                    callback = function() self:updateAllAvailable() end,
                })
            elseif current_tab == "Installed" then
                self:ensureInstalledState()
                if (self.browser_state and self.browser_state.show_filter_bar_installed ~= false) or is_installed_search_active then
                toolbar_buttons = {}
                local effective_installed_search = util.trim((self.installed_state.search_text and self.installed_state.search_text ~= "") and self.installed_state.search_text or (self.browser_state and self.browser_state.search_text or ""))
                if effective_installed_search ~= "" then
                    table.insert(toolbar_buttons, {
                        id = "search",
                        text = _("Search: ") .. effective_installed_search,
                        callback = function() self:showFilterDialog() end
                    })
                end
                if (self.browser_state and (self.browser_state.owner or "") ~= "") then
                    table.insert(toolbar_buttons, {
                        id = "owner",
                        text = _("Owner: ") .. self.browser_state.owner,
                        callback = function() self:showFilterDialog() end
                    })
                end
                local type_label = _("All Types")
                if self.installed_state.filter_type == "plugin" then type_label = _("Plugins")
                elseif self.installed_state.filter_type == "patch" then type_label = _("Patches")
                elseif self.installed_state.filter_type == "font" then type_label = _("Fonts")
                elseif self.installed_state.filter_type == "screensaver" then type_label = _("Screensavers") end
                table.insert(toolbar_buttons, {
                    id = "type",
                    text = type_label,
                    callback = function() self:showInstalledFilter() end
                })
                if self.installed_state.filter_default and self.installed_state.filter_default ~= "all" then
                    local def_label = (self.installed_state.filter_default == "default_only") and _("Default") or _("User Installed")
                    table.insert(toolbar_buttons, {
                        id = "origin",
                        text = def_label,
                        callback = function() self:showInstalledFilter() end
                    })
                end
                if self.installed_state.filter_status and self.installed_state.filter_status ~= "all" then
                    local stat_label = (self.installed_state.filter_status == "enabled") and _("Enabled") or _("Disabled")
                    table.insert(toolbar_buttons, {
                        id = "status",
                        text = stat_label,
                        callback = function() self:showInstalledFilter() end
                    })
                end
                local sort_map = {
                    name_asc = _("Sort: A-Z"),
                    name_desc = _("Sort: Z-A"),
                    date_desc = _("Sort: Updated"),
                    date_asc = _("Sort: Oldest"),
                    date = _("Sort: Updated"),
                    type = _("Sort: Type"),
                    status = _("Sort: Status"),
                }
                table.insert(toolbar_buttons, {
                    id = "sort",
                    text = sort_map[self.installed_state.sort_mode] or _("Sort"),
                    callback = function() self:browserAdvanceSort() end
                })
                table.insert(toolbar_buttons, {
                    id = "filter_dialog",
                    text = _("Filter..."),
                    callback = function() self:showInstalledFilter() end
                })
                end -- show_filter_bar_installed
            elseif current_tab == "Screensavers" then
                is_ss_filter_active = self:hasActiveFilters("Screensavers")
                if (self.browser_state and self.browser_state.show_filter_bar_screensavers ~= false) or is_ss_filter_active then
                    -- Build toolbar: active search/owner pills + active category pill + sort cycle + Filter... button
                    toolbar_buttons = {}
                    local effective_ss_search = util.trim((self.browser_state.search_text and self.browser_state.search_text ~= "") and self.browser_state.search_text or (self.browser_state.screensaver_search or ""))
                    local effective_ss_owner  = util.trim(self.browser_state.owner or "")
                    local ss_cat  = self.browser_state.screensaver_category or ""
                    local ss_cats = self.browser_state.screensaver_categories
                    local ss_sort = self.browser_state.screensaver_sort or "downloads"

                    if effective_ss_search ~= "" then
                        table.insert(toolbar_buttons, {
                            id = "ss_srch",
                            text = _("Search: ") .. effective_ss_search,
                            callback = function() self:showFilterDialog() end
                        })
                    end
                    if effective_ss_owner ~= "" then
                        table.insert(toolbar_buttons, {
                            id = "ss_owner",
                            text = _("Owner: ") .. effective_ss_owner,
                            callback = function() self:showFilterDialog() end
                        })
                    end

                    local active_cat_names = {}
                    if type(ss_cats) == "table" and next(ss_cats) and not ss_cats["all"] then
                        for k, v in pairs(ss_cats) do
                            if v and k ~= "all" then
                                local c_name = k:sub(1,1):upper() .. k:sub(2)
                                if k == "scifi" or k == "sci-fi" then c_name = "Sci-Fi" end
                                if k == "fine art" then c_name = "Fine Art" end
                                if k == "pop culture" then c_name = "Pop Culture" end
                                table.insert(active_cat_names, c_name)
                            end
                        end
                        table.sort(active_cat_names)
                    elseif ss_cat ~= "" and ss_cat ~= "all" then
                        table.insert(active_cat_names, ss_cat:sub(1,1):upper() .. ss_cat:sub(2))
                    end

                    if #active_cat_names > 0 then
                        local cat_str = #active_cat_names == 1 and active_cat_names[1] or string.format(_("%d Categories"), #active_cat_names)
                        table.insert(toolbar_buttons, {
                            id = "ss_cat",
                            text = _("Category: ") .. cat_str,
                            callback = function() self:showScreensaverFilter() end
                        })
                    end
                    local sort_labels = {
                        downloads = _("Most Downloaded"),
                        recent    = _("Recently Added"),
                        popular   = _("Most Popular"),
                        az        = _("A → Z"),
                        za        = _("Z → A"),
                    }
                    local sort_cycle = { "downloads", "recent", "popular", "az", "za" }
                    table.insert(toolbar_buttons, {
                        id = "ss_sort",
                        text = sort_labels[ss_sort] or _("Most Downloaded"),
                        callback = function()
                            local next_sort = "downloads"
                            for idx, s in ipairs(sort_cycle) do
                                if ss_sort == s then
                                    next_sort = sort_cycle[(idx % #sort_cycle) + 1]
                                    break
                                end
                            end
                            self.browser_state.screensaver_sort = next_sort
                            self.browser_state.page = 1
                            self:reopenBrowser()
                        end
                    })
                    table.insert(toolbar_buttons, {
                        id = "ss_filter",
                        text = _("Filter..."),
                        callback = function() self:showScreensaverFilter() end
                    })
                    table.insert(toolbar_buttons, {
                        id = "ss_settings",
                        text = _("⚙ Settings"),
                        callback = function()
                            local StorefrontScreensaverConfig = require("storefront_screensaver_config")
                            StorefrontScreensaverConfig.show(self, function()
                                self:reopenBrowser()
                            end)
                        end
                    })
                end
            end

            local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
            local remote_info_key = self.updates_state and self.updates_state.remote_info
            local patch_remote_info_key = self.patch_updates_state and self.patch_updates_state.remote_info
            
            if not self._cached_updates_count 
               or self._cached_updates_gen ~= current_generation
               or self._cached_remote_info ~= remote_info_key
               or self._cached_patch_remote_info ~= patch_remote_info_key then
               
                pcall(function()
                    local p_sum = self:collectUpdateSummary()
                    local pt_sum = self:collectPatchUpdateSummary()
                    self._cached_updates_count = (p_sum.updates or 0) + (pt_sum.updates or 0)
                end)
                self._cached_updates_gen = current_generation
                self._cached_remote_info = remote_info_key
                self._cached_patch_remote_info = patch_remote_info_key
            end
            local updates_count = self._cached_updates_count or 0

            local active_search_text = ""
            if current_tab == "Installed" then
                local raw_active_st = (self.installed_state and self.installed_state.search_text ~= "" and self.installed_state.search_text) or (self.browser_state and self.browser_state.search_text) or ""
                active_search_text = util.trim(raw_active_st)
            elseif current_tab ~= "Updates" then
                active_search_text = util.trim(self.browser_state.search_text or "")
            end

            local available_list_height, available_list_width = StorefrontBrowserDialog:measureListViewport{
                title = title,
                toolbar_buttons = toolbar_buttons,
                current_tab = current_tab,
                updates_count = updates_count,
                show_filter_bar_plugins = (self.browser_state and self.browser_state.show_filter_bar_plugins == true) or is_catalog_search_active,
                show_filter_bar_patches = (self.browser_state and self.browser_state.show_filter_bar_patches == true) or is_catalog_search_active,
                show_filter_bar_fonts = (self.browser_state and self.browser_state.show_filter_bar_fonts == true) or is_catalog_search_active,
                show_filter_bar_screensavers = (self.browser_state and self.browser_state.show_filter_bar_screensavers ~= false) or is_ss_filter_active,
                show_filter_bar_installed = (self.browser_state and self.browser_state.show_filter_bar_installed ~= false) or is_installed_search_active,
            }
            local items, total_pages = self:buildBrowserEntries(available_list_height, available_list_width)

            local dialog = StorefrontBrowserDialog:new{
                title = title,
                items = items,
                page = self.browser_state.page,
                total_pages = total_pages,
                scroll_offset = self.browser_state.scroll_offset,
                initial_focus = initial_focus,
                toolbar_buttons = toolbar_buttons,
                current_tab = current_tab,
                updates_count = updates_count,
                active_search_text = active_search_text,
                on_clear_search = function() self:clearSearchText() end,
                show_filter_bar_plugins = (self.browser_state and self.browser_state.show_filter_bar_plugins == true) or is_catalog_search_active,
                show_filter_bar_patches = (self.browser_state and self.browser_state.show_filter_bar_patches == true) or is_catalog_search_active,
                show_filter_bar_fonts = (self.browser_state and self.browser_state.show_filter_bar_fonts == true) or is_catalog_search_active,
                show_filter_bar_screensavers = (self.browser_state and self.browser_state.show_filter_bar_screensavers ~= false) or is_ss_filter_active,
                show_filter_bar_installed = (self.browser_state and self.browser_state.show_filter_bar_installed ~= false) or is_installed_search_active,
                on_toggle_filter_bar = function(tab_name)
                    self:toggleFilterBar(tab_name)
                end,
        updates_filter_only_outdated = self.updates_state.filter_only_outdated,
        on_updates_filter = function(outdated_only)
            self.updates_state.filter_only_outdated = outdated_only
            self.patch_updates_state.filter_only_outdated = outdated_only
            self.browser_state.page = 1
            self.browser_state.scroll_offset = nil
            self:saveBrowserState()
            self._browser_refresh_mode_hint = "partial"
            self:reopenBrowser()
        end,
        on_tab_switch = function(tab_name)
            self.browser_state.tab = tab_name
            self.browser_state.kind = (tab_name == "Patches" and "patch") or (tab_name == "Fonts" and "font") or "plugin"
            self.browser_state.page = 1
            self.browser_state.scroll_offset = nil
            self:saveBrowserState(true)
            self._browser_refresh_mode_hint = "partial"
            self:reopenBrowser()
        end,
        on_settings_tap = function()
            self:showStorefrontSettingsDialog()
        end,
        on_refresh = function()
            if self.browser_state.tab == "Updates" then
                self:checkAllUpdates()
            else
                self:browserRefresh()
            end
        end,
        on_search = function() self:showFilterDialog() end,
        on_filter = function() self:browserOpenFilter() end,
        on_sort = function() self:browserAdvanceSort() end,
        on_switch_tab = function() self:browserSwitchTab() end,
        on_first_page = function()
            if self.browser_state.page > 1 then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, false)
                self.browser_state.page = 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_prev_page = function()
            if self.browser_state.page > 1 then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, false)
                self.browser_state.page = self.browser_state.page - 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_next_page = function()
            local current_kind = (self.browser_state.tab == "Installed") and "installed" or (self.browser_state.tab == "Screensavers") and "screensaver" or (self.browser_state.kind or "plugin")
            local total_pages = (self._last_total_kind == current_kind) and (self._last_total_pages or 1) or 1
            if self.browser_state.page < total_pages then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, true)
                self.browser_state.page = self.browser_state.page + 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_last_page = function()
            local current_kind = (self.browser_state.tab == "Installed") and "installed" or (self.browser_state.tab == "Screensavers") and "screensaver" or (self.browser_state.kind or "plugin")
            local total_pages = (self._last_total_kind == current_kind) and (self._last_total_pages or 1) or 1
            if self.browser_state.page < total_pages then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, true)
                self.browser_state.page = total_pages
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_goto_page = function(page_num)
            local current_kind = (self.browser_state.tab == "Installed") and "installed" or (self.browser_state.tab == "Screensavers") and "screensaver" or (self.browser_state.kind or "plugin")
            local total_pages = (self._last_total_kind == current_kind) and (self._last_total_pages or 1) or 1
            if page_num >= 1 and page_num <= total_pages and page_num ~= self.browser_state.page then
                local forward = page_num > self.browser_state.page
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, forward)
                self.browser_state.page = page_num
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_dismiss = function(offset)
            if self.skip_scroll_save then
                self.browser_state.scroll_offset = nil
                self.skip_scroll_save = nil
            else
                self.browser_state.scroll_offset = normalizeScrollOffset(offset)
            end
            self:saveBrowserState()
            self:dismissProgressMessage()
            self.browser_menu = nil
            self._session_bg_checks_done = nil
            self._ss_thumb_task_id = (self._ss_thumb_task_id or 0) + 1
        end,
    }
    if dialog._used_trapper_progress then
        Trapper:reset()
    end
    self.browser_menu = dialog
    UIManager:show(dialog)
    local refresh_mode = self._browser_refresh_mode_hint or "full"
    self._browser_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
        end)
        if not ok then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = "Storefront Error:\n" .. tostring(err),
            })
        end
    end)
end

function Storefront:showFilterDialog()
    require("storefront_filter_dialog"):show(self)
end

function Storefront:showScreensaverFilter()
    require("storefront_filter_dialog").showScreensaverFilter(self)
end

function Storefront:showInstalledFilter()
    require("storefront_filter_dialog"):showInstalledFilter(self)
end


function Storefront:showCatalogFilter()
    require("storefront_filter_dialog"):showCatalogFilter(self)
end

function Storefront:toggleFilterBar(tab_name)
    self:ensureBrowserState()
    if tab_name == "Plugins" then
        self.browser_state.show_filter_bar_plugins = not self.browser_state.show_filter_bar_plugins
    elseif tab_name == "Patches" then
        self.browser_state.show_filter_bar_patches = not self.browser_state.show_filter_bar_patches
    elseif tab_name == "Fonts" then
        self.browser_state.show_filter_bar_fonts = not self.browser_state.show_filter_bar_fonts
    elseif tab_name == "Installed" then
        self.browser_state.show_filter_bar_installed = not (self.browser_state.show_filter_bar_installed ~= false)
    elseif tab_name == "Screensavers" then
        self.browser_state.show_filter_bar_screensavers = not (self.browser_state.show_filter_bar_screensavers ~= false)
    end
    self:saveBrowserState()
    self:reopenBrowser()
end

function Storefront:showStorefrontSettingsDialog()
    require("storefront_settings_dialog"):show(self)
end

-- Triggered from the Storefront settings dialog. Confirms with the user, then
-- removes every cached README markdown file produced by previous
-- "View README" actions. The cached files are regenerated on demand the next
-- time a README is opened, so deletion is non-destructive.
function Storefront:clearCachedReadmeFiles()
    self:showConfirmDialog{
        title = _("Clear README Cache?"),
        text = _("Delete all cached README files? They will be re-downloaded on demand."),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local result = RepoContent.clearReadmeCache()
            local removed = (result and result.removed) or 0
            local errors = (result and result.errors) or {}
            local msg
            if removed == 0 and #errors == 0 then
                msg = _("No cached README files to delete.")
            elseif #errors == 0 then
                msg = string.format(_("Deleted %d cached README file(s)."), removed)
            else
                msg = string.format(_("Deleted %d cached README file(s); %d failed."), removed, #errors)
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
        end,
    }
end

function Storefront:promptInstallPluginFromURL()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Install plugin from GitHub"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:fetchAndShowPluginRepo(owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:fetchAndShowPluginRepo(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Fetching repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        UIManager:close(progress)
        
        if not repo_data or not repo_data.id then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "plugin",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        self:promptRepoAction(repo)
    end)
end

function Storefront:promptInstallPatchFromURL()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Install patch from GitHub"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:fetchAndShowPatchRepo(owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:fetchAndShowPatchRepo(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Fetching repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        
        if not repo_data or not repo_data.id then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "patch",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        local entries = self:fetchPatchEntriesFromGitHub(repo)
        UIManager:close(progress)
        
        if not entries or #entries == 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("No patch files found in repository %s."), full_name),
                timeout = 4,
            })
            return
        end
        
        self:showPatchRepoActionDialog(repo, entries)
    end)
end

function Storefront:showPatchRepoActionDialog(repo, entries)
    if not repo or not entries then
        return
    end
    
    local dialog
    local buttons_row = {
        {
            text = _("Install a patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showPatchSelectionDialogForInstall(repo, entries)
            end,
        },
        {
            text = _("View README"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showReadme(repo)
            end,
        },
    }
    
    local lines = {}
    local description = normalizeDescription(repo.description)
    if description ~= "" then
        lines[#lines + 1] = description
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.updated_at or repo.data.created_at)
    if ts and ts ~= "" then
        if description ~= "" then
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = string.format(_("Updated: %s"), ts:sub(1, 10))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(_("Patches found: %d"), #entries)
    
    dialog = ConfirmBox:new{
        text = repo.full_name or repo.name or _("Repository"),
        cancel_text = _("Close"),
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = { buttons_row },
    }
    dialog:addWidget(makeTextBox(table.concat(lines, "\n")))
    UIManager:show(dialog)
end

function Storefront:showPatchSelectionDialogForInstall(repo, entries)
    if not repo or not entries or #entries == 0 then
        return
    end
    
    local dialog
    local buttons = {}
    for idx, entry in ipairs(entries) do
        table.insert(buttons, {
            {
                text = entry.path or entry.display_path or _("patch"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:installPatchFromRepo(repo, entry)
                end,
            },
        })
    end
    
    table.insert(buttons, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })
    
    dialog = ButtonDialog:new{
        title = string.format(_("Select patch file from %s"), repo.full_name or repo.name),
        buttons = buttons,
        tap_close_callback = function()
        end,
    }
    UIManager:show(dialog)
end

function Storefront:getStatusLines()
    local status_lines = { _("Storefront") }
    local plugin_count = Cache.countRepos and Cache.countRepos("plugin") or #Cache.listRepos("plugin")
    local patch_count = Cache.countRepos and Cache.countRepos("patch") or #Cache.listRepos("patch")
    local plugin_ts = Cache.getLastFetched("plugin")
    local patch_ts = Cache.getLastFetched("patch")
    table.insert(status_lines, string.format(_("Plugins cached: %s (last update: %s)"), tostring(plugin_count or 0), formatTimestamp(plugin_ts)))
    table.insert(status_lines, string.format(_("Patches cached: %s (last update: %s)"), tostring(patch_count or 0), formatTimestamp(patch_ts)))

    local now = os.time()
    if plugin_ts and plugin_ts > 0 and now - plugin_ts > STALE_WARNING_SECONDS then
        table.insert(status_lines, _("Plugin cache is older than a week, consider refreshing."))
    end
    if patch_ts and patch_ts > 0 and now - patch_ts > STALE_WARNING_SECONDS then
        table.insert(status_lines, _("Patch cache is older than a week, consider refreshing."))
    end

    local memo = StorefrontSettings:readSetting("status_text")
    if memo and memo ~= "" then
        table.insert(status_lines, memo)
    end

    return status_lines
end

function Storefront:buildStatusWidget()
    local group = VerticalGroup:new{}
    for _, line in ipairs(self:getStatusLines()) do
        group[#group + 1] = TextWidget:new{ text = line }
    end
    return CenterContainer:new{
        FrameContainer:new{
            padding = 20,
            group,
        }
    }
end

function Storefront:buildListWidget(lines)
    local text = table.concat(lines, "\n")
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end
    local text_box_args = {
        text = text,
        width = math.floor(Device.screen:getWidth() * 0.8),
    }
    if default_face then
        text_box_args.face = default_face
    end
    return CenterContainer:new{
        FrameContainer:new{
            padding = 20,
            TextBoxWidget:new(text_box_args),
        }
    }
end

local function truncateText(text, max_len)
    max_len = max_len or 140
    if not text or text == "" then
        return ""
    end
    text = util and util.trim(text) or text
    text = text:gsub("\n", " ")
    if #text <= max_len then
        return text
    end
    return text:sub(1, max_len - 3) .. "..."
end


-- Set of installed repos (by full name and repo id), used to mark the
-- plugin-kind browse list. Cached in memory and only rebuilt when the
-- install store actually changes (install/uninstall/match), instead of on
-- every browser render (page flip, sort, filter change).
function Storefront:getInstalledLookup()
    local generation = InstallStore.getGeneration and InstallStore.getGeneration()
    local cache = self._installed_lookup_cache
    if cache and cache.generation == generation then
        return cache.lookup
    end
    local lookup = { exact = {}, unmatched = {} }
    for _, rec in pairs(getInstallRecordsMap()) do
        local full_name = rec.repo_full_name
        if not full_name and rec.owner and rec.repo then
            full_name = rec.owner .. "/" .. rec.repo
        end
        local has_exact = false
        if full_name then
            has_exact = true
            lookup[full_name] = true
            lookup[full_name:lower()] = true
            lookup.exact[full_name] = true
            lookup.exact[full_name:lower()] = true
        end
        if rec.repo_id then
            has_exact = true
            lookup["id:" .. tostring(rec.repo_id)] = true
            lookup.exact["id:" .. tostring(rec.repo_id)] = true
        end

        if not has_exact then
            if rec.dirname then
                local low = rec.dirname:lower()
                local base = low:gsub("%.koplugin$", "")
                lookup[rec.dirname] = true
                lookup[low] = true
                lookup[base] = true
                lookup.unmatched[rec.dirname] = true
                lookup.unmatched[low] = true
                lookup.unmatched[base] = true
            end
        end
    end
    self._installed_lookup_cache = { generation = generation, lookup = lookup }
    return lookup
end

function Storefront:getRepoDescriptors(kind)
    -- Cache the built descriptor list in memory: rebuilding it reads the whole
    -- repo cache from disk and allocates a table per repo (hundreds of them),
    -- which is the dominant cost when flipping pages. Invalidate when the cache's
    -- last-fetched stamp changes (refresh) — see refreshCache resetting it too.
    local fetched = Cache.getLastFetched and Cache.getLastFetched(kind)
    local cache = self._repo_descriptors_cache
    if cache and cache[kind] and cache[kind].fetched == fetched and cache[kind].descriptors then
        local count = Cache.countRepos and Cache.countRepos(kind)
        if count == nil or count == #cache[kind].descriptors then
            return cache[kind].descriptors
        end
    end
    local entries = Cache.listRepos(kind)
    local descriptors = {}
    for _, repo in ipairs(entries) do
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        local is_font_kind = (kind == "font")
        local descriptor = {
            id = repo.repo_id,
            kind = kind,
            name = repo.name or (repo.data and repo.data.name),
            font_family = repo.font_family or (repo.data and repo.data.font_family) or (is_font_kind and (repo.data and repo.data.name or repo.name) or nil),
            font_file = repo.font_file or (repo.data and repo.data.font_file),
            category = repo.category or (repo.data and repo.data.category),
            license = repo.license or (repo.data and repo.data.license),
            download_url = repo.download_url or (repo.data and repo.data.download_url),
            full_name = repo.full_name or (repo.data and repo.data.full_name),
            owner = owner,
            stars = (repo.stars and repo.stars > 0) and repo.stars or (repo.data and tonumber(repo.data.stargazers_count) or 0),
            language = repo.language or (repo.data and repo.data.language),
            description = repo.description or (repo.data and repo.data.description),
            homepage = repo.homepage or (repo.data and repo.data.homepage),
            default_branch = repo.default_branch or (repo.data and repo.data.default_branch),
            latest_release = repo.latest_release or (repo.data and repo.data.latest_release),
            patch_files = repo.patch_files or (repo.data and repo.data.patch_files),
            data = repo.data or repo,
        }
        table.insert(descriptors, descriptor)
    end
    self._repo_descriptors_cache = self._repo_descriptors_cache or {}
    self._repo_descriptors_cache[kind] = { fetched = fetched, descriptors = descriptors }
    return descriptors
end

function Storefront:renderRepoLines(descriptors)
    if #descriptors == 0 then
        return { _("No cached entries yet. Refresh to fetch from GitHub.") }
    end
    local lines = {}
    for _, repo in ipairs(descriptors) do
        local badge = string.format("⭐ %s", tostring(repo.stars or 0))
        local fullname = repo.full_name or (repo.owner and repo.name and (repo.owner .. "/" .. repo.name)) or (repo.name or _("Unknown"))
        local raw_description = normalizeDescription(repo.description)
        local desc = truncateText(raw_description)
        local language = repo.language and (" · " .. repo.language) or ""
        local line = string.format("%s — %s%s", fullname, badge, language)
        if desc ~= "" then
            line = line .. "\n  " .. desc
        end
        table.insert(lines, line)
    end
    return lines
end



downloadToFile = function(url, local_path)
    if not url or url == "" then
        return false, _("Missing URL")
    end
    if not local_path or local_path == "" then
        return false, _("Missing target path")
    end

    local dir = local_path:match("^(.*)/")
    if dir and dir ~= "" then
        util.makePath(dir)
    end

    local temp_path = local_path .. ".tmp"
    pcall(os.remove, temp_path)

    local file, err = io.open(temp_path, "wb")
    if not file then
        return false, err or "failed to open file for writing"
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 180)
    local request = {
        url = url,
        method = "GET",
        sink = socketutil.file_sink(file),
        redirect = true,
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT or "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
            ["Accept"] = "application/zip, application/octet-stream, */*",
        },
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    pcall(function() file:close() end)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        pcall(os.remove, temp_path)
        return false, status or code or "timeout"
    end

    if not headers then
        pcall(os.remove, temp_path)
        return false, status or code or "network error"
    end

    local res_code = tonumber(code) or 0
    if res_code ~= 200 then
        pcall(os.remove, temp_path)
        return false, status or ("HTTP " .. tostring(code))
    end

    pcall(os.remove, local_path)
    local rename_ok = os.rename(temp_path, local_path)
    if not rename_ok then
        local in_f = io.open(temp_path, "rb")
        local out_f = io.open(local_path, "wb")
        if in_f and out_f then
            out_f:write(in_f:read("*all"))
            in_f:close()
            out_f:close()
            pcall(os.remove, temp_path)
            return true, nil
        end
        pcall(os.remove, temp_path)
        return false, _("Failed to save downloaded file")
    end

    return true, nil
end

local function detectPluginFromArchive(reader, repo)
    local plugin_root
    local plugin_dirname
    local meta_entry_path
    local shortest_meta_path_len

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            if path:match("^_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    plugin_root = ""
                    plugin_dirname = nil
                    shortest_meta_path_len = #path
                end
            elseif path:match("%.koplugin/_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    local root = path:match("(.+%.koplugin)/_meta%.lua$")
                    if root then
                        plugin_root = root
                        plugin_dirname = root:match("([^/]+%.koplugin)$")
                        shortest_meta_path_len = #path
                    end
                end
            elseif not meta_entry_path and path:match("/_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    plugin_root = path:match("(.+)/_meta%.lua$")
                    plugin_dirname = nil
                    shortest_meta_path_len = #path
                end
            end
        end
    end

    if not plugin_root or not plugin_dirname or not meta_entry_path then
        if not plugin_root or not meta_entry_path then
            return nil, _("Could not locate plugin folder (_meta.lua) in archive.")
        end
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local plugin_name
    local plugin_version
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end

    if not plugin_dirname then
        local repo_name = repo and repo.name
        local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        
        -- 1. Check if an installed plugin on disk already matches this repo
        if repo and repo.name then
            local target_owner = getRepoOwner(repo)
            if target_owner then
                local records = getInstallRecordsMap()
                local installed = listInstalledPlugins()
                for _, inst in ipairs(installed) do
                    local rec = records[inst.dirname]
                    if rec and rec.owner and rec.repo then
                        if rec.owner:lower() == target_owner:lower() and rec.repo:lower() == repo.name:lower() then
                            plugin_dirname = inst.dirname
                            break
                        end
                    end
                end
            end
        end

        if not plugin_dirname then
            if repo_is_plugin_dir then
                plugin_dirname = repo_name
            elseif plugin_root and plugin_root ~= "" then
                local root_basename = plugin_root:match("([^/]+)$")
                if root_basename then
                    if root_basename:match("%.koplugin") then
                        local extracted = root_basename:match("([%w_%-%.]+%.koplugin)")
                        if extracted then
                            plugin_dirname = extracted
                        end
                    elseif root_basename ~= "plugins" and root_basename ~= "src" and root_basename:match("^[%w_%-%.]+$") then
                        plugin_dirname = sanitizePluginDirname(root_basename)
                    end
                end
            end
        end
        
        if not plugin_dirname then
            if repo_name and repo_name ~= "" then
                plugin_dirname = sanitizePluginDirname(repo_name)
            elseif plugin_name and plugin_name ~= "" then
                plugin_dirname = sanitizePluginDirname(plugin_name)
            else
                plugin_dirname = sanitizePluginDirname("Storefront")
            end
        end
    elseif (not plugin_name or plugin_name == "") then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = plugin_root,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }
end

detectPluginFromArchiveWithFallback = function(reader, repo, release, asset)
    local info, detect_err = detectPluginFromArchive(reader, repo)
    if info and info.plugin_root and info.plugin_dirname then
        return info, nil
    end

    -- Rewind before the fallback pass because the iterator is exhausted after the first scan.
    if reader and reader.rewind then
        reader:rewind()
    end

    local meta_entry_path
    local root_candidate
    local shallow_meta_entry
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path:match("^_meta%.lua$") then
                meta_entry_path = entry.path
                root_candidate = ""
                shallow_meta_entry = shallow_meta_entry or entry.path
            elseif entry.path:match("/_meta%.lua$") then
                meta_entry_path = entry.path
                root_candidate = entry.path:match("(.+)/_meta%.lua$")
                shallow_meta_entry = shallow_meta_entry or entry.path
            end
            if entry.path:match("/_meta%.lua$") and (not shallow_meta_entry or #entry.path < #shallow_meta_entry) then
                shallow_meta_entry = entry.path
                meta_entry_path = entry.path
                root_candidate = entry.path:match("(.+)/_meta%.lua$")
            end
        end
    end

    if not meta_entry_path or not root_candidate then
        return nil, detect_err or _("Could not locate plugin folder (_meta.lua) in archive.")
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local plugin_dirname = extractReleaseNameFallback(repo, release, asset, meta_source)

    local plugin_name
    local plugin_version
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end
    if (not plugin_name or plugin_name == "") and plugin_dirname then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = root_candidate,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }, nil
end

renderReleaseNotesText = function(repo, release)
    local title = repo and (repo.full_name or repo.name) or _("Repository")
    local tag = release and (release.tag_name or release.name) or _("Latest release")
    local body = release and release.body
    if not body or body == json.null then
        body = ""
    end
    body = tostring(body)
    body = softWrapLongTokens(body, 60)
    if body == "" then
        body = _("No release notes.")
    end
    return table.concat({
        string.format(_("Release notes for %s"), title),
        string.format(_("Release: %s"), tostring(tag)),
        "",
        body,
    }, "\n")
end

extractPluginToUserDir = function(reader, info, dest_root)
    dest_root = dest_root or PluginPaths.getDefaultPluginsRoot()
    util.makePath(dest_root)
    local target_dir = dest_root .. "/" .. info.plugin_dirname

    -- Protected configuration files that must NOT be overwritten when updating
    -- an existing plugin directory (preserving user-edited tokens/settings).
    local protected_configs = {
        ["storefront_config.lua"] = true,
        ["storefront_configuration.lua"] = true,
    }

    -- Collect the set of relative paths coming from the archive so we can
    -- remove only those files before extraction.  Files that exist locally
    -- but are NOT in the archive (e.g. user-created configuration files)
    -- are left untouched.
    local archive_relatives = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if info.plugin_root == "" then
                archive_relatives[entry.path] = true
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                archive_relatives[entry.path:sub(#info.plugin_root + 2)] = true
            end
        end
    end

    -- Remove only the files that the archive will replace so stale code
    -- from a previous version does not linger.
    if lfs.attributes(target_dir, "mode") == "directory" then
        local function remove_archive_files(dir, prefix)
            for f in lfs.dir(dir) do
                if f ~= "." and f ~= ".." then
                    local rel = (prefix == "") and f or (prefix .. "/" .. f)
                    local full = dir .. "/" .. f
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        remove_archive_files(full, rel)
                    elseif mode == "file" and archive_relatives[rel] and not protected_configs[rel] then
                        os.remove(full)
                    end
                end
            end
        end
        remove_archive_files(target_dir, "")
    end

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local relative
            if info.plugin_root == "" then
                relative = entry.path
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                relative = entry.path:sub(#info.plugin_root + 2)
            end

            if relative then
                local dest_path = target_dir .. "/" .. relative
                -- Preserve existing user configuration files during updates
                if not (protected_configs[relative] and lfs.attributes(dest_path, "mode") == "file") then
                    local parent = dest_path:match("^(.*)/")
                    if parent and parent ~= "" then
                        util.makePath(parent)
                    end
                    local ok = reader:extractToPath(entry.path, dest_path)
                    if not ok then
                        return false, _("Failed to extract file: ") .. entry.path
                    end
                end
            end
        end
    end

    return true, target_dir
end

function Storefront:promptRepoAction(repo)
    local dialog
    local buttons_row = {}

    if self.match_context and self.match_context.plugin then
        local plugin = self.match_context.plugin
        local buttons_row = {
            {
                text = _("Match with this repo"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    self:matchPluginWithRepo(plugin, repo)
                end,
            },
        }
        dialog = ConfirmBox:new{
            text = repo.full_name or repo.name or _("Repository"),
            cancel_text = _("Cancel"),
            no_ok_button = true,
            custom_content = makeTextBox(table.concat({
                string.format(_("Match plugin: %s"), plugin.name or plugin.dirname or _("plugin")),
                formatRepoEntry(repo),
            }, "\n\n")),
            other_buttons_first = true,
            other_buttons = { buttons_row },
        }
        UIManager:show(dialog)
        return
    end

    local current_kind = repo.kind or (self.browser_state and self.browser_state.kind) or "plugin"
    local DetailsDialog = require("storefront_details_dialog")
    local details_dialog = DetailsDialog:new{
        Storefront = self,
        repo = repo,
        kind = current_kind,
    }
    details_dialog:show()
end

function Storefront:promptPatchAction(repo, patch)
    if not repo or not patch then
        return
    end
    local DetailsDialog = require("storefront_details_dialog")
    local details_dialog = DetailsDialog:new{
        Storefront = self,
        repo = repo,
        patch = patch,
        kind = "patch",
    }
    details_dialog:show()
end


function Storefront:handlePostInstall(info, repo)
    if info and info.plugin_dirname and (not info.plugin_version or info.plugin_version == "") then
        local root = (self.pending_install_context and self.pending_install_context.plugin and self.pending_install_context.plugin.root)
            or PluginPaths.getDefaultPluginsRoot()
        local meta_path = root .. "/" .. info.plugin_dirname .. "/_meta.lua"
        local ok_meta, meta = pcall(dofile, meta_path)
        if ok_meta and type(meta) == "table" and meta.version then
            info.plugin_version = meta.version
        elseif info.plugin_release_tag and info.plugin_release_tag ~= "" then
            info.plugin_version = info.plugin_release_tag:gsub("^[vV]", "")
        end
    end

    self:rememberInstall(info, repo)
    self._cached_plugin_summary = nil
    UIManager:setDirty(nil, "full")

    if not self.pending_install_context then
        return
    end
    local context = self.pending_install_context
    self.pending_install_context = nil
    if context.mode == "update" then
        local plugin = context.plugin
        local record = plugin and getRecordedInstall(plugin.dirname)
        if plugin and record then
            if info.plugin_dirname then
                self:ensureUpdatesState()
                local cached = self.updates_state.remote_info[info.plugin_dirname] or {}
                if info.plugin_version and info.plugin_version ~= "" then
                    if not cached.release_tag_name or (info.plugin_release_tag and info.plugin_release_tag == cached.release_tag_name) then
                        cached.remote_version = info.plugin_version
                    end
                end
                cached.last_checked = os.time()
                cached.error = nil
                self.updates_state.remote_info[info.plugin_dirname] = cached
                self:saveUpdatesState()
            end
        end
    end
    if context and context.batch_callback then
        context.batch_callback(true)
    end
end

function Storefront:showRepoList(kind, title)
    local descriptors = self:getRepoDescriptors(kind)
    local lines = self:renderRepoLines(descriptors)
    local dialog
    dialog = ConfirmBox:new{
        text = title,
        cancel_text = _("Back"),
        no_ok_button = true,
        custom_content = self:buildListWidget(lines),
        other_buttons = #descriptors > 0 and {
            {
                {
                    text = _("Open details"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptSelection(descriptors, title)
                    end,
                },
            },
        } or nil,
    }
    UIManager:show(dialog)
end

function Storefront:promptSelection(descriptors, title)
    if #descriptors == 0 then
        UIManager:show(InfoMessage:new{ text = _("No cached entries yet."), timeout = 4 })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = title or _("Select repository"),
        input_hint = _("Enter item number"),
        input_type = "number",
        buttons = {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    if not value or value < 1 or value > #descriptors then
                        UIManager:show(InfoMessage:new{ text = _("Invalid selection."), timeout = 3 })
                        return
                    end
                    UIManager:close(dialog)
                    self:promptRepoAction(descriptors[value])
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:showReadme(repo)
    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for README download."), timeout = 4 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, path_or_err = RepoContent.fetchReadme(owner, repo.name)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("README download failed: ") .. tostring(path_or_err), timeout = 4 })
            return
        end
        self:closeBrowserMenu()
        RepoContent.openReadme(path_or_err)
    end)
end



function Storefront:init()
    Localization:init(self.path)
    StorefrontLogger.reset()
    local mode_str = GitHub.isDirectApiEnabled() and "Direct API" or "Storefront Catalog"
    local plugin_count = Cache.countRepos and Cache.countRepos("plugin") or #Cache.listRepos("plugin")
    StorefrontLogger.info(string.format("Storefront initialized (Mode: %s, Cached plugins: %d)", mode_str, plugin_count or 0))
    Storefront.instance = self
    self.cache_dir = ensureCacheDir()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Migrate settings to page size 5 if not set
    if StorefrontSettings:readSetting(BROWSER_PAGE_SIZE_KEY) ~= 5 or StorefrontSettings:readSetting(MANAGE_PAGE_SIZE_KEY) ~= 5 then
        StorefrontSettings:saveSetting(BROWSER_PAGE_SIZE_KEY, 5)
        StorefrontSettings:saveSetting(MANAGE_PAGE_SIZE_KEY, 5)
        StorefrontSettings:flush()
    end

    if not G_session_init_done then
        G_session_init_done = true

        -- Cleanup legacy test files from plugin directory if updating from an older version
        local plugin_dir = self.path or (PluginPaths.getDefaultPluginsRoot() .. "/storefront.koplugin")
        local legacy_test_files = {
            "storefront_plugin_paths_test.lua",
            "storefront_readme_test.lua",
            "storefront_release_notes_test.lua",
            "storefront_ui_test.lua",
        }
        local lfs_mod = require("libs/libkoreader-lfs")
        for _, legacy_file in ipairs(legacy_test_files) do
            local legacy_path = plugin_dir .. "/" .. legacy_file
            local ok_attr, attr = pcall(lfs_mod.attributes, legacy_path, "mode")
            if ok_attr and attr == "file" then
                os.remove(legacy_path)
            end
        end

        -- Ensure any .asset files in plugin assets are restored to standard .ttf/.otf extension
        local asset_dir_candidates = {
            plugin_dir .. "/assets/fonts",
            plugin_dir .. "/assets/bundled_fonts",
            plugin_dir .. "/storefront.koplugin/assets/fonts",
            plugin_dir .. "/storefront.koplugin/assets/bundled_fonts",
        }
        for _, a_dir in ipairs(asset_dir_candidates) do
            if lfs_mod.attributes(a_dir, "mode") == "directory" then
                for font_folder in lfs_mod.dir(a_dir) do
                    if font_folder ~= "." and font_folder ~= ".." then
                        local f_path = a_dir .. "/" .. font_folder
                        if lfs_mod.attributes(f_path, "mode") == "directory" then
                            for item in lfs_mod.dir(f_path) do
                                if item:match("%.asset$") then
                                    local restored_name = item:gsub("%.asset$", "")
                                    pcall(os.rename, f_path .. "/" .. item, f_path .. "/" .. restored_name)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- One-time migration: import legacy StorefrontSettings ignored_releases into InstallStore.
        -- The old system stored a single ignored tag per repo under "owner/repo" keys.
        -- The new system (InstallStore) stores per-tag flags under item_options[item_key].ignored_releases.
        do
            local MIGRATED_KEY = "ignored_releases_migrated_v1"
            if not StorefrontSettings:readSetting(MIGRATED_KEY) then
                local legacy_ignored = StorefrontSettings:readSetting(IGNORED_RELEASES_KEY) or {}
                for repo_key, tag in pairs(legacy_ignored) do
                    if type(repo_key) == "string" and type(tag) == "string" and tag ~= "" then
                        local owner_part, repo_part = repo_key:match("^([^/]+)/(.+)$")
                        if owner_part and repo_part then
                            -- Write into InstallStore keyed by both "owner/repo" and bare "repo"
                            local full_key = string.format("%s/%s", owner_part, repo_part)
                            local opts_full = InstallStore.getItemOptions(full_key)
                            opts_full.ignored_releases[tag] = true
                            InstallStore.setItemOptions(full_key, opts_full)
                            local opts_bare = InstallStore.getItemOptions(repo_part)
                            opts_bare.ignored_releases[tag] = true
                            InstallStore.setItemOptions(repo_part, opts_bare)
                        end
                    end
                end
                StorefrontSettings:saveSetting(MIGRATED_KEY, true)
                StorefrontSettings:flush()
            end
        end

        -- Cleanup any files or directories marked for deletion in previous sessions
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage then
            local data_dir = DataStorage:getDataDir()
            local fonts_roots = { data_dir .. "/fonts" }
            if lfs_mod.attributes("fonts", "mode") == "directory" then
                table.insert(fonts_roots, "fonts")
            end
            local found_deleted = false
            for _, f_root in ipairs(fonts_roots) do
                if lfs_mod.attributes(f_root, "mode") == "directory" then
                    for f in lfs_mod.dir(f_root) do
                        if f:match("%.deleted$") then
                            found_deleted = true
                            local full_path = f_root .. "/" .. f
                            local mode = lfs_mod.attributes(full_path, "mode")
                            if mode == "directory" then
                                local ok_ffi, ffiutil = pcall(require, "ffi/util")
                                if ok_ffi and ffiutil and type(ffiutil.purgeDir) == "function" then
                                    pcall(ffiutil.purgeDir, full_path)
                                end
                                for inner in lfs_mod.dir(full_path) do
                                    if inner ~= "." and inner ~= ".." then
                                        pcall(os.remove, full_path .. "/" .. inner)
                                    end
                                end
                                pcall(lfs_mod.rmdir, full_path)
                            elseif mode == "file" then
                                pcall(os.remove, full_path)
                            end
                        end
                    end
                end
            end
            -- If we cleaned up any deleted fonts, also nuke fontinfo.dat so KOReader
            -- does a fresh font scan on this startup rather than loading stale cache.
            if found_deleted then
                os.remove(data_dir .. "/cache/fontlist/fontinfo.dat")
                os.remove(data_dir .. "/cache/fontinfo.dat")
            end
        end
    end

    -- Trigger non-blocking silent catalog update on startup if online and cache is older than 1 hour (3600s)
    -- NOTE: We intentionally do NOT use NetworkMgr:runWhenOnline here because that prompts the user
    -- to enable wifi when offline. This is a background operation; silently skip if not connected.
    UIManager:nextTick(function()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if not (ok_nm and NetworkMgr) then return end

        -- Silently check connectivity without prompting
        local is_online = false
        if type(NetworkMgr.isOnline) == "function" then
            is_online = NetworkMgr:isOnline()
        elseif type(NetworkMgr.isWifiOn) == "function" then
            is_online = NetworkMgr:isWifiOn()
        elseif type(NetworkMgr.isConnected) == "function" then
            is_online = NetworkMgr:isConnected()
        end
        if not is_online then
            logger.info("Storefront init: skipping background catalog update — not online")
            return
        end

        local Cache = require("storefront_cache")
        local plugin_count = Cache.countRepos("plugin") or 0
        local patch_count = Cache.countRepos("patch") or 0
        local plugin_fetched = Cache.getLastFetched("plugin") or 0
        local patch_fetched = Cache.getLastFetched("patch") or 0
        local last_fetched = (plugin_fetched > 0 and patch_fetched > 0) and math.min(plugin_fetched, patch_fetched) or 0
        local age = (last_fetched > 0) and (os.time() - last_fetched) or 999999

        local needs_fetch = (last_fetched == 0 or plugin_count == 0 or patch_count == 0 or age > 3600)
        if Storefront.instance and needs_fetch then
            Storefront.instance._last_catalog_check_time = os.time()
        end

        if not GitHub.isDirectApiEnabled() and needs_fetch then
            local msg = string.format("Storefront init: catalog cache is stale/unfetched (plugins: %d, patches: %d, %ds old), triggering background fetch", plugin_count, patch_count, age)
            logger.info(msg)
            StorefrontLogger.info(msg)
            local CatalogClient = require("storefront_net_catalog")
            CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
                if ok then
                    logger.info("Storefront init: background catalog update finished")
                    StorefrontLogger.info("Storefront init: background catalog update finished")
                    if Storefront.instance and Storefront.instance.browser_menu then
                        Storefront.instance:reopenBrowser()
                    end
                else
                    logger.warn("Storefront init: background catalog update failed: " .. tostring(err))
                    StorefrontLogger.warn("Storefront init: background catalog update failed: " .. tostring(err))
                    if Cache.countRepos("plugin") == 0 then
                        logger.info("Storefront init: catalog cache empty after fetch error, loading bundled catalog fallback")
                        CatalogClient.loadBundledCatalog()
                        if Storefront.instance and Storefront.instance.browser_menu then
                            Storefront.instance:reopenBrowser()
                        end
                    end
                    if Storefront.instance and not Storefront.instance._init_catalog_retried then
                        Storefront.instance._init_catalog_retried = true
                        local UIManager = require("ui/uimanager")
                        UIManager:scheduleIn(60, function()
                            logger.info("Storefront init: retrying background catalog update after delay...")
                            if StorefrontLogger then StorefrontLogger.info("Storefront init: retrying background catalog update after delay...") end
                            CatalogClient.fetchAndUpdateCacheAsync(nil, function(retry_ok, retry_err)
                                if retry_ok then
                                    logger.info("Storefront init: background catalog update retry succeeded")
                                    if StorefrontLogger then StorefrontLogger.info("Storefront init: background catalog update retry succeeded") end
                                    if Storefront.instance and Storefront.instance.browser_menu then
                                        Storefront.instance:reopenBrowser()
                                    end
                                else
                                    logger.warn("Storefront init: background catalog update retry failed: " .. tostring(retry_err))
                                    if StorefrontLogger then StorefrontLogger.warn("Storefront init: background catalog update retry failed: " .. tostring(retry_err)) end
                                    if Cache.countRepos("plugin") == 0 then
                                        CatalogClient.loadBundledCatalog()
                                    end
                                end
                            end)
                        end)
                    end
                end
            end)
        else
            local msg = string.format("Storefront init: catalog cache is fresh (%ds old <= 3600s), skipping background fetch", age)
            logger.info(msg)
            StorefrontLogger.info(msg)
        end
    end)
end


local function injectStorefrontIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function isItemInOrder(tbl, target_id)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == target_id then
                return true
            elseif type(val) == "table" then
                if isItemInOrder(val, target_id) then
                    return true
                end
            end
        end
        return false
    end

    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not isItemInOrder(order, "Storefront") then
                table.insert(order.tools, 2, "Storefront")
            end
        end
    end
end

function Storefront:addToMainMenu(menu_items)
    injectStorefrontIntoToolsMenu()
    menu_items.Storefront = {
        sorting_hint = "tools",
        text = _("Storefront"),
        callback = function()
            self:showBrowser()
        end,
    }
end

function Storefront:onDispatcherRegisterActions()
    Dispatcher:registerAction("storefront_open", {
        category = "none",
        event = "StorefrontOpen",
        title = _("Storefront: Open"),
        general = true,
    })
end

function Storefront:onStorefrontOpen()
    UIManager:nextTick(function()
        self:showBrowser()
    end)
    return true
end

Storefront.listInstalledPlugins = listInstalledPlugins
Storefront.listInstalledPatches = listInstalledPatches
Storefront.getInstallRecordsMap = getInstallRecordsMap
Storefront.getPatchRecordsMap = getPatchRecordsMap
Storefront.getBrowserPageSize = getBrowserPageSize

return Storefront
