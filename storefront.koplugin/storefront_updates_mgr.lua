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

    Storefront._processBatchUpdateQueue = function(sf, queue, index, stats)
        stats = stats or { success = 0, failed = 0 }
        _G.G_storefront_batch_updating = true
        if index > #queue then
            _G.G_storefront_batch_updating = false
            sf.pending_install_context = nil
            sf.pending_patch_install = nil

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

            if sf.showRestartConfirmation then
                sf:showRestartConfirmation(summary_msg)
            end
            return
        end

        local item = queue[index]

        local StorefrontToast = require("storefront_toast")
        local progress_msg = StorefrontToast.show(
            string.format(_("Updating [%d/%d]: %s…"), index, #queue, item.name or ""),
            0,
            { dismissable = false }
        )
        UIManager:forceRePaint()

        local next_step = function(success, err)
            if progress_msg and progress_msg.close then
                progress_msg:close()
            end
            if success then
                stats.success = stats.success + 1
            else
                stats.failed = stats.failed + 1
                StorefrontLogger.err(string.format("Batch update failed for item %s: %s", item.name, tostring(err)))
            end
            UIManager:nextTick(function()
                sf:_processBatchUpdateQueue(queue, index + 1, stats)
            end)
        end

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
            local release_override = item.remote or (record.tag_name and { tag_name = record.tag_name })
            sf:promptPluginInstallOptions(descriptor, release_override)
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
            local patch_entry = {
                filename = record.filename,
                path = record.path,
                branch = record.branch or "HEAD",
                download_url = record.download_url,
                sha = record.sha,
            }
            sf.pending_patch_install = {
                mode = "update",
                patch = installed_patch,
                is_batch = true,
                batch_callback = next_step,
            }
            sf:installPatchFromRepo(repo, patch_entry)
        else
            next_step(false, "Unknown item kind")
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
        if #tracked == 0 then
            UIManager:show(InfoMessage:new{ text = _("No matched plugins to check."), timeout = 4 })
            return
        end
        local GitHub = require("storefront_net_github")
        if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
            sf:_scanUpdatesForDirectApi(tracked)
            return
        end

        NetworkMgr:runWhenOnline(function()
            local Toast = require("storefront_toast")
            Toast.show(_("Refreshing catalog..."), 1.5)
            StorefrontLogger.info("Storefront UI: manual refresh triggered, fetching catalog cache...")

            local CatalogClient = require("storefront_net_catalog")
            CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
                if ok then
                    StorefrontLogger.info("Storefront UI: manual refresh succeeded, populating remote info.")
                    if sf.populateRemoteInfoFromCatalog then
                        sf:populateRemoteInfoFromCatalog()
                    end
                    if sf.updates_menu then
                        sf:updateUpdatesDialog()
                    end
                    UIManager:setDirty(nil, "full")
                    sf:refreshCurrentBrowserTab()
                    Toast.show(_("Catalog refreshed successfully."), 3)
                else
                    StorefrontLogger.warn("Storefront UI: manual refresh failed: " .. tostring(err))
                    Toast.show(_("Catalog refresh failed: ") .. tostring(err), 4)
                end
            end)
        end)
    end
end

return UpdatesMgr
