-- appstore_plugin_paths_test.lua
-- Run with: cd <extracted-koreader-dir> && ./luajit plugins/appstore.koplugin/appstore_plugin_paths_test.lua
package.path = "plugins/appstore.koplugin/?.lua;" .. package.path

local scratch = "/tmp/appstore_plugin_paths_test"
os.execute("rm -rf " .. scratch .. " && mkdir -p " .. scratch .. "/custom_a " .. scratch .. "/custom_b")

local failures = 0
local function check(label, got, expected)
    local ok
    if type(expected) == "table" then
        ok = type(got) == "table" and #got == #expected
        if ok then
            for i = 1, #expected do
                if got[i] ~= expected[i] then ok = false end
            end
        end
    else
        ok = got == expected
    end
    if ok then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

local function freshModule()
    package.loaded["appstore_plugin_paths"] = nil
    return require("appstore_plugin_paths")
end

-- Scenario 1: no extra_plugin_paths configured at all.
G_reader_settings = { readSetting = function() return nil end }
local M = freshModule()
check("no extra paths -> lookup is just 'plugins'", M.getLookupPaths(), { "plugins" })
check("no extra paths -> no custom paths", #M.getCustomLookupPaths(), 0)
local dest, prompt = M.resolveInstallDestination(nil, nil)
check("no custom paths -> falls back to default root", dest, M.getDefaultPluginsRoot())
check("no custom paths -> no prompt needed", prompt, false)

-- Scenario 2: a single custom extra_plugin_paths entry (the reporter's setup).
G_reader_settings = { readSetting = function() return scratch .. "/custom_a" end }
M = freshModule()
check("single custom path (string) -> included in lookup", M.getLookupPaths(), { "plugins", scratch .. "/custom_a" })
check("single custom path -> exactly one custom path", #M.getCustomLookupPaths(), 1)
dest, prompt = M.resolveInstallDestination(nil, nil)
check("single custom path -> installs there with no prompt", dest, scratch .. "/custom_a")
check("single custom path -> no prompt needed", prompt, false)

-- Scenario 3: a nonexistent directory in extra_plugin_paths is skipped.
G_reader_settings = { readSetting = function() return scratch .. "/does_not_exist" end }
M = freshModule()
check("nonexistent extra path is skipped", M.getLookupPaths(), { "plugins" })

-- Scenario 4: two custom paths -> ambiguous, caller must prompt.
G_reader_settings = { readSetting = function() return { scratch .. "/custom_a", scratch .. "/custom_b" } end }
M = freshModule()
check("two custom paths -> two entries in custom list", #M.getCustomLookupPaths(), 2)
dest, prompt = M.resolveInstallDestination(nil, nil)
check("two custom paths, no override -> ambiguous", prompt, true)
check("two custom paths, no override -> no destination yet", dest, nil)

-- Scenario 5: config override picks a path directly, even when ambiguous.
dest, prompt = M.resolveInstallDestination(scratch .. "/custom_b", nil)
check("config override resolves ambiguity", dest, scratch .. "/custom_b")
check("config override -> no prompt", prompt, false)

-- Scenario 6: an override that isn't a real lookup path is ignored.
dest, prompt = M.resolveInstallDestination("/not/a/configured/path", nil)
check("invalid config override falls through to prompt", prompt, true)

-- Scenario 7: a remembered choice from a previous prompt short-circuits future ones.
dest, prompt = M.resolveInstallDestination(nil, scratch .. "/custom_a")
check("remembered choice resolves ambiguity", dest, scratch .. "/custom_a")
check("remembered choice -> no prompt", prompt, false)

-- Scenario 8: a stale remembered choice (no longer configured) is discarded.
G_reader_settings = { readSetting = function() return scratch .. "/custom_a" end }
M = freshModule()
dest, prompt = M.resolveInstallDestination(nil, scratch .. "/custom_b")
check("stale remembered choice falls back to single custom path", dest, scratch .. "/custom_a")
check("stale remembered choice -> no prompt (single custom path remains)", prompt, false)

os.execute("rm -rf " .. scratch)

if failures == 0 then
    print("ALL TESTS PASSED")
    os.exit(0)
else
    print(string.format("%d TEST(S) FAILED", failures))
    os.exit(1)
end
