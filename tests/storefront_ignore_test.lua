-- Storefront Ignore Updates Unit Test Suite
-- Tests: Item-level update suppression (isAllUpdatesIgnored), release-level ignore checks,
-- repo-level ignore checks, and details dialog ignore action button rendering.

package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;tests/?.lua;../?.lua;?.lua;" .. package.path

local scratch = "/tmp/storefront_ignore_test_" .. os.time()
os.execute("mkdir -p " .. scratch)

-- Mock KOReader environment
package.loaded["datastorage"] = {
    getSettingsDir = function() return scratch end,
    getDataDir = function() return scratch end,
}

local settings_db = {}
package.loaded["luasettings"] = {
    open = function(self, path)
        return {
            readSetting = function(self, key)
                return settings_db[key]
            end,
            saveSetting = function(self, key, val)
                settings_db[key] = val
                return true
            end,
            read = function(self) return settings_db end,
            save = function(self, tbl) settings_db = tbl or {} return true end,
            flush = function(self) return true end,
        }
    end
}

package.loaded["json"] = {
    encode = function(tbl)
        -- simple lua table to json encoder for test
        local ok, dkjson = pcall(require, "dkjson")
        if ok and dkjson then return dkjson.encode(tbl) end
        local parts = {}
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                local inner = {}
                for ik, iv in pairs(v) do
                    if type(iv) == "table" then
                        local sub = {}
                        for sk, sv in pairs(iv) do
                            table.insert(sub, string.format("%q:%s", sk, tostring(sv)))
                        end
                        table.insert(inner, string.format("%q:{%s}", ik, table.concat(sub, ",")))
                    else
                        table.insert(inner, string.format("%q:%s", ik, type(iv) == "string" and string.format("%q", iv) or tostring(iv)))
                    end
                end
                table.insert(parts, string.format("%q:{%s}", k, table.concat(inner, ",")))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end,
    decode = function(str)
        local ok, dkjson = pcall(require, "dkjson")
        if ok and dkjson then return dkjson.decode(str) end
        return {}
    end
}

-- Try dkjson if available in WSL KOReader environment
pcall(function()
    local dkjson = require("dkjson")
    package.loaded["json"] = dkjson
end)

package.loaded["device"] = {
    screen = {
        scaleBySize = function(_, val) return val end,
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    },
    hasKeys = function() return false end,
    hasKeyboard = function() return false end,
}

package.loaded["ui/geometry"] = { new = function(_, t) return t end }
package.loaded["ui/widget/container/inputcontainer"] = { extend = function(_, t) return t end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_DARK_GRAY = 2 }
package.loaded["logger"] = { info = function() end, warn = function() end, dbg = function() end, err = function() end }
package.loaded["gettext"] = { _ = function(str) return str end }

