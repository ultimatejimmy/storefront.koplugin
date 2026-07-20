local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local json = require("json")
local logger = require("logger")

local Cache = {}

local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "cache/Storefront")
local PLUGINS_FILE = ffiUtil.joinPath(DB_DIRECTORY, "storefront_plugins.json")
local PATCHES_FILE = ffiUtil.joinPath(DB_DIRECTORY, "storefront_patches.json")

local _loaded = false
local _data = {
    plugin = { fetched_at = 0, repos = {} },
    patch = { fetched_at = 0, repos = {} },
}

local _by_id = {}
local _by_name = {}

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("Storefront cache directory creation failed", err)
    end
end

local function writeJsonFile(filepath, data)
    ensureDirectory()
    local ok, serialized = pcall(json.encode, data)
    if not ok then
        logger.err("Storefront: failed to serialize cache", serialized)
        return false
    end
    local temp_path = filepath .. ".tmp"
    local file, err = io.open(temp_path, "w")
    if not file then
        logger.err("Storefront: failed to open temp cache file for writing", err)
        return false
    end
    file:write(serialized)
    file:close()
    
    local ok_rename, rename_err = os.rename(temp_path, filepath)
    if not ok_rename then
        logger.err("Storefront: failed to rename cache file", rename_err)
        os.remove(temp_path)
        return false
    end
    return true
end

