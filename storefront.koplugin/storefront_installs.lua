local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local logger = require("logger")

local InstallStore = {}

local SETTINGS_DIR = DataStorage:getSettingsDir()
local SETTINGS_PATH = SETTINGS_DIR .. "/Storefront_installs.lua"
local settings = LuaSettings:open(SETTINGS_PATH)

local store_key = "installs"

-- Bumped on every successful write, so callers can cache derived data (e.g.
-- an installed-repo lookup) and only rebuild it when records actually change.
local generation = 0

local transient_record_keys = {
    in_catalog = true,
    cached_latest_release = true,
    cached_latest_prerelease = true,
    cached_version = true,
    cached_default_branch = true,
    cached_pushed_at = true,
    cached_sha = true,
    _store_key = true,
}

local function sanitizeRecord(record)
    if type(record) ~= "table" then
        return record
    end
    local clean = {}
    for k, v in pairs(record) do
        if not transient_record_keys[k] then
            clean[k] = v
        end
    end
    return clean
end

local function shallowCopyRecord(record)
    if type(record) ~= "table" then
        return record
    end
    local copy = {}
    for k, v in pairs(record) do
        copy[k] = v
    end
    return copy
end

local function normalizeData(data)
    if type(data) ~= "table" then
        data = {}
    end
    if data.plugins == nil then
        data = {
            plugins = data,
            patches = {},
            fonts = {},
            item_options = {},
        }
    else
        data.patches = data.patches or {}
        data.fonts = data.fonts or {}
        data.item_options = data.item_options or {}
    end
    if type(data.plugins) == "table" then
        for k, rec in pairs(data.plugins) do
            data.plugins[k] = sanitizeRecord(rec)
        end
    end
    if type(data.patches) == "table" then
        for k, rec in pairs(data.patches) do
            data.patches[k] = sanitizeRecord(rec)
        end
    end
    if type(data.fonts) == "table" then
        for k, rec in pairs(data.fonts) do
            data.fonts[k] = sanitizeRecord(rec)
        end
    end
    return data
end

local cached_store_data = nil

local function readStore()
    if cached_store_data then
        return cached_store_data
    end
    local encoded = settings:readSetting(store_key)
    if type(encoded) ~= "string" or encoded == "" then
        cached_store_data = normalizeData({})
        return cached_store_data
    end
    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("Storefront installs decode error", decoded)
        cached_store_data = normalizeData({})
        return cached_store_data
    end
    cached_store_data = normalizeData(decoded)
    return cached_store_data
end

local in_batch = false
local batch_dirty = false

local function writeStore(data)
    local payload = normalizeData(data)
    cached_store_data = payload
    generation = generation + 1
    if in_batch then
        batch_dirty = true
        return true
    end
    local ok, encoded = pcall(function()
        return json.encode(payload)
    end)
    if not ok then
        logger.warn("Storefront installs encode error", encoded)
        return false
    end
    settings:saveSetting(store_key, encoded)
    settings:flush()
    return true
end

function InstallStore.beginBatch()
    in_batch = true
    batch_dirty = false
end

function InstallStore.endBatch()
    in_batch = false
    if batch_dirty and cached_store_data then
        local ok, encoded = pcall(function()
            return json.encode(cached_store_data)
        end)
        if ok then
            settings:saveSetting(store_key, encoded)
            settings:flush()
        else
            logger.warn("Storefront installs encode error", encoded)
        end
        batch_dirty = false
    end
end

function InstallStore.list()
    return readStore().plugins
end
InstallStore.getRecords = InstallStore.list

-- Monotonic counter bumped on every write, so callers can cache data derived
-- from the store (e.g. an installed-repo lookup) and know when to rebuild it.
function InstallStore.getGeneration()
    return generation
end

function InstallStore.bumpGeneration()
    generation = generation + 1
    return generation
end

function InstallStore.listPatches()
    return readStore().patches
