--- Storefront Ratings Module
--- Manages anonymous device identification, local vote persistence, Wilson score ranking,
--- and background dispatch of votes to GitHub.
---
--- @module StorefrontRatings

local _ = require("gettext")
local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ok_su, socketutil = pcall(require, "socketutil")
if not ok_su or not socketutil then
    socketutil = {
        FILE_BLOCK_TIMEOUT = 15,
        FILE_TOTAL_TIMEOUT = 30,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end

local function getHttpModule(url)
    return require("socket.http")
end

local StorefrontSettings = require("storefront_settings")

local UUID_KEY = "device_uuid"
local VOTES_KEY = "user_votes"
local RATINGS_CACHE_FILE = DataStorage:getSettingsDir() .. "/storefront_ratings_cache.json"
local VOTES_BACKUP_FILE = DataStorage:getSettingsDir() .. "/storefront_votes_backup.json"
local CANONICAL_STOREFRONT_ID = "1304319884"

local STOREFRONT_LEGACY_ALIASES = {
    ["storefront"] = true,
    ["storefront.koplugin"] = true,
    ["1304319884.koplugin"] = true,
    ["ultimatejimmy/storefront"] = true,
    ["ultimatejimmy/storefront.koplugin"] = true,
}

local function cleanupLegacyCacheFile()
    pcall(os.remove, RATINGS_CACHE_FILE)
    pcall(os.remove, RATINGS_CACHE_FILE .. ".tmp")
end

cleanupLegacyCacheFile()

local function loadVotesBackupFile()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(VOTES_BACKUP_FILE, "mode") == "file" then
        local f = io.open(VOTES_BACKUP_FILE, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local ok_j, parsed = pcall(json.decode, content)
                if ok_j and type(parsed) == "table" then
                    return parsed
                end
            end
        end
    end
    return nil
end

local function saveVotesBackupFile(votes_table)
    if type(votes_table) == "table" then
        pcall(function()
            local ok_j, content = pcall(json.encode, votes_table)
            if ok_j and content and content ~= "" then
                local f = io.open(VOTES_BACKUP_FILE, "w")
                if f then
                    f:write(content)
                    f:close()
                end
            end
        end)
    end
end

local StorefrontRatings = {
    liveRatings = {}, -- Retired persistent cache; kept empty for backwards-compatibility
    BASE_URL = "https://storefront-vote.ultimatejimmy.workers.dev",
}

local user_votes_cache = nil
local _session_downloads = {}

local function loadVotesCache()
    if not user_votes_cache then
        local votes = StorefrontSettings:readSetting(VOTES_KEY)
        if type(votes) ~= "table" or next(votes) == nil then
            votes = loadVotesBackupFile()
        end
        if type(votes) == "table" then
            user_votes_cache = {}
            local migrated = false
            for k, v in pairs(votes) do
                local str_k = tostring(k)
                local lower_k = str_k:lower()

                -- Consolidate legacy Storefront aliases and integer key [1304319884] onto "1304319884"
                if STOREFRONT_LEGACY_ALIASES[lower_k] or type(k) == "number" then
                    local target_k = STOREFRONT_LEGACY_ALIASES[lower_k] and CANONICAL_STOREFRONT_ID or str_k
                    if user_votes_cache[target_k] == nil or type(v) == "table" then
                        user_votes_cache[target_k] = v
                    end
                    if target_k ~= str_k or type(k) == "number" then
                        migrated = true
                    end
                elseif not str_k:find("/") and not str_k:match("^%d+$") and type(v) == "table" then
                    -- Detect legacy bare keys (no '/' and not numeric) and migrate them if matched
                    local ok_inst, InstallStore = pcall(require, "storefront_installs")
                    local resolved = false
                    if ok_inst and InstallStore and InstallStore.list then
                        local installs = InstallStore.list() or {}
                        local rec = installs[str_k] or installs[str_k .. ".koplugin"] or installs[str_k:gsub("%.koplugin$", "")]
                        if rec and rec.owner and rec.owner ~= "" then
                            local name = rec.repo or str_k
                            local auth_key = rec.owner .. "/" .. name
                            user_votes_cache[auth_key] = v
                            user_votes_cache[auth_key:lower()] = v
                            if rec.repo_id then
                                user_votes_cache[tostring(rec.repo_id)] = v
                            end
                            migrated = true
                            resolved = true
                        end
                    end
                    if not resolved then
                        user_votes_cache[str_k] = v
                    end
                else
                    user_votes_cache[str_k] = v
                end
            end
            if migrated then
                pcall(function()
                    StorefrontSettings:saveSetting(VOTES_KEY, user_votes_cache)
                    StorefrontSettings:flush()
                end)
                saveVotesBackupFile(user_votes_cache)
            end
        else
            user_votes_cache = {}
        end
    end
    return user_votes_cache
end

--- Returns file count and total size in bytes of the legacy local ratings cache file (if present).
--- @return table { files = number, bytes = number }
function StorefrontRatings.getCacheStats()
    local f = io.open(RATINGS_CACHE_FILE, "r")
    if f then
        local content = f:read("*a")
        local sz = content and #content or 0
        f:close()
        return { files = 1, bytes = sz }
    end

    return { files = 0, bytes = 0 }
end

--- Deletes any leftover local ratings cache file and resets in-session deltas.
--- @return table { removed = number, bytes = number }
function StorefrontRatings.clearCache()
    local stats = StorefrontRatings.getCacheStats()
    local freed_bytes = stats.bytes or 0
    local removed = 0

    cleanupLegacyCacheFile()
    StorefrontRatings.liveRatings = {}
    _session_downloads = {}

    local check_stats = StorefrontRatings.getCacheStats()
    if check_stats.files == 0 then
        removed = stats.files
    end

    return { removed = removed, bytes = freed_bytes }
end

local function terminateAndCleanupSubProcess(pid, parent_read_fd)
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end
    if ok_ffi and ffiutil then
        if pid and ffiutil.terminateSubProcess then
            pcall(ffiutil.terminateSubProcess, pid)
            if ffiutil.isSubProcessDone then
                pcall(ffiutil.isSubProcessDone, pid, true)
            end
        end
        if parent_read_fd then
            local read_func = ffiutil.readAllFromFD or ffiutil.readFromFD
            if read_func then pcall(read_func, parent_read_fd) end
        end
    end
end

StorefrontRatings._active_requests = {}

local function trackActiveRequest(pid, fd)
    local req = { pid = pid, fd = fd, poll_fn = nil }
    table.insert(StorefrontRatings._active_requests, req)
    return req
end

local function untrackActiveRequest(req)
    if not req then return end
    for idx, r in ipairs(StorefrontRatings._active_requests or {}) do
        if r == req or (req.pid and r.pid == req.pid) then
            table.remove(StorefrontRatings._active_requests, idx)
            break
        end
    end
end

function StorefrontRatings.cancelPendingRequests()
    local UIManager = require("ui/uimanager")
    for _, req in ipairs(StorefrontRatings._active_requests or {}) do
        if req.poll_fn then
            pcall(UIManager.unschedule, UIManager, req.poll_fn)
        end
        terminateAndCleanupSubProcess(req.pid, req.fd)
    end
    StorefrontRatings._active_requests = {}
end

--- Deprecated no-op: ratings are now sourced from catalog.json without bulk /ratings fetches.
--- Retained as a compatibility shim so any legacy caller receives an immediate callback.
function StorefrontRatings.fetchRatings(callback, _force_refresh)
    if callback then
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end)
    end
end

local function getCandidateKeys(item_or_id)
    if type(item_or_id) == "table" and item_or_id._candidate_keys then
        return item_or_id._candidate_keys
    end
    local keys = {}
    local seen = {}

    local function add_single(s)
        if s == nil then return end
        local str_s = tostring(s)
        if str_s == "" then return end
        if not seen[str_s] then
            seen[str_s] = true
            table.insert(keys, str_s)
        end
    end

    local function add_key_variants(k)
        if k == nil or k == "" then return end
        local str_k = tostring(k)
        if str_k == "" then return end

        add_single(str_k)
        add_single(str_k:lower())

        -- Handle .koplugin suffix variations if present
        if str_k:sub(-9) == ".koplugin" then
            local base = str_k:sub(1, -10)
            add_single(base)
            add_single(base:lower())
        end

        -- Handle .disabled suffix variations for patches
        if str_k:sub(-9) == ".disabled" then
            local base = str_k:sub(1, -10)
            add_single(base)
            add_single(base:lower())
        end
    end

    if type(item_or_id) ~= "table" then
        local val = tostring(item_or_id or "")
        if val ~= "" then
            local val_lower = val:lower()
            if STOREFRONT_LEGACY_ALIASES[val_lower] or val_lower == CANONICAL_STOREFRONT_ID then
                add_key_variants(CANONICAL_STOREFRONT_ID)
            else
                add_key_variants(val)
            end
            if not val:find("/") and not val:match("^%d+$") and not STOREFRONT_LEGACY_ALIASES[val_lower] then
                local ok_inst, InstallStore = pcall(require, "storefront_installs")
                if ok_inst and InstallStore and InstallStore.list then
                    local installs = InstallStore.list() or {}
                    local rec = installs[val] or installs[val .. ".koplugin"] or installs[val:gsub("%.koplugin$", "")]
                    if rec and rec.owner and rec.owner ~= "" then
                        item_or_id = { owner = rec.owner, name = val, id = rec.repo_id or rec.id, repo_full_name = rec.repo_full_name }
                    end
                end
            end
        end
    end

    if type(item_or_id) ~= "table" then
        return keys
    end

    local item = item_or_id

    local primary_id = item.id
        or item.repo_id
        or (item.repo and (item.repo.repo_id or item.repo.id))
        or (item.record and (item.record.repo_id or item.record.id))
        or (item.plugin and item.plugin.id)

    local owner = item.owner
        or (type(item.full_name) == "string" and item.full_name:match("^([^/]+)/"))
        or (type(item.repo_full_name) == "string" and item.repo_full_name:match("^([^/]+)/"))
        or (item.repo and (type(item.repo.owner) == "string" and item.repo.owner or (type(item.repo.owner) == "table" and (item.repo.owner.login or item.repo.owner.name))))
        or (item.record and (item.record.owner or (type(item.record.repo_full_name) == "string" and item.record.repo_full_name:match("^([^/]+)/"))))
        or (item.plugin and item.plugin.owner)

    if type(owner) == "table" then owner = owner.login or owner.name end

    local name = item.name
        or item.dirname
        or (type(item.full_name) == "string" and item.full_name:match("^[^/]+/(.+)$"))
        or (type(item.repo_full_name) == "string" and item.repo_full_name:match("^[^/]+/(.+)$"))
        or (item.repo and item.repo.name)
        or (item.record and (item.record.name or item.record.repo))
        or (item.plugin and (item.plugin.dirname or item.plugin.name))
        or (item.patch and item.patch.filename)

    local item_name = tostring(item.name or ""):lower()
    local item_dirname = tostring(item.dirname or ""):lower()
    local item_full_name = tostring(item.full_name or item.repo_full_name or ""):lower()
    local owner_lower = type(owner) == "string" and owner:lower() or ""
    local has_conflicting_owner = (owner_lower ~= "" and owner_lower ~= "ultimatejimmy")

    if not primary_id and (
        item_full_name == "ultimatejimmy/storefront"
        or item_full_name == "ultimatejimmy/storefront.koplugin"
        or (not has_conflicting_owner and (
            item_name == "storefront" or item_name == "storefront.koplugin"
            or item_dirname == "storefront" or item_dirname == "storefront.koplugin"
        ))
    ) then
        primary_id = tonumber(CANONICAL_STOREFRONT_ID)
    end

    if primary_id then
        add_key_variants(primary_id)
    end

    local has_scoped = (primary_id ~= nil)
    if owner and type(owner) == "string" and owner ~= "" and name and type(name) == "string" and name ~= "" then
        has_scoped = true
        add_key_variants(owner .. "/" .. name)
        local clean_name = name:gsub("%.koplugin$", "")
        add_key_variants(owner .. "/" .. clean_name)
    end

    add_key_variants(item.full_name)
    if type(item.full_name) == "string" and item.full_name:find("/") then
        has_scoped = true
    end

    -- Only emit bare name/dirname keys when no canonical repo_id or owner/name scope exists
    if not has_scoped then
        add_key_variants(name)
        add_key_variants(item.dirname)
        add_key_variants(item.filename)
        add_key_variants(item.font_name)
    end

    if type(item_or_id) == "table" then
        item_or_id._candidate_keys = keys
    end

    return keys
end

local function getCatalogTimestamp()
    local ok_cache, Cache = pcall(require, "storefront_cache")
    if ok_cache and Cache and Cache.getGeneratedTimestamp then
        return tonumber(Cache.getGeneratedTimestamp()) or 0
    end
    return 0
end

local function extractBaseFields(t)
    if type(t) ~= "table" then return nil end
    local up = tonumber(t.user_thumbs_up or (t.data and t.data.user_thumbs_up) or (t.repo and t.repo.user_thumbs_up) or (t.plugin and t.plugin.user_thumbs_up) or (t.record and t.record.user_thumbs_up) or t.user_thumbs_up_base or t.likes)
    local down = tonumber(t.user_thumbs_down or (t.data and t.data.user_thumbs_down) or (t.repo and t.repo.user_thumbs_down) or (t.plugin and t.plugin.user_thumbs_down) or (t.record and t.record.user_thumbs_down) or t.user_thumbs_down_base)
    local wilson = tonumber(t.wilson_score or (t.data and t.data.wilson_score) or (t.repo and t.repo.wilson_score) or t.wilson)
    local downloads = tonumber(t.downloads or (t.data and t.data.downloads) or t.download_count or t.downloads_count or (t.repo and (t.repo.downloads or t.repo.download_count)) or t.installs)
    return up, down, wilson, downloads
end

local function resolveCatalogBase(item_or_id, entry)
    local e = type(entry) == "table" and entry or (type(item_or_id) == "table" and item_or_id or nil)
    local base_up, base_down, wilson, base_downloads = extractBaseFields(e)

    if base_up == nil and base_down == nil and base_downloads == nil then
        local ok_cache, Cache = pcall(require, "storefront_cache")
        if ok_cache and Cache and (not Cache.isLoaded or Cache.isLoaded()) then
            local candidate_keys = getCandidateKeys(item_or_id)
            local cached_repo = nil
            for _, k in ipairs(candidate_keys) do
                if k:match("^%d+$") and Cache.getRepo then
                    cached_repo = Cache.getRepo(tonumber(k))
                elseif k:find("/") and Cache.getRepoByName then
                    local o, n = k:match("^([^/]+)/(.+)$")
                    if o and n then cached_repo = Cache.getRepoByName(o, n) end
                end
                if cached_repo then break end
            end
            if cached_repo then
                base_up, base_down, wilson, base_downloads = extractBaseFields(cached_repo)
            end
        end
    end

    return base_up or 0, base_down or 0, wilson or 0, base_downloads or 0
end

local function clearPendingDeltaOnRecord(item_or_id)
    local votes = loadVotesCache()
    local candidate_keys = getCandidateKeys(item_or_id)
    local changed = false
    for _, key in ipairs(candidate_keys) do
        local num_k = tonumber(key)
        local rec = votes[key] or (num_k and votes[num_k])
        if type(rec) == "table" and ((rec.pending_delta_up or 0) ~= 0 or (rec.pending_delta_down or 0) ~= 0) then
            rec.pending_delta_up = 0
            rec.pending_delta_down = 0
            if rec.direction == "none" then
                votes[key] = nil
                if num_k then votes[num_k] = nil end
            end
            changed = true
        end
    end
    if changed then
        user_votes_cache = votes
        pcall(function()
            StorefrontSettings:saveSetting(VOTES_KEY, votes)
            StorefrontSettings:flush()
        end)
        saveVotesBackupFile(votes)
    end
end

--- Gets the rating summary for an item or repo ID from catalog baseline + pending local vote delta.
--- @param item_or_id table|number|string
--- @param entry table|nil
--- @return table { up = number, down = number, wilson = number, downloads = number }
function StorefrontRatings.getRating(item_or_id, entry)
    local base_up, base_down, wilson, base_downloads = resolveCatalogBase(item_or_id, entry)
    local candidate_keys = getCandidateKeys(item_or_id)
    local primary_key = candidate_keys[1] or tostring(item_or_id or "")

    local final_up = base_up
    local final_down = base_down

    local rec = StorefrontRatings.getUserVoteRecord(item_or_id)
    if rec and ((tonumber(rec.pending_delta_up) or 0) ~= 0 or (tonumber(rec.pending_delta_down) or 0) ~= 0) then
        local cur_catalog_ts = getCatalogTimestamp()
        local vote_catalog_ts = tonumber(rec.catalog_ts_at_vote) or 0
        local expired = false
        if vote_catalog_ts > 0 and cur_catalog_ts > vote_catalog_ts then
            expired = true
        elseif vote_catalog_ts == 0 and (base_up ~= (tonumber(rec.catalog_up_at_vote) or base_up) or base_down ~= (tonumber(rec.catalog_down_at_vote) or base_down)) then
            expired = true
        end

        if expired then
            clearPendingDeltaOnRecord(item_or_id)
        else
            final_up = math.max(0, base_up + (tonumber(rec.pending_delta_up) or 0))
            final_down = math.max(0, base_down + (tonumber(rec.pending_delta_down) or 0))
            wilson = StorefrontRatings.computeWilsonScore(final_up, final_down)
        end
    elseif wilson == 0 and (final_up > 0 or final_down > 0) then
        wilson = StorefrontRatings.computeWilsonScore(final_up, final_down)
    end

    local session_dl = _session_downloads[primary_key] or 0

    return {
        up = final_up,
        down = final_down,
        wilson = wilson,
        downloads = base_downloads + session_dl,
    }
end

--- Gets the total download count for an item.
--- @param item_or_id table|number|string
--- @param entry table|nil
--- @return number
function StorefrontRatings.getDownloads(item_or_id, entry)
    local r = StorefrontRatings.getRating(item_or_id, entry)
    return (r and r.downloads) or 0
end

--- Returns (or generates and saves) a persistent anonymous UUID for this device.
--- @return string
function StorefrontRatings.getDeviceUUID()
    local saved = StorefrontSettings:readSetting(UUID_KEY)
    if type(saved) == "string" and #saved >= 16 then
        return saved
    end

    -- Generate a pseudo-random UUID v4 string in Lua 5.1
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    math.randomseed(os.time() + os.clock() * 1000)
    local uuid = string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end)

    StorefrontSettings:saveSetting(UUID_KEY, uuid)
    StorefrontSettings:flush()
    return uuid
