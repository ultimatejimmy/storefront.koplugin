local http = require("socket.http")
local json = require("json")
local url = require("socket.url")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local ok_cfg, StorefrontConfig = pcall(require, "storefront_configuration")
if not ok_cfg then
    StorefrontConfig = {}
end

local GitHubClient = {}

local BASE_URL = "https://api.github.com"
local USER_AGENT = "KOReader-Storefront"

-- Token entered through the Settings UI (see storefront_settings_card.lua),
-- stored separately from storefront_configuration.lua so users don't have to
-- hand-edit a Lua file just to add a PAT. Kept in its own settings file (not
-- StorefrontSettings in main.lua) so this module has no dependency on it.
local AUTH_SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront_github.lua"
local AuthSettings = LuaSettings:open(AUTH_SETTINGS_PATH)
local TOKEN_KEY = "github_token"

local function joinQueryParts(parts)
    if not parts or #parts == 0 then
        return ""
    end
    return table.concat(parts, " ")
end

local function newTableSink(target)
    return function(chunk, err)
        if chunk then
            target[#target + 1] = chunk
        end
        return 1, err
    end
end

-- Returns the configured PAT, preferring the one saved via the Settings UI
-- over the legacy storefront_configuration.lua file (kept for users who
-- already set that up).
function GitHubClient.getToken()
    local saved = AuthSettings:readSetting(TOKEN_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    local auth = StorefrontConfig.auth and StorefrontConfig.auth.github
    local token = auth and auth.token
    if token and token ~= "" and token ~= "your_github_token" then
        return token
    end
    return nil
end

-- Saves (or, when token is nil/empty, clears) the PAT entered via the
-- Settings UI.
function GitHubClient.setToken(token)
    token = token and token:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if token == "" then
        AuthSettings:delSetting(TOKEN_KEY)
    else
        AuthSettings:saveSetting(TOKEN_KEY, token)
    end
    AuthSettings:flush()
end

local function getAuthHeaders()
    local token = GitHubClient.getToken()
    if not token then
        return nil
    end
    local scheme = (StorefrontConfig.auth and StorefrontConfig.auth.github and StorefrontConfig.auth.github.scheme) or "token"
    return {
        ["Authorization"] = string.format("%s %s", scheme, token),
    }
end

local function request(path, query)
    local response_body = {}
    local target = BASE_URL .. path
    if query and query ~= "" then
        target = target .. "?" .. query
    end
    logger.dbg("Storefront HTTP", target)
    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = USER_AGENT,
    }
    local auth_headers = getAuthHeaders()
    if auth_headers then
        for key, value in pairs(auth_headers) do
            headers[key] = value
        end
    end
    local _, code = http.request{
        url = target,
        headers = headers,
        sink = newTableSink(response_body),
    }
    local body = table.concat(response_body)
    return tonumber(code), body
end

local function buildQuery(opts)
    local query_parts = {}
    if opts.q and opts.q ~= "" then
        table.insert(query_parts, "q=" .. url.escape(opts.q))
    end
    if opts.sort and opts.sort ~= "" then
        table.insert(query_parts, "sort=" .. opts.sort)
    end
    if opts.order and opts.order ~= "" then
        table.insert(query_parts, "order=" .. opts.order)
    end
    table.insert(query_parts, "page=" .. tostring(opts.page or 1))
    table.insert(query_parts, "per_page=" .. tostring(opts.per_page or 30))
    return table.concat(query_parts, "&")
end

local function buildTopicQuery(topics, extra_terms)
    local parts = {}
    if topics then
        for _, topic in ipairs(topics) do
            if topic and topic ~= "" then
                table.insert(parts, string.format("topic:%s", topic))
            end
        end
    end
    if extra_terms and extra_terms ~= "" then
        table.insert(parts, extra_terms)
    end
    return joinQueryParts(parts)
end

function GitHubClient.searchRepositories(opts)
    opts = opts or {}
    local query = buildQuery(opts)
    local code, body = request("/search/repositories", query)
    if code ~= 200 then
        logger.warn("GitHub search error", code, body)
        -- GitHub's search endpoint rejects fine-grained PATs outright (they're
        -- not in its list of supported token types), returning a 403 with this
        -- wording rather than an actual rate-limit response. Classic tokens work.
        local is_fine_grained_unsupported = code == 403
            and body
            and body:lower():find("fine%-grained", 1, true) ~= nil
        local err_info = {
            code = code,
            body = body,
            is_rate_limit = (code == 403 or code == 429) and not is_fine_grained_unsupported,
            is_fine_grained_unsupported = is_fine_grained_unsupported,
        }
        return nil, err_info
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub search decode error", parsed)
        return nil, { code = 0, body = "decode", is_rate_limit = false }
    end
    return parsed, nil
