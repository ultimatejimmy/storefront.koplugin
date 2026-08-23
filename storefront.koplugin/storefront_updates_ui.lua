local util = require("util")
local InfoMessage = require("storefront_toast")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Cache = require("storefront_cache")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local StorefrontUpdatesUi = {}

function StorefrontUpdatesUi:init(StorefrontClass)
    -- Mixin methods to Storefront class

    function StorefrontClass:buildUpdatesEntries(available_list_height)
        self:ensureUpdatesState()
        self:ensurePatchUpdatesState()

        local InstallStore = require("storefront_installs")
        local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
        local remote_key = self.updates_state and self.updates_state.last_checked
        local patch_remote_key = self.patch_updates_state and self.patch_updates_state.last_checked
        local filter_outdated = self.updates_state and self.updates_state.filter_only_outdated
        -- Search/filter from browser_state is intentionally ignored on the Updates tab;
        -- those fields belong to the catalog tabs and should not suppress update entries.
        local search_text = ""
        local filter_owner = ""
        local filter_min_stars = 0

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
            
            local meta = plugin and plugin.meta
            local fullname = (meta and meta.fullname) or (plugin and plugin.fullname)
            local shortname = (meta and meta.name) or (plugin and (plugin.shortname or plugin.name))
            local display_name = (fullname and fullname ~= "") and fullname or (shortname or (plugin and plugin.dirname and plugin.dirname:gsub("%.koplugin$", "")) or _("plugin"))

            local match_search = true
            if search_text ~= "" then
                local full_lower = (fullname or ""):lower()
                local short_lower = (shortname or (plugin and plugin.dirname) or ""):lower()
                local dir_lower = (plugin and plugin.dirname or ""):lower():gsub("%.koplugin$", "")
                local owner_lower = (record and record.owner or ""):lower()
                local desc_lower = (record and record.repo_description or ""):lower()
                local repo_lower = (record and record.repo or ""):lower()

                if not (full_lower:find(search_text, 1, true)
                     or short_lower:find(search_text, 1, true)
                     or dir_lower:find(search_text, 1, true)
                     or owner_lower:find(search_text, 1, true)
                     or desc_lower:find(search_text, 1, true)
                     or repo_lower:find(search_text, 1, true)) then
                    match_search = false
                end
            end

            if filter_owner ~= "" then
                local owner_lower = (record and record.owner or ""):lower()
                if not owner_lower:find(filter_owner, 1, true) then
                    match_search = false
                end
            end

            if filter_min_stars > 0 then
                local stars = (record and tonumber(record.stars)) or 0
                if stars < filter_min_stars then
                    match_search = false
                end
            end

            -- Strip leading 'v'/'V' so "v2.4.4" displays as "2.4.4" consistently.
            local local_ver = (plugin and plugin.version and tostring(plugin.version):gsub("^[vV]", "")) or _("unknown")
            local remote_ver_raw = remote and (remote.release_tag_name or remote.remote_version)
            local remote_ver = remote_ver_raw and tostring(remote_ver_raw):gsub("^[vV]", "") or nil

            if has_update and match_search then
                local remote_display = remote_ver or _("new")
                
                table.insert(merged, {
                    name = display_name,
                    owner = record and record.owner or "",
                    stars_fmt = record and record.repo_description and "plugin" or "0",
                    updated = "",
                    kind_label = _("Plugin"),
                    description = record and record.repo_description or "",
                    badge = _("Update"),
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
                            name = record and record.repo or (plugin and plugin.dirname or ""),
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
                            update_item = { plugin = plugin, record = record, remote = remote, needs_update = has_update },
                            default_tab = "release_notes",
                            from_updates_tab = true,
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
 
            local patch_name = patch.filename or patch.path or _("patch")
            local match_search = true
            if search_text ~= "" then
                local name_lower = patch_name:lower()
                local owner_lower = (record and record.owner or ""):lower()
                local desc_lower = (record and record.repo_description or ""):lower()
                local repo_lower = (record and record.repo or ""):lower()
                if not (name_lower:find(search_text, 1, true) or owner_lower:find(search_text, 1, true) or desc_lower:find(search_text, 1, true) or repo_lower:find(search_text, 1, true)) then
                    match_search = false
                end
            end

            if filter_owner ~= "" then
                local owner_lower = (record and record.owner or ""):lower()
                if not owner_lower:find(filter_owner, 1, true) then
                    match_search = false
                end
            end

            if has_update and match_search then
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
                            from_updates_tab = true,
                        }
                        details_dialog:show()
                    end,
                })
            end
        end

        -- Sort merged list by name A-Z
        table.sort(merged, function(a, b)
            local aname = tostring(a and a.name or ""):lower()
            local bname = tostring(b and b.name or ""):lower()
            return aname < bname
        end)

        self._merged_updates_cache = {
            key = cache_key,
            merged = merged,
        }
        end

        local items = {}
        if display_total == 0 then
            table.insert(items, {
                text = _("No items found."),
                select_enabled = false,
            })
            table.insert(items, {
                text = _("Clear search/filters"),
                is_clear_button = true,
                callback = function()
                    self:clearSearchAndFilters()
                end,
            })
            return items, 1
        end

        return self:paginateEntries(merged, "Updates", available_list_height)
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
            if not self.browser_menu then
                return
            end

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
            if #plugin_repos > 0 and self.browser_menu then
                pcall(function()
                    self:_checkAllUpdatesInternal(plugin_repos)
                end)
            end
            if #patch_repos > 0 and self.browser_menu then
                pcall(function()
                    self:_refreshPatchUpdatesInternal(patch_repos)
                end)
            end

            if self.browser_menu then
                UIManager:nextTick(function()
                    if self.browser_menu then
                        self:refreshCurrentBrowserTab()
                    end
                end)
            end
        end)
    end
end

return StorefrontUpdatesUi
