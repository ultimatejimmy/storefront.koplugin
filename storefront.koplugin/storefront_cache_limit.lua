---@class StorefrontCacheLimit
--- Centralized cache size and age boundary enforcement for Storefront.
--- Bounds local storage growth across READMEs, wikis, release notes, and screensaver thumbnails.

local logger = require("logger")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local StorefrontCacheLimit = {}

StorefrontCacheLimit.PRESETS_MB = { 25, 50, 100, 250, 500, 0 } -- 0 == Unlimited
StorefrontCacheLimit.DEFAULT_MB = 100
StorefrontCacheLimit.MAX_AGE_DAYS = 30
StorefrontCacheLimit.SETTING_KEY = "cache_limit_mb"
StorefrontCacheLimit.THROTTLE_SECS = 300

local _last_enforce_time = 0

--- Resets the enforcement throttle timestamp (primarily for tests).
function StorefrontCacheLimit.resetThrottle()
    _last_enforce_time = 0
end

--- Returns the active cache limit in megabytes (0 = Unlimited).
--- Falls back to DEFAULT_MB (100) if unset, non-numeric, or unrecognized.
---@return number
function StorefrontCacheLimit.getLimitMB()
    local ok_set, StorefrontSettings = pcall(require, "storefront_settings")
    if not (ok_set and StorefrontSettings and StorefrontSettings.readSetting) then
        return StorefrontCacheLimit.DEFAULT_MB
    end

    local val = StorefrontSettings:readSetting(StorefrontCacheLimit.SETTING_KEY, StorefrontCacheLimit.DEFAULT_MB)
    if type(val) ~= "number" then
        val = tonumber(val)
    end
    if not val or val < 0 then
        return StorefrontCacheLimit.DEFAULT_MB
    end

    local is_preset = false
    for _, preset in ipairs(StorefrontCacheLimit.PRESETS_MB) do
        if preset == val then
            is_preset = true
            break
        end
    end

    return is_preset and val or StorefrontCacheLimit.DEFAULT_MB
end

--- Saves the cache limit setting and triggers an immediate forced eviction check.
---@param mb number
---@return table { removed: number, bytes: number }
function StorefrontCacheLimit.setLimitMB(mb)
    if type(mb) ~= "number" then
        mb = tonumber(mb)
    end
    if not mb or mb < 0 then
        mb = StorefrontCacheLimit.DEFAULT_MB
    end

    local ok_set, StorefrontSettings = pcall(require, "storefront_settings")
    if ok_set and StorefrontSettings and StorefrontSettings.saveSetting then
        StorefrontSettings:saveSetting(StorefrontCacheLimit.SETTING_KEY, mb)
        if StorefrontSettings.flush then
            StorefrontSettings:flush()
        end
    end

    return StorefrontCacheLimit.enforce(true)
end

