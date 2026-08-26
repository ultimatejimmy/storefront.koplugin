--- Storefront Ratings Module
--- Manages anonymous device identification, local vote persistence, Wilson score ranking,
--- and background dispatch of votes to GitHub.
---
--- @module StorefrontRatings

local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local socketutil = require("socketutil")

local function getHttpModule(url)
    return require("socket.http")
end

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)

local UUID_KEY = "device_uuid"
local VOTES_KEY = "user_votes"
local RATINGS_CACHE_FILE = DataStorage:getSettingsDir() .. "/storefront_ratings_cache.json"
local VOTES_BACKUP_FILE = DataStorage:getSettingsDir() .. "/storefront_votes_backup.json"

local function normalizeRatingsTable(tbl)
    if type(tbl) ~= "table" then return {} end
    local normalized = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            local str_key = tostring(k)
            normalized[str_key] = {
                up = tonumber(v.up) or 0,
                down = tonumber(v.down) or 0,
                wilson = tonumber(v.wilson) or 0,
                downloads = tonumber(v.downloads) or 0,
            }
        end
    end
    return normalized
end

local function loadLocalRatingsFile()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(RATINGS_CACHE_FILE, "mode") == "file" then
        local f = io.open(RATINGS_CACHE_FILE, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local ok_j, parsed = pcall(json.decode, content)
                if ok_j and type(parsed) == "table" then
                    return normalizeRatingsTable(parsed)
                end
            end
        end
    end
    return nil
end

local function saveLocalRatingsFile(ratings_table)
    if type(ratings_table) == "table" then
        pcall(function()
            local norm = normalizeRatingsTable(ratings_table)
            local ok_j, content = pcall(json.encode, norm)
            if ok_j and content and content ~= "" then
                local f = io.open(RATINGS_CACHE_FILE, "w")
                if f then
                    f:write(content)
                    f:close()
                end
            end
        end)
    end
end

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
    liveRatings = loadLocalRatingsFile() or {}, -- Cached ratings table: { [repo_id] = { up = 0, down = 0, wilson = 0 } }
    BASE_URL = "https://storefront-vote.ultimatejimmy.workers.dev",
}

local user_votes_cache = nil

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
                local num_k = tonumber(k)
                user_votes_cache[str_k] = v
                if num_k then
                    user_votes_cache[num_k] = v
                end

                -- Detect legacy bare keys (no '/' and not numeric) and migrate them if matched
                if not str_k:find("/") and not str_k:match("^%d+$") and type(v) == "table" then
                    local ok_inst, InstallStore = pcall(require, "storefront_installs")
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
                                user_votes_cache[rec.repo_id] = v
                            end
                            user_votes_cache[str_k] = nil
                            if num_k then user_votes_cache[num_k] = nil end
                            migrated = true
                        end
                    end
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

local is_fetching = false
local last_fetch_time = 0
local session_ratings_fetched = false
local FETCH_COOLDOWN = 3600 -- seconds (1 hour)

--- Fetches all live ratings from the Cloudflare D1 backend asynchronously.
--- @param callback function|nil Called with (success, ratings_table)
--- @param force_refresh boolean|nil If true, bypasses session cache & cooldown
function StorefrontRatings.fetchRatings(callback, force_refresh)
    local UIManager = require("ui/uimanager")
    local NetworkMgr = require("ui/network/manager")

    local now = os.time()
    if not force_refresh then
        if session_ratings_fetched or (now - last_fetch_time) < FETCH_COOLDOWN then
            if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
            return
        end
    end

    session_ratings_fetched = true
    last_fetch_time = now

    if NetworkMgr and type(NetworkMgr.isConnected) == "function" and not NetworkMgr:isConnected() then
        logger.info("StorefrontRatings: network not connected, returning local cache")
        if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
        return
    end

    if is_fetching then
        if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
        return
    end

    is_fetching = true
    local fetch_task = function()
        local http_req = getHttpModule(StorefrontRatings.BASE_URL)
        local response_body = {}

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok_req, res_code = pcall(function()
            local params = {
                url = StorefrontRatings.BASE_URL .. "/ratings",
                method = "GET",
                headers = {
                    ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
                    ["Accept"] = "application/json",
                },
                sink = function(chunk)
                    if chunk then table.insert(response_body, chunk) end
                    return 1
                end,
            }
            local _, c = http_req.request(params)
            return c
        end)
        socketutil:reset_timeout()

        is_fetching = false
        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            local body_str = table.concat(response_body)
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and type(parsed) == "table" then
                local norm = normalizeRatingsTable(parsed)
                StorefrontRatings.liveRatings = norm
                saveLocalRatingsFile(norm)
                logger.info("StorefrontRatings: successfully fetched live ratings")
                if callback then UIManager:scheduleIn(0, function() callback(true, norm) end) end
                return
            end
        end
        logger.warn("StorefrontRatings: failed to fetch ratings", res_code)
        if callback then UIManager:scheduleIn(0, function() callback(false, nil) end) end
    end

    UIManager:scheduleIn(0.05, fetch_task)
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
            add_key_variants(val)
            if not val:find("/") and not val:match("^%d+$") then
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

    if primary_id then
        add_key_variants(primary_id)
    end

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

    if owner and type(owner) == "string" and owner ~= "" and name and type(name) == "string" and name ~= "" then
        add_key_variants(owner .. "/" .. name)
        local clean_name = name:gsub("%.koplugin$", "")
        add_key_variants(owner .. "/" .. clean_name)
    end

    add_key_variants(item.full_name)
    add_key_variants(name)
    add_key_variants(item.dirname)
    add_key_variants(item.filename)
    add_key_variants(item.font_name)

    if type(item_or_id) == "table" then
        item_or_id._candidate_keys = keys
    end

    return keys
