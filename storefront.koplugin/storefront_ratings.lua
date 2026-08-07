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

local StorefrontRatings = {
    liveRatings = {}, -- Cached ratings table: { [repo_id] = { up = 0, down = 0, wilson = 0 } }
    BASE_URL = "https://storefront-vote.ultimatejimmy.workers.dev",
}

--- Fetches all live ratings from the Cloudflare D1 backend asynchronously.
--- @param callback function|nil Called with (success, ratings_table)
function StorefrontRatings.fetchRatings(callback)
    local UIManager = require("ui/uimanager")
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

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            local body_str = table.concat(response_body)
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and type(parsed) == "table" then
                StorefrontRatings.liveRatings = parsed
                logger.info("StorefrontRatings: successfully fetched live ratings")
                if callback then UIManager:scheduleIn(0, function() callback(true, parsed) end) end
                return
            end
        end
        logger.warn("StorefrontRatings: failed to fetch ratings", res_code)
        if callback then UIManager:scheduleIn(0, function() callback(false, nil) end) end
    end

    UIManager:scheduleIn(0.05, fetch_task)
end

--- Gets the live rating summary for a repo ID.
--- @param repo_id number|string
--- @return table { up = number, down = number, wilson = number }
function StorefrontRatings.getRating(repo_id)
    if not repo_id then return { up = 0, down = 0, wilson = 0 } end
    local r = StorefrontRatings.liveRatings[tostring(repo_id)]
    if type(r) == "table" then
        return {
            up = tonumber(r.up) or 0,
            down = tonumber(r.down) or 0,
            wilson = tonumber(r.wilson) or 0,
        }
    end
    return { up = 0, down = 0, wilson = 0 }
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

--- Gets the user's local vote for a given repository ID.
--- @param repo_id number|string
--- @return string|nil "up", "down", or nil
function StorefrontRatings.getUserVote(repo_id)
    if not repo_id then return nil end
    local votes = StorefrontSettings:readSetting(VOTES_KEY)
    if type(votes) ~= "table" then return nil end
    return votes[tostring(repo_id)]
end

--- Saves the user's local vote for a given repository ID.
--- @param repo_id number|string
--- @param direction string|nil "up", "down", or "none"/nil
function StorefrontRatings.saveUserVote(repo_id, direction)
    if not repo_id then return end
    local votes = StorefrontSettings:readSetting(VOTES_KEY)
    if type(votes) ~= "table" then votes = {} end

    local key = tostring(repo_id)
    if direction == "up" or direction == "down" then
        votes[key] = direction
    else
        votes[key] = nil
    end

    StorefrontSettings:saveSetting(VOTES_KEY, votes)
    StorefrontSettings:flush()
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
--- @param repo_id number|string
--- @param direction string "up", "down", or "none"
--- @param item_kind string|nil "plugin", "patch", or "font"
--- @param callback function|nil Called with (success, error_message)
function StorefrontRatings.submitVote(repo_id, direction, item_kind, callback)
    if not repo_id then
        if callback then callback(false, "Invalid repo_id") end
        return
    end

    local dev_uuid = StorefrontRatings.getDeviceUUID()
    item_kind = item_kind or "plugin"
    direction = direction or "none"

    local prev_vote = StorefrontRatings.getUserVote(repo_id)
    -- Update local state immediately
    StorefrontRatings.saveUserVote(repo_id, direction)

    -- Optimistically update in-memory liveRatings immediately
    local key = tostring(repo_id)
    local cur = StorefrontRatings.liveRatings[key] or { up = 0, down = 0, wilson = 0 }
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
                StorefrontRatings.liveRatings[key] = {
                    up = tonumber(parsed.up) or 0,
                    down = tonumber(parsed.down) or 0,
                    wilson = tonumber(parsed.wilson) or 0,
                }
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
