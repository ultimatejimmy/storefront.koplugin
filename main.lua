local Device = require("device")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CheckButton = require("ui/widget/checkbutton")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local _ = require("gettext")

local Input = Device.input

local Cache = require("appstore_cache")
local GitHub = require("appstore_net_github")
local RepoContent = require("appstore_repo_content")
local InstallStore = require("appstore_installs")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local socketutil = require("socketutil")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local Archiver = require("ffi/archiver")
local sha2 = require("ffi/sha2")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local logger = require("logger")

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/appstore.lua"
local AppStoreSettings = LuaSettings:open(SETTINGS_PATH)

local STALE_WARNING_SECONDS = 7 * 24 * 3600
local BROWSER_PAGE_SIZE = 14
local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin" fork:true' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches" fork:true' }
local BROWSER_STATE_KEY = "browser_state"
local PATCH_CACHE_TTL = 10 * 60
local DEFAULT_SORT_MODE = "stars_desc"

local PLUGINS_ROOT = DataStorage:getDataDir() .. "/plugins"
local PATCHES_ROOT = DataStorage:getDataDir() .. "/patches"

local AppStore = WidgetContainer:extend{
    name = "appstore",
    is_doc_only = false,
    is_refreshing = false,
    browser_state = nil,
    browser_menu = nil,
    patch_cache = {},
    updates_state = nil,
    updates_menu = nil,
    patch_updates_state = nil,
    patch_updates_menu = nil,
    match_context = nil,
    pending_install_context = nil,
    pending_patch_install = nil,
    readme_filter = nil,
}

local AppStoreListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
}

local AppStoreBrowserDialog

local extractRepoOwner
local ensureCacheDir
local ensurePatchesDir
local downloadToFile
local buildPatchDownloadUrl
local derivePluginRepoPath
local sanitizeMetaPath
local fetchGitHubRaw
local formatTimestamp
local parseGitHubTimestamp
local buildRepoDescriptorFromRecord
local buildBranchCandidates
local getRepoDefaultBranch
local extractMetaField
local getPatchRecordsMap
local extractPluginToUserDir
local extractReleaseNameFallback
local detectPluginFromArchiveWithFallback
local renderReleaseNotesText
local softWrapLongTokens

local function buildPatchRepoDescriptor(record)
    if not record or not record.owner or not record.repo then
        return nil
    end

    local owner = record.owner
    return {
        kind = "patch",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end

softWrapLongTokens = function(text, max_len)
    max_len = tonumber(max_len) or 60
    if not text or text == "" then
        return ""
    end
    text = tostring(text)
    return text:gsub("(%S+)", function(token)
        if #token <= max_len then
            return token
        end
        if token:match("[\128-\255]") then
            return token
        end
        local parts = {}
        local i = 1
        while i <= #token do
            parts[#parts + 1] = token:sub(i, i + max_len - 1)
            i = i + max_len
        end
        return table.concat(parts, "\n")
    end)
end

local function makeScrollableTextBoxForDialog(dialog, text)
    local width = dialog and dialog.getAddedWidgetAvailableWidth and dialog:getAddedWidgetAvailableWidth()
    width = tonumber(width) or math.floor(Device.screen:getWidth() * 0.8)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local scrollbar_slack = 3 * Device.screen:scaleBySize(6)
    local content_width = math.max(width - scrollbar_slack, 200)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end

    local box = TextBoxWidget:new{
        text = text,
        width = math.max(content_width - 2 * Size.padding.default, 160),
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        show_parent = dialog,
        frame,
    }
end
local function makeTextBox(text)
    local args = {
        text = text,
        width = math.floor(Device.screen:getWidth() * 0.8),
    }
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if not face and Font and Font.getFace then
        face = Font:getFace("infofont")
    end
    if face then
        args.face = face
    end
    return TextBoxWidget:new(args)
end

local function makeScrollableTextBox(text)
    local width = math.floor(Device.screen:getWidth() * 0.9)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end
    local box = TextBoxWidget:new{
        text = text,
        width = width - 2 * Size.padding.default,
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        frame,
    }
end

function AppStore:refreshPatchUpdates()
    local records = getPatchRecordsMap()
    local tracked = {}
    local installed = listInstalledPatches()
    local installed_map = {}
    for _, patch in ipairs(installed) do
        if patch.filename then
            installed_map[patch.filename] = true
        end
    end
    for filename, record in pairs(records) do
        if installed_map[filename] and record.owner and record.repo and record.path then
            local copy = util.tableDeepCopy(record)
            copy.filename = filename
            table.insert(tracked, copy)
        end
    end
    if #tracked == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matched patches to check."), timeout = 4 })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Checking patch updates…"),
        timeout = 5,
    })
    NetworkMgr:runWhenOnline(function()
        self:_refreshPatchUpdatesInternal(tracked)
    end)
end

function AppStore:_refreshPatchUpdatesInternal(records)
    records = records or {}
    self:ensurePatchUpdatesState()
    local single_context = self.patch_updates_state.single_check_context
        and self.patch_updates_state.single_check_context.filename
    self.patch_updates_state.single_check_context = nil
    local progress = InfoMessage:new{ text = _("Checking patch updates…"), timeout = 0 }
    UIManager:show(progress)
    UIManager:forceRePaint()
    local remote_info = self.patch_updates_state.remote_info or {}
    local repo_cache = {}

    local function getRepoKey(repo)
        return repo.repo_id or repo.full_name or repo.name
    end

    local function ensureRepoEntries(repo)
        local key = getRepoKey(repo)
        if repo_cache[key] then
            return repo_cache[key].map, repo_cache[key].err
        end
        local entries = self:fetchPatchEntriesFromGitHub(repo)
        local map = {}
        if entries and #entries > 0 then
            for _, entry in ipairs(entries) do
                if entry.path then
                    map[entry.path] = entry
                end
            end
            repo_cache[key] = { map = map }
            return map, nil
        end
        local err = _("Failed to fetch patch list.")
        repo_cache[key] = { map = nil, err = err }
        return nil, err
    end

    for _, record in ipairs(records) do
        local repo = buildPatchRepoDescriptor(record)
        local entry
        local err
        if repo then
            local map
            map, err = ensureRepoEntries(repo)
            if map then
                entry = map[record.path]
                if not entry then
                    err = _("Patch file not found in repository.")
                end
            end
        else
            err = _("Missing repository metadata for patch.")
        end
        remote_info[record.filename] = {
            remote_sha = entry and entry.sha or nil,
            download_url = entry and entry.download_url or record.download_url,
            error = err,
            last_checked = os.time(),
        }
    end

    UIManager:close(progress)
    self.patch_updates_state.remote_info = remote_info

    local summary = self:collectPatchUpdateSummary()
    local summary_tracked = summary.tracked or 0
    local summary_map = {}
    for _, item in ipairs(summary.data or {}) do
        if item.patch and item.patch.filename then
            summary_map[item.patch.filename] = item
        end
    end

    local processed_count = #records
    local processed_updates = 0
    for _, record in ipairs(records) do
        local filename = record and record.filename
        local entry = filename and summary_map[filename]
        if entry and entry.needs_update then
            processed_updates = processed_updates + 1
        end
    end
    local processed_up_to_date = math.max(processed_count - processed_updates, 0)

    local processed_all = processed_count > 0 and processed_count == summary_tracked
    if processed_all then
        self.patch_updates_state.last_checked = os.time()
    end

    local message
    if processed_count == 1 then
        local record = records[1]
        local display = record and (record.filename or record.path) or _("patch")
        if processed_updates == 1 then
            message = string.format(_("%s needs an update."), display)
        else
            message = string.format(_("%s is up to date."), display)
        end
    else
        message = string.format(_("Checked %d patches: %d need updates, %d up to date."), processed_count, processed_updates, processed_up_to_date)
    end

    UIManager:show(InfoMessage:new{ text = message, timeout = 5 })

    if processed_all and self.patch_updates_menu then
        self:showPatchUpdatesDialog()
    elseif single_context and records and records[1] and records[1].filename == single_context then
        if self.patch_updates_menu then
            local scroll = self.patch_updates_menu:getScrollOffset() and self.patch_updates_menu:getScrollOffset()
            self:showPatchUpdatesDialog()
            if scroll then
                self.patch_updates_menu:setScrollOffset(scroll)
            end
        end
    end
end

local function formatPatchRemoteStatus(remote_entry)
    if not remote_entry then
        return _("Remote: (not checked)")
    end
    if remote_entry.error then
        return _("Remote check failed: ") .. tostring(remote_entry.error)
    end
    if remote_entry.remote_sha then
        local sha = remote_entry.remote_sha
        local short = sha and sha:sub(1, 8) or _("unknown")
        local ts = remote_entry.last_checked and formatTimestamp(remote_entry.last_checked)
        if ts then
            return string.format(_("Remote SHA: %s (checked %s)"), short, ts)
        end
        return string.format(_("Remote SHA: %s"), short)
    end
    return _("Remote: (not checked)")
end

