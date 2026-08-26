-- storefront_font_test.lua
-- Unit tests for Storefront Font Installation, Sync Queue & InstallStore logic
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label)
    end
    io.stdout:flush()
end

-- Mock dependencies for headless testing
package.loaded["socket.http"] = {}
package.loaded["ssl.https"] = {}
package.loaded["socket"] = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    mkdir = function() return true end,
    dir = function() return function() return nil end end,
}
package.loaded["socketutil"] = {
    set_timeout = function() end,
    reset_timeout = function() end,
}
package.loaded["ltn12"] = {
    sink = { table = function() return function() end end }
}

local ok_json, real_json = pcall(require, "json")
if not ok_json or not real_json or type(real_json.decode) ~= "function" then
    -- Simple JSON mock for unit testing InstallStore serialization
    local json_mock = {}
    function json_mock.encode(tbl)
        if type(tbl) ~= "table" then return "{}" end
        local items = {}
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                table.insert(items, string.format("%q:%s", k, json_mock.encode(v)))
            elseif type(v) == "boolean" then
                table.insert(items, string.format("%q:%s", k, tostring(v)))
            elseif type(v) == "number" then
                table.insert(items, string.format("%q:%d", k, v))
            else
                table.insert(items, string.format("%q:%q", k, tostring(v)))
            end
        end
        return "{" .. table.concat(items, ",") .. "}"
    end

    function json_mock.decode(str)
        if not str or str == "" or str == "{}" then return {} end
        -- Basic mock deserialization for test records
        local res = { plugins = {}, patches = {}, fonts = {}, item_options = {} }
        if str:find("lora") then
            local is_pending = str:find('"pending_download":true') ~= nil
            local is_full = str:find('"full_installed":true') ~= nil
            res.fonts["lora"] = {
                font_name = "Lora",
                owner = "cyrealtype",
                pending_download = is_pending,
                full_installed = is_full,
                download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip"
            }
        end
        return res
    end
    package.loaded["json"] = json_mock
end

package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, Color8 = function(g) return g end }
package.loaded["ffi/util"] = { realpath = function(p) return p end, purgeDir = function() end }
package.loaded["ffi/utf8proc"] = {}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/geometry"] = { new = function(a, b) return b or a end }
package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
package.loaded["ui/widget/infomessage"] = { new = function(a, b) return b or a end }
package.loaded["device"] = { isAndroid = function() return false end, isKindle = function() return false end, isDesktop = function() return true end, home_dir = "/tmp" }

local memory_store = {}
package.loaded["luasettings"] = {
    open = function()
        return {
            readSetting = function(self, k) return memory_store[k] end,
            saveSetting = function(self, k, v) memory_store[k] = v end,
            delSetting = function(self, k) memory_store[k] = nil end,
            flush = function() end,
        }
    end
}
package.loaded["gettext"] = setmetatable({
    _ = function(s) return s end,
    getLanguage = function() return "en" end,
}, {
    __call = function(_, s) return s end,
})

print("=== Running Font System Unit Tests ===")

local InstallStore = require("storefront_installs")

-- Test 1: Font Upsert with pending_download & download_url
local ok_upsert = InstallStore.upsertFont("lora", {
    font_name = "Lora",
    owner = "cyrealtype",
    pending_download = true,
    download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip",
    full_installed = false,
})
check("InstallStore.upsertFont succeeds", ok_upsert == true)

local font_list = InstallStore.listFonts()
check("InstallStore.listFonts contains Lora", font_list and font_list["lora"] ~= nil)
check("Lora pending_download flag is true", font_list and font_list["lora"] and font_list["lora"].pending_download == true)
check("Lora download_url stored correctly", font_list and font_list["lora"] and font_list["lora"].download_url and font_list["lora"].download_url:find("Lora.zip", 1, true) ~= nil)

-- Test 2: Font Upsert update to full_installed
InstallStore.upsertFont("lora", {
    font_name = "Lora",
    owner = "cyrealtype",
    pending_download = false,
    download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip",
    full_installed = true,
})
local font_list2 = InstallStore.listFonts()
check("Lora pending_download updated to false", font_list2 and font_list2["lora"] and font_list2["lora"].pending_download == false)
check("Lora full_installed updated to true", font_list2 and font_list2["lora"] and font_list2["lora"].full_installed == true)

-- Test 3: Font Removal
InstallStore.removeFont("lora")
local font_list3 = InstallStore.listFonts()
check("Lora font removed successfully", font_list3 and font_list3["lora"] == nil)

