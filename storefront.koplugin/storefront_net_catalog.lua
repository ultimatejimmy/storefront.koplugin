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

function CatalogClient.processCatalogDataToStaging(catalog_data, staging_plugins_file, staging_patches_file)
    if not catalog_data or type(catalog_data) ~= "table" then
        return false, "invalid catalog format"
    end
    
    local plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}
    local fetched_at = os.time()

    local function getOwnerLogin(owner)
        if type(owner) == "string" then return owner
        elseif type(owner) == "table" and owner.login then return tostring(owner.login)
        end
        return ""
    end

    local plugin_list = {}
    for _, repo in ipairs(plugins) do
        table.insert(plugin_list, {
            repo_id = tonumber(repo.id) or 0,
            kind = "plugin",
            name = tostring(repo.name or ""),
            owner = getOwnerLogin(repo.owner),
            full_name = tostring(repo.full_name or ""),
            description = repo.description ~= json.null and tostring(repo.description or "") or "",
            stars = tonumber(repo.stargazers_count) or tonumber(repo.stars) or 0,
            language = repo.language ~= json.null and tostring(repo.language or "") or "",
            homepage = repo.homepage ~= json.null and tostring(repo.homepage or "") or "",
            fetched_at = fetched_at,
            data = repo,
        })
    end

    local patch_list = {}
    for _, repo in ipairs(patches) do
        local repo_id = tonumber(repo.id) or 0
        local record = {
            repo_id = repo_id,
            kind = "patch",
            name = tostring(repo.name or ""),
            owner = getOwnerLogin(repo.owner),
            full_name = tostring(repo.full_name or ""),
            description = repo.description ~= json.null and tostring(repo.description or "") or "",
            stars = tonumber(repo.stargazers_count) or tonumber(repo.stars) or 0,
            language = repo.language ~= json.null and tostring(repo.language or "") or "",
            homepage = repo.homepage ~= json.null and tostring(repo.homepage or "") or "",
            fetched_at = fetched_at,
            data = repo,
            patch_files = {},
        }
        if repo.patch_files and type(repo.patch_files) == "table" then
            local pushed_at = repo.pushed_at or repo.updated_at or ""
            local patch_files = {}
            for _, entry in ipairs(repo.patch_files) do
                table.insert(patch_files, {
                    path = tostring(entry.path or ""),
                    filename = tostring(entry.filename or ""),
                    branch = tostring(entry.branch or ""),
                    sha = tostring(entry.sha or ""),
                    size = tonumber(entry.size) or 0,
                    download_url = tostring(entry.download_url or ""),
                    fetched_at = fetched_at,
                    source_pushed_at = tostring(pushed_at),
                })
            end
            record.patch_files = patch_files
        end
        table.insert(patch_list, record)
    end

    local plugin_data = { fetched_at = fetched_at, repos = plugin_list }
    local patch_data = { fetched_at = fetched_at, repos = patch_list }

    local ok_p, ser_p = pcall(json.encode, plugin_data)
    if not ok_p then return false, "plugin json encode failed" end
    local fp, err_p = io.open(staging_plugins_file, "w")
    if not fp then return false, "failed to write staging plugins" end
    fp:write(ser_p)
    fp:close()

    local ok_pt, ser_pt = pcall(json.encode, patch_data)
    if not ok_pt then return false, "patch json encode failed" end
    local fpt, err_pt = io.open(staging_patches_file, "w")
    if not fpt then return false, "failed to write staging patches" end
    fpt:write(ser_pt)
    fpt:close()

    return true, nil
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

    local staging_raw_catalog = cache_dir .. "/catalog_download.json.tmp"
    local staging_plugins_file = cache_dir .. "/storefront_plugins.json.tmp"
    local staging_patches_file = cache_dir .. "/storefront_patches.json.tmp"

    local final_plugins_file = cache_dir .. "/storefront_plugins.json"
    local final_patches_file = cache_dir .. "/storefront_patches.json"

    os.remove(staging_raw_catalog)
    os.remove(staging_plugins_file)
    os.remove(staging_patches_file)

    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        logger.warn("Storefront: ffiutil.runInSubProcess unavailable, falling back to sync fetch")
        local ok, err = CatalogClient.fetchAndUpdateCache(target_url)
        if callback then callback(ok, err) end
        return
    end

    -- Run download AND JSON decoding AND disk writing inside child subprocess
    local pid = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local ok_dl, dl_err = CatalogClient.fetchCatalogToFile(target_url, staging_raw_catalog)
        if not ok_dl then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_DOWNLOAD", true) end
            return
        end

        local f = io.open(staging_raw_catalog, "r")
        if not f then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_NOFILE", true) end
            return
        end
        local content = f:read("*all")
        f:close()
        os.remove(staging_raw_catalog)

        local ok_dec, parsed = pcall(json.decode, content)
        if not ok_dec or type(parsed) ~= "table" then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_DECODE", true) end
            return
        end

        local ok_proc, proc_err = CatalogClient.processCatalogDataToStaging(parsed, staging_plugins_file, staging_patches_file)
        if not ok_proc then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_PROC", true) end
            return
        end

        if child_write_fd then ffiutil.writeToFD(child_write_fd, "OK", true) end
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

            -- Main thread does ONLY an atomic file rename (< 1ms CPU time)
            local ok_rename_p = os.rename(staging_plugins_file, final_plugins_file)
            local ok_rename_pt = os.rename(staging_patches_file, final_patches_file)

            if ok_rename_p or ok_rename_pt then
                Cache.invalidate()
                logger.info("Storefront: background catalog update finished and atomic cache swap complete")
                if StorefrontLogger then StorefrontLogger.info("Storefront: background catalog update finished and atomic cache swap complete") end
                if callback then callback(true, nil) end
            else
                logger.warn("Storefront catalog async fetch failed: staged files missing or rename failed")
                if StorefrontLogger then StorefrontLogger.warn("Storefront catalog async fetch failed: staged files missing or rename failed") end
                if callback then callback(false, "staged rename failed") end
            end
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