local function buildPatchRepoDescriptor(record)
    if not record or not record.owner or not record.repo then
        return nil
    end
    local owner = record.owner
    return {
        kind = "patch",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end

local function buildPatchEntryFromRecord(record)
    if not record or not record.path then
        return nil
    end
    local download_url = record.download_url
        or (record.owner and record.repo and buildPatchDownloadUrl(record.owner, record.repo, record.branch or "HEAD", record.path))
    if not download_url then
        return nil
    end
    return {
        filename = record.filename,
        path = record.path,
        display_path = record.path,
        download_url = download_url,
        branch = record.branch or "HEAD",
        sha = record.sha,
    }
end

local function computeFileSha1(path)
    if not path or path == "" then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content then
        return nil
    end
    local header = string.format("blob %d", #content)
    return sha2.sha1(header .. "\0" .. content)
end

function listInstalledPatches()
    local patches = {}
    if lfs.attributes(PATCHES_ROOT, "mode") ~= "directory" then
        return patches
    end
    for entry in lfs.dir(PATCHES_ROOT) do
        if entry ~= "." and entry ~= ".." and entry:match("%.lua$") then
            local fullpath = PATCHES_ROOT .. "/" .. entry
            local attr = lfs.attributes(fullpath)
            if attr and attr.mode == "file" then
                table.insert(patches, {
                    filename = entry,
                    path = fullpath,
                    size = attr.size,
                    latest_mtime = attr.modification,
                })
            end
        end
    end
    table.sort(patches, function(a, b)
        return (a.filename or "") < (b.filename or "")
    end)
    return patches
end

getPatchRecordsMap = function()
    local ok, records = pcall(function()
        return InstallStore.listPatches()
    end)
    if not ok or type(records) ~= "table" then
        return {}
    end
    return records
end

local function buildPatchRecordFields(filename, repo, patch_info)
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
        sha = patch_info and patch_info.sha,
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
        local remote_sha = (remote_entry and remote_entry.remote_sha)
            or (record and record.sha)
        local needs_update = false
        if record and remote_sha and local_sha then
            needs_update = remote_sha ~= local_sha
        elseif record and remote_sha and not local_sha then
            needs_update = true
        end
        if needs_update then
            summary.updates = summary.updates + 1
        end
        summary.data[#summary.data + 1] = {
            patch = installed_patch,
            record = record,
            local_sha = local_sha,
            remote_sha = remote_sha,
            remote_entry = remote_entry,
            needs_update = needs_update,
        }
    end
    return summary
end

function AppStore:buildPatchUpdateItems(summary)
    self:ensurePatchUpdatesState()
    summary = summary or self:collectPatchUpdateSummary()
    local entries = {}
    local filter_updates = self.patch_updates_state.filter_only_outdated
    for idx, patch_item in ipairs(summary.data or {}) do
        if (not filter_updates) or patch_item.needs_update then
            local patch = patch_item.patch
            local record = patch_item.record
            local remote_entry = patch_item.remote_entry
            local lines = {
                string.format("• %s", patch.filename or patch.path or _("patch")),
            }
            if record and record.owner and record.repo then
                table.insert(lines, string.format(_("Repo: %s/%s"), record.owner, record.repo))
            else
                table.insert(lines, _("Repo: (not matched)"))
            end
            if record and record.path then
                table.insert(lines, string.format(_("Path: %s"), record.path))
            end
            table.insert(lines, formatPatchRemoteStatus(remote_entry))
            if patch_item.needs_update then
                table.insert(lines, _("Status: Update available"))
            elseif record and record.owner and record.repo then
                table.insert(lines, _("Status: Up to date"))
            else
                table.insert(lines, _("Status: Needs matching"))
            end

            local entry = {
                text = table.concat(lines, "\n"),
                dim = not patch_item.needs_update,
                keep_menu_open = true,
            }
            entry.callback = function()
                self:promptPatchUpdateAction(patch_item)
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

buildBranchCandidates = function(record)
    local seen = {}
    local candidates = {}
    local function add(branch)
        if not branch or branch == "" then
            return
        end
        if seen[branch] then
            return
        end
        seen[branch] = true
        table.insert(candidates, branch)
    end

    if record then
        add(record.branch)
    end
    add("HEAD")
    add("main")
    add("master")

    return candidates
end

local function normalizeMetaPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = path:gsub("^/+", "")
    if normalized == "_meta.lua" then
        return normalized
    end
    if normalized:match("/_meta%.lua$") then
        return normalized
    end
    if not normalized:match("%.koplugin$") then
        normalized = normalized .. ".koplugin"
    end
    return normalized .. "/_meta.lua"
end

local function sanitizeMetaPath(path, fallback)
    if path and path ~= "" then
        local normalized = normalizeMetaPath(path)
        if normalized then
            return normalized
        end
    end
    if fallback and fallback ~= "" then
        return normalizeMetaPath(fallback)
    end
end

local function buildMetaPathCandidates(record)
    if not record then
        return {}
    end
    local seen = {}
    local candidates = {}
    local function add(path)
        if not path or path == "" then
            return
        end
        local normalized = normalizeMetaPath(path)
        if not normalized or seen[normalized] then
            return
        end
        seen[normalized] = true
        table.insert(candidates, normalized)
    end

    add(record.meta_path)
    add(record.meta_path_hint)

    if record.meta_path then
        local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end
    if record.meta_path_hint then
        local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end

    if record.dirname and record.dirname ~= "" then
        add(record.dirname .. "/_meta.lua")
        if record.dirname:match("%.koplugin$") then
            local without_suffix = record.dirname:gsub("%.koplugin$", "")
            add(without_suffix .. "/_meta.lua")
        end
    end

    add("_meta.lua")

    return candidates
end

local function formatRemoteStatus(remote)
    if not remote then
        return _("Remote: (not checked)")
    end
    if remote.remote_version then
        local ts = remote.last_checked and formatTimestamp(remote.last_checked)
        if ts then
            return string.format(_("Remote: %s (checked %s)"), remote.remote_version, ts)
        end
        return string.format(_("Remote: %s"), remote.remote_version)
    end
    if remote.error then
        return _("Remote check failed: ") .. tostring(remote.error)
    end
    return _("Remote: (not checked)")
end

local function firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
end

local function isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    if v1_str == v2_str then
        return false
    end

    local function normalizeVersion(v_str)
        local parts = {}
        for part in tostring(v_str):gmatch("([^.-]+)") do
            local num = tonumber(part)
            if num then
                table.insert(parts, num)
            else
                table.insert(parts, 0)
            end
        end
        return parts
    end

    local v1 = normalizeVersion(v1_str)
    local v2 = normalizeVersion(v2_str)
    local max_len = math.max(#v1, #v2)
    for i = 1, max_len do
        local a = v1[i] or 0
        local b = v2[i] or 0
        if a > b then
            return true
        end
        if a < b then
            return false
        end
    end
    return false
end

local function normalizeDescription(value)
    if type(value) ~= "string" then
        return ""
    end
    if value:match("^function:%s*0x%x+$") then
        return ""
    end
    return value
end

local function getRepoOwner(repo)
    if not repo then
        return nil
    end
    if repo.owner and repo.owner ~= "" then
        return repo.owner
    end
    if repo.data and repo.data.owner and repo.data.owner.login then
        return repo.data.owner.login
    end
end

local function getRepoDefaultBranch(repo)
    return (repo and repo.data and repo.data.default_branch)
        or (repo and repo.default_branch)
        or "HEAD"
end

local function buildInstallRecordFields(dirname, plugin_name, installed_version, repo, meta_path)
    if not dirname or dirname == "" then
        return nil
    end
    local owner = getRepoOwner(repo)
    local repo_name = repo and repo.name
    local record = {
        dirname = dirname,
        plugin_name = plugin_name,
        installed_version = installed_version,
        owner = owner,
        repo = repo_name,
        repo_full_name = repo and (repo.full_name or (owner and repo_name and (owner .. "/" .. repo_name))) or nil,
        repo_id = repo and (repo.repo_id or repo.id) or nil,
        repo_description = repo and repo.description or nil,
        branch = getRepoDefaultBranch(repo),
        meta_path = meta_path,
        matched_at = os.time(),
    }
    return record
end

local function getPluginMetaPath(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return string.format("%s/%s/_meta.lua", PLUGINS_ROOT, dirname)
end

local function loadPluginMeta(dirname)
    local meta_path = getPluginMetaPath(dirname)
    if not meta_path or lfs.attributes(meta_path, "mode") ~= "file" then
        return nil
    end
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" then
        return meta
    end
end

local function getPluginDisplayName(meta, dirname)
    if meta and meta.name and meta.name ~= "" then
        return meta.name
    end
    if dirname and dirname ~= "" then
        return dirname:gsub("%.koplugin$", "")
    end
    return "plugin"
end

local function getLatestModificationTimestamp(path)
    if not path or path == "" then
        return 0
    end
    local attr = lfs.attributes(path)
    if not attr then
        return 0
    end
    local latest = attr.modification or 0
    if attr.mode ~= "directory" then
        return latest
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child_path = path .. "/" .. entry
            local child_mtime = getLatestModificationTimestamp(child_path)
            if child_mtime > latest then
                latest = child_mtime
            end
        end
    end
    return latest
end

local function listInstalledPlugins()
    local plugins = {}
    if lfs.attributes(PLUGINS_ROOT, "mode") ~= "directory" then
        return plugins
    end
    for entry in lfs.dir(PLUGINS_ROOT) do
        if entry ~= "." and entry ~= ".." and entry:match("%.koplugin$") then
            local meta = loadPluginMeta(entry)
            local plugin = {
                dirname = entry,
                meta = meta,
                name = getPluginDisplayName(meta, entry),
                version = meta and meta.version or nil,
                path = PLUGINS_ROOT .. "/" .. entry,
                meta_path_hint = entry .. "/_meta.lua",
            }
            plugin.latest_mtime = getLatestModificationTimestamp(plugin.path)
            table.insert(plugins, plugin)
        end
    end
    table.sort(plugins, function(a, b)
        return (a.name or a.dirname) < (b.name or b.dirname)
    end)
    return plugins
end

local function findInstalledPlugin(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    local installed = listInstalledPlugins()
    for _, plugin in ipairs(installed) do
        if plugin.dirname == dirname then
            return plugin
        end
    end
end

local function findInstalledPatch(filename)
    if not filename or filename == "" then
        return nil
    end
    local patches = listInstalledPatches()
    for _, patch in ipairs(patches) do
        if patch.filename == filename then
            return patch
        end
    end
end

local function getInstallRecordsMap()
    local ok, records = pcall(function()
        return InstallStore.list()
    end)
    if not ok or type(records) ~= "table" then
        return {}
    end
    return records
end

function AppStore:ensureUpdatesState()
    if not self.updates_state then
        self.updates_state = {}
    end
    self.updates_state.filter_only_outdated = self.updates_state.filter_only_outdated or false
    self.updates_state.remote_info = self.updates_state.remote_info or {}
end

function AppStore:ensurePatchUpdatesState()
    if not self.patch_updates_state then
        self.patch_updates_state = {}
    end
    self.patch_updates_state.filter_only_outdated = self.patch_updates_state.filter_only_outdated or false
    self.patch_updates_state.remote_info = self.patch_updates_state.remote_info or {}
end

function AppStore:collectPatchUpdateSummary()
    self:ensurePatchUpdatesState()
    return buildPatchSummary(self.patch_updates_state.remote_info)
end

function AppStore:getPatchUpdatesSummaryText(summary)
    summary = summary or self:collectPatchUpdateSummary()
    local parts = {
        string.format(_("Tracked: %d"), summary.tracked or 0),
        string.format(_("Unmatched: %d"), summary.unmatched or 0),
        string.format(_("Needs update: %d"), summary.updates or 0),
    }
    if self.patch_updates_state and self.patch_updates_state.last_checked then
        table.insert(parts, string.format(_("Last check: %s"), formatTimestamp(self.patch_updates_state.last_checked)))
    end
    return table.concat(parts, " • ")
end

function AppStore:collectUpdateSummary()
    self:ensureUpdatesState()
    local records = getInstallRecordsMap()
    local installed = listInstalledPlugins()
    local remote_info = self.updates_state.remote_info or {}
    local data = {}
    local summary = {
        total = #installed,
        tracked = 0,
        unmatched = 0,
        updates = 0,
    }

    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        local tracked = record and record.owner and record.repo
        if tracked then
            summary.tracked = summary.tracked + 1
        else
            summary.unmatched = summary.unmatched + 1
        end

        local remote = remote_info[plugin.dirname]
        local local_version = plugin.version
        local remote_version = remote and remote.remote_version
        local local_latest_ts = plugin.latest_mtime
        if not local_latest_ts or local_latest_ts == 0 then
            local_latest_ts = getLatestModificationTimestamp(plugin.path)
            plugin.latest_mtime = local_latest_ts
        end
        local remote_repo_ts = remote and remote.remote_repo_ts or 0
        local remote_newer_by_date = false
        if tracked and remote_repo_ts and remote_repo_ts > (local_latest_ts or 0) then
            remote_newer_by_date = true
        end
        local has_update = false
        if remote_newer_by_date then
            has_update = true
        elseif tracked and remote_version and local_version then
            has_update = isVersionNewer(remote_version, local_version)
        end
        if has_update then
            summary.updates = summary.updates + 1
        end

        data[#data + 1] = {
            plugin = plugin,
            record = record,
            remote = remote,
            has_update = has_update,
            remote_newer_by_date = remote_newer_by_date,
            remote_repo_ts = remote_repo_ts,
            local_latest_ts = local_latest_ts,
        }
    end

    summary.data = data
    summary.records = records
    return summary
end

function AppStore:getUpdatesSummaryText(summary)
    summary = summary or self:collectUpdateSummary()
    local parts = {
        string.format(_("Tracked: %d"), summary.tracked or 0),
        string.format(_("Unmatched: %d"), summary.unmatched or 0),
        string.format(_("Needs update: %d"), summary.updates or 0),
    }
    if self.updates_state and self.updates_state.last_checked then
        table.insert(parts, string.format(_("Last check: %s"), formatTimestamp(self.updates_state.last_checked)))
    end
    return table.concat(parts, " • ")
end

function AppStore:buildUpdateItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local entries = {}
    local filter_updates = self.updates_state.filter_only_outdated
    for idx, item in ipairs(summary.data or {}) do
        if (not filter_updates) or item.has_update then
            local plugin = item.plugin
            local record = item.record
            local remote = item.remote
            local lines = {
                string.format("• %s (%s)", plugin.name or plugin.dirname, plugin.dirname),
            }

            local local_line = string.format(_("Local: %s"), plugin.version or _("unknown"))
            if remote and remote.remote_version then
                local_line = string.format("%s  %s", local_line, string.format(_("Remote: %s"), remote.remote_version))
            end
            if item.remote_newer_by_date then
                local_line = string.format("%s  %s", local_line, _("Remote newer by files"))
            end
            table.insert(lines, local_line)

            if record and record.owner and record.repo then
                table.insert(lines, string.format(_("Repo: %s/%s"), record.owner, record.repo))
            else
                table.insert(lines, _("Repo: (not matched)"))
            end

            if remote and remote.remote_version then
                table.insert(lines, formatRemoteStatus(remote))
            elseif remote and remote.error then
                table.insert(lines, formatRemoteStatus(remote))
            else
                table.insert(lines, _("Remote: (not checked)"))
            end

            if item.has_update then
                table.insert(lines, _("Status: Update available"))
            elseif record and record.owner and record.repo then
                table.insert(lines, _("Status: Up to date"))
            else
                table.insert(lines, _("Status: Needs matching"))
            end

            local text = table.concat(lines, "\n")
            local entry = {
                text = text,
                dim = not item.has_update,
                keep_menu_open = true,
            }
            entry.callback = function()
                self:promptUpdateAction(plugin, record)
            end
            entries[#entries + 1] = entry
        end
    end

    if #entries == 0 then
        if self.updates_state.filter_only_outdated then
            entries[#entries + 1] = { text = _("No plugins need updates."), select_enabled = false }
        else
            entries[#entries + 1] = { text = _("No plugins to display."), select_enabled = false }
        end
    end

    return entries
end

function AppStore:buildUpdateBrowserItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text = self:getUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        callback = function()
            self:checkAllUpdates()
        end,
    }
    items[#items].separator = true

    local filter_label = self.updates_state.filter_only_outdated and _("Show all plugins") or _("Show only needs update")
    items[#items + 1] = {
        text = filter_label,
        keep_menu_open = true,
        callback = function()
            self:toggleUpdatesFilter()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = "⮤ " .. _("Switch to plugin list"),
        keep_menu_open = true,
        callback = function()
            self:closeUpdatesDialog(true)
            self:showBrowser("plugin")
        end,
    }
    items[#items].separator = true

    local plugin_items = self:buildUpdateItems(summary)
    for _, entry in ipairs(plugin_items) do
        items[#items + 1] = entry
        items[#items].separator = true
    end

    return items
end

function AppStore:buildPatchUpdateBrowserItems(summary)
    self:ensurePatchUpdatesState()
    summary = summary or self:collectPatchUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text = self:getPatchUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        callback = function()
            self:refreshPatchUpdates()
        end,
    }
    items[#items].separator = true

    local filter_label = self.patch_updates_state.filter_only_outdated and _("Show all patches") or _("Show only needs update")
    items[#items + 1] = {
        text = filter_label,
        keep_menu_open = true,
        callback = function()
            self:togglePatchUpdatesFilter()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text ="⮤ " .. _("Switch to patch list"),
        keep_menu_open = true,
        callback = function()
            self:closePatchUpdatesDialog(true)
            self:showBrowser("patch")
        end,
    }
    items[#items].separator = true

    local patch_items = self:buildPatchUpdateItems(summary)
    for _, entry in ipairs(patch_items) do
        items[#items + 1] = entry
        items[#items].separator = true
    end

    return items
end

function AppStore:updateUpdatesDialog()
    if not self.updates_menu then
        return
    end
    if self.updates_menu.getScrollOffset then
        self:ensureUpdatesState()
        self.updates_state.scroll_offset = self.updates_menu:getScrollOffset()
    end
    self:closeUpdatesDialog(true)
    self:showUpdatesDialog()
end

function AppStore:closeUpdatesDialog(skip_scroll_save)
    if self.updates_menu then
        if not skip_scroll_save and self.updates_menu.getScrollOffset then
            self:ensureUpdatesState()
            self.updates_state.scroll_offset = self.updates_menu:getScrollOffset()
        end
        UIManager:close(self.updates_menu)
        self.updates_menu = nil
    end
end

function AppStore:closePatchUpdatesDialog(skip_scroll_save)
    if self.patch_updates_menu then
        if not skip_scroll_save and self.patch_updates_menu.getScrollOffset then
            self:ensurePatchUpdatesState()
            self.patch_updates_state.scroll_offset = self.patch_updates_menu:getScrollOffset()
        end
        UIManager:close(self.patch_updates_menu)
        self.patch_updates_menu = nil
    end
end

function AppStore:showUpdatesDialog()
    self:ensureUpdatesState()
    local summary = self:collectUpdateSummary()
    local entries = self:buildUpdateBrowserItems(summary)
    local dialog = AppStoreBrowserDialog:new{
        title = _("App Store · Plugin updates"),
        items = entries,
        appstore = self,
        page = 1,
        total_pages = 1,
        on_dismiss = function(scroll_offset)
            self.updates_menu = nil
            self:ensureUpdatesState()
            self.updates_state.scroll_offset = scroll_offset
        end,
    }
    self.updates_menu = dialog
    UIManager:show(dialog)
    if self.updates_state.scroll_offset then
        dialog:setScrollOffset(self.updates_state.scroll_offset)
    end
end

function AppStore:showPatchUpdatesDialog()
    self:ensurePatchUpdatesState()
    local prev_scroll = self.patch_updates_state.scroll_offset
    if self.patch_updates_menu and self.patch_updates_menu.getScrollOffset then
        prev_scroll = self.patch_updates_menu:getScrollOffset()
    end
    self.patch_updates_state.scroll_offset = prev_scroll
    self:closePatchUpdatesDialog(true)
    local summary = self:collectPatchUpdateSummary()
    local entries = self:buildPatchUpdateBrowserItems(summary)
    local dialog = AppStoreBrowserDialog:new{
        title = _("App Store · Patch updates"),
        items = entries,
        appstore = self,
        page = 1,
        total_pages = 1,
        on_dismiss = function(scroll_offset)
            self.patch_updates_menu = nil
            self:ensurePatchUpdatesState()
            self.patch_updates_state.scroll_offset = scroll_offset
        end,
    }
    self.patch_updates_menu = dialog
    UIManager:show(dialog)
    if self.patch_updates_state.scroll_offset then
        dialog:setScrollOffset(self.patch_updates_state.scroll_offset)
    end
end

function AppStore:updatePatchUpdatesDialog()
    if not self.patch_updates_menu then
        return
    end
    if self.patch_updates_menu.getScrollOffset then
        self:ensurePatchUpdatesState()
        self.patch_updates_state.scroll_offset = self.patch_updates_menu:getScrollOffset()
    end
    self:closePatchUpdatesDialog(true)
    self:showPatchUpdatesDialog()
end

function AppStore:toggleUpdatesFilter()
    self:ensureUpdatesState()
    self.updates_state.filter_only_outdated = not self.updates_state.filter_only_outdated
    self:updateUpdatesDialog()
end

function AppStore:togglePatchUpdatesFilter()
    self:ensurePatchUpdatesState()
    self.patch_updates_state.filter_only_outdated = not self.patch_updates_state.filter_only_outdated
    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function AppStore:checkAllUpdates()
    local records = getInstallRecordsMap()
    local tracked = {}
    local installed = listInstalledPlugins()
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
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local GitHub = require("appstore_net_github")

        local function parseGitHubTimestampWorker(ts)
            if type(ts) ~= "string" or ts == "" then
                return 0
            end
            local year, month, day, hour, min, sec = ts:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
            if not year then
                return 0
            end
            return os.time{
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec),
            }
        end

        local function fetchGitHubRawWorker(owner, repo_name, branch, path)
            if not owner or not repo_name or not path or path == "" then
                return nil, "Missing repository metadata for remote fetch."
            end
            branch = branch or "HEAD"
            local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo_name, branch, path)
            local response = {}
            local _, code = http.request{
                url = url,
                sink = ltn12.sink.table(response),
                headers = {
                    ["User-Agent"] = "KOReader-AppStore",
                    ["Accept"] = "text/plain",
                },
            }
            code = tonumber(code)
            if code ~= 200 then
                return nil, string.format("HTTP %s", tostring(code))
            end
            return table.concat(response)
        end

        local function extractMetaFieldWorker(source, field)
            if type(source) ~= "string" or source == "" or type(field) ~= "string" then
                return nil
            end
            -- Match lines like: field = "value" or field='value'
            local pattern = field .. "%s*=%s*['\"]([^'\"]+)['\"]"
            return source:match(pattern)
        end

        local function runCheckAllUpdatesWorker(records_worker)
            local result = {}
            for _, record in ipairs(records_worker or {}) do
                local dirname = record.dirname
                local owner = record.owner
                local repo_name = record.repo
                local remote_version
                local remote_repo_ts = 0
                local last_err

                if not owner or not repo_name then
                    last_err = "Missing repository info."
                else
                    local metadata, metadata_err = GitHub.fetchRepoMetadata(owner, repo_name)
                    if metadata and type(metadata) == "table" then
                        -- Prefer pushed_at (last pushed commit, including merged PRs),
                        -- fall back to created_at if missing
                        local ts = metadata.pushed_at or metadata.created_at
                        remote_repo_ts = parseGitHubTimestampWorker(ts)
                    else
                        last_err = metadata_err or last_err
                    end

                    local meta_path = record.meta_path
                    if (not meta_path or meta_path == "") and dirname and dirname ~= "" then
                        meta_path = dirname .. "/_meta.lua"
                    end

                    local branch = record.branch
                    if (not branch or branch == "") and metadata and type(metadata) == "table" then
                        branch = metadata.default_branch or metadata.master_branch or "HEAD"
                    end

                    if meta_path and meta_path ~= "" then
                        local body, err = fetchGitHubRawWorker(owner, repo_name, branch, meta_path)
                        if body then
                            local version = extractMetaFieldWorker(body, "version")
                            if version then
                                remote_version = version
                            else
                                last_err = "Remote version not found."
                            end
                        else
                            last_err = err or last_err or "HTTP error"
                        end
                    else
                        last_err = last_err or "Missing meta path in record."
                    end
                end

                if dirname and dirname ~= "" then
                    result[dirname] = {
                        remote_version = remote_version,
                        remote_repo_ts = remote_repo_ts,
                        error = last_err,
                        last_checked = os.time(),
                    }
                end
            end
            return result
        end

        local info = InfoMessage:new{
            text = _("Checking plugin updates… (tap to cancel)"),
            timeout = 0,
        }
        UIManager:show(info)
        UIManager:forceRePaint()

        local completed, remote_info_result = Trapper:dismissableRunInSubprocess(function()
            return runCheckAllUpdatesWorker(tracked)
        end, info)

        UIManager:close(info)

        if not completed then
            UIManager:show(InfoMessage:new{
                text = _("Update check was cancelled"),
                timeout = 4,
            })
            return
        end

        if type(remote_info_result) ~= "table" then
            UIManager:show(InfoMessage:new{
                text = _("Update check failed."),
                timeout = 4,
            })
            return
        end

        self:ensureUpdatesState()
        local remote_info = self.updates_state.remote_info or {}
        for dirname, data in pairs(remote_info_result) do
            remote_info[dirname] = data
        end
        self.updates_state.remote_info = remote_info
        self.updates_state.last_checked = os.time()
        self:updateUpdatesDialog()

        local summary = self:collectUpdateSummary()
        local tracked_count = summary.tracked or #tracked
        local needs_update = summary.updates or 0
        local up_to_date = math.max(tracked_count - needs_update, 0)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Checked %d plugins: %d need updates, %d up to date."), tracked_count, needs_update, up_to_date),
            timeout = 5,
        })
        UIManager:setDirty(nil, "full")
    end)
end

function AppStore:_checkAllUpdatesInternal(records)
    self:ensureUpdatesState()
    local progress = InfoMessage:new{ text = _("Checking plugin updates…"), timeout = 0 }
    UIManager:show(progress)
    local remote_info = self.updates_state.remote_info or {}
    for _, record in ipairs(records) do
        local remote_version, remote_repo_ts, err = self:fetchRemoteVersionForRecord(record)
        remote_info[record.dirname] = {
            remote_version = remote_version,
            remote_repo_ts = remote_repo_ts,
            error = err,
            last_checked = os.time(),
        }
    end
    UIManager:close(progress)
    self.updates_state.remote_info = remote_info
    self.updates_state.last_checked = os.time()
    self:updateUpdatesDialog()

    local summary = self:collectUpdateSummary()
    local tracked = summary.tracked or #records
    local needs_update = summary.updates or 0
    local up_to_date = math.max(tracked - needs_update, 0)
    UIManager:show(InfoMessage:new{
        text = string.format(_("Checked %d plugins: %d need updates, %d up to date."), tracked, needs_update, up_to_date),
        timeout = 5,
    })
    UIManager:setDirty(nil, "full")
end

function AppStore:fetchRemoteVersionForRecord(record)
    if not record or not record.owner or not record.repo then
        return nil, 0, _("Not matched with a repository.")
    end

    local meta_candidates = buildMetaPathCandidates(record)
    if #meta_candidates == 0 then
        return nil, 0, _("Missing meta path in record.")
    end

    local branch_candidates = buildBranchCandidates(record)
    local last_err
    local remote_repo_ts = 0
    local metadata, metadata_err = GitHub.fetchRepoMetadata(record.owner, record.repo)
    if metadata and type(metadata) == "table" then
        -- Prefer pushed_at (last pushed commit), then created_at
        local ts = metadata.pushed_at or metadata.created_at
        remote_repo_ts = parseGitHubTimestamp(ts)
    else
        last_err = metadata_err or last_err
    end
    for meta_idx, meta_path in ipairs(meta_candidates) do
        for branch_idx, branch in ipairs(branch_candidates) do
            local body, err = fetchGitHubRaw(record.owner, record.repo, branch, meta_path)
            if body then
                local version = extractMetaField(body, "version")
                if version then
                    if record.dirname and (record.meta_path ~= meta_path or record.branch ~= branch) then
                        self:updateInstallRecord(record.dirname, { meta_path = meta_path, branch = branch })
                        record.meta_path = meta_path
                        record.branch = branch
                    end
                    return version, remote_repo_ts, nil
                end
                last_err = _("Remote version not found.")
            else
                last_err = err or _("HTTP error")
                if not (err and tostring(err):find("404", 1, true)) then
                    return nil, remote_repo_ts, last_err
                end
            end
        end
    end

    -- If we only saw 404/not-found style issues, treat this as "no remote version info"
    -- instead of a hard error, so single-plugin checks can report gracefully.
    if last_err then
        local msg = tostring(last_err)
        if msg:find("404", 1, true) or msg == _("Remote version not found.") then
            return nil, remote_repo_ts, nil
        end
    end

    return nil, remote_repo_ts, last_err or _("Remote version not found.")
end

function AppStore:getUnmatchedPlugins()
    local records = getInstallRecordsMap()
    local installed = listInstalledPlugins()
    local unmatched = {}
    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        if not (record and record.owner and record.repo) then
            table.insert(unmatched, plugin)
        end
    end
    return unmatched
end

function AppStore:startMatchFlow()
    local unmatched = self:getUnmatchedPlugins()
    if #unmatched == 0 then
        UIManager:show(InfoMessage:new{ text = _("All plugins are already matched."), timeout = 4 })
        return
    end
    local lines = {}
    for idx, plugin in ipairs(unmatched) do
        lines[#lines + 1] = string.format("%d. %s (%s)", idx, plugin.name or plugin.dirname, plugin.dirname)
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Select plugin to match"),
        description = table.concat(lines, "\n"),
        input_hint = _("Enter plugin number"),
        input_type = "number",
        buttons = {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    if not value or value < 1 or value > #unmatched then
                        UIManager:show(InfoMessage:new{ text = _("Invalid selection."), timeout = 3 })
                        return
                    end
                    UIManager:close(dialog)
                    self:startMatchFlowForPlugin(unmatched[value])
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function AppStore:startMatchFlowForPlugin(plugin)
    if not plugin then
        return
    end
    self.match_context = { kind = "plugin", plugin = plugin }
    self:ensureBrowserState()
    self.browser_state.kind = "plugin"
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:saveBrowserState()
    self:closeUpdatesDialog()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{ text = _("Select a repository to match with the chosen plugin."), timeout = 4 })
    self:showBrowser("plugin")
end

function AppStore:matchPluginWithRepo(plugin, repo)
    if not plugin or not repo then
        return
    end
    local record = buildInstallRecordFields(
        plugin.dirname,
        plugin.name,
        plugin.version,
        repo,
        sanitizeMetaPath(plugin.meta_path_hint or (plugin.dirname .. "/_meta.lua"), plugin.dirname)
    )
    if not record then
        UIManager:show(InfoMessage:new{ text = _("Unable to store match for plugin."), timeout = 4 })
        return
    end
    InstallStore.upsert(plugin.dirname, record)
    self.match_context = nil
    self:closeBrowserMenu()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Matched %s with %s."), plugin.name or plugin.dirname, repo.full_name or repo.name or _("repository")),
        timeout = 5,
    })
    if self.updates_menu then
        self:updateUpdatesDialog()
    else
        self:showUpdatesDialog()
    end
end

function AppStore:promptUpdateAction(plugin, record)
    local lines = {
        string.format("%s (%s)", plugin.name or plugin.dirname, plugin.dirname),
        string.format(_("Local version: %s"), plugin.version or _("unknown")),
    }
    if record and record.owner and record.repo then
        table.insert(lines, string.format(_("Matched repo: %s/%s"), record.owner, record.repo))
    else
        table.insert(lines, _("Not matched with a repository."))
    end
    local info_box
    local other_buttons = {}
    if record and record.owner and record.repo then
        table.insert(other_buttons, {
            text = _("Check this plugin"),
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePlugin(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update plugin"),
            callback = function()
                UIManager:close(info_box)
                self:updatePluginFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Rematch with repo"),
            callback = function()
                UIManager:close(info_box)
                self:startMatchFlowForPlugin(plugin)
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match with repo"),
            callback = function()
                UIManager:close(info_box)
                self:startMatchFlowForPlugin(plugin)
            end,
        })
    end

    info_box = ConfirmBox:new{
        text = plugin.name or plugin.dirname,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons },
    }
    UIManager:show(info_box)
end

function AppStore:promptPatchUpdateAction(patch_item)
    if not patch_item or not patch_item.patch then
        return
    end
    local patch = patch_item.patch
    local record = patch_item.record
    local remote_entry = patch_item.remote_entry
    local lines = {
        string.format("• %s", patch.filename or patch.path or _("patch")),
    }
    if record and record.owner and record.repo then
        table.insert(lines, string.format(_("Matched repo: %s/%s"), record.owner, record.repo))
        if record.path then
            table.insert(lines, string.format(_("Path: %s"), record.path))
        end
        if record.branch then
            table.insert(lines, string.format(_("Branch: %s"), record.branch))
        end
    else
        table.insert(lines, _("Not matched with a repository."))
    end
    if patch_item.local_sha then
        table.insert(lines, string.format(_("Local SHA: %s"), patch_item.local_sha:sub(1, 8)))
    end
    table.insert(lines, formatPatchRemoteStatus(remote_entry))
    if patch_item.needs_update then
        table.insert(lines, _("Status: Update available"))
    elseif record and record.owner and record.repo then
        table.insert(lines, _("Status: Up to date"))
    else
        table.insert(lines, _("Status: Needs matching"))
    end

    local info_box
    local other_buttons = {}
    if record and record.owner and record.repo and record.path then
        table.insert(other_buttons, {
            text = _("Check this patch"),
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePatch(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update patch"),
            callback = function()
                UIManager:close(info_box)
                self:updatePatchFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Rematch with repo"),
            callback = function()
                UIManager:close(info_box)
                self:startPatchMatchFlow(patch)
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match with repo"),
            callback = function()
                UIManager:close(info_box)
                self:startPatchMatchFlow(patch)
            end,
        })
    end

    info_box = ConfirmBox:new{
        text = patch.filename or patch.path or _("Patch"),
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons },
    }
    UIManager:show(info_box)
end

function AppStore:checkSinglePlugin(record)
    if not record then
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:_checkSinglePluginInternal(record)
    end)
end

function AppStore:checkSinglePatch(record)
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
        self:_refreshPatchUpdatesInternal({ copy })
    end)
    UIManager:show(InfoMessage:new{ text = string.format(_("Checking %s…"), patch_name), timeout = 3 })
end

function AppStore:_checkSinglePluginInternal(record)
    self:ensureUpdatesState()
    local plugin_name = record.dirname or _("plugin")
    local progress = InfoMessage:new{ text = string.format(_("Checking %s…"), plugin_name), timeout = 0 }
    UIManager:show(progress)
    local remote_version, remote_repo_ts, err = self:fetchRemoteVersionForRecord(record)
    UIManager:close(progress)
    self.updates_state.remote_info[record.dirname] = {
        remote_version = remote_version,
        remote_repo_ts = remote_repo_ts,
        error = err,
        last_checked = os.time(),
    }
    self:updateUpdatesDialog()

    local message
    local plugin = findInstalledPlugin(record.dirname)
    local display_name = (plugin and (plugin.name or plugin.dirname)) or record.plugin_name or plugin_name
    local installed_version = plugin and plugin.version

    if err then
        message = string.format(_("Failed to check %s: %s"), display_name, err)
    elseif remote_version and installed_version then
        if isVersionNewer(remote_version, installed_version) then
            message = string.format(_("Update available for %s: remote %s, installed %s."), display_name, remote_version, installed_version)
        else
            message = string.format(_("%s is up to date (version %s)."), display_name, installed_version)
        end
    elseif remote_version then
        message = string.format(_("Remote version for %s: %s."), display_name, remote_version)
    else
        message = string.format(_("No remote version info for %s."), display_name)
    end

    if message then
        UIManager:show(InfoMessage:new{ text = message, timeout = 5 })
    end
end

function AppStore:updatePluginFromRecord(record)
    local descriptor = buildRepoDescriptorFromRecord(record)
    if not descriptor then
        UIManager:show(InfoMessage:new{ text = _("Missing repository info for update."), timeout = 4 })
        return
    end
    local plugin = findInstalledPlugin(record.dirname)
    if not plugin then
        UIManager:show(InfoMessage:new{ text = _("Plugin folder not found."), timeout = 4 })
        return
    end
    self.pending_install_context = {
        mode = "update",
        plugin = plugin,
    }
    self:promptPluginInstallOptions(descriptor)
end

function AppStore:updatePatchFromRecord(record)
    if not record or not record.owner or not record.repo or not record.path then
        UIManager:show(InfoMessage:new{ text = _("Missing repository info for patch update."), timeout = 4 })
        return
    end
    local repo = buildPatchRepoDescriptor(record)
    if not repo then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for patch update."), timeout = 4 })
        return
    end
    local patch_entry = buildPatchEntryFromRecord(record)
    if not patch_entry then
        UIManager:show(InfoMessage:new{ text = _("Missing patch file info for update."), timeout = 4 })
        return
    end
    local installed_patch = findInstalledPatch(record.filename)
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

function AppStore:cancelMatchContext()
    self.match_context = nil
end

function AppStore:startPatchMatchFlow(patch)
    if type(patch) == "string" then
        patch = findInstalledPatch(patch)
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
        -- Strip multiple extensions (e.g. ".lua.disabled")
        while true do
            local before = search_text
            search_text = search_text:gsub("%.[^%.]+$", "")
            if search_text == before then
                break
            end
        end
        -- Drop numeric prefix like "2-" or "10-"
        search_text = search_text:gsub("^%d+%-", "")
        -- Replace dashes/underscores with spaces
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

function AppStore:matchPatchWithRepo(patch, repo, patch_entry)
    if type(patch) == "string" then
        patch = findInstalledPatch(patch)
    end
    if not patch or not repo or not patch_entry then
        return
    end
    local from_patch_updates = self.match_context
        and self.match_context.kind == "patch"
        and self.match_context.from_patch_updates
    local record = buildPatchRecordFields(patch.filename, repo, patch_entry)
    if not record then
        UIManager:show(InfoMessage:new{ text = _("Unable to store match for patch."), timeout = 4 })
        return
    end
    InstallStore.upsertPatch(patch.filename, record)
    self.match_context = nil
    self:closeBrowserMenu()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Matched %s with %s."), patch.filename, repo.full_name or repo.name or _("repository")),
        timeout = 5,
    })
    if from_patch_updates then
        self:showPatchUpdatesDialog()
    end
end

local function getRecordedInstall(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return InstallStore.get(dirname)
end

function AppStore:updateInstallRecord(dirname, fields)
    if not dirname or dirname == "" or type(fields) ~= "table" then
        return
    end
    local record = getRecordedInstall(dirname) or { dirname = dirname }
    for key, value in pairs(fields) do
        if value ~= nil then
            record[key] = value
        end
    end
    InstallStore.upsert(dirname, record)
end

function AppStore:updatePatchRecord(filename, fields)
    if not filename or filename == "" or type(fields) ~= "table" then
        return
    end
    local records = getPatchRecordsMap()
    local record = records[filename] or { filename = filename }
    for key, value in pairs(fields) do
        if value ~= nil then
            record[key] = value
        end
    end
    InstallStore.upsertPatch(filename, record)
end

function AppStore:rememberPatchInstall(filename, repo, patch_info)
    if not filename or filename == "" then
        return
    end
    local record = buildPatchRecordFields(filename, repo, patch_info)
    if record then
        InstallStore.upsertPatch(filename, record)
        return record
    end
end

function AppStore:updateSinglePatchStatus(filename, record)
    if not filename or filename == "" then
        return
    end
    record = record or (getPatchRecordsMap()[filename])
    if not record then
        return
    end
    self:ensurePatchUpdatesState()
    local remote_info = self.patch_updates_state.remote_info or {}
    local download_url = record.download_url
        or buildPatchDownloadUrl(record.owner, record.repo, record.branch or "HEAD", record.path)
    remote_info[filename] = {
        remote_sha = record.sha,
        download_url = download_url,
        error = nil,
        last_checked = os.time(),
    }
    self.patch_updates_state.remote_info = remote_info

    if self.patch_updates_menu then
        local scroll = self.patch_updates_menu.getScrollOffset and self.patch_updates_menu:getScrollOffset()
        self:showPatchUpdatesDialog()
        if scroll then
            self.patch_updates_menu:setScrollOffset(scroll)
        end
    end
end

local derivePluginRepoPath

function AppStore:rememberInstall(info, repo)
    if not info or not info.plugin_dirname then
        return
    end
    local meta_path
    if info.plugin_root then
        meta_path = sanitizeMetaPath(derivePluginRepoPath(info.plugin_root), info.plugin_dirname)
    end
    meta_path = meta_path or (info.plugin_dirname .. "/_meta.lua")
    local record = buildInstallRecordFields(
        info.plugin_dirname,
        info.plugin_name,
        info.plugin_version,
        repo,
        meta_path
    )
    if record then
        InstallStore.upsert(info.plugin_dirname, record)
    end
end

derivePluginRepoPath = function(plugin_root)
    if not plugin_root or plugin_root == "" then
        return nil
    end
    local without_root = plugin_root
    local slash = without_root:find("/")
    if slash then
        without_root = without_root:sub(slash + 1)
    end
    if without_root and without_root ~= "" then
        return without_root
    end
    return plugin_root
end

local function normalizeMetaPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = path:gsub("^/+", "")
    if normalized:match("/_meta%.lua$") then
        return normalized
    end
    if not normalized:match("%.koplugin$") then
        normalized = normalized .. ".koplugin"
    end
    return normalized .. "/_meta.lua"
end

local function sanitizeMetaPath(path, fallback)
    if path and path ~= "" then
        local normalized = normalizeMetaPath(path)
        if normalized then
            return normalized
        end
    end
    if fallback and fallback ~= "" then
        return normalizeMetaPath(fallback)
    end
end

fetchGitHubRaw = function(owner, repo_name, branch, path)
    if not owner or not repo_name or not path or path == "" then
        return nil, _("Missing repository metadata for remote fetch.")
    end
    branch = branch or "HEAD"
    local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo_name, branch, path)
    local response = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = {
            ["User-Agent"] = "KOReader-AppStore",
            ["Accept"] = "text/plain",
        },
    }
    code = tonumber(code)
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    return table.concat(response)
end

extractMetaField = function(source, field)
    if type(source) ~= "string" or source == "" or type(field) ~= "string" then
        return nil
    end
    local pattern = field .. "%s*=%s*[%\"']([^%\"']+)[%\"']"
    return source:match(pattern)
end

buildRepoDescriptorFromRecord = function(record)
    if not record or not record.owner or not record.repo then
        return nil
    end
    local owner = record.owner
    return {
        kind = "plugin",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end

local function firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
end

local function isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    if v1_str == v2_str then
        return false
    end

    local function normalizeVersion(v_str)
        local parts = {}
        for part in tostring(v_str):gmatch("([^.-]+)") do
            local num = tonumber(part)
            if num then
                table.insert(parts, num)
            else
                table.insert(parts, 0)
            end
        end
        return parts
    end

    local v1 = normalizeVersion(v1_str)
    local v2 = normalizeVersion(v2_str)
    local max_len = math.max(#v1, #v2)
    for i = 1, max_len do
        local a = v1[i] or 0
        local b = v2[i] or 0
        if a > b then
            return true
        end
        if a < b then
            return false
        end
    end
    return false
end

local function normalizeDescription(value)
    if type(value) ~= "string" then
        return ""
    end
    if value:match("^function:%s*0x%x+$") then
        return ""
    end
    return value
end

function AppStore:resetFiltersForRefresh()
    self:ensureBrowserState()
    self.browser_state.search_text = ""
    self.browser_state.owner = ""
    self.browser_state.min_stars = 0
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self.browser_state.search_in_readme = false
    self.readme_filter = nil
    self:saveBrowserState()
end

function AppStoreListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local content_width = self.width or math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
    local text_color = (entry.dim or entry.select_enabled == false) and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    local face = Font:getFace("smallinfofont")
    local line_height_px = math.floor(face.size * 1.4)
    local max_height = line_height_px * 3
    local text_box = TextBoxWidget:new{
        text = entry.text or "",
        width = content_width - 2 * Size.padding.default,
        face = face,
        fgcolor = text_color,
        alignment = "left",
        justified = false,
        height = max_height,
        height_overflow_show_ellipsis = true,
        height_adjust = true,
    }
    self.frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        text_box,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()

    if entry.callback or entry.hold_callback then
        local tap_range = function()
            return Geom:new{
                x = self.dimen.x,
                y = self.dimen.y,
                w = self.dimen.w,
                h = self.dimen.h,
            }
        end

function AppStore:promptPatchAction(repo, patch)
    local repo_title = repo.full_name or repo.name or _("Repository")
    local details = {
        string.format(_("Patch: %s"), patch.filename),
        string.format(_("Repository: %s"), repo_title),
    }
    if patch.display_path and patch.display_path ~= patch.filename then
        table.insert(details, string.format(_("Path: %s"), patch.display_path))
    end
    table.insert(details, string.format(_("Branch: %s"), patch.branch or "HEAD"))

    local dialog
    local other_buttons
    local is_matching_patch = self.match_context and self.match_context.kind == "patch" and self.match_context.patch
    if is_matching_patch then
        other_buttons = {
            {
                {
                    text = _("Match this remote patch"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self:matchPatchWithRepo(self.match_context.patch, repo, patch)
                    end,
                },
                {
                    text = _("Cancel matching"),
                    callback = function()
                        UIManager:close(dialog)
                        --local had_patch_updates = self.patch_updates_menu ~= nil
                        --self:cancelMatchContext()
                        --UIManager:show(InfoMessage:new{ text = _("Patch matching cancelled."), timeout = 3 })
                        --if had_patch_updates then
                        --    self:showPatchUpdatesDialog()
                        --else
                        --    self:showBrowser("patch")
                        --end
                    end,
                },
            },
        }
    else
        other_buttons = {
            {
                {
                    text = _("Install patch"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self:installPatchFromRepo(repo, patch)
                    end,
                },
                {
                    text = _("View README"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showReadme(repo)
                    end,
                },
            },
        }
    end

    dialog = ConfirmBox:new{
        text = repo_title,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(details, "\n")),
        other_buttons_first = true,
        other_buttons = other_buttons,
    }
    UIManager:show(dialog)
end

function AppStore:installPatchFromRepo(repo, patch)
    NetworkMgr:runWhenOnline(function()
        self:_installPatchFromRepoInternal(repo, patch)
    end)
end

function AppStore:_installPatchFromRepoInternal(repo, patch)
    local owner = extractRepoOwner(repo)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for patch install."), timeout = 4 })
        return
    end
    local url = patch.download_url or buildPatchDownloadUrl(owner, repo.name, patch.branch or "HEAD", patch.path)
    if not url then
        UIManager:show(InfoMessage:new{ text = _("Unable to determine patch download URL."), timeout = 4 })
        return
    end
    local patches_dir, err = ensurePatchesDir()
    if not patches_dir then
        UIManager:show(InfoMessage:new{ text = _("Failed to prepare patches directory."), timeout = 4 })
        return
    end
    local target_path = patches_dir .. "/" .. patch.filename
    local temp_path = target_path .. ".download"
    local progress = InfoMessage:new{ text = _("Downloading patch…"), timeout = 0 }
    UIManager:show(progress)
    local ok, download_err = downloadToFile(url, temp_path)
    UIManager:close(progress)
    if not ok then
        util.removeFile(temp_path)
        UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(download_err), timeout = 6 })
        return
    end
    util.removeFile(target_path)
    local rename_ok, rename_err = os.rename(temp_path, target_path)
    if not rename_ok then
        util.removeFile(temp_path)
        UIManager:show(InfoMessage:new{ text = _("Failed to install patch: ") .. tostring(rename_err), timeout = 6 })
        return
    end
    local stored_record = self:rememberPatchInstall(patch.filename, repo, patch)
    UIManager:show(InfoMessage:new{
        text = string.format(_("Installed patch \"%s\"."), patch.filename),
        timeout = 5,
    })
    if stored_record then
        self:updateSinglePatchStatus(patch.filename, stored_record)
    end
    if self.pending_patch_install then
        local context = self.pending_patch_install
        self.pending_patch_install = nil
        if context.mode == "update" and context.patch then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Updated patch %s."), context.patch.filename or _("patch")),
                timeout = 4,
            })
        end
    end
end
        self.ges_events = {
            AppStoreTap = {
                GestureRange:new{
                    ges = "tap",
                    range = tap_range,
                },
            },
        }
        if entry.hold_callback then
            self.ges_events.AppStoreHold = {
                GestureRange:new{
                    ges = "hold",
                    range = tap_range,
                },
            }
        end
    end
end

function AppStoreListItem:onAppStoreTap()
    if self.dialog then
        self.dialog:onEntryActivated(self.entry)
    end
    return true
end

function AppStoreListItem:onAppStoreHold()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

AppStoreBrowserDialog = InputContainer:extend{
    AppStore = nil,
    title = "",
    items = nil,
    width = nil,
    page = 1,
    total_pages = 1,
    scroll_offset = nil,
    on_prev_page = nil,
    on_next_page = nil,
    on_dismiss = nil,
}

function AppStoreBrowserDialog:init()
    self.show_parent = self
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title,
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local list_group = VerticalGroup:new{}
    local entry_width = self:getListEntryWidth()
    if self.items then
        for idx, entry in ipairs(self.items) do
            local item_widget = AppStoreListItem:new{
                entry = entry,
                width = entry_width,
                dialog = self,
            }
            list_group[#list_group + 1] = item_widget
            if entry.separator and idx < #self.items then
                list_group[#list_group + 1] = LineWidget:new{
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen = Geom:new{ w = entry_width, h = Size.line.thin },
                }
            else
                list_group[#list_group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
            end
        end
    end

    self.list_container = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        list_group,
    }

    local prev_button = Button:new{
        text = _("Previous"),
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            if self.on_prev_page then
                self.on_prev_page()
            end
        end,
    }
    prev_button:enableDisable(self.page > 1)

    local next_button = Button:new{
        text = _("Next"),
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            if self.on_next_page then
                self.on_next_page()
            end
        end,
    }
    next_button:enableDisable(self.page < self.total_pages)

    local page_label = TextWidget:new{
        text = string.format(_("Page %d / %d"), self.page, math.max(1, self.total_pages)),
        face = Font:getFace("smallinfofont"),
    }

    local title_height = self.title_bar:getHeight()
    local footer_height = math.max(prev_button:getSize().h, next_button:getSize().h)
    local vertical_padding = 3 * Size.span.vertical_default
    local body_height = self.screen_h - title_height - footer_height - vertical_padding
    if body_height < math.floor(self.screen_h * 0.5) then
        body_height = math.floor(self.screen_h * 0.5)
    end

    self.list_scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = body_height },
        show_parent = self,
        self.list_container,
    }
    self.cropping_widget = self.list_scroller

    self.footer = HorizontalGroup:new{
        prev_button,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        page_label,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        next_button,
    }

    self.content = VerticalGroup:new{
        self.title_bar,
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.list_scroller,
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.footer,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        dimen = self.dimen:copy(),
        self.content,
    }

    if self.scroll_offset then
        self:setScrollOffset(self.scroll_offset)
    end
end

function AppStoreBrowserDialog:getListEntryWidth()
    local horizontal_reserve = 3 * ScrollableContainer.scroll_bar_width
    local width = self.width - 2 * Size.padding.default - horizontal_reserve
    if width < 0 then
        width = self.width - 2 * Size.padding.default
    end
    return math.max(width, 0)
end

function AppStoreBrowserDialog:onEntryActivated(entry)
    if not entry or entry.select_enabled == false then
        return true
    end
    if entry.callback then
        entry.callback()
    end
    if not entry.keep_menu_open then
        UIManager:close(self)
    end
    return true
end

function AppStoreBrowserDialog:onCloseWidget()
    if self.on_dismiss then
        self.on_dismiss(self:getScrollOffset())
    end
end

function AppStoreBrowserDialog:onClose()
    UIManager:close(self)
    return true
end

function AppStoreBrowserDialog:getScrollOffset()
    if self.list_scroller then
        return self.list_scroller:getScrolledOffset()
    end
end

function AppStoreBrowserDialog:setScrollOffset(offset)
    if offset and self.list_scroller then
        self.list_scroller:setScrolledOffset(offset)
    end
end

function AppStoreBrowserDialog:resetScroll()
    if self.list_scroller then
        self.list_scroller:setScrolledOffset({ x = 0, y = 0 })
    end
end

ensureCacheDir = function()
    local lfs = require("libs/libkoreader-lfs")
    local cache_dir = DataStorage:getDataDir() .. "/cache/appstore"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    return cache_dir
end

function AppStore:promptPluginInstallOptions(repo)
    if not repo then
        return
    end

    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for installation."), timeout = 4 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching release info…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local release, release_err = GitHub.fetchLatestRelease(owner, repo.name)

        UIManager:close(progress)

        local dialog
        local buttons = {}

        table.insert(buttons, {
            text = _("Direct download from repo"),
            callback = function()
                UIManager:close(dialog)
                self:installPluginFromRepo(repo)
            end,
        })

        local assets = release and release.assets
        if type(assets) == "table" then
            for _, asset in ipairs(assets) do
                local name = asset and asset.name
                local url = asset and asset.browser_download_url
                local is_source = name and (name:match("^Source code") ~= nil)
                if name and url and not is_source then
                    table.insert(buttons, {
                        text = name,
                        callback = function()
                            UIManager:close(dialog)
                            self:installPluginFromReleaseAsset(repo, release, asset)
                        end,
                    })
                end
            end
        end

        local show_notes = release ~= nil
        if show_notes then
            table.insert(buttons, {
                text = _("View release notes"),
                callback = function()
                    UIManager:close(dialog)
                    local notes_dialog = ConfirmBox:new{
                        text = _("Release notes"),
                        cancel_text = _("Close"),
                        no_ok_button = true,
                    }
                    notes_dialog:addWidget(makeScrollableTextBoxForDialog(notes_dialog, renderReleaseNotesText(repo, release)))
                    UIManager:show(notes_dialog)
                end,
            })
        end

        if release_err and #buttons == 1 then
            UIManager:show(InfoMessage:new{ text = _("Could not fetch latest release. You can still use direct repo download."), timeout = 6 })
        elseif #buttons == 1 then
            UIManager:show(InfoMessage:new{ text = _("No release assets found. You can still use direct repo download."), timeout = 5 })
        end

        local button_rows = {}
        for _, button in ipairs(buttons) do
            table.insert(button_rows, { button })
        end

        dialog = ConfirmBox:new{
            text = _("Download options"),
            cancel_text = _("Cancel"),
            no_ok_button = true,
            other_buttons = button_rows,
        }
        UIManager:show(dialog)
    end)
end

function AppStore:installPluginFromReleaseAsset(repo, release, asset)
    if not repo or not asset then
        return
    end

    local url = asset.browser_download_url
    if not url or url == "" then
        UIManager:show(InfoMessage:new{ text = _("Missing download URL for release asset."), timeout = 4 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local cache_dir = ensureCacheDir()
        local downloads_dir = cache_dir .. "/downloads"
        if lfs.attributes(downloads_dir, "mode") ~= "directory" then
            lfs.mkdir(downloads_dir)
        end

        local safe_name = tostring(asset.name or (repo.name .. "-asset.zip")):gsub("[^%w_%-%.]", "_")
        local zip_path = string.format("%s/%s-%d.zip", downloads_dir, safe_name, os.time())

        local progress = InfoMessage:new{ text = _("Downloading release asset…"), timeout = 0 }
        UIManager:show(progress)
        local ok, err = downloadToFile(url, zip_path)
        UIManager:close(progress)
        if not ok then
            util.removeFile(zip_path)
            UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(err), timeout = 6 })
            return
        end

        local reader = Archiver.Reader:new()
        if not reader:open(zip_path) then
            util.removeFile(zip_path)
            UIManager:show(InfoMessage:new{ text = _("Failed to open downloaded archive."), timeout = 6 })
            return
        end

        local info, detect_err = detectPluginFromArchiveWithFallback(reader, repo, release, asset)
        if not info then
            reader:close()
            util.removeFile(zip_path)
            UIManager:show(InfoMessage:new{ text = detect_err or _("Could not detect plugin inside archive."), timeout = 6 })
            return
        end

        if self.pending_install_context and self.pending_install_context.mode == "update" then
            local ctx_plugin = self.pending_install_context.plugin
            if ctx_plugin and ctx_plugin.dirname and ctx_plugin.dirname ~= "" then
                info.plugin_dirname = ctx_plugin.dirname
            end
        end

        local install_progress = InfoMessage:new{ text = _("Installing plugin…"), timeout = 0 }
        UIManager:show(install_progress)
        local ok_extract, dest_or_err = extractPluginToUserDir(reader, info)
        reader:close()
        util.removeFile(zip_path)

        if not ok_extract then
            UIManager:show(InfoMessage:new{ text = _("Installation failed: ") .. tostring(dest_or_err), timeout = 6 })
            return
        end

        local msg
        if info.plugin_version and info.plugin_version ~= "" then
            msg = string.format(_("Installed plugin \"%s\" (version %s). Restart KOReader to load it."), info.plugin_name, info.plugin_version)
        else
            msg = string.format(_("Installed plugin \"%s\". Restart KOReader to load it."), info.plugin_name)
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 8 })

        self:handlePostInstall(info, repo)
        if self.updates_menu then
            self:updateUpdatesDialog()
        end
    end)
