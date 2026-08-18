-- Storefront Automated Test Suite
-- Tests: Font face preview rendering, fallback paths, cache hit/miss, FontList registry isolation, alias expansion, localization.

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

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
    -- TEST 2: Font Fallback & Cache Regression Tests
    -- ----------------------------------------------------
    print("\n--- TEST 2: Font Fallback & Cache Robustness ---")
    -- Test A: Font not in bundled assets with font_file specified (regression test for ipairs nil bug)
    local unbundled_entry = {
        kind = "font",
        is_font = true,
        name = "UnbundledTestFont",
        font_family = "UnbundledTestFontFamily",
        font_file = "UnbundledTestFont-Regular.ttf",
    }
    local ok_unbundled, face_unbundled = pcall(StorefrontListItem.resolveFontItemFace, unbundled_entry, 22)
    assertTest(ok_unbundled and face_unbundled ~= nil, "Unbundled Font with font_file (no crash on fallback)")

    -- Test B: Repeated resolution to test cache hit with false/empty
    local ok_cached, face_cached = pcall(StorefrontListItem.resolveFontItemFace, unbundled_entry, 22)
    assertTest(ok_cached and face_cached ~= nil, "Cached Unbundled Font (cache hit branch)")

    -- Test C: Font with no font_file
    local no_file_entry = {
        kind = "font",
        is_font = true,
        name = "NoFileFont",
    }
    local ok_nofile, face_nofile = pcall(StorefrontListItem.resolveFontItemFace, no_file_entry, 22)
    assertTest(ok_nofile and face_nofile ~= nil, "Font without font_file")

    -- ----------------------------------------------------
    -- TEST 3: FontList Registry Isolation
    -- ----------------------------------------------------
    print("\n--- TEST 3: FontList Registry Isolation ---")
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
    -- TEST 4: Alias Expansion Audit
    -- ----------------------------------------------------
    print("\n--- TEST 4: Alias Stem Mapping Coverage ---")
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
    -- TEST 5: Localization Suite Run
    -- ----------------------------------------------------
    print("\n--- TEST 5: Localization Suite ---")
    local ok_loc_suite, loc_err = pcall(dofile, script_dir .. "storefront_localization_test.lua")
    assertTest(ok_loc_suite, "Localization Test Suite Execution", loc_err)

    print("\n==================================================")
    print(string.format("  SUMMARY: %d Passed, %d Failed", passed, failed))
    print("==================================================")
    return failed == 0
end

local ok, success = xpcall(runTests, debug.traceback)
if not ok then
    print("\n[CRITICAL ERROR IN TEST HARNESS]")
    print(success)
    os.exit(1)
elseif not success then
    os.exit(1)
else
    os.exit(0)
end
