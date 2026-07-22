local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local Cache = require("storefront_cache")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = nil end

local ok_cfg, StorefrontConfig = pcall(require, "storefront_config")
if not ok_cfg then
    ok_cfg, StorefrontConfig = pcall(require, "storefront_configuration")
end
if not ok_cfg then
    StorefrontConfig = {}
end

local CatalogClient = {}

local DEFAULT_CATALOG_URL = "https://ultimatejimmy.github.io/storefront.koplugin/catalog.json"
local USER_AGENT = "KOReader-Storefront"

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront.lua"
local StorefrontSettings = LuaSettings:open(SETTINGS_PATH)
local CATALOG_URL_KEY = "catalog_url"

function CatalogClient.getCatalogUrl()
    local saved = StorefrontSettings:readSetting(CATALOG_URL_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    if StorefrontConfig.catalog_url and StorefrontConfig.catalog_url ~= "" then
        return StorefrontConfig.catalog_url
    end
    return DEFAULT_CATALOG_URL
end

function CatalogClient.setCatalogUrl(url)
    url = url and url:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if url == "" or url == DEFAULT_CATALOG_URL then
        StorefrontSettings:delSetting(CATALOG_URL_KEY)
    else
        StorefrontSettings:saveSetting(CATALOG_URL_KEY, url)
    end
    StorefrontSettings:flush()
end

local function newTableSink(target)
    return function(chunk, err)
        if chunk then
            target[#target + 1] = chunk
        end
        return 1, err
    end
end

function CatalogClient.fetchCatalog(url_to_fetch)
    local target_url = url_to_fetch or CatalogClient.getCatalogUrl()
    logger.info("Storefront: fetching static catalog from", target_url)
    
    local response_body = {}
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
    }
    
    local _, code = http.request{
        url = target_url,
        headers = headers,
        sink = newTableSink(response_body),
    }
    
    code = tonumber(code) or 0
    if code ~= 200 then
        logger.warn("Storefront catalog fetch error", target_url, code)
        return nil, { code = code, body = "HTTP " .. tostring(code) }
    end
    
    local body = table.concat(response_body)
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= "table" then
        logger.warn("Storefront catalog decode error", parsed)
        return nil, { code = 0, body = "JSON decode error" }
    end
    
    return parsed, nil
end

function CatalogClient.updateCacheFromCatalog(catalog_data)
    if not catalog_data or type(catalog_data) ~= "table" then
        return false, "invalid catalog format"
    end
    
    local plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}
    
    logger.info("Storefront: updating cache from static catalog", "plugins:", #plugins, "patches:", #patches)
    
    -- Store plugin repositories
    Cache.storeRepos("plugin", plugins)
    
    -- Store patch repositories
    Cache.storeRepos("patch", patches)
    
    -- Store patch file metadata for patch repositories
    for _, repo in ipairs(patches) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        if repo_id and repo.patch_files and type(repo.patch_files) == "table" then
            local pushed_at = repo.pushed_at or repo.updated_at or ""
            Cache.storePatchFiles(repo_id, repo.patch_files, pushed_at)
        end
    end
    
    return true, nil
end

function CatalogClient.fetchCatalogToFile(url_to_fetch, dest_path)
    local target_url = url_to_fetch or CatalogClient.getCatalogUrl()
    logger.info("Storefront: fetching catalog to file from", target_url)

    local file, err = io.open(dest_path, "w")
    if not file then
        logger.err("Storefront: failed to open dest_path for writing", err)
        return false, "failed to open dest_path"
    end

    local sink = function(chunk, err_chunk)
        if chunk then
            file:write(chunk)
        end
        return 1, err_chunk
    end

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
    }

    local _, code = http.request{
        url = target_url,
        headers = headers,
        sink = sink,
    }
    file:close()

    code = tonumber(code) or 0
    if code ~= 200 then
        os.remove(dest_path)
        logger.warn("Storefront catalog fetch to file error", target_url, code)
        return false, "HTTP " .. tostring(code)
    end
    return true, nil
