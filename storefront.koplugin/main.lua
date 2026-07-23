local R = {
    Device = require("device"),
    DataStorage = require("datastorage"),
    LuaSettings = require("luasettings"),
    UIManager = require("ui/uimanager"),
    WidgetContainer = require("ui/widget/container/widgetcontainer"),
    InputContainer = require("ui/widget/container/inputcontainer"),
    FocusManager = require("ui/widget/focusmanager"),
    ScrollableContainer = require("ui/widget/container/scrollablecontainer"),
    Geom = require("ui/geometry"),
    GestureRange = require("ui/gesturerange"),
    TitleBar = require("ui/widget/titlebar"),
    Button = require("ui/widget/button"),
    HorizontalGroup = require("ui/widget/horizontalgroup"),
    HorizontalSpan = require("ui/widget/horizontalspan"),
    VerticalSpan = require("ui/widget/verticalspan"),
    LineWidget = require("ui/widget/linewidget"),
    Size = require("ui/size"),
    Blitbuffer = require("ffi/blitbuffer"),
    ConfirmBox = require("ui/widget/confirmbox"),
    InfoMessage = require("ui/widget/infomessage"),
    TextViewer = require("ui/widget/textviewer"),
    TextWidget = require("ui/widget/textwidget"),
    TextBoxWidget = require("ui/widget/textboxwidget"),
    MultiInputDialog = require("ui/widget/multiinputdialog"),
    CheckButton = require("ui/widget/checkbutton"),
    ButtonDialog = require("ui/widget/buttondialog"),
    SpinWidget = require("ui/widget/spinwidget"),
    Font = require("ui/font"),
    Dispatcher = require("dispatcher"),
    InputDialog = require("ui/widget/inputdialog"),
    VerticalGroup = require("ui/widget/verticalgroup"),
    FrameContainer = require("ui/widget/container/framecontainer"),
    CenterContainer = require("ui/widget/container/centercontainer"),
    RightContainer = require("ui/widget/container/rightcontainer"),
    OverlapGroup = require("ui/widget/overlapgroup"),
    _ = require("gettext"),
    Cache = require("storefront_cache"),
    GitHub = require("storefront_net_github"),
    RepoContent = require("storefront_repo_content"),
    InstallStore = require("storefront_installs"),
    util = require("util"),
    NetworkMgr = require("ui/network/manager"),
    socketutil = require("socketutil"),
    socket = require("socket"),
    http = require("socket.http"),
    ltn12 = require("ltn12"),
    Archiver = require("ffi/archiver"),
    sha2 = require("ffi/sha2"),
    lfs = require("libs/libkoreader-lfs"),
    json = require("json"),
    logger = require("logger"),
    StorefrontLogger = require("storefront_logger"),
}
R.Input = R.Device.input

local env = setmetatable({}, { __index = _G })
for k, v in pairs(R) do
    env[k] = v
end
setfenv(1, env)

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)

local IGNORED_RELEASES_KEY = "ignored_releases"

local STALE_WARNING_SECONDS = 7 * 24 * 3600
local DEFAULT_BROWSER_PAGE_SIZE = 5
local MIN_BROWSER_PAGE_SIZE = 4
local MAX_BROWSER_PAGE_SIZE = 100
-- Installed/manage lists hold taller multi-line entries (name + version +
-- update status), so they get their own page-size setting, defaulting smaller
-- than the compact available-browser list.
local DEFAULT_MANAGE_PAGE_SIZE = 5
local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin"' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches"' }
local BROWSER_STATE_KEY = "browser_state"
local BROWSER_PAGE_SIZE_KEY = "browser_page_size"
local MANAGE_PAGE_SIZE_KEY = "manage_page_size"
local INCLUDE_ZERO_STAR_FORKS_KEY = "include_zero_star_forks"
local PATCH_CACHE_TTL = 10 * 60
local DEFAULT_SORT_MODE = "stars_desc"

local PluginPaths = require("storefront_plugin_paths")
local PATCHES_ROOT = DataStorage:getDataDir() .. "/patches"