-- Test 4: User Font Dirs & Multi-Directory Resolution
local ok_fm, FontMgr = pcall(require, "storefront_font_mgr")
check("storefront_font_mgr requires cleanly (" .. tostring(FontMgr) .. ")", ok_fm and FontMgr ~= nil)
if ok_fm and FontMgr then
    local user_dirs = FontMgr.getUserFontDirs and FontMgr.getUserFontDirs()
    check("getUserFontDirs returns table with at least 1 path", type(user_dirs) == "table" and #user_dirs >= 1)
    local has_primary = false
    local has_kindle = false
    for _, d in ipairs(user_dirs or {}) do
        if d:find("fonts") then
            has_primary = true
        end
        if d == "/mnt/us/fonts" or d == "/mnt/base-us/fonts" then
            has_kindle = true
        end
    end
    check("getUserFontDirs includes primary font directory path", has_primary == true)
    check("getUserFontDirs includes Kindle /mnt/us/fonts directory", has_kindle == true)
end

-- Test 5: Font Installed Map & Stem / Alias Matching
if ok_fm and FontMgr then
    local mock_installed_map = {
        ["nvbitter"] = true,
        ["bitter"] = true,
        ["gentiumbookplus"] = true,
        ["literataregular"] = true,
    }

    check("isFontInstalled matches direct name 'Bitter'", FontMgr.isFontInstalled("Bitter", mock_installed_map) == true)
    check("isFontInstalled matches alias 'NV Bitter' <-> 'bitter'", FontMgr.isFontInstalled("NV Bitter", mock_installed_map) == true)
    check("isFontInstalled matches 'Gentium Plus' <-> 'gentiumbookplus'", FontMgr.isFontInstalled("Gentium Plus", mock_installed_map) == true)
    check("isFontInstalled matches table repo with font_family", FontMgr.isFontInstalled({ name = "Literata", font_family = "Literata" }, mock_installed_map) == true)
    check("isFontInstalled returns false for uninstalled 'OpenDyslexic'", FontMgr.isFontInstalled("OpenDyslexic", mock_installed_map) == false)
end

-- Test 6: Rejection of Phantom InstallStore Records without Files
if ok_fm and FontMgr then
    -- Add a phantom font into InstallStore
    InstallStore.upsertFont("phantomfont", {
        font_name = "PhantomFont",
        owner = "nobody",
        download_url = "https://example.com/phantom.zip",
        full_installed = false,
    })
    local empty_map = {}
    check("isFontInstalled rejects phantom font when not in installed map", FontMgr.isFontInstalled("PhantomFont", empty_map) == false)
    InstallStore.removeFont("phantomfont")
end

-- Test 7: FontList Integration
if ok_fm and FontMgr then
    package.loaded["fontlist"] = {
        fontnames = { ["Charis SIL"] = true, ["Libre Baskerville"] = true },
        fontinfo = { ["/mnt/us/fonts/Charis.ttf"] = { family = "Charis SIL" } },
    }
    local dynamic_map = FontMgr.getInstalledFontsMap()
    check("getInstalledFontsMap incorporates KOReader FontList fontnames", dynamic_map["charissil"] == true or dynamic_map["Charis SIL"] == true)
    check("isFontInstalled detects font from FontList", FontMgr.isFontInstalled("Charis SIL", dynamic_map) == true)
    check("isFontInstalled resolves NV Basker alias to Libre Baskerville in FontList", FontMgr.isFontInstalled("NV Basker", dynamic_map) == true)
end

-- Test 8: Storefront Mixin Method Invocation
if ok_fm and FontMgr then
    local mock_sf = { name = "storefront" }
    FontMgr:init(mock_sf)
    local mock_installed_map = {
        ["nvbitter"] = true,
        ["bitter"] = true,
        ["gentiumbookplus"] = true,
    }
    check("Storefront:isFontInstalled method works with colon invocation for 'Bitter'", mock_sf:isFontInstalled({ name = "Bitter", font_family = "Bitter" }, mock_installed_map) == true)
    check("Storefront:isFontInstalled method works with string 'Gentium Plus'", mock_sf:isFontInstalled("Gentium Plus", mock_installed_map) == true)
    check("Storefront:isFontInstalled method returns false for uninstalled 'OpenDyslexic'", mock_sf:isFontInstalled("OpenDyslexic", mock_installed_map) == false)
end

print("=== Font System Unit Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
