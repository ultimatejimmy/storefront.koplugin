local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local util = require("util")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = { action = function() end, err = function() end, info = function() end, warn = function() end } end

local InstallStore = require("storefront_installs")
local PluginPaths = require("storefront_plugin_paths")

local UpdatesMgr = {}

function UpdatesMgr:init(Storefront)
    Storefront.updateAllAvailable = function(sf)
        sf:ensureUpdatesState()
        sf:ensurePatchUpdatesState()

        local plugin_summary = sf:collectUpdateSummary()
        local patch_summary = sf:collectPatchUpdateSummary()

        local pending_queue = {}

        for _idx, item in ipairs(plugin_summary.data or {}) do
            if item.has_update and item.record then
                table.insert(pending_queue, {
                    kind = "plugin",
                    name = item.plugin and (item.plugin.name or item.plugin.dirname) or item.record.repo or _("plugin"),
                    record = item.record,
                    plugin = item.plugin,
                    remote = item.remote,
                })
            end
        end

        for _idx, item in ipairs(patch_summary.data or {}) do
            if item.needs_update and item.record then
                table.insert(pending_queue, {
                    kind = "patch",
                    name = item.patch and (item.patch.filename or item.patch.path) or item.record.filename or _("patch"),
                    record = item.record,
                    patch = item.patch,
                    remote_entry = item.remote_entry,
                })
            end
        end

        if #pending_queue == 0 then
            local StorefrontToast = require("storefront_toast")
            UIManager:show(StorefrontToast:new{
                text = _("All items are up to date."),
                timeout = 4,
            })
            return
        end

        local plugin_count = 0
        local patch_count = 0
        for _, item in ipairs(pending_queue) do
            if item.kind == "plugin" then
                plugin_count = plugin_count + 1
            else
                patch_count = patch_count + 1
            end
        end

        local detail_str
        if plugin_count > 0 and patch_count > 0 then
            local plugin_str = (plugin_count == 1) and _("1 plugin") or string.format(_("%d plugins"), plugin_count)
            local patch_str = (patch_count == 1) and _("1 patch") or string.format(_("%d patches"), patch_count)
            detail_str = string.format(_("%s and %s"), plugin_str, patch_str)
        elseif plugin_count > 0 then
            detail_str = (plugin_count == 1) and _("1 plugin") or string.format(_("%d plugins"), plugin_count)
        else
            detail_str = (patch_count == 1) and _("1 patch") or string.format(_("%d patches"), patch_count)
        end

        local confirm_text = string.format(_("Update %s?"), detail_str)

        sf:showConfirmDialog{
            title = _("Confirm Update All"),
            text = confirm_text,
            ok_text = _("Update All"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                _G.G_storefront_batch_updating = true
                UIManager:nextTick(function()
                    sf:_processBatchUpdateQueue(pending_queue, 1, { success = 0, failed = 0 })
                end)
            end,
        }
    end

    Storefront._processBatchUpdateQueue = function(sf, queue, index, stats, batch_toast)
        stats = stats or { success = 0, failed = 0 }
        _G.G_storefront_batch_updating = true
        if index > #queue then
            _G.G_storefront_batch_updating = false
            sf.pending_install_context = nil
            sf.pending_patch_install = nil

            if batch_toast and batch_toast.close then
                batch_toast:close()
            end

            if sf.invalidateInstalledPluginsCache then
                sf:invalidateInstalledPluginsCache()
            end
            sf._merged_updates_cache = nil
            sf._cached_plugin_summary = nil
            sf._cached_patch_summary = nil
            sf._cached_updates_count = nil

            sf:saveUpdatesState()
            sf:savePatchUpdatesState()
            if sf.saveInstalledState then sf:saveInstalledState() end

            sf:softRefreshCurrentBrowserView()

            local summary_msg
            if stats.failed == 0 then
                summary_msg = string.format(_("Successfully updated %d item(s)."), stats.success)
            else
                summary_msg = string.format(_("Updated %d of %d item(s) (%d failed)."), stats.success, #queue, stats.failed)
            end

            if stats.success > 0 then
                if sf.showRestartConfirmation then
                    sf:showRestartConfirmation(summary_msg)
                end
            else
                local StorefrontToast = require("storefront_toast")
                StorefrontToast.show(summary_msg, 4)
            end
            return
        end

        local item = queue[index]
        local item_title = item.name or ""
        local progress_text = string.format(_("Updating [%d/%d]: %s…\nTap screen to cancel."), index, #queue, item_title)

        local StorefrontToast = require("storefront_toast")
        if not batch_toast then
            batch_toast = StorefrontToast.show(progress_text, 0, {
                dismissable = true,
                dismiss_callback = function()
                    _G.G_storefront_batch_updating = false
                    sf.pending_install_context = nil
                    sf.pending_patch_install = nil
                    if sf.invalidateInstalledPluginsCache then
                        sf:invalidateInstalledPluginsCache()
                    end
                    sf:softRefreshCurrentBrowserView()
                    StorefrontToast.show(_("Batch update cancelled."), 3)
                end,
            })
        else
            if batch_toast.setText then
                batch_toast:setText(progress_text)
            end
        end

        local next_step = function(success, err)
            if err == "Cancelled by user" or err == "Cancelled asset selection" then
                _G.G_storefront_batch_updating = false
                sf.pending_install_context = nil
                sf.pending_patch_install = nil
                if batch_toast and batch_toast.close then
                    batch_toast:close()
                end
                if sf.invalidateInstalledPluginsCache then
                    sf:invalidateInstalledPluginsCache()
                end
                sf:softRefreshCurrentBrowserView()
                StorefrontToast.show(_("Batch update cancelled."), 3)
                return
            end
            if success then
                stats.success = stats.success + 1
            else
                stats.failed = stats.failed + 1
                StorefrontLogger.err(string.format("Batch update failed for item %s: %s", tostring(item.name), tostring(err)))
            end
            UIManager:nextTick(function()
                sf:_processBatchUpdateQueue(queue, index + 1, stats, batch_toast)
            end)
        end

        local ok_dispatch, dispatch_err = pcall(function()
            if item.kind == "plugin" then
                local record = item.record
                local plugin = item.plugin
                if not plugin and sf.listInstalledPlugins then
                    for _, p in ipairs(sf:listInstalledPlugins()) do
                        if p.dirname == record.dirname then
                            plugin = p
                            break
                        end
                    end
                end
                if not plugin or not record then
                    next_step(false, "Missing local plugin or record")
                    return
                end
                sf.pending_install_context = {
                    mode = "update",
                    plugin = plugin,
                    is_batch = true,
                    batch_callback = next_step,
                    batch_toast = batch_toast,
                }
                local descriptor = {
                    kind = "plugin",
                    name = record.repo,
                    owner = record.owner,
                    full_name = record.repo_full_name or (record.owner and record.repo and (record.owner .. "/" .. record.repo)),
                    id = record.repo_id,
                    description = record.repo_description,
                    default_branch = record.branch or "main",
                }
                if record.source == "branch" and record.branch and sf.installPluginFromBranch then
                    sf:installPluginFromBranch(descriptor, record.branch)
                else
                    local release_override = item.remote or (record.tag_name and { tag_name = record.tag_name })
                    sf:promptPluginInstallOptions(descriptor, release_override)
                end
            elseif item.kind == "patch" then
                local record = item.record
                local installed_patch = item.patch
                if not record or not installed_patch then
                    next_step(false, "Missing local patch or record")
                    return
                end
                local repo = {
                    kind = "patch",
                    name = record.repo,
                    owner = record.owner,
                    full_name = record.repo_full_name or (record.owner and record.repo and (record.owner .. "/" .. record.repo)),
                    id = record.repo_id,
                    description = record.repo_description,
                }
                local remote_entry = item.remote_entry or (sf.patch_updates_state and sf.patch_updates_state.remote_info and sf.patch_updates_state.remote_info[record.filename])
                local patch_entry = {
                    filename = record.filename,
                    path = record.path,
                    branch = record.branch or "HEAD",
                    download_url = (remote_entry and remote_entry.download_url) or record.download_url,
                    sha = (remote_entry and remote_entry.remote_sha) or item.remote_sha or record.sha,
                }
                sf.pending_patch_install = {
                    mode = "update",
                    patch = installed_patch,
                    is_batch = true,
                    batch_callback = next_step,
                    batch_toast = batch_toast,
                }
                sf:installPatchFromRepo(repo, patch_entry)
            else
                next_step(false, "Unknown item kind")
            end
        end)

        if not ok_dispatch then
            _G.G_storefront_batch_updating = false
            next_step(false, "Dispatch error: " .. tostring(dispatch_err))
        end
    end

    Storefront.checkAllUpdates = function(sf)
        if sf.invalidateInstalledPluginsCache then
            sf:invalidateInstalledPluginsCache()
        end
        local records = (InstallStore.list and InstallStore.list()) or {}
        local tracked = {}
        local installed = sf:listInstalledPlugins()
        local installed_map = {}
        for _, plugin in ipairs(installed) do
            if plugin.dirname then
                installed_map[plugin.dirname] = true
            end
        end
        for dirname, record in pairs(records) do
            if installed_map[dirname] and record.owner and record.repo then
                record.dirname = dirname
                tracked[#tracked + 1] = record
            end
        end

        local tracked_patches = {}
        local ok_patch, PatchMgr = pcall(require, "storefront_patch_mgr")
        if ok_patch and PatchMgr and PatchMgr.isUserPatchEnabled and PatchMgr.isUserPatchEnabled() then
            local patch_records = (sf.getPatchRecordsMap and sf:getPatchRecordsMap()) or {}
            local installed_patches = (sf.listInstalledPatches and sf:listInstalledPatches()) or {}
            local installed_patch_map = {}
            for _, patch in ipairs(installed_patches) do
                if patch.filename then
                    installed_patch_map[patch.filename] = true
                end
            end
            for filename, prec in pairs(patch_records) do
                if installed_patch_map[filename] and prec.owner and prec.repo and prec.path then
                    local copy = {}
                    for k, v in pairs(prec) do copy[k] = v end
                    copy.filename = filename
                    tracked_patches[#tracked_patches + 1] = copy
                end
            end
        end

        if #tracked == 0 and #tracked_patches == 0 then
            UIManager:show(InfoMessage:new{ text = _("No tracked plugins to check."), timeout = 4 })
            return
        end
        -- User explicitly requested manual update check: query GitHub API directly.
        sf:_scanUpdatesForDirectApi(tracked, tracked_patches)
    end

    Storefront.collectUpdatesForNotification = function(sf)
        if sf.ensureUpdatesState then sf:ensureUpdatesState() end
        if sf.ensurePatchUpdatesState then sf:ensurePatchUpdatesState() end

        if sf.populateRemoteInfoFromCatalog then
            pcall(function() sf:populateRemoteInfoFromCatalog() end)
        end

        local plugin_summary = (sf.collectUpdateSummary and sf:collectUpdateSummary()) or {}
        local patch_summary = (sf.collectPatchUpdateSummary and sf:collectPatchUpdateSummary()) or {}

        local updates = {}
        local seen_names = {}

        -- 1. Plugins with updates
        for _, item in ipairs(plugin_summary.data or {}) do
            if item.has_update then
                local dirname = item.plugin and item.plugin.dirname
                local repo = item.record and item.record.repo
                local is_storefront = (dirname and dirname:lower():match("storefront"))
                    or (repo and repo:lower():match("storefront"))

                local name
                if is_storefront then
                    name = "Storefront"
                else
                    name = (item.plugin and (item.plugin.name or item.plugin.dirname))
                        or (item.record and item.record.repo)
                        or _("Plugin")
                end

                local ver = item.remote and (item.remote.release_tag_name or item.remote.remote_version)
                if not ver and item.record then
                    ver = item.record.tag_name or item.record.version
                end
                local key = name:lower():gsub("%.koplugin$", "")
                
                local is_seen = seen_names[key]
                if dirname then
                    local d_key = dirname:lower():gsub("%.koplugin$", "")
                    is_seen = is_seen or seen_names[d_key]
                end
                if repo then
                    local r_key = repo:lower():gsub("%.koplugin$", "")
                    is_seen = is_seen or seen_names[r_key]
                end

                if not is_seen then
                    seen_names[key] = true
                    if dirname then seen_names[dirname:lower():gsub("%.koplugin$", "")] = true end
                    if repo then seen_names[repo:lower():gsub("%.koplugin$", "")] = true end
                    if is_storefront then
                        seen_names["storefront"] = true
                        seen_names["storefront.koplugin"] = true
                    end

                    table.insert(updates, {
                        name = name,
                        version = ver or "",
                        kind = "plugin",
                    })
                end
            end
        end

        -- 2. Patches with updates
        for _, item in ipairs(patch_summary.data or {}) do
            if item.needs_update then
                local name = (item.patch and (item.patch.filename or item.patch.path))
                    or (item.record and item.record.filename)
                    or _("Patch")
                local key = name:lower()
                if not seen_names[key] then
                    seen_names[key] = true
                    table.insert(updates, {
                        name = name,
                        version = "(patch)",
                        kind = "patch",
                    })
                end
            end
        end

        -- 3. Storefront self-update (if not already found in plugin_summary)
        local sf_seen = seen_names["storefront"] or seen_names["storefront.koplugin"]
        if not sf_seen then
            local ok_about, AboutDialog = pcall(require, "storefront_about_dialog")
            local ok_cache, Cache = pcall(require, "storefront_cache")
            local ok_utils, StorefrontUtils = pcall(require, "storefront_utils")
            if ok_about and AboutDialog and ok_cache and Cache and ok_utils and StorefrontUtils then
                local current_ver = AboutDialog.getVersion and AboutDialog.getVersion()
                local channel = AboutDialog.getChannel and AboutDialog.getChannel() or "stable"
                local cached_repo = Cache.getRepoByName("ultimatejimmy", "storefront.koplugin")
                    or Cache.getRepoByName("ultimatejimmy", "storefront")
                if cached_repo and current_ver then
                    local target_rel = cached_repo.latest_release or (cached_repo.data and cached_repo.data.latest_release)
                    if channel == "beta" then
                        local pre_rel = cached_repo.latest_prerelease or (cached_repo.data and cached_repo.data.latest_prerelease)
                        if pre_rel and pre_rel.tag_name then
                            target_rel = pre_rel
                        end
                    end
                    local remote_tag = target_rel and (target_rel.tag_name or target_rel.name)
                    if remote_tag then
                        local clean_remote = tostring(remote_tag):gsub("^[vV]", "")
                        local clean_curr = tostring(current_ver):gsub("^[vV]", "")
                        if clean_remote ~= "" and StorefrontUtils.isVersionNewer(clean_remote, clean_curr) then
                            table.insert(updates, 1, {
                                name = "Storefront",
                                version = "v" .. clean_remote,
                                kind = "plugin",
                            })
                        end
                    end
                end
            end
        end

        return updates
    end

    Storefront.checkStartupNotifications = function(sf, is_online)
        local NotificationMgr = require("storefront_notification_mgr")
        local should_check, reason = NotificationMgr.shouldCheckNow(nil, is_online)
        if not should_check then
            StorefrontLogger.info(string.format("Storefront notifications: check skipped (%s)", tostring(reason)))
            return
        end

        local updates = sf:collectUpdatesForNotification()
        if (not updates or #updates == 0) and NotificationMgr.isDebugAlwaysTrigger() then
            updates = {
                { name = "Libbee (Test)", version = "v26.9.13-beta", kind = "plugin" },
            }
        end
        NotificationMgr.markChecked()

        if updates and #updates > 0 then
            StorefrontLogger.info(string.format("Storefront notifications: %d update(s) found, presenting notification dialog", #updates))
            local NotificationUI = require("storefront_notification_ui")
            UIManager:nextTick(function()
                NotificationUI.show(sf, updates)
            end)
        else
            StorefrontLogger.info("Storefront notifications: check completed, no updates found")
        end
    end
end

return UpdatesMgr