--- Calculates the next preset value in cyclic sequence.
---@param current_mb number
---@return number
function StorefrontCacheLimit.nextPreset(current_mb)
    local presets = StorefrontCacheLimit.PRESETS_MB
    for i, p in ipairs(presets) do
        if p == current_mb then
            local next_idx = (i % #presets) + 1
            return presets[next_idx]
        end
    end
    return StorefrontCacheLimit.DEFAULT_MB
end

--- Retrieves protected screensaver filenames and stems to preserve active screensavers.
---@return table<string, boolean>
function StorefrontCacheLimit.getProtectedIdentifiers()
    local protected = {}
    local ok_mgr, StorefrontScreensaverMgr = pcall(require, "storefront_screensaver_mgr")
    if ok_mgr and StorefrontScreensaverMgr and StorefrontScreensaverMgr.getActiveScreensaverIdentifiers then
        local ok_call, ids = pcall(StorefrontScreensaverMgr.getActiveScreensaverIdentifiers)
        if ok_call and type(ids) == "table" then
            for k, v in pairs(ids) do
                if v then
                    local k_lower = tostring(k):lower()
                    protected[k_lower] = true
                    local stem = k_lower:gsub("%..+$", "")
                    protected[stem] = true
                end
            end
        end
    end
    return protected
end

--- Returns the standard cache directory roots that are eligible for size & age eviction.
--- Excludes catalog metadata JSONs and ratings database files.
---@return string[]
function StorefrontCacheLimit.getCacheRoots()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp"
    return {
        data_dir .. "/cache/Storefront/readme",
        data_dir .. "/cache/Storefront/wiki",
        data_dir .. "/cache/Storefront/release_notes",
        data_dir .. "/cache/storefront_thumbs",
    }
end

--- Traverses cache directories and returns an inventory of all cached files.
---@param roots string[]
---@param protected_keys table<string, boolean>
---@return table[] list of { path: string, mtime: number, size: number, protected: boolean }
function StorefrontCacheLimit.collectFiles(roots, protected_keys)
    local items = {}
    if not (ok_lfs and lfs and lfs.attributes) then
        return items
    end

    protected_keys = protected_keys or {}

    for _, base_dir in ipairs(roots or {}) do
        local mode = lfs.attributes(base_dir, "mode")
        if mode == "directory" then
            local is_thumbs = base_dir:find("storefront_thumbs", 1, true) ~= nil
            local function scan(dir)
                for entry in lfs.dir(dir) do
                    if entry ~= "." and entry ~= ".." then
                        local full = dir .. "/" .. entry
                        local attr = lfs.attributes(full)
                        if attr then
                            if attr.mode == "file" then
                                local is_prot = false
                                if is_thumbs then
                                    local entry_lower = entry:lower()
                                    local entry_stem = entry_lower:gsub("%..+$", "")
                                    if protected_keys[entry_lower] or protected_keys[entry_stem] then
                                        is_prot = true
                                    end
                                end
                                table.insert(items, {
                                    path = full,
                                    mtime = attr.modification or 0,
                                    size = attr.size or 0,
                                    protected = is_prot,
                                })
                            elseif attr.mode == "directory" then
                                scan(full)
                            end
                        end
                    end
                end
            end
            scan(base_dir)
        end
    end

    return items
end

--- Recursively removes empty subdirectories inside cache roots (preserving roots themselves).
---@param roots string[]
function StorefrontCacheLimit.pruneEmptyDirs(roots)
    if not (ok_lfs and lfs and lfs.attributes and lfs.rmdir) then
        return
    end

    for _, root_dir in ipairs(roots or {}) do
        if lfs.attributes(root_dir, "mode") == "directory" then
            local function prune(dir)
                local has_sub = false
                for entry in lfs.dir(dir) do
                    if entry ~= "." and entry ~= ".." then
                        local full = dir .. "/" .. entry
                        if lfs.attributes(full, "mode") == "directory" then
                            prune(full)
                            local check_empty = true
                            for sub in lfs.dir(full) do
                                if sub ~= "." and sub ~= ".." then
                                    check_empty = false
                                    break
                                end
                            end
                            if check_empty and full ~= root_dir then
                                pcall(lfs.rmdir, full)
                            else
                                has_sub = true
                            end
                        else
                            has_sub = true
                        end
                    end
                end
                return has_sub
            end
            prune(root_dir)
        end
    end
end

--- Enforces the cache limits across all Storefront cache roots.
--- 1. Deletes files exceeding max age (30 days), skipping protected active screensavers.
--- 2. If total size exceeds the configured limit, deletes oldest non-protected files first.
---@param force boolean|nil If true, bypasses the 5-minute throttle
---@param override_mb number|nil Optional limit in MB (e.g. for testing)
---@param override_age number|nil Optional max age in days (e.g. for testing)
---@return table { removed: number, bytes: number, total_remaining: number, throttled: boolean|nil }
function StorefrontCacheLimit.enforce(force, override_mb, override_age)
    local now = os.time()
    if not force and _last_enforce_time > 0 and (now - _last_enforce_time < StorefrontCacheLimit.THROTTLE_SECS) then
        return {
            removed = 0,
            bytes = 0,
            throttled = true,
        }
    end
    _last_enforce_time = now

    local limit_mb = override_mb or StorefrontCacheLimit.getLimitMB()
    local max_age_days = override_age or StorefrontCacheLimit.MAX_AGE_DAYS
    local max_age_secs = max_age_days * 86400
    local max_bytes = (limit_mb and limit_mb > 0) and (limit_mb * 1024 * 1024) or 0

    local roots = StorefrontCacheLimit.getCacheRoots()
    local protected_keys = StorefrontCacheLimit.getProtectedIdentifiers()
    local files = StorefrontCacheLimit.collectFiles(roots, protected_keys)

    local removed_count = 0
    local freed_bytes = 0
    local remaining = {}
    local total_size = 0
    local protected_size = 0

    -- Phase 1: Expiry by age (skipping protected files)
    for _, f in ipairs(files) do
        local age = now - f.mtime
        if not f.protected and max_age_secs > 0 and age > max_age_secs then
            if os.remove(f.path) then
                removed_count = removed_count + 1
                freed_bytes = freed_bytes + f.size
            end
        else
            table.insert(remaining, f)
            total_size = total_size + f.size
            if f.protected then
                protected_size = protected_size + f.size
            end
        end
    end

    -- Phase 2: Expiry by total size (oldest first, skipping protected files)
    if max_bytes > 0 and total_size > max_bytes then
        if protected_size > max_bytes then
            local warn_msg = string.format(
                "Storefront: protected screensaver thumbnails (%d KB) exceed cache limit (%d KB)",
                math.ceil(protected_size / 1024),
                math.ceil(max_bytes / 1024)
            )
            local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
            if ok_log and StorefrontLogger and StorefrontLogger.warn then
                StorefrontLogger.warn(warn_msg)
            else
                logger.warn(warn_msg)
            end
        end

        local to_evict = {}
        for _, f in ipairs(remaining) do
            if not f.protected then
                table.insert(to_evict, f)
            end
        end

        table.sort(to_evict, function(a, b)
            return a.mtime < b.mtime
        end)

        for _, f in ipairs(to_evict) do
            if total_size <= max_bytes then
                break
            end
            if os.remove(f.path) then
                total_size = total_size - f.size
                removed_count = removed_count + 1
                freed_bytes = freed_bytes + f.size
            end
        end
    end

    -- Phase 3: Prune empty subdirectories
    StorefrontCacheLimit.pruneEmptyDirs(roots)

    return {
        removed = removed_count,
        bytes = freed_bytes,
        total_remaining = total_size,
    }
end

return StorefrontCacheLimit
