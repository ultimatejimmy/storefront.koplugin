local DataStorage = require("datastorage")
local InstallStore = require("storefront_installs")
local Cache = require("storefront_cache")
local GitHub = require("storefront_net_github")
local StorefrontSettings = require("storefront_config")
local StorefrontLogger = require("storefront_logger")
local InfoMessage = require("storefront_toast")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local M = {}

local PATCHES_ROOT = DataStorage:getDataDir() .. "/patches"
local G_installed_patches_cache = nil

local function isPatchDisabled(filename)
    if not filename or filename == "" then return false end
    return filename:match("%.disabled$") ~= nil
end

local function extractRepoOwner(repo)
    if not repo then return nil end
    if type(repo.owner) == "string" and repo.owner ~= "" then
        return repo.owner
    elseif type(repo.owner) == "table" and repo.owner.login then
        return tostring(repo.owner.login)
    elseif repo.full_name then
        local owner = repo.full_name:match("^([^/]+)")
        if owner then return owner end
    end
    return nil
end

local function getRepoDefaultBranch(repo)
    if not repo then return "HEAD" end
    if repo.data and repo.data.default_branch and repo.data.default_branch ~= "" then
        return repo.data.default_branch
    end
    if repo.default_branch and repo.default_branch ~= "" then
        return repo.default_branch
    end
    return "HEAD"
end

local function computeFileSha1(filepath)
    if not filepath or filepath == "" then return nil end
    local file = io.open(filepath, "rb")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    if not content then return nil end
    local ok, DataUtils = pcall(require, "datautils")
    if ok and DataUtils and DataUtils.sha1 then
        return DataUtils.sha1(content)
    end
    local ok_hash, Hash = pcall(require, "ffi/sha1")
    if ok_hash and Hash and Hash.sha1 then
        return Hash.sha1(content)
    end
    return nil
end

local function listInstalledPatches()
    local generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    if G_installed_patches_cache and G_installed_patches_cache.generation == generation then
        return G_installed_patches_cache.patches
    end
    local patches = {}
    if lfs.attributes(PATCHES_ROOT, "mode") ~= "directory" then
        return patches
    end
    for entry in lfs.dir(PATCHES_ROOT) do
        if entry ~= "." and entry ~= ".." then
            local is_lua = entry:match("%.lua$")
            local is_disabled = entry:match("%.lua%.disabled$")
            if is_lua or is_disabled then
                local fullpath = PATCHES_ROOT .. "/" .. entry
                local attr = lfs.attributes(fullpath)
                if attr and attr.mode == "file" then
                    table.insert(patches, {
                        filename = entry,
                        path = fullpath,
                        size = attr.size,
                        latest_mtime = attr.modification,
                        disabled = is_disabled,
                    })
                end
            end
        end
    end
    table.sort(patches, function(a, b)
        return (a.filename or "") < (b.filename or "")
    end)
    G_installed_patches_cache = {
        generation = generation,
        patches = patches,
    }
    return patches
end

local function invalidateInstalledPatchesCache()
    G_installed_patches_cache = nil
end

local function getPatchRecordsMap()
    local ok, records = pcall(function()
        return InstallStore.listPatches()
    end)
    if not ok or type(records) ~= "table" then
        return {}
    end
    return records
end

local function buildPatchRecordFields(filename, repo, patch_info, include_sha)
    if not filename or filename == "" or not repo then
        return nil
    end
    local owner = extractRepoOwner(repo)
    local repo_name = repo.name
    local record = {
        filename = filename,
        owner = owner,
        repo = repo_name,
        repo_full_name = repo.full_name or (owner and repo_name and (owner .. "/" .. repo_name)) or repo_name,
        repo_id = repo.repo_id or repo.id,
        repo_description = repo.description,
        branch = (patch_info and patch_info.branch) or getRepoDefaultBranch(repo),
        path = patch_info and patch_info.path,
        download_url = patch_info and patch_info.download_url,
        sha = include_sha and (patch_info and patch_info.sha) or nil,
        matched_at = os.time(),
    }
    return record
end

