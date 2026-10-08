-- tests/storefront_dual_source_test.lua
-- Tests dual-source screensaver integration: Storefront + ReaderBackdrop

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

local StorefrontScreensavers = require("storefront_screensavers_ui")

local function run()
    print("==================================================")
    print("  RUNNING STOREFRONT DUAL SOURCE TEST SUITE       ")
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

    -- Test 1: Normalize Storefront native item
    local sf_item = {
        id = "foggy-forest-pines",
        title = "Foggy Mountain Pines",
        author = "Unsplash (CC0)",
        category = "Nature",
        tags = { "fog", "forest", "mountain" },
        ext = "jpg",
    }
    StorefrontScreensavers.normalizeItem(sf_item)
    assertTest(sf_item.source == "Storefront", "Storefront item source defaulted to 'Storefront'")
    assertTest(sf_item.fullUrl:find("foggy%-forest%-pines%.jpg") ~= nil, "Storefront fullUrl generated correctly")
    assertTest(sf_item.thumbnailUrl:find("thumbnails/foggy%-forest%-pines%.jpg") ~= nil, "Storefront thumbnailUrl generated correctly")

    -- Test 2: Normalize ReaderBackdrop remote item
    local rb_item = {
        id = "rb-a9e46fd39d40fa3",
        title = "The Great Wave Off Kanagawa",
        author = "Alephvzla (ReaderBackdrop)",
        category = "Nature",
        tags = { "wave", "ocean" },
        fullUrl = "https://67n00ixa74.ufs.sh/f/0592cf39-1i9bny.png",
        downloads = 4077,
        ext = "png",
    }
    StorefrontScreensavers.normalizeItem(rb_item)
    assertTest(rb_item.source == "ReaderBackdrop", "ReaderBackdrop item detected from rb- prefix")
    assertTest(rb_item.fullUrl == "https://67n00ixa74.ufs.sh/f/0592cf39-1i9bny.png", "ReaderBackdrop fullUrl preserved")
    assertTest(rb_item.thumbnailUrl:find("thumbnails/rb/rb%-a9e46fd39d40fa3%.jpg") ~= nil, "ReaderBackdrop thumbnailUrl routed to lightweight CDN thumbnail")
    assertTest(rb_item.pluginThumbnailUrl:find("thumbnails/rb/rb%-a9e46fd39d40fa3%.jpg") ~= nil, "ReaderBackdrop pluginThumbnailUrl routed to lightweight CDN thumbnail")

    -- Test 2b: Preserve explicit remote thumbnail when distinct from fullUrl
    local rb_custom = {
        id = "rb-custom-1",
        fullUrl = "https://example.com/large.png",
        thumbnailUrl = "https://example.com/small_thumb.jpg",
    }
    StorefrontScreensavers.normalizeItem(rb_custom)
    assertTest(rb_custom.thumbnailUrl == "https://example.com/small_thumb.jpg", "ReaderBackdrop explicit thumbnail preserved when distinct from fullUrl")
    assertTest(rb_custom.pluginThumbnailUrl == "https://example.com/small_thumb.jpg", "ReaderBackdrop pluginThumbnailUrl inherited explicit remote thumbnail")

    -- Test 3: Source filtering simulation
    local catalog = { sf_item, rb_item }

    local function filterBySource(items, active_sources)
        local res = {}
        for _, item in ipairs(items) do
            local s = (item.source or "Storefront"):lower()
            local is_rb = s:find("reader") ~= nil
            if is_rb then
                if active_sources.readerbackdrop ~= false then table.insert(res, item) end
            else
                if active_sources.storefront ~= false then table.insert(res, item) end
            end
        end
        return res
    end

    local both = filterBySource(catalog, { storefront = true, readerbackdrop = true })
    assertTest(#both == 2, "Both sources enabled returns all items (count: 2)")

    local sf_only = filterBySource(catalog, { storefront = true, readerbackdrop = false })
    assertTest(#sf_only == 1 and sf_only[1].source == "Storefront", "Storefront-only filter returns 1 Storefront item")

    local rb_only = filterBySource(catalog, { storefront = false, readerbackdrop = true })
    assertTest(#rb_only == 1 and rb_only[1].source == "ReaderBackdrop", "ReaderBackdrop-only filter returns 1 ReaderBackdrop item")

    print(string.format("\nDual Source Tests Complete: %d Passed, %d Failed\n", passed, failed))
    if failed > 0 then os.exit(1) end
end

run()