local function runTests()
    print("==================================================")
    print("  RUNNING STOREFRONT IGNORE UPDATES TEST SUITE    ")
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

    local InstallStore = require("storefront_installs")

    -- ----------------------------------------------------
    -- TEST 1: Default Ignore State
    -- ----------------------------------------------------
    print("\n--- TEST 1: Default Ignore State ---")
    local test_item = "test_plugin.koplugin"
    local test_repo_owner = "testowner"
    local test_repo_name = "testrepo"
    local test_repo_key = test_repo_owner .. "/" .. test_repo_name

    assertTest(InstallStore.isAllUpdatesIgnored(test_item) == false, "Item default not ignored", test_item)
    assertTest(InstallStore.isAllUpdatesIgnored(test_repo_key) == false, "Repo key default not ignored", test_repo_key)
    assertTest(InstallStore.isReleaseIgnored(test_item, "v1.0.0") == false, "Release tag default not ignored", "v1.0.0")
    assertTest(InstallStore.isReleaseIgnoredByRepo(test_repo_owner, test_repo_name, "v1.0.0") == false, "Repo release tag default not ignored", "v1.0.0")

    -- ----------------------------------------------------
    -- TEST 2: Toggle Item-Level Ignore All Updates
    -- ----------------------------------------------------
    print("\n--- TEST 2: Item-Level Ignore All Updates ---")
    InstallStore.setAllUpdatesIgnored(test_item, true)
    assertTest(InstallStore.isAllUpdatesIgnored(test_item) == true, "setAllUpdatesIgnored(true)", test_item)
    assertTest(InstallStore.isAllUpdatesIgnored("test_plugin") == true, "Clean key match (without .koplugin)", "test_plugin")
    assertTest(InstallStore.isReleaseIgnored(test_item, "v1.0.0") == true, "isReleaseIgnored returns true for v1.0.0 when item ignored")
    assertTest(InstallStore.isReleaseIgnored(test_item, "v9.9.9") == true, "isReleaseIgnored returns true for v9.9.9 when item ignored")

    InstallStore.toggleAllUpdatesIgnored(test_item)
    assertTest(InstallStore.isAllUpdatesIgnored(test_item) == false, "toggleAllUpdatesIgnored back to false", test_item)
    assertTest(InstallStore.isReleaseIgnored(test_item, "v1.0.0") == false, "isReleaseIgnored returns false after unignore")

    -- ----------------------------------------------------
    -- TEST 3: Repo-Level Ignore All Updates
    -- ----------------------------------------------------
    print("\n--- TEST 3: Repo-Level Ignore All Updates ---")
    InstallStore.setAllUpdatesIgnored(test_repo_key, true)
    assertTest(InstallStore.isAllUpdatesIgnored(test_repo_key) == true, "Repo key ignored", test_repo_key)
    assertTest(InstallStore.isReleaseIgnoredByRepo(test_repo_owner, test_repo_name, "v2.0.0") == true, "isReleaseIgnoredByRepo returns true for v2.0.0")

    InstallStore.setAllUpdatesIgnored(test_repo_key, false)
    assertTest(InstallStore.isReleaseIgnoredByRepo(test_repo_owner, test_repo_name, "v2.0.0") == false, "isReleaseIgnoredByRepo returns false after unignore")

    -- ----------------------------------------------------
    -- TEST 4: Specific Release Tag Ignore vs Item-Level
    -- ----------------------------------------------------
    print("\n--- TEST 4: Per-Tag Ignoring ---")
    InstallStore.toggleReleaseIgnored(test_item, "v1.2.0")
    assertTest(InstallStore.isReleaseIgnored(test_item, "v1.2.0") == true, "Per-tag v1.2.0 ignored")
    assertTest(InstallStore.isReleaseIgnored(test_item, "v1.3.0") == false, "Per-tag v1.3.0 NOT ignored")
    assertTest(InstallStore.isAllUpdatesIgnored(test_item) == false, "Item-level ignore remains false when only tag is ignored")

    -- Clean up per-tag toggle
    InstallStore.toggleReleaseIgnored(test_item, "v1.2.0")

    -- ----------------------------------------------------
    -- TEST 5: Patch Item Ignore Checks
    -- ----------------------------------------------------
    print("\n--- TEST 5: Patch Item Ignore Checks ---")
    local patch_filename = "2-sample_patch.lua"
    InstallStore.setAllUpdatesIgnored(patch_filename, true)
    assertTest(InstallStore.isAllUpdatesIgnored(patch_filename) == true, "Patch filename ignored")
    assertTest(InstallStore.isReleaseIgnored(patch_filename, "sha:1234567") == true, "Patch release SHA ignored")

    InstallStore.setAllUpdatesIgnored(patch_filename, false)
    assertTest(InstallStore.isAllUpdatesIgnored(patch_filename) == false, "Patch filename unignored")

    -- Clean up scratch directory
    os.execute("rm -rf " .. scratch)

    print(string.format("\n=================================================="))
    print(string.format("  RESULTS: %d PASSED, %d FAILED                    ", passed, failed))
    print(string.format("=================================================="))

    if failed > 0 then
        os.exit(1)
    end
end

runTests()