local function readJsonFile(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then
        return nil
    end
    local ok, decoded = pcall(json.decode, content)
    if not ok then
        logger.err("Storefront: failed to decode cache file", decoded)
        return nil
    end
    return decoded
end

function Cache.init()
    if _loaded then
        return
    end
    ensureDirectory()
    local plugins_data = readJsonFile(PLUGINS_FILE)
    if plugins_data then
        _data.plugin = plugins_data
    end
    local patches_data = readJsonFile(PATCHES_FILE)
    if patches_data then
        _data.patch = patches_data
    end
    
    _by_id = {}
    _by_name = {}
    
    local function indexRepos(repos)
        for _, repo in ipairs(repos) do
            if repo.repo_id then
                _by_id[repo.repo_id] = repo
            end
            if repo.owner and repo.name then
                local key = string.format("%s/%s", repo.owner:lower(), repo.name:lower())
                _by_name[key] = repo
            end
        end
    end
    
    if _data.plugin and _data.plugin.repos then
        indexRepos(_data.plugin.repos)
    end
    if _data.patch and _data.patch.repos then
        indexRepos(_data.patch.repos)
    end
    
    _loaded = true
end

function Cache.storeRepos(kind, repos)
    if not kind or type(repos) ~= "table" then return end
    Cache.init()
    
    local fetched_at = os.time()
    local list = {}
    
    local existing_patches = {}
    if kind == "patch" and _data.patch and _data.patch.repos then
        for _, r in ipairs(_data.patch.repos) do
            if r.repo_id and r.patch_files then
                existing_patches[r.repo_id] = r.patch_files
            end
        end
    end
    
    local function getOwnerLogin(owner)
        if type(owner) == "table" and owner.login then
            return tostring(owner.login)
        end
        return ""
    end
    
    for _, repo in ipairs(repos) do
        local owner_login = getOwnerLogin(repo.owner)
        local repo_id = tonumber(repo.id) or 0
        local record = {
            repo_id = repo_id,
            kind = kind,
            name = tostring(repo.name or ""),
            owner = owner_login,
            full_name = tostring(repo.full_name or ""),
            description = repo.description ~= json.null and tostring(repo.description or "") or "",
            stars = tonumber(repo.stargazers_count) or 0,
            language = repo.language ~= json.null and tostring(repo.language or "") or "",
            homepage = repo.homepage ~= json.null and tostring(repo.homepage or "") or "",
            fetched_at = fetched_at,
            data = repo,
        }
        if kind == "patch" then
            record.patch_files = existing_patches[repo_id] or {}
        end
        table.insert(list, record)
    end
    
    _data[kind] = {
        fetched_at = fetched_at,
        repos = list,
    }
    
    local file_path = kind == "plugin" and PLUGINS_FILE or PATCHES_FILE
    writeJsonFile(file_path, _data[kind])
    
    _loaded = false
    Cache.init()
end

function Cache.listRepos(kind)
    kind = kind or "plugin"
    Cache.init()
    local repos = _data[kind] and _data[kind].repos or {}
    local copy = {}
    for _, r in ipairs(repos) do
        table.insert(copy, r)
    end
    table.sort(copy, function(a, b)
        if (a.stars or 0) ~= (b.stars or 0) then
            return (a.stars or 0) > (b.stars or 0)
        end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return copy
end

function Cache.getRepo(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then return nil end
    Cache.init()
    return _by_id[repo_id]
end

function Cache.getRepoByName(owner, name)
    if not owner or not name then return nil end
    Cache.init()
    local key = string.format("%s/%s", owner:lower(), name:lower())
    return _by_name[key]
end

function Cache.getLastFetched(kind)
    kind = kind or "plugin"
    Cache.init()
    return _data[kind] and _data[kind].fetched_at or 0
end

function Cache.countRepos(kind)
    kind = kind or "plugin"
    Cache.init()
    return _data[kind] and _data[kind].repos and #_data[kind].repos or 0
end

function Cache.storePatchFiles(repo_id, entries, source_pushed_at)
    repo_id = tonumber(repo_id)
    if not repo_id then return end
    Cache.init()
    
    local repo = _by_id[repo_id]
    if not repo then
        return
    end
    
    local fetched_at = os.time()
    local patch_files = {}
    if entries then
        for _, entry in ipairs(entries) do
            table.insert(patch_files, {
                path = tostring(entry.path or ""),
                filename = tostring(entry.filename or ""),
                branch = tostring(entry.branch or ""),
                sha = tostring(entry.sha or ""),
                size = tonumber(entry.size) or 0,
                download_url = tostring(entry.download_url or ""),
                fetched_at = fetched_at,
                source_pushed_at = tostring(source_pushed_at or ""),
            })
        end
    end
    repo.patch_files = patch_files
    writeJsonFile(PATCHES_FILE, _data.patch)
end

function Cache.getPatchFilePushedAt(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then return nil end
    Cache.init()
    local repo = _by_id[repo_id]
    if not repo or not repo.patch_files or #repo.patch_files == 0 then
        return nil
    end
    local val = repo.patch_files[1].source_pushed_at
    if val == "" or val == nil then return nil end
    return val
end

function Cache.countPatchFiles(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then return 0 end
    Cache.init()
    local repo = _by_id[repo_id]
    return repo and repo.patch_files and #repo.patch_files or 0
end

function Cache.listPatchFiles(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then return {} end
    Cache.init()
    local repo = _by_id[repo_id]
    if not repo or not repo.patch_files then
        return {}
    end
    local copy = {}
    for _, file in ipairs(repo.patch_files) do
        table.insert(copy, file)
    end
    table.sort(copy, function(a, b)
        return tostring(a.filename):lower() < tostring(b.filename):lower()
    end)
    return copy
end

function Cache.pruneOrphanPatchFiles(valid_repo_ids)
    valid_repo_ids = valid_repo_ids or {}
    local lookup = {}
    for _, id in ipairs(valid_repo_ids) do
        local numeric = tonumber(id)
        if numeric then
            lookup[numeric] = true
        end
    end
    Cache.init()
    
    local changed = false
    for _, repo in ipairs(_data.patch.repos) do
        if repo.repo_id and not lookup[repo.repo_id] then
            if repo.patch_files and #repo.patch_files > 0 then
                repo.patch_files = {}
                changed = true
            end
        end
    end
    if changed then
        writeJsonFile(PATCHES_FILE, _data.patch)
    end
end

function Cache.clearPatchFiles(kind)
    if kind == "plugin" then return end
    Cache.init()
    local changed = false
    for _, repo in ipairs(_data.patch.repos) do
        if repo.patch_files and #repo.patch_files > 0 then
            repo.patch_files = {}
            changed = true
        end
    end
    if changed then
        writeJsonFile(PATCHES_FILE, _data.patch)
    end
end

function Cache.findPatchRepoAndFile(filename)
    if not filename or filename == "" then return nil, nil end
    Cache.init()
    local best_repo, best_file
    for _, repo in ipairs(_data.patch.repos) do
        if repo.patch_files then
            for _, file in ipairs(repo.patch_files) do
                if file.filename == filename then
                    if not best_repo or (repo.stars or 0) > (best_repo.stars or 0) then
                        best_repo = repo
                        best_file = file
                    end
                end
            end
        end
    end
    if best_repo then
        local file_map = {
            path = best_file.path,
            branch = best_file.branch,
            sha = best_file.sha,
            download_url = best_file.download_url,
        }
        return best_repo, file_map
    end
    return nil, nil
end

function Cache.clear()
    _data = {
        plugin = { fetched_at = 0, repos = {} },
        patch = { fetched_at = 0, repos = {} },
    }
    _by_id = {}
    _by_name = {}
    os.remove(PLUGINS_FILE)
    os.remove(PATCHES_FILE)
end

return Cache
