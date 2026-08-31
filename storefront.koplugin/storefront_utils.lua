local storefront_utils = {}

function storefront_utils.softWrapLongTokens(text, max_len)
    max_len = tonumber(max_len) or 60
    if not text or text == "" then
        return ""
    end
    text = tostring(text)
    return text:gsub("(%S+)", function(token)
        if #token <= max_len then
            return token
        end
        if token:match("[\128-\255]") then
            return token
        end
        local parts = {}
        local i = 1
        while i <= #token do
            parts[#parts + 1] = token:sub(i, i + max_len - 1)
            i = i + max_len
        end
        return table.concat(parts, "\n")
    end)
end

function storefront_utils.normalizeMetaPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = path:gsub("^/+", "")
    if normalized == "_meta.lua" then
        return normalized
    end
    if normalized:match("/_meta%.lua$") then
        return normalized
    end
    if not normalized:match("%.koplugin$") then
        normalized = normalized .. ".koplugin"
    end
    return normalized .. "/_meta.lua"
end

function storefront_utils.sanitizeMetaPath(path, fallback)
    if path and path ~= "" then
        local normalized = storefront_utils.normalizeMetaPath(path)
        if normalized then
            return normalized
        end
    end
    if fallback and fallback ~= "" then
        return storefront_utils.normalizeMetaPath(fallback)
    end
end

function storefront_utils.firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
end

local function parseVersionDescriptor(v_str)
    v_str = tostring(v_str):gsub("^[vV]", "")
    local main_str, pre_str = v_str:match("^([%d%.]+)%-?(.*)$")
    if not main_str or main_str == "" then
        main_str = v_str
        pre_str = ""
    end

    local nums = {}
    for part in main_str:gmatch("%d+") do
        table.insert(nums, tonumber(part) or 0)
    end

    local pre_info = nil
    if pre_str and pre_str ~= "" then
        local pre_type, pre_num = pre_str:match("^([a-zA-Z]+)(%d*)$")
        if not pre_type then
            pre_type = pre_str
            pre_num = "0"
        end
        local ranks = {
            dev = 1,
            alpha = 2,
            beta = 3,
            preview = 4,
            rc = 5,
        }
        pre_info = {
            type_rank = ranks[pre_type:lower()] or 0,
            type_name = pre_type:lower(),
            num = tonumber(pre_num) or 0,
        }
    end

    return {
        nums = nums,
        pre = pre_info,
    }
end

function storefront_utils.isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    v1_str = tostring(v1_str):gsub("^[vV]", "")
    v2_str = tostring(v2_str):gsub("^[vV]", "")
    if v1_str == v2_str then
        return false
    end

    local d1 = parseVersionDescriptor(v1_str)
    local d2 = parseVersionDescriptor(v2_str)

    local max_len = math.max(#d1.nums, #d2.nums)
    for i = 1, max_len do
        local a = d1.nums[i] or 0
        local b = d2.nums[i] or 0
        if a > b then
            return true
        end
        if a < b then
            return false
        end
    end

    if not d1.pre and d2.pre then
        return true
    end
    if d1.pre and not d2.pre then
        return false
    end

    if d1.pre and d2.pre then
        if d1.pre.type_rank ~= d2.pre.type_rank then
            return d1.pre.type_rank > d2.pre.type_rank
        end
        if d1.pre.type_name ~= d2.pre.type_name then
            return d1.pre.type_name > d2.pre.type_name
        end
        if d1.pre.num ~= d2.pre.num then
            return d1.pre.num > d2.pre.num
        end
    end

    return false
end

function storefront_utils.normalizeDescription(value)
    if type(value) ~= "string" then
        return ""
    end
    if value:match("^function:%s*0x%x+$") then
        return ""
    end
    return value
end

function storefront_utils.parseGitHubTimestamp(value)
    if type(value) ~= "string" then
        return 0
    end
    local year, month, day, hour, min, sec = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return 0
    end
    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    }) or 0
end

function storefront_utils.repoStarsValue(repo)
    if type(repo) ~= "table" then return 0 end
    local s = tonumber(repo.stars)
    if s and s > 0 then return s end
    if repo.data then
        s = tonumber(repo.data.stargazers_count) or tonumber(repo.data.stars)
        if s and s > 0 then return s end
    end
    return s or 0
end

function storefront_utils.repoIsFork(repo)
    if type(repo) ~= "table" then return false end
    if repo.fork ~= nil then return repo.fork == true end
    if repo.data and repo.data.fork ~= nil then return repo.data.fork == true end
    return false
end