end

--- Gets the full vote record for an item or repository ID.
--- @param item_or_id table|number|string
--- @return table|nil { direction = string, catalog_up_at_vote = number, catalog_down_at_vote = number }
function StorefrontRatings.getUserVoteRecord(item_or_id)
    if not item_or_id then return nil end
    local votes = loadVotesCache()
    local candidate_keys = getCandidateKeys(item_or_id)
    for _, key in ipairs(candidate_keys) do
        local num_k = tonumber(key)
        local rec = votes[key] or (num_k and votes[num_k])
        if type(rec) == "table" and rec.direction then
            return rec
        elseif type(rec) == "string" then
            return { direction = rec, catalog_up_at_vote = 0, catalog_down_at_vote = 0 }
        end
    end
    return nil
end

--- Gets the user's local vote direction for a given item or repository ID.
--- @param item_or_id table|number|string
--- @return string|nil "up", "down", or nil
function StorefrontRatings.getUserVote(item_or_id)
    local rec = StorefrontRatings.getUserVoteRecord(item_or_id)
    if rec and rec.direction and rec.direction ~= "none" then
        return rec.direction
    end
    return nil
end

--- Saves the user's local vote for a given item or repository ID.
--- @param item_or_id table|number|string
--- @param direction string|nil "up", "down", or "none"/nil
--- @param catalog_up number|nil
--- @param catalog_down number|nil
--- @param delta_info table|nil
function StorefrontRatings.saveUserVote(item_or_id, direction, catalog_up, catalog_down, delta_info)
    if not item_or_id then return end
    local votes = loadVotesCache()
    local candidate_keys = getCandidateKeys(item_or_id)
    if #candidate_keys == 0 then return end

    local pending_up = delta_info and tonumber(delta_info.pending_delta_up) or 0
    local pending_down = delta_info and tonumber(delta_info.pending_delta_down) or 0
    local vote_rec = nil
    if direction == "up" or direction == "down" or pending_up ~= 0 or pending_down ~= 0 then
        vote_rec = {
            direction = (direction == "up" or direction == "down") and direction or "none",
            catalog_up_at_vote = tonumber(catalog_up) or 0,
            catalog_down_at_vote = tonumber(catalog_down) or 0,
            pending_delta_up = pending_up,
            pending_delta_down = pending_down,
            catalog_ts_at_vote = delta_info and tonumber(delta_info.catalog_ts_at_vote) or 0,
        }
    end

    -- Check if we have scoped keys (numeric ID or owner/name)
    local has_scoped = false
    for _, key in ipairs(candidate_keys) do
        if key:find("/") or key:match("^%d+$") then
            has_scoped = true
            break
        end
    end

    for _, key in ipairs(candidate_keys) do
        if not has_scoped or key:find("/") or key:match("^%d+$") then
            votes[key] = vote_rec
            local num_k = tonumber(key)
            if num_k then
                votes[num_k] = nil
            end
        end
    end

    user_votes_cache = votes
    pcall(function()
        StorefrontSettings:saveSetting(VOTES_KEY, votes)
        StorefrontSettings:flush()
    end)
    saveVotesBackupFile(votes)