local function buildPatchSummary(remote_info)
    local installed = listInstalledPatches()
    local records = getPatchRecordsMap()
    local summary = {
        total = #installed,
        tracked = 0,
        unmatched = 0,
        updates = 0,
        data = {},
    }
    for idx, installed_patch in ipairs(installed) do
        local record = records[installed_patch.filename]
        if record and record.owner and record.repo and record.path then
            summary.tracked = summary.tracked + 1
        else
            summary.unmatched = summary.unmatched + 1
        end
        local local_sha = computeFileSha1(installed_patch.path)
        local remote_entry = remote_info and remote_info[installed_patch.filename]
        if (not remote_entry or remote_entry.error) and record and record.owner and record.repo then
            local repo, file_map = Cache.findPatchRepoAndFile(installed_patch.filename)
            if file_map then
                remote_entry = {
                    remote_sha = file_map.sha,
                    download_url = file_map.download_url,
                    is_cached_fallback = true,
                }
            end
        end
        local remote_sha = (remote_entry and remote_entry.remote_sha)
            or (record and record.sha)
        local installed_sha = record and record.sha
        local needs_update = false
        if record and remote_sha then
            if installed_sha then
                needs_update = remote_sha ~= installed_sha
            elseif local_sha then
                needs_update = remote_sha ~= local_sha
            else
                needs_update = true
            end
        end
        if needs_update then
            local p_key = installed_patch.filename
            local r_key = record and record.owner and record.repo and (record.owner .. "/" .. record.repo)
            if (p_key and InstallStore.isAllUpdatesIgnored(p_key))
               or (r_key and InstallStore.isAllUpdatesIgnored(r_key))
               or (record and record.repo and InstallStore.isAllUpdatesIgnored(record.repo)) then
                needs_update = false
            end
        end
        if needs_update then
            summary.updates = summary.updates + 1
        end
        summary.data[#summary.data + 1] = {
            patch = installed_patch,
            record = record,
            remote_entry = remote_entry,
            local_sha = local_sha,
            needs_update = needs_update,
        }
    end
    summary.records = records
    return summary
end

local function fetchPatchEntriesFromGitHub(owner, repo, branch, callback)
    if not owner or not repo then
        if callback then callback(nil, "Missing owner/repo") end
        return
    end
    branch = branch or "HEAD"
    GitHub.fetchRepoTree(owner, repo, branch, function(tree_entries, err)
        if not tree_entries then
            if callback then callback(nil, err or "Tree fetch failed") end
            return
        end
        local patch_files = {}
        for _, entry in ipairs(tree_entries) do
            if entry.type == "blob" and entry.path and entry.path:match("%.lua$") then
                local filename = entry.path:match("([^/]+)$") or entry.path
                local raw_url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo, branch, entry.path)
                table.insert(patch_files, {
                    path = entry.path,
                    filename = filename,
                    branch = branch,
                    sha = entry.sha,
                    size = entry.size or 0,
                    download_url = raw_url,
                })
            end
        end
        table.sort(patch_files, function(a, b)
            return (a.filename or "") < (b.filename or "")
        end)
        if callback then callback(patch_files, nil) end
    end)
end

local function storePatchEntriesForRepo(owner, repo, branch, entries)
    local repo_obj = Cache.getRepoByName(owner, repo)
    if repo_obj and repo_obj.repo_id then
        Cache.storePatchFiles(repo_obj.repo_id, entries, os.time())
    end
end

local function refreshPatchFileListings(owner, repo, branch, callback)
    fetchPatchEntriesFromGitHub(owner, repo, branch, function(entries, err)
        if entries then
            storePatchEntriesForRepo(owner, repo, branch, entries)
        end
        if callback then callback(entries, err) end
    end)
end

local function getPatchEntriesForRepo(owner, repo, branch, callback)
    local repo_obj = Cache.getRepoByName(owner, repo)
    local cached_files
    if repo_obj and repo_obj.repo_id then
        cached_files = Cache.getPatchFiles(repo_obj.repo_id)
    end
    if cached_files and #cached_files > 0 then
        if callback then callback(cached_files, nil) end
        return
    end
    refreshPatchFileListings(owner, repo, branch, callback)
end

