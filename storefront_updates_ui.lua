local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local StorefrontUpdatesUi = {}

function StorefrontUpdatesUi:init(StorefrontClass)
    -- Mixin methods to Storefront class

    function StorefrontClass:buildUpdatesEntries()
        self:ensureUpdatesState()
        self:ensurePatchUpdatesState()

        -- Merged list of updates
        local plugin_summary = self:collectUpdateSummary()
        local patch_summary = self:collectPatchUpdateSummary()

        local merged = {}

        -- Gather plugins
        for idx, item in ipairs(plugin_summary.data or {}) do
            local plugin = item.plugin
            local record = item.record
            local remote = item.remote
            local has_update = item.has_update
            
            if not self.updates_state.filter_only_outdated or has_update then
                local local_ver = plugin.version or _("unknown")
                local remote_ver = remote and (remote.release_tag_name or remote.remote_version) or _("unknown")
                
                table.insert(merged, {
                    name = plugin.name or plugin.dirname,
                    owner = record and record.owner or "",
                    stars_fmt = record and record.repo_description and "plugin" or "0",
                    updated = "",
                    kind_label = _("Plugin"),
                    description = record and record.repo_description or "",
                    badge = has_update and _("Update") or _("Installed"),
                    is_entry = true,
                    keep_menu_open = true,
                    is_update_item = true,
                    version_transition = local_ver .. " → " .. remote_ver,
                    callback = function()
                        self:promptUpdateAction(plugin, record)
                    end,
                })
            end
        end

        -- Gather patches
        for idx, item in ipairs(patch_summary.data or {}) do
            local patch = item.patch
            local record = item.record
            local remote_entry = item.remote_entry
            local has_update = item.needs_update
 
            if not self.patch_updates_state.filter_only_outdated or has_update then
                local local_commit = (record and record.commit) or item.local_sha or ""
                local remote_commit = (remote_entry and remote_entry.commit) or item.remote_sha or ""
                local local_ver = local_commit ~= "" and ("sha " .. local_commit:sub(1, 5)) or _("unknown")
                local remote_ver = remote_commit ~= "" and ("sha " .. remote_commit:sub(1, 5)) or _("unknown")

                table.insert(merged, {
                    name = patch.filename or patch.path or _("patch"),
                    owner = record and record.owner or "",
                    stars_fmt = "patch",
                    updated = "",
                    kind_label = _("Patch"),
                    description = record and record.repo_description or "",
                    badge = has_update and _("Update") or _("Installed"),
                    is_entry = true,
                    keep_menu_open = true,
                    is_update_item = true,
                    version_transition = local_ver .. " → " .. remote_ver,
                    callback = function()
                        self:promptPatchUpdateAction(item)
                    end,
                })
            end
        end

        -- Sort merged list by name A-Z
        table.sort(merged, function(a, b)
            local aname = a.name or ""
            local bname = b.name or ""
            return aname:lower() < bname:lower()
        end)

        local display_total = #merged
        local page_size = 7
        local total_pages = math.max(1, math.ceil(display_total / page_size))
        local page = math.min(math.max(self.browser_state.page or 1, 1), total_pages)
        if self.browser_state.page ~= page then
            self.browser_state.page = page
            self:saveBrowserState()
        end

        local start_index = (page - 1) * page_size + 1
        local end_index = math.min(display_total, start_index + page_size - 1)

        local items = {}
        if display_total == 0 then
            table.insert(items, {
                text = _("No items found."),
                select_enabled = false,
            })
        else
            for i = start_index, end_index do
                local entry = merged[i]
                entry.separator = true
                table.insert(items, entry)
            end
        end

        return items, total_pages
    end

    function StorefrontClass:maybeAutoCheckUpdates()
        if self._updates_checked_this_session then
            return
        end
        self._updates_checked_this_session = true

        UIManager:nextTick(function()
            local progress = InfoMessage:new{ text = _("Checking updates…"), timeout = 0 }
            UIManager:show(progress)
            UIManager:forceRePaint()

            NetworkMgr:runWhenOnline(function()
                -- Check plugins
                local installed_plugins = self:listInstalledPlugins()
                local records = self:getInstallRecordsMap()
                local plugin_repos = {}
                for idx, plugin in ipairs(installed_plugins) do
                    local record = records[plugin.dirname]
                    if record and record.owner and record.repo then
                        table.insert(plugin_repos, record)
                    end
                end
                
                -- Check patches
                local installed_patches = self:listInstalledPatches()
                local patch_records = self:getPatchRecordsMap()
                local patch_repos = {}
                for idx, patch in ipairs(installed_patches) do
                    local record = patch_records[patch.filename]
                    if record and record.owner and record.repo and record.path then
                        table.insert(patch_repos, record)
                    end
                end

                -- Run the checks
                pcall(function()
                    self:_refreshUpdatesInternal(plugin_repos)
                end)
                pcall(function()
                    self:_refreshPatchUpdatesInternal(patch_repos)
                end)

                UIManager:close(progress)
                UIManager:nextTick(function()
                    self:reopenBrowser()
                end)
            end)
        end)
    end
end

return StorefrontUpdatesUi
