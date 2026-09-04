-- spec_helper.lua
-- Helper file for KOReader storefront plugin unit and integration tests

package.path = package.path .. ";storefront.koplugin/?.lua"
package.path = package.path .. ";plugins/storefront.koplugin/?.lua"
package.path = package.path .. ";../?.lua"
package.path = package.path .. ";?.lua"

-- Mocking KOReader environment
package.loaded["device"] = {
    getModel = function() return "K5" end,
    isAndroid = function() return false end,
    isKindle = function() return true end,
    isPocketBook = function() return false end,
    isKobo = function() return false end,
    isKoboV2 = function() return false end,
    hasDPad = function() return false end,
    hasKeys = function() return false end,
    hasKeyboard = function() return false end,
    input = { group = {} },
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(a, b) return b or a end,
    }
}

_G.G_defaults = _G.G_defaults or {
    readSetting = function() end,
    saveSetting = function() end,
}
_G.G_reader_settings = _G.G_reader_settings or {
    readSetting = function() end,
    saveSetting = function() end,
    isTrue = function() return false end,
}
package.loaded["dispatcher"] = {
    registerAction = function() end,
    getAction = function() return { name = "dummy" } end,
}

package.loaded["lfs"] = {
    attributes = function(path, req)
        if req == "mode" then
            if path and (path:match("%.jpg$") or path:match("%.png$") or path:match("%.lua$") or path:match("%.disabled$") or path:match("%.zip$")) then
                return "file"
            end
            return "directory"
        end
        if path and (path:match("%.jpg$") or path:match("%.png$") or path:match("%.lua$") or path:match("%.disabled$") or path:match("%.zip$")) then
            return { mode = "file", size = 1234, modification = os.time() }
        end
        return { mode = "directory", size = 4096, modification = os.time() }
    end,
    dir = function(path)
        local dummy_state = { __name = "directory", path = path }
        local entries = {}
        if path and type(path) == "string" then
            local ok, p = pcall(io.popen, "ls -a \"" .. path .. "\" 2>/dev/null")
            if ok and p then
                for line in p:lines() do
                    line = line:gsub("[\r\n]$", "")
                    if line ~= "" then
                        table.insert(entries, line)
                    end
                end
                p:close()
            end
        end
        if #entries == 0 then
            if path and tostring(path):match("languages") then
                entries = {
                    ".", "..",
                    "ar.po", "de.po", "en.po", "es.po", "fr.po",
                    "hu.po", "id.po", "it.po", "ja.po", "ko.po",
                    "nl.po", "pl.po", "pt_br.po", "ru.po", "sr.po",
                    "tr.po", "uk.po", "zh_CN.po",
                }
            else
                entries = { ".", "..", "sample_wallpaper.jpg" }
            end
        end
        local idx = 0
        local function iter(state)
            if state ~= dummy_state then
                error("bad argument #1 to '(for generator)' (directory metatable expected, got " .. type(state) .. ")", 2)
            end
            idx = idx + 1
            return entries[idx]
        end
        return iter, dummy_state
    end,
    mkdir = function() return true end,
    rmdir = function() return true end,
}
package.loaded["libs/libkoreader-lfs"] = package.loaded["lfs"]

package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
    debug = function(...) end,
    dbg = function(...) end,
    setLevel = function(...) end,
    levels = { DBG = 1, INFO = 2, WARN = 3, ERR = 4 },
}

local ds_mock = {
    getSettingsDir = function() return "/tmp/koreader/settings" end,
    getDataDir = function() return "/tmp/koreader" end,
    writeToFile = function(...) return true end,
    readFromFile = function(...) return {} end,
    save = function(...) return true end,
    load = function(...) return {} end,
}
package.loaded["datastorage"] = ds_mock
package.loaded["DataStorage"] = ds_mock
package.loaded["frontend/datastorage"] = ds_mock
package.loaded["frontend/DataStorage"] = ds_mock

local luasettings_mock = {
    open = function(self, path)
        local s = {
            data = {},
            readSetting = function(me, k, default) return me.data[k] or default end,
            saveSetting = function(me, k, v) me.data[k] = v end,
            isTrue = function(me, k) return me.data[k] == true end,
            isFalse = function(me, k) return me.data[k] == false end,
            isNil = function(me, k) return me.data[k] == nil end,
            has = function(me, k) return me.data[k] ~= nil end,
            flush = function() return true end,
            close = function() end,
        }
        return s
    end
}
package.loaded["luasettings"] = luasettings_mock
package.loaded["LuaSettings"] = luasettings_mock