end

--- Computes the lower bound of Wilson score confidence interval for a 95% confidence level.
--- Used to sort items by rating in a statistically fair manner.
--- @param up number Thumbs up count
--- @param down number Thumbs down count
--- @return number Wilson score (0.0 to 1.0)
function StorefrontRatings.computeWilsonScore(up, down)
    up = tonumber(up) or 0
    down = tonumber(down) or 0
    local n = up + down
    if n == 0 then return 0 end

    -- z = 1.96 for 95% confidence interval
    local z = 1.96
    local phat = up / n
    local z2 = z * z
    local score = (phat + z2 / (2 * n) - z * math.sqrt((phat * (1 - phat) + z2 / (4 * n)) / n)) / (1 + z2 / n)
    return math.max(0, score)
end

--- Dispatches a user vote to the Cloudflare D1 backend in the background.
--- @param item_or_id table|number|string
--- @param direction string "up", "down", or "none"
--- @param item_kind string|nil "plugin", "patch", or "font"
--- @param callback function|nil Called with (success, error_message)
function StorefrontRatings.submitVote(item_or_id, direction, item_kind, callback)
    if not item_or_id then
        if callback then callback(false, "Invalid item_or_id") end
        return
    end

    local candidate_keys = getCandidateKeys(item_or_id)
    local repo_id = candidate_keys[1] or tostring(item_or_id)

    local dev_uuid = StorefrontRatings.getDeviceUUID()
    item_kind = item_kind or "plugin"
    direction = direction or "none"

    local base_up, base_down = resolveCatalogBase(item_or_id)
    local prev_rec = StorefrontRatings.getUserVoteRecord(item_or_id)
    local prev_vote = (prev_rec and prev_rec.direction ~= "none") and prev_rec.direction or nil

    local pending_up = (prev_rec and tonumber(prev_rec.pending_delta_up) or 0)
        + ((direction == "up" and 1 or 0) - (prev_vote == "up" and 1 or 0))
    local pending_down = (prev_rec and tonumber(prev_rec.pending_delta_down) or 0)
        + ((direction == "down" and 1 or 0) - (prev_vote == "down" and 1 or 0))
    local catalog_ts = getCatalogTimestamp()

    -- Save vote + pending delta locally (no storefront_ratings_cache.json writes)
    StorefrontRatings.saveUserVote(item_or_id, direction, base_up, base_down, {
        pending_delta_up = pending_up,
        pending_delta_down = pending_down,
        catalog_ts_at_vote = catalog_ts,
    })

    local UIManager = require("ui/uimanager")

    local payload = json.encode({
        repo_id = tonumber(repo_id) or repo_id,
        direction = direction,
        device_uuid = dev_uuid,
        item_kind = item_kind,
    })

    local dispatch_task = function()
        logger.info("StorefrontRatings: submitting vote", repo_id, direction)

        local StorefrontUtils = require("storefront_utils")
        local is_low_mem = StorefrontUtils.isLowMemory and StorefrontUtils.isLowMemory()

        local function execute_sync(custom_timeout)
            local http_req = getHttpModule(StorefrontRatings.BASE_URL)
            local response_body = {}
            local headers = {
                ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
                ["Content-Length"] = tostring(#payload),
            }

            local block_to = custom_timeout or (socketutil and socketutil.FILE_BLOCK_TIMEOUT) or 15
            local total_to = custom_timeout and (custom_timeout + 2) or (socketutil and socketutil.FILE_TOTAL_TIMEOUT) or 30
            local start_ts = os.time()
            if socketutil and socketutil.set_timeout then
                socketutil:set_timeout(block_to, total_to)
            end
            local ok_req, res_code = pcall(function()
                local payload_sent = false
                local params = {
                    url = StorefrontRatings.BASE_URL,
                    method = "POST",
                    headers = headers,
                    source = function()
                        if not payload_sent then payload_sent = true; return payload end
                        return nil
                    end,
                    sink = function(chunk)
                        if chunk then
                            if total_to > 0 and (os.time() - start_ts > total_to) then
                                return nil, (socketutil and socketutil.SINK_TIMEOUT_CODE) or "sink timeout"
                            end
                            table.insert(response_body, chunk)
                        end
                        return 1
                    end,
                }
                local _, c = http_req.request(params)
                return c
            end)
            if socketutil and socketutil.reset_timeout then
                socketutil:reset_timeout()
            end

            local code = tonumber(res_code) or 0
            if ok_req and code == 200 then
                local body_str = table.concat(response_body)
                local ok_json, parsed = pcall(json.decode, body_str)
                if ok_json and parsed and parsed.success then
                    return true, parsed
                end
            end
            return false, "HTTP " .. tostring(res_code)
        end

        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end

        local can_fork = ok_ffi and ffiutil and ffiutil.runInSubProcess and ffiutil.isSubProcessDone and not is_low_mem

        if can_fork then
            local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
                local ok, parsed_or_err = execute_sync()
                if child_write_fd then
                    local res_payload = json.encode({ok = ok, result = parsed_or_err})
                    ffiutil.writeToFD(child_write_fd, res_payload, true)
                end
            end, true)

            if pid then
                local req = trackActiveRequest(pid, parent_read_fd)
                local poll_attempts = 0
                local MAX_POLL_ATTEMPTS = 30 -- 15-second hard ceiling
                local poll_func
                poll_func = function()
                    local ok_dev, Device = pcall(require, "device")
                    if ok_dev and Device and ((Device.isSuspended and Device:isSuspended()) or Device.screen_saver_mode) then
                        untrackActiveRequest(req)
                        terminateAndCleanupSubProcess(pid, parent_read_fd)
                        if callback then callback(false, "device_suspended") end
                        return
                    end

                    poll_attempts = poll_attempts + 1
                    if poll_attempts > MAX_POLL_ATTEMPTS then
                        untrackActiveRequest(req)
                        terminateAndCleanupSubProcess(pid, parent_read_fd)
                        clearPendingDeltaOnRecord(item_or_id)
                        logger.warn("StorefrontRatings: vote submission subprocess timed out, child terminated")
                        if callback then callback(false, "Subprocess timed out") end
                        return
                    end

                    if ffiutil.isSubProcessDone(pid) then
                        untrackActiveRequest(req)
                        local read_func = ffiutil.readAllFromFD or ffiutil.readFromFD
                        local ok_read, raw_msg = pcall(function()
                            if read_func and parent_read_fd then
                                return read_func(parent_read_fd)
                            elseif read_func then
                                return read_func(pid)
                            end
                        end)
                        if ok_read and type(raw_msg) == "string" and raw_msg ~= "" then
                            local ok_dec, res_data = pcall(json.decode, raw_msg)
                            if ok_dec and res_data and res_data.ok then
                                logger.info("StorefrontRatings: vote submitted successfully", repo_id)
                                if callback then callback(true, nil) end
                                return
                            end
                        end
                        clearPendingDeltaOnRecord(item_or_id)
                        local err_msg = "Subprocess fetch failed"
                        logger.warn("StorefrontRatings: vote submission returned", err_msg)
                        if callback then callback(false, err_msg) end
                    else
                        UIManager:scheduleIn(0.5, poll_func)
                    end
                end
                req.poll_fn = poll_func
                UIManager:scheduleIn(0.5, poll_func)
                return
            end
        end

        -- Low memory or fork unavailable: inform user with toast message and execute lightweight direct HTTP
        if is_low_mem then
            pcall(function()
                local ok_toast, StorefrontToast = pcall(require, "storefront_toast")
                if ok_toast and StorefrontToast and StorefrontToast.show then
                    StorefrontToast.show(_("Submitting vote..."), 1)
                end
            end)
        end

        local ok, result = execute_sync(3) -- 3-second tight timeout
        if ok then
            logger.info("StorefrontRatings: vote submitted successfully (direct)", repo_id)
            if callback then UIManager:scheduleIn(0, function() callback(true, nil) end) end
        else
            clearPendingDeltaOnRecord(item_or_id)
            logger.warn("StorefrontRatings: vote submission returned", result)
            if callback then UIManager:scheduleIn(0, function() callback(false, result) end) end
        end
    end

    UIManager:scheduleIn(0.05, dispatch_task)