local Storefront = WidgetContainer:extend{
    name = "storefront",
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

require("storefront_updates_ui"):init(Storefront)

local StorefrontListItem = require("storefront_list_item")
local StorefrontBrowserDialog = require("storefront_browser_ui")

local function getBrowserPageSize()
    local v = StorefrontSettings:readSetting(BROWSER_PAGE_SIZE_KEY)
    if type(v) == "number" and v >= MIN_BROWSER_PAGE_SIZE then
        return math.min(math.floor(v), MAX_BROWSER_PAGE_SIZE)
    end
    return DEFAULT_BROWSER_PAGE_SIZE
end

local function getManagePageSize()
    local v = StorefrontSettings:readSetting(MANAGE_PAGE_SIZE_KEY)
    if type(v) == "number" and v >= MIN_BROWSER_PAGE_SIZE then
        return math.min(math.floor(v), MAX_BROWSER_PAGE_SIZE)
    end
    return DEFAULT_MANAGE_PAGE_SIZE
end

local function showRestartConfirmation(message)
    UIManager:show(ConfirmBox:new{
        text = message .. "\n\n" .. _("This will take effect on next restart."),
        ok_text = _("Restart now"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
        cancel_text = _("Restart later"),
        background = Blitbuffer.COLOR_WHITE,
    })
end

local function getIgnoredReleases()
    return StorefrontSettings:readSetting(IGNORED_RELEASES_KEY) or {}
end

local function saveIgnoredReleases(ignored_releases)
    StorefrontSettings:saveSetting(IGNORED_RELEASES_KEY, ignored_releases)
    StorefrontSettings:flush()
end

local function ignoreRelease(owner, repo_name, version)
    if not owner or not repo_name or not version then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    ignored[key] = version
    saveIgnoredReleases(ignored)
end

local function clearIgnoredRelease(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    if ignored[key] then
        ignored[key] = nil
        saveIgnoredReleases(ignored)
    end
end

local function getIgnoredVersion(owner, repo_name)
    if not owner or not repo_name then
        return nil
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = getIgnoredReleases()
    return ignored[key]
end

local function isReleaseIgnored(owner, repo_name, version)
    local ignored_version = getIgnoredVersion(owner, repo_name)
    return ignored_version == version
end


local extractRepoOwner, ensureCacheDir, ensurePatchesDir, downloadToFile, buildPatchDownloadUrl, derivePluginRepoPath, sanitizeMetaPath, fetchGitHubRaw, formatTimestamp, parseGitHubTimestamp, buildRepoDescriptorFromRecord, buildBranchCandidates, getRepoDefaultBranch, extractMetaField, getPatchRecordsMap, extractPluginToUserDir, extractReleaseNameFallback, detectPluginFromArchiveWithFallback, renderReleaseNotesText, softWrapLongTokens, repoIsFork, repoStarsValue

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

function Storefront:refreshPatchUpdates()
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

function Storefront:_refreshPatchUpdatesInternal(records)
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

    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    end
    self:savePatchUpdatesState()

    UIManager:setDirty(nil, "full")
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

local function isPluginDisabled(dirname)
    if not dirname or dirname == "" then
        return false
    end
    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local plugin_name = dirname:gsub("%.koplugin$", "")
    return plugins_disabled[plugin_name] == true
end

local function isPatchDisabled(filename)
    if not filename or filename == "" then
        return false
    end
    return filename:match("%.disabled$") ~= nil
end

local function deleteDirectoryRecursive(path)
    if not path or path == "" then
        return false, "Invalid path"
    end
    local attr = lfs.attributes(path)
    if not attr then
        return false, "Path does not exist"
    end
    if attr.mode ~= "directory" then
        return os.remove(path), "Not a directory"
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = path .. "/" .. entry
            local entry_attr = lfs.attributes(full_path)
            if entry_attr then
                if entry_attr.mode == "directory" then
                    local ok, err = deleteDirectoryRecursive(full_path)
                    if not ok then
                        return false, err
                    end
                else
                    local ok, err = os.remove(full_path)
                    if not ok then
                        return false, err
                    end
                end
            end
        end
    end
    return lfs.rmdir(path)
end

function listInstalledPatches()
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
        -- Only include SHA when explicitly requested (during install/update).
        -- During match, leave it nil so fallback mechanism can detect old files.
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
        -- installed_sha: the SHA recorded at install/update time.
        -- Comparing remote_sha against this (not local_sha) means user edits to
        -- the local file do NOT trigger a false "update available" — only a real
        -- server-side change will flip needs_update to true.
        local installed_sha = record and record.sha
        local needs_update = false
        if record and remote_sha then
            if installed_sha then
                -- Normal path: server current SHA vs SHA at install time.
                needs_update = remote_sha ~= installed_sha
            elseif local_sha then
                -- Fallback for old records that pre-date SHA storage: compare
                -- against the local file so we don't silently miss updates.
                needs_update = remote_sha ~= local_sha
            else
                needs_update = true
            end
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

function Storefront:buildPatchUpdateItems(summary)
    self:ensurePatchUpdatesState()
    summary = summary or self:collectPatchUpdateSummary()
    local entries = {}
    local filter_updates = self.patch_updates_state.filter_only_outdated
    local filter_linked = self.patch_updates_state.filter_only_linked
    for idx, patch_item in ipairs(summary.data or {}) do
        local is_linked = patch_item.record and patch_item.record.owner and patch_item.record.repo
        if ((not filter_updates) or patch_item.needs_update) and ((not filter_linked) or is_linked) then
            local patch = patch_item.patch
            local record = patch_item.record
            local remote_entry = patch_item.remote_entry
            local disabled_label = (patch.disabled or isPatchDisabled(patch.filename)) and "[DISABLED] " or ""
            local lines = {
                string.format("• %s%s", disabled_label, patch.filename or patch.path or _("patch")),
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
                is_entry = true,
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
    if record.meta_path and derivePluginRepoPath then
        add(derivePluginRepoPath(record.meta_path))
    end
    add(record.meta_path_hint)

    if record.meta_path then
        local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
        if derivePluginRepoPath then
            add(derivePluginRepoPath(trimmed))
        end
    end
    if record.meta_path_hint then
        local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end

    if record.dirname and record.dirname ~= "" then
        add("plugins/" .. record.dirname .. "/_meta.lua")
        add(record.dirname .. "/_meta.lua")
        if record.dirname:match("%.koplugin$") then
            local without_suffix = record.dirname:gsub("%.koplugin$", "")
            add("plugins/" .. without_suffix .. "/_meta.lua")
            add(without_suffix .. "/_meta.lua")
        end
    end

    add("plugins/_meta.lua")
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

local function isPreReleaseTag(tag_name)
    if not tag_name then
        return false
    end
    
    local lower = tag_name:lower()
    local prerelease_keywords = {
        "alpha",
        "beta",
        "rc",
        "dev",
        "preview",
        "pre",
        "test",
    }
    
    for _, keyword in ipairs(prerelease_keywords) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end
    
    return false
end

local function isDateBasedVersion(version_str)
    if not version_str then
        return false
    end
    
    local year, month, day = version_str:match("^(%d%d%d%d)%.(%d+)%.(%d+)$")
    if year then
        local y = tonumber(year)
        local m = tonumber(month)
        local d = tonumber(day)
        
        if y >= 2000 and y <= 2100 and m >= 1 and m <= 12 and d >= 1 and d <= 31 then
            return true
        end
    end
    
    return false
end

local function parseVersionFromTag(tag_name)
    if not tag_name then
        return nil
    end
    
    local cleaned = tag_name:gsub("^[vV]", "")
    cleaned = cleaned:gsub("^release%-?", "")
    cleaned = cleaned:gsub("^version%-?", "")
    cleaned = cleaned:gsub("^plugin%-?", "")
    
    local patterns = {
        "^(%d+%.%d+%.%d+)",
        "^(%d+%.%d+)",
        "^(%d+)",
    }
    
    for _, pattern in ipairs(patterns) do
        local version = cleaned:match(pattern)
        if version then
            if isDateBasedVersion(version) then
                return nil
            end
            return version
        end
    end
    
    return nil
end

local function isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    -- Strip a leading "v"/"V" so a _meta.lua version like "v1.4.2" compares
    -- equal to a release tag parsed to "1.4.2" (parseVersionFromTag already
    -- strips it on the tag side). Otherwise normalizeVersion turns the "v1"
    -- segment into 0 and the local version always looks older.
    v1_str = tostring(v1_str):gsub("^[vV]", "")
    v2_str = tostring(v2_str):gsub("^[vV]", "")
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

local function buildInstallRecordFields(dirname, plugin_name, installed_version, repo, meta_path, installed_tag)
    if not dirname or dirname == "" then
        return nil
    end
    local owner = getRepoOwner(repo)
    local repo_name = repo and repo.name
    local record = {
        dirname = dirname,
        plugin_name = plugin_name,
        installed_version = installed_version,
        installed_tag = installed_tag or nil,
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

local function getPluginMetaPath(root, dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return string.format("%s/%s/_meta.lua", root, dirname)
end

local function loadPluginMeta(root, dirname)
    local meta_path = getPluginMetaPath(root, dirname)
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
    local hidden_paths = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
    for _, root in ipairs(PluginPaths.getLookupPaths()) do
        if lfs.attributes(root, "mode") == "directory" and not PluginPaths.isPathHidden(root, hidden_paths) then
            for entry in lfs.dir(root) do
                if entry ~= "." and entry ~= ".." and entry:match("%.koplugin$") then
                    local meta = loadPluginMeta(root, entry)
                    local plugin = {
                        dirname = entry,
                        meta = meta,
                        name = getPluginDisplayName(meta, entry),
                        version = meta and meta.version or nil,
                        root = root,
                        path = root .. "/" .. entry,
                        meta_path_hint = entry .. "/_meta.lua",
                    }
                    plugin.latest_mtime = getLatestModificationTimestamp(plugin.path)
                    table.insert(plugins, plugin)
                end
            end
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

function Storefront:saveUpdatesState()
    if self.updates_state then
        StorefrontSettings:saveSetting("updates_state", self.updates_state)
        StorefrontSettings:flush()
    end
end

function Storefront:savePatchUpdatesState()
    if self.patch_updates_state then
        StorefrontSettings:saveSetting("patch_updates_state", self.patch_updates_state)
        StorefrontSettings:flush()
    end
end

function Storefront:ensureUpdatesState()
    if not self.updates_state then
        self.updates_state = StorefrontSettings:readSetting("updates_state") or {}
    end
    self.updates_state.filter_only_outdated = self.updates_state.filter_only_outdated or false
    self.updates_state.filter_only_linked = self.updates_state.filter_only_linked or false
    self.updates_state.remote_info = self.updates_state.remote_info or {}
    self.updates_state.page = self.updates_state.page or 1
end

function Storefront:ensurePatchUpdatesState()
    if not self.patch_updates_state then
        self.patch_updates_state = StorefrontSettings:readSetting("patch_updates_state") or {}
    end
    self.patch_updates_state.filter_only_outdated = self.patch_updates_state.filter_only_outdated or false
    self.patch_updates_state.filter_only_linked = self.patch_updates_state.filter_only_linked or false
    self.patch_updates_state.remote_info = self.patch_updates_state.remote_info or {}
    self.patch_updates_state.page = self.patch_updates_state.page or 1
end

-- Reset a paginated dialog's state to "top of list" (page 1, no saved scroll
-- offset) and reset its live scroller. Both steps are needed: otherwise the
-- dialog's on_dismiss would write the current (old) live offset back over the
-- nil just set here, and the rebuilt list would reopen scrolled past its
-- first rows. Used whenever a filter/sort/page-size change invalidates the
-- current view (see call sites in showPluginFilterDialog/showPatchFilterDialog).
function Storefront:resetPageAndScroll(state, menu)
    state.page = 1
    state.scroll_offset = nil
    if menu and menu.resetScroll then
        menu:resetScroll()
    end
end

local function extractAuthorFromPlugin(plugin)
    if not plugin then return nil end
    local meta = plugin.meta
    if meta then
        if meta.owner and type(meta.owner) == "string" and meta.owner ~= "" then return meta.owner end
        if meta.author and type(meta.author) == "string" and meta.author ~= "" then return meta.author end
        if meta.developer and type(meta.developer) == "string" and meta.developer ~= "" then return meta.developer end
        if meta.by and type(meta.by) == "string" and meta.by ~= "" then return meta.by end
        
        local url = meta.url or meta.homepage or meta.repository or meta.repo or meta.fullname
        if url and type(url) == "string" then
            local owner = url:match("github%.com[:/]([^/]+)")
            if owner then return owner end
        end
    end
    
    if plugin.path then
        local meta_path = plugin.path .. "/_meta.lua"
        local mf = io.open(meta_path, "r")
        if mf then
            local mcontent = mf:read("*a")
            mf:close()
            if mcontent then
                local owner = mcontent:match("github%.com[:/]([^/\"']+)")
                if owner then return owner end
                local author = mcontent:match("author%s*=%s*[\"']([^\"']+)[\"']") or mcontent:match("owner%s*=%s*[\"']([^\"']+)[\"']")
                if author and author ~= "" then return author end
            end
        end

        local git_cfg_path = plugin.path .. "/.git/config"
        local f = io.open(git_cfg_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content then
                local owner = content:match("github%.com[:/]([^/]+)")
                if owner then return owner end
            end
        end
    end
    
    return nil
end

function Storefront:autoMatchInstalled()
    local current_gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    if self._auto_matched_gen == current_gen then
        return
    end
    self._auto_matched_gen = current_gen
    StorefrontLogger.info("AUTO-MATCH starting for installed plugins and patches")

    -- 1. Plugins
    local records = getInstallRecordsMap()
    local installed_plugins = listInstalledPlugins()
    local unmatched_plugins = {}
    for _, plugin in ipairs(installed_plugins) do
        local record = records[plugin.dirname]
        if not (record and record.owner and record.repo) or record.is_auto_matched then
            table.insert(unmatched_plugins, plugin)
        end
    end

    if #unmatched_plugins > 0 then
        local cached_plugins = Cache.listRepos("plugin")
        local name_map = {}

        local function isBetterMatch(existing, candidate)
            if not existing then return true end
            local ex_stars = repoStarsValue(existing)
            local ca_stars = repoStarsValue(candidate)
            if ca_stars ~= ex_stars then
                return ca_stars > ex_stars -- higher star count always wins
            end
            local ex_fork = existing.fork or (existing.data and existing.data.fork) or false
            local ca_fork = candidate.fork or (candidate.data and candidate.data.fork) or false
            if ex_fork ~= ca_fork then
                return not ca_fork -- tiebreaker: prefer non-fork if stars are equal
            end
            return false
        end

        for _, repo in ipairs(cached_plugins) do
            if repo.name then
                local low_name = repo.name:lower()
                if isBetterMatch(name_map[low_name], repo) then
                    name_map[low_name] = repo
                end
                local clean = repo.name:gsub("%.koplugin$", ""):lower()
                if isBetterMatch(name_map[clean], repo) then
                    name_map[clean] = repo
                end
            end
        end

        for _, plugin in ipairs(unmatched_plugins) do
            local author = extractAuthorFromPlugin(plugin)
            local clean_dirname = plugin.dirname:gsub("%.koplugin$", ""):lower()
            local repo
            if author then
                local norm_author = author:lower()
                for _, candidate in ipairs(cached_plugins) do
                    if candidate.name then
                        local candidate_clean = candidate.name:gsub("%.koplugin$", ""):lower()
                        if candidate_clean == clean_dirname or candidate.name:lower() == plugin.dirname:lower() then
                            local ca_owner = (candidate.owner or (candidate.data and candidate.data.owner and candidate.data.owner.login) or ""):lower()
                            if ca_owner == norm_author then
                                repo = candidate
                                break
                            end
                        end
                    end
                end
            end

            if not repo then
                repo = name_map[clean_dirname] or name_map[plugin.dirname:lower()]
            end

            if repo then
                local existing_rec = records[plugin.dirname]
                local matched_at = (existing_rec and existing_rec.matched_at) or os.time()
                local record = {
                    owner = repo.owner,
                    repo = repo.name,
                    repo_full_name = repo.full_name,
                    repo_description = repo.description,
                    repo_id = repo.repo_id,
                    branch = repo.data and repo.data.default_branch or "main",
                    matched_at = matched_at,
                    is_auto_matched = true,
                }
                InstallStore.upsert(plugin.dirname, record)
                StorefrontLogger.action(string.format("AUTO-MATCHED plugin %s -> %s", tostring(plugin.dirname), tostring(repo.full_name or repo.name)))
            end
        end
    end

    -- 2. Patches
    local patch_records = getPatchRecordsMap()
    local installed_patches = listInstalledPatches()
    for _, patch in ipairs(installed_patches) do
        local record = patch_records[patch.filename]
        if not (record and record.owner and record.repo and record.path) then
            local repo, file_map = Cache.findPatchRepoAndFile(patch.filename)
            if repo and file_map then
                local existing_patch_rec = patch_records[patch.filename]
                local matched_at = (existing_patch_rec and existing_patch_rec.matched_at) or os.time()
                local record = {
                    filename = patch.filename,
                    owner = repo.owner,
                    repo = repo.name,
                    repo_full_name = repo.full_name,
                    repo_id = repo.repo_id,
                    repo_description = repo.description,
                    branch = file_map.branch or repo.data and repo.data.default_branch or "HEAD",
                    path = file_map.path,
                    download_url = file_map.download_url,
                    sha = file_map.sha,
                    matched_at = matched_at,
                    is_auto_matched = true,
                }
                InstallStore.upsertPatch(patch.filename, record)
                StorefrontLogger.action(string.format("AUTO-MATCHED patch %s -> %s (%s)", tostring(patch.filename), tostring(repo.full_name or repo.name), tostring(file_map.path or "")))
            end
        end
    end
end

function Storefront:collectPatchUpdateSummary()
    local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local remote_info_key = self.patch_updates_state and self.patch_updates_state.remote_info
    
    if self._cached_patch_summary
       and self._cached_patch_summary_gen == current_generation
       and self._cached_patch_summary_remote == remote_info_key then
        return self._cached_patch_summary
    end

    self:autoMatchInstalled()
    self:ensurePatchUpdatesState()
    local summary = buildPatchSummary(self.patch_updates_state.remote_info)
    
    self._cached_patch_summary = summary
    self._cached_patch_summary_gen = current_generation
    self._cached_patch_summary_remote = remote_info_key
    return summary
end

function Storefront:getPatchUpdatesSummaryText(summary)
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

function Storefront:collectUpdateSummary()
    local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local remote_info_key = self.updates_state and self.updates_state.remote_info
    
    if self._cached_plugin_summary
       and self._cached_plugin_summary_gen == current_generation
       and self._cached_plugin_summary_remote == remote_info_key then
        return self._cached_plugin_summary
    end

    self:autoMatchInstalled()
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

    local repo_map = {}

    for _, plugin in ipairs(installed) do
        local record = records[plugin.dirname]
        local tracked = record and record.owner and record.repo
        local repo_key = tracked and (record.owner:lower() .. "/" .. record.repo:lower()) or nil

        if repo_key then
            if repo_map[repo_key] then
                local existing_index = repo_map[repo_key]
                local existing_item = data[existing_index]
                local existing_plugin = existing_item.plugin

                local current_matches_repo = (plugin.dirname:lower() == (record.repo:lower() .. ".koplugin"))
                local existing_matches_repo = (existing_plugin.dirname:lower() == (existing_item.record.repo:lower() .. ".koplugin"))

                local current_is_primary = false
                if current_matches_repo and not existing_matches_repo then
                    current_is_primary = true
                elseif not current_matches_repo and existing_matches_repo then
                    current_is_primary = false
                else
                    current_is_primary = (plugin.latest_mtime or 0) > (existing_plugin.latest_mtime or 0)
                end

                summary.total = summary.total - 1
                if current_is_primary then
                    existing_item.duplicates = existing_item.duplicates or {}
                    table.insert(existing_item.duplicates, existing_plugin)

                    existing_item.plugin = plugin
                    existing_item.record = record
                    existing_item.remote = remote_info[plugin.dirname]
                else
                    existing_item.duplicates = existing_item.duplicates or {}
                    table.insert(existing_item.duplicates, plugin)
                    goto continue_plugin
                end
            end
        end

        if tracked then
            summary.tracked = summary.tracked + 1
        else
            summary.unmatched = summary.unmatched + 1
        end

        local remote = remote_info[plugin.dirname]
        local has_checked_info = remote and not remote.error
        if not has_checked_info and tracked then
            local cached_repo
            if record.repo_id then
                cached_repo = Cache.getRepo(record.repo_id)
            end
            if not cached_repo and record.owner and record.repo then
                cached_repo = Cache.getRepoByName(record.owner, record.repo)
            end
            if cached_repo and cached_repo.data then
                local pushed_at_str = cached_repo.data.pushed_at or cached_repo.data.updated_at
                local remote_repo_ts = pushed_at_str and parseGitHubTimestamp(pushed_at_str) or 0
                local remote_version = cached_repo.data.version
                local prev_version = remote and (remote.release_tag_name or remote.remote_version)
                -- Fix 3: Carry release_tag_name through the fallback so the version-compare
                -- branch is taken in has_update logic (instead of timestamp-only).
                local prev_release_tag = remote and remote.release_tag_name
                remote = {
                    remote_version = prev_version or remote_version,
                    remote_repo_ts = remote_repo_ts,
                    release_tag_name = prev_release_tag,
                    is_cached_fallback = true,
                }
            end
        end
        local local_version = plugin.version
        local local_latest_ts = plugin.latest_mtime
        if not local_latest_ts or local_latest_ts == 0 then
            local_latest_ts = getLatestModificationTimestamp(plugin.path)
            plugin.latest_mtime = local_latest_ts
        end
        
        local has_update = false
        
        if tracked and remote then
            local release_tag = remote.release_tag_name
            local release_ts = remote.release_published_at or 0
            
            if release_tag then
                local release_version = parseVersionFromTag(release_tag)

                if release_version and local_version then
                    has_update = isVersionNewer(release_version, local_version)
                elseif release_version then
                    has_update = release_ts > local_latest_ts
                else
                    local raw_tag = release_tag:gsub("^[vV]", "")
                    local raw_local = local_version and tostring(local_version):gsub("^[vV]", "") or nil
                    if raw_tag ~= "" and raw_local then
                        if raw_tag == raw_local then
                            has_update = false
                        else
                            has_update = isVersionNewer(raw_tag, raw_local)
                        end
                    elseif release_ts > 0 and local_latest_ts > 0 then
                        has_update = release_ts > local_latest_ts
                    end
                end

                if has_update and record.owner and record.repo then
                    if isReleaseIgnored(record.owner, record.repo, release_tag) then
                        has_update = false
                    else
                        local ignored_version = getIgnoredVersion(record.owner, record.repo)
                        if ignored_version and ignored_version ~= release_tag then
                            clearIgnoredRelease(record.owner, record.repo)
                        end
                    end
                end
            else
                local remote_version = remote.remote_version
                local remote_repo_ts = remote.remote_repo_ts or 0

                if remote_version and local_version then
                    has_update = isVersionNewer(remote_version, local_version)
                else
                    has_update = false
                end
            end
        end
        
        if has_update then
            summary.updates = summary.updates + 1
        end

        data[#data + 1] = {
            plugin = plugin,
            record = record,
            remote = remote,
            has_update = has_update,
        }
        if repo_key then
            repo_map[repo_key] = #data
        end

        ::continue_plugin::
    end

    summary.data = data
    summary.records = records
    
    self._cached_plugin_summary = summary
    self._cached_plugin_summary_gen = current_generation
    self._cached_plugin_summary_remote = remote_info_key
    return summary
end

function Storefront:getUpdatesSummaryText(summary)
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

function Storefront:buildUpdateItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local entries = {}
    local filter_updates = self.updates_state.filter_only_outdated
    local filter_linked = self.updates_state.filter_only_linked
    for idx, item in ipairs(summary.data or {}) do
        local is_linked = item.record and item.record.owner and item.record.repo
        if ((not filter_updates) or item.has_update) and ((not filter_linked) or is_linked) then
            local plugin = item.plugin
            local record = item.record
            local remote = item.remote
            local disabled_label = isPluginDisabled(plugin.dirname) and "[DISABLED] " or ""
            local lines = {
                string.format("• %s%s (%s)", disabled_label, plugin.name or plugin.dirname, plugin.dirname),
            }

            local local_version_str = plugin.version or _("unknown")
            local remote_version_str = nil
            local update_reason = nil
            
            if remote then
                if remote.release_tag_name then
                    local release_version = parseVersionFromTag(remote.release_tag_name)
                    if release_version then
                        remote_version_str = release_version
                    else
                        remote_version_str = remote.release_tag_name
                    end
                    
                    if item.has_update then
                        if release_version and plugin.version then
                            if isVersionNewer(release_version, plugin.version) then
                                update_reason = nil
                            else
                                update_reason = _("release is newer by date")
                            end
                        else
                            update_reason = _("release is newer by date")
                        end
                    end
                else
                    if remote.remote_version then
                        remote_version_str = remote.remote_version
                    end
                    
                    if item.has_update then
                        local local_latest_ts = plugin.latest_mtime or 0
                        local remote_repo_ts = remote.remote_repo_ts or 0
                        
                        if remote_repo_ts > local_latest_ts then
                            update_reason = _("remote is newer by date")
                        elseif plugin.version and remote.remote_version then
                            if isVersionNewer(remote.remote_version, plugin.version) then
                                update_reason = nil
                            else
                                update_reason = _("remote is newer by date")
                            end
                        else
                            update_reason = _("remote is newer by date")
                        end
                    end
                end
            end
            
            local version_line
            if remote_version_str then
                version_line = string.format(_("Local: %s → Remote: %s"), local_version_str, remote_version_str)
            else
                version_line = string.format(_("Local: %s"), local_version_str)
            end
            if update_reason then
                version_line = version_line .. " (" .. update_reason .. ")"
            end
            table.insert(lines, version_line)

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
                is_entry = true,
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

function Storefront:buildUpdateBrowserItems(summary)
    self:ensureUpdatesState()
    summary = summary or self:collectUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text = "⮤ " .. _("Switch to plugin list"),
        keep_menu_open = true,
        focus_id = "switch_list",
        callback = function()
            self:closeUpdatesDialog(true)
            self:showBrowser("plugin")
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = "↔ " .. _("Switch to installed patches"),
        keep_menu_open = true,
        focus_id = "switch_installed",
        callback = function()
            self:closeUpdatesDialog(true)
            self:showPatchUpdatesDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        focus_id = "check_all",
        callback = function()
            self:checkAllUpdates()
        end,
    }
    items[#items].separator = true

    local current_filter
    if self.updates_state.filter_only_outdated then
        current_filter = _("Needs update")
    elseif self.updates_state.filter_only_linked then
        current_filter = _("Linked only")
    else
        current_filter = _("All plugins")
    end

    items[#items + 1] = {
        text = _("Filter: ") .. current_filter,
        keep_menu_open = true,
        focus_id = "filter",
        callback = function()
            self:showPluginFilterDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = self:getUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    -- Paginate the installed-plugin entries the same way the browser paginates
    -- its available list. Without this the whole list (dozens of multi-line
    -- widgets) lives on one page, so every cursor move triggers a full-dialog
    -- repaint that takes tens of seconds on e-ink. The informational header
    -- items above are kept on every page (cheap single-line widgets).
    local plugin_items = self:buildUpdateItems(summary)
    local page_size = getManagePageSize()
    local display_total = #plugin_items
    local total_pages = math.max(1, math.ceil(display_total / page_size))
    local page = math.min(math.max(self.updates_state.page or 1, 1), total_pages)
    if self.updates_state.page ~= page then
        self.updates_state.page = page
    end
    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(display_total, start_index + page_size - 1)
    for i = start_index, end_index do
        items[#items + 1] = plugin_items[i]
        items[#items].separator = true
    end

    return items, total_pages
end

function Storefront:buildPatchUpdateBrowserItems(summary)
    self:ensurePatchUpdatesState()
    summary = summary or self:collectPatchUpdateSummary()
    local items = {}

    items[#items + 1] = {
        text ="⮤ " .. _("Switch to patch list"),
        keep_menu_open = true,
        focus_id = "switch_list",
        callback = function()
            self:closePatchUpdatesDialog(true)
            self:showBrowser("patch")
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = "↔ " .. _("Switch to installed plugins"),
        keep_menu_open = true,
        focus_id = "switch_installed",
        callback = function()
            self:closePatchUpdatesDialog(true)
            self:showUpdatesDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Check all updates"),
        keep_menu_open = true,
        focus_id = "check_all",
        callback = function()
            self:refreshPatchUpdates()
        end,
    }
    items[#items].separator = true

    local current_filter
    if self.patch_updates_state.filter_only_outdated then
        current_filter = _("Needs update")
    elseif self.patch_updates_state.filter_only_linked then
        current_filter = _("Linked only")
    else
        current_filter = _("All patches")
    end

    items[#items + 1] = {
        text = _("Filter: ") .. current_filter,
        keep_menu_open = true,
        focus_id = "filter",
        callback = function()
            self:showPatchFilterDialog()
        end,
    }
    items[#items].separator = true

    items[#items + 1] = {
        text = self:getPatchUpdatesSummaryText(summary),
        select_enabled = false,
    }
    items[#items].separator = true

    -- Paginate installed-patch entries (see buildUpdateBrowserItems for why).
    local patch_items = self:buildPatchUpdateItems(summary)
    local page_size = getManagePageSize()
    local display_total = #patch_items
    local total_pages = math.max(1, math.ceil(display_total / page_size))
    local page = math.min(math.max(self.patch_updates_state.page or 1, 1), total_pages)
    if self.patch_updates_state.page ~= page then
        self.patch_updates_state.page = page
    end
    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(display_total, start_index + page_size - 1)
    for i = start_index, end_index do
        items[#items + 1] = patch_items[i]
        items[#items].separator = true
    end

    return items, total_pages
end

function Storefront:updateUpdatesDialog()
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

-- Flip the installed-plugins dialog to another page: reset scroll to the top
-- (do not save the current offset) and rebuild. The builder clamps the page to
-- the valid range, so out-of-range requests settle on the nearest edge.
function Storefront:gotoUpdatesPage(page_num)
    self:ensureUpdatesState()
    local target = math.max(1, page_num or 1)
    if target == self.updates_state.page then
        return
    end
    self.updates_focus_hint = self:computePageFlipFocus(self.updates_menu, target > self.updates_state.page)
    self.updates_state.page = target
    self.updates_state.scroll_offset = nil
    -- Reset the live scroller to the top before closing: otherwise onCloseWidget's
    -- on_dismiss writes the current (old) offset back over the nil above, and the
    -- new page would open scrolled down, hiding its first rows.
    if self.updates_menu and self.updates_menu.resetScroll then
        self.updates_menu:resetScroll()
    end
    self:closeUpdatesDialog(true)
    -- A page flip doesn't change the dialog's title or overall chrome, only the
    -- list body, so it doesn't need the full flashing refresh that a genuine
    -- dialog-identity change (open/switch-tab/filter) uses to avoid ghosting.
    self._updates_refresh_mode_hint = "partial"
    self:showUpdatesDialog()
end

function Storefront:closeUpdatesDialog(skip_scroll_save)
    if self.updates_menu then
        if not skip_scroll_save and self.updates_menu.getScrollOffset then
            self:ensureUpdatesState()
            self.updates_state.scroll_offset = self.updates_menu:getScrollOffset()
        end
        UIManager:close(self.updates_menu)
        self.updates_menu = nil
    end
end

function Storefront:closePatchUpdatesDialog(skip_scroll_save)
    if self.patch_updates_menu then
        if not skip_scroll_save and self.patch_updates_menu.getScrollOffset then
            self:ensurePatchUpdatesState()
            self.patch_updates_state.scroll_offset = self.patch_updates_menu:getScrollOffset()
        end
        UIManager:close(self.patch_updates_menu)
        self.patch_updates_menu = nil
    end
end

function Storefront:showManagePluginPathsDialog()
    local hidden_paths = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
    local lookup_paths = PluginPaths.getLookupPaths()

    local button_dialog
    local buttons = {}
    for _, path in ipairs(lookup_paths) do
        local this_path = path -- upvalue capture per row
        local is_hidden = PluginPaths.isPathHidden(this_path, hidden_paths)
        local checkbox_text = is_hidden and "☐ " or "☑ "
        table.insert(buttons, {
            {
                text = checkbox_text .. this_path,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local current_hidden = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
                    local new_hidden = {}
                    local was_hidden = false
                    for _, h in ipairs(current_hidden) do
                        if PluginPaths.isPathHidden(this_path, { h }) then
                            was_hidden = true
                        else
                            table.insert(new_hidden, h)
                        end
                    end
                    if not was_hidden then
                        table.insert(new_hidden, this_path)
                    end
                    StorefrontSettings:saveSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY, new_hidden)
                    StorefrontSettings:flush()
                    UIManager:close(button_dialog)
                    UIManager:nextTick(function()
                        self:showManagePluginPathsDialog()
                    end)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
                self:closeUpdatesDialog(true)
                self:showUpdatesDialog()
            end,
        },
    })

    button_dialog = ButtonDialog:new{
        title = _("Manage plugin paths\n\nHiding a path only affects what Storefront shows/manages here. KOReader will still load plugins from it."),
        title_align = "center",
        buttons = buttons,
        -- Back-key / tap-outside dismissal doesn't go through the "Close"
        -- button's callback above, so refresh here too -- otherwise the
        -- installed-plugins list behind this dialog can look unchanged
        -- even though hide/show state was just toggled.
        tap_close_callback = function()
            self:closeUpdatesDialog(true)
            self:showUpdatesDialog()
        end,
    }
    UIManager:show(button_dialog)
end

function Storefront:showPluginUpdatesSettings()
    local button_dialog
    local buttons = {}

    if #PluginPaths.getLookupPaths() > 1 then
        table.insert(buttons, {
            {
                text = _("Manage plugin paths"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                    self:showManagePluginPathsDialog()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = string.format(_("Items per page: %d"), getManagePageSize()),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
                UIManager:show(SpinWidget:new{
                    title_text = _("Items per page"),
                    value = getManagePageSize(),
                    value_min = MIN_BROWSER_PAGE_SIZE,
                    value_max = MAX_BROWSER_PAGE_SIZE,
                    ok_text = _("Set"),
                    callback = function(spin)
                        StorefrontSettings:saveSetting(MANAGE_PAGE_SIZE_KEY, spin.value)
                        StorefrontSettings:flush()
                        self:ensureUpdatesState()
                        self.updates_state.page = 1
                        self.updates_state.scroll_offset = nil
                        -- Reset the open scroller before closing, else
                        -- on_dismiss saves the old offset back over the nil.
                        if self.updates_menu and self.updates_menu.resetScroll then
                            self.updates_menu:resetScroll()
                        end
                        self:closeUpdatesDialog(true)
                        self:showUpdatesDialog()
                    end,
                })
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
            end,
        },
    })

    button_dialog = ButtonDialog:new{
        title = _("Installed Plugins Settings"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

function Storefront:showUpdatesDialog()
    self:ensureUpdatesState()
    local summary = self:collectUpdateSummary()
    local entries, total_pages = self:buildUpdateBrowserItems(summary)
    local initial_focus = self.updates_focus_hint
    self.updates_focus_hint = nil
    local dialog = StorefrontBrowserDialog:new{
        title = _("App Store · Installed plugins"),
        items = entries,
        Storefront = self,
        page = self.updates_state.page or 1,
        total_pages = total_pages,
        initial_focus = initial_focus,
        on_settings_tap = function()
            self:showPluginUpdatesSettings()
        end,
        -- Hardware-keyboard hotkeys (r/f/t; no "s" here, this dialog has no sort).
        on_refresh = function() self:checkAllUpdates() end,
        on_filter = function() self:showPluginFilterDialog() end,
        on_switch_tab = function() self:showPatchUpdatesDialog() end,
        on_first_page = function() self:gotoUpdatesPage(1) end,
        on_prev_page = function() self:gotoUpdatesPage((self.updates_state.page or 1) - 1) end,
        on_next_page = function() self:gotoUpdatesPage((self.updates_state.page or 1) + 1) end,
        on_last_page = function() self:gotoUpdatesPage(total_pages) end,
        on_goto_page = function(page_num) self:gotoUpdatesPage(page_num) end,
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
    -- Full (flashing) e-ink refresh by default: this dialog usually replaces
    -- another full-screen Storefront dialog (the browser, settings) and on devices
    -- that default to partial refresh (e.g. Kobo) the old frame ghosts through
    -- otherwise. Old Kindle controllers flash on every update, so this is
    -- effectively a no-op there. gotoUpdatesPage narrows this to a lighter
    -- "partial" refresh for plain page flips, where the title/chrome don't change.
    local refresh_mode = self._updates_refresh_mode_hint or "full"
    self._updates_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
end

function Storefront:showPatchUpdatesSettings()
    local button_dialog
    local buttons = {
        {
            {
                text = string.format(_("Items per page: %d"), getManagePageSize()),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Items per page"),
                        value = getManagePageSize(),
                        value_min = MIN_BROWSER_PAGE_SIZE,
                        value_max = MAX_BROWSER_PAGE_SIZE,
                        ok_text = _("Set"),
                        callback = function(spin)
                            StorefrontSettings:saveSetting(MANAGE_PAGE_SIZE_KEY, spin.value)
                            StorefrontSettings:flush()
                            self:ensurePatchUpdatesState()
                            self.patch_updates_state.page = 1
                            self.patch_updates_state.scroll_offset = nil
                            -- Reset the open scroller before closing, else
                            -- on_dismiss saves the old offset back over the nil.
                            if self.patch_updates_menu and self.patch_updates_menu.resetScroll then
                                self.patch_updates_menu:resetScroll()
                            end
                            self:closePatchUpdatesDialog(true)
                            self:showPatchUpdatesDialog()
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                end,
            },
        },
    }

    button_dialog = ButtonDialog:new{
        title = _("Installed Patches Settings"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

function Storefront:showPatchUpdatesDialog()
    self:ensurePatchUpdatesState()
    local prev_scroll = self.patch_updates_state.scroll_offset
    if self.patch_updates_menu and self.patch_updates_menu.getScrollOffset then
        prev_scroll = self.patch_updates_menu:getScrollOffset()
    end
    self.patch_updates_state.scroll_offset = prev_scroll
    self:closePatchUpdatesDialog(true)
    local summary = self:collectPatchUpdateSummary()
    local entries, total_pages = self:buildPatchUpdateBrowserItems(summary)
    local initial_focus = self.patch_updates_focus_hint
    self.patch_updates_focus_hint = nil
    local dialog = StorefrontBrowserDialog:new{
        title = _("App Store · Installed patches"),
        items = entries,
        Storefront = self,
        page = self.patch_updates_state.page or 1,
        total_pages = total_pages,
        initial_focus = initial_focus,
        on_settings_tap = function()
            self:showPatchUpdatesSettings()
        end,
        -- Hardware-keyboard hotkeys (r/f/t; no "s" here, this dialog has no sort).
        on_refresh = function() self:refreshPatchUpdates() end,
        on_filter = function() self:showPatchFilterDialog() end,
        on_switch_tab = function() self:showUpdatesDialog() end,
        on_first_page = function() self:gotoPatchUpdatesPage(1) end,
        on_prev_page = function() self:gotoPatchUpdatesPage((self.patch_updates_state.page or 1) - 1) end,
        on_next_page = function() self:gotoPatchUpdatesPage((self.patch_updates_state.page or 1) + 1) end,
        on_last_page = function() self:gotoPatchUpdatesPage(total_pages) end,
        on_goto_page = function(page_num) self:gotoPatchUpdatesPage(page_num) end,
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
    -- Full refresh by default so the previous dialog does not ghost through on
    -- partial-refresh devices; narrowed to "partial" for plain page flips. See
    -- showUpdatesDialog for the rationale.
    local refresh_mode = self._patch_updates_refresh_mode_hint or "full"
    self._patch_updates_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
end

function Storefront:updatePatchUpdatesDialog()
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

function Storefront:gotoPatchUpdatesPage(page_num)
    self:ensurePatchUpdatesState()
    local target = math.max(1, page_num or 1)
    if target == self.patch_updates_state.page then
        return
    end
    self.patch_updates_focus_hint = self:computePageFlipFocus(self.patch_updates_menu, target > self.patch_updates_state.page)
    self.patch_updates_state.page = target
    self.patch_updates_state.scroll_offset = nil
    -- Reset the live scroller to the top before closing (see gotoUpdatesPage):
    -- otherwise on_dismiss writes the old offset back over the nil above.
    if self.patch_updates_menu and self.patch_updates_menu.resetScroll then
        self.patch_updates_menu:resetScroll()
    end
    self:closePatchUpdatesDialog(true)
    -- See gotoUpdatesPage: a page flip doesn't change the dialog's title/chrome,
    -- so it doesn't need the full flashing refresh used elsewhere to avoid
    -- ghosting on a genuine dialog-identity change.
    self._patch_updates_refresh_mode_hint = "partial"
    self:showPatchUpdatesDialog()
end

function Storefront:toggleUpdatesFilter()
    self:ensureUpdatesState()
    self.updates_state.filter_only_outdated = not self.updates_state.filter_only_outdated
    self:updateUpdatesDialog()
end

function Storefront:toggleLinkedFilter()
    self:ensureUpdatesState()
    self.updates_state.filter_only_linked = not self.updates_state.filter_only_linked
    self:updateUpdatesDialog()
end

function Storefront:showPluginFilterDialog()
    self:ensureUpdatesState()
    local current_outdated = self.updates_state.filter_only_outdated
    local current_linked = self.updates_state.filter_only_linked

    local function makeCheckbox(enabled)
        return enabled and "☑ " or "☐ "
    end

    local buttons = {
        {
            {
                text = makeCheckbox(not current_outdated and not current_linked) .. _("All plugins"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = false
                    self.updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_outdated) .. _("Needs update"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = true
                    self.updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_linked) .. _("Linked only"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                    self.updates_state.filter_only_outdated = false
                    self.updates_state.filter_only_linked = true
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.updates_state, self.updates_menu)
                    UIManager:nextTick(function()
                        self:updateUpdatesDialog()
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.plugin_filter_dialog)
                end,
            },
        },
    }

    self.plugin_filter_dialog = ButtonDialog:new{
        title = _("Filter Installed Plugins"),
        buttons = buttons,
    }
    UIManager:show(self.plugin_filter_dialog)
end

function Storefront:togglePatchUpdatesFilter()
    self:ensurePatchUpdatesState()
    self.patch_updates_state.filter_only_outdated = not self.patch_updates_state.filter_only_outdated
    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:togglePatchLinkedFilter()
    self:ensurePatchUpdatesState()
    self.patch_updates_state.filter_only_linked = not self.patch_updates_state.filter_only_linked
    if self.patch_updates_menu then
        self:updatePatchUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:showPatchFilterDialog()
    self:ensurePatchUpdatesState()
    local current_outdated = self.patch_updates_state.filter_only_outdated
    local current_linked = self.patch_updates_state.filter_only_linked

    local function makeCheckbox(enabled)
        return enabled and "☑ " or "☐ "
    end

    local buttons = {
        {
            {
                text = makeCheckbox(not current_outdated and not current_linked) .. _("All patches"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = false
                    self.patch_updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_outdated) .. _("Needs update"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = true
                    self.patch_updates_state.filter_only_linked = false
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = makeCheckbox(current_linked) .. _("Linked only"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                    self.patch_updates_state.filter_only_outdated = false
                    self.patch_updates_state.filter_only_linked = true
                    -- A new filter changes the matching set, so restart at page 1.
                    self:resetPageAndScroll(self.patch_updates_state, self.patch_updates_menu)
                    UIManager:nextTick(function()
                        if self.patch_updates_menu then
                            self:updatePatchUpdatesDialog()
                        else
                            self:showPatchUpdatesDialog()
                        end
                    end)
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(self.patch_filter_dialog)
                end,
            },
        },
    }

    self.patch_filter_dialog = ButtonDialog:new{
        title = _("Filter Installed Patches"),
        buttons = buttons,
    }
    UIManager:show(self.patch_filter_dialog)
end

function Storefront:checkAllUpdates()
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
        local GitHub = require("storefront_net_github")

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
                    ["User-Agent"] = "KOReader-Storefront",
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

        local function derivePluginRepoPathWorker(plugin_root)
            if not plugin_root or plugin_root == "" then
                return nil
            end
            local plugins_match = plugin_root:match("(plugins/.*)")
            if plugins_match and plugins_match ~= "" then
                return plugins_match
            end
            local koplugin_match = plugin_root:match("(%w[%w_%-%.]*%.koplugin.*)") or plugin_root:match("([^/]+%.koplugin.*)")
            if koplugin_match and koplugin_match ~= "" then
                return koplugin_match
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

        local function normalizeMetaPathWorker(path)
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

        local function buildMetaPathCandidatesWorker(record)
            if not record then
                return {}
            end
            local seen = {}
            local candidates = {}
            local function add(path)
                if not path or path == "" then
                    return
                end
                local normalized = normalizeMetaPathWorker(path)
                if not normalized or seen[normalized] then
                    return
                end
                seen[normalized] = true
                table.insert(candidates, normalized)
            end

            add(record.meta_path)
            if record.meta_path then
                add(derivePluginRepoPathWorker(record.meta_path))
            end
            add(record.meta_path_hint)

            if record.meta_path then
                local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
                add(trimmed)
                add(derivePluginRepoPathWorker(trimmed))
            end
            if record.meta_path_hint then
                local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
                add(trimmed)
            end

            if record.dirname and record.dirname ~= "" then
                add("plugins/" .. record.dirname .. "/_meta.lua")
                add(record.dirname .. "/_meta.lua")
                if record.dirname:match("%.koplugin$") then
                    local without_suffix = record.dirname:gsub("%.koplugin$", "")
                    add("plugins/" .. without_suffix .. "/_meta.lua")
                    add(without_suffix .. "/_meta.lua")
                end
            end

            add("plugins/_meta.lua")
            add("_meta.lua")

            return candidates
        end

        local function runCheckAllUpdatesWorker(records_worker)
            local result = {}
            for _, record in ipairs(records_worker or {}) do
                local dirname = record.dirname
                local owner = record.owner
                local repo_name = record.repo
                local remote_version
                local remote_repo_ts = 0
                local release_tag_name
                local release_published_at
                local last_err

                if not owner or not repo_name then
                    last_err = "Missing repository info."
                else
                    local cached_repo = Cache.getRepoByName(owner, repo_name) or (record.repo_id and Cache.getRepo(record.repo_id))
                    if cached_repo and not GitHub.isDirectApiEnabled() then
                        local rel = cached_repo.latest_release or (cached_repo.data and cached_repo.data.latest_release)
                        if rel and rel.tag_name then
                            release_tag_name = rel.tag_name
                            release_published_at = parseGitHubTimestampWorker(rel.published_at)
                        end
                        if not release_tag_name and cached_repo.version then
                            release_tag_name = cached_repo.version
                        end
                        local ts = cached_repo.data and (cached_repo.data.pushed_at or cached_repo.data.created_at)
                        remote_repo_ts = parseGitHubTimestampWorker(ts)
                    else
                        local latest_release, release_err = GitHub.fetchLatestRelease(owner, repo_name)
                        
                        if latest_release and latest_release.tag_name then
                            if not latest_release.prerelease and not latest_release.draft then
                                local tag_lower = latest_release.tag_name:lower()
                                local is_prerelease_tag = tag_lower:find("alpha", 1, true) or 
                                                          tag_lower:find("beta", 1, true) or 
                                                          tag_lower:find("rc", 1, true) or 
                                                          tag_lower:find("dev", 1, true) or 
                                                          tag_lower:find("preview", 1, true) or 
                                                          tag_lower:find("pre", 1, true) or 
                                                          tag_lower:find("test", 1, true)
                                
                                if not is_prerelease_tag then
                                    release_tag_name = latest_release.tag_name
                                    release_published_at = parseGitHubTimestampWorker(latest_release.published_at)
                                end
                            end
                        end
                        
                        if not release_tag_name then
                            local releases, fetch_err = GitHub.fetchReleases(owner, repo_name, {
                                per_page = 30,
                                max_pages = 1,
                            })
                            
                            if releases and #releases > 0 then
                                for _, release in ipairs(releases) do
                                    if not release.draft and not release.prerelease then
                                        local tag_lower = release.tag_name:lower()
                                        local is_prerelease_tag = tag_lower:find("alpha", 1, true) or 
                                                                  tag_lower:find("beta", 1, true) or 
                                                                  tag_lower:find("rc", 1, true) or 
                                                                  tag_lower:find("dev", 1, true) or 
                                                                  tag_lower:find("preview", 1, true) or 
                                                                  tag_lower:find("pre", 1, true) or 
                                                                  tag_lower:find("test", 1, true)
                                        
                                        if not is_prerelease_tag then
                                            release_tag_name = release.tag_name
                                            release_published_at = parseGitHubTimestampWorker(release.published_at)
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        
                        local metadata, metadata_err = GitHub.fetchRepoMetadata(owner, repo_name)
                        if metadata and type(metadata) == "table" then
                            local ts = metadata.pushed_at or metadata.created_at
                            remote_repo_ts = parseGitHubTimestampWorker(ts)
                        else
                            last_err = metadata_err or last_err
                        end
                    end

                    local meta_path = record.meta_path
                    if (not meta_path or meta_path == "") and dirname and dirname ~= "" then
                        meta_path = dirname .. "/_meta.lua"
                    end

                    local branch = record.branch
                    if (not branch or branch == "") and metadata and type(metadata) == "table" then
                        branch = metadata.default_branch or metadata.master_branch or "HEAD"
                    end

                    local candidates = buildMetaPathCandidatesWorker and buildMetaPathCandidatesWorker(record) or {}
                    if #candidates == 0 and meta_path then
                        table.insert(candidates, meta_path)
                    end

                    local found_body = nil
                    local working_meta_path = nil
                    for _, candidate in ipairs(candidates) do
                        local body, err = fetchGitHubRawWorker(owner, repo_name, branch, candidate)
                        if body then
                            found_body = body
                            working_meta_path = candidate
                            break
                        else
                            last_err = err or last_err
                        end
                    end

                    if found_body then
                        local version = extractMetaFieldWorker(found_body, "version")
                        if version then
                            remote_version = version
                            if working_meta_path and working_meta_path ~= record.meta_path then
                                record.meta_path = working_meta_path
                                pcall(function() InstallStore.upsert(dirname, record) end)
                            end
                        else
                            last_err = "Remote version not found."
                        end
                    else
                        last_err = last_err or "Missing meta path in record."
                    end
                end

                if dirname and dirname ~= "" then
                    result[dirname] = {
                        remote_version = remote_version,
                        remote_repo_ts = remote_repo_ts,
                        release_tag_name = release_tag_name,
                        release_published_at = release_published_at,
                        error = last_err,
                        last_checked = os.time(),
                    }
                end
            end
            return result
        end

        local info = InfoMessage:new{
            text = _("Checking plugin updates…"),
            timeout = 0,
            dismissable = false,
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
            return
        end

        self:ensureUpdatesState()
        local remote_info = self.updates_state.remote_info or {}
        for dirname, data in pairs(remote_info_result) do
            if not data.error or not remote_info[dirname] then
                remote_info[dirname] = data
            elseif remote_info[dirname] then
                remote_info[dirname].error = data.error
            end
        end
        self.updates_state.remote_info = remote_info
        self.updates_state.last_checked = os.time()
        -- Fix 4: Bust the summary cache. The cache key is the remote_info table
        -- reference, but we mutate it in-place, so the reference never changes and
        -- stale has_update values survive. Clearing the cache forces recomputation.
        self._cached_plugin_summary = nil
        self:updateUpdatesDialog()
        self:saveUpdatesState()
        UIManager:setDirty(nil, "full")
    end)
end

function Storefront:_checkAllUpdatesInternal(records)
    self:ensureUpdatesState()
    local progress = InfoMessage:new{ text = _("Checking plugin updates…"), timeout = 0 }
    UIManager:show(progress)
    local remote_info = self.updates_state.remote_info or {}
    for _, record in ipairs(records) do
        local remote_version, remote_repo_ts, err, release_tag_name = self:fetchRemoteVersionForRecord(record)
        local prev = remote_info[record.dirname] or {}
        remote_info[record.dirname] = {
            remote_version = remote_version or prev.remote_version,
            remote_repo_ts = remote_repo_ts or prev.remote_repo_ts or 0,
            release_tag_name = release_tag_name or prev.release_tag_name,
            error = err,
            last_checked = os.time(),
        }
    end
    UIManager:close(progress)
    self.updates_state.remote_info = remote_info
    self.updates_state.last_checked = os.time()
    -- Fix 4: bust summary cache (see companion note in subprocess path above)
    self._cached_plugin_summary = nil
    self:updateUpdatesDialog()
    self:saveUpdatesState()
    UIManager:setDirty(nil, "full")
end

local function findLatestRelease(owner, repo, allow_beta)
    local GitHub = require("storefront_net_github")

    if allow_beta then
        local releases, fetch_err = GitHub.fetchReleases(owner, repo, {
            per_page = 10,
            max_pages = 1,
        })
        if releases and #releases > 0 then
            for _, release in ipairs(releases) do
                if not release.draft then
                    return release, nil
                end
            end
        end
    end

    local latest, err = GitHub.fetchLatestRelease(owner, repo)

    if latest and latest.tag_name then
        if not latest.prerelease and not latest.draft then
            if not isPreReleaseTag(latest.tag_name) then
                return latest, nil
            end
        end
    end

    local releases, fetch_err = GitHub.fetchReleases(owner, repo, {
        per_page = 30,
        max_pages = 1,
    })

    if not releases or #releases == 0 then
        return nil, fetch_err or err or "No releases found"
    end

    for _, release in ipairs(releases) do
        if not release.draft and not release.prerelease then
            if not isPreReleaseTag(release.tag_name) then
                return release, nil
            end
        end
    end

    return nil, "No stable release found"
end

-- Pure network-fetching core of fetchRemoteVersionForRecord below -- touches
-- no `self` state, so it's safe to run inside a forked subprocess (see
-- Storefront:_checkSinglePluginInternal, which does exactly that so a slow
-- or unreachable repo can't block the UI thread for several seconds).
-- Returns remote_version, remote_repo_ts, err, release_tag_name,
-- updated_meta_path, updated_branch -- the last two are only set when a
-- meta_path/branch different from the record's own is the one that worked.
local function fetchRemoteVersionCore(record)
    if not record or not record.owner or not record.repo then
        return nil, 0, _("Not matched with a repository.")
    end

    local owner = record.owner
    local repo_name = record.repo
    local last_err

    local is_storefront = record.dirname == "storefront.koplugin"
        or (record.repo and record.repo:lower():match("storefront%.koplugin"))
    local allow_beta = is_storefront and (require("storefront_about_dialog").getChannel() == "beta")

    local latest_release = findLatestRelease(owner, repo_name, allow_beta)

    if latest_release and latest_release.tag_name then
        local release_version = parseVersionFromTag(latest_release.tag_name)
        local release_ts = parseGitHubTimestamp(latest_release.published_at)
        return release_version, release_ts, nil, latest_release.tag_name
    end

    local meta_candidates = buildMetaPathCandidates(record)
    if #meta_candidates == 0 then
        return nil, 0, _("Missing meta path in record.")
    end

    local branch_candidates = buildBranchCandidates(record)
    local remote_repo_ts = 0
    local metadata, metadata_err = GitHub.fetchRepoMetadata(owner, repo_name)
    if metadata and type(metadata) == "table" then
        local ts = metadata.pushed_at or metadata.created_at
        remote_repo_ts = parseGitHubTimestamp(ts)
    else
        last_err = metadata_err or last_err
    end

    for _, meta_path in ipairs(meta_candidates) do
        for _, branch in ipairs(branch_candidates) do
            local body, err = fetchGitHubRaw(owner, repo_name, branch, meta_path)
            if body then
                local version = extractMetaField(body, "version")
                if version then
                    local updated_meta_path, updated_branch
                    if record.dirname and (record.meta_path ~= meta_path or record.branch ~= branch) then
                        updated_meta_path, updated_branch = meta_path, branch
                    end
                    return version, remote_repo_ts, nil, nil, updated_meta_path, updated_branch
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

    if last_err then
        local msg = tostring(last_err)
        if msg:find("404", 1, true) or msg == _("Remote version not found.") then
            return nil, remote_repo_ts, nil
        end
    end

    return nil, remote_repo_ts, last_err or _("Remote version not found.")
end

-- Applies the `self`-touching side effects that fetchRemoteVersionCore
-- itself can't (see its comment) -- shared by fetchRemoteVersionForRecord
-- and _checkSinglePluginInternal, the latter calling it on the parent
-- process only after its subprocess worker has already returned.
function Storefront:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, updated_meta_path, updated_branch)
    if release_tag_name then
        self:ensureUpdatesState()
        local dirname = record.dirname
        if dirname then
            local cached = self.updates_state.remote_info[dirname] or {}
            cached.release_tag_name = release_tag_name
            cached.release_published_at = remote_repo_ts
            self.updates_state.remote_info[dirname] = cached
        end
    elseif updated_meta_path then
        self:updateInstallRecord(record.dirname, { meta_path = updated_meta_path, branch = updated_branch })
        record.meta_path = updated_meta_path
        record.branch = updated_branch
    end
end

function Storefront:fetchRemoteVersionForRecord(record)
    local remote_version, remote_repo_ts, err, release_tag_name, updated_meta_path, updated_branch =
        fetchRemoteVersionCore(record)
    self:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, updated_meta_path, updated_branch)
    return remote_version, remote_repo_ts, err, release_tag_name
end

function Storefront:getUnmatchedPlugins()
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

function Storefront:startMatchFlow()
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

function Storefront:startMatchFlowForPlugin(plugin)
    if not plugin then
        return
    end
    self.match_context = { kind = "plugin", plugin = plugin }
    self:ensureBrowserState()
    self.browser_state.kind = "plugin"
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    
    local search_text = plugin.dirname or ""
    if search_text ~= "" then
        search_text = search_text:gsub("%.koplugin$", "")
        self.browser_state.search_text = search_text
    end
    
    self:saveBrowserState()
    self:closeUpdatesDialog()
    UIManager:setDirty(nil, "ui")
    UIManager:show(InfoMessage:new{ text = _("Select a repository to match with the chosen plugin."), timeout = 4 })
    self:showBrowser("plugin")
end

function Storefront:matchPluginWithRepo(plugin, repo)
    if not plugin or not repo then
        return
    end
    StorefrontLogger.action(string.format("MATCH plugin: %s matched with repo %s", tostring(plugin.dirname), tostring(repo.full_name or repo.name)))
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

function Storefront:promptManualMatchForPlugin(plugin)
    if not plugin then
        return
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Match plugin with GitHub repository"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Match"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:verifyAndMatchPluginWithManualRepo(plugin, owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:verifyAndMatchPluginWithManualRepo(plugin, owner, repo_name)
    if not plugin or not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Verifying repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        UIManager:close(progress)
        
        if not repo_data or not repo_data.id then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "plugin",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        self:matchPluginWithRepo(plugin, repo)
    end)
end

function Storefront:promptUpdateAction(plugin, record)
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
    local other_buttons_row2 = {}
    
    if record and record.owner and record.repo then
        table.insert(other_buttons, {
            text = _("Check this plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePlugin(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:updatePluginFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Unlink the repo"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                -- Clear repo info but preserve installed_version for future re-matching
                local existing = InstallStore.get(plugin.dirname)
                local preserved_version = existing and existing.installed_version
                
                -- Clear ignored release for this repo
                if record.owner and record.repo then
                    clearIgnoredRelease(record.owner, record.repo)
                end
                
                InstallStore.remove(plugin.dirname)
                if preserved_version then
                    -- Store minimal record with just dirname and version
                    InstallStore.upsert(plugin.dirname, {
                        dirname = plugin.dirname,
                        plugin_name = plugin.name,
                        installed_version = preserved_version,
                    })
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Unlinked %s from repository."), plugin.name or plugin.dirname),
                    timeout = 3,
                })
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
                self:promptUpdateAction(plugin, nil)
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match from List"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:startMatchFlowForPlugin(plugin)
            end,
        })
        table.insert(other_buttons, {
            text = _("Match with URL"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:promptManualMatchForPlugin(plugin)
            end,
        })
    end
    
    local is_disabled = isPluginDisabled(plugin.dirname)
    if is_disabled then
        table.insert(other_buttons_row2, {
            text = _("Enable plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:enablePlugin(plugin.dirname)
                showRestartConfirmation(string.format(_("Plugin '%s' enabled."), plugin.name or plugin.dirname))
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end,
        })
    else
        table.insert(other_buttons_row2, {
            text = _("Disable plugin"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:disablePlugin(plugin.dirname)
                showRestartConfirmation(string.format(_("Plugin '%s' disabled."), plugin.name or plugin.dirname))
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end,
        })
    end
    
    table.insert(other_buttons_row2, {
        text = _("Modify Plugin"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:modifyPlugin(plugin)
        end,
    })

    table.insert(other_buttons_row2, {
        text = _("Delete plugin"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:deletePlugin(plugin.dirname, record)
        end,
    })

    info_box = ConfirmBox:new{
        text = plugin.name or plugin.dirname,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons, other_buttons_row2 },
    }
    UIManager:show(info_box)
end

function Storefront:promptPatchUpdateAction(patch_item)
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
    local other_buttons_row2 = {}
    
    if record and record.owner and record.repo and record.path then
        table.insert(other_buttons, {
            text = _("Check this patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:checkSinglePatch(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Update patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:updatePatchFromRecord(record)
            end,
        })
        table.insert(other_buttons, {
            text = _("Unlink the repo"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                -- Clear repo info but preserve SHA so it can be used when re-matching
                local existing = InstallStore.getPatch(patch.filename)
                local preserved_sha = existing and existing.sha
                InstallStore.removePatch(patch.filename)
                if preserved_sha then
                    -- Store minimal record with just filename and SHA
                    InstallStore.upsertPatch(patch.filename, {
                        filename = patch.filename,
                        sha = preserved_sha,
                    })
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Unlinked %s from repository."), patch.filename),
                    timeout = 3,
                })
                if self.patch_updates_menu then
                    self:updatePatchUpdatesDialog()
                end
                self:promptPatchUpdateAction({ patch = patch, record = nil, remote_entry = nil, needs_update = false })
            end,
        })
    else
        table.insert(other_buttons, {
            text = _("Match from List"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:startPatchMatchFlow(patch)
            end,
        })
        table.insert(other_buttons, {
            text = _("Match with URL"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                self:promptManualMatchForPatch(patch)
            end,
        })
    end
    
    local is_disabled = patch.disabled or isPatchDisabled(patch.filename)
    if is_disabled then
        table.insert(other_buttons_row2, {
            text = _("Enable patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                local ok = self:enablePatch(patch.filename)
                if ok then
                    showRestartConfirmation(string.format(_("Patch '%s' enabled."), patch.filename))
                    if self.patch_updates_menu then
                        self:updatePatchUpdatesDialog()
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to enable patch '%s'."), patch.filename),
                        timeout = 4,
                    })
                end
            end,
        })
    else
        table.insert(other_buttons_row2, {
            text = _("Disable patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(info_box)
                local ok = self:disablePatch(patch.filename)
                if ok then
                    showRestartConfirmation(string.format(_("Patch '%s' disabled."), patch.filename))
                    if self.patch_updates_menu then
                        self:updatePatchUpdatesDialog()
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to disable patch '%s'."), patch.filename),
                        timeout = 4,
                    })
                end
            end,
        })
    end
    
    table.insert(other_buttons_row2, {
        text = _("Modify Patch"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            local patch_path = PATCHES_ROOT .. "/" .. patch.filename
            local PluginLoader = require("pluginloader")
            local te = PluginLoader:getPluginInstance("texteditor")
            if te and te.checkEditFile then
                te:checkEditFile(patch_path)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Text editor plugin is not available."),
                    timeout = 4,
                })
            end
        end,
    })

    table.insert(other_buttons_row2, {
        text = _("Delete patch"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(info_box)
            self:deletePatch(patch.filename, record)
        end,
    })

    info_box = ConfirmBox:new{
        text = patch.filename or patch.path or _("Patch"),
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = makeTextBox(table.concat(lines, "\n")),
        other_buttons = { other_buttons, other_buttons_row2 },
    }
    UIManager:show(info_box)
end

-- ─── Modify Plugin ────────────────────────────────────────────────────────────

function Storefront:modifyPlugin(plugin)
    if not plugin or not plugin.dirname then
        return
    end
    self:showPluginFilesDialog(plugin, true)
end

function Storefront:showPluginFilesDialog(plugin, filter_config_only)
    local plugin_path = plugin.path
    if lfs.attributes(plugin_path, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Plugin directory not found."),
            timeout = 3,
        })
        return
    end

    -- Collect all .lua files recursively
    local all_files = {}
    local function scan_dir(dir, prefix)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local rel  = (prefix == "") and entry or (prefix .. "/" .. entry)
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    scan_dir(full, rel)
                elseif mode == "file" and entry:match("%.lua$") then
                    table.insert(all_files, { path = full, name = entry, rel = rel })
                end
            end
        end
    end
    scan_dir(plugin_path, "")
    table.sort(all_files, function(a, b) return a.rel < b.rel end)

    -- Apply filter
    local filtered = {}
    if filter_config_only then
        for _, f in ipairs(all_files) do
            if f.name:lower():find("config", 1, true) then
                table.insert(filtered, f)
            end
        end
    else
        filtered = all_files
    end

    local dialog
    local buttons = {}

    -- Toggle filter checkbox row
    local filter_label = filter_config_only
        and ("\xE2\x98\x91 " .. _("Config files only"))
        or  ("\xE2\x98\x90 " .. _("Config files only"))
    table.insert(buttons, {
        {
            text = filter_label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showPluginFilesDialog(plugin, not filter_config_only)
            end,
        },
    })

    if #filtered == 0 then
        local msg = filter_config_only
            and _("No config files found — uncheck filter to show all files")
            or  _("No Lua files found in plugin directory")
        table.insert(buttons, {
            {
                text = msg,
                background = Blitbuffer.COLOR_WHITE,
                callback = function() end,
            },
        })
    else
        for _, f in ipairs(filtered) do
            local file = f  -- upvalue capture
            table.insert(buttons, {
                {
                    text = file.rel,
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                        self:showPluginFileActionDialog(plugin, file.path, file.name, filter_config_only)
                    end,
                },
            })
        end
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = string.format(_("Modify Plugin: %s"), plugin.name or plugin.dirname),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Storefront:showPluginFileActionDialog(plugin, filepath, filename, filter_config_only)
    local dialog
    local buttons = {}

    -- Edit
    table.insert(buttons, {
        {
            text = _("Edit"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local PluginLoader = require("pluginloader")
                local te = PluginLoader:getPluginInstance("texteditor")
                if te and te.checkEditFile then
                    te:checkEditFile(filepath)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Text editor plugin is not available."),
                        timeout = 4,
                    })
                end
            end,
        },
    })

    -- Copy
    table.insert(buttons, {
        {
            text = _("Copy"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local copy_dialog
                copy_dialog = InputDialog:new{
                    title = _("Copy file as"),
                    input = filename,
                    input_hint = _("New filename"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(copy_dialog)
                                end,
                            },
                            {
                                text = _("Copy"),
                                is_enter_default = true,
                                callback = function()
                                    local new_name = util.trim(copy_dialog:getInputText() or "")
                                    if new_name == "" then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Filename cannot be empty."),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    local dir = filepath:match("^(.*)[\\/]")
                                    local new_path = dir .. "/" .. new_name
                                    local src = io.open(filepath, "rb")
                                    if not src then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Cannot read source file."),
                                            timeout = 3,
                                        })
                                        UIManager:close(copy_dialog)
                                        return
                                    end
                                    local content = src:read("*all")
                                    src:close()
                                    local dst = io.open(new_path, "wb")
                                    if not dst then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Cannot write destination file."),
                                            timeout = 3,
                                        })
                                        UIManager:close(copy_dialog)
                                        return
                                    end
                                    dst:write(content)
                                    dst:close()
                                    UIManager:close(copy_dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("Copied to '%s'."), new_name),
                                        timeout = 3,
                                    })
                                    self:showPluginFilesDialog(plugin, filter_config_only)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(copy_dialog)
                copy_dialog:onShowKeyboard()
            end,
        },
    })

    -- Rename
    table.insert(buttons, {
        {
            text = _("Rename"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                local rename_dialog
                rename_dialog = InputDialog:new{
                    title = _("Rename file"),
                    input = filename,
                    input_hint = _("New filename"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(rename_dialog)
                                end,
                            },
                            {
                                text = _("Rename"),
                                is_enter_default = true,
                                callback = function()
                                    local new_name = util.trim(rename_dialog:getInputText() or "")
                                    if new_name == "" then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Filename cannot be empty."),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    local dir = filepath:match("^(.*)[\\/]")
                                    local new_path = dir .. "/" .. new_name
                                    local ok, err = os.rename(filepath, new_path)
                                    if not ok then
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Rename failed: %s"), tostring(err)),
                                            timeout = 4,
                                        })
                                    else
                                        UIManager:close(rename_dialog)
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Renamed to '%s'."), new_name),
                                            timeout = 3,
                                        })
                                        self:showPluginFilesDialog(plugin, filter_config_only)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(rename_dialog)
                rename_dialog:onShowKeyboard()
            end,
        },
    })

    -- Delete
    table.insert(buttons, {
        {
            text = _("Delete"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete file '%s'?\n\nThis cannot be undone."), filename),
                    ok_text = _("Delete"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local ok, err = os.remove(filepath)
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Deleted '%s'."), filename),
                                timeout = 3,
                            })
                            self:showPluginFilesDialog(plugin, filter_config_only)
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to delete: %s"), tostring(err)),
                                timeout = 4,
                            })
                        end
                    end,
                })
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = filename,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ─── End Modify Plugin ────────────────────────────────────────────────────────

function Storefront:disablePlugin(dirname)
    if not dirname or dirname == "" then
        return false
    end
    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local plugin_name = dirname:gsub("%.koplugin$", "")
    plugins_disabled[plugin_name] = true
    G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
    return true
end

function Storefront:enablePlugin(dirname)
    if not dirname or dirname == "" then
        return false
    end
    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local plugin_name = dirname:gsub("%.koplugin$", "")
    plugins_disabled[plugin_name] = nil
    G_reader_settings:saveSetting("plugins_disabled", plugins_disabled)
    return true
end

function Storefront:performPluginDeletion(dirname, record, plugin_instance_for_settings)
    StorefrontLogger.action(string.format("DELETE starting: plugin %s", tostring(dirname)))
    local plugin = findInstalledPlugin(dirname)
    local display_name = plugin and (plugin.name or plugin.dirname) or dirname

    local plugin_path = (plugin and plugin.path) or (PluginPaths.getDefaultPluginsRoot() .. "/" .. dirname)
    local ok, err = deleteDirectoryRecursive(plugin_path)
    if ok then
        if plugin_instance_for_settings then
            if type(plugin_instance_for_settings.deletePluginSettings) == "function" then
                pcall(plugin_instance_for_settings.deletePluginSettings, plugin_instance_for_settings)
            end
            
            if plugin_instance_for_settings.settings_file then
                os.remove(plugin_instance_for_settings.settings_file)
                os.remove(plugin_instance_for_settings.settings_file .. ".old")
            end
            
            if plugin_instance_for_settings.settings_key then
                G_reader_settings:delSetting(plugin_instance_for_settings.settings_key)
            end
            
            G_reader_settings:flush()
        end
        
        if record then
            InstallStore.remove(dirname)
        end
        StorefrontLogger.action(string.format("DELETED plugin %s from disk (%s)", tostring(dirname), plugin_path))
        showRestartConfirmation(string.format(_("Plugin '%s' deleted."), display_name))
        if self.updates_menu then
            self:updateUpdatesDialog()
        end
    else
        StorefrontLogger.err(string.format("DELETE failed for plugin %s: %s", tostring(dirname), tostring(err)))
        UIManager:show(InfoMessage:new{
            text = string.format(_("Failed to delete plugin: %s"), tostring(err)),
            timeout = 5,
        })
    end
end

function Storefront:deletePlugin(dirname, record)
    if not dirname or dirname == "" then
        return
    end
    local plugin = findInstalledPlugin(dirname)
    local display_name = plugin and (plugin.name or plugin.dirname) or dirname
    
    local PluginLoader = require("pluginloader")
    local plugin_name = dirname:gsub("%.koplugin$", "")
    local plugin_instance = PluginLoader:getPluginInstance(plugin_name)
    
    local delete_settings = false
    local confirm_box
    confirm_box = ConfirmBox:new{
        text = string.format(_("Delete plugin '%s'?\n\nThis action cannot be undone.\n\nChanges will take effect after restart."), display_name),
        ok_text = _("Delete"),
        ok_callback = function()
            self:performPluginDeletion(dirname, record, delete_settings and plugin_instance)
        end,
        cancel_text = _("Cancel"),
    }
    
    local check_button = CheckButton:new{
        text = _("Also delete plugin settings"),
        checked = false,
        parent = confirm_box,
        callback = function()
            delete_settings = not delete_settings
            if delete_settings and not plugin_instance then
                local is_filemanager = self.ui and self.ui.file_chooser
                local message
                if is_filemanager then
                    message = _("Plugin is not currently loaded, so settings cannot be deleted.\n\nThis plugin may only be available in Reader mode. Try deleting from a document if you want to delete settings.")
                else
                    message = _("Plugin is not currently loaded, so settings cannot be deleted.")
                end
                UIManager:show(InfoMessage:new{
                    text = message,
                    timeout = 8,
                })
            end
        end,
    }
    confirm_box:addWidget(check_button)
    
    UIManager:show(confirm_box)
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
        logger.warn("Failed to disable patch:", filename, err)
        return false
    end
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
        logger.warn("Failed to enable patch:", filename, err)
        return false
    end
    return true
end

function Storefront:deletePatch(filename, record)
    if not filename or filename == "" then
        return
    end
    local display_name = filename
    
    local confirm_box
    confirm_box = ConfirmBox:new{
        text = string.format(_("Delete patch '%s'?\n\nThis action cannot be undone.\n\nChanges will take effect after restart."), display_name),
        ok_text = _("Delete"),
        ok_callback = function()
            local patch_path = PATCHES_ROOT .. "/" .. filename
            local ok, err = os.remove(patch_path)
            if ok then
                if record then
                    InstallStore.removePatch(filename)
                end
                showRestartConfirmation(string.format(_("Patch '%s' deleted."), display_name))
                if self.patch_updates_menu then
                    self:updatePatchUpdatesDialog()
                end
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Failed to delete patch: %s"), tostring(err)),
                    timeout = 5,
                })
            end
        end,
        cancel_text = _("Cancel"),
    }
    UIManager:show(confirm_box)
end

function Storefront:checkSinglePlugin(record)
    if not record then
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:_checkSinglePluginInternal(record)
    end)
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
        self:_refreshPatchUpdatesInternal({ copy })
    end)
    UIManager:show(InfoMessage:new{ text = string.format(_("Checking %s…"), patch_name), timeout = 3 })
end

function Storefront:_checkSinglePluginInternal(record)
    self:ensureUpdatesState()
    local plugin_name = record.dirname or _("plugin")
    -- Runs the actual network fetching in a forked subprocess (same pattern
    -- as checkAllUpdates) instead of calling fetchRemoteVersionForRecord
    -- directly: that used to block KOReader's whole UI thread -- often for
    -- several seconds, across multiple sequential GitHub requests -- for a
    -- repo with a slow/unreachable connection, which looked like a freeze
    -- or crash rather than a slow check.
    local Trapper = require("ui/trapper")
    local progress = InfoMessage:new{
        text = string.format(_("Checking %s…"), plugin_name),
        timeout = 0,
        dismissable = false,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()

    local completed, result = Trapper:dismissableRunInSubprocess(function()
        local remote_version, remote_repo_ts, err, release_tag_name, updated_meta_path, updated_branch =
            fetchRemoteVersionCore(record)
        return {
            remote_version = remote_version,
            remote_repo_ts = remote_repo_ts,
            err = err,
            release_tag_name = release_tag_name,
            updated_meta_path = updated_meta_path,
            updated_branch = updated_branch,
        }
    end, progress)

    UIManager:close(progress)

    if not completed then
        UIManager:show(InfoMessage:new{ text = _("Update check was cancelled"), timeout = 4 })
        return
    end
    if type(result) ~= "table" then
        return
    end

    local remote_version = result.remote_version
    local remote_repo_ts = result.remote_repo_ts
    local err = result.err
    local release_tag_name = result.release_tag_name
    self:applyRemoteVersionResult(record, remote_repo_ts, release_tag_name, result.updated_meta_path, result.updated_branch)

    local cached = self.updates_state.remote_info[record.dirname] or {}
    cached.remote_version = remote_version
    cached.remote_repo_ts = remote_repo_ts
    cached.release_tag_name = release_tag_name
    cached.error = err
    cached.last_checked = os.time()
    self.updates_state.remote_info[record.dirname] = cached
    -- Fix 4: bust summary cache (remote_info mutated in-place; reference unchanged)
    self._cached_plugin_summary = nil
    self:updateUpdatesDialog()
    self:saveUpdatesState()

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

function Storefront:updatePluginFromRecord(record)
    if record then
        StorefrontLogger.action(string.format("UPDATE plugin starting: dirname=%s (repo=%s/%s, version=%s)", tostring(record.dirname), tostring(record.owner), tostring(record.repo), tostring(record.installed_version)))
    end
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

function Storefront:updatePatchFromRecord(record)
    if record then
        StorefrontLogger.action(string.format("UPDATE patch starting: filename=%s (repo=%s/%s)", tostring(record.filename), tostring(record.owner), tostring(record.repo)))
    end
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

function Storefront:cancelMatchContext()
    self.match_context = nil
end

function Storefront:startPatchMatchFlow(patch)
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

function Storefront:matchPatchWithRepo(patch, repo, patch_entry)
    if type(patch) == "string" then
        patch = findInstalledPatch(patch)
    end
    if not patch or not repo or not patch_entry then
        return
    end
    StorefrontLogger.action(string.format("MATCH patch: %s matched with repo %s", tostring(patch.filename), tostring(repo.full_name or repo.name)))
    local from_patch_updates = self.match_context
        and self.match_context.kind == "patch"
        and self.match_context.from_patch_updates
    -- Don't include SHA during match (include_sha=false). If the patch was previously
    -- installed, the existing SHA will be preserved. If not, it stays nil and the
    -- fallback mechanism (line 606-609) will compare remote_sha against local_sha,
    -- correctly detecting updates for manually installed old files.
    local record = buildPatchRecordFields(patch.filename, repo, patch_entry, false)
    if not record then
        UIManager:show(InfoMessage:new{ text = _("Unable to store match for patch."), timeout = 4 })
        return
    end
    InstallStore.upsertPatch(patch.filename, record)
    -- Keep the in-memory remote_info cache consistent so the patch updates
    -- dialog reflects the newly matched SHA immediately, without a full refresh.
    self:updateSinglePatchStatus(patch.filename, record)
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

function Storefront:promptManualMatchForPatch(patch)
    if type(patch) == "string" then
        patch = findInstalledPatch(patch)
    end
    if not patch then
        return
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Match patch with GitHub repository"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Match"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
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
end

function Storefront:verifyAndMatchPatchWithManualRepo(patch, owner, repo_name)
    if type(patch) == "string" then
        patch = findInstalledPatch(patch)
    end
    if not patch or not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Verifying repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        
        if not repo_data or not repo_data.id then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "patch",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        local entries = self:fetchPatchEntriesFromGitHub(repo)
        UIManager:close(progress)
        
        if not entries or #entries == 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("No patch files found in repository %s."), full_name),
                timeout = 4,
            })
            return
        end
        
        self.match_context = { kind = "patch", patch = patch, from_patch_updates = self.patch_updates_menu ~= nil }
        self:showPatchSelectionDialog(patch, repo, entries)
    end)
end

function Storefront:showPatchSelectionDialog(patch, repo, entries)
    if not patch or not repo or not entries or #entries == 0 then
        return
    end
    
    local dialog
    local buttons = {}
    for idx, entry in ipairs(entries) do
        table.insert(buttons, {
            {
                text = entry.path or entry.display_path or _("patch"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:matchPatchWithRepo(patch, repo, entry)
                end,
            },
        })
    end
    
    table.insert(buttons, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self.match_context = nil
            end,
        },
    })
    
    dialog = ButtonDialog:new{
        title = string.format(_("Select patch file from %s"), repo.full_name or repo.name),
        buttons = buttons,
        tap_close_callback = function()
            self.match_context = nil
        end,
    }
    UIManager:show(dialog)
end

local function getRecordedInstall(dirname)
    if not dirname or dirname == "" then
        return nil
    end
    return InstallStore.get(dirname)
end

function Storefront:updateInstallRecord(dirname, fields)
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

function Storefront:updatePatchRecord(filename, fields)
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

function Storefront:rememberPatchInstall(filename, repo, patch_info)
    if not filename or filename == "" then
        return
    end
    -- Include SHA during install/update (include_sha=true) so we can track the
    -- installed version and detect future updates correctly.
    local record = buildPatchRecordFields(filename, repo, patch_info, true)
    if record then
        InstallStore.upsertPatch(filename, record)
        return record
    end
end

function Storefront:updateSinglePatchStatus(filename, record)
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

function Storefront:rememberInstall(info, repo)
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
        meta_path,
        info.plugin_release_tag
    )
    if record then
        InstallStore.upsert(info.plugin_dirname, record)
        
        -- Clear ignored release if user installed the ignored version
        if repo and repo.owner and repo.name and info.plugin_release_tag then
            local owner = repo.owner
            local repo_name = repo.name
            if isReleaseIgnored(owner, repo_name, info.plugin_release_tag) then
                clearIgnoredRelease(owner, repo_name)
            end
        end
    end
end

derivePluginRepoPath = function(plugin_root)
    if not plugin_root or plugin_root == "" then
        return nil
    end
    local plugins_match = plugin_root:match("(plugins/.*)")
    if plugins_match and plugins_match ~= "" then
        return plugins_match
    end
    local koplugin_match = plugin_root:match("(%w[%w_%-%.]*%.koplugin.*)") or plugin_root:match("([^/]+%.koplugin.*)")
    if koplugin_match and koplugin_match ~= "" then
        return koplugin_match
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
            ["User-Agent"] = "KOReader-Storefront",
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
    -- Strip a leading "v"/"V" so a _meta.lua version like "v1.4.2" compares
    -- equal to a release tag parsed to "1.4.2" (parseVersionFromTag already
    -- strips it on the tag side). Otherwise normalizeVersion turns the "v1"
    -- segment into 0 and the local version always looks older.
    v1_str = tostring(v1_str):gsub("^[vV]", "")
    v2_str = tostring(v2_str):gsub("^[vV]", "")
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

function Storefront:resetFiltersForRefresh()
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

function Storefront:promptPatchAction(repo, patch)
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
        local DetailsDialog = require("storefront_details_dialog")
        local details_dialog = DetailsDialog:new{
            Storefront = self,
            repo = repo,
            patch = patch,
            kind = "patch",
        }
        details_dialog:show()
    end
end

function Storefront:installPatchFromRepo(repo, patch)
    NetworkMgr:runWhenOnline(function()
        self:_installPatchFromRepoInternal(repo, patch)
    end)
end

function Storefront:_installPatchFromRepoInternal(repo, patch)
    local owner = extractRepoOwner(repo)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for patch install."), timeout = 4 })
        return
    end
    local url = patch.download_url or buildPatchDownloadUrl(owner, repo.name, patch.branch or "HEAD", patch.path)
    StorefrontLogger.action(string.format("INSTALL patch starting: filename=%s (repo=%s/%s, url=%s)", tostring(patch and patch.filename), tostring(owner), tostring(repo.name), tostring(url)))
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
    -- Compute the actual SHA of the downloaded file so record.sha always reflects
    -- the real installed content, even when updating from a stale record.sha.
    local actual_sha = computeFileSha1(target_path)
    local patch_for_record = patch
    if actual_sha and actual_sha ~= patch.sha then
        patch_for_record = {}
        for k, v in pairs(patch) do patch_for_record[k] = v end
        patch_for_record.sha = actual_sha
    end
    local stored_record = self:rememberPatchInstall(patch.filename, repo, patch_for_record)
    if self.pending_patch_install then
        local context = self.pending_patch_install
        self.pending_patch_install = nil
        if context.mode == "update" and context.patch then
            showRestartConfirmation(string.format(_("Updated patch %s."), context.patch.filename or _("patch")))
        else
            showRestartConfirmation(string.format(_("Installed patch \"%s\"."), patch.filename))
        end
    else
        showRestartConfirmation(string.format(_("Installed patch \"%s\"."), patch.filename))
    end
    if stored_record then
        self:updateSinglePatchStatus(patch.filename, stored_record)
    end
end


function StorefrontBrowserDialog:resetScroll()
    if self.list_scroller then
        self.list_scroller:setScrolledOffset({ x = 0, y = 0 })
    end
end

ensureCacheDir = function()
    local lfs = require("libs/libkoreader-lfs")
    local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    return cache_dir
end

-- Format the published date of a GitHub release for display next to its tag.
-- Falls back to created_at when published_at is missing.
local function formatReleaseDate(release)
    if not release then
        return nil
    end
    local raw = release.published_at or release.created_at
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local ts = parseGitHubTimestamp(raw)
    if not ts or ts <= 0 then
        return nil
    end
    return os.date("%Y-%m-%d", ts)
end

local function getReleaseLabel(release)
    if not release then
        return nil
    end
    local tag = release.tag_name
    if not tag or tag == "" then
        tag = release.name
    end
    if not tag or tag == "" then
        return nil
    end
    return tostring(tag)
end

-- Fetch commits between two tags via the GitHub compare API and show them
-- in a scrollable dialog.  Called from inside the Full changelog dialog.
function Storefront:showCommitCompare(owner, repo_desc, base_tag, head_tag)
    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching commits…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local result, err = GitHub.fetchCompareCommits(owner, repo_desc.name, base_tag, head_tag)
        UIManager:close(progress)

        if not result then
            local msg = (type(err) == "table" and err.code == 404)
                and string.format(_("Tag not found on GitHub (%s or %s)."), base_tag, head_tag)
                or  _("Could not fetch commit comparison.")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
            return
        end

        local commits = result.commits or {}
        local total   = result.total_commits or #commits
        local repo_name = repo_desc.full_name or repo_desc.name or owner

        local lines = {
            string.format(_("Commit diff: %s → %s"), base_tag, head_tag),
            string.format(_("Repository: %s"), repo_name),
            string.format(_("Total commits: %d"), total),
            "",
        }

        if #commits == 0 then
            table.insert(lines, _("No commits found in this range."))
        else
            -- GitHub returns oldest-first in the commits array; keep that order
            -- (chronological = natural reading order for a changelog).
            for _, commit in ipairs(commits) do
                local msg   = commit.commit and commit.commit.message or ""
                local title = msg:match("^([^\n\r]+)") or msg
                title = util.trim(title)
                title = softWrapLongTokens(title, 55)
                local sha   = commit.sha and commit.sha:sub(1, 7) or "???????"
                table.insert(lines, string.format("\xE2\x80\xA2 %s  [%s]", title, sha))
            end
            if total > #commits then
                table.insert(lines, "")
                table.insert(lines, string.format(
                    _("(showing %d of %d commits)"), #commits, total))
            end
        end

        local text = table.concat(lines, "\n")
        UIManager:show(TextViewer:new{
            title = string.format(_("Commits: %s \xE2\x86\x92 %s"), base_tag, head_tag),
            text  = text,
            add_default_buttons = true,
        })
    end)
end

-- Show a scrollable dialog with all release notes between the installed
-- version and `target_release`, fetched from the GitHub releases list.
-- `installed_tag` is the exact GitHub release tag of the installed version;
-- when present it is used as the range boundary directly (no version parsing).
-- Only shown when the target release is strictly newer than what is installed.
function Storefront:showFullChangelog(owner, repo_desc, installed_version, target_release, installed_tag)
    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching changelog…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local releases, err = GitHub.fetchReleases(owner, repo_desc.name)
        UIManager:close(progress)

        if not releases or #releases == 0 then
            UIManager:show(InfoMessage:new{
                text = err
                    and _("Could not fetch releases for changelog.")
                    or  _("No releases found for this repository."),
                timeout = 4,
            })
            return
        end

        local target_tag = target_release and target_release.tag_name
        local sections   = {}
        -- `base_tag` is the known installed release tag used for commit-compare.
        -- Prefer the recorded installed_tag; fall back to version-based detection.
        local base_tag   = installed_tag or nil
        local collecting = (target_tag == nil)
        local is_downgrade = false

        for _, rel in ipairs(releases) do
            local rel_tag = rel.tag_name

            -- Downgrade detection: if we hit the installed tag before the
            -- target tag the user is going backwards.
            if installed_tag and not collecting and rel_tag == installed_tag then
                is_downgrade = true
                break
            end

            -- Start collecting at the target release tag.
            if not collecting and rel_tag == target_tag then
                collecting = true
            end

            if collecting then
                -- Stop when we reach the installed tag (exact match).
                if installed_tag and rel_tag == installed_tag then
                    break
                end

                -- Fallback stop: version-string comparison when no installed_tag.
                if not installed_tag then
                    local rel_version = parseVersionFromTag(rel_tag)
                    if rel_version and not isVersionNewer(rel_version, installed_version) then
                        base_tag = rel_tag
                        break
                    end
                end

                local label  = getReleaseLabel(rel) or rel_tag or _("Release")
                local date   = formatReleaseDate(rel)
                local header = date
                    and string.format("=== %s (%s) ===", label, date)
                    or  string.format("=== %s ===", label)
                local body = rel.body
                if not body or body == json.null or body == "" then
                    body = _("No release notes.")
                else
                    -- Trim leading/trailing blank lines and collapse any run of
                    -- 3+ newlines down to a single blank line. GitHub release
                    -- bodies commonly end with (or contain) extra blank lines;
                    -- left as-is, these stack with our own "\n\n" separators
                    -- between sections and can push an entire page of the
                    -- changelog viewer to be blank when paging through it.
                    body = util.trim(tostring(body))
                    if body == "" then
                        body = _("No release notes.")
                    else
                        body = body:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
                        body = softWrapLongTokens(body, 60)
                    end
                end
                table.insert(sections, header .. "\n\n" .. body)
            end
        end

        -- Fallback base_tag from version string when not found in releases list.
        if not base_tag and installed_version then
            base_tag = "v" .. installed_version
        end

        -- Reverse so oldest release appears first (chronological reading order).
        local reversed = {}
        for i = #sections, 1, -1 do
            reversed[#reversed + 1] = sections[i]
        end

        local downgrade_notice = ""
        if is_downgrade then
            downgrade_notice = string.format(
                "\xE2\x9A\xA0 %s\n\n",
                _("Warning: the selected version is older than what is currently installed. You are downgrading.")
            )
        end

        local text
        if is_downgrade or #sections == 0 then
            local repo_name = repo_desc.full_name or repo_desc.name or owner
            text = string.format(
                _("Changelog for %s\n%s \xE2\x86\x92 %s"),
                repo_name,
                installed_version or _("?"),
                target_tag        or _("latest")
            ) .. "\n\n" .. downgrade_notice .. _("No changelog entries found for this range.")
        else
            local repo_name = repo_desc.full_name or repo_desc.name or owner
            text = string.format(
                _("Changelog for %s\n%s \xE2\x86\x92 %s"),
                repo_name,
                installed_version or _("?"),
                target_tag        or _("latest")
            ) .. "\n\n" .. table.concat(reversed, "\n\n")
        end

        -- "View commits" button: only available when we have both tag bounds.
        local buttons_table = nil
        if base_tag and target_tag then
            local self_ref = self
            local b_label = is_downgrade
                and string.format(_("View commits (%s \xE2\x86\x92 %s)"), target_tag, base_tag)
                or  string.format(_("View commits (%s \xE2\x86\x92 %s)"), base_tag, target_tag)
            local b_base = is_downgrade and target_tag or base_tag
            local b_head = is_downgrade and base_tag  or target_tag
            buttons_table = {
                {
                    {
                        text = b_label,
                        callback = function()
                            self_ref:showCommitCompare(owner, repo_desc, b_base, b_head)
                        end,
                    },
                },
            }
        end

        UIManager:show(TextViewer:new{
            title               = string.format(_("Changelog: %s"), repo_desc.full_name or repo_desc.name or owner),
            text                = text,
            buttons_table       = buttons_table,
            add_default_buttons = true,
        })
    end)
end

local ASSETS_PAGE_SIZE = 8

local function buildDownloadOptionsTitle(release, owner, repo_name)
    local tag = release and release.tag_name and release.tag_name ~= "" and release.tag_name or nil
    local title = release and release.name and release.name ~= "" and release.name or nil
    local has_distinct_title = title and tag
        and title:lower():gsub("^%s*(.-)%s*$", "%1") ~= tag:lower():gsub("^%s*(.-)%s*$", "%1")
    local label
    if has_distinct_title then
        label = string.format("%s \xE2\x80\x94 %s", title, tag)
    else
        label = getReleaseLabel(release)
    end
    local repo_prefix = (owner and repo_name) and string.format("[%s/%s] ", owner, repo_name) or ""
    local result
    if not label then
        result = repo_prefix .. _("Download options")
    else
        local date = formatReleaseDate(release)
        if date then
            result = repo_prefix .. string.format(_("Download options — %s (%s)"), label, date)
        else
            result = repo_prefix .. string.format(_("Download options — %s"), label)
        end
    end
    
    if owner and repo_name and tag and isReleaseIgnored(owner, repo_name, tag) then
        result = result .. " " .. _("[Ignored]")
    end
    
    return result
end

-- Display a paginated list of release assets. `on_select` is called with the
-- chosen asset table when the user taps an entry.
function Storefront:renderAssetListPage(repo, release, assets, page, on_select)
    page = page or 1
    local total = #assets
    local total_pages = math.max(1, math.ceil(total / ASSETS_PAGE_SIZE))
    if page < 1 then page = 1 end
    if page > total_pages then page = total_pages end

    local dialog
    local button_rows = {}

    local first = (page - 1) * ASSETS_PAGE_SIZE + 1
    local last = math.min(first + ASSETS_PAGE_SIZE - 1, total)
    for i = first, last do
        local asset = assets[i]
        table.insert(button_rows, {
            {
                text = asset.name,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    on_select(asset)
                end,
            },
        })
    end

    if total_pages > 1 then
        local nav_row = {}
        if page > 1 then
            table.insert(nav_row, {
                text = "\xE2\x97\x80  " .. _("Prev"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderAssetListPage(repo, release, assets, page - 1, on_select)
                end,
            })
        end
        table.insert(nav_row, {
            text = string.format(_("Page %d/%d"), page, total_pages),
            background = Blitbuffer.COLOR_WHITE,
            callback = function() end,
        })
        if page < total_pages then
            table.insert(nav_row, {
                text = _("Next") .. "  \xE2\x96\xB6",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderAssetListPage(repo, release, assets, page + 1, on_select)
                end,
            })
        end
        table.insert(button_rows, nav_row)
    end

    table.insert(button_rows, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    local tag_label = release and (release.tag_name or release.name) or (repo.full_name or repo.name or "")
    dialog = ButtonDialog:new{
        title = string.format(_("Assets — %s"), tag_label),
        title_align = "center",
        buttons = button_rows,
    }
    UIManager:show(dialog)
end

function Storefront:promptPluginInstallOptions(repo, release_override)
    if not repo then
        return
    end

    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for installation."), timeout = 4 })
        return
    end

    local saved_ctx = self.pending_install_context

    NetworkMgr:runWhenOnline(function()
        self.pending_install_context = saved_ctx
        local release, release_err
        if release_override then
            release = release_override
        else
            local progress = InfoMessage:new{ text = _("Fetching release info…"), timeout = 0 }
            UIManager:show(progress)
            UIManager:forceRePaint()
            release, release_err = GitHub.fetchLatestRelease(owner, repo.name)
            UIManager:close(progress)
        end

        local dialog
        local buttons = {}

        table.insert(buttons, {
            text = _("Direct download from repo"),
            callback = function()
                UIManager:close(dialog)
                self.pending_install_context = saved_ctx
                self:installPluginFromRepo(repo)
            end,
        })

        local assets = release and release.assets
        local custom_assets = {}
        
        if type(assets) == "table" then
            for _, asset in ipairs(assets) do
                local name = asset and asset.name
                local url = asset and asset.browser_download_url
                if name and url then
                    table.insert(custom_assets, asset)
                end
            end
        end
        
        if #custom_assets > 0 then
            if #custom_assets > ASSETS_PAGE_SIZE then
                -- Too many assets to list inline — open a separate paginated picker.
                table.insert(buttons, {
                    text = string.format(_("Choose asset… (%d available)"), #custom_assets),
                    callback = function()
                        UIManager:close(dialog)
                        self.pending_install_context = saved_ctx
                        self:renderAssetListPage(repo, release, custom_assets, 1, function(asset)
                            self.pending_install_context = saved_ctx
                            self:installPluginFromReleaseAsset(repo, release, asset)
                        end)
                    end,
                })
            else
                for _, asset in ipairs(custom_assets) do
                    table.insert(buttons, {
                        text = asset.name,
                        callback = function()
                            UIManager:close(dialog)
                            self.pending_install_context = saved_ctx
                            self:installPluginFromReleaseAsset(repo, release, asset)
                        end,
                    })
                end
            end
        elseif release and release.zipball_url then
            local tag_name = release.tag_name or "latest"
            local source_code_name = string.format("Source code (%s.zip)", tag_name)
            table.insert(buttons, {
                text = source_code_name,
                callback = function()
                    UIManager:close(dialog)
                    self.pending_install_context = saved_ctx
                    local source_asset = {
                        name = source_code_name,
                        browser_download_url = release.zipball_url,
                    }
                    self:installPluginFromReleaseAsset(repo, release, source_asset)
                end,
            })
        end

        local show_notes = release ~= nil
        if show_notes then
            table.insert(buttons, {
                text = _("View release notes"),
                callback = function()
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

        -- Add a "Full changelog" button only when the fetched release is
        -- strictly newer than the currently installed version of this plugin.
        -- We search install records to find a match even when not in update mode.
        do
            local installed_ver = nil
            local installed_tag = nil
            local ctx_plugin = self.pending_install_context and self.pending_install_context.plugin
            if ctx_plugin then
                installed_ver = ctx_plugin.version
                local ctx_rec = InstallStore.get(ctx_plugin.dirname)
                installed_tag = ctx_rec and ctx_rec.installed_tag
            else
                local all_records = InstallStore.list()
                for dirname, rec in pairs(all_records) do
                    if type(rec) == "table" and rec.owner == owner and rec.repo == repo.name then
                        local p = findInstalledPlugin(dirname)
                        installed_ver = (p and p.version) or rec.installed_version
                        installed_tag = rec.installed_tag
                        break
                    end
                end
            end

            local release_ver = release and parseVersionFromTag(release.tag_name)
            if installed_ver and release_ver and isVersionNewer(release_ver, installed_ver) then
                table.insert(buttons, {
                    text = _("Full changelog"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showFullChangelog(owner, repo, installed_ver, release, installed_tag)
                    end,
                })
            end
        end

        -- Add "Ignore This Release" button only when showing the latest release
        -- (not when user manually selected a different release), when it's
        -- an update (newer than installed version), and when it's not already ignored.
        if release and release.tag_name and not release_override then
            local ctx_plugin = self.pending_install_context and self.pending_install_context.plugin
            local installed_ver = nil
            if ctx_plugin then
                installed_ver = ctx_plugin.version
            else
                local all_records = InstallStore.list()
                for dirname, rec in pairs(all_records) do
                    if type(rec) == "table" and rec.owner == owner and rec.repo == repo.name then
                        local p = findInstalledPlugin(dirname)
                        installed_ver = (p and p.version) or rec.installed_version
                        break
                    end
                end
            end
            
            local release_ver = parseVersionFromTag(release.tag_name)
            local is_update = installed_ver and release_ver and isVersionNewer(release_ver, installed_ver)
            local is_ignored = isReleaseIgnored(owner, repo.name, release.tag_name)
            
            if is_update and not is_ignored then
                table.insert(buttons, {
                    text = _("Ignore this release"),
                    callback = function()
                        ignoreRelease(owner, repo.name, release.tag_name)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Release %s will be ignored until a newer version is available."), release.tag_name),
                            timeout = 3,
                        })
                    end,
                })
            end
        end

        -- Always offer a way to switch to a different release; the release
        -- list itself handles the case where no releases are available.
        table.insert(buttons, {
            text = _("Other releases…"),
            callback = function()
                UIManager:close(dialog)
                self:showReleaseListDialog(repo, release)
            end,
        })

        -- `buttons` always contains at least direct download + other releases
        -- so we now compare against 2 (was 1 before "Other releases" was added)
        -- to decide whether the user effectively has nothing release-related.
        if release_err and #buttons == 2 and not release_override then
            UIManager:show(InfoMessage:new{ text = _("Could not fetch latest release. You can still use direct repo download."), timeout = 6 })
        elseif #buttons == 2 and not release_override then
            UIManager:show(InfoMessage:new{ text = _("No release assets found. You can still use direct repo download."), timeout = 5 })
        end

        local button_rows = {}
        for _, button in ipairs(buttons) do
            table.insert(button_rows, { button })
        end

        dialog = ConfirmBox:new{
            text = buildDownloadOptionsTitle(release, owner, repo.name),
            cancel_text = _("Cancel"),
            no_ok_button = true,
            keep_dialog_open = true,
            other_buttons = button_rows,
        }
        UIManager:show(dialog)
    end)
end

local RELEASES_PAGE_SIZE = 10

-- Display a paginated list of every release published by `repo`. Selecting a
-- release closes this dialog and reopens the Download options popup for that
-- release; this avoids stacking popups on top of each other.
function Storefront:showReleaseListDialog(repo, current_release)
    if not repo then
        return
    end
    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for releases."), timeout = 4 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching releases…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local releases, err = GitHub.fetchReleases(owner, repo.name)

        UIManager:close(progress)

        if not releases or #releases == 0 then
            local message
            if err then
                message = _("Could not fetch releases for this repository.")
            else
                message = _("No releases found for this repository.")
            end
            UIManager:show(InfoMessage:new{ text = message, timeout = 4 })
            return
        end

        self:renderReleaseListPage(repo, releases, 1, current_release, true)
    end)
end

local RELEASES_PAGE_SIZE = 10

local function isPreRelease(release)
    if release.prerelease then return true end
    local tag = (release.tag_name or release.name or ""):lower()
    -- Check common pre-release suffixes in version tags (e.g. v1.2.3-rc1, v1.0.0-beta.2)
    if tag:find("[%-.]alpha") or tag:find("[%-.]beta")
        or tag:find("[%-.]rc%d") or tag:find("[%-.]rc$") or tag:find("[%-.]rc%-")
        or tag:find("[%-.]pre%d") or tag:find("[%-.]preview") or tag:find("%-pre%-")
        or tag:find("[%-.]dev%d") or tag:find("[%-.]dev$")
        or tag:find("nightly") then
        return true
    end
    return false
end

function Storefront:renderReleaseListPage(repo, releases, page, current_release, filter_pre_releases)
    if filter_pre_releases == nil then filter_pre_releases = true end
    page = page or 1

    -- Apply pre-release filter, keeping the original list for toggling
    local visible_releases = releases
    if filter_pre_releases then
        visible_releases = {}
        for _, r in ipairs(releases) do
            if not isPreRelease(r) then
                table.insert(visible_releases, r)
            end
        end
    end

    local total = #visible_releases
    local total_pages = math.max(1, math.ceil(total / RELEASES_PAGE_SIZE))
    if page < 1 then page = 1 end
    if page > total_pages then page = total_pages end

    local current_tag = getReleaseLabel(current_release)

    local dialog
    local button_rows = {}

    -- Filter toggle checkbox row (always first)
    local filter_label = filter_pre_releases
        and ("\xE2\x98\x91 " .. _("Filter pre-releases"))
        or  ("\xE2\x98\x90 " .. _("Filter pre-releases"))
    table.insert(button_rows, {
        {
            text = filter_label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:renderReleaseListPage(repo, releases, 1, current_release, not filter_pre_releases)
            end,
        },
    })

    if total == 0 then
        local msg = filter_pre_releases
            and _("No stable releases found — uncheck filter to show all releases")
            or  _("No releases found for this repository.")
        table.insert(button_rows, {
            {
                text = msg,
                background = Blitbuffer.COLOR_WHITE,
                callback = function() end,
            },
        })
    else

    local first = (page - 1) * RELEASES_PAGE_SIZE + 1
    local last = math.min(first + RELEASES_PAGE_SIZE - 1, total)
    for i = first, last do
        local release = visible_releases[i]
        local tag = release.tag_name and release.tag_name ~= "" and release.tag_name or nil
        local title = release.name and release.name ~= "" and release.name or nil
        -- Show "Title — tag" when title exists and differs from tag (case-insensitive trim)
        local has_distinct_title = title and tag
            and title:lower():gsub("^%s*(.-)%s*$", "%1") ~= tag:lower():gsub("^%s*(.-)%s*$", "%1")
        local label
        if has_distinct_title then
            label = string.format("%s \xE2\x80\x94 %s", title, tag)  -- "Title — tag"
        else
            label = getReleaseLabel(release) or _("Unnamed release")
        end
        local date = formatReleaseDate(release)
        local prefix = ""
        if current_tag and getReleaseLabel(release) == current_tag then
            prefix = "\xE2\x80\xA2 " -- bullet to mark currently shown release
        end
        local text
        if date then
            text = string.format("%s%s (%s)", prefix, label, date)
        else
            text = string.format("%s%s", prefix, label)
        end
        if release.prerelease then
            text = text .. " " .. _("[pre]")
        elseif release.draft then
            text = text .. " " .. _("[draft]")
        end
        
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if owner and repo.name and tag and isReleaseIgnored(owner, repo.name, tag) then
            text = text .. " " .. _("[Ignored]")
        end
        table.insert(button_rows, {
            {
                text = text,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    -- Close the release list, then reopen Download options for
                    -- the chosen release.
                    self:promptPluginInstallOptions(repo, release)
                end,
            },
        })
    end

    if total_pages > 1 then
        local nav_row = {}
        if page > 1 then
            table.insert(nav_row, {
                text = "◀  " .. _("Prev"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderReleaseListPage(repo, releases, page - 1, current_release, filter_pre_releases)
                end,
            })
        end
        table.insert(nav_row, {
            text = string.format(_("Page %d/%d"), page, total_pages),
            background = Blitbuffer.COLOR_WHITE,
            callback = function() end,
        })
        if page < total_pages then
            table.insert(nav_row, {
                text = _("Next") .. "  ▶",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:renderReleaseListPage(repo, releases, page + 1, current_release, filter_pre_releases)
                end,
            })
        end
        table.insert(button_rows, nav_row)
    end

    end -- end else (total > 0)

    table.insert(button_rows, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    local title_label = repo.full_name or repo.name or _("Releases")
    dialog = ButtonDialog:new{
        title = string.format(_("Releases — %s"), title_label),
        title_align = "center",
        buttons = button_rows,
    }
    UIManager:show(dialog)
end

function Storefront:installPluginFromReleaseAsset(repo, release, asset)
    if not repo or not asset then
        return
    end

    local url = asset.browser_download_url
    if not url or url == "" then
        UIManager:show(InfoMessage:new{ text = _("Missing download URL for release asset."), timeout = 4 })
        return
    end

    StorefrontLogger.action(string.format("DOWNLOAD asset: url=%s asset=%s repo=%s", url, tostring(asset.name), repo and (repo.full_name or repo.name) or "?"))

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
            StorefrontLogger.err(string.format("Download failed: %s (url=%s)", tostring(err), url))
            UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(err), timeout = 6 })
            return
        end

        local reader = Archiver.Reader:new()
        if not reader:open(zip_path) then
            util.removeFile(zip_path)
            StorefrontLogger.err(string.format("Failed to open archive for repo=%s", repo and repo.name or "?"))
            UIManager:show(InfoMessage:new{ text = _("Failed to open downloaded archive."), timeout = 6 })
            return
        end

        local info, detect_err = detectPluginFromArchiveWithFallback(reader, repo, release, asset)
        if not info then
            reader:close()
            util.removeFile(zip_path)
            StorefrontLogger.err(string.format("Plugin detection failed: %s", tostring(detect_err)))
            UIManager:show(InfoMessage:new{ text = detect_err or _("Could not detect plugin inside archive."), timeout = 6 })
            return
        end

        StorefrontLogger.action(string.format("DETECTED plugin inside archive: dirname=%s, plugin_name=%s, version=%s", tostring(info.plugin_dirname), tostring(info.plugin_name), tostring(info.plugin_version)))

        -- Store the release tag so it gets persisted in the install record.
        if release and release.tag_name and release.tag_name ~= "" then
            info.plugin_release_tag = release.tag_name
        end

        if self.pending_install_context and self.pending_install_context.mode == "update" then
            local ctx_plugin = self.pending_install_context.plugin
            if ctx_plugin and ctx_plugin.dirname and ctx_plugin.dirname ~= "" then
                info.plugin_dirname = ctx_plugin.dirname
            end
        end

        local function proceedWithInstall(dest_root)
            local install_progress = InfoMessage:new{ text = _("Installing plugin…"), timeout = 0 }
            UIManager:show(install_progress)
            local ok_extract, dest_or_err = extractPluginToUserDir(reader, info, dest_root)
            reader:close()
            util.removeFile(zip_path)

            if not ok_extract then
                UIManager:show(InfoMessage:new{ text = _("Installation failed: ") .. tostring(dest_or_err), timeout = 6 })
                return
            end

            -- Clean up duplicate directories on disk if any existed from prior bug
            if info.duplicates then
                for _, dup in ipairs(info.duplicates) do
                    if dup.dirname and dup.dirname ~= info.plugin_dirname then
                        local dup_path = (dup.root or dest_root) .. "/" .. dup.dirname
                        deleteDirectoryRecursive(dup_path)
                        InstallStore.remove(dup.dirname)
                    end
                end
            end

            UIManager:close(install_progress)

            -- Some plugins' _meta.lua only set `fullname` (often wrapped in _()), so
            -- plugin_name parsing can come back nil; fall back to the directory name
            -- to avoid showing "nil" in the success message.
            info.plugin_name = info.plugin_name or ((info.plugin_dirname or "plugin"):gsub("%.koplugin$", ""))
            local msg
            if self.pending_install_context and self.pending_install_context.mode == "update" then
                if info.plugin_version and info.plugin_version ~= "" then
                    msg = string.format(_("Updated plugin \"%s\" to version %s."), info.plugin_name, info.plugin_version)
                else
                    msg = string.format(_("Updated plugin \"%s\"."), info.plugin_name)
                end
            else
                if info.plugin_version and info.plugin_version ~= "" then
                    msg = string.format(_("Installed plugin \"%s\" (version %s)."), info.plugin_name, info.plugin_version)
                else
                    msg = string.format(_("Installed plugin \"%s\"."), info.plugin_name)
                end
            end

            showRestartConfirmation(msg)

            self:handlePostInstall(info, repo)
            if self.updates_menu then
                self:updateUpdatesDialog()
            end
        end

        if self.pending_install_context and self.pending_install_context.mode == "update" then
            proceedWithInstall(self.pending_install_context.plugin.root)
        else
            self:resolveNewInstallDestination(proceedWithInstall, function()
                reader:close()
                util.removeFile(zip_path)
            end)
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
    
    local is_source_code = asset_name and asset_name:match("^Source code") ~= nil
    if is_source_code and repo_name then
        local repo_is_plugin_dir = repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        if repo_is_plugin_dir then
            return repo_name
        end
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

    local is_12h = false
    if G_reader_settings then
        if type(G_reader_settings.isTrue) == "function" and G_reader_settings:isTrue("twelve_hour_clock") then
            is_12h = true
        end
        if not is_12h and type(G_reader_settings.readSetting) == "function" then
            local val = G_reader_settings:readSetting("twelve_hour_clock")
            if val == true or val == "true" or val == "12h" or val == 1 then
                is_12h = true
            end
        end
    end
    local ok_dt, datetime = pcall(require, "datetime")
    if not ok_dt then ok_dt, datetime = pcall(require, "ui/datetime") end
    if ok_dt and datetime then
        if type(datetime.is12HourClock) == "function" and datetime.is12HourClock() then
            is_12h = true
        elseif type(datetime.has12HourClock) == "function" and datetime.has12HourClock() then
            is_12h = true
        elseif type(datetime.is12Hour) == "function" and datetime.is12Hour() then
            is_12h = true
        end
    end

    if not is_12h and G_reader_settings then
        if type(G_reader_settings.isTrue) == "function" then
            if G_reader_settings:isTrue("clock_12h")
                or G_reader_settings:isTrue("clock_format_12h")
                or G_reader_settings:isTrue("c_clock_12h")
                or G_reader_settings:isTrue("c_time_12h")
                or G_reader_settings:isTrue("time_12h")
                or G_reader_settings:isTrue("12h_clock")
                or G_reader_settings:isTrue("use_12h_clock")
                or G_reader_settings:isTrue("is_12h_clock")
                or G_reader_settings:isTrue("is_12h")
                or G_reader_settings:isTrue("12_hour_clock")
                or G_reader_settings:isTrue("c_12_hour_clock") then
                is_12h = true
            end
        end

        if not is_12h and type(G_reader_settings.readSetting) == "function" then
            local keys = {
                "c_time_format", "clock_format", "time_format", "c_clock_format",
                "clock", "time_mode", "clock_mode", "time_display", "status_time_format"
            }
            for _, key in ipairs(keys) do
                local val = G_reader_settings:readSetting(key)
                if val ~= nil then
                    local sval = tostring(val):lower()
                    if sval:find("12") or sval == "true" then
                        is_12h = true
                        break
                    end
                end
            end
        end
    end

    if is_12h then
        local formatted = os.date("%Y-%m-%d %I:%M%p", ts):lower()
        return (formatted:gsub(" 0(%d:)", " %1"))
    else
        return os.date("%Y-%m-%d %H:%M", ts)
    end
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
        logger.warn("Storefront patches dir create failed", err)
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

function Storefront:repoMatchesSearch(repo, search)
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

function Storefront:patchMatchesSearch(patch, search)
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

function Storefront:repoHasMatchingPatch(repo, search)
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

repoStarsValue = function(repo)
    if type(repo) ~= "table" then return 0 end
    local s = tonumber(repo.stars)
    if s and s > 0 then return s end
    if repo.data then
        s = tonumber(repo.data.stargazers_count) or tonumber(repo.data.stars)
        if s and s > 0 then return s end
    end
    return s or 0
end

repoIsFork = function(repo)
    if type(repo) ~= "table" then return false end
    if repo.fork ~= nil then return repo.fork == true end
    if repo.data and repo.data.fork ~= nil then return repo.data.fork == true end
    return false
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

function Storefront:getSortOption(mode)
    return SORT_OPTION_LOOKUP[mode] or SORT_OPTION_LOOKUP[DEFAULT_SORT_MODE]
end

function Storefront:getSortSummary()
    local option = self:getSortOption(self.browser_state.sort_mode)
    return option and option.summary or ""
end

function Storefront:advanceSortMode()
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
    -- Keep focus on the Sort row after the rebuild so repeated presses cycle
    -- through the sort modes in place.
    self.browser_focus_hint = { id = "sort" }
    self:reopenBrowser()
end

function Storefront:sortRepoList(list)
    if not list or #list <= 1 then
        return
    end
    local option = self:getSortOption(self.browser_state.sort_mode)
    local comparator = option and option.repo_comparator or compareRepoStarsDesc
    table.sort(list, comparator)
end

function Storefront:sortPatchEntries(entries)
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

function Storefront:loadBrowserStateFromSettings()
    if self._browser_state_loaded then
        return
    end
    self._browser_state_loaded = true
    local encoded = StorefrontSettings:readSetting(BROWSER_STATE_KEY)
    if type(encoded) ~= "string" or encoded == "" then
        return
    end
    local ok, decoded = pcall(json.decode, encoded)
    if not ok or type(decoded) ~= "table" then
        return
    end
    self.browser_state = {
        kind = decoded.kind == "patch" and "patch" or "plugin",
        tab = decoded.tab or (decoded.kind == "patch" and "Patches" or "Plugins"),
        search_text = decoded.search_text or "",
        owner = decoded.owner or "",
        min_stars = tonumber(decoded.min_stars) or 0,
        page = math.max(1, tonumber(decoded.page) or 1),
        scroll_offset = normalizeScrollOffset(decoded.scroll_offset),
        sort_mode = decoded.sort_mode or DEFAULT_SORT_MODE,
        search_in_readme = decoded.search_in_readme == true,
    }
end

function Storefront:saveBrowserState()
    if not self.browser_state then
        return
    end
    local state = {
        kind = self.browser_state.kind == "patch" and "patch" or "plugin",
        tab = self.browser_state.tab or "Plugins",
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
        StorefrontSettings:saveSetting(BROWSER_STATE_KEY, encoded)
        StorefrontSettings:flush()
    end
end

function Storefront:ensureBrowserState()
    if not self.browser_state then
        self:loadBrowserStateFromSettings()
    end
    if not self.browser_state then
        self.browser_state = {
            kind = "plugin",
            tab = "Plugins",
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
    self.browser_state.tab = self.browser_state.tab or (self.browser_state.kind == "patch" and "Patches" or "Plugins")
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

function Storefront:updateReadmeFilter()
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
                logger.warn("Storefront README search error", query, body)
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

function Storefront:getOwners(kind)
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

function Storefront:matchesGeneralFilters(repo, filters)
    filters = filters or self.browser_state or {}

    local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
        or (self.browser_state and self.browser_state.include_zero_star_forks == true)
    if not include_zero then
        local is_fork = repoIsFork(repo) or repo.fork == true or (repo.data and repo.data.fork == true)
        local stars = repoStarsValue(repo)
        if is_fork and stars == 0 then
            return false
        end
    end

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
        local stars = repoStarsValue(repo)
        if stars < min_stars then
            return false
        end
    end

    return true
end

function Storefront:descriptorMatches(repo, filters)
    if not self:matchesGeneralFilters(repo, filters) then
        return false
    end
    local search = normalizedLower(filters.search_text)
    if search ~= "" then
        return self:repoMatchesSearch(repo, search)
    end
    return true
end

function Storefront:getFilteredDescriptors(kind)
    self:ensureBrowserState()
    local descriptors = self:getRepoDescriptors(kind)
    
    local search = normalizedLower(self.browser_state.search_text)
    local search_active = search ~= ""
    local rf = self.readme_filter
    local rf_key = rf and (rf.kind .. "_" .. (rf.matches_count or 0)) or ""
    local fetched = Cache.getLastFetched and Cache.getLastFetched(kind) or 0
    local gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local cache_key = string.format("%s|%s|%s|%s|%s|%s|%s|%s|%s",
        tostring(kind), tostring(search), tostring(self.browser_state.search_in_readme),
        tostring(self.browser_state.min_stars), tostring(self.browser_state.owner),
        tostring(self.browser_state.include_zero_star_forks), rf_key, tostring(fetched), tostring(gen))
        
    if self._filtered_descriptors_cache and self._filtered_descriptors_cache.key == cache_key then
        return self._filtered_descriptors_cache.filtered, self._filtered_descriptors_cache.total
    end

    local filtered = {}
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
    self._filtered_descriptors_cache = {
        key = cache_key,
        filtered = filtered,
        total = #descriptors
    }
    return filtered, #descriptors
end

function Storefront:getFilterSummary()
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

function Storefront:getCacheStatusLine(kind, total_count)
    local ts = Cache.getLastFetched(kind)
    local ts_text = ts and ts > 0 and formatTimestamp(ts) or _("Never")
    local label = kind == "plugin" and _("Plugins cached: %s (last update: %s)") or _("Patches cached: %s (last update: %s)")
    return string.format(label, tostring(total_count or 0), ts_text)
end

function Storefront:getCacheWarning(kind)
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

-- Returns true when the raw GitHub repo payload marks this entry as a fork.
-- The full API response is cached as `repo.data`, so no extra request is needed.
local function repoIsFork(repo)
    if not repo then return false end
    if repo.fork == true then return true end
    return repo.data and repo.data.fork == true or false
end

local function formatRepoEntry(repo, opts)
    opts = opts or {}
    local include_description = opts.include_description ~= false
    local include_updated = opts.include_updated ~= false
    local lines = {}
    local title = repo.full_name or repo.name or _("Repository")
    local stars = tonumber(repo.stars) or 0
    local meta = string.format("⭐ %d", stars)
    if repoIsFork(repo) then
        -- Keep the badge short; the browser list has limited horizontal room.
        meta = meta .. " · " .. _("(fork)")
    end
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

function Storefront:fetchPatchEntriesFromGitHub(repo)
    local owner = extractRepoOwner(repo)
    if not owner or not repo.name then
        return {}
    end
    local branch = (repo.data and repo.data.default_branch)
        or repo.default_branch
        or "HEAD"
    local tree, err = GitHub.fetchRepoTree(owner, repo.name, branch)
    if not tree or type(tree.tree) ~= "table" then
        logger.warn("Storefront patch tree fetch failed", repo.full_name or repo.name, err)
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

function Storefront:storePatchEntriesForRepo(repo, source_pushed_at)
    local repo_id = repo.repo_id or repo.id
    if not repo_id then
        return
    end
    local entries = self:fetchPatchEntriesFromGitHub(repo)
    Cache.storePatchFiles(repo_id, entries, source_pushed_at)
end

-- Incremental refresh of every patch repository's patch_files rows.
-- For each repo we compare the freshly fetched pushed_at (from the search
-- result stored in `repo.data`) against the pushed_at recorded the last time
-- we successfully downloaded the tree. Unchanged repos skip the git/trees
-- API call entirely. Repos that dropped out of the search results are pruned
-- so that stale rows never survive across refreshes.
function Storefront:refreshPatchFileListings()
    local patch_repos = self:getRepoDescriptors("patch")

    local valid_repo_ids = {}
    for _, repo in ipairs(patch_repos) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        if repo_id then
            table.insert(valid_repo_ids, repo_id)
        end
    end
    if Cache.pruneOrphanPatchFiles then
        Cache.pruneOrphanPatchFiles(valid_repo_ids)
    end

    local refreshed, skipped = 0, 0
    for _, repo in ipairs(patch_repos) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        local remote_pushed_at = repo.data and repo.data.pushed_at
        if type(remote_pushed_at) ~= "string" or remote_pushed_at == "" then
            remote_pushed_at = nil
        end

        local cached_pushed_at = repo_id and Cache.getPatchFilePushedAt
            and Cache.getPatchFilePushedAt(repo_id) or nil
        local cached_count = (repo_id and Cache.countPatchFiles)
            and Cache.countPatchFiles(repo_id) or 0

        -- A tree fetch is required when any of the following is true:
        --   * We have no recorded pushed_at for this repo (first run after the
        --     schema bump, a prior failure, or a brand-new repo).
        --   * The remote pushed_at differs from the cached value.
        --   * Cache has zero rows AND the remote repo has commits: a previous
        --     attempt likely failed, so retry even if timestamps match.
        local must_refetch = (not cached_pushed_at)
            or (remote_pushed_at and cached_pushed_at ~= remote_pushed_at)
            or (cached_count == 0)

        if must_refetch then
            self:storePatchEntriesForRepo(repo, remote_pushed_at)
            refreshed = refreshed + 1
        else
            skipped = skipped + 1
        end
    end
    logger.dbg("Storefront patch tree refresh: refreshed=", refreshed, "skipped=", skipped)
end

function Storefront:getPatchEntriesForRepo(repo)
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

function Storefront:collectPatchEntries(repos)
    local search = normalizedLower(self.browser_state.search_text)
    local cache_key = tostring(#repos) .. "_" .. search .. "_" .. (self.browser_state.search_in_readme and "1" or "0")
    if self._cached_patch_entries and self._cached_patch_entries_key == cache_key then
        return self._cached_patch_entries
    end

    local aggregated = {}
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
    local result = self:sortPatchEntries(aggregated)
    self._cached_patch_entries = result
    self._cached_patch_entries_key = cache_key
    return result
end

local function getRepoVersionOrDate(repo, installed_lookup)
    local ver = repo.latest_version or repo.version or repo.tag_name or repo.release_tag
    if not ver and repo.data then
        ver = repo.data.tag_name or repo.data.latest_version or repo.data.version
    end
    if not ver and installed_lookup then
        local inst = (repo.full_name and installed_lookup[repo.full_name]) or (repo.id and installed_lookup["id:" .. tostring(repo.id)])
        if type(inst) == "table" then
            ver = inst.version or inst.tag_name or inst.latest_version
        end
    end
    if ver and type(ver) == "string" and ver ~= "" then
        if not ver:match("^v") and ver:match("^%d") then
            return "v" .. ver
        end
        return ver
    end
    local ts = repo.data and (repo.data.pushed_at or repo.data.created_at)
    return (ts and type(ts) == "string") and ts:sub(1, 10) or ""
end

function Storefront:makeRepoMenuItem(repo, installed_lookup)
    local is_installed = false
    if installed_lookup then
        if repo.full_name and (installed_lookup[repo.full_name] or installed_lookup[repo.full_name:lower()]) then
            is_installed = true
        elseif repo.id and installed_lookup["id:" .. tostring(repo.id)] then
            is_installed = true
        elseif installed_lookup.unmatched and repo.name then
            local low_name = repo.name:lower()
            local base_name = low_name:gsub("%.koplugin$", "")
            if installed_lookup.unmatched[low_name] or installed_lookup.unmatched[base_name] then
                is_installed = true
            end
        end
    end
    local stars = repoStarsValue(repo)
    local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)
    local badge = is_installed and _("Installed") or nil
    local description = normalizeDescription(repo.description)
    local owner = getRepoOwner(repo) or ""
    local updated = getRepoVersionOrDate(repo, installed_lookup)

    return {
        name = repo.name or repo.full_name or _("Repository"),
        owner = owner,
        stars_fmt = stars_fmt,
        updated = updated,
        description = description,
        badge = badge,
        text = formatRepoEntry(repo),
        installed = is_installed,
        is_entry = true,
        keep_menu_open = true,
        callback = function()
            self:promptRepoAction(repo)
        end,
        hold_callback = function()
            self:showReadme(repo)
        end,
    }
end

function Storefront:makePatchMenuItem(repo, patch)
    local stars = tonumber(repo.stars) or (repo.data and tonumber(repo.data.stargazers_count)) or 0
    local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)
    local lines = { string.format("• %s — ⭐ %d", patch.filename, stars) }
    if patch.display_path and patch.display_path ~= patch.filename then
        table.insert(lines, "  " .. patch.display_path)
    end
    local repo_title = repo.full_name or repo.name or ""
    if repo_title ~= "" then
        if repoIsFork(repo) then
            repo_title = repo_title .. " " .. _("(fork)")
        end
        table.insert(lines, "  " .. repo_title)
    end
    return {
        name = patch.filename,
        owner = getRepoOwner(repo) or "",
        stars_fmt = stars_fmt,
        updated = "",
        description = patch.display_path or "",
        badge = nil,
        text = table.concat(lines, "\n"),
        is_entry = true,
        keep_menu_open = true,
        callback = function()
            self:promptPatchAction(repo, patch)
        end,
        hold_callback = function()
            self:promptPatchAction(repo, patch)
        end,
    }
end

function Storefront:calculateDynamicPageSize(tab_name)
    local screen_h = Device.screen:getHeight()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    
    local title_height = sc(64)
    local tab_bar_height = sc(38)
    local footer_height = sc(56)
    
    local toolbar_height = 0
    if tab_name == "Updates" then
        toolbar_height = sc(36) + Size.span.vertical_default
    end
    
    local divider_height = Size.line.thin + Size.span.vertical_default
    if tab_name == "Updates" then
        divider_height = divider_height + Size.span.vertical_default
    end
    
    local body_height = screen_h - title_height - tab_bar_height - toolbar_height - divider_height - footer_height
    if body_height < math.floor(screen_h * 0.5) then
        body_height = math.floor(screen_h * 0.5)
    end
    
    local item_height
    if tab_name == "Plugins" then
        item_height = sc(102)
    elseif tab_name == "Patches" then
        item_height = sc(102)
    else -- Updates
        item_height = sc(82)
    end
    
    return math.max(1, math.floor(body_height / item_height))
end

function Storefront:buildBrowserEntries()
    self:ensureBrowserState()
    local tab = self.browser_state.tab or "Plugins"
    if tab == "Updates" then
        local items, total_pages = self:buildUpdatesEntries()
        self._last_total_pages = total_pages
        self._last_total_kind = self.browser_state.kind or "plugin"
        return items, total_pages
    end
    local kind = tab == "Plugins" and "plugin" or "patch"
    self.browser_state.kind = kind
    local items = {}

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

    local filtered, total = self:getFilteredDescriptors(kind)
    -- table.insert(items, {
    --     text = self:getCacheStatusLine(kind, total),
    --     select_enabled = false,
    -- })
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
    -- table.insert(items, {
    --     text = match_line,
    --     select_enabled = false,
    -- })
    -- items[#items].separator = true

    local page_size = self:calculateDynamicPageSize(tab)
    local total_pages = math.max(1, math.ceil(display_total / page_size))
    local page = math.min(math.max(self.browser_state.page or 1, 1), total_pages)
    if self.browser_state.page ~= page then
        self.browser_state.page = page
        self:saveBrowserState()
    end

    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(display_total, start_index + page_size - 1)

    -- Set of repos already installed (by full name and repo id), so the
    -- available list can mark them. Cached across renders; see getInstalledLookup.
    local installed_lookup
    if kind == "plugin" then
        installed_lookup = self:getInstalledLookup()
    end

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
                table.insert(items, self:makeRepoMenuItem(filtered[i], installed_lookup))
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

function Storefront:closeBrowserMenu()
    if self.browser_menu then
        UIManager:close(self.browser_menu)
        self.browser_menu = nil
    end
end

function Storefront:resetBrowserScrollState()
    if self.browser_menu and self.browser_menu.resetScroll then
        self.browser_menu:resetScroll()
    end
    self.skip_scroll_save = true
end

-- Given the live browser/manager dialog and a flip direction, return the focus
-- hint for the rebuilt dialog so the cursor stays where the user expects:
--   on a list entry  -> top entry when flipping forward, bottom when backward
--   on a control row -> the same control row
--   on a footer page-control -> the same footer control (with fallback)
function Storefront:computePageFlipFocus(dialog, forward)
    if not dialog or not dialog.getFocusContext then return nil end
    local ctx = dialog:getFocusContext()
    if ctx.kind == "entry" then
        return { entry = forward and "first" or "last" }
    elseif ctx.kind == "control" and ctx.focus_id then
        return { id = ctx.focus_id }
    elseif ctx.kind == "toolbar" and ctx.which then
        return { toolbar = ctx.which }
    elseif ctx.kind == "footer" and ctx.which then
        return { footer = ctx.which, direction = forward and "forward" or "backward" }
    end
    return nil
end

function Storefront:reopenBrowser(kind)
    if self.browser_state and self.browser_state.scroll_offset == nil then
        self:resetBrowserScrollState()
    end
    UIManager:nextTick(function()
        self:showBrowser(kind)
    end)
end

-- Browser actions, shared by the gear menu, the Menu hardware key and the
-- r/f/s/t hotkeys. Kept out of the list body so they are reachable from any
-- scroll position / page without scrolling back to the top.
function Storefront:browserSwitchTab(tab_name)
    self:ensureBrowserState()
    if not tab_name then
        local current = self.browser_state.tab or "Plugins"
        if current == "Plugins" then
            tab_name = "Patches"
        elseif current == "Patches" then
            tab_name = "Updates"
        else
            tab_name = "Plugins"
        end
    end
    self.browser_state.tab = tab_name
    self.browser_state.kind = (tab_name == "Patches" and "patch" or "plugin")
    self.browser_state.page = 1
    self.browser_state.scroll_offset = nil
    self:resetFiltersForRefresh()
    self:saveBrowserState()
    self:resetBrowserScrollState()
    self:closeBrowserMenu()
    self:showBrowser()
end

function Storefront:browserRefresh()
    self:ensureBrowserState()
    local kind = self.browser_state.kind or "plugin"
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
end

function Storefront:browserManageInstalled()
    self:ensureBrowserState()
    local kind = self.browser_state.kind or "plugin"
    self:closeBrowserMenu()
    if kind == "plugin" then
        self:showUpdatesDialog()
    else
        self:showPatchUpdatesDialog()
    end
end

function Storefront:browserOpenFilter()
    self:showFilterDialog()
end

function Storefront:browserAdvanceSort()
    self:advanceSortMode()
end

function Storefront:softRefreshCurrentBrowserView()
    self._repo_descriptors_cache = nil
    self._filtered_descriptors_cache = nil

    if self.browser_menu then
        UIManager:setDirty(self.browser_menu)
    end
end

function Storefront:maybeCheckCatalogBackground()
    local GitHub = require("storefront_net_github")
    if GitHub.isDirectApiEnabled() then
        return
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not (ok_nm and NetworkMgr) then
        return
    end

    local is_online = false
    if type(NetworkMgr.isOnline) == "function" then
        is_online = NetworkMgr:isOnline()
    elseif type(NetworkMgr.isWifiOn) == "function" then
        is_online = NetworkMgr:isWifiOn()
    elseif type(NetworkMgr.isConnected) == "function" then
        is_online = NetworkMgr:isConnected()
    end

    if not is_online then
        return
    end

    local Cache = require("storefront_cache")
    local current_tab = (self.browser_state and self.browser_state.tab) or "Plugins"
    local check_kind = (current_tab == "Patches") and "patch" or "plugin"
    local last_fetched = Cache.getLastFetched(check_kind) or 0
    local now = os.time()
    local age = (last_fetched > 0) and (now - last_fetched) or 999999

    if last_fetched == 0 or age > 3600 then
        local msg = string.format("Storefront: catalog cache is stale (%ds old > 3600s), triggering background fetch", age)
        logger.info(msg)
        StorefrontLogger.info(msg)

        local CatalogClient = require("storefront_net_catalog")
        CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
            if ok then
                logger.info("Storefront: background catalog update finished")
                StorefrontLogger.info("Storefront: background catalog update finished")
                self:softRefreshCurrentBrowserView()
            else
                logger.warn("Storefront: background catalog update failed: " .. tostring(err))
                StorefrontLogger.warn("Storefront: background catalog update failed: " .. tostring(err))
            end
        end)
    else
        local msg = string.format("Storefront: catalog cache is fresh (%ds old <= 3600s), skipping background fetch", age)
        logger.info(msg)
        StorefrontLogger.info(msg)
    end
end

function Storefront:showBrowser(kind)
    logger.info("Storefront: showBrowser called")
    self:ensureBrowserState()
    if self.browser_menu then
        self:closeBrowserMenu()
    end
    local current_tab = self.browser_state.tab or "Plugins"
    self:maybeAutoCheckUpdates()

    -- Schedule deferred background catalog check 0.5s AFTER opening UI (zero launch delay)
    UIManager:scheduleIn(0.5, function()
        self:maybeCheckCatalogBackground()
    end)

    local title = _("Storefront")
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
    local items, total_pages = self:buildBrowserEntries()
    local initial_focus = self.browser_focus_hint
    self.browser_focus_hint = nil

    local toolbar_buttons
    if current_tab == "Updates" then
        toolbar_buttons = {
            { id = "check_all", text = _("↻ Check all"), callback = function() self:browserRefresh() end },
        }
    end

    local current_generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    local remote_info_key = self.updates_state and self.updates_state.remote_info
    local patch_remote_info_key = self.patch_updates_state and self.patch_updates_state.remote_info
    
    if not self._cached_updates_count 
       or self._cached_updates_gen ~= current_generation
       or self._cached_remote_info ~= remote_info_key
       or self._cached_patch_remote_info ~= patch_remote_info_key then
       
        pcall(function()
            local p_sum = self:collectUpdateSummary()
            local pt_sum = self:collectPatchUpdateSummary()
            self._cached_updates_count = (p_sum.updates or 0) + (pt_sum.updates or 0)
        end)
        self._cached_updates_gen = current_generation
        self._cached_remote_info = remote_info_key
        self._cached_patch_remote_info = patch_remote_info_key
    end
    local updates_count = self._cached_updates_count or 0

    local dialog = StorefrontBrowserDialog:new{
        title = title,
        items = items,
        page = self.browser_state.page,
        total_pages = total_pages,
        scroll_offset = self.browser_state.scroll_offset,
        initial_focus = initial_focus,
        toolbar_buttons = toolbar_buttons,
        current_tab = current_tab,
        updates_count = updates_count,
        updates_filter_only_outdated = self.updates_state.filter_only_outdated,
        on_updates_filter = function(outdated_only)
            self.updates_state.filter_only_outdated = outdated_only
            self.patch_updates_state.filter_only_outdated = outdated_only
            self.browser_state.page = 1
            self.browser_state.scroll_offset = nil
            self:saveBrowserState()
            self:reopenBrowser()
        end,
        on_tab_switch = function(tab_name)
            self.browser_state.tab = tab_name
            self.browser_state.kind = (tab_name == "Patches" and "patch" or "plugin")
            self.browser_state.page = 1
            self.browser_state.scroll_offset = nil
            self:saveBrowserState()
            self:reopenBrowser()
        end,
        on_settings_tap = function()
            self:showStorefrontSettingsDialog()
        end,
        on_refresh = function()
            if self.browser_state.tab == "Updates" then
                self:checkAllUpdates()
            else
                self:browserRefresh()
            end
        end,
        on_filter = function() self:browserOpenFilter() end,
        on_sort = function() self:browserAdvanceSort() end,
        on_switch_tab = function() self:browserSwitchTab() end,
        on_first_page = function()
            if self.browser_state.page > 1 then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, false)
                self.browser_state.page = 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_prev_page = function()
            if self.browser_state.page > 1 then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, false)
                self.browser_state.page = self.browser_state.page - 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_next_page = function()
            local total_pages = self._last_total_kind == (self.browser_state.kind or "plugin") and (self._last_total_pages or 1) or 1
            if self.browser_state.page < total_pages then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, true)
                self.browser_state.page = self.browser_state.page + 1
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_last_page = function()
            local total_pages = self._last_total_kind == (self.browser_state.kind or "plugin") and (self._last_total_pages or 1) or 1
            if self.browser_state.page < total_pages then
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, true)
                self.browser_state.page = total_pages
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
                self:reopenBrowser()
            end
        end,
        on_goto_page = function(page_num)
            local total_pages = self._last_total_kind == (self.browser_state.kind or "plugin") and (self._last_total_pages or 1) or 1
            if page_num >= 1 and page_num <= total_pages and page_num ~= self.browser_state.page then
                local forward = page_num > self.browser_state.page
                self:resetBrowserScrollState()
                self.browser_focus_hint = self:computePageFlipFocus(self.browser_menu, forward)
                self.browser_state.page = page_num
                self.browser_state.scroll_offset = nil
                self:saveBrowserState()
                self._browser_refresh_mode_hint = "partial"
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
    if dialog._used_trapper_progress then
        Trapper:reset()
    end
    self.browser_menu = dialog
    UIManager:show(dialog)
    local refresh_mode = self._browser_refresh_mode_hint or "full"
    self._browser_refresh_mode_hint = nil
    UIManager:setDirty(dialog, refresh_mode)
    end)
end

function Storefront:showFilterDialog()
    require("storefront_filter_dialog"):show(self)
end

function Storefront:showStorefrontSettingsDialog()
    require("storefront_settings_dialog"):show(self)
end

-- Triggered from the Storefront settings dialog. Confirms with the user, then
-- removes every cached README markdown file produced by previous
-- "View README" actions. The cached files are regenerated on demand the next
-- time a README is opened, so deletion is non-destructive.
function Storefront:clearCachedReadmeFiles()
    local confirm
    confirm = ConfirmBox:new{
        text = _("Delete all cached README files? They will be re-downloaded on demand."),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local result = RepoContent.clearReadmeCache()
            local removed = (result and result.removed) or 0
            local errors = (result and result.errors) or {}
            local msg
            if removed == 0 and #errors == 0 then
                msg = _("No cached README files to delete.")
            elseif #errors == 0 then
                msg = string.format(_("Deleted %d cached README file(s)."), removed)
            else
                msg = string.format(_("Deleted %d cached README file(s); %d failed."), removed, #errors)
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
        end,
    }
    UIManager:show(confirm)
end

function Storefront:promptInstallPluginFromURL()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Install plugin from GitHub"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:fetchAndShowPluginRepo(owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:fetchAndShowPluginRepo(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Fetching repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        UIManager:close(progress)
        
        if not repo_data or not repo_data.id then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "plugin",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        self:promptRepoAction(repo)
    end)
end

function Storefront:promptInstallPatchFromURL()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Install patch from GitHub"),
        fields = {
            {
                description = _("Repository owner"),
                text = "",
                hint = _("e.g., koreader"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = _("e.g., koreader"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local owner = util.trim(fields[1] or "")
                        local repo_name = util.trim(fields[2] or "")
                        if owner == "" or repo_name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Both owner and repository name are required."),
                                timeout = 3,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:fetchAndShowPatchRepo(owner, repo_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storefront:fetchAndShowPatchRepo(owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local progress = InfoMessage:new{
        text = string.format(_("Fetching repository %s/%s..."), owner, repo_name),
        timeout = 0,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()
    
    NetworkMgr:runWhenOnline(function()
        local full_name = owner .. "/" .. repo_name
        local repo_data, err = GitHub.fetchRepoMetadata(owner, repo_name)
        
        if not repo_data or not repo_data.id then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = string.format(_("Repository %s not found on GitHub."), full_name),
                timeout = 4,
            })
            return
        end
        
        local repo = {
            kind = "patch",
            name = repo_name,
            owner = owner,
            full_name = full_name,
            id = repo_data.id,
            repo_id = repo_data.id,
            description = repo_data.description,
            data = repo_data,
        }
        
        local entries = self:fetchPatchEntriesFromGitHub(repo)
        UIManager:close(progress)
        
        if not entries or #entries == 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("No patch files found in repository %s."), full_name),
                timeout = 4,
            })
            return
        end
        
        self:showPatchRepoActionDialog(repo, entries)
    end)
end

function Storefront:showPatchRepoActionDialog(repo, entries)
    if not repo or not entries then
        return
    end
    
    local dialog
    local buttons_row = {
        {
            text = _("Install a patch"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showPatchSelectionDialogForInstall(repo, entries)
            end,
        },
        {
            text = _("View README"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                self:showReadme(repo)
            end,
        },
    }
    
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
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(_("Patches found: %d"), #entries)
    
    dialog = ConfirmBox:new{
        text = repo.full_name or repo.name or _("Repository"),
        cancel_text = _("Close"),
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = { buttons_row },
    }
    dialog:addWidget(makeTextBox(table.concat(lines, "\n")))
    UIManager:show(dialog)
end

function Storefront:showPatchSelectionDialogForInstall(repo, entries)
    if not repo or not entries or #entries == 0 then
        return
    end
    
    local dialog
    local buttons = {}
    for idx, entry in ipairs(entries) do
        table.insert(buttons, {
            {
                text = entry.path or entry.display_path or _("patch"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:installPatchFromRepo(repo, entry)
                end,
            },
        })
    end
    
    table.insert(buttons, {
        {
            text = _("Cancel"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })
    
    dialog = ButtonDialog:new{
        title = string.format(_("Select patch file from %s"), repo.full_name or repo.name),
        buttons = buttons,
        tap_close_callback = function()
        end,
    }
    UIManager:show(dialog)
end

function Storefront:getStatusLines()
    local status_lines = { _("Storefront") }
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

    local memo = StorefrontSettings:readSetting("status_text")
    if memo and memo ~= "" then
        table.insert(status_lines, memo)
    end

    return status_lines
end

function Storefront:buildStatusWidget()
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

function Storefront:buildListWidget(lines)
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


-- Set of installed repos (by full name and repo id), used to mark the
-- plugin-kind browse list. Cached in memory and only rebuilt when the
-- install store actually changes (install/uninstall/match), instead of on
-- every browser render (page flip, sort, filter change).
function Storefront:getInstalledLookup()
    local generation = InstallStore.getGeneration and InstallStore.getGeneration()
    local cache = self._installed_lookup_cache
    if cache and cache.generation == generation then
        return cache.lookup
    end
    local lookup = { exact = {}, unmatched = {} }
    for _, rec in pairs(getInstallRecordsMap()) do
        local full_name = rec.repo_full_name
        if not full_name and rec.owner and rec.repo then
            full_name = rec.owner .. "/" .. rec.repo
        end
        local has_exact = false
        if full_name then
            has_exact = true
            lookup[full_name] = true
            lookup[full_name:lower()] = true
            lookup.exact[full_name] = true
            lookup.exact[full_name:lower()] = true
        end
        if rec.repo_id then
            has_exact = true
            lookup["id:" .. tostring(rec.repo_id)] = true
            lookup.exact["id:" .. tostring(rec.repo_id)] = true
        end

        if not has_exact then
            if rec.dirname then
                local low = rec.dirname:lower()
                local base = low:gsub("%.koplugin$", "")
                lookup[rec.dirname] = true
                lookup[low] = true
                lookup[base] = true
                lookup.unmatched[rec.dirname] = true
                lookup.unmatched[low] = true
                lookup.unmatched[base] = true
            end
        end
    end
    self._installed_lookup_cache = { generation = generation, lookup = lookup }
    return lookup
end

function Storefront:getRepoDescriptors(kind)
    -- Cache the built descriptor list in memory: rebuilding it reads the whole
    -- repo cache from disk and allocates a table per repo (hundreds of them),
    -- which is the dominant cost when flipping pages. Invalidate when the cache's
    -- last-fetched stamp changes (refresh) — see refreshCache resetting it too.
    local fetched = Cache.getLastFetched and Cache.getLastFetched(kind)
    local cache = self._repo_descriptors_cache
    if cache and cache[kind] and cache[kind].fetched == fetched then
        return cache[kind].descriptors
    end
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
            stars = (repo.stars and repo.stars > 0) and repo.stars or (repo.data and tonumber(repo.data.stargazers_count) or 0),
            language = repo.language,
            description = repo.description,
            homepage = repo.homepage,
            default_branch = repo.default_branch,
            latest_release = repo.latest_release,
            patch_files = repo.patch_files,
            data = repo.data,
        }
        table.insert(descriptors, descriptor)
    end
    self._repo_descriptors_cache = self._repo_descriptors_cache or {}
    self._repo_descriptors_cache[kind] = { fetched = fetched, descriptors = descriptors }
    return descriptors
end

function Storefront:renderRepoLines(descriptors)
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
    local shortest_meta_path_len

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            if path:match("^_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    plugin_root = ""
                    plugin_dirname = nil
                    shortest_meta_path_len = #path
                end
            elseif path:match("%.koplugin/_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    local root = path:match("(.+%.koplugin)/_meta%.lua$")
                    if root then
                        plugin_root = root
                        plugin_dirname = root:match("([^/]+%.koplugin)$")
                        shortest_meta_path_len = #path
                    end
                end
            elseif not meta_entry_path and path:match("/_meta%.lua$") then
                if not shortest_meta_path_len or #path < shortest_meta_path_len then
                    meta_entry_path = path
                    plugin_root = path:match("(.+)/_meta%.lua$")
                    plugin_dirname = nil
                    shortest_meta_path_len = #path
                end
            end
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
        
        -- 1. Check if an installed plugin on disk already matches this repo
        if repo and repo.name then
            local target_owner = getRepoOwner(repo)
            if target_owner then
                local records = getInstallRecordsMap()
                local installed = listInstalledPlugins()
                for _, inst in ipairs(installed) do
                    local rec = records[inst.dirname]
                    if rec and rec.owner and rec.repo then
                        if rec.owner:lower() == target_owner:lower() and rec.repo:lower() == repo.name:lower() then
                            plugin_dirname = inst.dirname
                            break
                        end
                    end
                end
            end
        end

        if not plugin_dirname then
            if repo_is_plugin_dir then
                plugin_dirname = repo_name
            elseif plugin_root and plugin_root ~= "" then
                local root_basename = plugin_root:match("([^/]+)$")
                if root_basename then
                    if root_basename:match("%.koplugin") then
                        local extracted = root_basename:match("([%w_%-%.]+%.koplugin)")
                        if extracted then
                            plugin_dirname = extracted
                        end
                    elseif root_basename ~= "plugins" and root_basename ~= "src" and root_basename:match("^[%w_%-%.]+$") then
                        plugin_dirname = sanitizePluginDirname(root_basename)
                    end
                end
            end
        end
        
        if not plugin_dirname then
            if repo_name and repo_name ~= "" then
                plugin_dirname = sanitizePluginDirname(repo_name)
            elseif plugin_name and plugin_name ~= "" then
                plugin_dirname = sanitizePluginDirname(plugin_name)
            else
                plugin_dirname = sanitizePluginDirname("Storefront")
            end
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

extractPluginToUserDir = function(reader, info, dest_root)
    dest_root = dest_root or PluginPaths.getDefaultPluginsRoot()
    util.makePath(dest_root)
    local target_dir = dest_root .. "/" .. info.plugin_dirname

    -- Protected configuration files that must NOT be overwritten when updating
    -- an existing plugin directory (preserving user-edited tokens/settings).
    local protected_configs = {
        ["storefront_config.lua"] = true,
        ["storefront_configuration.lua"] = true,
    }

    -- Collect the set of relative paths coming from the archive so we can
    -- remove only those files before extraction.  Files that exist locally
    -- but are NOT in the archive (e.g. user-created configuration files)
    -- are left untouched.
    local archive_relatives = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if info.plugin_root == "" then
                archive_relatives[entry.path] = true
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                archive_relatives[entry.path:sub(#info.plugin_root + 2)] = true
            end
        end
    end

    -- Remove only the files that the archive will replace so stale code
    -- from a previous version does not linger.
    if lfs.attributes(target_dir, "mode") == "directory" then
        local function remove_archive_files(dir, prefix)
            for f in lfs.dir(dir) do
                if f ~= "." and f ~= ".." then
                    local rel = (prefix == "") and f or (prefix .. "/" .. f)
                    local full = dir .. "/" .. f
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        remove_archive_files(full, rel)
                    elseif mode == "file" and archive_relatives[rel] and not protected_configs[rel] then
                        os.remove(full)
                    end
                end
            end
        end
        remove_archive_files(target_dir, "")
    end

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local relative
            if info.plugin_root == "" then
                relative = entry.path
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                relative = entry.path:sub(#info.plugin_root + 2)
            end

            if relative then
                local dest_path = target_dir .. "/" .. relative
                -- Preserve existing user configuration files during updates
                if not (protected_configs[relative] and lfs.attributes(dest_path, "mode") == "file") then
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
        end
    end

    return true, target_dir
end

-- NOTE: Storefront_config and the remembered-path settings key are
-- resolved locally (rather than as file-level locals like the other
-- *_KEY constants) because main.lua's chunk is already at LuaJIT's 200
-- local variable ceiling; scoping them to this function keeps them out of
-- that shared budget without changing behavior (require() is cached, so
-- repeat calls are cheap).
function Storefront:resolveNewInstallDestination(callback, on_cancel)
    local REMEMBERED_PLUGIN_INSTALL_PATH_KEY = "remembered_plugin_install_path"
    local ok_cfg, StorefrontConfig = pcall(require, "storefront_config")
    if not ok_cfg then
        ok_cfg, StorefrontConfig = pcall(require, "storefront_configuration")
    end
    if not ok_cfg then
        StorefrontConfig = {}
    end

    local config_override = StorefrontConfig.plugin_install_path
    local remembered_path = StorefrontSettings:readSetting(REMEMBERED_PLUGIN_INSTALL_PATH_KEY)
    local hidden_paths = StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}

    local dest_root, needs_prompt, candidates, all_hidden =
        PluginPaths.resolveInstallDestination(config_override, remembered_path, hidden_paths)

    if all_hidden then
        local warn_dialog
        warn_dialog = ConfirmBox:new{
            text = _("All of your custom plugin folders are currently hidden (see Manage plugin paths). Install to the default plugin folder anyway?"),
            ok_text = _("Install to default"),
            ok_callback = function()
                callback(PluginPaths.getDefaultPluginsRoot())
            end,
            cancel_text = _("Cancel"),
            cancel_callback = function()
                on_cancel()
            end,
        }
        UIManager:show(warn_dialog)
        return
    end

    if not needs_prompt then
        callback(dest_root)
        return
    end

    local options = {}
    for _, p in ipairs(candidates) do
        table.insert(options, p)
    end
    table.insert(options, PluginPaths.getDefaultPluginsRoot())

    local remember_choice = false
    local dialog
    local buttons = {}
    for _, path_option in ipairs(options) do
        local chosen_path = path_option -- upvalue capture per row
        table.insert(buttons, {
            {
                text = chosen_path,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if remember_choice then
                        StorefrontSettings:saveSetting(REMEMBERED_PLUGIN_INSTALL_PATH_KEY, chosen_path)
                        StorefrontSettings:flush()
                    end
                    callback(chosen_path)
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = _("Multiple custom plugin folders are configured. Where should this plugin be installed?"),
        title_align = "center",
        buttons = buttons,
        dismissable = false, -- a destination choice is mandatory; the downloaded
        -- archive and its reader handle are only cleaned up inside the button
        -- callbacks above, so this dialog must not be dismissable without one.
    }

    local remember_checkbox = CheckButton:new{
        text = _("Always install here (don't ask again)"),
        checked = false,
        parent = dialog,
        callback = function()
            remember_choice = not remember_choice
        end,
    }
    dialog:addWidget(remember_checkbox)

    UIManager:show(dialog)
end

function Storefront:promptRepoAction(repo)
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

    local DetailsDialog = require("storefront_details_dialog")
    local details_dialog = DetailsDialog:new{
        Storefront = self,
        repo = repo,
        kind = "plugin",
    }
    details_dialog:show()
end

function Storefront:installPluginFromRepo(repo)
    if not repo then
        return
    end

    NetworkMgr:runWhenOnline(function()
        self:_installPluginFromRepoInternal(repo)
    end)
end

function Storefront:_installPluginFromRepoInternal(repo)
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

    StorefrontLogger.action(string.format("INSTALL direct repo starting: %s/%s", owner, repo.name))

    local url
    local branch = repo.default_branch or (repo.data and repo.data.default_branch) or "main"
    local release = repo.latest_release or (repo.data and repo.data.latest_release)

    if release and type(release) == "table" then
        if release.download_url and release.download_url ~= "" then
            url = release.download_url
        elseif release.assets and type(release.assets) == "table" and #release.assets > 0 then
            for _, asset in ipairs(release.assets) do
                if asset.name and asset.name:match("%.zip$") and asset.browser_download_url then
                    url = asset.browser_download_url
                    break
                end
            end
            if not url and release.assets[1] then
                url = release.assets[1].browser_download_url
            end
        elseif release.zipball_url and release.zipball_url ~= "" then
            url = release.zipball_url
        elseif release.tag_name and release.tag_name ~= "" then
            url = string.format("https://github.com/%s/%s/archive/refs/tags/%s.zip", owner, repo.name, release.tag_name)
        end
    end

    if not url or url == "" then
        if GitHub.isDirectApiEnabled() then
            url = string.format("https://api.github.com/repos/%s/%s/zipball", owner, repo.name)
        else
            url = string.format("https://github.com/%s/%s/archive/refs/heads/%s.zip", owner, repo.name, branch)
        end
    end

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

    local function proceedWithInstall(dest_root)
        local install_progress = InfoMessage:new{
            text = _("Installing plugin…"),
            timeout = 0,
        }
        UIManager:show(install_progress)
        local ok_extract, dest_or_err = extractPluginToUserDir(reader, info, dest_root)
        reader:close()
        util.removeFile(zip_path)

        if not ok_extract then
            UIManager:show(InfoMessage:new{
                text = _("Installation failed: ") .. tostring(dest_or_err),
                timeout = 6,
            })
            return
        end

        -- Fall back to the directory name if plugin_name came back nil (e.g. a
        -- _meta.lua that only sets fullname), so we never show "nil".
        info.plugin_name = info.plugin_name or ((info.plugin_dirname or "plugin"):gsub("%.koplugin$", ""))
        local msg
        if self.pending_install_context and self.pending_install_context.mode == "update" then
            if info.plugin_version and info.plugin_version ~= "" then
                msg = string.format(_("Updated plugin \"%s\" to version %s."), info.plugin_name, info.plugin_version)
            else
                msg = string.format(_("Updated plugin \"%s\"."), info.plugin_name)
            end
        else
            if info.plugin_version and info.plugin_version ~= "" then
                msg = string.format(_("Installed plugin \"%s\" (version %s)."), info.plugin_name, info.plugin_version)
            else
                msg = string.format(_("Installed plugin \"%s\"."), info.plugin_name)
            end
        end

        UIManager:close(install_progress)
        StorefrontLogger.action(msg)
        showRestartConfirmation(msg)

        self:handlePostInstall(info, repo)
        if self.updates_menu then
            self:updateUpdatesDialog()
        end
    end

    if self.pending_install_context and self.pending_install_context.mode == "update" then
        proceedWithInstall(self.pending_install_context.plugin.root)
    else
        self:resolveNewInstallDestination(proceedWithInstall, function()
            reader:close()
            util.removeFile(zip_path)
        end)
    end
end

function Storefront:handlePostInstall(info, repo)
    if info and info.plugin_dirname and (not info.plugin_version or info.plugin_version == "") then
        local root = (self.pending_install_context and self.pending_install_context.plugin and self.pending_install_context.plugin.root)
            or PluginPaths.getDefaultPluginsRoot()
        local meta_path = root .. "/" .. info.plugin_dirname .. "/_meta.lua"
        local ok_meta, meta = pcall(dofile, meta_path)
        if ok_meta and type(meta) == "table" and meta.version then
            info.plugin_version = meta.version
        end
    end

    self:rememberInstall(info, repo)
    self._cached_plugin_summary = nil
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
            if info.plugin_dirname then
                self:ensureUpdatesState()
                local cached = self.updates_state.remote_info[info.plugin_dirname] or {}
                if info.plugin_version and info.plugin_version ~= "" then
                    cached.remote_version = info.plugin_version
                end
                cached.last_checked = os.time()
                cached.error = nil
                self.updates_state.remote_info[info.plugin_dirname] = cached
                self:saveUpdatesState()
            end
        end
    end
end

function Storefront:showRepoList(kind, title)
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

function Storefront:promptSelection(descriptors, title)
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

function Storefront:showReadme(repo)
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

-- GitHub Search API returns at most 1000 results per query.
-- Strategy (adaptive, applied per base query):
--   1. Start with two server-side filtered queries per base: non-fork and
--      fork. `include_zero_star_forks` controls whether 0-star forks are
--      requested at all (they are filtered server-side, never client-side).
--   2. Read `total_count` from the first real page (no dedicated probe) and:
--        - if total_count < 1000 → paginate the branch normally;
--        - if total_count >= 1000 → fall back to the legacy star split for
--          that one branch, and then exhaustiveSearch handles any sub-query
--          that still overflows by bisecting on created:date.
local SEARCH_RESULT_LIMIT = 1000
local SEARCH_DATE_BISECT_MAX_DEPTH = 8
local SEARCH_ORIGIN_DATE = "2010-01-01"

local function dateToTimestamp(date_str)
    local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
    if not y then return os.time() end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

local function timestampToDate(ts)
    return os.date("%Y-%m-%d", ts)
end

-- Build the minimal set of queries needed to cover both non-fork and fork
-- repositories while honoring the `include_zero_star_forks` preference.
-- GitHub Search default excludes forks unless `fork:only` or `fork:true` is
-- specified, so we can split the work into two server-side filtered queries.
-- When `include_zero` is false, 0-star forks are never downloaded; the
-- `fork:only stars:>=1` qualifier keeps that filtering on GitHub's side.
-- When the ecosystem grows past ~1000 results per sub-query the inner
-- adaptive exhaustiveSearch handles the overflow by falling back to star
-- splits and/or date bisection — see the 4-way STAR_SPLIT_SUFFIXES below.
local NON_FORK_SUFFIX = ""
local FORK_WITH_STARS_SUFFIX = " fork:only stars:>=1"
local FORK_ANY_STARS_SUFFIX = " fork:only"

-- Legacy-compatible star split used ONLY when a sub-query exceeds the
-- GitHub 1000-result hard cap. Paired up with `include_zero_star_forks`
-- the same way the original `expandQueryForForkStarSplit` did.
local STAR_SPLIT_SUFFIXES_NONFORK = { " stars:0", " stars:>=1" }
local STAR_SPLIT_SUFFIXES_FORK_DEFAULT = { " fork:only stars:>=1" }
local STAR_SPLIT_SUFFIXES_FORK_WITH_ZERO = { " fork:only stars:0", " fork:only stars:>=1" }

-- When a single adaptive query hits the 1000-result ceiling we fall back to
-- the legacy star-split approach for that branch. The split suffixes are
-- applied to `base_query` (without the fork suffix) so callers can pick the
-- matching set based on whether the failing query is the non-fork or the
-- fork branch.
local function starSplitSuffixes(branch, include_zero)
    if branch == "nonfork" then
        return STAR_SPLIT_SUFFIXES_NONFORK
    end
    if include_zero then
        return STAR_SPLIT_SUFFIXES_FORK_WITH_ZERO
    end
    return STAR_SPLIT_SUFFIXES_FORK_DEFAULT
end

local function buildRateLimitMessage()
    if GitHub.hasAuthToken() then
        return _("GitHub API rate limit exceeded. Please wait a few minutes and try again.")
    end
    return _("GitHub API rate limit exceeded. Add a GitHub token in Storefront settings to increase the limit (10→30 req/min).")
end

-- Issue one Search API call for `query` at the given page. Returns
-- `response_table, err_info`. On rate-limit it raises a user-facing error
-- (caught by the caller in pcall) so the refresh can surface the limit
-- message without silently dropping data.
local function performSearchPage(query, page, per_page)
    local response, err = GitHub.searchRepositories({
        q = query,
        per_page = per_page,
        sort = "stars",
        order = "desc",
        page = page,
    })
    if not response then
        if type(err) == "table" and err.is_fine_grained_unsupported then
            error(_("GitHub rejected this request: fine-grained personal access tokens are not supported for search. Please use a classic token instead (see the Storefront README)."))
        end
        if type(err) == "table" and err.is_rate_limit then
            err.body = buildRateLimitMessage()
            return nil, err
        end
    end
    return response, err
end

-- Paginate `query` starting at `start_page`, invoking `append(repo)` for
-- every result. Returns err_info on failure (after any collected items
-- have been appended), or nil on completion.
local function paginateFromPage(query, append, start_page)
    local per_page = 100
    local page = start_page or 1
    while true do
        local response, err = performSearchPage(query, page, per_page)
        if not response then
            return err
        end
        local items = response.items or {}
        if #items == 0 then
            return nil
        end
        for _, repo in ipairs(items) do
            append(repo)
        end
        if #items < per_page then
            return nil
        end
        page = page + 1
    end
end

-- Exhaustively fetch all results for `base_query`, dynamically falling back
-- to date bisection when a query exceeds GitHub's 1000-result hard limit.
--
-- Key difference from the legacy version: there is no dedicated probe
-- call. The first page (per_page=100) already reports `total_count`, so we
-- consume that page directly, branch based on the reported total, and only
-- continue paginating when we are safely under the limit. This saves one
-- API call per sub-query in the common case where the ecosystem has fewer
-- than 1000 repos per branch (which is the current KOReader reality).
local function exhaustiveSearch(base_query, append, date_from, date_to, depth)
    depth = depth or 0

    local query = base_query
    if date_from and date_to then
        query = base_query .. string.format(" created:%s..%s", date_from, date_to)
    end

    local first_response, first_err = performSearchPage(query, 1, 100)
    if not first_response then
        logger.warn("Storefront search first-page error", query, first_err and first_err.body or first_err)
        return
    end

    local total_count = tonumber(first_response.total_count) or 0
    local first_items = first_response.items or {}

    -- Always consume the first page's items; they are highest-starred and
    -- appendUniqueRepo deduplicates against later bisected sub-queries.
    for _, repo in ipairs(first_items) do
        append(repo)
    end

    if total_count < SEARCH_RESULT_LIMIT or depth >= SEARCH_DATE_BISECT_MAX_DEPTH then
        if total_count >= SEARCH_RESULT_LIMIT then
            logger.warn("Storefront: date bisect depth limit reached, some results may be lost", query, total_count)
        end
        -- Fetch remaining pages if there could be more results beyond page 1.
        if #first_items >= 100 then
            local err = paginateFromPage(query, append, 2)
            if err then
                logger.warn("Storefront pagination error", query, err)
            end
        end
        return
    end

    -- total_count >= 1000 — bisect by created date. We skip paginating the
    -- flat query (the legacy probe path did the same) because the bisected
    -- sub-queries will cover the remaining ranks via their date windows.
    logger.info("Storefront: query has", total_count, "results (>=1000), bisecting by date", query)
    local from_ts = date_from and dateToTimestamp(date_from) or dateToTimestamp(SEARCH_ORIGIN_DATE)
    local to_ts = date_to and dateToTimestamp(date_to) or os.time()

    if to_ts - from_ts < 86400 then
        -- Date range too small to split, just take what we can from this range.
        if #first_items >= 100 then
            local err = paginateFromPage(query, append, 2)
            if err then
                logger.warn("Storefront pagination error (tiny range)", query, err)
            end
        end
        return
    end

    local mid_ts = math.floor((from_ts + to_ts) / 2)
    local mid_date = timestampToDate(mid_ts)
    local next_date = timestampToDate(mid_ts + 86400)
    local from_str = date_from or SEARCH_ORIGIN_DATE
    local to_str = date_to or timestampToDate(os.time())

    exhaustiveSearch(base_query, append, from_str, mid_date, depth + 1)
    exhaustiveSearch(base_query, append, next_date, to_str, depth + 1)
end

-- Run one adaptive branch (non-fork or fork) for `base_topic_query`, with
-- automatic fallback to the legacy star split when the branch exceeds the
-- 1000-result limit. The first-page response is used both to count results
-- and to consume the first 100 items, so no extra probe call is issued.
local function exhaustiveSearchAdaptive(base_topic_query, branch_suffix, append, branch)
    local query = base_topic_query .. branch_suffix

    local first_response, first_err = performSearchPage(query, 1, 100)
    if not first_response then
        logger.warn("Storefront adaptive search first-page error", query, first_err and first_err.body or first_err)
        return
    end

    local total_count = tonumber(first_response.total_count) or 0
    local first_items = first_response.items or {}

    for _, repo in ipairs(first_items) do
        append(repo)
    end

    if total_count < SEARCH_RESULT_LIMIT then
        if #first_items >= 100 then
            local err = paginateFromPage(query, append, 2)
            if err then
                logger.warn("Storefront adaptive pagination error", query, err)
            end
        end
        return
    end

    -- Over the 1000-result cap: fall back to the legacy star split for this
    -- branch and let exhaustiveSearch handle date bisection if any sub-query
    -- still overflows.
    logger.info("Storefront: adaptive branch exceeded limit, falling back to star split",
        query, total_count)
    local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
    for _, suffix in ipairs(starSplitSuffixes(branch, include_zero)) do
        exhaustiveSearch(base_topic_query .. suffix, append)
    end
end

function Storefront:fetchAndStore(kind, topics, label, name_queries)
    local collected = {}
    local seen = {}
    local function append(repo)
        appendUniqueRepo(collected, seen, repo)
    end

    -- Topic-based query: run the adaptive non-fork + fork pair. Each branch
    -- falls back to the legacy star split only when it individually exceeds
    -- the 1000-result GitHub cap (rare for the KOReader ecosystem).
    if topics then
        local parts = {}
        for _, topic in ipairs(topics) do
            if topic and topic ~= "" then
                table.insert(parts, string.format("topic:%s", topic))
            end
        end
        local base_topic_query = table.concat(parts, " ")
        if base_topic_query ~= "" then
            -- Non-fork branch (default GitHub behavior excludes forks).
            exhaustiveSearchAdaptive(base_topic_query, NON_FORK_SUFFIX, append, "nonfork")
            -- Fork branch: suffix honors `include_zero_star_forks` server-side.
            local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
            local fork_suffix = include_zero and FORK_ANY_STARS_SUFFIX or FORK_WITH_STARS_SUFFIX
            exhaustiveSearchAdaptive(base_topic_query, fork_suffix, append, "fork")
        end
    end

    -- Name-based queries: same adaptive two-branch approach per base query.
    if name_queries then
        local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
        local fork_suffix = include_zero and FORK_ANY_STARS_SUFFIX or FORK_WITH_STARS_SUFFIX
        for _, base_query in ipairs(name_queries) do
            if base_query and base_query ~= "" then
                exhaustiveSearchAdaptive(base_query, NON_FORK_SUFFIX, append, "nonfork")
                exhaustiveSearchAdaptive(base_query, fork_suffix, append, "fork")
            end
        end
    end

    Cache.storeRepos(kind, collected)
    return #collected
end

function Storefront:refreshCache(kind)
    if self.is_refreshing then
        return
    end
    self:ensureBrowserState()
    kind = kind or (self.browser_state and self.browser_state.kind) or "plugin"

    self.is_refreshing = true
    self.patch_cache = {}
    self._repo_descriptors_cache = nil
    StorefrontLogger.info(string.format("CACHE REFRESH starting (kind=%s)", tostring(kind)))
    local progress = InfoMessage:new{ text = _("Refreshing Storefront cache..."), timeout = 0 }
    UIManager:show(progress)

    local summary
    local ok, err = pcall(function()
        local CatalogClient = require("storefront_net_catalog")
        if not GitHub.isDirectApiEnabled() then
            logger.info("Storefront: refreshing via static catalog feed")
            local catalog_ok, catalog_err = CatalogClient.fetchAndUpdateCache()
            if catalog_ok then
                local p_count = Cache.countRepos("plugin")
                local pt_count = Cache.countRepos("patch")
                summary = string.format(_("Catalog updated: %d plugins, %d patches."), p_count, pt_count)
                StorefrontSettings:saveSetting("status_text", summary)
                StorefrontSettings:flush()
                return
            else
                logger.warn("Storefront static catalog update failed, falling back to direct API", catalog_err)
            end
        end

        local refresh_plugins = (kind == "plugin") or (kind == "all")
        local refresh_patches = (kind == "patch") or (kind == "all")
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
            summary = _("Storefront cache refreshed.")
        end
        StorefrontSettings:saveSetting("status_text", summary)
        StorefrontSettings:flush()
    end)

    UIManager:close(progress)
    self.is_refreshing = false

    if ok then
        StorefrontLogger.info(string.format("CACHE REFRESH complete: %s", tostring(summary)))
        UIManager:show(InfoMessage:new{ text = summary or _("Storefront cache refreshed."), timeout = 5 })
    else
        local message = tostring(err)
        StorefrontLogger.err(string.format("CACHE REFRESH failed: %s", message))
        UIManager:show(InfoMessage:new{ text = _("Storefront refresh failed: ") .. message, timeout = 6 })
    end
end

function Storefront:init()
    StorefrontLogger.reset()
    local mode_str = GitHub.isDirectApiEnabled() and "Direct API" or "Storefront Catalog"
    local plugin_count = Cache.countRepos and Cache.countRepos("plugin") or #Cache.listRepos("plugin")
    StorefrontLogger.info(string.format("Storefront initialized (Mode: %s, Cached plugins: %d)", mode_str, plugin_count or 0))
    Storefront.instance = self
    self.cache_dir = ensureCacheDir()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Migrate settings to page size 5
    StorefrontSettings:writeSetting(BROWSER_PAGE_SIZE_KEY, 5)
    StorefrontSettings:writeSetting(MANAGE_PAGE_SIZE_KEY, 5)
    StorefrontSettings:flush()

    -- Cleanup legacy test files from plugin directory if updating from an older version
    local plugin_dir = self.path or (PluginPaths.getDefaultPluginsRoot() .. "/storefront.koplugin")
    local legacy_test_files = {
        "storefront_plugin_paths_test.lua",
        "storefront_readme_test.lua",
        "storefront_release_notes_test.lua",
        "storefront_ui_test.lua",
    }
    local lfs_mod = require("libs/libkoreader-lfs")
    for _, legacy_file in ipairs(legacy_test_files) do
        local legacy_path = plugin_dir .. "/" .. legacy_file
        local ok_attr, attr = pcall(lfs_mod.attributes, legacy_path, "mode")
        if ok_attr and attr == "file" then
            os.remove(legacy_path)
        end
    end

    -- Trigger non-blocking silent catalog update on startup if online and cache is older than 1 hour (3600s)
    UIManager:nextTick(function()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
            NetworkMgr:runWhenOnline(function()
                local Cache = require("storefront_cache")
                local plugin_fetched = Cache.getLastFetched("plugin") or 0
                local patch_fetched = Cache.getLastFetched("patch") or 0
                local last_fetched = (plugin_fetched > 0 and patch_fetched > 0) and math.min(plugin_fetched, patch_fetched) or 0
                local age = (last_fetched > 0) and (os.time() - last_fetched) or 999999
                if not GitHub.isDirectApiEnabled() and (last_fetched == 0 or age > 3600) then
                    local msg = string.format("Storefront init: catalog cache is stale (%ds old > 3600s), triggering background fetch", age)
                    logger.info(msg)
                    StorefrontLogger.info(msg)
                    local CatalogClient = require("storefront_net_catalog")
                    CatalogClient.fetchAndUpdateCacheAsync(nil, function(ok, err)
                        if ok then
                            logger.info("Storefront init: background catalog update finished")
                            StorefrontLogger.info("Storefront init: background catalog update finished")
                            if Storefront.instance and Storefront.instance.browser_menu then
                                Storefront.instance:reopenBrowser()
                            end
                        else
                            logger.warn("Storefront init: background catalog update failed: " .. tostring(err))
                            StorefrontLogger.warn("Storefront init: background catalog update failed: " .. tostring(err))
                        end
                    end)
                else
                    local msg = string.format("Storefront init: catalog cache is fresh (%ds old <= 3600s), skipping background fetch", age)
                    logger.info(msg)
                    StorefrontLogger.info(msg)
                end
            end)
        end
    end)
end


local function injectStorefrontIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            local found = false
            for _, id in ipairs(order.tools) do
                if id == "Storefront" then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(order.tools, 2, "Storefront")
            end
        end
    end
end

function Storefront:addToMainMenu(menu_items)
    injectStorefrontIntoToolsMenu()
    menu_items.Storefront = {
        sorting_hint = "tools",
        text = _("Storefront"),
        callback = function()
            self:showBrowser()
        end,
    }
end

function Storefront:onDispatcherRegisterActions()
    Dispatcher:registerAction("storefront_open", {
        category = "none",
        event = "OpenStorefrontMenu",
        title = _("Open Storefront"),
        general = true,
    })
end

function Storefront:onOpenStorefrontMenu()
    UIManager:nextTick(function()
        self:showBrowser()
    end)
end

Storefront.listInstalledPlugins = listInstalledPlugins
Storefront.listInstalledPatches = listInstalledPatches
Storefront.getInstallRecordsMap = getInstallRecordsMap
Storefront.getPatchRecordsMap = getPatchRecordsMap
Storefront.getBrowserPageSize = getBrowserPageSize

return Storefront

