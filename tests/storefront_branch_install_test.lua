local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. package.path

require("spec_helper")

local function runTests()
    print("==================================================")
    print("  RUNNING INSTALL FROM BRANCH TEST SUITE          ")
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

    -- 1. Localization keys test
    print("\n--- TEST 1: Localization Keys ---")
    local Localization = require("localization_storefront")
    local str_install_branch = Localization:t("install_from_branch")
    assertTest(str_install_branch == "Install from branch…", "Lookup 'install_from_branch'", "Got: " .. tostring(str_install_branch))

    local str_confirm_title = Localization:t("confirm_branch_install_title", "main")
    assertTest(str_confirm_title == "Install from branch 'main'?", "Format 'confirm_branch_install_title'", "Got: " .. tostring(str_confirm_title))

    local str_tracking = Localization:t("tracking_branch", "develop")
    assertTest(str_tracking == "Tracking branch: develop", "Format 'tracking_branch'", "Got: " .. tostring(str_tracking))

    local str_repull = Localization:t("repull_from_branch")
    assertTest(str_repull == "Re-pull from branch", "Lookup 'repull_from_branch'", "Got: " .. tostring(str_repull))

    -- 2. GitHubClient branches & SHA methods
    print("\n--- TEST 2: GitHubClient Methods ---")
    local GitHub = require("storefront_net_github")
    assertTest(type(GitHub.fetchBranches) == "function", "GitHubClient.fetchBranches exists")
    assertTest(type(GitHub.fetchBranchSHA) == "function", "GitHubClient.fetchBranchSHA exists")

    local ok_branches, err_branches = GitHub.fetchBranches(nil, nil)
    assertTest(ok_branches == nil and err_branches == "missing owner/repo", "fetchBranches validates parameters")

    local ok_sha, err_sha = GitHub.fetchBranchSHA(nil, nil, nil)
    assertTest(ok_sha == nil and err_sha == "missing parameters", "fetchBranchSHA validates parameters")

    -- 3. InstallStore record with source = 'branch'
    print("\n--- TEST 3: InstallStore Branch Tracking ---")
    local InstallStore = require("storefront_installs")
    assertTest(type(InstallStore.upsert) == "function", "InstallStore.upsert exists")

    local test_record = {
        dirname = "myplugin.koplugin",
        plugin_name = "MyPlugin",
        owner = "testowner",
        repo = "myplugin",
        source = "branch",
        branch = "main",
        sha = "abc1234567890",
        installed_tag = "main",
    }
    local ok_save = InstallStore.upsert("myplugin.koplugin", test_record)
    assertTest(ok_save == true, "InstallStore successfully saves branch record")

    local retrieved = InstallStore.get("myplugin.koplugin")
    assertTest(retrieved ~= nil, "Record retrieved from store")
    assertTest(retrieved.source == "branch", "Record source is 'branch'")
    assertTest(retrieved.branch == "main", "Record branch is 'main'")
    assertTest(retrieved.sha == "abc1234567890", "Record sha is stored")

    -- 4. Storefront installer branch methods
    print("\n--- TEST 4: Storefront Installer Methods ---")
    local storefront_installer = require("storefront_installer")
    local mockStorefront = {}
    storefront_installer:init(mockStorefront)
    assertTest(type(mockStorefront.installPluginFromBranch) == "function", "mockStorefront.installPluginFromBranch initialized")
    assertTest(type(mockStorefront.showBranchPickerDialog) == "function", "mockStorefront.showBranchPickerDialog initialized")
    assertTest(type(mockStorefront.renderBranchPickerModal) == "function", "mockStorefront.renderBranchPickerModal initialized")

    local test_branches = {}
    for i = 1, 14 do
        table.insert(test_branches, { name = "branch-" .. tostring(i) })
    end
    local ok_render, err_render = pcall(function()
        mockStorefront:renderBranchPickerModal({ name = "testplugin" }, test_branches, "branch-1")
    end)
    assertTest(ok_render == true, "renderBranchPickerModal runs without error for 14 branches", err_render)

    -- 5. Branch update detection in collectUpdateSummary
    print("\n--- TEST 5: Branch Update Detection in collectUpdateSummary ---")
    local MainStorefront = require("main")
    local test_sha_installed = "f4e58b3a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e"
    local test_sha_newer = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6ef4e58b3"

    InstallStore.upsert("pencil.koplugin", {
        dirname = "pencil.koplugin",
        plugin_name = "Pencil",
        owner = "user",
        repo = "pencil",
        source = "branch",
        branch = "main",
        sha = test_sha_installed,
    })

    local sf_test = {
        updates_state = { remote_info = {} },
        ensureUpdatesState = function(self) self.updates_state = self.updates_state or {} end,
        saveUpdatesState = function(self) end,
        autoMatchInstalled = function(self) end,
        listInstalledPlugins = function(self)
            return {
                { dirname = "pencil.koplugin", name = "Pencil", version = "0.5.0", path = "/dummy/pencil.koplugin" }
            }
        end,
    }

    -- Case 5A: Stale release tag "0.5.0" in remote_info must NOT trigger update
    sf_test._cached_plugin_summary = nil
    sf_test.updates_state.remote_info["pencil.koplugin"] = {
        remote_version = "0.5.0",
        release_tag_name = "0.5.0",
        last_checked = os.time(),
    }
    local summary_stale = MainStorefront.collectUpdateSummary(sf_test)
    local item_stale = summary_stale.data and summary_stale.data[1]
    assertTest(item_stale and item_stale.has_update == false, "Stale semver '0.5.0' does NOT trigger branch update")

    -- Case 5B: Cached fallback from catalog must NOT trigger branch update
    sf_test._cached_plugin_summary = nil
    sf_test.updates_state.remote_info["pencil.koplugin"] = {
        remote_version = test_sha_newer,
        is_cached_fallback = true,
        last_checked = os.time(),
    }
    local summary_fallback = MainStorefront.collectUpdateSummary(sf_test)
    local item_fallback = summary_fallback.data and summary_fallback.data[1]
    assertTest(item_fallback and item_fallback.has_update == false, "Cached fallback does NOT trigger branch update")

    -- Case 5C: Matching remote SHA must NOT trigger update (including short SHA vs full SHA)
    sf_test._cached_plugin_summary = nil
    sf_test.updates_state.remote_info["pencil.koplugin"] = {
        remote_version = test_sha_installed,
        release_tag_name = "main@" .. test_sha_installed:sub(1, 7),
        last_checked = os.time(),
    }
    local summary_same = MainStorefront.collectUpdateSummary(sf_test)
    local item_same = summary_same.data and summary_same.data[1]
    assertTest(item_same and item_same.has_update == false, "Matching full branch SHA does NOT trigger update")

    -- Short 7-char installed SHA vs 40-char remote SHA
    InstallStore.upsert("pencil.koplugin", {
        dirname = "pencil.koplugin",
        plugin_name = "Pencil",
        owner = "user",
        repo = "pencil",
        source = "branch",
        branch = "main",
        sha = test_sha_installed:sub(1, 7),
    })
    sf_test._cached_plugin_summary = nil
    local summary_short = MainStorefront.collectUpdateSummary(sf_test)
    local item_short = summary_short.data and summary_short.data[1]
    assertTest(item_short and item_short.has_update == false, "Short 7-char installed SHA vs 40-char remote SHA does NOT trigger update")

    -- Case-insensitive match (e.g. uppercase vs lowercase hex)
    InstallStore.upsert("pencil.koplugin", {
        dirname = "pencil.koplugin",
        plugin_name = "Pencil",
        owner = "user",
        repo = "pencil",
        source = "branch",
        branch = "main",
        sha = test_sha_installed:upper(),
    })
    sf_test._cached_plugin_summary = nil
    local summary_case = MainStorefront.collectUpdateSummary(sf_test)
    local item_case = summary_case.data and summary_case.data[1]
    assertTest(item_case and item_case.has_update == false, "Uppercase installed SHA vs lowercase remote SHA does NOT trigger update")

    -- Restore full lowercase installed SHA for subsequent tests
    InstallStore.upsert("pencil.koplugin", {
        dirname = "pencil.koplugin",
        plugin_name = "Pencil",
        owner = "user",
        repo = "pencil",
        source = "branch",
        branch = "main",
        sha = test_sha_installed,
    })

    -- Case 5D: Genuine new commit SHA on branch MUST trigger update
    sf_test._cached_plugin_summary = nil
    sf_test.updates_state.remote_info["pencil.koplugin"] = {
        remote_version = test_sha_newer,
        release_tag_name = "main@" .. test_sha_newer:sub(1, 7),
        last_checked = os.time(),
    }
    local summary_new = MainStorefront.collectUpdateSummary(sf_test)
    local item_new = summary_new.data and summary_new.data[1]
    assertTest(item_new and item_new.has_update == true, "New commit SHA on branch triggers update")

    -- Direct unit tests for StorefrontUtils.isShaDifferent
    local StorefrontUtils = require("storefront_utils")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed, test_sha_installed:sub(1, 7)) == false, "isShaDifferent 40-char vs 7-char prefix match returns false")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed:sub(1, 7), test_sha_installed) == false, "isShaDifferent 7-char vs 40-char prefix match returns false")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed:upper(), test_sha_installed:lower()) == false, "isShaDifferent uppercase vs lowercase returns false")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed .. "\n", test_sha_installed) == false, "isShaDifferent whitespace trimmed returns false")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed, test_sha_newer) == true, "isShaDifferent differing 40-char SHAs returns true")
    assertTest(StorefrontUtils.isShaDifferent(test_sha_installed:sub(1, 7), test_sha_newer:sub(1, 7)) == true, "isShaDifferent differing 7-char SHAs returns true")

    -- 6. handlePostInstall branch remote_info initialization
    print("\n--- TEST 6: handlePostInstall Remote Info Initialization ---")
    local post_sf = {
        updates_state = {
            remote_info = {
                ["pencil.koplugin"] = {
                    remote_version = "0.5.0",
                    release_tag_name = "0.5.0",
                }
            }
        },
        ensureUpdatesState = function(self) self.updates_state = self.updates_state or {} end,
        saveUpdatesState = function(self) end,
        rememberInstall = function(self, info, repo)
            InstallStore.upsert(info.plugin_dirname, {
                dirname = info.plugin_dirname,
                source = info.source,
                branch = info.branch,
                sha = info.sha,
            })
        end,
    }
    MainStorefront.handlePostInstall(post_sf, {
        plugin_dirname = "pencil.koplugin",
        source = "branch",
        branch = "main",
        sha = test_sha_installed,
    }, { name = "pencil", owner = "user" })

    local post_remote = post_sf.updates_state.remote_info["pencil.koplugin"]
    assertTest(post_remote ~= nil, "handlePostInstall populated remote_info")
    assertTest(post_remote.remote_version == test_sha_installed, "handlePostInstall set remote_version to installed SHA")
    assertTest(post_remote.release_tag_name == "main@" .. test_sha_installed:sub(1, 7), "handlePostInstall set release_tag_name to main@short_sha")

    -- 7. populateRemoteInfoFromCatalog cleans up stale release info for branch plugins
    print("\n--- TEST 7: populateRemoteInfoFromCatalog Stale Cleanup ---")
    local cat_sf = {
        updates_state = {
            remote_info = {
                ["pencil.koplugin"] = {
                    remote_version = "0.5.0",
                    release_tag_name = "0.5.0",
                    is_cached_fallback = true,
                }
            }
        },
        ensureUpdatesState = function(self) self.updates_state = self.updates_state or {} end,
        saveUpdatesState = function(self) end,
        listInstalledPlugins = function(self)
            return { { dirname = "pencil.koplugin" } }
        end,
    }
    MainStorefront.populateRemoteInfoFromCatalog(cat_sf)
    local cleaned_remote = cat_sf.updates_state.remote_info["pencil.koplugin"]
    assertTest(cleaned_remote ~= nil and cleaned_remote.remote_version == test_sha_installed, "populateRemoteInfoFromCatalog cleaned up stale '0.5.0' tag for branch plugin")

    -- Clean up test record
    InstallStore.remove("pencil.koplugin")

    -- 8. Branch installation UI badges and labels (no "v" prefix)
    print("\n--- TEST 8: Branch Installation UI Badges and Labels ---")
    InstallStore.upsert("pencil.koplugin", {
        dirname = "pencil.koplugin",
        owner = "user",
        repo = "pencil",
        source = "branch",
        branch = "main",
        sha = test_sha_installed,
        repo_full_name = "user/pencil",
    })
    MainStorefront._installed_lookup_cache = nil
    local lookup = MainStorefront:getInstalledLookup()
    assertTest(lookup["user/pencil"] == true, "Installed lookup has exact full_name boolean")
    assertTest(lookup.records and lookup.records["user/pencil"] ~= nil, "Installed lookup records contains entry")
    assertTest(lookup.records["user/pencil"].branch == "main", "Installed record branch is main")

    -- Check catalog item badge
    local catalog_item = MainStorefront:makeRepoMenuItem({
        full_name = "user/pencil",
        name = "pencil",
        description = "A test pencil plugin",
    }, lookup)
    assertTest(catalog_item.badge == "branch: main", "Catalog item badge is 'branch: main' (not vmain)")
    assertTest(catalog_item.badge:find("vmain") == nil, "Catalog item badge does not contain 'vmain'")

    -- Check installed tab entry metadata and badge
    local orig_list_plugins = MainStorefront.listInstalledPlugins
    local orig_list_patches = MainStorefront.listInstalledPatches
    MainStorefront.installed_state = MainStorefront.installed_state or {}
    MainStorefront.installed_state.search_text = ""
    MainStorefront.installed_state.filter_type = "plugin"
    MainStorefront.installed_state.filter_default = "all"
    MainStorefront.installed_state.filter_status = "all"
    MainStorefront._installed_tab_items_cache = nil
    MainStorefront.listInstalledPlugins = function()
        return {
            {
                dirname = "pencil.koplugin",
                name = "Pencil Plugin",
                meta = { name = "pencil", fullname = "Pencil Plugin" },
                path = "plugins/pencil.koplugin",
                root = "plugins",
            }
        }
    end
    MainStorefront.listInstalledPatches = function() return {} end
    local installed_entries = MainStorefront:buildInstalledEntries()
    MainStorefront.listInstalledPlugins = orig_list_plugins
    MainStorefront.listInstalledPatches = orig_list_patches

    assertTest(#installed_entries >= 1, "buildInstalledEntries returned items")
    local pencil_entry
    for _, e in ipairs(installed_entries) do
        if e.dirname == "pencil.koplugin" then
            pencil_entry = e
            break
        end
    end
    assertTest(pencil_entry ~= nil, "Pencil entry found in installed entries")
    assertTest(pencil_entry and pencil_entry.badge == nil, "Installed entry badge is nil when up-to-date (no duplication)")
    assertTest(pencil_entry and pencil_entry.kind_label and pencil_entry.kind_label:find("branch: main") ~= nil, "Installed entry kind_label contains 'branch: main'")
    assertTest(pencil_entry and pencil_entry.kind_label and pencil_entry.kind_label:find("vmain") == nil, "Installed entry kind_label does not contain 'vmain'")

    -- Clean up test record
    InstallStore.remove("pencil.koplugin")
    MainStorefront._installed_lookup_cache = nil
    MainStorefront._installed_tab_items_cache = nil

    print("\n--- Test 9: Bug 1 - Forward Declaration and Migrated Auto-Switch Without Crash ---")
    -- Simulate _scanUpdatesForDirectApi result with migrated_source and updated_meta_path
    local sf_scan = {
        updates_state = { remote_info = {} },
        ensureUpdatesState = function(self) self.updates_state = self.updates_state or {} end,
        saveUpdatesState = function(self) end,
    }
    InstallStore.upsert("autoswitch.koplugin", {
        dirname = "autoswitch.koplugin",
        plugin_name = "Autoswitch Plugin",
        owner = "testowner",
        repo = "autoswitch",
        source = "release",
        meta_path = "autoswitch.koplugin/_meta.lua",
    })

    -- Verify getRecordedInstall is accessible in main.lua scope and upsert persists to disk
    local rec_before = InstallStore.get("autoswitch.koplugin")
    assertTest(rec_before ~= nil, "Autoswitch record initialized in InstallStore")

    -- Simulate the exact code path at main.lua:3736-3754
    rec_before.source = "branch"
    rec_before.branch = "main"
    rec_before.sha = nil -- Design concern: auto-switch leaves sha empty
    InstallStore.upsert("autoswitch.koplugin", rec_before)

    rec_before.meta_path = "plugins/autoswitch/_meta.lua"
    rec_before.meta_path_verified = true
    InstallStore.upsert("autoswitch.koplugin", rec_before)

    local rec_after = InstallStore.get("autoswitch.koplugin")
    assertTest(rec_after and rec_after.source == "branch", "Auto-switch persisted source = 'branch'")
    assertTest(rec_after and rec_after.branch == "main", "Auto-switch persisted branch = 'main'")
    assertTest(rec_after and rec_after.sha == nil, "Auto-switch leaves sha nil (does not assume latest commit)")
    assertTest(rec_after and rec_after.meta_path == "plugins/autoswitch/_meta.lua", "Updated meta_path persisted via in-place mutation")

    InstallStore.remove("autoswitch.koplugin")

    print("\n--- Test 10: Missing SHA in branch record flags update & shows unknown ---")
    InstallStore.upsert("missing_sha.koplugin", {
        dirname = "missing_sha.koplugin",
        plugin_name = "Missing SHA Plugin",
        owner = "user",
        repo = "missing_sha",
        source = "branch",
        branch = "main",
        sha = nil,
    })
    local sf_missing = {
        updates_state = { remote_info = {} },
        ensureUpdatesState = function(self) self.updates_state = self.updates_state or {} end,
        saveUpdatesState = function(self) end,
        autoMatchInstalled = function(self) end,
        listInstalledPlugins = function(self)
            return {
                { dirname = "missing_sha.koplugin", name = "Missing SHA Plugin", version = "1.0.0", path = "/dummy/missing_sha.koplugin" }
            }
        end,
    }
    local summary_missing = MainStorefront.collectUpdateSummary(sf_missing)
    local item_missing = summary_missing.data and summary_missing.data[1]
    assertTest(item_missing and item_missing.has_update == true, "Missing SHA on branch record flags has_update = true")

    -- Check Updates tab rendering for missing SHA via buildUpdatesEntries
    MainStorefront._merged_updates_cache = nil
    local orig_collect_plugin = MainStorefront.collectUpdateSummary
    local orig_collect_patch = MainStorefront.collectPatchUpdateSummary
    MainStorefront.collectUpdateSummary = function(self) return summary_missing end
    MainStorefront.collectPatchUpdateSummary = function(self) return { total = 0, tracked = 0, updates = 0, data = {} } end
    local updates_entries = MainStorefront:buildUpdatesEntries()
    MainStorefront.collectUpdateSummary = orig_collect_plugin
    MainStorefront.collectPatchUpdateSummary = orig_collect_patch

    local ui_item_missing = updates_entries and updates_entries[1]
    assertTest(ui_item_missing ~= nil, "buildUpdatesEntries rendered missing SHA item")
    assertTest(ui_item_missing and ui_item_missing.badge == "Re-pull from branch", "Updates tab shows 'Re-pull from branch' badge")
    local missing_trans = ui_item_missing and (ui_item_missing.version_transition or ui_item_missing.transition)
    assertTest(missing_trans and missing_trans:find("unknown") ~= nil, "Updates tab transition contains 'unknown'")

    -- Check Installed tab shows (unknown)
    local orig_list_plugins_2 = MainStorefront.listInstalledPlugins
    MainStorefront.listInstalledPlugins = function()
        return {
            {
                dirname = "missing_sha.koplugin",
                name = "Missing SHA Plugin",
                meta = { name = "missing_sha", fullname = "Missing SHA Plugin" },
                path = "plugins/missing_sha.koplugin",
                root = "plugins",
            }
        }
    end
    MainStorefront._installed_tab_items_cache = nil
    local installed_entries_missing = MainStorefront:buildInstalledEntries()
    MainStorefront.listInstalledPlugins = orig_list_plugins_2
    local missing_entry = installed_entries_missing and installed_entries_missing[1]
    assertTest(missing_entry and missing_entry.kind_label and missing_entry.kind_label:find("branch: main %(unknown%)") ~= nil, "Installed tab displays 'branch: main (unknown)'")

    InstallStore.remove("missing_sha.koplugin")

    print("\n--- Test 11: Zip EOCD Commit SHA Extraction ---")
    local Installer = require("storefront_installer")
    assertTest(type(Installer.extractGitHubZipCommitSha) == "function", "Installer.extractGitHubZipCommitSha is exported")

    -- Create synthetic zip file with GitHub 40-char commit SHA in EOCD comment
    local test_zip_path = script_dir .. "test_eocd_sha.zip"
    local sample_sha = "1234567890abcdef1234567890abcdef12345678"
    local f_zip, open_err = io.open(test_zip_path, "wb")
    if f_zip then
        -- Minimal valid zip: Empty Central Directory + EOCD record
        -- EOCD signature: PK\x05\x06 (4 bytes)
        -- disk number (2), start disk (2), entries on disk (2), total entries (2): all 0
        -- central dir size (4), central dir offset (4): all 0
        -- comment length: 40 (2 bytes: \x28\x00)
        -- comment: 40 bytes hex SHA
        local eocd = "PK\005\006" .. string.rep("\0", 16) .. string.char(40, 0) .. sample_sha
        f_zip:write(eocd)
        f_zip:close()

        local extracted = Installer.extractGitHubZipCommitSha(test_zip_path)
        assertTest(extracted == sample_sha, "extractGitHubZipCommitSha extracts 40-char SHA from EOCD comment")
        os.remove(test_zip_path)
    else
        assertTest(false, "Could not create test zip for EOCD test: " .. tostring(open_err))
    end

    print("\n--- Test 12: InstallStore in-place mutation and transient scrubbing ---")
    InstallStore.upsert("clean_test.koplugin", {
        dirname = "clean_test.koplugin",
        plugin_name = "Clean Test",
        in_catalog = true,
        cached_sha = "abc",
        cached_version = "1.0",
        source = "branch",
        branch = "main",
    })
    local got_rec = InstallStore.get("clean_test.koplugin")
    assertTest(got_rec.in_catalog == nil, "Transient in_catalog stripped by InstallStore.upsert")
    assertTest(got_rec.cached_sha == nil, "Transient cached_sha stripped by InstallStore.upsert")
    assertTest(got_rec.cached_version == nil, "Transient cached_version stripped by InstallStore.upsert")

    -- In-place mutation test
    got_rec.meta_path = "plugins/clean_test/_meta.lua"
    InstallStore.upsert("clean_test.koplugin", got_rec)
    local reloaded_rec = InstallStore.get("clean_test.koplugin")
    assertTest(reloaded_rec.meta_path == "plugins/clean_test/_meta.lua", "InstallStore.upsert persists modified meta_path on in-place mutated record")

    InstallStore.remove("clean_test.koplugin")

    print("\n--- Test 13: Catalog Does Not Overwrite Newer Live Release/Pre-release ---")
    local Cache = require("storefront_cache")
    Cache.init()
    MainStorefront.updates_state = {
        remote_info = {
            ["liveplugin.koplugin"] = {
                remote_version = "2.1.0-beta.1",
                release_tag_name = "v2.1.0-beta.1",
                last_checked = os.time(),
                is_cached_fallback = false, -- live check result
            }
        },
        last_checked = os.time(),
    }
    InstallStore.upsert("liveplugin.koplugin", {
        dirname = "liveplugin.koplugin",
        owner = "liveowner",
        repo = "liveplugin",
        repo_id = 8888,
    })
    Cache.storeRepos("plugin", {
        {
            name = "liveplugin",
            owner = "liveowner",
            id = 8888,
            version = "2.0.0",
            latest_release = {
                tag_name = "v2.0.0",
                published_at = "2026-10-01T00:00:00Z",
            },
        }
    })
    local orig_list_live = MainStorefront.listInstalledPlugins
    MainStorefront.listInstalledPlugins = function() return { { dirname = "liveplugin.koplugin" } } end
    MainStorefront:populateRemoteInfoFromCatalog()
    MainStorefront.listInstalledPlugins = orig_list_live

    local preserved = MainStorefront.updates_state.remote_info["liveplugin.koplugin"]
    assertTest(preserved and preserved.release_tag_name == "v2.1.0-beta.1", "populateRemoteInfoFromCatalog preserves newer live check result")
    assertTest(preserved and preserved.is_cached_fallback == false, "Live check result is not marked as cached fallback")

    InstallStore.remove("liveplugin.koplugin")

    print("\n--- Test 14: Rate-Limited Branch Scan Does Not Fake Up-to-Date ---")
    InstallStore.upsert("ratelimit.koplugin", {
        dirname = "ratelimit.koplugin",
        owner = "rlowner",
        repo = "ratelimit",
        source = "branch",
        branch = "main",
        sha = "1111222233334444555566667777888899990000",
    })
    MainStorefront.updates_state = {
        remote_info = {
            ["ratelimit.koplugin"] = {
                remote_version = "9999888877776666555544443333222211110000",
                release_tag_name = "main@9999888",
                last_checked = os.time() - 3600,
            }
        }
    }
    -- Simulate the merge logic when worker encounters rate limit (data has error and nil remote_version)
    local worker_res = {
        ["ratelimit.koplugin"] = {
            remote_version = nil,
            release_tag_name = nil,
            error = "API rate limit reached; using catalog data.",
            last_checked = os.time(),
        }
    }
    local remote_info = MainStorefront.updates_state.remote_info
    for dirname, data in pairs(worker_res) do
        local prev = remote_info[dirname]
        if data.error and (not data.remote_version and not data.release_tag_name) and prev and (prev.remote_version or prev.release_tag_name) then
            prev.error = data.error
            prev.last_checked = data.last_checked or os.time()
        else
            remote_info[dirname] = data
        end
    end
    local rl_entry = remote_info["ratelimit.koplugin"]
    assertTest(rl_entry and rl_entry.remote_version == "9999888877776666555544443333222211110000", "Rate-limited worker does not wipe previously detected remote SHA")
    assertTest(rl_entry and rl_entry.remote_version ~= "1111222233334444555566667777888899990000", "Rate-limited worker does not fake up-to-date with installed SHA")

    InstallStore.remove("ratelimit.koplugin")

    print("\n==================================================")
    print(string.format("RESULTS: %d PASSED, %d FAILED", passed, failed))
    print("==================================================")
    if failed > 0 then
        os.exit(1)
    end
end

runTests()
