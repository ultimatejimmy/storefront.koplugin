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
local USER_AGENT = "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)"

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

local FALLBACK_CATALOG_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront.koplugin/main/catalog.json"

function CatalogClient.fetchCatalog(url_to_fetch)
    local socketutil = require("socketutil")
    local socket = require("socket")
    local http = require("socket.http")

    local urls_to_try = {}
    if url_to_fetch then
        table.insert(urls_to_try, url_to_fetch)
    else
        table.insert(urls_to_try, CatalogClient.getCatalogUrl())
        table.insert(urls_to_try, FALLBACK_CATALOG_URL)
    end

    local last_err = "No catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        logger.info("Storefront: fetching static catalog from", target_url)
        local response_body = {}
        local headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = USER_AGENT,
        }

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok_req, res_code = pcall(function()
            local _, c = http.request{
                url = target_url,
                method = "GET",
                headers = headers,
                sink = newTableSink(response_body),
                redirect = true,
            }
            return c
        end)
        socketutil:reset_timeout()

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            local body = table.concat(response_body)
            local ok, parsed = pcall(json.decode, body)
            if ok and type(parsed) == "table" and parsed.plugins then
                return parsed, nil
            else
                logger.warn("Storefront catalog decode error from", target_url)
                last_err = "JSON decode error"
            end
        else
            local err_str = "Unknown error"
            if not ok_req then
                err_str = "pcall failed: " .. tostring(res_code)
            elseif tonumber(res_code) then
                err_str = "HTTP " .. tostring(res_code)
            elseif type(res_code) == "table" then
                local dump = "TableError{"
                for k, v in pairs(res_code) do
                    dump = dump .. tostring(k) .. "=" .. tostring(v) .. ", "
                end
                err_str = dump .. "}"
            else
                err_str = tostring(res_code)
            end
            logger.warn("Storefront catalog fetch error from", target_url, err_str)
            last_err = err_str
        end
    end

    return nil, last_err
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
    local socketutil = require("socketutil")
    local socket = require("socket")
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    local urls_to_try = {}
    if url_to_fetch then
        table.insert(urls_to_try, url_to_fetch)
    else
        table.insert(urls_to_try, CatalogClient.getCatalogUrl())
        table.insert(urls_to_try, FALLBACK_CATALOG_URL)
    end

    local last_err = "No catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        logger.info("Storefront: fetching catalog to file from", target_url)
        local file, err = io.open(dest_path, "w")
        if file then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = USER_AGENT,
            }

            local ok_req, res_code = pcall(function()
                local _, c = http.request{
                    url = target_url,
                    method = "GET",
                    headers = headers,
                    sink = socketutil.file_sink(file),
                    redirect = true,
                }
                return c
            end)
            file:close()
            socketutil:reset_timeout()

            local code = tonumber(res_code) or 0
            if ok_req and code == 200 then
                return true, nil
            else
                os.remove(dest_path)
                local err_str = "Unknown error"
                if not ok_req then
                    err_str = "pcall failed: " .. tostring(res_code)
                elseif tonumber(res_code) then
                    err_str = "HTTP " .. tostring(res_code)
                elseif type(res_code) == "table" then
                    local dump = "TableError{"
                    for k, v in pairs(res_code) do
                        dump = dump .. tostring(k) .. "=" .. tostring(v) .. ", "
                    end
                    err_str = dump .. "}"
                else
                    err_str = tostring(res_code)
                end
                logger.warn("Storefront catalog fetch to file error from", target_url, err_str)
                last_err = err_str
            end
        else
            logger.err("Storefront: failed to open dest_path for writing", err)
            last_err = "failed to open dest_path"
        end
    end

    return false, last_err
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
        local version = repo.version or (repo.latest_release and repo.latest_release.tag_name) or repo.release_tag_name or repo.tag_name
        table.insert(plugin_list, {
            repo_id = tonumber(repo.id or repo.repo_id) or 0,
            kind = "plugin",
            name = tostring(repo.name or ""),
            owner = getOwnerLogin(repo.owner),
            full_name = tostring(repo.full_name or ""),
            description = repo.description ~= json.null and tostring(repo.description or "") or "",
            stars = tonumber(repo.stargazers_count) or tonumber(repo.stars) or 0,
            language = repo.language ~= json.null and tostring(repo.language or "") or "",
            homepage = repo.homepage ~= json.null and tostring(repo.homepage or "") or "",
            version = version,
            latest_release = repo.latest_release,
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
        local ok, err = xpcall(function()
            pcall(require, "socketutil")
            local ok_dl, dl_err = CatalogClient.fetchCatalogToFile(target_url, staging_raw_catalog)
            if not ok_dl then
                if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_DOWNLOAD: " .. tostring(dl_err), true) end
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
                if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_PROC: " .. tostring(proc_err), true) end
                return
            end

            if child_write_fd then ffiutil.writeToFD(child_write_fd, "OK", true) end
        end, debug.traceback)

        if not ok then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_FATAL: " .. tostring(err), true) end
        end
    end, true)

    if not pid then
        logger.warn("Storefront: failed to launch background process for catalog fetch")
        local sync_ok, sync_err = CatalogClient.fetchAndUpdateCache(target_url)
        if callback then callback(sync_ok, sync_err) end
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

            local raw_msg = ffiutil.readFromFD and ffiutil.readFromFD(pid)
            local child_msg = (type(raw_msg) == "string" and raw_msg ~= "") and raw_msg or "SUBPROCESS_NO_MSG"
            logger.info("Storefront: catalog subprocess finished with msg:", tostring(child_msg))
            if StorefrontLogger then StorefrontLogger.info("Storefront: catalog subprocess finished with msg: " .. tostring(child_msg)) end

            local function safeReplace(src, dest)
                if not util.fileExists(src) then return false end
                os.remove(dest)
                local ok_ren = os.rename(src, dest)
                if ok_ren then return true end
                -- Fallback if rename fails
                local sf, s_err = io.open(src, "rb")
                if not sf then return false end
                local df, d_err = io.open(dest, "wb")
                if not df then sf:close(); return false end
                df:write(sf:read("*all"))
                sf:close()
                df:close()
                os.remove(src)
                return true
            end

            local ok_swap_p = safeReplace(staging_plugins_file, final_plugins_file)
            local ok_swap_pt = safeReplace(staging_patches_file, final_patches_file)

            if child_msg == "OK" and (ok_swap_p or ok_swap_pt) then
                Cache.invalidate()
                logger.info("Storefront: background catalog update finished and cache swap complete")
                if StorefrontLogger then StorefrontLogger.info("Storefront: background catalog update finished and cache swap complete") end
                if callback then callback(true, nil) end
            else
                logger.warn("Storefront catalog async fetch failed (msg: " .. tostring(child_msg) .. "), falling back to sync fetch")
                if StorefrontLogger then StorefrontLogger.warn("Storefront catalog async fetch failed (msg: " .. tostring(child_msg) .. "), falling back to sync fetch") end
                local sync_ok, sync_err = CatalogClient.fetchAndUpdateCache(target_url)
                if type(sync_err) == "table" then
                    local dump = ""
                    for k,v in pairs(sync_err) do
                        dump = dump .. tostring(k) .. "=" .. tostring(v) .. ", "
                    end
                    if StorefrontLogger then StorefrontLogger.warn("DEBUG sync_err table: " .. dump) end
                    sync_err = "Table Error: " .. dump
                end
                if callback then callback(sync_ok, sync_err) end
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

