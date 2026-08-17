local Cache = require("storefront_cache")
local GitHub = require("storefront_net_github")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local logger = require("logger")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = { info = function() end, err = function() end, warn = function() end } end

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)

local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin"' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches"' }

local INCLUDE_ZERO_STAR_FORKS_KEY = "include_zero_star_forks"

local SEARCH_RESULT_LIMIT = 1000
local SEARCH_DATE_BISECT_MAX_DEPTH = 8
local SEARCH_ORIGIN_DATE = "2010-01-01"

local NON_FORK_SUFFIX = ""
local FORK_WITH_STARS_SUFFIX = " fork:only stars:>=1"
local FORK_ANY_STARS_SUFFIX = " fork:only"

local STAR_SPLIT_SUFFIXES_NONFORK = { " stars:0", " stars:>=1" }
local STAR_SPLIT_SUFFIXES_FORK_DEFAULT = { " fork:only stars:>=1" }
local STAR_SPLIT_SUFFIXES_FORK_WITH_ZERO = { " fork:only stars:0", " fork:only stars:>=1" }

local SearchNet = {}

local function appendUniqueRepo(target, seen, repo)
    if type(repo) ~= "table" then return end
    local key = repo.id or repo.node_id or repo.full_name
    if not key then
        local owner = repo.owner and (repo.owner.login or repo.owner)
        if owner and repo.name then
            key = tostring(owner) .. "/" .. tostring(repo.name)
        elseif repo.name then
            key = tostring(repo.name)
        end
    end
    if not key then return end
    key = tostring(key)
    if seen[key] then return end
    seen[key] = true
    table.insert(target, repo)
end

local function dateToTimestamp(date_str)
    local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
    if not y then return os.time() end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

local function timestampToDate(ts)
    return os.date("%Y-%m-%d", ts)
end

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

    for _, repo in ipairs(first_items) do
        append(repo)
    end

    if total_count < SEARCH_RESULT_LIMIT or depth >= SEARCH_DATE_BISECT_MAX_DEPTH then
        if total_count >= SEARCH_RESULT_LIMIT then
            logger.warn("Storefront: date bisect depth limit reached, some results may be lost", query, total_count)
        end
        if #first_items >= 100 then
            local err = paginateFromPage(query, append, 2)
            if err then
                logger.warn("Storefront pagination error", query, err)
            end
        end
        return
    end

    logger.info("Storefront: query has", total_count, "results (>=1000), bisecting by date", query)
    local from_ts = date_from and dateToTimestamp(date_from) or dateToTimestamp(SEARCH_ORIGIN_DATE)
    local to_ts = date_to and dateToTimestamp(date_to) or os.time()

    if to_ts - from_ts < 86400 then
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

    logger.info("Storefront: adaptive branch exceeded limit, falling back to star split", query, total_count)
    local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
    for _, suffix in ipairs(starSplitSuffixes(branch, include_zero)) do
        exhaustiveSearch(base_topic_query .. suffix, append)
    end
end

