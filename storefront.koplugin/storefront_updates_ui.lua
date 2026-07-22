local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Cache = require("storefront_cache")
local _ = require("gettext")

local StorefrontUpdatesUi = {}

function StorefrontUpdatesUi:init(StorefrontClass)
    -- Mixin methods to Storefront class

    function StorefrontClass:buildUpdatesEntries()
        self:ensureUpdatesState()
        self:ensurePatchUpdatesState()

        local InstallStore = require("storefront_installs")
        local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
        local remote_key = self.updates_state and self.updates_state.remote_info
        local patch_remote_key = self.patch_updates_state and self.patch_updates_state.remote_info
        local filter_outdated = self.updates_state and self.updates_state.filter_only_outdated
        local cache_key = string.format("%s|%s|%s|%s", tostring(gen), tostring(remote_key), tostring(patch_remote_key), tostring(filter_outdated))

        local merged
        if self._merged_updates_cache and self._merged_updates_cache.key == cache_key then
            merged = self._merged_updates_cache.merged
        else
            -- Merged list of updates
            local plugin_summary = self:collectUpdateSummary()
            local patch_summary = self:collectPatchUpdateSummary()

            merged = {}

        -- Gather plugins
        for idx, item in ipairs(plugin_summary.data or {}) do
            local plugin = item.plugin
            local record = item.record
            local remote = item.remote
            local has_update = item.has_update
            
            if not self.updates_state.filter_only_outdated or has_update then
                -- Strip leading 'v'/'V' so "v2.4.4" displays as "2.4.4" consistently.
                local local_ver = (plugin.version and tostring(plugin.version):gsub("^[vV]", "")) or _("unknown")
                local remote_ver_raw = remote and (remote.release_tag_name or remote.remote_version)
                local remote_ver = remote_ver_raw and tostring(remote_ver_raw):gsub("^[vV]", "") or nil

                if not remote_ver or remote_ver == "" or remote_ver == "new" or remote_ver == local_ver then
                    has_update = false
                end

                local remote_display
                if has_update then
                    remote_display = remote_ver or _("new")
                else
                    remote_display = _("latest")
                end
                
                table.insert(merged, {
                    name = plugin.name or plugin.dirname,
                    owner = record and record.owner or "",
                    stars_fmt = record and record.repo_description and "plugin" or "0",
                    updated = "",
                    kind_label = _("Plugin"),
                    description = record and record.repo_description or "",
                    badge = has_update and _("Update") or _("✓ Current"),
                    is_entry = true,
                    keep_menu_open = true,
                    is_update_item = true,
                    version_transition = local_ver .. " → " .. remote_display,
                    callback = function()
                        local DetailsDialog = require("storefront_details_dialog")
                        local cached_repo
                        if record then
                            if record.repo_id then
                                cached_repo = Cache.getRepo(record.repo_id)
                            end
                            if not cached_repo and record.owner and record.repo then
                                cached_repo = Cache.getRepoByName(record.owner, record.repo)
                            end
                        end
                        local repo = cached_repo or {
                            name = record and record.repo or plugin.dirname,
                            owner = record and record.owner or "",
                            full_name = record and record.repo_full_name or "",
                            id = record and record.repo_id or nil,
                            description = record and record.repo_description or "",
                            stars = 0,
                            data = {
                                owner = { login = record and record.owner or "" },
                                default_branch = record and record.branch or "HEAD",
                                stargazers_count = 0,
                            }
                        }
                        local details_dialog = DetailsDialog:new{
                            Storefront = self,
                            repo = repo,
                            kind = "update",
                            update_item = { plugin = plugin, record = record, needs_update = has_update },
                            default_tab = "release_notes",
                        }
                        details_dialog:show()
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
                local remote_commit = (remote_entry and remote_entry.remote_sha) or item.remote_sha or ""
                local local_ver = local_commit ~= "" and ("sha " .. local_commit:sub(1, 5)) or _("unknown")
                local remote_ver = remote_commit ~= "" and ("sha " .. remote_commit:sub(1, 5)) or _("unknown")

                local remote_display
                if has_update then
                    remote_display = remote_ver
                else
                    remote_display = _("latest")
                end

                table.insert(merged, {
                    name = patch.filename or patch.path or _("patch"),
                    owner = record and record.owner or "",
                    stars_fmt = "patch",
                    updated = "",
                    kind_label = _("Patch"),
                    description = record and record.repo_description or "",
                    badge = has_update and _("Update") or _("✓ Current"),
                    is_entry = true,
                    keep_menu_open = true,
                    is_update_item = true,
                    version_transition = local_ver .. " → " .. remote_display,
                    callback = function()
                        local DetailsDialog = require("storefront_details_dialog")
                        local cached_repo
                        if record then
                            if record.repo_id then
                                cached_repo = Cache.getRepo(record.repo_id)
                            end
                            if not cached_repo and record.owner and record.repo then
                                cached_repo = Cache.getRepoByName(record.owner, record.repo)
                            end
                        end
                        local repo = cached_repo or {
                            name = record and record.repo or patch.filename,
                            owner = record and record.owner or "",
                            full_name = record and record.repo_full_name or "",
                            id = record and record.repo_id or nil,
                            description = record and record.repo_description or "",
                            stars = 0,
                            data = {
                                owner = { login = record and record.owner or "" },
                                default_branch = record and record.branch or "HEAD",
                                stargazers_count = 0,
                            }
                        }
                        local patch_entry = {
                            filename = patch.filename,
                            path = patch.path,
                            display_path = record and record.path or patch.path,
                            download_url = record and record.download_url,
                            branch = record and record.branch or "HEAD",
                            sha = record and record.sha,
                        }
                        local details_dialog = DetailsDialog:new{
                            Storefront = self,
                            repo = repo,
                            patch = patch_entry,
                            kind = "update",
                            update_item = item,
                            default_tab = "release_notes",
                        }
                        details_dialog:show()
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

        self._merged_updates_cache = {
            key = cache_key,
            merged = merged,
        }
        end

        local display_total = #merged
        local page_size = self:calculateDynamicPageSize("Updates")
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
        
        self:ensureUpdatesState()
        local last_check = self.updates_state.last_auto_check or 0
        if os.time() - last_check < 86400 then
            self._updates_checked_this_session = true
            return
        end

        if not NetworkMgr:isWifiOn() then
            -- Skip if wifi is off to avoid annoying prompts
            return
        end

        self._updates_checked_this_session = true
        self.updates_state.last_auto_check = os.time()
        self:saveUpdatesState()

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
                    self:_checkAllUpdatesInternal(plugin_repos)
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