end

function GitHubClient.hasAuthToken()
    return GitHubClient.getToken() ~= nil
end

function GitHubClient.searchByTopics(topics, opts)
    opts = opts or {}
    local q = buildTopicQuery(topics, opts.extra)
    opts.q = q
    opts.sort = opts.sort or "stars"
    opts.order = opts.order or "desc"
    opts.per_page = opts.per_page or 100
    return GitHubClient.searchRepositories(opts)
end

function GitHubClient.fetchRepoTree(owner, repo, ref)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    ref = ref or "HEAD"
    local path = string.format("/repos/%s/%s/git/trees/%s", owner, repo, ref)
    local code, body = request(path, "recursive=1")
    if code ~= 200 then
        logger.warn("GitHub fetch tree error", owner .. "/" .. repo, ref, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch tree decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchRepoMetadata(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch repo metadata error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch repo metadata decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchLatestRelease(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s/releases/latest", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch latest release error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch latest release decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

-- Fetch all releases of a repository (sorted from newest to oldest by GitHub).
-- Pagination is performed transparently up to `max_pages` to avoid hammering
-- the API for repositories with hundreds of releases.
function GitHubClient.fetchReleases(owner, repo, opts)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    opts = opts or {}
    local per_page = tonumber(opts.per_page) or 100
    local max_pages = tonumber(opts.max_pages) or 5
    local results = {}
    for page = 1, max_pages do
        local path = string.format("/repos/%s/%s/releases", owner, repo)
        local query = string.format("per_page=%d&page=%d", per_page, page)
        local code, body = request(path, query)
        if code ~= 200 then
            logger.warn("GitHub fetch releases error", owner .. "/" .. repo, code, body)
            if #results > 0 then
                return results, nil
            end
            return nil, { code = code, body = body }
        end
        local ok, parsed = pcall(json.decode, body)
        if not ok or type(parsed) ~= "table" then
            logger.warn("GitHub fetch releases decode error", parsed)
            if #results > 0 then
                return results, nil
            end
            return nil, "decode"
        end
        if #parsed == 0 then
            break
        end
        for _, rel in ipairs(parsed) do
            table.insert(results, rel)
        end
        if #parsed < per_page then
            break
        end
    end
    return results, nil
end

-- Fetch the list of commits between two refs (tags, branches, SHAs).
-- Uses the GitHub compare endpoint: /repos/{owner}/{repo}/compare/{base}...{head}
-- Returns the parsed JSON table (contains `commits`, `total_commits`, etc.) or nil + err.
function GitHubClient.fetchCompareCommits(owner, repo, base, head)
    if not owner or not repo or not base or not head then
        return nil, "missing parameters"
    end
    local path = string.format("/repos/%s/%s/compare/%s...%s", owner, repo, base, head)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub compare error", owner .. "/" .. repo, base .. "..." .. head, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub compare decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

-- Fetch the HTML representation of README.
-- Returns raw HTML string, or nil + error.
function GitHubClient.fetchReadmeHtml(owner, repo)
    if not owner or not repo then
        return nil, "missing parameters"
    end
    local path = string.format("/repos/%s/%s/readme", owner, repo)
    local response_body = {}
    local target = BASE_URL .. path
    logger.dbg("Storefront HTTP readme html", target)
    local headers = {
        ["Accept"] = "application/vnd.github.html",
        ["User-Agent"] = USER_AGENT,
    }
    local auth_headers = getAuthHeaders()
    if auth_headers then
        for key, value in pairs(auth_headers) do
            headers[key] = value
        end
    end
    local _, code = http.request{
        url = target,
        headers = headers,
        sink = newTableSink(response_body),
    }
    local body = table.concat(response_body)
    if tonumber(code) ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    return body, nil
end

return GitHubClient