function storefront_utils.getMappedScreensaverCategories(cat_input)
    if not cat_input then
        return { "Fine Art" }
    end

    local raw_list = {}
    if type(cat_input) == "table" then
        for _, v in ipairs(cat_input) do
            if type(v) == "string" and v ~= "" then
                table.insert(raw_list, v)
            end
        end
        if #raw_list == 0 then
            for _, v in pairs(cat_input) do
                if type(v) == "string" and v ~= "" then
                    table.insert(raw_list, v)
                end
            end
        end
    elseif type(cat_input) == "string" then
        if cat_input == "" then return { "Fine Art" } end
        for part in string.gmatch(cat_input, "[^,]+") do
            table.insert(raw_list, part)
        end
    end

    if #raw_list == 0 then
        return { "Fine Art" }
    end

    local result = {}
    local seen = {}
    for _, part in ipairs(raw_list) do
        local c = part:match("^%s*(.-)%s*$"):lower()
        local mapped = nil
        if c:find("transparent") or c:find("overlay") then
            mapped = "Transparent"
        elseif c:find("space") or c:find("astronomy") or c:find("sci") then
            mapped = "Sci-Fi"
        elseif c:find("nature") or c:find("landscape") then
            mapped = "Nature"
        elseif c:find("pop") or c:find("culture") then
            mapped = "Pop Culture"
        elseif c:find("cozy") or c:find("minimal") then
            mapped = "Minimalist"
        elseif c:find("abstract") or c:find("dark") then
            mapped = "Abstract"
        elseif c:find("anime") then
            mapped = "Anime"
        elseif c:find("architect") or c:find("miniature") then
            mapped = "Architecture"
        elseif c:find("fantasy") then
            mapped = "Fantasy"
        elseif c:find("quote") then
            mapped = "Quotes"
        elseif c:find("art") or c:find("ceramic") or c:find("drawing") or c:find("paint") or c:find("print") or c:find("sculpture") or c:find("installation") or c:find("funerary") then
            mapped = "Fine Art"
        else
            local clean = part:match("^%s*(.-)%s*$")
            if clean ~= "" then
                mapped = clean:sub(1,1):upper() .. clean:sub(2):lower()
            else
                mapped = "Fine Art"
            end
        end
        if mapped and not seen[mapped:lower()] then
            seen[mapped:lower()] = true
            table.insert(result, mapped)
        end
    end
    if #result == 0 then table.insert(result, "Fine Art") end
    return result
end

function storefront_utils.calcDynamicFontSize(text, max_width, face_name, max_font_size, min_font_size, bold)
    if not text or text == "" or not max_width or max_width <= 0 then
        return max_font_size or 22
    end
    face_name = face_name or "NotoSerif-Regular.ttf"
    max_font_size = max_font_size or 22
    min_font_size = min_font_size or 11
    if bold == nil then bold = true end

    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")

    for sz = max_font_size, min_font_size, -1 do
        local face = Font:getFace(face_name, sz)
        local tw = TextWidget:new{ text = text, face = face, bold = bold }
        if tw:getSize().w <= max_width then
            return sz
        end
    end
    return min_font_size
end