end

local function sanitizePluginDirname(name)
    name = name or "plugin"
    name = util.trim(name)
    if name == "" then
        name = "plugin"
    end
    name = name:gsub("[^%w_%-%.]", "_")
    if not name:match("%.koplugin$") then
        name = name .. ".koplugin"
    end
    return name
end

extractReleaseNameFallback = function(repo, release, asset, meta_source)
    local repo_name = repo and repo.name
    local asset_name = asset and asset.name
    local plugin_name
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
    end

    local asset_plugin_dir = asset_name and asset_name:match("([%w_%-%.]+%.koplugin)%.zip$")
    if asset_plugin_dir then
        return asset_plugin_dir
    end

    local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
    if repo_is_plugin_dir then
        return repo_name
    end

    if repo_name and repo_name:match("^[%w_%-%.]+$") then
        return repo_name .. ".koplugin"
    end

    if plugin_name and plugin_name ~= "" then
        return sanitizePluginDirname(plugin_name)
    end

    return sanitizePluginDirname("plugin")
end

local function truncateText(text, max_len)
    max_len = max_len or 140
    if not text or text == "" then
        return ""
    end
    local trimmed = util.trim(text)
    if #trimmed <= max_len then
        return trimmed
    end
    return trimmed:sub(1, max_len - 1) .. "…"