function SearchNet:init(Storefront)
    Storefront.fetchAndStore = function(sf, kind, topics, label, name_queries)
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
            local base_topic_query = table.concat(parts, " ")
            if base_topic_query ~= "" then
                exhaustiveSearchAdaptive(base_topic_query, NON_FORK_SUFFIX, append, "nonfork")
                local include_zero = StorefrontSettings:readSetting(INCLUDE_ZERO_STAR_FORKS_KEY) == true
                local fork_suffix = include_zero and FORK_ANY_STARS_SUFFIX or FORK_WITH_STARS_SUFFIX
                exhaustiveSearchAdaptive(base_topic_query, fork_suffix, append, "fork")
            end
        end

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

    Storefront.isRefreshing = function(sf)
        if sf and sf.is_refreshing then
            return true
        end
        local ok_cat, CatalogClient = pcall(require, "storefront_net_catalog")
        if ok_cat and CatalogClient and CatalogClient.isRefreshing and CatalogClient.isRefreshing() then
            return true
        end
        return false
    end

    Storefront.refreshCache = function(sf, kind, callback)
        local Toast = require("storefront_toast")
        if sf:isRefreshing() then
            Toast.show(_("Catalog refresh is already in progress in the background."), 3)
            if callback then callback(false, "Already refreshing") end
            return
        end
        sf:ensureBrowserState()
        kind = kind or (sf.browser_state and sf.browser_state.kind) or "plugin"

        sf.is_refreshing = true
        sf.patch_cache = {}
        sf._repo_descriptors_cache = nil
        StorefrontLogger.info(string.format("CACHE REFRESH starting (kind=%s)", tostring(kind)))

        local Toast = require("storefront_toast")
        local UIManager = require("ui/uimanager")
        local is_direct = GitHub.isDirectApiEnabled()
        local initial_msg = is_direct and _("Refreshing catalog via Direct GitHub API…") or _("Refreshing catalog…")
        local progress_toast = Toast.show(initial_msg, 0, { dismissable = false })
        if UIManager.forceRePaint then UIManager:forceRePaint() end

        local finishRefresh = function(ok, summary_msg, err_msg)
            sf.is_refreshing = false
            if progress_toast and progress_toast.close then
                pcall(function() progress_toast:close() end)
            end
            if ok then
                StorefrontLogger.info(string.format("CACHE REFRESH complete: %s", tostring(summary_msg)))
                Toast.show(summary_msg or _("Storefront cache refreshed."), 3)
            else
                local message = tostring(err_msg or "Unknown error")
                StorefrontLogger.err(string.format("CACHE REFRESH failed: %s", message))
                Toast.show(_("Storefront refresh failed: ") .. message, 4)
            end
            if callback then callback(ok, summary_msg or err_msg) end
        end

        local CatalogClient = require("storefront_net_catalog")
        if not is_direct then
            logger.info("Storefront: refreshing via static catalog feed (async)")
            CatalogClient.fetchAndUpdateCacheAsync(nil, function(catalog_ok, catalog_err)
                if catalog_ok then
                    local p_count = Cache.countRepos("plugin")
                    local pt_count = Cache.countRepos("patch")
                    local f_count = Cache.countRepos("font")
                    local summary = string.format(_("Catalog updated: %d plugins, %d patches, %d fonts."), p_count, pt_count, f_count)
                    StorefrontSettings:saveSetting("status_text", summary)
                    StorefrontSettings:flush()
                    finishRefresh(true, summary, nil)
                else
                    logger.warn("Storefront static catalog update failed:", catalog_err)
                    local ok_c, Cache = pcall(require, "storefront_cache")
                    if ok_c and Cache and (Cache.countRepos("plugin") or 0) == 0 then
                        logger.info("Storefront: catalog cache empty after fetch error, loading bundled catalog fallback")
                        CatalogClient.loadBundledCatalog()
                    end
                    finishRefresh(false, nil, catalog_err)
                end
            end)
            return
        end

        UIManager:scheduleIn(0.05, function()
            local ok, err = pcall(function()
                local refresh_plugins = (kind == "plugin") or (kind == "all")
                local refresh_patches = (kind == "patch") or (kind == "all")
                local summary_parts = {}
                if refresh_plugins then
                    if progress_toast and progress_toast.setText then
                        progress_toast:setText(_("Fetching plugins via Direct GitHub API…"))
                        if UIManager.forceRePaint then UIManager:forceRePaint() end
                    end
                    local plugin_total = sf:fetchAndStore("plugin", PLUGIN_TOPICS, "Plugin", PLUGIN_NAME_QUERIES)
                    table.insert(summary_parts, string.format(_("Cached %s plugins."), tostring(plugin_total)))
                end
                if refresh_patches then
                    if progress_toast and progress_toast.setText then
                        progress_toast:setText(_("Fetching patches via Direct GitHub API…"))
                        if UIManager.forceRePaint then UIManager:forceRePaint() end
                    end
                    local patch_total = sf:fetchAndStore("patch", PATCH_TOPICS, "Patch", PATCH_NAME_QUERIES)
                    if sf.refreshPatchFileListings then
                        if progress_toast and progress_toast.setText then
                            progress_toast:setText(_("Fetching patch file listings…"))
                            if UIManager.forceRePaint then UIManager:forceRePaint() end
                        end
                        sf:refreshPatchFileListings()
                    end
                    table.insert(summary_parts, string.format(_("Cached %s patch repositories."), tostring(patch_total)))
                end
                local summary = table.concat(summary_parts, " ")
                if summary == "" then
                    summary = _("Storefront cache refreshed.")
                end
                StorefrontSettings:saveSetting("status_text", summary)
                StorefrontSettings:flush()
                finishRefresh(true, summary, nil)
            end)

            if not ok then
                finishRefresh(false, nil, err)
            end
        end)
    end

    Storefront.cancelRefreshCache = function(sf)
        local CatalogClient = require("storefront_net_catalog")
        if CatalogClient and CatalogClient.cancelAsyncFetch then
            CatalogClient.cancelAsyncFetch()
        end
        sf.is_refreshing = false
    end
end

return SearchNet