function storefront_utils.calcGroupFontSize(texts, total_avail_width, gap, face_name, padding_per_item, max_font_size, min_font_size)
    face_name = face_name or "cfont"
    local Device = require("device")
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local sc = function(val)
        return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
    end
    padding_per_item = padding_per_item or sc(16)
    max_font_size = max_font_size or 18
    min_font_size = min_font_size or 10
    local num = #texts
    if num == 0 then return max_font_size end
    local gaps_total = gap * math.max(0, num - 1)
    for sz = max_font_size, min_font_size, -1 do
        local face = Font:getFace(face_name, sz)
        local total_w = gaps_total
        for _, text in ipairs(texts) do
            local tw = TextWidget:new{ text = text, face = face, bold = true }
            local sz = tw.getSize and tw:getSize()
            local tw_w = (sz and sz.w) or (#text * 8)
            total_w = total_w + tw_w + padding_per_item
        end
        if total_w <= total_avail_width then
            return sz
        end
    end
    return min_font_size
end

function storefront_utils.calcProportionalBtnWidths(button_texts, total_avail_width, gap, font_size, face_name)
    local num_btns = #button_texts
    if num_btns == 0 then return {} end
    if num_btns == 1 then return { total_avail_width } end

    local Device = require("device")
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local sc = function(val)
        return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
    end

    font_size = font_size or 18
    face_name = face_name or "cfont"
    local usable_width = total_avail_width - gap * (num_btns - 1)

    local ideal_widths = {}
    local total_ideal = 0
    local padding_per_btn = sc(16)
    local face = Font:getFace(face_name, font_size)

    for i, text in ipairs(button_texts) do
        local tw = TextWidget:new{ text = text, face = face, bold = true }
        local sz = tw.getSize and tw:getSize()
        local tw_w = (sz and sz.w) or (#text * 8)
        local ideal = tw_w + padding_per_btn
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

function storefront_utils.createButton(opts)
    opts = opts or {}
    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local TextWidget = require("ui/widget/textwidget")
    local sc = function(val)
        return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
    end

    local btn_w = opts.width
    local btn_h = opts.height or sc(38)
    local is_primary = (opts.background == Blitbuffer.COLOR_BLACK) or (opts.primary == true)
    local border_size = opts.bordersize or (storefront_theme.border_btn or sc(1))
    local border_color = opts.color or Blitbuffer.COLOR_BLACK
    local radius = opts.radius or (storefront_theme.radius_btn or sc(4))

    local face_name = opts.face_name or "cfont"
    local initial_font_size = opts.text_font_size or 18
    local chosen_font_size = initial_font_size

    if btn_w and opts.text and opts.text ~= "" then
        local max_text_w = math.max(10, btn_w - sc(16))
        for sz = initial_font_size, 10, -1 do
            local test_face = Font:getFace(face_name, sz)
            local tw = TextWidget:new{
                text = opts.text,
                face = test_face,
                bold = (opts.bold ~= false),
            }
            local tw_sz = tw.getSize and tw:getSize()
            local tw_w = (tw_sz and tw_sz.w) or (#opts.text * 8)
            if tw_w <= max_text_w then
                chosen_font_size = sz
                break
            end
            chosen_font_size = sz
        end
    end

    local btn_opts = {
        text = opts.text or "",
        text_font_size = chosen_font_size,
        text_font_bold = (opts.bold ~= false),
        bordersize = border_size,
        border_color = border_color,
        padding = 0,
        radius = radius,
        width = btn_w,
        height = btn_h,
        show_parent = opts.show_parent,
        callback = opts.callback,
    }

    if is_primary then
        btn_opts.background = Blitbuffer.COLOR_BLACK
        btn_opts.text_font_color = Blitbuffer.COLOR_WHITE
    else
        btn_opts.background = nil
        btn_opts.text_font_color = opts.text_font_color or Blitbuffer.COLOR_BLACK
    end

    local btn = Button:new(btn_opts)
    if is_primary and btn.label_widget then
        btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    return btn
end

function storefront_utils.showConfirmDialog(opts)
    opts = opts or {}
    local storefront_theme = require("storefront_theme")
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager = require("ui/uimanager")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Localization = require("localization_storefront")
    local _ = function(key, ...) return Localization:t(key, ...) end

    local sc = function(val)
        return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
    end

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local card_padding = sc(14)
    local card_border = storefront_theme.border_window or sc(2)
    local dialog_w = math.min(sw - sc(20), sc(380))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = storefront_theme.face_label_size or 18
    local title_font_size = storefront_theme.title_font_size or 22

    local overlay

    local title_text = opts.title or _("Confirm")
    local dynamic_title_size = storefront_utils.calcDynamicFontSize(title_text, inner_w, "NotoSerif-Regular.ttf", title_font_size, 12, true)
    local title_label = TextBoxWidget:new{
        text = title_text,
        face = Font:getFace("NotoSerif-Regular.ttf", dynamic_title_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local content_items = { title_label }

    if opts.text and opts.text ~= "" then
        local body_widget = TextBoxWidget:new{
            text = opts.text,
            face = Font:getFace("cfont", ui_font_size),
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = inner_w,
            alignment = "center",
        }
        table.insert(content_items, VerticalSpan:new{ width = sc(12) })
        table.insert(content_items, body_widget)
    end

    local btn_gap = sc(12)
    local cancel_text = opts.cancel_text or _("Cancel")
    local ok_text = opts.ok_text or _("OK")
    local btn_font_size = storefront_utils.calcGroupFontSize({ cancel_text, ok_text }, inner_w, btn_gap, "cfont", sc(16), 18, 10)
    local btn_widths = storefront_utils.calcProportionalBtnWidths({ cancel_text, ok_text }, inner_w, btn_gap, btn_font_size, "cfont")

    local FocusManager = require("ui/widget/focusmanager")

    local cancel_btn = storefront_utils.createButton{
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

    local ok_btn = storefront_utils.createButton{
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

    local buttons_hg = HorizontalGroup:new{
        cancel_btn,
        HorizontalSpan:new{ width = btn_gap },
        ok_btn,
    }

    table.insert(content_items, VerticalSpan:new{ width = sc(16) })
    table.insert(content_items, buttons_hg)

    local content_vg = VerticalGroup:new{
        align = "center",
        unpack(content_items)
    }

    local card = FrameContainer:new{
        bordersize = card_border,
        radius = storefront_theme.radius_window or 0,
        color = Blitbuffer.COLOR_BLACK,
        padding = card_padding,
        background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
        content_vg,
    }

    local Input = Device and Device.input
    local key_events = {
        Close = { { "Back" }, { "Escape" } }
    }
    if Input and Input.group and Input.group.Back then
        table.insert(key_events.Close, { Input.group.Back })
    end

    overlay = FocusManager:new{
        align = "center",
        vertical_align = "center",
        dimen = Geom:new{ w = sw, h = sh },
        layout = { { cancel_btn, ok_btn } },
        selected = { x = 2, y = 1 },
        key_events = key_events,
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
    return overlay
end

return storefront_utils