end

function InstallStore.listFonts()
    return readStore().fonts
end

function InstallStore.save(entries)
    local data = readStore()
    data.plugins = entries or {}
    return writeStore(data)
end

function InstallStore.savePatches(entries)
    local data = readStore()
    data.patches = entries or {}
    return writeStore(data)
end

function InstallStore.saveFonts(entries)
    local data = readStore()
    data.fonts = entries or {}
    return writeStore(data)
end

local function isRecordEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.dirname == b.dirname
       and a.owner == b.owner
       and a.repo == b.repo
       and a.repo_full_name == b.repo_full_name
       and a.repo_description == b.repo_description
       and a.repo_id == b.repo_id
       and a.branch == b.branch
       and a.sha == b.sha
       and a.path == b.path
       and a.filename == b.filename
       and a.is_auto_matched == b.is_auto_matched
       and a.version == b.version
       and a.installed_version == b.installed_version
       and a.installed_tag == b.installed_tag
       and a.tag_name == b.tag_name
       and a.matched_at == b.matched_at
       and a.pending_download == b.pending_download
       and a.full_installed == b.full_installed
       and a.download_url == b.download_url
       and a.failed_attempts == b.failed_attempts
       and a.asset_filename == b.asset_filename
       and a.download_error == b.download_error
       and a.source == b.source
       and a.meta_path == b.meta_path
       and a.meta_path_verified == b.meta_path_verified
       and a.plugin_name == b.plugin_name
       and a.ignore_prereleases == b.ignore_prereleases
       and a.allow_prereleases == b.allow_prereleases
end

function InstallStore.upsert(plugin_id, record)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local clean_record = sanitizeRecord(record)
    local data = readStore()
    local existing = data.plugins[plugin_id]
    if isRecordEqual(existing, clean_record) then
        return true
    end
    data.plugins[plugin_id] = clean_record
    return writeStore(data)
end

function InstallStore.upsertPatch(filename, record)
    if not filename or filename == "" then
        return false
    end
    local clean_record = sanitizeRecord(record)
    local data = readStore()
    local existing = data.patches[filename]
    -- Preserve existing SHA if new record doesn't have one (e.g., during match operation).
    -- This ensures install SHA is not lost when matching an already-installed patch.
    if existing and existing.sha and not clean_record.sha then
        clean_record.sha = existing.sha
    end
    if isRecordEqual(existing, clean_record) then
        return true
    end
    data.patches[filename] = clean_record
    return writeStore(data)
end

function InstallStore.upsertFont(font_name, record)
    if not font_name or font_name == "" then
        return false
    end
    local clean_record = sanitizeRecord(record)
    local data = readStore()
    font_name = font_name:lower()
    local existing = data.fonts[font_name]
    if isRecordEqual(existing, clean_record) then
        return true
    end
    data.fonts[font_name] = clean_record
    return writeStore(data)
end

function InstallStore.remove(plugin_id)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local data = readStore()
    if data.plugins[plugin_id] == nil then
        InstallStore.bumpGeneration()
        return true
    end
    data.plugins[plugin_id] = nil
    return writeStore(data)
end

function InstallStore.removePatch(filename)
    if not filename or filename == "" then
        return false
    end
    local data = readStore()
    if data.patches[filename] == nil then
        InstallStore.bumpGeneration()
        return true
    end
    data.patches[filename] = nil
    return writeStore(data)
end