end

formatTimestamp = function(ts)
    if not ts or ts <= 0 then
        return _("Never")
    end
    return os.date("%Y-%m-%d %H:%M", ts)
end

local function isPatchFilename(filename)
    if not filename or filename == "" then
        return false
    end
    return filename:match("^%d+%-.+%.lua$") ~= nil
end

local function buildPatchDownloadUrl(owner, repo_name, branch, path)
    if not owner or not repo_name or not path then
        return nil
    end
    branch = branch or "HEAD"
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s",
        owner,
        repo_name,
        branch,
        path
    )
end

ensurePatchesDir = function()
    local dir = DataStorage:getDataDir() .. "/patches"
    local ok, err = util.makePath(dir)
    if not ok then
        logger.warn("AppStore patches dir create failed", err)
        return nil, err or "mkdir"
    end
    return dir
end

extractRepoOwner = function(repo)
    if repo.owner and repo.owner ~= "" then
        return repo.owner
    end
    if repo.data and repo.data.owner and repo.data.owner.login then
        return repo.data.owner.login
    end
end

local function normalizedLower(value)
    if not value then
        return ""
    end
    if type(value) ~= "string" then
        value = tostring(value)
    end
    local trimmed = util.trim(value)
    if trimmed == "" then
        return ""
    end
    if util.lower then
        return util.lower(trimmed)
    end
    return trimmed:lower()