end

function CatalogClient.cancelAsyncFetch()
    if CatalogClient._async_pid then
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end
        if ok_ffi and ffiutil and ffiutil.terminateSubProcess then
            ffiutil.terminateSubProcess(CatalogClient._async_pid)
        end
        CatalogClient._async_pid = nil
    end
end

function CatalogClient.fetchAndUpdateCacheAsync(url_to_fetch, callback)
    local GitHub = require("storefront_net_github")
    if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
        logger.info("Storefront: skipping background catalog update because Direct API mode is active")
        if callback then callback(false, "Direct API mode active") end
        return
    end

    if CatalogClient._async_pid then
        logger.info("Storefront: catalog async fetch already in progress")
        if callback then callback(false, "already in progress") end
        return
    end

    local UIManager = require("ui/uimanager")
    local util = require("util")
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end

    local target_url = url_to_fetch or CatalogClient.getCatalogUrl()
    logger.info("Storefront: starting background catalog fetch from", target_url)
    if StorefrontLogger then StorefrontLogger.info("Storefront: starting background catalog fetch from " .. tostring(target_url)) end

    local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
    util.makePath(cache_dir)
    local tmp_file = cache_dir .. "/catalog_download.json.tmp"

    os.remove(tmp_file)

    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        logger.warn("Storefront: ffiutil.runInSubProcess unavailable, falling back to sync fetch")
        local ok, err = CatalogClient.fetchAndUpdateCache(target_url)
        if callback then callback(ok, err) end
        return
    end

    local pid = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local ok, fetch_err = CatalogClient.fetchCatalogToFile(target_url, tmp_file)
        if child_write_fd then
            ffiutil.writeToFD(child_write_fd, ok and "OK" or (fetch_err or "ERR"), true)
        end
    end, true)

    if not pid then
        logger.warn("Storefront: failed to launch background process for catalog fetch")
        if callback then callback(false, "subprocess launch failed") end
        return
    end

    CatalogClient._async_pid = pid

    local poll_func
    poll_func = function()
        if CatalogClient._async_pid ~= pid then
            -- Fetch was cancelled or superseded
            return
        end

        if ffiutil.isSubProcessDone(pid) then
            CatalogClient._async_pid = nil
            local file = io.open(tmp_file, "r")
            if not file then
                logger.warn("Storefront catalog async fetch failed: temp file missing")
                if callback then callback(false, "temp file missing") end
                return
            end
            local body = file:read("*all")
            file:close()
            os.remove(tmp_file)

            if not body or body == "" then
                logger.warn("Storefront catalog async fetch failed: empty response")
                if callback then callback(false, "empty response") end
                return
            end

            local ok_dec, parsed = pcall(json.decode, body)
            if not ok_dec or type(parsed) ~= "table" then
                logger.warn("Storefront catalog async fetch JSON decode failed", parsed)
                if callback then callback(false, "JSON decode error") end
                return
            end

            local ok_upd, upd_err = CatalogClient.updateCacheFromCatalog(parsed)
            if not ok_upd then
                logger.warn("Storefront catalog cache update failed", upd_err)
                if callback then callback(false, upd_err) end
                return
            end

            logger.info("Storefront: catalog async fetch and update completed successfully")
            if callback then callback(true, nil) end
        else
            UIManager:scheduleIn(1.0, poll_func)
        end
    end

    UIManager:scheduleIn(1.0, poll_func)
end

function CatalogClient.fetchAndUpdateCache(url_to_fetch)
    local GitHub = require("storefront_net_github")
    if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
        logger.info("Storefront: catalog fetch skipped in Direct API mode")
        return false, "Direct API mode active"
    end
    local catalog, err = CatalogClient.fetchCatalog(url_to_fetch)
    if not catalog then
        return false, err
    end
    local ok, update_err = CatalogClient.updateCacheFromCatalog(catalog)
    if not ok then
        return false, update_err
    end
    return true, nil
end

return CatalogClient

