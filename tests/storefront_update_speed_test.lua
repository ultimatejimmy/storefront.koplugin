-- tests/storefront_update_speed_test.lua
-- Unit tests for Update Speedup (#5084):
-- - Rate limit detection and configurable timeouts in storefront_net_github
-- - Blocking progress toast with explicit Cancel button (only Cancel button dismisses)
-- - Smart candidate ordering (root _meta.lua and <dirname>/_meta.lua prioritized)
-- - Default-branch fallback install tracking (branch & head SHA preserved)
-- - Unified plugin + patch update checks in checkAllUpdates()

require("tests/spec_helper")

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS\t" .. label)
    else
        failures = failures + 1
        print("FAIL\t" .. label)
    end
    io.stdout:flush()
end

print("=== Running Storefront Update Speedup Test Suite (#5084) ===")

local GitHub = require("storefront_net_github")
local Toast = require("storefront_toast")
local Geom = require("ui/geometry")
local InstallStore = require("storefront_installs")
local Cache = require("storefront_cache")
local Storefront = require("main")

-- 1. GitHub Rate-Limit Detection
do
    check("isRateLimitError returns false for nil", GitHub.isRateLimitError(nil) == false)
    check("isRateLimitError returns false for 404", GitHub.isRateLimitError({ code = 404 }) == false)
    check("isRateLimitError returns false for 200", GitHub.isRateLimitError({ code = 200 }) == false)
    check("isRateLimitError returns false for generic 403", GitHub.isRateLimitError({ code = 403, body = "Forbidden" }) == false)
    
    check("isRateLimitError detects HTTP 429", GitHub.isRateLimitError({ code = 429 }) == true)
    check("isRateLimitError detects is_rate_limit flag", GitHub.isRateLimitError({ code = 403, is_rate_limit = true }) == true)
    check("isRateLimitError detects secondary rate limit in body", GitHub.isRateLimitError({ code = 403, body = "You have exceeded a secondary rate limit" }) == true)
    check("isRateLimitError detects rate limit in body", GitHub.isRateLimitError({ code = 403, body = "API rate limit exceeded for user" }) == true)
end

-- 2. Configurable Request Timeouts
do
    check("setRequestTimeouts callable", pcall(function() GitHub.setRequestTimeouts(5, 10) end))
    check("resetRequestTimeouts callable", pcall(function() GitHub.resetRequestTimeouts() end))
end

-- 3. Toast Cancel Button & Dismiss Behavior
do
    local cancelled = false
    local toast = Toast.show("Checking updates…", 0, {
        show_cancel = true,
        cancel_text = "Cancel",
        cancel_callback = function()
            cancelled = true
        end,
    })

    check("Toast has cancel_btn when show_cancel = true", toast.cancel_btn ~= nil)
    check("Toast cancel_btn has dimen", toast.cancel_btn and toast.cancel_btn.dimen ~= nil)

    -- Tap outside cancel button (at 0,0)
    local outside_pos = Geom:new{ x = 0, y = 0, w = 1, h = 1 }
    local res_outside = toast:onToastTap(nil, { pos = outside_pos })
    check("Outside tap is swallowed (returns true)", res_outside == true)
    check("Outside tap did NOT trigger cancel callback", cancelled == false)

    -- Tap inside cancel button
    local btn_dimen = toast.cancel_btn.dimen
    local inside_pos = Geom:new{
        x = btn_dimen.x + 2,
        y = btn_dimen.y + 2,
        w = 1,
        h = 1,
    }
    local res_inside = toast:onToastTap(nil, { pos = inside_pos })
    check("Inside tap returns true", res_inside == true)
    check("Inside tap triggered cancel callback", cancelled == true)

    -- Test CancelKey
    local key_cancelled = false
    local key_dismissed = false
    local key_toast = Toast.show("Checking again…", 0, {
        show_cancel = true,
        cancel_callback = function()
            key_cancelled = true
        end,
    })
    key_toast.dismiss_callback = function()
        key_dismissed = true
    end
    key_toast:onCancelKey()
    check("onCancelKey triggers cancel_callback", key_cancelled == true)
    check("onCancelKey triggers dismiss_callback", key_dismissed == true)

    -- Test dismiss_callback called on inside tap
    local tap_dismissed = false
    local tap_toast = Toast.show("Checking third…", 0, {
        show_cancel = true,
    })
    tap_toast.dismiss_callback = function()
        tap_dismissed = true
    end
    local btn_dimen2 = tap_toast.cancel_btn.dimen
    local inside_pos2 = Geom:new{
        x = btn_dimen2.x + 2,
        y = btn_dimen2.y + 2,
        w = 1,
        h = 1,
    }
    tap_toast:onToastTap(nil, { pos = inside_pos2 })
    check("onToastTap on cancel_btn triggers dismiss_callback", tap_dismissed == true)

    -- Test default cancel_btn text is localized
    local default_cancel_toast = Toast.show("Default text toast", 0, { show_cancel = true })
    check("Default cancel_text is not nil", default_cancel_toast.cancel_text ~= nil)
    check("Default cancel_btn text is 'Cancel'", default_cancel_toast.cancel_btn.text == "Cancel")
end

-- 4. Unified checkAllUpdates (checking both plugins & patches in single subprocess)
do
    local sf = Storefront
    local scanned_plugins = nil
    local scanned_patches = nil

    -- Mock _scanUpdatesForDirectApi
    local orig_scan = sf._scanUpdatesForDirectApi
    sf._scanUpdatesForDirectApi = function(self_sf, plugins, patches)
        scanned_plugins = plugins
        scanned_patches = patches
    end

    -- Setup mock installed plugins & records
    InstallStore.upsert("testplug.koplugin", {
        dirname = "testplug.koplugin",
        owner = "testowner",
        repo = "testplug",
        version = "1.0.0",
    })

    sf.listInstalledPlugins = function()
        return { { dirname = "testplug.koplugin" } }
    end

    -- Setup mock patch mgr & records
    local PatchMgr = require("storefront_patch_mgr")
    PatchMgr.isUserPatchEnabled = function() return true end
    sf.listInstalledPatches = function()
        return { { filename = "1-test.patch" } }
    end
    sf.getPatchRecordsMap = function()
        return {
            ["1-test.patch"] = {
                filename = "1-test.patch",
                owner = "testowner",
                repo = "testpatches",
                path = "1-test.patch",
            }
        }
    end

    sf:checkAllUpdates()

    check("checkAllUpdates scanned plugins", scanned_plugins ~= nil and #scanned_plugins == 1)
    check("checkAllUpdates scanned patches", scanned_patches ~= nil and #scanned_patches == 1)
    check("scanned patch has filename", scanned_patches and scanned_patches[1].filename == "1-test.patch")

    -- Restore
    sf._scanUpdatesForDirectApi = orig_scan
end

-- 5. Default Branch Fallback Install Tracking
do
    local sf = Storefront

    local info = {
        plugin_dirname = "releaseless.koplugin",
        plugin_name = "Releaseless Plugin",
        plugin_version = "HEAD",
        source = "branch",
        branch = "main",
        sha = "deadbeef1234567890abcdef",
    }
    local repo = {
        name = "releaseless",
        owner = "someowner",
    }

    sf:rememberInstall(info, repo)
    local saved = InstallStore.get("releaseless.koplugin")
    check("InstallStore recorded source = branch", saved and saved.source == "branch")
    check("InstallStore recorded branch = main", saved and saved.branch == "main")
    check("InstallStore recorded sha", saved and saved.sha == "deadbeef1234567890abcdef")
end

-- 6. Immediate Catalog Update Pre-population
do
    local sf = Storefront
    Cache.init()
    sf.updates_state = { remote_info = {}, last_checked = 0 }

    -- Insert mock repo in Cache with a newer latest_release
    Cache.storeRepos("plugin", {
        {
            name = "myplugin",
            owner = "pluginowner",
            id = 9999,
            latest_release = {
                tag_name = "v2.0.0",
                published_at = "2026-10-01T00:00:00Z",
            },
        }
    })

    InstallStore.upsert("myplugin.koplugin", {
        dirname = "myplugin.koplugin",
        owner = "pluginowner",
        repo = "myplugin",
        version = "1.0.0",
        repo_id = 9999,
    })

    sf.listInstalledPlugins = function()
        return { { dirname = "myplugin.koplugin" } }
    end

    sf:populateRemoteInfoFromCatalog()
    local remote = sf.updates_state.remote_info["myplugin.koplugin"]
    check("populateRemoteInfoFromCatalog sets remote_version", remote and remote.remote_version == "2.0.0")
    check("populateRemoteInfoFromCatalog sets release_tag_name", remote and remote.release_tag_name == "v2.0.0")
    check("populateRemoteInfoFromCatalog marks is_cached_fallback", remote and remote.is_cached_fallback == true)
end

print(string.format("=== Storefront Update Speedup Test Suite Complete: %d Failures ===", failures))
if failures > 0 then
    os.exit(1)
end
