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
        if type(votes) == "table" and next(votes) ~= nil then
            user_votes_cache = votes
        else
            local backup_votes = loadVotesBackupFile()
            if type(backup_votes) == "table" then
                user_votes_cache = backup_votes
                pcall(function()
                    StorefrontSettings:saveSetting(VOTES_KEY, user_votes_cache)
                    StorefrontSettings:flush()
                end)
            else
                user_votes_cache = type(votes) == "table" and votes or {}
            end
        end
    end
    return user_votes_cache
end

local is_fetching = false
local last_fetch_time = 0
local FETCH_COOLDOWN = 60 -- seconds

--- Fetches all live ratings from the Cloudflare D1 backend asynchronously.
--- @param callback function|nil Called with (success, ratings_table)
function StorefrontRatings.fetchRatings(callback)
    local UIManager = require("ui/uimanager")
    local NetworkMgr = require("ui/network/manager")

    if NetworkMgr and type(NetworkMgr.isConnected) == "function" and not NetworkMgr:isConnected() then
        logger.info("StorefrontRatings: network not connected, returning local cache")
        if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
        UIManager:scheduleIn(5, function() StorefrontRatings.fetchRatings(nil) end)
        return
    end

    local now = os.time()
    if (now - last_fetch_time) < FETCH_COOLDOWN and next(StorefrontRatings.liveRatings) ~= nil then
        if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
        return
    end
    if is_fetching then
        if callback then UIManager:scheduleIn(0, function() callback(true, StorefrontRatings.liveRatings) end) end
        return
    end

    is_fetching = true
    last_fetch_time = now
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
    local keys = {}
    local seen = {}
    local function add_key(k)
        if k ~= nil and k ~= "" then
            local str_k = tostring(k)
            if not seen[str_k] then
                seen[str_k] = true
                table.insert(keys, str_k)
            end
        end
    end

    if type(item_or_id) == "table" then
        local item = item_or_id
        add_key(item.id)
        add_key(item.repo_id)
        if item.repo then
            add_key(item.repo.id)
            add_key(item.repo.repo_id)
            if item.repo.data then
                add_key(item.repo.data.id)
                add_key(item.repo.data.repo_id)
            end
            add_key(item.repo.full_name)
            add_key(item.repo.name)
        end
        if item.record then
            add_key(item.record.id)
            add_key(item.record.repo_id)
            add_key(item.record.repo_full_name)
            add_key(item.record.repo)
        end
        if item.plugin then
            add_key(item.plugin.id)
            add_key(item.plugin.repo_id)
            add_key(item.plugin.dirname)
            add_key(item.plugin.name)
        end
        if item.patch then
            add_key(item.patch.id)
            add_key(item.patch.repo_id)
            add_key(item.patch.filename)
        end
        add_key(item.full_name)
        add_key(item.name)
        add_key(item.dirname)
        add_key(item.filename)
        add_key(item.font_name)
        add_key(item.font_family)
    else
        add_key(item_or_id)
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

    local e = type(entry) == "table" and entry or (type(item_or_id) == "table" and item_or_id or nil)
    if e then
        base_up = tonumber(e.user_thumbs_up or (e.repo and e.repo.user_thumbs_up) or (e.plugin and e.plugin.user_thumbs_up) or (e.record and e.record.user_thumbs_up) or e.user_thumbs_up_base) or 0
        base_down = tonumber(e.user_thumbs_down or (e.repo and e.repo.user_thumbs_down) or (e.plugin and e.plugin.user_thumbs_down) or (e.record and e.record.user_thumbs_down) or e.user_thumbs_down_base) or 0
        wilson = tonumber(e.wilson_score or (e.repo and e.repo.wilson_score) or e.wilson) or 0
    end

    local candidate_keys = getCandidateKeys(item_or_id)
    for _, key in ipairs(candidate_keys) do
        local r = StorefrontRatings.liveRatings[key]
        if type(r) == "table" then
            local r_up = tonumber(r.up) or 0
            local r_down = tonumber(r.down) or 0
            if r_up > base_up then base_up = r_up end
            if r_down > base_down then base_down = r_down end
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
    }
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
        local rec = votes[key]
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

return StorefrontRatings