end

local function extractSearchTerms(search)
    if not search or search == "" then
        return nil
    end
    local normalized = normalizedLower(search)
    if normalized == "" then
        return nil
    end
    local terms = {}
    for term in normalized:gmatch("%S+") do
        terms[#terms + 1] = term
    end
    if #terms == 0 then
        return nil
    end
    return terms
end

function AppStore:repoMatchesSearch(repo, search)
    local terms = extractSearchTerms(search)
    if not terms then
        return true
    end
    local haystacks = {}
    local function addField(value)
        local normalized = normalizedLower(value)
        if normalized ~= "" then
            haystacks[#haystacks + 1] = normalized
        end
    end
    addField(repo.full_name)
    addField(repo.name)
    addField(repo.description)
    addField(repo.language)
    if repo.data and type(repo.data.topics) == "table" then
        for _, topic in ipairs(repo.data.topics) do
            addField(topic)
        end
    end
    if #haystacks == 0 then
        return false
    end
    for _, term in ipairs(terms) do
        local matched = false
        for _, hay in ipairs(haystacks) do
            if hay:find(term, 1, true) then
                matched = true
                break
            end
        end
        if not matched then
            return false
        end
    end
    return true
end

function AppStore:patchMatchesSearch(patch, search)
    local terms = extractSearchTerms(search)
    if not terms then
        return true
    end
    local haystacks = {}
    local function addField(value)
        local normalized = normalizedLower(value)
        if normalized ~= "" then
            haystacks[#haystacks + 1] = normalized
        end
    end
    addField(patch.filename)
    addField(patch.display_path)
    addField(patch.path)
    if #haystacks == 0 then
        return false
    end
    for _, term in ipairs(terms) do
        local matched = false
        for _, hay in ipairs(haystacks) do
            if hay:find(term, 1, true) then
                matched = true
                break
            end
        end
        if not matched then
            return false
        end
    end
    return true
end

function AppStore:repoHasMatchingPatch(repo, search)
    if not search or search == "" then
        return true
    end
    local patches = self:getPatchEntriesForRepo(repo)
    for _, patch in ipairs(patches) do
        if self:patchMatchesSearch(patch, search) then
            return true
        end
    end
    return false
end

parseGitHubTimestamp = function(value)
    if type(value) ~= "string" then
        return 0
    end
    local year, month, day, hour, min, sec = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return 0
    end
    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    }) or 0
end

local function repoStarsValue(repo)
    return tonumber(repo.stars)
        or (repo.data and tonumber(repo.data.stargazers_count))
        or 0
end

local function repoUpdatedValue(repo)
    -- For ordering, only consider pushed_at (last pushed commit).
    -- Repos with no pushes get value 0 and sink to the bottom.
    if repo.data and repo.data.pushed_at then
        return parseGitHubTimestamp(repo.data.pushed_at)
    end
    return 0
end

local function repoCreatedValue(repo)
    if repo.data and repo.data.created_at then
        return parseGitHubTimestamp(repo.data.created_at)
    end
    return 0
end

local function repoNameKey(repo)
    return normalizedLower(repo.name or repo.full_name or "")
end

local function patchNameKey(entry)
    return normalizedLower(entry.patch and entry.patch.filename or "")
end

local function compareRepoStarsDesc(a, b)
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    local ua = repoUpdatedValue(a)
    local ub = repoUpdatedValue(b)
    if ua ~= ub then
        return ua > ub
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function compareRepoUpdatedDesc(a, b)
    local ua = repoUpdatedValue(a)
    local ub = repoUpdatedValue(b)
    if ua ~= ub then
        return ua > ub
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function compareRepoNameAsc(a, b)
    local na = repoNameKey(a)
    local nb = repoNameKey(b)
    if na ~= nb then
        return na < nb
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoUpdatedValue(a) > repoUpdatedValue(b)
end

local function compareRepoCreatedDesc(a, b)
    local ca = repoCreatedValue(a)
    local cb = repoCreatedValue(b)
    if ca ~= cb then
        return ca > cb
    end
    local sa = repoStarsValue(a)
    local sb = repoStarsValue(b)
    if sa ~= sb then
        return sa > sb
    end
    return repoNameKey(a) < repoNameKey(b)
end

local function comparePatchStarsDesc(a, b)
    if a.stars ~= b.stars then
        return a.stars > b.stars
    end
    local na = repoNameKey(a.repo)
    local nb = repoNameKey(b.repo)
    if na ~= nb then
        return na < nb
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchUpdatedDesc(a, b)
    local ua = repoUpdatedValue(a.repo)
    local ub = repoUpdatedValue(b.repo)
    if ua ~= ub then
        return ua > ub
    end
    if a.stars ~= b.stars then
        return a.stars > b.stars
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchNameAsc(a, b)
    local na = repoNameKey(a.repo)
    local nb = repoNameKey(b.repo)
    if na ~= nb then
        return na < nb
    end
    return patchNameKey(a) < patchNameKey(b)
end

local function comparePatchRepoCreatedDesc(a, b)
    local ca = repoCreatedValue(a.repo)
    local cb = repoCreatedValue(b.repo)
    if ca ~= cb then
        return ca > cb
    end
    return comparePatchStarsDesc(a, b)
end

local SORT_OPTIONS = {
    {
        id = "stars_desc",
        summary = _("Sort: Stars (high → low)"),
        repo_comparator = compareRepoStarsDesc,
        patch_comparator = comparePatchStarsDesc,
    },
    {
        id = "updated_desc",
        summary = _("Sort: Recently updated"),
        repo_comparator = compareRepoUpdatedDesc,
        patch_comparator = comparePatchUpdatedDesc,
    },
    {
        id = "name_asc",
        summary = _("Sort: Name (A → Z)"),
        repo_comparator = compareRepoNameAsc,
        patch_comparator = comparePatchNameAsc,
    },
    {
        id = "created_desc",
        summary = _("Sort: New"),
        repo_comparator = compareRepoCreatedDesc,
        patch_comparator = comparePatchRepoCreatedDesc,
    },
}

local SORT_OPTION_LOOKUP = {}
for _, option in ipairs(SORT_OPTIONS) do
    SORT_OPTION_LOOKUP[option.id] = option
end

function AppStore:getSortOption(mode)
    return SORT_OPTION_LOOKUP[mode] or SORT_OPTION_LOOKUP[DEFAULT_SORT_MODE]
end

function AppStore:getSortSummary()
    local option = self:getSortOption(self.browser_state.sort_mode)
    return option and option.summary or ""
end

function AppStore:advanceSortMode()
    local current = self.browser_state.sort_mode or DEFAULT_SORT_MODE
    local next_index = 1
    for idx, option in ipairs(SORT_OPTIONS) do
        if option.id == current then
            next_index = idx % #SORT_OPTIONS + 1
            break
        end
    end
    self.browser_state.sort_mode = SORT_OPTIONS[next_index].id
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:saveBrowserState()
    self:reopenBrowser()
end

function AppStore:sortRepoList(list)
    if not list or #list <= 1 then
        return
    end
    local option = self:getSortOption(self.browser_state.sort_mode)
    local comparator = option and option.repo_comparator or compareRepoStarsDesc
    table.sort(list, comparator)
end

function AppStore:sortPatchEntries(entries)
    if not entries or #entries <= 1 then
        return entries
    end
    local option = self:getSortOption(self.browser_state.sort_mode)
    local comparator = option and option.patch_comparator or comparePatchStarsDesc
    table.sort(entries, comparator)
    return entries
end

local function normalizeScrollOffset(offset)
    if type(offset) ~= "table" then
        return nil
    end
    local x = tonumber(offset.x)
    local y = tonumber(offset.y)
    if not x or not y then
        return nil
    end
    return { x = x, y = y }
end

function AppStore:loadBrowserStateFromSettings()
    if self._browser_state_loaded then
        return
    end
    self._browser_state_loaded = true
    local encoded = AppStoreSettings:readSetting(BROWSER_STATE_KEY)
    if type(encoded) ~= "string" or encoded == "" then
        return
    end
    local ok, decoded = pcall(json.decode, encoded)
    if not ok or type(decoded) ~= "table" then
        return
    end
    self.browser_state = {
        kind = decoded.kind == "patch" and "patch" or "plugin",
        search_text = decoded.search_text or "",
        owner = decoded.owner or "",
        min_stars = tonumber(decoded.min_stars) or 0,
        page = math.max(1, tonumber(decoded.page) or 1),
        scroll_offset = normalizeScrollOffset(decoded.scroll_offset),
        sort_mode = decoded.sort_mode or DEFAULT_SORT_MODE,
        search_in_readme = decoded.search_in_readme == true,
    }
end

function AppStore:saveBrowserState()
    if not self.browser_state then
        return
    end
    local state = {
        kind = self.browser_state.kind == "patch" and "patch" or "plugin",
        search_text = self.browser_state.search_text or "",
        owner = self.browser_state.owner or "",
        min_stars = tonumber(self.browser_state.min_stars) or 0,
        page = math.max(1, tonumber(self.browser_state.page) or 1),
        scroll_offset = normalizeScrollOffset(self.browser_state.scroll_offset),
        sort_mode = self.browser_state.sort_mode or DEFAULT_SORT_MODE,
        search_in_readme = self.browser_state.search_in_readme == true,
    }
    self.browser_state.scroll_offset = state.scroll_offset
    local ok, encoded = pcall(json.encode, state)
    if ok then
        AppStoreSettings:saveSetting(BROWSER_STATE_KEY, encoded)
        AppStoreSettings:flush()
    end
end

function AppStore:ensureBrowserState()
    if not self.browser_state then
        self:loadBrowserStateFromSettings()
    end
    if not self.browser_state then
        self.browser_state = {
            kind = "plugin",
            search_text = "",
            owner = "",
            min_stars = 0,
            page = 1,
            scroll_offset = nil,
            sort_mode = DEFAULT_SORT_MODE,
            search_in_readme = false,
        }
        self:saveBrowserState()
        return
    end
    self.browser_state.kind = self.browser_state.kind == "patch" and "patch" or "plugin"
    if type(self.browser_state.search_text) ~= "string" then
        self.browser_state.search_text = ""
    end
    if type(self.browser_state.owner) ~= "string" then
        self.browser_state.owner = ""
    end
    self.browser_state.min_stars = tonumber(self.browser_state.min_stars) or 0
    self.browser_state.page = math.max(1, tonumber(self.browser_state.page) or 1)
    self.browser_state.scroll_offset = normalizeScrollOffset(self.browser_state.scroll_offset)
    if type(self.browser_state.sort_mode) ~= "string" or not SORT_OPTION_LOOKUP[self.browser_state.sort_mode] then
        self.browser_state.sort_mode = DEFAULT_SORT_MODE
    end
    if type(self.browser_state.search_in_readme) ~= "boolean" then
        self.browser_state.search_in_readme = false
    end
end

function AppStore:updateReadmeFilter()
    self.readme_filter = nil
    self:ensureBrowserState()
    local kind = self.browser_state.kind or "plugin"
    local search_text = self.browser_state.search_text or ""
    if not self.browser_state.search_in_readme then
        return
    end
    if search_text == "" then
        return
    end

    local matches = {}

    local function addMatchesFromQuery(query)
        local per_page = 100
        local sort = "stars"
        local order = "desc"
        local page = 1
        while true do
            local request_opts = {
                q = query,
                per_page = per_page,
                sort = sort,
                order = order,
                page = page,
            }
            local response, err = GitHub.searchRepositories(request_opts)
            if not response then
                local body = err and err.body or err
                logger.warn("AppStore README search error", query, body)
                return false
            end
            local items = response.items or {}
            if #items == 0 then
                break
            end
            for _, repo in ipairs(items) do
                if type(repo) == "table" then
                    local key = repo.full_name or repo.name
                    if not key and repo.owner and repo.name then
                        local owner = repo.owner.login or repo.owner
                        if owner and owner ~= "" then
                            key = tostring(owner) .. "/" .. tostring(repo.name)
                        end
                    end
                    if key and key ~= "" then
                        matches[tostring(key)] = true
                    end
                end
            end
            if #items < per_page then
                break
            end
            page = page + 1
        end
        return true
    end

    local base = search_text .. " in:readme,description"
    local queries = {}
    if kind == "plugin" then
        table.insert(queries, base .. " topic:koreader-plugin")
        table.insert(queries, base .. " in:name \".koplugin\"")
    elseif kind == "patch" then
        table.insert(queries, base .. " topic:koreader-user-patch")
        table.insert(queries, base .. " in:name \"KOReader.patches\"")
    else
        return
    end

    local any_ok = false
    for _, q in ipairs(queries) do
        local ok = addMatchesFromQuery(q)
        if ok then
            any_ok = true
        end
    end

    if not any_ok then
        -- Leave readme_filter as nil to fall back to local-only behavior.
        return
    end

    self.readme_filter = {
        kind = kind,
        search = search_text,
        matches = matches,
    }
end

function AppStore:getOwners(kind)
    local descriptors = self:getRepoDescriptors(kind)
    local seen = {}
    local owners = {}
    for _, repo in ipairs(descriptors) do
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if owner and owner ~= "" then
            if not seen[owner] then
                seen[owner] = true
                table.insert(owners, owner)
            end
        end
    end
    table.sort(owners, function(a, b)
        return a:lower() < b:lower()
    end)
    return owners
end

function AppStore:matchesGeneralFilters(repo, filters)
    filters = filters or self.browser_state or {}
    local owner_filter = normalizedLower(filters.owner)
    if owner_filter ~= "" then
        local owner_value = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        owner_value = normalizedLower(owner_value)
        if owner_value == "" or not owner_value:find(owner_filter, 1, true) then
            return false
        end
    end

    local min_stars = tonumber(filters.min_stars) or 0
    if min_stars > 0 then
        local stars = tonumber(repo.stars) or 0
        if stars < min_stars then
            return false
        end
    end

    return true
end

function AppStore:descriptorMatches(repo, filters)
    if not self:matchesGeneralFilters(repo, filters) then
        return false
    end
    local search = normalizedLower(filters.search_text)
    if search ~= "" then
        return self:repoMatchesSearch(repo, search)
    end
    return true
end

function AppStore:getFilteredDescriptors(kind)
    self:ensureBrowserState()
    local descriptors = self:getRepoDescriptors(kind)
    local filtered = {}
    local search = normalizedLower(self.browser_state.search_text)
    local search_active = search ~= ""
    for _, repo in ipairs(descriptors) do
        if kind == "patch" then
            if self:matchesGeneralFilters(repo, self.browser_state) then
                local repo_match = (not search_active) or self:repoMatchesSearch(repo, search)
                local patch_match = search_active and not repo_match and self:repoHasMatchingPatch(repo, search)

                local remote_match = false
                local rf = self.readme_filter
                if rf and rf.kind == "patch" and rf.matches and self.browser_state.search_in_readme and search_active then
                    local key = repo.full_name
                    if not key then
                        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                        if owner and repo.name then
                            key = tostring(owner) .. "/" .. tostring(repo.name)
                        else
                            key = repo.name
                        end
                    end
                    if key and rf.matches[tostring(key)] then
                        remote_match = true
                    end
                end

                if repo_match or patch_match or remote_match then
                    table.insert(filtered, repo)
                end
            end
        else
            local passes_general = self:matchesGeneralFilters(repo, self.browser_state)
            if passes_general then
                local local_match
                if search_active then
                    local_match = self:repoMatchesSearch(repo, search)
                else
                    local_match = true
                end

                local remote_match = false
                local rf = self.readme_filter
                if rf and rf.kind == "plugin" and rf.matches and self.browser_state.search_in_readme and search_active then
                    local key = repo.full_name
                    if not key then
                        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                        if owner and repo.name then
                            key = tostring(owner) .. "/" .. tostring(repo.name)
                        else
                            key = repo.name
                        end
                    end
                    if key and rf.matches[tostring(key)] then
                        remote_match = true
                    end
                end

                if local_match or remote_match then
                    table.insert(filtered, repo)
                end
            end
        end
    end
    self:sortRepoList(filtered)
    return filtered, #descriptors
end

function AppStore:getFilterSummary()
    self:ensureBrowserState()
    local filters = self.browser_state
    local parts = {}
    if filters.search_text and filters.search_text ~= "" then
        table.insert(parts, string.format(_([[Search "%s"]]), filters.search_text))
    end
    if filters.owner and filters.owner ~= "" then
        table.insert(parts, string.format(_([[Owner %s]]), filters.owner))
    end
    local stars = tonumber(filters.min_stars) or 0
    if stars > 0 then
        table.insert(parts, string.format(_([[≥ %s ⭐]]), tostring(stars)))
    end
    if #parts == 0 then
        return _([[Filters: (none)]])
    end
    return _([[Filters: ]]) .. table.concat(parts, ", ")
end

function AppStore:getCacheStatusLine(kind, total_count)
    local ts = Cache.getLastFetched(kind)
    local ts_text = ts and ts > 0 and formatTimestamp(ts) or _("Never")
    local label = kind == "plugin" and _("Plugins cached: %s (last update: %s)") or _("Patches cached: %s (last update: %s)")
    return string.format(label, tostring(total_count or 0), ts_text)
end

function AppStore:getCacheWarning(kind)
    local ts = Cache.getLastFetched(kind)
    if not ts or ts <= 0 then
        return _("Cache empty. Refresh to retrieve repositories."), true
    end
    local age = os.time() - ts
    if age > STALE_WARNING_SECONDS then
        return _("Cache is older than a week, consider refreshing."), false
    end
    return nil, false
end

local function formatRepoEntry(repo, opts)
    opts = opts or {}
    local include_description = opts.include_description ~= false
    local include_updated = opts.include_updated ~= false
    local lines = {}
    local title = repo.full_name or repo.name or _("Repository")
    local stars = tonumber(repo.stars) or 0
    local meta = string.format("⭐ %d", stars)
    table.insert(lines, string.format("• %s — %s", title, meta))
    local description = normalizeDescription(repo.description)
    if include_description and description ~= "" then
        table.insert(lines, "  " .. truncateText(description, 200))
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.created_at)
    if include_updated and ts and type(ts) == "string" then
        table.insert(lines, "  " .. string.format(_("Updated: %s"), ts:sub(1, 10)))
    end
    return table.concat(lines, "\n")