function InstallStore.removeFont(font_name)
    if not font_name or font_name == "" then
        return false
    end
    local data = readStore()
    local clean_target = font_name:lower():gsub("[%s%-_]+", "")
    local alias_map = {
        ["nvbasker"] = {"librebaskerville", "baskerville", "nvbasker", "basker"},
        ["librebaskerville"] = {"librebaskerville", "baskerville", "nvbasker", "basker"},
        ["nvbitter"] = {"bitter", "nvbitter"},
        ["bitter"] = {"bitter", "nvbitter"},
        ["nvliterata"] = {"literata", "nvliterata"},
        ["literata"] = {"literata", "nvliterata"},
        ["gentiumbookplus"] = {"gentiumplus", "gentiumbookplus", "gentium"},
        ["gentiumplus"] = {"gentiumplus", "gentiumbookplus", "gentium"},
        ["opendyslexic"] = {"opendyslexic", "opendyslexic3"},
        ["readerly"] = {"readerly", "newsreader"},
        ["sourcerer"] = {"sourcerer", "sourceserif"},
    }
    local targets = alias_map[clean_target] or { clean_target }

    for k in pairs(data.fonts) do
        local k_clean = k:lower():gsub("[%s%-_]+", "")
        local is_match = false
        for _, t in ipairs(targets) do
            if k_clean:find(t, 1, true) or t:find(k_clean, 1, true) then
                is_match = true
                break
            end
        end
        if is_match then
            data.fonts[k] = nil
        end
    end
    data.fonts[font_name:lower()] = nil
    return writeStore(data)
end

function InstallStore.get(plugin_id)
    if not plugin_id or plugin_id == "" then
        return nil
    end
    local data = readStore()
    return shallowCopyRecord(data.plugins[plugin_id])
end