end

--- Gets the live rating summary for an item or repo ID.
--- @param item_or_id table|number|string
--- @param entry table|nil
--- @return table { up = number, down = number, wilson = number }
function StorefrontRatings.getRating(item_or_id, entry)
    local base_up = 0
    local base_down = 0
    local wilson = 0
    local base_downloads = 0

    local e = type(entry) == "table" and entry or (type(item_or_id) == "table" and item_or_id or nil)
    if e then
        base_up = tonumber(e.user_thumbs_up or (e.repo and e.repo.user_thumbs_up) or (e.plugin and e.plugin.user_thumbs_up) or (e.record and e.record.user_thumbs_up) or e.user_thumbs_up_base or e.likes) or 0
        base_down = tonumber(e.user_thumbs_down or (e.repo and e.repo.user_thumbs_down) or (e.plugin and e.plugin.user_thumbs_down) or (e.record and e.record.user_thumbs_down) or e.user_thumbs_down_base) or 0
        wilson = tonumber(e.wilson_score or (e.repo and e.repo.wilson_score) or e.wilson) or 0
        base_downloads = tonumber(e.downloads or e.download_count or e.downloads_count or (e.repo and (e.repo.downloads or e.repo.download_count)) or e.installs) or 0
    end

    local candidate_keys = getCandidateKeys(item_or_id)
    for _, key in ipairs(candidate_keys) do
        local num_k = tonumber(key)
        local r = StorefrontRatings.liveRatings[key] or (num_k and StorefrontRatings.liveRatings[num_k])
        if type(r) == "table" then
            local r_up = tonumber(r.up) or 0
            local r_down = tonumber(r.down) or 0
            local r_dl = tonumber(r.downloads) or 0
            if r_up > base_up then base_up = r_up end
            if r_down > base_down then base_down = r_down end
            if r_dl > base_downloads then base_downloads = r_dl end
            if (tonumber(r.wilson) or 0) > wilson then wilson = tonumber(r.wilson) or 0 end
            break
        end
    end

    local final_up = base_up
    local final_down = base_down

    local vote_rec = StorefrontRatings.getUserVoteRecord(item_or_id)
    if vote_rec and vote_rec.direction then
        if vote_rec.direction == "up" then
            if base_up <= (tonumber(vote_rec.catalog_up_at_vote) or 0) then
                final_up = base_up + 1
            end
        elseif vote_rec.direction == "down" then
            if base_down <= (tonumber(vote_rec.catalog_down_at_vote) or 0) then
                final_down = base_down + 1
            end
        end
    end

    return {
        up = final_up,
        down = final_down,
        wilson = wilson,
        downloads = base_downloads,
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
    return rec and rec.direction or nil
end

--- Saves the user's local vote for a given item or repository ID.
--- @param item_or_id table|number|string
--- @param direction string|nil "up", "down", or "none"/nil
--- @param catalog_up number|nil
--- @param catalog_down number|nil
function StorefrontRatings.saveUserVote(item_or_id, direction, catalog_up, catalog_down)
    if not item_or_id then return end
    local votes = loadVotesCache()
    local candidate_keys = getCandidateKeys(item_or_id)
    if #candidate_keys == 0 then return end

    local vote_rec = nil
    if direction == "up" or direction == "down" then
        vote_rec = {
            direction = direction,
            catalog_up_at_vote = tonumber(catalog_up) or 0,
            catalog_down_at_vote = tonumber(catalog_down) or 0,
        }
    end

    for _, key in ipairs(candidate_keys) do
        votes[key] = vote_rec
        local num_k = tonumber(key)
        if num_k then
            votes[num_k] = vote_rec
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

    local cur_rating = StorefrontRatings.getRating(item_or_id)
    local prev_vote = StorefrontRatings.getUserVote(item_or_id)
    
    -- Save vote locally with catalog base numbers to avoid double counting
    StorefrontRatings.saveUserVote(item_or_id, direction, cur_rating.up, cur_rating.down)

    -- Optimistically update in-memory liveRatings immediately
    local key = tostring(repo_id)
    local cur = StorefrontRatings.liveRatings[key] or { up = cur_rating.up, down = cur_rating.down, wilson = 0 }
    local up = tonumber(cur.up) or 0
    local down = tonumber(cur.down) or 0

    if prev_vote == "up" then up = math.max(0, up - 1)
    elseif prev_vote == "down" then down = math.max(0, down - 1) end

    if direction == "up" then up = up + 1
    elseif direction == "down" then down = down + 1 end

    StorefrontRatings.liveRatings[key] = {
        up = up,
        down = down,
        wilson = StorefrontRatings.computeWilsonScore(up, down),
    }

    local UIManager = require("ui/uimanager")

    local payload = json.encode({
        repo_id = tonumber(repo_id) or repo_id,
        direction = direction,
        device_uuid = dev_uuid,
        item_kind = item_kind,
    })

    local dispatch_task = function()
        logger.info("StorefrontRatings: submitting vote", repo_id, direction)
        local http_req = getHttpModule(StorefrontRatings.BASE_URL)
        local response_body = {}
        local headers = {
            ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        }

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
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
                    if chunk then table.insert(response_body, chunk) end
                    return 1
                end,
            }
            local _, c = http_req.request(params)
            return c
        end)
        socketutil:reset_timeout()

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            local body_str = table.concat(response_body)
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and parsed and parsed.success then
                -- Confirm with exact database values from Cloudflare
                for _, k in ipairs(candidate_keys) do
                    StorefrontRatings.liveRatings[k] = {
                        up = tonumber(parsed.up) or 0,
                        down = tonumber(parsed.down) or 0,
                        wilson = tonumber(parsed.wilson) or 0,
                    }
                end
                UIManager:scheduleIn(1, function()
                    saveLocalRatingsFile(StorefrontRatings.liveRatings)
                end)
            end
            logger.info("StorefrontRatings: vote submitted successfully", repo_id)
            if callback then UIManager:scheduleIn(0, function() callback(true, nil) end) end
        else
            local err_msg = "HTTP " .. tostring(res_code)
            logger.warn("StorefrontRatings: vote submission returned", err_msg)
            if callback then UIManager:scheduleIn(0, function() callback(false, err_msg) end) end
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

    -- Optimistically update local in-memory downloads count
    local key = tostring(repo_id)
    local cur = StorefrontRatings.liveRatings[key] or { up = 0, down = 0, wilson = 0, downloads = 0 }
    cur.downloads = (tonumber(cur.downloads) or 0) + 1
    StorefrontRatings.liveRatings[key] = cur

    local UIManager = require("ui/uimanager")

    local payload = json.encode({
        action = "download",
        repo_id = tonumber(repo_id) or repo_id,
        device_uuid = StorefrontRatings.getDeviceUUID(),
        item_kind = item_kind,
    })

    local dispatch_task = function()
        logger.info("StorefrontRatings: tracking download", repo_id, item_kind)
        local http_req = getHttpModule(StorefrontRatings.BASE_URL)
        local response_body = {}
        local headers = {
            ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        }

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
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
                    if chunk then table.insert(response_body, chunk) end
                    return 1
                end,
            }
            local _, c = http_req.request(params)
            return c
        end)
        socketutil:reset_timeout()

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            local body_str = table.concat(response_body)
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and parsed and parsed.success and parsed.downloads then
                for _, k in ipairs(candidate_keys) do
                    local entry = StorefrontRatings.liveRatings[k] or { up = 0, down = 0, wilson = 0 }
                    entry.downloads = tonumber(parsed.downloads) or entry.downloads
                    StorefrontRatings.liveRatings[k] = entry
                end
                UIManager:scheduleIn(1, function()
                    saveLocalRatingsFile(StorefrontRatings.liveRatings)
                end)
            end
            logger.info("StorefrontRatings: download tracked successfully", repo_id)
            if callback then UIManager:scheduleIn(0, function() callback(true, nil) end) end
        else
            local err_msg = "HTTP " .. tostring(res_code)
            logger.dbg("StorefrontRatings: download track returned", err_msg)
            if callback then UIManager:scheduleIn(0, function() callback(false, err_msg) end) end
        end
    end

    UIManager:scheduleIn(0.05, dispatch_task)
end

return StorefrontRatings