end

function AppStore:fetchPatchEntriesFromGitHub(repo)
    local owner = extractRepoOwner(repo)
    if not owner or not repo.name then
        return {}
    end
    local branch = (repo.data and repo.data.default_branch)
        or repo.default_branch
        or "HEAD"
    local tree, err = GitHub.fetchRepoTree(owner, repo.name, branch)
    if not tree or type(tree.tree) ~= "table" then
        logger.warn("AppStore patch tree fetch failed", repo.full_name or repo.name, err)
        return {}
    end
    local entries = {}
    for _, node in ipairs(tree.tree) do
        if node.type == "blob" then
            local filename = node.path and node.path:match("([^/]+)$")
            if isPatchFilename(filename) then
                table.insert(entries, {
                    filename = filename,
                    path = node.path,
                    display_path = node.path,
                    download_url = buildPatchDownloadUrl(owner, repo.name, branch, node.path),
                    branch = branch,
                    sha = node.sha,
                    size = node.size,
                })
            end
        end
    end
    table.sort(entries, function(a, b)
        return a.filename < b.filename
    end)
    return entries
end

function AppStore:storePatchEntriesForRepo(repo)
    local repo_id = repo.repo_id or repo.id
    if not repo_id then
        return
    end
    local entries = self:fetchPatchEntriesFromGitHub(repo)
    Cache.storePatchFiles(repo_id, entries)
end

function AppStore:refreshPatchFileListings()
    Cache.clearPatchFiles("patch")
    local patch_repos = self:getRepoDescriptors("patch")
    for _, repo in ipairs(patch_repos) do
        self:storePatchEntriesForRepo(repo)
    end
end

function AppStore:getPatchEntriesForRepo(repo)
    self.patch_cache = self.patch_cache or {}
    local repo_id = repo.repo_id or repo.id
    local key = repo_id or repo.full_name or repo.name or "repo"
    local cache = self.patch_cache[key]
    local now = os.time()
    if cache and cache.entries and cache.timestamp and (now - cache.timestamp) < PATCH_CACHE_TTL then
        return cache.entries
    end

    local entries = {}
    if repo_id then
        local rows = Cache.listPatchFiles(repo_id)
        for _, row in ipairs(rows) do
            local filename = row.filename or (row.path and row.path:match("([^/]+)$"))
            if filename then
                table.insert(entries, {
                    filename = filename,
                    path = row.path,
                    display_path = row.path,
                    download_url = row.download_url,
                    branch = row.branch or "HEAD",
                    sha = row.sha,
                    size = row.size,
                })
            end
        end
    end

    table.sort(entries, function(a, b)
        return (a.filename or "") < (b.filename or "")
    end)
    self.patch_cache[key] = {
        entries = entries,
        timestamp = now,
    }
    return entries
end

function AppStore:collectPatchEntries(repos)
    local aggregated = {}
    local search = normalizedLower(self.browser_state.search_text)
    local search_active = search ~= ""
    local rf = self.readme_filter
    for _, repo in ipairs(repos) do
        local patches = self:getPatchEntriesForRepo(repo)
        local stars = tonumber(repo.stars) or (repo.data and tonumber(repo.data.stargazers_count)) or 0
        local readme_repo_match = false
        if rf and rf.kind == "patch" and rf.matches and self.browser_state.search_in_readme and search_active then
            local key = repo.full_name
            if not key then
                local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
                if owner and repo.name then
                    key = tostring(owner) .. "/" .. tostring(repo.name)
                else
                    key = repo.name
                end
            end
            if key and rf.matches[tostring(key)] then
                readme_repo_match = true
            end
        end
        local repo_matches_search = (not search_active)
            or self:repoMatchesSearch(repo, search)
            or readme_repo_match
        for _, patch in ipairs(patches) do
            local keep = true
            if search_active and not repo_matches_search then
                keep = self:patchMatchesSearch(patch, search)
            end
            if keep then
                aggregated[#aggregated + 1] = {
                    repo = repo,
                    patch = patch,
                    stars = stars,
                }
            end
        end
    end
    return self:sortPatchEntries(aggregated)
end

function AppStore:makeRepoMenuItem(repo)
    return {
        text = formatRepoEntry(repo),
        keep_menu_open = true,
        callback = function()
            self:promptRepoAction(repo)
        end,
        hold_callback = function()
            self:showReadme(repo)
        end,
    }
end

function AppStore:makePatchMenuItem(repo, patch)
    local stars = tonumber(repo.stars) or (repo.data and tonumber(repo.data.stargazers_count)) or 0
    local lines = { string.format("• %s — ⭐ %d", patch.filename, stars) }
    if patch.display_path and patch.display_path ~= patch.filename then
        table.insert(lines, "  " .. patch.display_path)
    end
    local repo_title = repo.full_name or repo.name or ""
    if repo_title ~= "" then
        table.insert(lines, "  " .. repo_title)
    end
    return {
        text = table.concat(lines, "\n"),
        keep_menu_open = true,
        callback = function()
            self:promptPatchAction(repo, patch)
        end,
        hold_callback = function()
            self:promptPatchAction(repo, patch)
        end,
    }
end