-- UI tracking for testing
_G.ui_tracker = {
    shown = {},
    last_shown = nil,
    closed = {}
}

package.loaded["ui/uimanager"] = {
    show = function(self, widget, refreshtype, region, x, y)
        local w = type(self) == "table" and widget or self
        local posX = type(self) == "table" and x or refreshtype
        local posY = type(self) == "table" and y or region
        table.insert(_G.ui_tracker.shown, w)
        _G.ui_tracker.last_shown = w
        _G.ui_tracker.last_show_x = posX
        _G.ui_tracker.last_show_y = posY
    end,
    close = function(a, b)
        local w = b or a
        table.insert(_G.ui_tracker.closed, w)
    end,
    scheduleIn = function(a, b, c)
        if type(a) == "function" then a()
        elseif type(b) == "function" then b()
        elseif type(c) == "function" then c() end
    end,
    nextTick = function(a, b)
        local f = b or a
        if type(f) == "function" then f() end
    end,
    setDirty = function() end,
    forceRePaint = function() end,
    getTime = function() return 0 end,
}
package.loaded["ui/widget/infomessage"] = {
    new = function(a, b) return { type = "InfoMessage", args = b or a } end
}
package.loaded["ui/widget/notification"] = {
    new = function(a, b) return { type = "Notification", args = b or a } end
}
package.loaded["ui/widget/progressbardialog"] = {
    new = function(a, b)
        local dialog = { type = "ProgressBarDialog", args = b or a }
        dialog.show = function() end
        dialog.close = function() end
        dialog.reportProgress = function() end
        return dialog
    end
}
package.loaded["ui/widget/buttondialog"] = {
    new = function(a, b) 
        local dialog = { type = "ButtonDialog", args = b or a }
        dialog.getSize = function() return { w = 800, h = 100 } end
        return dialog
    end
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(a, b) return { type = "ConfirmBox", args = b or a } end
}
package.loaded["ui/widget/textviewer"] = {
    new = function(a, b) return { type = "TextViewer", args = b or a } end
}
package.loaded["ui/widget/menu"] = {
    new = function(a, b) return { type = "Menu", args = b or a } end
}
package.loaded["ui/widget/verticalgroup"] = {
    new = function(a, b)
        local args = b or a or {}
        local vg = { type = "VerticalGroup", args = args }
        for k, v in pairs(args) do vg[k] = v end
        vg.getSize = function() return { w = 100, h = 50 } end
        return vg
    end
}
package.loaded["ui/widget/widget"] = (function()
    local klass = {}
    klass.extend = function(self, prototype)
        prototype = prototype or {}
        prototype.new = function(cls, args)
            local instance = {}
            for k, v in pairs(prototype) do instance[k] = v end
            for k, v in pairs(args or {}) do instance[k] = v end
            return instance
        end
        return prototype
    end
    klass.new = function(self, args)
        return klass:extend(args):new()
    end
    return klass
end)()
package.loaded["ui/widget/widgetcontainer"] = {
    new = function(a, b) return { type = "WidgetContainer", args = b or a } end
}
package.loaded["ui/widget/container/framecontainer"] = {
    new = function(a, b) 
        local fc = { type = "FrameContainer", args = b or a }
        fc.getSize = function() return { w = 800, h = 300 } end
        return fc
    end
}
package.loaded["ui/widget/container/alphacontainer"] = {
    new = function(a, b)
        local ac = { type = "AlphaContainer", args = b or a }
        ac.getSize = function() return { w = 800, h = 800 } end
        ac.paintTo = function() end
        ac.onCloseWidget = function() end
        return ac
    end
}
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(a, b) return { type = "CenterContainer", args = b or a } end
}
package.loaded["ui/widget/container/movablecontainer"] = {
    new = function(a, b) return { type = "MovableContainer", args = b or a } end
}
package.loaded["ui/widget/container/widgetcontainer"] = (function()
    local klass = {}
    klass.extend = function(self, prototype)
        prototype = prototype or {}
        prototype.new = function(cls, args)
            args = args or {}
            local instance = {}
            for k, v in pairs(prototype) do instance[k] = v end
            for k, v in pairs(args) do instance[k] = v end
            instance.type = "WidgetContainer"
            if instance.init then instance:init() end
            return instance
        end
        return prototype
    end
    klass.new = function(self, args)
        return klass:extend(args):new()
    end
    return klass
end)()
package.loaded["ui/widget/container/scrollablecontainer"] = {
    new = function(a, b)
        local sc = { type = "ScrollableContainer", args = b or a }
        sc.getSize = function() return { w = 800, h = 600 } end
        return sc
    end
}
package.loaded["ui/widget/horizontalscrollbar"] = {
    new = function(a, b) return { type = "HorizontalScrollBar", args = b or a } end
}
package.loaded["ui/widget/container/inputcontainer"] = (function()
    local klass = {}
    klass.extend = function(self, prototype)
        prototype = prototype or {}
        prototype.new = function(cls, args)
            args = args or {}
            local instance = {}
            for k, v in pairs(prototype) do instance[k] = v end
            for k, v in pairs(args) do instance[k] = v end
            instance.type = "InputContainer"
            if instance.init then instance:init() end
            return instance
        end
        return prototype
    end
    klass.new = function(self, args)
        return klass:extend(args):new()
    end
    return klass
end)()
package.loaded["ui/widget/focusmanager"] = (function()
    local klass = {}
    klass.extend = function(self, prototype)
        prototype = prototype or {}
        prototype.onFocusMove = function(self, args)
            if not self.layout then return false end
            local dx, dy = args[1] or 0, args[2] or 0
            if not self.selected then self.selected = { x = 1, y = 1 } end
            local target_y = self.selected.y + dy
            if target_y >= 1 and target_y <= #self.layout then
                local row = self.layout[target_y]
                local target_x = math.min(math.max(1, self.selected.x + dx), #row)
                self.selected = { x = target_x, y = target_y }
                local item = row[target_x]
                if item and item.handleEvent then
                    item:handleEvent({ name = "Focus" })
                end
                return true
            end
            return false
        end
        prototype.getFocusItem = function(self)
            if self.layout and self.selected and self.layout[self.selected.y] then
                return self.layout[self.selected.y][self.selected.x]
            end
            return nil
        end
        prototype.onPress = function(self)
            local item = self:getFocusItem()
            if item and item.onTapSelect then return item:onTapSelect() end
            if item and item.callback then item.callback(); return true end
            return false
        end
        prototype.new = function(cls, args)
            args = args or {}
            local instance = {}
            for k, v in pairs(prototype) do instance[k] = v end
            for k, v in pairs(args) do instance[k] = v end
            instance.type = "FocusManager"
            if instance.init then instance:init() end
            return instance
        end
        return prototype
    end
    klass.onFocusMove = function(self, args)
        if not self.layout then return false end
        local dx, dy = args[1] or 0, args[2] or 0
        if not self.selected then self.selected = { x = 1, y = 1 } end
        local target_y = self.selected.y + dy
        if target_y >= 1 and target_y <= #self.layout then
            local row = self.layout[target_y]
            local target_x = math.min(math.max(1, self.selected.x + dx), #row)
            self.selected = { x = target_x, y = target_y }
            local item = row[target_x]
            if item and item.handleEvent then
                item:handleEvent({ name = "Focus" })
            end
            return true
        end
        return false
    end
    klass.getFocusItem = function(self)
        if self.layout and self.selected and self.layout[self.selected.y] then
            return self.layout[self.selected.y][self.selected.x]
        end
        return nil
    end
    klass.onPress = function(self)
        local item = self:getFocusItem()
        if item and item.onTapSelect then return item:onTapSelect() end
        if item and item.callback then item.callback(); return true end
        return false
    end
    klass.new = function(self, args)
        return klass:extend(args):new()
    end
    return klass
end)()
package.loaded["ui/widget/container/leftcontainer"] = {
    new = function(a, b) return { type = "LeftContainer", args = b or a } end
}
package.loaded["ui/widget/container/rightcontainer"] = {
    new = function(a, b) return { type = "RightContainer", args = b or a } end
}
package.loaded["ui/widget/container/bottomcontainer"] = {
    new = function(a, b) return { type = "BottomContainer", args = b or a } end
}
package.loaded["ui/widget/textboxwidget"] = {
    new = function(a, b)
        local tb = { type = "TextBoxWidget", args = b or a }
        tb.getSize = function() return { w = 200, h = 40 } end
        return tb
    end
}
package.loaded["ui/widget/linewidget"] = {
    new = function(a, b)
        local lw = { type = "LineWidget", args = b or a }
        lw.getSize = function() return { w = 200, h = 2 } end
        return lw
    end
}
package.loaded["ui/widget/verticalspan"] = {
    new = function(a, b) return { type = "VerticalSpan", args = b or a } end
}
package.loaded["ui/widget/horizontalgroup"] = {
    new = function(a, b)
        local args = b or a or {}
        local hg = { type = "HorizontalGroup", args = args }
        for k, v in pairs(args) do hg[k] = v end
        hg.getSize = function() return { w = 100, h = 50 } end
        return hg
    end
}
package.loaded["ui/widget/horizontalspan"] = {
    new = function(a, b) return { type = "HorizontalSpan", args = b or a } end
}
package.loaded["ui/size"] = {
    line = { thick = 2, thin = 1, default = 1 },
    border = { thick = 2, thin = 1, default = 1 },
    padding = { small = 4, default = 8, large = 16 },
    span = { vertical_default = 8, horizontal_default = 8 },
}
package.loaded["ui/geometry"] = {
    new = function(a, b) return b or a end
}
package.loaded["ui/widget/table"] = {
    new = function(a, b) return { type = "Table", args = b or a } end
}
package.loaded["ui/widget/checkbutton"] = {
    new = function(a, b) return { type = "CheckButton", args = b or a } end
}
package.loaded["ui/widget/checkmark"] = {
    new = function(a, b) return { type = "CheckMark", args = b or a } end
}
package.loaded["ui/widget/iconbutton"] = {
    new = function(a, b) return { type = "IconButton", args = b or a } end
}
package.loaded["ui/widget/titlebar"] = {
    new = function(a, b) return { type = "TitleBar", args = b or a } end
}
package.loaded["ui/widget/verticalscrollbar"] = {
    new = function(a, b) return { type = "VerticalScrollBar", args = b or a } end
}
package.loaded["ui/widget/scrolltextwidget"] = {
    new = function(a, b) return { type = "ScrollTextWidget", args = b or a } end
}
package.loaded["ui/widget/inputdialog"] = {
    new = function(a, b) return { type = "InputDialog", args = b or a } end
}
package.loaded["ui/widget/multiinputdialog"] = {
    new = function(a, b) return { type = "MultiInputDialog", args = b or a } end
}
package.loaded["ui/widget/spinwidget"] = {
    new = function(a, b) return { type = "SpinWidget", args = b or a } end
}
package.loaded["ui/widget/iconwidget"] = {
    new = function(a, b) return { type = "IconWidget", args = b or a } end
}
package.loaded["ui/widget/multiconfirmbox"] = {
    new = function(a, b) return { type = "MultiConfirmBox", args = b or a } end
}
package.loaded["ui/network/manager"] = {
    isOnline = function() return true end
}
package.loaded["ui/widget/htmlboxwidget"] = {
    new = function(a, b)
        local hb = { type = "HtmlBoxWidget", args = b or a, page_number = 1 }
        hb.setContent = function() end
        hb.getSize = function() return { w = 200, h = 200 } end
        return hb
    end
}
package.loaded["ui/widget/textviewer"] = {
    new = function(a, b) return { type = "TextViewer", args = b or a } end
}
package.loaded["ui/widget/imageviewer"] = {
    new = function(a, b) return { type = "ImageViewer", args = b or a } end
}
package.loaded["ui/widget/screenshoter"] = {}
package.loaded["ui/widget/booklist"] = {}
package.loaded["ui/renderimage"] = {}
package.loaded["ui/widget/confirmbox"] = {
    new = function(a, b) return { type = "ConfirmBox", args = b or a } end
}
package.loaded["ui/widget/textwidget"] = {
    new = function(a, b) 
        local args = b or a or {}
        local tw = { type = "TextWidget", args = args, text = args.text or "" }
        tw.getSize = function() return { w = #(tw.args and tw.args.text or tw.text or "") * 8, h = 20 } end
        return tw
    end
}
package.loaded["ui/widget/button"] = {
    new = function(a, b) 
        local args = b or a or {}
        local btn = { type = "Button", args = args }
        for k, v in pairs(args) do btn[k] = v end
        btn.getSize = function() return { w = 100, h = 50 } end
        btn.enableDisable = function() end
        btn.enable = function() end
        btn.disable = function() end
        btn.isFocusable = function() return true end
        btn.onFocus = function() end
        btn.onUnfocus = function() end
        btn.onTapSelect = function(self)
            if self.callback then
                self.callback()
                return true
            end
            return false
        end
        return btn
    end
}
package.loaded["ui/widget/imagewidget"] = {
    new = function(a, b)
        local iw = { type = "ImageWidget", args = b or a }
        iw.getSize = function() return { w = 100, h = 100 } end
        return iw
    end
}
package.loaded["ui/widget/overlapgroup"] = {
    new = function(a, b)
        local og = { type = "OverlapGroup", args = b or a }
        og.getSize = function() return { w = 100, h = 100 } end
        return og
    end
}
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0,
    COLOR_WHITE = 1,
    COLOR_GRAY = 2,
    COLOR_LIGHT_GRAY = 3,
    COLOR_DARK_GRAY = 4,
    COLOR_GRAY_B = 5,
    Color8 = function(g) return g end
}
package.loaded["ui/font"] = {
    getFace = function() return {} end
}
package.loaded["ui/rendertext"] = {}
package.loaded["ui/event"] = {
    new = function(a, b, c) 
        if type(a) == "string" then return { name = a, args = b } end
        return { name = b, args = c }
    end
}
package.loaded["ui/gesturerange"] = {
    new = function(a, b) return { type = "GestureRange", args = b or a } end
}
package.loaded["gettext"] = setmetatable({
    _ = function(s) return s end,
    C_ = function(ctx, s) return s end,
    N_ = function(s) return s end,
    T_ = function(s) return s end,
    pgettext = function(ctx, s) return s end,
    getLanguage = function() return "en" end,
    setLanguage = function() end,
}, {
    __call = function(t, s) return s end
})
package.loaded["ui/trapper"] = {
    dismissableRunInSubprocess = function(_, _, f) return true, f() end
}
package.loaded["socket.http"] = {}
package.loaded["ssl.https"] = {}
package.loaded["ltn12"] = {}
package.loaded["socket"] = {}
package.loaded["socketutil"] = {}
package.loaded["ffi/archiver"] = {}
package.loaded["ffi/sha2"] = {}
package.loaded["util"] = {
    splitToChars = function(text)
        local chars = {}
        for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(chars, c)
        end
        return chars
    end,
    makePath = function(path) return true end,
    purgeDir = function(path) return true end,
    realpath = function(p) return p end,
    joinPath = function(...)
        local parts = {...}
        return table.concat(parts, "/")
    end,
}
package.loaded["ffi/util"] = package.loaded["util"]
local json_lib = nil
local ok_json, real_json = pcall(require, "json")
if ok_json and type(real_json) == "table" and type(real_json.decode) == "function" then
    json_lib = real_json
else
    local ok_dk, real_dk = pcall(require, "dkjson")
    if ok_dk and type(real_dk) == "table" and type(real_dk.decode) == "function" then
        json_lib = real_dk
    end
end

if not json_lib then
    local function parse_json(str)
        if not str or str == "" then return nil end
        local pos = 1
        local len = #str

        local function skip_whitespace()
            while pos <= len do
                local b = str:byte(pos)
                if b == 32 or b == 9 or b == 10 or b == 13 then
                    pos = pos + 1
                else
                    break
                end
            end
        end

        local parse_val

        local function parse_str()
            pos = pos + 1
            local start = pos
            local chunks = {}
            while pos <= len do
                local c = str:sub(pos, pos)
                if c == '"' then
                    table.insert(chunks, str:sub(start, pos - 1))
                    pos = pos + 1
                    return table.concat(chunks)
                elseif c == '\\' then
                    table.insert(chunks, str:sub(start, pos - 1))
                    local next_c = str:sub(pos + 1, pos + 1)
                    if next_c == '"' or next_c == '\\' or next_c == '/' then
                        table.insert(chunks, next_c)
                        pos = pos + 2
                    elseif next_c == 'b' then table.insert(chunks, '\b'); pos = pos + 2
                    elseif next_c == 'f' then table.insert(chunks, '\f'); pos = pos + 2
                    elseif next_c == 'n' then table.insert(chunks, '\n'); pos = pos + 2
                    elseif next_c == 'r' then table.insert(chunks, '\r'); pos = pos + 2
                    elseif next_c == 't' then table.insert(chunks, '\t'); pos = pos + 2
                    elseif next_c == 'u' then
                        pos = pos + 6
                        table.insert(chunks, "?")
                    else
                        table.insert(chunks, next_c)
                        pos = pos + 2
                    end
                    start = pos
                else
                    pos = pos + 1
                end
            end
            return table.concat(chunks)
        end

        local function parse_array()
            pos = pos + 1
            local arr = {}
            skip_whitespace()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            while pos <= len do
                table.insert(arr, parse_val())
                skip_whitespace()
                local c = str:sub(pos, pos)
                if c == ',' then
                    pos = pos + 1
                    skip_whitespace()
                elseif c == ']' then
                    pos = pos + 1
                    return arr
                else
                    break
                end
            end
            return arr
        end

        local function parse_obj()
            pos = pos + 1
            local obj = {}
            skip_whitespace()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            while pos <= len do
                skip_whitespace()
                if str:sub(pos, pos) ~= '"' then break end
                local key = parse_str()
                skip_whitespace()
                if str:sub(pos, pos) == ':' then
                    pos = pos + 1
                end
                local val = parse_val()
                obj[key] = val
                skip_whitespace()
                local c = str:sub(pos, pos)
                if c == ',' then
                    pos = pos + 1
                elseif c == '}' then
                    pos = pos + 1
                    return obj
                else
                    break
                end
            end
            return obj
        end

        parse_val = function()
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '"' then
                return parse_str()
            elseif c == '{' then
                return parse_obj()
            elseif c == '[' then
                return parse_array()
            elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
                pos = pos + 4
                return true
            elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
                pos = pos + 5
                return false
            elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
                pos = pos + 4
                return nil
            else
                local num_str = str:match("^-?[%d%.eE+-]+", pos)
                if num_str then
                    pos = pos + #num_str
                    return tonumber(num_str)
                end
                pos = pos + 1
                return nil
            end
        end

        return parse_val()
    end

    json_lib = {
        encode = function(t) return "{}" end,
        decode = function(s) return parse_json(s) end
    }
end

package.loaded["json"] = json_lib
package.loaded["dkjson"] = json_lib
package.loaded["libs/libkoreader-dkjson"] = json_lib

function _G.createMockPlugin()
    local plugin = {
        ui = {
            document = {
                file = "test_book.epub",
                getToc = function() return {} end,
                getProps = function() return { title = "Test Title", authors = "Test Author" } end,
                compareXPointers = function(self_doc, xp1, xp2)
                    if xp1 == xp2 then return 0 end
                    local mock_positions = {
                        xp_five = 5,
                        xp_25 = 6,
                        xp_37 = 7,
                        xp_minus37 = 7,
                        xp_uni37 = 7,
                        xp_space37 = 7,
                        xp_80 = 8,
                        xp1 = 10,
                        xp2 = 20,
                    }
                    local pos1 = mock_positions[xp1] or 0
                    local pos2 = mock_positions[xp2] or 0
                    if pos1 < pos2 then return 1 end
                    if pos1 > pos2 then return -1 end
                    if xp1 < xp2 then return 1 end
                    return -1
                end
            },
            paging = {
                getCurrentPage = function() return 10 end
            },
            handleEvent = function() end,
            font = {
                font_face = "FreeSerif",
                configurable = {
                    font_size = 22,
                }
            }
        },
        loc = {
            t = function(s, ...)
                local fmt = s
                local args = {...}
                if type(s) == "table" then
                    fmt = args[1]
                    table.remove(args, 1)
                end
                if type(fmt) == "string" and #args > 0 then
                    if fmt:find("%%") then
                        local status, res = pcall(string.format, fmt, unpack(args))
                        if status then return res end
                    end
                    -- Fallback for testing: just append args
                    for i = 1, #args do
                        fmt = fmt .. " " .. tostring(args[i])
                    end
                end
                return fmt
            end,
            getLanguage = function() return "en" end,
            setLanguage = function() end
        },
        log = function(...) end,
    }
    return plugin
end
