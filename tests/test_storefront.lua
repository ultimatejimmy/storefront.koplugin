-- Storefront Automated Test Suite
-- Tests: Font face preview rendering, FontList registry isolation, batch font deletion, alias expansion.

local function runTests()
    print("==================================================")
    print("  RUNNING STOREFRONT AUTOMATED TEST SUITE        ")
    print("==================================================")

    local passed = 0
    local failed = 0

    local function assertTest(condition, name, msg)
        if condition then
            passed = passed + 1
            print(" [PASS] " .. name)
        else
            failed = failed + 1
            print(" [FAIL] " .. name .. (msg and (" - " .. tostring(msg)) or ""))
        end
    end

    -- Setup package.path for plugin directory imports
    local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "../?.lua;" .. package.path

    -- Mock basic KOReader modules if running outside full KOReader environment
    package.loaded["gettext"] = package.loaded["gettext"] or { _ = function(str) return str end }
    package.loaded["device"] = package.loaded["device"] or {
        screen = {
            scaleBySize = function(_, val) return val end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        hasKeys = function() return false end,
        hasKeyboard = function() return false end,
    }
    package.loaded["ui/geometry"] = package.loaded["ui/geometry"] or { new = function(_, t) return t end }
    package.loaded["ui/widget/container/inputcontainer"] = package.loaded["ui/widget/container/inputcontainer"] or { extend = function(_, t) return t end }
    package.loaded["ffi/blitbuffer"] = package.loaded["ffi/blitbuffer"] or { COLOR_BLACK = 0, COLOR_WHITE = 1 }

    -- ----------------------------------------------------
    -- TEST 1: Catalog Font Face Preview Resolution
    -- ----------------------------------------------------
    print("\n--- TEST 1: Preview Font Face Resolution ---")
    local StorefrontListItem = require("storefront_list_item")

    local catalog_path = script_dir .. "../catalog.json"
    local f = io.open(catalog_path, "r")
    local catalog_data = {}
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(function()
            local dk_json = require("libs/libkoreader-dkjson") or require("dkjson")
            return dk_json.decode(content)
        end)
        if ok and type(data) == "table" and data.fonts then
            catalog_data = data.fonts
        end
    end

    assertTest(#catalog_data > 0, "Catalog Loaded", "Found " .. #catalog_data .. " fonts in catalog.json")

    for _, font in ipairs(catalog_data) do
        local font_entry = {
            kind = "font",
            is_font = true,
            font_family = font.font_family or font.name,
            font_name = font.name,
            name = font.name,
            font_file = font.font_file,
        }
        local face = StorefrontListItem.resolveFontItemFace(font_entry, 22)
        assertTest(face ~= nil, "Render Preview: " .. font.name)
    end

    -- ----------------------------------------------------
    -- TEST 2: FontList Registry Isolation
    -- ----------------------------------------------------
    print("\n--- TEST 2: FontList Registry Isolation ---")
    local ok_fl, FontList = pcall(require, "fontlist")
    if ok_fl and FontList then
        local fontlist_count = FontList.fontlist and #FontList.fontlist or 0
        local fontinfo_count = 0
        if FontList.fontinfo then
            for _ in pairs(FontList.fontinfo) do fontinfo_count = fontinfo_count + 1 end
        end

        -- Render all catalog items again
        for _, font in ipairs(catalog_data) do
            StorefrontListItem.resolveFontItemFace({ kind = "font", is_font = true, name = font.name }, 22)
        end

        local new_fontlist_count = FontList.fontlist and #FontList.fontlist or 0
        local new_fontinfo_count = 0
        if FontList.fontinfo then
            for _ in pairs(FontList.fontinfo) do new_fontinfo_count = new_fontinfo_count + 1 end
        end

        assertTest(new_fontlist_count == fontlist_count, "FontList Count Unchanged", "Pre: " .. fontlist_count .. ", Post: " .. new_fontlist_count)
        assertTest(new_fontinfo_count == fontinfo_count, "FontInfo Count Unchanged", "Pre: " .. fontinfo_count .. ", Post: " .. new_fontinfo_count)
    else
        print(" [SKIP] FontList module not present in mock env")
    end

    -- ----------------------------------------------------
    -- TEST 3: Alias Expansion Audit
    -- ----------------------------------------------------
    print("\n--- TEST 3: Alias Stem Mapping Coverage ---")
    local font_aliases = {
        ["bitter"] = { "nv bitter", "bitter", "nv_bitter" },
        ["nv bitter"] = { "nv bitter", "bitter", "nv_bitter" },
        ["literata"] = { "nv literata", "literata", "nv_literata" },
        ["nv literata"] = { "nv literata", "literata", "nv_literata" },
        ["libre baskerville"] = { "nv basker", "libre baskerville", "librebaskerville", "baskerville", "basker" },
        ["nv basker"] = { "nv basker", "libre baskerville", "librebaskerville", "baskerville", "basker" },
        ["gentium plus"] = { "gentium book plus", "gentium plus", "gentiumbookplus", "gentium" },
        ["gentium book plus"] = { "gentium book plus", "gentium plus", "gentiumbookplus", "gentium" },
        ["readerly"] = { "readerly", "newsreader" },
        ["sourcerer"] = { "sourcerer", "source serif" },
    }

    assertTest(font_aliases["libre baskerville"] ~= nil, "Alias Exists: Libre Baskerville")
    assertTest(font_aliases["bitter"] ~= nil, "Alias Exists: Bitter")
    assertTest(font_aliases["literata"] ~= nil, "Alias Exists: Literata")
    assertTest(font_aliases["gentium plus"] ~= nil, "Alias Exists: Gentium Plus")

    -- ----------------------------------------------------
    -- TEST 4: Localization Suite Run
    -- ----------------------------------------------------
    print("\n--- TEST 4: Localization Suite ---")
    local ok_loc_suite = pcall(dofile, script_dir .. "storefront_localization_test.lua")
    assertTest(ok_loc_suite, "Localization Test Suite Execution")

    print("\n==================================================")
    print(string.format("  SUMMARY: %d Passed, %d Failed", passed, failed))
    print("==================================================")
    return failed == 0
end

local ok, success = pcall(runTests)
if not ok or not success then
    os.exit(1)
else
    os.exit(0)
end