function M:init(Storefront)
    Storefront.isPatchDisabled = isPatchDisabled
    Storefront.invalidateInstalledPatchesCache = invalidateInstalledPatchesCache

    function Storefront:listInstalledPatches()
        return listInstalledPatches()
    end

    function Storefront:getPatchRecordsMap()
        return getPatchRecordsMap()
    end

    function Storefront:collectPatchUpdateSummary()
        self:ensurePatchUpdatesState()
        local remote_info = self.patch_updates_state.remote_info or {}
        return buildPatchSummary(remote_info)
    end

    function Storefront:disablePatch(filename)
        if not filename or filename == "" then
            return false
        end
        if filename:match("%.disabled$") then
            return true
        end
        local old_path = PATCHES_ROOT .. "/" .. filename
        local new_path = old_path .. ".disabled"
        local ok, err = os.rename(old_path, new_path)
        if not ok then
            StorefrontLogger.warn("Failed to disable patch:", filename, err)
            return false
        end
        invalidateInstalledPatchesCache()
        return true
    end

    function Storefront:enablePatch(filename)
        if not filename or filename == "" then
            return false
        end
        if not filename:match("%.disabled$") then
            return true
        end
        local old_path = PATCHES_ROOT .. "/" .. filename
        local new_path = old_path:gsub("%.disabled$", "")
        local ok, err = os.rename(old_path, new_path)
        if not ok then
            StorefrontLogger.warn("Failed to enable patch:", filename, err)
            return false
        end
        invalidateInstalledPatchesCache()
        return true
    end

    function Storefront:deletePatch(filename, record)
        if not filename or filename == "" then
            return
        end
        local display_name = filename
        local patch_path = PATCHES_ROOT .. "/" .. filename
        local ok, err = os.remove(patch_path)
        if ok then
            if record then
                InstallStore.removePatch(filename)
            end
            invalidateInstalledPatchesCache()
            if self.patch_updates_menu then
                self:updatePatchUpdatesDialog()
            end
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to delete patch: %s"), tostring(err)),
                timeout = 5,
            })
        end
    end

    function Storefront:checkSinglePatch(record)
        if not record then
            return
        end
        local patch_name = record.filename or record.path or _("patch")
        local copy = util.tableDeepCopy(record)
        copy.filename = record.filename
        copy.owner = record.owner
        copy.repo = record.repo
        copy.path = record.path
        copy.branch = record.branch
        NetworkMgr:runWhenOnline(function()
            if self._refreshPatchUpdatesInternal then
                self:_refreshPatchUpdatesInternal({ copy })
            end
        end)
        UIManager:show(InfoMessage:new{ text = string.format(_("Checking %s…"), patch_name), timeout = 3 })
    end

    function Storefront:updatePatchFromRecord(record)
        if record then
            StorefrontLogger.action(string.format("UPDATE patch starting: filename=%s (repo=%s/%s)", tostring(record.filename), tostring(record.owner), tostring(record.repo)))
        end
        if not record or not record.owner or not record.repo or not record.path then
            UIManager:show(InfoMessage:new{ text = _("Missing repository info for patch update."), timeout = 4 })
            return
        end
        local repo = {
            kind = "patch",
            name = record.repo,
            owner = record.owner,
            full_name = record.repo_full_name or (record.owner .. "/" .. record.repo),
            id = record.repo_id,
            description = record.repo_description,
        }
        local patch_entry = {
            path = record.path,
            filename = record.filename,
            branch = record.branch or "HEAD",
            download_url = record.download_url,
            sha = record.sha,
        }
        local installed_patch = nil
        for _, p in ipairs(listInstalledPatches()) do
            if p.filename == record.filename then
                installed_patch = p
                break
            end
        end
        if not installed_patch then
            UIManager:show(InfoMessage:new{ text = _("Patch file not found locally."), timeout = 4 })
            return
        end
        self.pending_patch_install = {
            mode = "update",
            patch = installed_patch,
        }
        self:installPatchFromRepo(repo, patch_entry)
    end

    function Storefront:startPatchMatchFlow(patch)
        if type(patch) == "string" then
            for _, p in ipairs(listInstalledPatches()) do
                if p.filename == patch then patch = p; break end
            end
            if type(patch) == "string" then patch = nil end
        end
        if not patch then
            UIManager:show(InfoMessage:new{ text = _("Patch file not found."), timeout = 4 })
            return
        end
        local from_patch_updates = self.patch_updates_menu ~= nil
        self.match_context = { kind = "patch", patch = patch, from_patch_updates = from_patch_updates }
        self:ensureBrowserState()
        self.browser_state.kind = "patch"
        self.browser_state.page = 1
        self.browser_state.scroll_offset = nil

        local search_text = patch.filename or patch.path or ""
        if search_text ~= "" then
            while true do
                local before = search_text
                search_text = search_text:gsub("%.[^%.]+$", "")
                if search_text == before then break end
            end
            search_text = search_text:gsub("^%d+%-", "")
            search_text = search_text:gsub("[-_]+", " ")
            search_text = util.trim(search_text)
            self.browser_state.search_text = search_text
        end
        self:saveBrowserState()
        self:closeUpdatesDialog()
        self:closePatchUpdatesDialog()
        UIManager:setDirty(nil, "ui")
        UIManager:show(InfoMessage:new{ text = _("Select a repository patch entry to match with the chosen file."), timeout = 4 })
        self:showBrowser("patch")
    end

    function Storefront:matchPatchWithRepo(patch, repo, patch_entry)
        if type(patch) == "string" then
            for _, p in ipairs(listInstalledPatches()) do
                if p.filename == patch then patch = p; break end
            end
            if type(patch) == "string" then patch = nil end
        end
        if not patch or not repo or not patch_entry then return end
        StorefrontLogger.action(string.format("MATCH patch: %s matched with repo %s", tostring(patch.filename), tostring(repo.full_name or repo.name)))
        local from_patch_updates = self.match_context and self.match_context.kind == "patch" and self.match_context.from_patch_updates
        local record = buildPatchRecordFields(patch.filename, repo, patch_entry, false)
        if not record then
            UIManager:show(InfoMessage:new{ text = _("Unable to store match for patch."), timeout = 4 })
            return
        end
        InstallStore.upsertPatch(patch.filename, record)
        self:updateSinglePatchStatus(patch.filename, record)
        self.match_context = nil
        self:closeBrowserMenu()
        UIManager:setDirty(nil, "ui")
        UIManager:show(InfoMessage:new{ text = string.format(_("Matched %s with %s."), patch.filename, repo.full_name or repo.name or _("repository")), timeout = 5 })
        if from_patch_updates then
            self:showPatchUpdatesDialog()
        end
    end

    function Storefront:promptManualMatchForPatch(patch)
        if type(patch) == "string" then
            for _, p in ipairs(listInstalledPatches()) do
                if p.filename == patch then patch = p; break end
            end
            if type(patch) == "string" then patch = nil end
        end
        if not patch then return end
        local dialog
        dialog = MultiInputDialog:new{
            title = _("Match patch with GitHub repository"),
            fields = {
                { description = _("Repository owner"), text = "", hint = _("e.g., koreader") },
                { description = _("Repository name"), text = "", hint = _("e.g., koreader") },
            },
            buttons = {
                {
                    { text = _("Cancel"), background = Blitbuffer.COLOR_WHITE, callback = function() UIManager:close(dialog) end },
                    {
                        text = _("Match"), background = Blitbuffer.COLOR_WHITE, is_enter_default = true,
                        callback = function()
                            local fields = dialog:getFields()
                            local owner = util.trim(fields[1] or "")
                            local repo_name = util.trim(fields[2] or "")
                            if owner == "" or repo_name == "" then
                                UIManager:show(InfoMessage:new{ text = _("Both owner and repository name are required."), timeout = 3 })
                                return
                            end
                            UIManager:close(dialog)
                            self:verifyAndMatchPatchWithManualRepo(patch, owner, repo_name)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    function Storefront:verifyAndMatchPatchWithManualRepo(patch, owner, repo_name)
        GitHub.fetchRepoInfo(owner, repo_name, function(repo_info, err)
            if not repo_info then
                UIManager:show(InfoMessage:new{ text = string.format(_("Failed to fetch repository '%s/%s': %s"), owner, repo_name, tostring(err or _("not found"))), timeout = 5 })
                return
            end
            local repo = {
                kind = "patch",
                name = repo_info.name or repo_name,
                owner = owner,
                full_name = repo_info.full_name or (owner .. "/" .. repo_name),
                id = repo_info.id,
                description = repo_info.description,
            }
            refreshPatchFileListings(owner, repo.name, repo_info.default_branch or "HEAD", function(patch_entries, fetch_err)
                if not patch_entries or #patch_entries == 0 then
                    UIManager:show(InfoMessage:new{ text = string.format(_("No patch files found in %s/%s."), owner, repo.name), timeout = 5 })
                    return
                end
                if #patch_entries == 1 then
                    self:matchPatchWithRepo(patch, repo, patch_entries[1])
                else
                    self:showPatchSelectionDialog(repo, patch_entries)
                end
            end)
        end)
    end

    function Storefront:showPatchSelectionDialog(repo, patch_entries)
        local is_matching = self.match_context and self.match_context.kind == "patch" and self.match_context.patch
        local buttons = {}
        for _, entry in ipairs(patch_entries) do
            local item = entry
            local label = item.filename
            if item.path and item.path ~= item.filename then
                label = string.format("%s (%s)", item.filename, item.path)
            end
            table.insert(buttons, {
                {
                    text = label, background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        if is_matching then
                            self:matchPatchWithRepo(self.match_context.patch, repo, item)
                        else
                            self:promptPatchAction(repo, item)
                        end
                    end,
                },
            })
        end
        table.insert(buttons, {
            { text = _("Cancel"), background = Blitbuffer.COLOR_WHITE, callback = function() end },
        })
        local dialog = ButtonDialog:new{ title = string.format(_("Select patch in %s"), repo.full_name or repo.name), buttons = buttons }
        UIManager:show(dialog)
    end

    function Storefront:updatePatchRecord(filename, record)
        if not filename or filename == "" or not record then return end
        InstallStore.upsertPatch(filename, record)
        self:updateSinglePatchStatus(filename, record)
    end

    function Storefront:rememberPatchInstall(filename, record)
        if not filename or filename == "" or not record then return end
        InstallStore.upsertPatch(filename, record)
        self:updateSinglePatchStatus(filename, record)
    end

    function Storefront:updateSinglePatchStatus(filename, record)
        if not filename or filename == "" then return end
        self:ensurePatchUpdatesState()
        local remote_info = self.patch_updates_state.remote_info or {}
        local entry = remote_info[filename] or {}
        if record and record.sha then entry.remote_sha = record.sha end
        if record and record.download_url then entry.download_url = record.download_url end
        entry.last_checked = os.time()
        entry.error = nil
        remote_info[filename] = entry
        self.patch_updates_state.remote_info = remote_info
        self:savePatchUpdatesState()
    end

    function Storefront:installPatchFromRepo(repo, patch)
        NetworkMgr:runWhenOnline(function()
            self:_installPatchFromRepoInternal(repo, patch)
        end)
    end

    function Storefront:_installPatchFromRepoInternal(repo, patch)
        local is_batch = (_G.G_storefront_batch_updating == true) or (self.pending_patch_install and self.pending_patch_install.is_batch == true)
        local owner = extractRepoOwner(repo)
        if not owner or not repo.name then
            if not is_batch then
                UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for patch install."), timeout = 4 })
            end
            if self.pending_patch_install and self.pending_patch_install.batch_callback then
                local cb = self.pending_patch_install.batch_callback
                self.pending_patch_install = nil
                cb(false, "Missing repository metadata for patch install")
            end
            return
        end
        local raw_url = patch.download_url or string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo.name, patch.branch or "HEAD", patch.path or patch.filename)
        local target_filename = patch.filename or (patch.path and patch.path:match("([^/]+)$"))
        if not target_filename or target_filename == "" then
            if not is_batch then
                UIManager:show(InfoMessage:new{ text = _("Invalid patch target filename."), timeout = 4 })
            end
            if self.pending_patch_install and self.pending_patch_install.batch_callback then
                local cb = self.pending_patch_install.batch_callback
                self.pending_patch_install = nil
                cb(false, "Invalid patch target filename")
            end
            return
        end
        local ok_dir, err_dir = util.makePath(PATCHES_ROOT)
        if not ok_dir then
            if not is_batch then
                UIManager:show(InfoMessage:new{ text = string.format(_("Failed to create patches directory: %s"), tostring(err_dir)), timeout = 5 })
            end
            if self.pending_patch_install and self.pending_patch_install.batch_callback then
                local cb = self.pending_patch_install.batch_callback
                self.pending_patch_install = nil
                cb(false, tostring(err_dir))
            end
            return
        end
        local target_path = PATCHES_ROOT .. "/" .. target_filename
        local size_str = (patch and patch.size and patch.size > 0)
            and string.format(" (%d KB)", math.floor(patch.size / 1024))
            or ""

        local batch_toast = self.pending_patch_install and self.pending_patch_install.batch_toast
        local dl_msg = string.format(_("Downloading patch %s%s…\nTap screen to cancel."), target_filename, size_str)

        local trap_widget
        if batch_toast then
            if batch_toast.setText then
                batch_toast:setText(dl_msg)
            end
            trap_widget = batch_toast
        else
            local Toast = require("storefront_toast")
            trap_widget = Toast.show(dl_msg, 0)
        end

        local Trapper = require("ui/trapper")
        local completed, res
        Trapper:wrap(function()
            completed, res = Trapper:dismissableRunInSubprocess(function()
                local dl_ok, dl_err = storefront_installer.downloadToFile(raw_url, target_path)
                return { ok = dl_ok, err = dl_err }
            end, trap_widget)
        end)

        if trap_widget and trap_widget ~= batch_toast and trap_widget.close then
            trap_widget:close()
        end

        if not completed then
            util.removeFile(target_path)
            local Toast = require("storefront_toast")
            Toast.show(_("Download cancelled."), 3)
            if self.pending_patch_install and self.pending_patch_install.batch_callback then
                local cb = self.pending_patch_install.batch_callback
                self.pending_patch_install = nil
                cb(false, "Cancelled by user")
            end
            return
        end

        local ok_dl = res and res.ok
        local dl_err = res and res.err

        if not ok_dl then
            util.removeFile(target_path)
            if not is_batch then
                UIManager:show(InfoMessage:new{ text = string.format(_("Failed to download patch: %s"), tostring(dl_err)), timeout = 5 })
            end
            if self.pending_patch_install and self.pending_patch_install.batch_callback then
                local cb = self.pending_patch_install.batch_callback
                self.pending_patch_install = nil
                cb(false, tostring(dl_err))
            end
            return
        end

        local stored_record = buildPatchRecordFields(target_filename, repo, patch, true)
        if stored_record then
            InstallStore.upsertPatch(target_filename, stored_record)
        end
        invalidateInstalledPatchesCache()

        local is_update = self.pending_patch_install and self.pending_patch_install.mode == "update"
        local batch_cb = self.pending_patch_install and self.pending_patch_install.batch_callback
        self.pending_patch_install = nil
        if is_update then
            StorefrontLogger.action(string.format("Updated patch \"%s\".", target_filename))
            if not is_batch and not _G.G_storefront_batch_updating then
                self:showRestartConfirmation(string.format(_("Updated patch \"%s\"."), target_filename))
            end
            if self.patch_updates_menu then
                self:updatePatchUpdatesDialog()
            end
        else
            StorefrontLogger.action(string.format("Installed patch \"%s\".", target_filename))
            if not is_batch and not _G.G_storefront_batch_updating then
                self:showRestartConfirmation(string.format(_("Installed patch \"%s\"."), target_filename))
            end
        end
        if stored_record then
            self:updateSinglePatchStatus(target_filename, stored_record)
        end
        if batch_cb then
            batch_cb(true)
        end
    end

    function Storefront:buildPatchUpdateItems(summary)
        self:ensurePatchUpdatesState()
        summary = summary or self:collectPatchUpdateSummary()
        local entries = {}
        local filter_updates = self.patch_updates_state.filter_only_outdated
        local filter_linked = self.patch_updates_state.filter_only_linked
        for idx, item in ipairs(summary.data or {}) do
            local is_linked = item.record and item.record.owner and item.record.repo
            if ((not filter_updates) or item.needs_update) and ((not filter_linked) or is_linked) then
                local patch = item.patch
                local record = item.record
                local remote_entry = item.remote_entry
                local disabled_label = isPatchDisabled(patch.filename) and "[DISABLED] " or ""
                local lines = {
                    string.format("• %s%s", disabled_label, patch.filename),
                }
                if record and record.owner and record.repo then
                    table.insert(lines, string.format(_("Repo: %s/%s"), record.owner, record.repo))
                else
                    table.insert(lines, _("Repo: (not matched)"))
                end
                if item.needs_update then
                    table.insert(lines, _("Status: Update available"))
                elseif record then
                    table.insert(lines, _("Status: Up to date"))
                else
                    table.insert(lines, _("Status: Needs matching"))
                end
                local text = table.concat(lines, "\n")
                local entry = {
                    text = text,
                    dim = not item.needs_update,
                    is_entry = true,
                    keep_menu_open = true,
                }
                entry.callback = function()
                    if record then
                        self:updatePatchFromRecord(record)
                    else
                        self:startPatchMatchFlow(patch)
                    end
                end
                entries[#entries + 1] = entry
            end
        end
        if #entries == 0 then
            if self.patch_updates_state.filter_only_outdated then
                entries[#entries + 1] = { text = _("No patches need updates."), select_enabled = false }
            else
                entries[#entries + 1] = { text = _("No patches to display."), select_enabled = false }
            end
        end
        return entries
    end
end

M.listInstalledPatches = listInstalledPatches
M.getPatchRecordsMap = getPatchRecordsMap
M.buildPatchRecordFields = buildPatchRecordFields
M.buildPatchSummary = buildPatchSummary
M.computeFileSha1 = computeFileSha1

return M
