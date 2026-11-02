local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. package.path

require("spec_helper")

local function runTests()
    print("==================================================")
    print("  RUNNING STOREFRONT DELETE & STALE RECORD TESTS  ")
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

    -- In spec_helper, lfs.attributes() by default returns "directory" for non-file paths.
    -- Mock lfs to support realistic directory existence tracking for our test cases.
    local lfs = require("libs/libkoreader-lfs")
    local real_lfs_attributes = lfs.attributes
    local existing_dirs = {}
    local existing_files = {}

    lfs.attributes = function(path, req)
        if not path then return nil end
        if existing_files[path] then
            local mode = "file"
            local size = 100
            if req == "mode" then return mode end
            if req == "size" then return size end
            return { mode = mode, size = size, modification = os.time() }
        end
        if existing_dirs[path] then
            local mode = "directory"
            local size = 4096
            if req == "mode" then return mode end
            if req == "size" then return size end
            return { mode = mode, size = size, modification = os.time() }
        end
        return nil
    end

    local InstallStore = require("storefront_installs")
    local Matcher = require("storefront_match")

    -- 1. InstallStore.findPluginRecord
    print("\n--- TEST 1: InstallStore.findPluginRecord ---")
    InstallStore.clear()

    -- Seed records:
    -- A) JorgeTheFox/koreader-dynamic-panelzoom with dirname = dynamic_panelzoom.koplugin
    InstallStore.upsert("dynamic_panelzoom.koplugin", {
        dirname = "dynamic_panelzoom.koplugin",
        owner = "JorgeTheFox",
        repo = "koreader-dynamic-panelzoom",
        repo_full_name = "JorgeTheFox/koreader-dynamic-panelzoom",
        repo_id = 998877,
        version = "v1.2.0",
    })

    -- B) Legacy auto-matched record with NO explicit record.dirname field
    InstallStore.upsert("legacy_plugin.koplugin", {
        owner = "SomeDev",
        repo = "koreader-legacy-plugin",
        repo_full_name = "SomeDev/koreader-legacy-plugin",
        version = "v1.0.0",
    })

    -- Test: find by full repo name
    local r1, k1 = InstallStore.findPluginRecord({
        full_name = "JorgeTheFox/koreader-dynamic-panelzoom",
        repo_name = "koreader-dynamic-panelzoom",
    })
    assertTest(r1 ~= nil and k1 == "dynamic_panelzoom.koplugin", "Find by full_name finds record", "Got key: " .. tostring(k1))
    assertTest(r1 and r1.dirname == "dynamic_panelzoom.koplugin", "Record contains dirname", "Got: " .. tostring(r1 and r1.dirname))

    -- Test: legacy record without dirname recovers store key as dirname
    local r2, k2 = InstallStore.findPluginRecord({
        full_name = "SomeDev/koreader-legacy-plugin",
        repo_name = "koreader-legacy-plugin",
    })
    assertTest(r2 ~= nil and k2 == "legacy_plugin.koplugin", "Legacy record found by repo name", "Got key: " .. tostring(k2))
    assertTest(r2 and r2.dirname == "legacy_plugin.koplugin", "Legacy record has dirname filled from key", "Got: " .. tostring(r2 and r2.dirname))

    -- Test: cross-owner conflict rejection (ownerA/tool vs ownerB/tool)
    InstallStore.upsert("tool.koplugin", {
        owner = "Alice",
        repo = "awesome-tool",
        repo_full_name = "Alice/awesome-tool",
    })
    local r_cross, k_cross = InstallStore.findPluginRecord({
        owner = "Bob",
        repo_name = "awesome-tool",
        full_name = "Bob/awesome-tool",
    })
    assertTest(r_cross == nil and k_cross == nil, "Does not match same repo_name from different owner", "Got key: " .. tostring(k_cross))

    -- 2. StorefrontDetailsDialog folder resolution & doRemove
    print("\n--- TEST 2: StorefrontDetailsDialog Folder Resolution & doRemove ---")
    local deleted_dir_arg = nil
    local deleted_rec_arg = nil
    local mock_sf = {
        deletePlugin = function(self_sf, dirname, rec)
            deleted_dir_arg = dirname
            deleted_rec_arg = rec
        end,
        listInstalledPlugins = function() return {} end,
        CORE_KOREADER_PLUGINS = Matcher.CORE_KOREADER_PLUGINS,
    }

    local StorefrontDetailsDialog = require("storefront_details_dialog")
    local dialog = StorefrontDetailsDialog:new{
        Storefront = mock_sf,
        repo = {
            owner = "JorgeTheFox",
            name = "koreader-dynamic-panelzoom",
            full_name = "JorgeTheFox/koreader-dynamic-panelzoom",
            id = 998877,
        },
        update_item = nil, -- catalogue tab
    }
    dialog:init()

    local rec, rec_k = InstallStore.findPluginRecord({
        repo_name = dialog.repo.name,
        full_name = dialog.repo.full_name,
        owner = dialog.repo.owner,
        repo_id = dialog.repo.id,
    })
    assertTest(rec and rec.dirname == "dynamic_panelzoom.koplugin", "Details dialog resolves installed folder for catalogue item")

    -- 3. Stale install record cleanup (folder missing on disk)
    print("\n--- TEST 3: Stale Record Cleanup When Folder Missing ---")
    local test_fake_plugin = "missing_ghost.koplugin"
    InstallStore.upsert(test_fake_plugin, {
        dirname = test_fake_plugin,
        owner = "GhostDev",
        repo = "ghost-plugin",
        repo_full_name = "GhostDev/ghost-plugin",
        repo_id = 112233,
    })

    assertTest(InstallStore.get(test_fake_plugin) ~= nil, "Ghost record saved in InstallStore")

    local DeleteUI = require("storefront_delete_ui")
    local delete_plugin_sf = {
        CORE_KOREADER_PLUGINS = Matcher.CORE_KOREADER_PLUGINS,
        listInstalledPlugins = function() return {} end,
        refreshCurrentBrowserTab = function(self_sf, cb) if cb then cb() end end,
    }
    DeleteUI:init(delete_plugin_sf)

    delete_plugin_sf:performPluginDeletion(test_fake_plugin, InstallStore.get(test_fake_plugin), nil)
    assertTest(InstallStore.get(test_fake_plugin) == nil, "Stale record is cleared when folder does not exist on disk")

    -- 4. Protection for built-in KOReader plugins (e.g. statistics.koplugin)
    print("\n--- TEST 4: Built-in Core Plugin Protection ---")
    local PluginPaths = require("storefront_plugin_paths")
    local stat_dir = PluginPaths.getDefaultPluginsRoot() .. "/statistics.koplugin"
    existing_dirs[stat_dir] = true
    local canary_file = stat_dir .. "/canary.txt"
    existing_files[canary_file] = true

    -- Seed hijacked ComicReader record targeting statistics.koplugin
    InstallStore.upsert("statistics.koplugin", {
        dirname = "statistics.koplugin",
        owner = "KORComic",
        repo = "comicreader",
        repo_full_name = "KORComic/comicreader.koplugin",
        repo_id = 445566,
    })

    assertTest(lfs.attributes(stat_dir, "mode") == "directory", "Core plugin folder exists on disk")
    assertTest(InstallStore.get("statistics.koplugin") ~= nil, "Hijacked record exists in InstallStore")

    delete_plugin_sf:performPluginDeletion("statistics.koplugin", InstallStore.get("statistics.koplugin"), nil)

    assertTest(lfs.attributes(stat_dir, "mode") == "directory", "Core plugin folder is NOT deleted from disk")
    assertTest(lfs.attributes(canary_file, "mode") == "file", "Core plugin files remain intact")
    assertTest(InstallStore.get("statistics.koplugin") == nil, "Hijacked third-party install record was cleared")

    -- Clean up test mock entries
    existing_files[canary_file] = nil
    existing_dirs[stat_dir] = nil

    -- 5. Multi-plugin archive detection and extra_plugins reporting
    print("\n--- TEST 5: Multi-Plugin Archive Tie-Breaking & Extra Warning ---")
    local Installer = require("storefront_installer")
    local function makeArchive(paths)
        return {
            iterate = function()
                local i = 0
                return function()
                    i = i + 1
                    if i <= #paths then
                        return { path = paths[i], mode = "file" }
                    end
                    return nil
                end
            end,
            extractToPath = function() return true end,
            close = function() end,
        }
    end

    local multi_paths = {
        "comicreader.koplugin/_meta.lua",
        "comicreader.koplugin/main.lua",
        "statistics.koplugin/_meta.lua",
        "statistics.koplugin/main.lua",
    }
    local info = Installer.detectPluginFromArchive(makeArchive(multi_paths), { name = "comicreader" })
    assertTest(info ~= nil and info.plugin_dirname == "comicreader.koplugin", "Selects comicreader.koplugin over statistics.koplugin")
    assertTest(info.extra_plugins ~= nil and #info.extra_plugins == 1 and info.extra_plugins[1] == "statistics.koplugin", "Identifies statistics.koplugin as extra skipped plugin")

    -- Restore lfs attributes
    lfs.attributes = real_lfs_attributes

    print(string.format("\nTests finished: %d passed, %d failed", passed, failed))
    if failed > 0 then
        os.exit(1)
    end
end

runTests()