---@param name string|nil
---@return string|nil
local function normalizeDirBase(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name:gsub("%.koplugin$", ""):lower()
end

---@param dir_name string|nil
---@param core_plugins table|nil
---@return boolean
local function isCorePluginDir(dir_name, core_plugins)
    if type(dir_name) ~= "string" or type(core_plugins) ~= "table" then
        return false
    end
    local clean = normalizeDirBase(dir_name)
    if not clean then
        return false
    end
    return core_plugins[clean .. ".koplugin"] == true or core_plugins[clean] == true
end

---@param rec table|nil
---@return string|nil
local function extractRecordFullNameLower(rec)
    if type(rec) ~= "table" then
        return nil
    end
    if type(rec.repo_full_name) == "string" and rec.repo_full_name ~= "" then
        return rec.repo_full_name:lower()
    end
    if type(rec.owner) == "string" and rec.owner ~= "" and type(rec.repo) == "string" and rec.repo ~= "" then
        return (rec.owner .. "/" .. rec.repo):lower()
    end
    return nil
end

---@param rec table|nil
---@param rec_key string|nil
---@return table|nil, string|nil
local function buildReturnedRecord(rec, rec_key)
    if type(rec) ~= "table" then
        return nil, nil
    end
    local copy = shallowCopyRecord(rec)
    if (type(copy.dirname) ~= "string" or copy.dirname == "") and type(rec_key) == "string" and rec_key ~= "" then
        copy.dirname = rec_key
    end
    copy._store_key = rec_key
    return copy, rec_key
end

---@param cand_k string
---@param cand_r table
---@param best_k string|nil
---@param best_r table|nil
---@param repo_base_lower string|nil
---@param core_plugins table|nil
---@return boolean
local function isBetterRecordCandidate(cand_k, cand_r, best_k, best_r, repo_base_lower, core_plugins)
    if not best_r then
        return true
    end
    local cand_dir = (type(cand_r.dirname) == "string" and cand_r.dirname ~= "" and cand_r.dirname) or cand_k
    local best_dir = (type(best_r.dirname) == "string" and best_r.dirname ~= "" and best_r.dirname) or best_k

    local cand_is_core = isCorePluginDir(cand_dir, core_plugins)
    local best_is_core = isCorePluginDir(best_dir, core_plugins)
    if cand_is_core ~= best_is_core then
        return not cand_is_core
    end

    if repo_base_lower then
        local cand_matches_repo = (normalizeDirBase(cand_dir) == repo_base_lower)
        local best_matches_repo = (normalizeDirBase(best_dir) == repo_base_lower)
        if cand_matches_repo ~= best_matches_repo then
            return cand_matches_repo
        end
    end

    local cand_time = tonumber(cand_r.matched_at) or 0
    local best_time = tonumber(best_r.matched_at) or 0
    if cand_time ~= best_time then
        return cand_time > best_time
    end

    local cand_has_ext = tostring(cand_k):find("%.koplugin$") ~= nil
    local best_has_ext = tostring(best_k):find("%.koplugin$") ~= nil
    if cand_has_ext ~= best_has_ext then
        return cand_has_ext
    end

    return tostring(cand_k) < tostring(best_k)
end

---@param query table { dirname?: string, repo_name?: string, full_name?: string, owner?: string, repo_id?: string|number, core_plugins?: table }
---@return table|nil record, string|nil rec_key
function InstallStore.findPluginRecord(query)
    if type(query) ~= "table" then
        return nil, nil
    end
    local plugins = readStore().plugins or {}
    local core_plugins = query.core_plugins

    local query_repo_id = (query.repo_id ~= nil and tostring(query.repo_id) ~= "") and tostring(query.repo_id) or nil
    local query_full_lower = nil
    if type(query.full_name) == "string" and query.full_name ~= "" then
        query_full_lower = query.full_name:lower()
    elseif type(query.owner) == "string" and query.owner ~= "" and type(query.repo_name) == "string" and query.repo_name ~= "" then
        query_full_lower = (query.owner .. "/" .. query.repo_name):lower()
    end
    local repo_base_lower = normalizeDirBase(query.repo_name)
    if not repo_base_lower and query_full_lower then
        repo_base_lower = normalizeDirBase(query_full_lower:match("/([^/]+)$"))
    end

    -- Pass 1: Explicit dirname lookup (exact key variants, then case-insensitive folder match)
    if type(query.dirname) == "string" and query.dirname ~= "" then
        local raw_dir = query.dirname
        local clean_dir = raw_dir:gsub("%.koplugin$", "")
        local ext_dir = clean_dir .. ".koplugin"
        for _, candidate_key in ipairs({ raw_dir, ext_dir, clean_dir }) do
            if type(plugins[candidate_key]) == "table" then
                return buildReturnedRecord(plugins[candidate_key], candidate_key)
            end
        end

        local clean_lower = clean_dir:lower()
        local best_k, best_r = nil, nil
        for k, r in pairs(plugins) do
            if type(r) == "table" then
                if normalizeDirBase(k) == clean_lower or normalizeDirBase(r.dirname) == clean_lower then
                    if isBetterRecordCandidate(k, r, best_k, best_r, repo_base_lower, core_plugins) then
                        best_k, best_r = k, r
                    end
                end
            end
        end
        if best_r then
            return buildReturnedRecord(best_r, best_k)
        end
    end

    -- Pass 2: Strong repository identity (repo_id or owner/repo full_name)
    if query_repo_id or query_full_lower then
        local best_k, best_r = nil, nil
        for k, r in pairs(plugins) do
            if type(r) == "table" then
                local id_match = (query_repo_id ~= nil and r.repo_id ~= nil and tostring(r.repo_id) == query_repo_id)
                local full_match = (query_full_lower ~= nil and extractRecordFullNameLower(r) == query_full_lower)
                if id_match or full_match then
                    if isBetterRecordCandidate(k, r, best_k, best_r, repo_base_lower, core_plugins) then
                        best_k, best_r = k, r
                    end
                end
            end
        end
        if best_r then
            return buildReturnedRecord(best_r, best_k)
        end
    end

    -- Pass 3: Fallback repo_name / folder match when candidate does not belong to a different owner/repo
    if type(query.repo_name) == "string" and query.repo_name ~= "" then
        local repo_raw = query.repo_name
        local repo_raw_lower = repo_raw:lower()
        local repo_clean_lower = normalizeDirBase(repo_raw)

        local function conflictsWithQueryRepo(r)
            if query_repo_id and r.repo_id ~= nil and tostring(r.repo_id) ~= "" and tostring(r.repo_id) ~= query_repo_id then
                return true
            end
            local rec_full = extractRecordFullNameLower(r)
            if query_full_lower and rec_full and rec_full ~= query_full_lower then
                return true
            end
            return false
        end

        local best_k, best_r = nil, nil
        for k, r in pairs(plugins) do
            if type(r) == "table" and not conflictsWithQueryRepo(r) then
                local k_base = normalizeDirBase(k)
                local d_base = normalizeDirBase(r.dirname)
                local r_repo_base = normalizeDirBase(r.repo)
                local name_match = (k_base == repo_clean_lower)
                    or (d_base == repo_clean_lower)
                    or (type(r.repo) == "string" and (r.repo:lower() == repo_raw_lower or r_repo_base == repo_clean_lower))
                if name_match and isBetterRecordCandidate(k, r, best_k, best_r, repo_base_lower, core_plugins) then
                    best_k, best_r = k, r
                end
            end
        end
        if best_r then
            return buildReturnedRecord(best_r, best_k)
        end
    end

    return nil, nil
end

---@param dirname string|nil
---@param record table|nil
---@param dir_exists_fn fun(dir_name: string): boolean|nil
---@param core_plugins table|nil
---@return boolean
function InstallStore.removePluginRecordsForDeletion(dirname, record, dir_exists_fn, core_plugins)
    local data = readStore()
    local plugins = data.plugins
    if type(plugins) ~= "table" then
        InstallStore.bumpGeneration()
        return true
    end

    local target_bases = {}
    local function addTargetName(name)
        if type(name) == "string" and name ~= "" then
            local clean = name:gsub("%.koplugin$", "")
            target_bases[clean:lower()] = true
        end
    end

    addTargetName(dirname)
    if type(record) == "table" then
        addTargetName(record.dirname)
        addTargetName(record._store_key)
    end

    local target_repo_id = (type(record) == "table" and record.repo_id ~= nil and tostring(record.repo_id) ~= "")
        and tostring(record.repo_id) or nil
    local target_full_lower = (type(record) == "table") and extractRecordFullNameLower(record) or nil

    local keys_to_remove = {}
    for k, r in pairs(plugins) do
        local k_base = normalizeDirBase(k)
        local d_base = (type(r) == "table") and normalizeDirBase(r.dirname) or nil
        if (k_base and target_bases[k_base]) or (d_base and target_bases[d_base]) then
            keys_to_remove[k] = true
        elseif type(r) == "table" and (target_repo_id or target_full_lower) then
            local id_match = (target_repo_id ~= nil and r.repo_id ~= nil and tostring(r.repo_id) == target_repo_id)
            local full_match = (target_full_lower ~= nil and extractRecordFullNameLower(r) == target_full_lower)
            if id_match or full_match then
                local cand_dir = (type(r.dirname) == "string" and r.dirname ~= "" and r.dirname) or k
                local missing_on_disk = (type(dir_exists_fn) == "function") and (not dir_exists_fn(cand_dir)) or false
                local hijacked_core = isCorePluginDir(cand_dir, core_plugins)
                    and (normalizeDirBase(r.repo) ~= normalizeDirBase(cand_dir))
                if missing_on_disk or hijacked_core then
                    keys_to_remove[k] = true
                end
            end
        end
    end

    local removed_any = false
    for k in pairs(keys_to_remove) do
        plugins[k] = nil
        removed_any = true
    end

    if not removed_any then
        InstallStore.bumpGeneration()
        return true
    end
    return writeStore(data)
end

function InstallStore.getPatch(filename)
    if not filename or filename == "" then
        return nil
    end
    local data = readStore()
    return shallowCopyRecord(data.patches[filename])
end

function InstallStore.getFont(font_name)
    if not font_name or font_name == "" then
        return nil
    end
    local data = readStore()
    return shallowCopyRecord(data.fonts[font_name:lower()])
end

function InstallStore.clear()
    return writeStore({ plugins = {}, patches = {} })
end

function InstallStore.clearPatches()
    local data = readStore()
    data.patches = {}
    return writeStore(data)
end

function InstallStore.getItemOptions(item_key)
    if not item_key or item_key == "" then
        return { allow_prerelease = false, ignored_releases = {} }
    end
    item_key = item_key:lower()
    local data = readStore()
    local opts = (data.item_options and data.item_options[item_key]) or {}
    opts.ignored_releases = opts.ignored_releases or {}
    return opts
end

function InstallStore.setItemOptions(item_key, opts)
    if not item_key or item_key == "" then
        return false
    end
    item_key = item_key:lower()
    local data = readStore()
    data.item_options[item_key] = opts or {}
    return writeStore(data)
end

function InstallStore.isPreReleaseAllowed(item_key)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    if opts.allow_prerelease == true then return true end
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        opts = InstallStore.getItemOptions(clean_key)
        if opts.allow_prerelease == true then return true end
    end
    return false
end

function InstallStore.setPreReleaseAllowed(item_key, allowed)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.allow_prerelease = (allowed == true)
    InstallStore.setItemOptions(item_key, opts)
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        local clean_opts = InstallStore.getItemOptions(clean_key)
        clean_opts.allow_prerelease = (allowed == true)
        InstallStore.setItemOptions(clean_key, clean_opts)
    end
    return true
end

function InstallStore.isAllUpdatesIgnored(item_key)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    if opts.ignore_all_updates == true then return true end
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        opts = InstallStore.getItemOptions(clean_key)
        if opts.ignore_all_updates == true then return true end
    end
    return false
end

function InstallStore.setAllUpdatesIgnored(item_key, ignored)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.ignore_all_updates = (ignored == true)
    InstallStore.setItemOptions(item_key, opts)
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        local clean_opts = InstallStore.getItemOptions(clean_key)
        clean_opts.ignore_all_updates = (ignored == true)
        InstallStore.setItemOptions(clean_key, clean_opts)
    end
    return true
end

function InstallStore.toggleAllUpdatesIgnored(item_key)
    if not item_key or item_key == "" then return false end
    local current = InstallStore.isAllUpdatesIgnored(item_key)
    return InstallStore.setAllUpdatesIgnored(item_key, not current)
end

function InstallStore.isReleaseIgnored(item_key, tag_name)
    if not item_key or item_key == "" then return false end
    if InstallStore.isAllUpdatesIgnored(item_key) then return true end
    if not tag_name or tag_name == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    return opts.ignored_releases[tag_name] == true
end

function InstallStore.toggleReleaseIgnored(item_key, tag_name)
    if not tag_name or tag_name == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.ignored_releases[tag_name] = not (opts.ignored_releases[tag_name] == true)
    return InstallStore.setItemOptions(item_key, opts)
end

function InstallStore.isReleaseIgnoredByRepo(owner, repo_name, tag_name)
    if not owner or not repo_name then return false end
    local item_key = string.format("%s/%s", owner, repo_name)
    if InstallStore.isAllUpdatesIgnored(item_key) or InstallStore.isAllUpdatesIgnored(repo_name) then
        return true
    end
    if not tag_name or tag_name == "" then return false end
    return InstallStore.isReleaseIgnored(item_key, tag_name)
        or InstallStore.isReleaseIgnored(repo_name, tag_name)
end

function InstallStore.getPreferredAsset(item_key)
    if not item_key or item_key == "" then return nil end
    local opts = InstallStore.getItemOptions(item_key)
    return opts.preferred_asset
end

function InstallStore.setPreferredAsset(item_key, asset_name)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.preferred_asset = asset_name
    return InstallStore.setItemOptions(item_key, opts)
end

return InstallStore