function AppStore:buildBrowserEntries()
    self:ensureBrowserState()
    local kind = self.browser_state.kind or "plugin"
    local items = {}
    local other_kind = kind == "plugin" and "patch" or "plugin"

    if self.match_context then
        if self.match_context.kind == "plugin" and self.match_context.plugin then
            local plugin = self.match_context.plugin
            table.insert(items, {
                text = string.format(_("Matching plugin: %s — tap to cancel"), plugin.name or plugin.dirname or _("plugin")),
                callback = function()
                    self:cancelMatchContext()
                    self:closeBrowserMenu()
                    self:showBrowser(kind)
                end,
                keep_menu_open = true,
            })
            items[#items].separator = true
        elseif self.match_context.kind == "patch" and self.match_context.patch and kind == "patch" then
            local patch = self.match_context.patch
            table.insert(items, {
                text = string.format(_("Matching patch: %s — tap to cancel"), patch.filename or patch.path or _("patch")),
                callback = function()
                    self:cancelMatchContext()
                    self:closeBrowserMenu()
                    self:showBrowser(kind)
                end,
                keep_menu_open = true,
            })
            items[#items].separator = true
        end
    end

    table.insert(items, {
        text = other_kind == "plugin" and "↔ " .. _("Switch to plugins tab") or "↔ " .. _("Switch to patches tab"),
        callback = function()
            self.browser_state.kind = other_kind
            self.browser_state.page = 1
            self.browser_state.scroll_offset = nil
            self:resetFiltersForRefresh()
            self:saveBrowserState()
            self:closeBrowserMenu()
            self:showBrowser()
        end,
    })

    table.insert(items, {
        text = _("Refresh cache"),
        callback = function()
            self:resetBrowserScrollState()
            self:resetFiltersForRefresh()
            self:closeBrowserMenu()
            NetworkMgr:runWhenOnline(function()
                UIManager:nextTick(function()
                    local start_notice = InfoMessage:new{
                        text = _("Caching started, please wait…"),
                        timeout = 5,
                    }
                    UIManager:show(start_notice)
                    UIManager:nextTick(function()
                        self:refreshCache(kind)
                        UIManager:nextTick(function()
                            self:showBrowser(kind)
                            UIManager:nextTick(function()
                                if self.browser_menu then
                                    UIManager:setDirty(self.browser_menu)
                                end
                            end)
                        end)
                    end)
                end)
            end)
        end,
    })
    items[#items].separator = true

    if kind == "plugin" then
        table.insert(items, {
            text = _("Check plugin updates"),
            callback = function()
                self:closeBrowserMenu()
                self:showUpdatesDialog()
            end,
        })
        items[#items].separator = true
    else
        table.insert(items, {
            text = _("Check patch updates"),
            callback = function()
                self:closeBrowserMenu()
                self:showPatchUpdatesDialog()
            end,
        })
        items[#items].separator = true
    end

    table.insert(items, {
        text = self:getFilterSummary(),
        callback = function()
            self:showFilterDialog()
        end,
        keep_menu_open = true,
    })
    items[#items].separator = true

    table.insert(items, {
        text = self:getSortSummary(),
        callback = function()
            self:advanceSortMode()
        end,
        keep_menu_open = true,
    })
    items[#items].separator = true

    local filtered, total = self:getFilteredDescriptors(kind)
    table.insert(items, {
        text = self:getCacheStatusLine(kind, total),
        select_enabled = false,
    })
    local warning = self:getCacheWarning(kind)
    if warning then
        table.insert(items, {
            text = warning,
            select_enabled = false,
        })
    end
    local patch_display_entries
    if kind == "patch" then
        patch_display_entries = self:collectPatchEntries(filtered)
    end
    local display_total = kind == "patch" and #patch_display_entries or #filtered
    local match_line
    if kind == "patch" then
        match_line = string.format(_("Matching patches: %s (repos: %s / %s)"), tostring(display_total), tostring(#filtered), tostring(total))
    else
        match_line = string.format(_("Matching entries: %s / %s"), tostring(#filtered), tostring(total))
    end
    table.insert(items, {
        text = match_line,
        select_enabled = false,
    })
    items[#items].separator = true

    local total_pages = math.max(1, math.ceil(display_total / BROWSER_PAGE_SIZE))
    local page = math.min(math.max(self.browser_state.page or 1, 1), total_pages)
    if self.browser_state.page ~= page then
        self.browser_state.page = page
        self:saveBrowserState()
    end

    local start_index = (page - 1) * BROWSER_PAGE_SIZE + 1
    local end_index = math.min(display_total, start_index + BROWSER_PAGE_SIZE - 1)

    if display_total == 0 then
        local empty_text = kind == "patch" and _("No patches found in matching repositories.") or _("No entries match current filters.")
        table.insert(items, {
            text = empty_text,
            select_enabled = false,
        })
    else
        for i = start_index, end_index do
            if kind == "patch" then
                table.insert(items, self:makePatchMenuItem(patch_display_entries[i].repo, patch_display_entries[i].patch))
            else
                table.insert(items, self:makeRepoMenuItem(filtered[i]))
            end
            items[#items].separator = true
        end
    end

    self._last_total_kind = kind
    self._last_total_pages = total_pages
    if kind == "patch" then
        self._last_patch_display_total = display_total
    end
    return items, total_pages
end

function AppStore:closeBrowserMenu()
    if self.browser_menu then
        UIManager:close(self.browser_menu)
        self.browser_menu = nil
    end
end

function AppStore:resetBrowserScrollState()
    if self.browser_menu and self.browser_menu.resetScroll then
        self.browser_menu:resetScroll()
    end
    self.skip_scroll_save = true
end

function AppStore:reopenBrowser(kind)
    self:closeBrowserMenu()
    UIManager:nextTick(function()
        self:showBrowser(kind)
    end)
end

function AppStore:showBrowser(kind)
    self:ensureBrowserState()
    -- Always ensure only a single AppStore browser dialog is active.
    -- If one is already open (possibly underneath other dialogs), close it
    -- before creating a new one so that applying filters or reopening the
    -- browser does not leave stale AppStore screens in the UI stack.
    if self.browser_menu then
        self:closeBrowserMenu()
    end
    local previous_kind = self.browser_state.kind or "plugin"
    if kind and kind ~= self.browser_state.kind then
        self.browser_state.kind = kind
        self.browser_state.page = 1
        self.browser_state.scroll_offset = nil
        self:saveBrowserState()

        local search_text = self.browser_state.search_text or ""
        if self.browser_state.search_in_readme and search_text ~= "" then
            self.readme_filter = nil
            NetworkMgr:runWhenOnline(function()
                if not self.browser_state or not self.browser_state.search_in_readme then
                    return
                end
                if (self.browser_state.kind or "plugin") ~= kind then
                    return
                end
                if (self.browser_state.search_text or "") == "" then
                    return
                end
                self:updateReadmeFilter()
                UIManager:nextTick(function()
                    self:reopenBrowser(kind)
                end)
            end)
        end
    end
    local title = self.browser_state.kind == "plugin" and _("App Store · Plugins") or _("App Store · Patches")
    local items, total_pages = self:buildBrowserEntries()
    local dialog = AppStoreBrowserDialog:new{
        title = title,
        items = items,
        page = self.browser_state.page,
        total_pages = total_pages,
        scroll_offset = self.browser_state.scroll_offset,
        on_prev_page = function()
            if self.browser_state.page > 1 then
                self:resetBrowserScrollState()
                self.browser_state.page = self.browser_state.page - 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self:reopenBrowser()
            end
        end,
        on_next_page = function()
            local total_pages = self._last_total_kind == (self.browser_state.kind or "plugin") and (self._last_total_pages or 1) or 1
            if self.browser_state.page < total_pages then
                self:resetBrowserScrollState()
                self.browser_state.page = self.browser_state.page + 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self:reopenBrowser()
            end
        end,
        on_dismiss = function(offset)
            if self.skip_scroll_save then
                self.browser_state.scroll_offset = nil
                self.skip_scroll_save = nil
            else
                self.browser_state.scroll_offset = normalizeScrollOffset(offset)
            end
            self:saveBrowserState()
            self.browser_menu = nil
        end,
    }
    self.browser_menu = dialog
    UIManager:show(dialog)
end

function AppStore:showFilterDialog()
    self:ensureBrowserState()
    local filters = self.browser_state
    local prev_search_in_readme = filters.search_in_readme == true
    local dialog
    local check_readme
    dialog = MultiInputDialog:new{
        title = _("AppStore filters"),
        fields = {
            {
                description = _("Search text"),
                text = filters.search_text or "",
                hint = _("Name, description, topic"),
            },
            {
                description = _("Owner"),
                text = filters.owner or "",
                hint = "",
            },
            {
                description = _("Minimum stars"),
                input_type = "number",
                text = (filters.min_stars and filters.min_stars > 0) and tostring(filters.min_stars) or "",
                hint = "0",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear filters"),
                    callback = function()
                        self.browser_state.search_text = ""
                        self.browser_state.owner = ""
                        self.browser_state.min_stars = 0
                        self.browser_state.page = 1
                        self.browser_state.scroll_offset = nil
                        self.browser_state.search_in_readme = false
                        self.readme_filter = nil
                        self:saveBrowserState()
                        UIManager:close(dialog)
                        self:reopenBrowser()
                    end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local values = dialog:getFields()
                        self.browser_state.search_text = util.trim(values[1] or "")
                        self.browser_state.owner = util.trim(values[2] or "")
                        local stars = tonumber(values[3]) or 0
                        if stars < 0 then
                            stars = 0
                        end
                        self.browser_state.min_stars = math.floor(stars)
                        local enable_readme = false
                        if check_readme then
                            enable_readme = check_readme.checked and true or false
                            self.browser_state.search_in_readme = enable_readme
                        else
                            self.browser_state.search_in_readme = self.browser_state.search_in_readme and true or false
                            enable_readme = self.browser_state.search_in_readme
                        end
                        if enable_readme and not prev_search_in_readme and (not GitHub.hasAuthToken or not GitHub.hasAuthToken()) then
                            UIManager:show(InfoMessage:new{
                                text = _("GitHub token is not configured. README search may be rate limited."),
                                timeout = 5,
                            })
                        end
                        self.readme_filter = nil
                        self.browser_state.page = 1
                        self.browser_state.scroll_offset = nil
                        self:saveBrowserState()
                        local search_text = self.browser_state.search_text or ""
                        local kind = self.browser_state.kind or "plugin"
                        if enable_readme and search_text ~= "" then
                            NetworkMgr:runWhenOnline(function()
                                if not self.browser_state or not self.browser_state.search_in_readme then
                                    return
                                end
                                if (self.browser_state.search_text or "") == "" then
                                    return
                                end
                                self:updateReadmeFilter()
                                UIManager:nextTick(function()
                                    self:reopenBrowser()
                                end)
                            end)
                        end
                        UIManager:close(dialog)
                        self:reopenBrowser()
                    end,
                },
            },
        },
    }
    check_readme = CheckButton:new{
        text = _("Search in README"),
        checked = filters.search_in_readme == true,
        parent = dialog,
    }
    -- Insert checkbox visually between Search text and Owner.
    dialog:addWidget(check_readme)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end


function AppStore:getStatusLines()
    local status_lines = { _("AppStore") }
    local plugin_count = Cache.countRepos and Cache.countRepos("plugin") or #Cache.listRepos("plugin")
    local patch_count = Cache.countRepos and Cache.countRepos("patch") or #Cache.listRepos("patch")
    local plugin_ts = Cache.getLastFetched("plugin")
    local patch_ts = Cache.getLastFetched("patch")
    table.insert(status_lines, string.format(_("Plugins cached: %s (last update: %s)"), tostring(plugin_count or 0), formatTimestamp(plugin_ts)))
    table.insert(status_lines, string.format(_("Patches cached: %s (last update: %s)"), tostring(patch_count or 0), formatTimestamp(patch_ts)))

    local now = os.time()
    if plugin_ts and plugin_ts > 0 and now - plugin_ts > STALE_WARNING_SECONDS then
        table.insert(status_lines, _("Plugin cache is older than a week, consider refreshing."))
    end
    if patch_ts and patch_ts > 0 and now - patch_ts > STALE_WARNING_SECONDS then
        table.insert(status_lines, _("Patch cache is older than a week, consider refreshing."))
    end

    local memo = AppStoreSettings:readSetting("status_text")
    if memo and memo ~= "" then
        table.insert(status_lines, memo)
    end

    return status_lines
end

function AppStore:buildStatusWidget()
    local group = VerticalGroup:new{}
    for _, line in ipairs(self:getStatusLines()) do
        group[#group + 1] = TextWidget:new{ text = line }
    end
    return CenterContainer:new{
        FrameContainer:new{
            padding = 20,
            group,
        }
    }
end

function AppStore:buildListWidget(lines)
    local text = table.concat(lines, "\n")
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end
    local text_box_args = {
        text = text,
        width = math.floor(Device.screen:getWidth() * 0.8),
    }
    if default_face then
        text_box_args.face = default_face
    end
    return CenterContainer:new{
        FrameContainer:new{
            padding = 20,
            TextBoxWidget:new(text_box_args),
        }
    }
end

local function truncateText(text, max_len)
    max_len = max_len or 140
    if not text or text == "" then
        return ""
    end
    text = util and util.trim(text) or text
    text = text:gsub("\n", " ")
    if #text <= max_len then
        return text
    end
    return text:sub(1, max_len - 3) .. "..."
end


function AppStore:getRepoDescriptors(kind)
    local entries = Cache.listRepos(kind)
    local descriptors = {}
    for _, repo in ipairs(entries) do
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        local descriptor = {
            id = repo.repo_id,
            kind = kind,
            name = repo.name,
            full_name = repo.full_name,
            owner = owner,
            stars = repo.stars or 0,
            language = repo.language,
            description = repo.description,
            homepage = repo.homepage,
            data = repo.data,
        }
        table.insert(descriptors, descriptor)
    end
    return descriptors
end

function AppStore:renderRepoLines(descriptors)
    if #descriptors == 0 then
        return { _("No cached entries yet. Refresh to fetch from GitHub.") }
    end
    local lines = {}
    for _, repo in ipairs(descriptors) do
        local badge = string.format("⭐ %s", tostring(repo.stars or 0))
        local fullname = repo.full_name or (repo.owner and repo.name and (repo.owner .. "/" .. repo.name)) or (repo.name or _("Unknown"))
        local raw_description = normalizeDescription(repo.description)
        local desc = truncateText(raw_description)
        local language = repo.language and (" · " .. repo.language) or ""
        local line = string.format("%s — %s%s", fullname, badge, language)
        if desc ~= "" then
            line = line .. "\n  " .. desc
        end
        table.insert(lines, line)
    end
    return lines
end

downloadToFile = function(url, local_path)
    local dir = local_path:match("^(.*)/")
    if dir and dir ~= "" then
        util.makePath(dir)
    end

    local file, err = io.open(local_path, "wb")
    if not file then
        return false, err or "failed to open file for writing"
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        sink = socketutil.file_sink(file),
        redirect = true,
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT,
            ["Accept"] = "application/zip, application/octet-stream",
        },
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        util.removeFile(local_path)
        return false, status or code or "timeout"
    end

    if not headers then
        util.removeFile(local_path)
        return false, status or code or "network error"
    end

    if code ~= 200 then
        util.removeFile(local_path)
        return false, status or tostring(code)
    end

    return true
end

local function detectPluginFromArchive(reader, repo)
    local plugin_root
    local plugin_dirname
    local meta_entry_path

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:match("^_meta%.lua$") then
            meta_entry_path = entry.path
            plugin_root = ""
        elseif entry.mode == "file" and entry.path:match("%.koplugin/_meta%.lua$") then
            meta_entry_path = entry.path
            plugin_root = entry.path:match("(.+%.koplugin)/_meta%.lua$")
            if plugin_root then
                plugin_dirname = plugin_root:match("([^/]+%.koplugin)$")
            end
            break
        elseif not meta_entry_path and entry.mode == "file" and entry.path:match("/_meta%.lua$") then
            meta_entry_path = entry.path
            plugin_root = entry.path:match("(.+)/_meta%.lua$")
        end
    end

    if not plugin_root or not plugin_dirname or not meta_entry_path then
        if not plugin_root or not meta_entry_path then
            return nil, _("Could not locate plugin folder (_meta.lua) in archive.")
        end
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local plugin_name
    local plugin_version
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end

    if not plugin_dirname then
        local repo_name = repo and repo.name
        local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        if repo_is_plugin_dir then
            plugin_dirname = repo_name
        elseif plugin_name and plugin_name ~= "" then
            plugin_dirname = sanitizePluginDirname(plugin_name)
        elseif repo_name then
            plugin_dirname = sanitizePluginDirname(repo_name)
        else
            plugin_dirname = sanitizePluginDirname("appstore")
        end
    elseif (not plugin_name or plugin_name == "") then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = plugin_root,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }
end

detectPluginFromArchiveWithFallback = function(reader, repo, release, asset)
    local info, detect_err = detectPluginFromArchive(reader, repo)
    if info and info.plugin_root and info.plugin_dirname then
        return info, nil
    end

    -- Rewind before the fallback pass because the iterator is exhausted after the first scan.
    if reader and reader.rewind then
        reader:rewind()
    end

    local meta_entry_path
    local root_candidate
    local shallow_meta_entry
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path:match("^_meta%.lua$") then
                meta_entry_path = entry.path
                root_candidate = ""
                shallow_meta_entry = shallow_meta_entry or entry.path
            elseif entry.path:match("/_meta%.lua$") then
                meta_entry_path = entry.path
                root_candidate = entry.path:match("(.+)/_meta%.lua$")
                shallow_meta_entry = shallow_meta_entry or entry.path
            end
            if entry.path:match("/_meta%.lua$") and (not shallow_meta_entry or #entry.path < #shallow_meta_entry) then
                shallow_meta_entry = entry.path
                meta_entry_path = entry.path
                root_candidate = entry.path:match("(.+)/_meta%.lua$")
            end
        end
    end

    if not meta_entry_path or not root_candidate then
        return nil, detect_err or _("Could not locate plugin folder (_meta.lua) in archive.")
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local plugin_dirname = extractReleaseNameFallback(repo, release, asset, meta_source)

    local plugin_name
    local plugin_version
    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end
    if (not plugin_name or plugin_name == "") and plugin_dirname then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = root_candidate,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }, nil
end

renderReleaseNotesText = function(repo, release)
    local title = repo and (repo.full_name or repo.name) or _("Repository")
    local tag = release and (release.tag_name or release.name) or _("Latest release")
    local body = release and release.body
    if not body or body == json.null then
        body = ""
    end
    body = tostring(body)
    body = softWrapLongTokens(body, 60)
    if body == "" then
        body = _("No release notes.")
    end
    return table.concat({
        string.format(_("Release notes for %s"), title),
        string.format(_("Release: %s"), tostring(tag)),
        "",
        body,
    }, "\n")
end

extractPluginToUserDir = function(reader, info)
    local plugins_root = DataStorage:getDataDir() .. "/plugins"
    util.makePath(plugins_root)
    local target_dir = plugins_root .. "/" .. info.plugin_dirname
    if lfs.attributes(target_dir, "mode") == "directory" then
        util.removePath(target_dir)
    end

    for entry in reader:iterate() do
        if entry.mode == "file"
            and entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
            local relative = entry.path:sub(#info.plugin_root + 2)
            local dest_path = target_dir .. "/" .. relative
            local parent = dest_path:match("^(.*)/")
            if parent and parent ~= "" then
                util.makePath(parent)
            end
            local ok = reader:extractToPath(entry.path, dest_path)
            if not ok then
                return false, _("Failed to extract file: ") .. entry.path
            end
        end
    end

    return true, target_dir
end

function AppStore:promptRepoAction(repo)
    local dialog
    local buttons_row = {}

    if self.match_context and self.match_context.plugin then
        local plugin = self.match_context.plugin
        local buttons_row = {
            {
                text = _("Match with this repo"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    self:matchPluginWithRepo(plugin, repo)
                end,
            },
        }
        dialog = ConfirmBox:new{
            text = repo.full_name or repo.name or _("Repository"),
            cancel_text = _("Cancel"),
            no_ok_button = true,
            custom_content = makeTextBox(table.concat({
                string.format(_("Match plugin: %s"), plugin.name or plugin.dirname or _("plugin")),
                formatRepoEntry(repo),
            }, "\n\n")),
            other_buttons_first = true,
            other_buttons = { buttons_row },
        }
        UIManager:show(dialog)
        return
    end

    if repo.kind == "plugin" then
        table.insert(buttons_row, {
            text = _("Install plugin"),
            callback = function()
                UIManager:close(dialog)
                self:promptPluginInstallOptions(repo)
            end,
        })
    end

    table.insert(buttons_row, {
        text = _("View README"),
        callback = function()
            UIManager:close(dialog)
            self:showReadme(repo)
        end,
    })

    local lines = {}
    local description = normalizeDescription(repo.description)
    if description ~= "" then
        lines[#lines + 1] = description
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.updated_at or repo.data.created_at)
    if ts and ts ~= "" then
        if description ~= "" then
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = string.format(_("Updated: %s"), ts:sub(1, 10))
    end

    dialog = ConfirmBox:new{
        text = repo.full_name or repo.name or _("Repository"),
        cancel_text = _("Close"),
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = {
            buttons_row,
        },
    }
    dialog:addWidget(makeTextBox(table.concat(lines, "\n")))
    UIManager:show(dialog)
end

function AppStore:installPluginFromRepo(repo)
    if not repo then
        return
    end

    NetworkMgr:runWhenOnline(function()
        self:_installPluginFromRepoInternal(repo)
    end)
end

function AppStore:_installPluginFromRepoInternal(repo)
    if (repo.kind or "plugin") ~= "plugin" then
        UIManager:show(InfoMessage:new{
            text = _("Installation is currently only supported for plugins."),
            timeout = 4,
        })
        return
    end

    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{
            text = _("Missing repository metadata for installation."),
            timeout = 4,
        })
        return
    end

    local url = string.format("https://api.github.com/repos/%s/%s/zipball", owner, repo.name)

    local cache_dir = ensureCacheDir()
    local downloads_dir = cache_dir .. "/downloads"
    if lfs.attributes(downloads_dir, "mode") ~= "directory" then
        lfs.mkdir(downloads_dir)
    end
    local zip_path = string.format("%s/%s-%d.zip", downloads_dir, repo.name, os.time())

    local progress = InfoMessage:new{
        text = _("Downloading plugin archive…"),
        timeout = 0,
    }
    UIManager:show(progress)
    local ok, err = downloadToFile(url, zip_path)
    UIManager:close(progress)

    if not ok then
        util.removeFile(zip_path)
        UIManager:show(InfoMessage:new{
            text = _("Download failed: ") .. tostring(err),
            timeout = 6,
        })
        return
    end

    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        util.removeFile(zip_path)
        UIManager:show(InfoMessage:new{
            text = _("Failed to open downloaded archive."),
            timeout = 6,
        })
        return
    end

    local info, detect_err = detectPluginFromArchive(reader, repo)
    if not info then
        reader:close()
        util.removeFile(zip_path)
        UIManager:show(InfoMessage:new{
            text = detect_err or _("Could not detect plugin inside archive."),
            timeout = 6,
        })
        return
    end

    -- When updating from the plugin updates screen, keep the existing
    -- plugin directory name instead of deriving a new one from the
    -- archive or repository metadata.
    if self.pending_install_context and self.pending_install_context.mode == "update" then
        local ctx_plugin = self.pending_install_context.plugin
        if ctx_plugin and ctx_plugin.dirname and ctx_plugin.dirname ~= "" then
            info.plugin_dirname = ctx_plugin.dirname
        end
    end

    local install_progress = InfoMessage:new{
        text = _("Installing plugin…"),
        timeout = 0,
    }
    UIManager:show(install_progress)
    local ok_extract, dest_or_err = extractPluginToUserDir(reader, info)
    reader:close()
    util.removeFile(zip_path)

    if not ok_extract then
        UIManager:show(InfoMessage:new{
            text = _("Installation failed: ") .. tostring(dest_or_err),
            timeout = 6,
        })
        return
    end

    local msg
    if info.plugin_version and info.plugin_version ~= "" then
        msg = string.format(
            _("Installed plugin \"%s\" (version %s). Restart KOReader to load it."),
            info.plugin_name,
            info.plugin_version
        )
    else
        msg = string.format(
            _("Installed plugin \"%s\". Restart KOReader to load it."),
            info.plugin_name
        )
    end

    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 8,
    })

    self:handlePostInstall(info, repo)
    if self.updates_menu then
        self:updateUpdatesDialog()
    end
end

function AppStore:handlePostInstall(info, repo)
    self:rememberInstall(info, repo)
    -- Ensure the screen refreshes after installation/update to clear any artifacts.
    UIManager:setDirty(nil, "full")
    if not self.pending_install_context then
        return
    end
    local context = self.pending_install_context
    self.pending_install_context = nil
    if context.mode == "update" then
        local plugin = context.plugin
        local record = plugin and getRecordedInstall(plugin.dirname)
        if plugin and record then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Updated %s to version %s."), plugin.name or plugin.dirname, info.plugin_version or _("unknown")),
                timeout = 5,
            })
        end
    end
end

function AppStore:showRepoList(kind, title)
    local descriptors = self:getRepoDescriptors(kind)
    local lines = self:renderRepoLines(descriptors)
    local dialog
    dialog = ConfirmBox:new{
        text = title,
        cancel_text = _("Back"),
        no_ok_button = true,
        custom_content = self:buildListWidget(lines),
        other_buttons = #descriptors > 0 and {
            {
                {
                    text = _("Open details"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptSelection(descriptors, title)
                    end,
                },
            },
        } or nil,
    }
    UIManager:show(dialog)
end

function AppStore:promptSelection(descriptors, title)
    if #descriptors == 0 then
        UIManager:show(InfoMessage:new{ text = _("No cached entries yet."), timeout = 4 })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = title or _("Select repository"),
        input_hint = _("Enter item number"),
        input_type = "number",
        buttons = {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    if not value or value < 1 or value > #descriptors then
                        UIManager:show(InfoMessage:new{ text = _("Invalid selection."), timeout = 3 })
                        return
                    end
                    UIManager:close(dialog)
                    self:promptRepoAction(descriptors[value])
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function AppStore:showReadme(repo)
    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for README download."), timeout = 4 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, path_or_err = RepoContent.fetchReadme(owner, repo.name)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("README download failed: ") .. tostring(path_or_err), timeout = 4 })
            return
        end
        self:closeBrowserMenu()
        RepoContent.openReadme(path_or_err)
    end)
end

local function appendUniqueRepo(target, seen, repo)
    if type(repo) ~= "table" then
        return
    end
    local key = repo.id or repo.node_id or repo.full_name
    if not key then
        local owner = repo.owner and (repo.owner.login or repo.owner)
        if owner and repo.name then
            key = tostring(owner) .. "/" .. tostring(repo.name)
        elseif repo.name then
            key = tostring(repo.name)
        end
    end
    if not key then
        return
    end
    key = tostring(key)
    if seen[key] then
        return
    end
    seen[key] = true
    table.insert(target, repo)
end

local function fetchByQueries(kind_label, queries, opts, append)
    if not queries then
        return
    end
    local per_page = opts.per_page or 100
    local sort = opts.sort or "stars"
    local order = opts.order or "desc"
    for _, query in ipairs(queries) do
        if query and query ~= "" then
            local page = 1
            while true do
                local request_opts = {
                    q = query,
                    per_page = per_page,
                    sort = sort,
                    order = order,
                    page = page,
                }
                local response, err = GitHub.searchRepositories(request_opts)
                if not response then
                    local body = err and err.body or err
                    error(string.format("%s query failed (%s): %s", kind_label, query, tostring(body)))
                end
                local items = response.items or {}
                if #items == 0 then
                    break
                end
                for _, repo in ipairs(items) do
                    append(repo)
                end
                if #items < per_page then
                    break
                end
                page = page + 1
            end
        end
    end
end

function AppStore:fetchAndStore(kind, topics, label, name_queries)
    local collected = {}
    local seen = {}
    local function append(repo)
        appendUniqueRepo(collected, seen, repo)
    end

    if topics then
        local parts = {}
        for _, topic in ipairs(topics) do
            if topic and topic ~= "" then
                table.insert(parts, string.format("topic:%s", topic))
            end
        end
        table.insert(parts, "fork:true")
        local topic_query = table.concat(parts, " ")
        local per_page = 100
        local sort = "stars"
        local order = "desc"
        local page = 1
        while true do
            local request_opts = {
                q = topic_query,
                per_page = per_page,
                sort = sort,
                order = order,
                page = page,
            }
            local response, err = GitHub.searchRepositories(request_opts)
            if not response then
                local body = err and err.body or err
                error(string.format("%s topic search failed (%s): %s", label, topic_query, tostring(body)))
            end
            local items = response.items or {}
            if #items == 0 then
                break
            end
            for _, repo in ipairs(items) do
                append(repo)
            end
            if #items < per_page then
                break
            end
            page = page + 1
        end
    end

    fetchByQueries(label, name_queries, { per_page = 100 }, append)

    Cache.storeRepos(kind, collected)
    return #collected
end

function AppStore:refreshCache(kind)
    if self.is_refreshing then
        return
    end
    self:ensureBrowserState()
    kind = kind or (self.browser_state and self.browser_state.kind) or "plugin"
    local refresh_plugins = (kind == "plugin") or (kind == "all")
    local refresh_patches = (kind == "patch") or (kind == "all")
    if not refresh_plugins and not refresh_patches then
        return
    end

    self.is_refreshing = true
    self.patch_cache = {}
    local progress = InfoMessage:new{ text = _("Refreshing AppStore cache..."), timeout = 0 }
    UIManager:show(progress)

    local summary
    local ok, err = pcall(function()
        local summary_parts = {}
        if refresh_plugins then
            local plugin_total = self:fetchAndStore("plugin", PLUGIN_TOPICS, "Plugin", PLUGIN_NAME_QUERIES)
            table.insert(summary_parts, string.format(_("Cached %s plugins."), tostring(plugin_total)))
        end
        if refresh_patches then
            local patch_total = self:fetchAndStore("patch", PATCH_TOPICS, "Patch", PATCH_NAME_QUERIES)
            self:refreshPatchFileListings()
            table.insert(summary_parts, string.format(_("Cached %s patch repositories."), tostring(patch_total)))
        end
        summary = table.concat(summary_parts, " ")
        if summary == "" then
            summary = _("AppStore cache refreshed.")
        end
        AppStoreSettings:saveSetting("status_text", summary)
        AppStoreSettings:flush()
    end)

    UIManager:close(progress)
    self.is_refreshing = false

    if ok then
        UIManager:show(InfoMessage:new{ text = summary or _("AppStore cache refreshed."), timeout = 5 })
    else
        local message = tostring(err)
        UIManager:show(InfoMessage:new{ text = _("AppStore refresh failed: ") .. message, timeout = 6 })
    end
end

function AppStore:init()
    self.cache_dir = ensureCacheDir()
    self.ui.menu:registerToMainMenu(self)
end

function AppStore:addToMainMenu(menu_items)
    menu_items.AppStore = {
        sorting_hint = "tools",
        text = _("App Store"),
        callback = function()
            self:showBrowser()
        end,
    }
end

return AppStore