end

--- Dispatches an anonymous download telemetry ping to the Cloudflare D1 backend in the background.
--- Completely non-blocking and safe for e-ink devices.
--- @param item_or_id table|number|string
--- @param item_kind string|nil "screensaver", "plugin", "patch", or "font"
--- @param callback function|nil Called with (success, error_message)
function StorefrontRatings.trackDownload(item_or_id, item_kind, callback)
    if not item_or_id then
        if callback then callback(false, "Invalid item_or_id") end
        return
    end

    local candidate_keys = getCandidateKeys(item_or_id)
    local repo_id = candidate_keys[1] or tostring(item_or_id)
    item_kind = item_kind or "screensaver"

    -- Optimistically bump local in-session downloads count only
    local key = tostring(repo_id)
    _session_downloads[key] = (_session_downloads[key] or 0) + 1

    local UIManager = require("ui/uimanager")

    local payload = json.encode({
        action = "download",
        repo_id = tonumber(repo_id) or repo_id,
        device_uuid = StorefrontRatings.getDeviceUUID(),
        item_kind = item_kind,
    })

    local dispatch_task = function()
        logger.info("StorefrontRatings: tracking download", repo_id, item_kind)

        local StorefrontUtils = require("storefront_utils")
        local is_low_mem = StorefrontUtils.isLowMemory and StorefrontUtils.isLowMemory()
        if is_low_mem then
            logger.dbg("StorefrontRatings: skipping download telemetry ping due to low memory")
            if callback then callback(true, nil) end
            return
        end

        local function execute_sync(custom_timeout)
            local http_req = getHttpModule(StorefrontRatings.BASE_URL)
            local response_body = {}
            local headers = {
                ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
                ["Content-Length"] = tostring(#payload),
            }

            local block_to = custom_timeout or (socketutil and socketutil.FILE_BLOCK_TIMEOUT) or 15
            local total_to = custom_timeout and (custom_timeout + 2) or (socketutil and socketutil.FILE_TOTAL_TIMEOUT) or 30
            local start_ts = os.time()
            if socketutil and socketutil.set_timeout then
                socketutil:set_timeout(block_to, total_to)
            end
            local ok_req, res_code = pcall(function()
                local payload_sent = false
                local params = {
                    url = StorefrontRatings.BASE_URL .. "/download",
                    method = "POST",
                    headers = headers,
                    source = function()
                        if not payload_sent then payload_sent = true; return payload end
                        return nil
                    end,
                    sink = function(chunk)
                        if chunk then
                            if total_to > 0 and (os.time() - start_ts > total_to) then
                                return nil, (socketutil and socketutil.SINK_TIMEOUT_CODE) or "sink timeout"
                            end
                            table.insert(response_body, chunk)
                        end
                        return 1
                    end,
                }
                local _, c = http_req.request(params)
                return c
            end)
            if socketutil and socketutil.reset_timeout then
                socketutil:reset_timeout()
            end

            local code = tonumber(res_code) or 0
            if ok_req and code == 200 then
                local body_str = table.concat(response_body)
                local ok_json, parsed = pcall(json.decode, body_str)
                if ok_json and parsed and parsed.success and parsed.downloads then
                    return true, parsed
                end
            end
            return false, "HTTP " .. tostring(res_code)
        end

        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end

        local can_fork = ok_ffi and ffiutil and ffiutil.runInSubProcess and ffiutil.isSubProcessDone and not is_low_mem

        if can_fork then
            local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
                local ok, parsed_or_err = execute_sync()
                if child_write_fd then
                    local res_payload = json.encode({ok = ok, result = parsed_or_err})
                    ffiutil.writeToFD(child_write_fd, res_payload, true)
                end
            end, true)

            if pid then
                local req = trackActiveRequest(pid, parent_read_fd)
                local poll_attempts = 0
                local MAX_POLL_ATTEMPTS = 30 -- 15-second hard ceiling
                local poll_func
                poll_func = function()
                    local ok_dev, Device = pcall(require, "device")
                    if ok_dev and Device and ((Device.isSuspended and Device:isSuspended()) or Device.screen_saver_mode) then
                        untrackActiveRequest(req)
                        terminateAndCleanupSubProcess(pid, parent_read_fd)
                        if callback then callback(false, "device_suspended") end
                        return
                    end

                    poll_attempts = poll_attempts + 1
                    if poll_attempts > MAX_POLL_ATTEMPTS then
                        untrackActiveRequest(req)
                        terminateAndCleanupSubProcess(pid, parent_read_fd)
                        logger.dbg("StorefrontRatings: download track subprocess timed out, child terminated")
                        if callback then callback(false, "Subprocess timed out") end
                        return
                    end

                    if ffiutil.isSubProcessDone(pid) then
                        untrackActiveRequest(req)
                        local read_func = ffiutil.readAllFromFD or ffiutil.readFromFD
                        local ok_read, raw_msg = pcall(function()
                            if read_func and parent_read_fd then
                                return read_func(parent_read_fd)
                            elseif read_func then
                                return read_func(pid)
                            end
                        end)
                        if ok_read and type(raw_msg) == "string" and raw_msg ~= "" then
                            local ok_dec, res_data = pcall(json.decode, raw_msg)
                            if ok_dec and res_data and res_data.ok then
                                local parsed = res_data.result
                                local _, _, _, base_dl = resolveCatalogBase(item_or_id)
                                local server_dl = tonumber(parsed and parsed.downloads) or 0
                                if server_dl > base_dl then
                                    _session_downloads[key] = math.max(_session_downloads[key] or 0, server_dl - base_dl)
                                end
                                logger.info("StorefrontRatings: download tracked successfully", repo_id)
                                if callback then callback(true, nil) end
                                return
                            end
                        end
                        local err_msg = "Subprocess fetch failed"
                        logger.dbg("StorefrontRatings: download track returned", err_msg)
                        if callback then callback(false, err_msg) end
                    else
                        UIManager:scheduleIn(0.5, poll_func)
                    end
                end
                req.poll_fn = poll_func
                UIManager:scheduleIn(0.5, poll_func)
                return
            end
        end

        -- Fallback to sync
        local ok, result = execute_sync(3)
        if ok then
            local _, _, _, base_dl = resolveCatalogBase(item_or_id)
            local server_dl = tonumber(result and result.downloads) or 0
            if server_dl > base_dl then
                _session_downloads[key] = math.max(_session_downloads[key] or 0, server_dl - base_dl)
            end
            logger.info("StorefrontRatings: download tracked successfully (direct)", repo_id)
            if callback then UIManager:scheduleIn(0, function() callback(true, nil) end) end
        else
            logger.dbg("StorefrontRatings: download track returned", result)
            if callback then UIManager:scheduleIn(0, function() callback(false, result) end) end
        end
    end

    UIManager:scheduleIn(0.05, dispatch_task)
end

return StorefrontRatings
