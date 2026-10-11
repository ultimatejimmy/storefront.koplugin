local json = require("json")
local logger = require("logger")
local Cache = require("storefront_cache")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = nil end

-- Pick the right http module based on URL scheme
local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

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

local StorefrontSettings = require("storefront_settings")
local CATALOG_URL_KEY = "catalog_url"
local CATALOG_ETAG_KEY = "catalog_etag"

function CatalogClient.getStoredEtag()
    local saved = StorefrontSettings:readSetting(CATALOG_ETAG_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    return nil
end

function CatalogClient.setStoredEtag(etag)
    if type(etag) == "string" and etag ~= "" then
        StorefrontSettings:saveSetting(CATALOG_ETAG_KEY, etag)
        StorefrontSettings:flush()
    end
end

function CatalogClient.clearStoredEtag()
    StorefrontSettings:delSetting(CATALOG_ETAG_KEY)
    StorefrontSettings:flush()
end

local DEFAULT_SCREENSAVER_CATALOG_URL = "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.unified.lite.json"
local FALLBACK_SCREENSAVER_CATALOG_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.unified.lite.json"
local LEGACY_SCREENSAVER_CATALOG_URL = "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.lite.json"
local SCREENSAVER_CATALOG_ETAG_KEY = "screensaver_catalog_etag"
local SCREENSAVER_CATALOG_LAST_FETCHED_KEY = "screensaver_catalog_last_fetched"

local DEFAULT_RB_CATALOG_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/readerbackdrop.lite.json"
local FALLBACK_RB_CATALOG_URL = "https://ultimatejimmy.github.io/storefront-screensavers/readerbackdrop.lite.json"
local RB_CATALOG_ETAG_KEY = "readerbackdrop_catalog_etag"

function CatalogClient.getStoredReaderBackdropEtag()
    local saved = StorefrontSettings:readSetting(RB_CATALOG_ETAG_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    return nil
end

function CatalogClient.setStoredReaderBackdropEtag(etag)
    if type(etag) == "string" and etag ~= "" then
        StorefrontSettings:saveSetting(RB_CATALOG_ETAG_KEY, etag)
        StorefrontSettings:flush()
    end
end

function CatalogClient.clearStoredReaderBackdropEtag()
    StorefrontSettings:delSetting(RB_CATALOG_ETAG_KEY)
    StorefrontSettings:flush()
end

function CatalogClient.getStoredScreensaverEtag()
    local saved = StorefrontSettings:readSetting(SCREENSAVER_CATALOG_ETAG_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    return nil
end

function CatalogClient.setStoredScreensaverEtag(etag)
    if type(etag) == "string" and etag ~= "" then
        StorefrontSettings:saveSetting(SCREENSAVER_CATALOG_ETAG_KEY, etag)
        StorefrontSettings:flush()
    end
end

function CatalogClient.clearStoredScreensaverEtag()
    StorefrontSettings:delSetting(SCREENSAVER_CATALOG_ETAG_KEY)
    StorefrontSettings:delSetting(SCREENSAVER_CATALOG_LAST_FETCHED_KEY)
    StorefrontSettings:delSetting(RB_CATALOG_ETAG_KEY)
    StorefrontSettings:flush()
end

function CatalogClient.getLastFetchedScreensavers()
    local saved = StorefrontSettings:readSetting(SCREENSAVER_CATALOG_LAST_FETCHED_KEY)
    return tonumber(saved) or 0
end

function CatalogClient.setLastFetchedScreensavers(timestamp)
    StorefrontSettings:saveSetting(SCREENSAVER_CATALOG_LAST_FETCHED_KEY, tonumber(timestamp) or os.time())
    StorefrontSettings:flush()
end

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
    CatalogClient.clearStoredEtag()
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

local function requestWithRedirects(target_url, sink_fn, extra_headers)
    local socketutil = require("socketutil")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local max_retries = 3
        local attempt = 0
        local last_res_code, last_headers_res, last_ok_req

        while attempt < max_retries do
            attempt = attempt + 1
            local is_https = current_url:match("^https://") ~= nil
            local http_req = getHttpModule(current_url)
            local headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = USER_AGENT,
            }
            if extra_headers then
                for k, v in pairs(extra_headers) do
                    headers[k] = v
                end
            end

            local sink = sink_fn()
            if not sink then
                return false, "failed to create sink", nil
            end

            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local ok_req, res_code, response_headers = pcall(function()
                local params = {
                    url = current_url,
                    method = "GET",
                    headers = headers,
                    sink = sink,
                }
                if not is_https then params.redirect = true end
                local _, c, h = http_req.request(params)
                return c, h
            end)
            socketutil:reset_timeout()

            last_ok_req = ok_req
            last_res_code = res_code
            last_headers_res = response_headers

            local code = tonumber(res_code) or 0
            if ok_req and (code == 200 or code == 304) then
                return true, code, response_headers
            elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
                break
            end
        end

        local code = tonumber(last_res_code) or 0
        if last_ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            local location = (type(last_headers_res) == "table") and (last_headers_res.location or last_headers_res.Location)
            if location and location ~= "" then
                if not location:match("^https?://") then
                    local scheme_host = current_url:match("^(https?://[^/]+)")
                    if scheme_host then
                        if location:sub(1,1) == "/" then
                            current_url = scheme_host .. location
                        else
                            current_url = scheme_host .. "/" .. location
                        end
                    end
                else
                    current_url = location
                end
                redirect_count = redirect_count + 1
            else
                return false, last_res_code, last_headers_res
            end
        else
            return false, last_res_code, last_headers_res
        end
    end
    return false, "too many redirects", nil
end

function CatalogClient.fetchCatalog(url_to_fetch)
    local urls_to_try = {}
    local primary_url = url_to_fetch or CatalogClient.getCatalogUrl()
    table.insert(urls_to_try, primary_url)
    if primary_url ~= FALLBACK_CATALOG_URL then
        table.insert(urls_to_try, FALLBACK_CATALOG_URL)
    end

    local etag = nil
    if Cache.countRepos("plugin") > 0 then
        etag = CatalogClient.getStoredEtag()
    end

    local last_err = "No catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        logger.info("Storefront: fetching static catalog from", target_url)
        local response_body = {}
        local sink_fn = function()
            response_body = {}
            return newTableSink(response_body)
        end

        local extra_headers = nil
        if etag and etag ~= "" and target_url == primary_url then
            extra_headers = { ["If-None-Match"] = etag }
        end

        local ok, res_code, res_headers = requestWithRedirects(target_url, sink_fn, extra_headers)
        local code = tonumber(res_code) or 0
        if ok and code == 304 then
            logger.info("Storefront: catalog unchanged (HTTP 304) from", target_url)
            return "not_modified", nil
        elseif ok and code == 200 then
            local new_etag = res_headers and (res_headers.etag or res_headers.ETag or res_headers["etag"])
            if type(new_etag) == "string" and new_etag ~= "" then
                CatalogClient.setStoredEtag(new_etag)
            end
            local body = table.concat(response_body)
            local ok_dec, parsed = pcall(json.decode, body)
            if ok_dec and type(parsed) == "table" and parsed.plugins then
                return parsed, nil
            else
                logger.warn("Storefront catalog decode error from", target_url)
                last_err = "JSON decode error"
            end
        else
            local err_str = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            logger.warn("Storefront catalog fetch error from", target_url, err_str)
            last_err = err_str
        end
    end

    return nil, last_err
end

function CatalogClient.updateCacheFromCatalog(catalog_data, is_bundled)
    if not catalog_data or type(catalog_data) ~= "table" then
        return false, "invalid catalog format"
    end
    
    local plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}
    local fonts   = catalog_data.fonts or {}
    
    if #patches == 0 then
        local existing_patches = Cache.listRepos("patch")
        if existing_patches and #existing_patches > 0 then
            patches = existing_patches
        end
    end

    local custom_fetched_at = is_bundled and 0 or nil
    logger.info("Storefront: updating cache from static catalog", "plugins:", #plugins, "patches:", #patches, "fonts:", #fonts, "is_bundled:", tostring(is_bundled))

    
    -- Store plugin repositories
    Cache.storeRepos("plugin", plugins, custom_fetched_at)
    
    -- Store patch repositories
    Cache.storeRepos("patch", patches, custom_fetched_at)
    
    -- Store font repositories
    Cache.storeRepos("font", fonts, custom_fetched_at)
    
    -- Store patch file metadata for patch repositories
    local has_patch_files = false
    for _, repo in ipairs(patches) do
        local repo_id = tonumber(repo.repo_id or repo.id)
        if repo_id and repo.patch_files and type(repo.patch_files) == "table" then
            local pushed_at = repo.pushed_at or repo.updated_at or ""
            Cache.storePatchFiles(repo_id, repo.patch_files, pushed_at, true)
            has_patch_files = true
        end
    end
    if has_patch_files and Cache.savePatchFiles then
        Cache.savePatchFiles()
    end
    
    return true, nil
end

function CatalogClient.fetchCatalogToFile(url_to_fetch, dest_path)
    local urls_to_try = {}
    local primary_url = url_to_fetch or CatalogClient.getCatalogUrl()
    table.insert(urls_to_try, primary_url)
    if primary_url ~= FALLBACK_CATALOG_URL then
        table.insert(urls_to_try, FALLBACK_CATALOG_URL)
    end

    local etag = nil
    if Cache.countRepos("plugin") > 0 then
        etag = CatalogClient.getStoredEtag()
    end

    local last_err = "No catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        logger.info("Storefront: fetching catalog to file from", target_url)
        local current_file = nil
        local sink_fn = function()
            if current_file then pcall(function() current_file:close() end) end
            os.remove(dest_path)
            local f, err = io.open(dest_path, "wb")
            if not f then
                logger.err("Storefront: failed to open dest_path for writing", err)
                return nil
            end
            current_file = f
            return require("socketutil").file_sink(f)
        end

        local extra_headers = nil
        if etag and etag ~= "" and target_url == primary_url then
            extra_headers = { ["If-None-Match"] = etag }
        end

        local ok, res_code, res_headers = requestWithRedirects(target_url, sink_fn, extra_headers)
        if current_file then pcall(function() current_file:close() end); current_file = nil end

        local code = tonumber(res_code) or 0
        if ok and code == 304 then
            os.remove(dest_path)
            logger.info("Storefront: catalog unchanged (HTTP 304 Not Modified) from", target_url)
            return true, "not_modified"
        elseif ok and code == 200 then
            local new_etag = res_headers and (res_headers.etag or res_headers.ETag or res_headers["etag"])
            if type(new_etag) == "string" and new_etag ~= "" then
                CatalogClient.setStoredEtag(new_etag)
            end
            return true, "updated"
        else
            os.remove(dest_path)
            local err_str = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            logger.warn("Storefront catalog fetch to file error from", target_url, err_str)
            last_err = err_str
        end
    end

    return false, last_err
end

function CatalogClient.fetchScreensaverCatalogToFile(dest_path)
    local urls_to_try = {
        DEFAULT_SCREENSAVER_CATALOG_URL,
        FALLBACK_SCREENSAVER_CATALOG_URL,
        LEGACY_SCREENSAVER_CATALOG_URL,
    }

    local final_cat_path = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
    local etag = nil
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(final_cat_path, "mode") == "file" then
        etag = CatalogClient.getStoredScreensaverEtag()
    end

    local last_err = "No screensaver catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        local extra_headers = nil
        if etag and etag ~= "" and target_url == DEFAULT_SCREENSAVER_CATALOG_URL then
            extra_headers = { ["If-None-Match"] = etag }
        end

        logger.info("Storefront: fetching screensaver catalog to file from", target_url)
        if StorefrontLogger then
            StorefrontLogger.info("Storefront: fetching screensavers catalog from " .. tostring(target_url) .. (extra_headers and " (with ETag)" or ""))
        end
        local current_file = nil
        local sink_fn = function()
            if current_file then pcall(function() current_file:close() end) end
            os.remove(dest_path)
            local f, err = io.open(dest_path, "wb")
            if not f then
                logger.err("Storefront: failed to open dest_path for screensaver writing", err)
                if StorefrontLogger then StorefrontLogger.err("Storefront: failed to open dest_path for screensaver writing: " .. tostring(err)) end
                return nil
            end
            current_file = f
            return require("socketutil").file_sink(f)
        end

        local ok, res_code, res_headers = requestWithRedirects(target_url, sink_fn, extra_headers)
        if current_file then pcall(function() current_file:close() end); current_file = nil end

        local code = tonumber(res_code) or 0
        if ok and code == 304 then
            os.remove(dest_path)
            logger.info("Storefront: screensaver catalog unchanged (HTTP 304 Not Modified) from", target_url)
            if StorefrontLogger then StorefrontLogger.info("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified)") end
            return true, "not_modified"
        elseif ok and code == 200 then
            local new_etag = res_headers and (res_headers.etag or res_headers.ETag or res_headers["etag"])
            if type(new_etag) == "string" and new_etag ~= "" then
                CatalogClient.setStoredScreensaverEtag(new_etag)
            end
            if StorefrontLogger then StorefrontLogger.info("Storefront: screensavers catalog downloaded successfully (HTTP 200)") end
            return true, "updated"
        else
            os.remove(dest_path)
            local err_str = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            logger.warn("Storefront screensaver catalog fetch error from", target_url, err_str)
            if StorefrontLogger then StorefrontLogger.warn("Storefront: screensavers catalog fetch error from " .. tostring(target_url) .. ": " .. tostring(err_str)) end
            last_err = err_str
        end
    end

    return false, last_err
end

function CatalogClient.fetchReaderBackdropCatalogToFile(dest_path)
    local urls_to_try = {
        DEFAULT_RB_CATALOG_URL,
        FALLBACK_RB_CATALOG_URL,
    }

    local final_cat_path = DataStorage:getDataDir() .. "/cache/storefront_readerbackdrop_catalog.json"
    local etag = nil
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(final_cat_path, "mode") == "file" then
        etag = CatalogClient.getStoredReaderBackdropEtag()
    end

    local last_err = "No ReaderBackdrop catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        local extra_headers = nil
        if etag and etag ~= "" and target_url == DEFAULT_RB_CATALOG_URL then
            extra_headers = { ["If-None-Match"] = etag }
        end

        logger.info("Storefront: fetching ReaderBackdrop catalog to file from", target_url)
        if StorefrontLogger then
            StorefrontLogger.info("Storefront: fetching ReaderBackdrop catalog from " .. tostring(target_url) .. (extra_headers and " (with ETag)" or ""))
        end
        local current_file = nil
        local sink_fn = function()
            if current_file then pcall(function() current_file:close() end) end
            os.remove(dest_path)
            local f, err = io.open(dest_path, "wb")
            if not f then
                logger.err("Storefront: failed to open dest_path for RB catalog writing", err)
                if StorefrontLogger then StorefrontLogger.err("Storefront: failed to open dest_path for RB catalog writing: " .. tostring(err)) end
                return nil
            end
            current_file = f
            return require("socketutil").file_sink(f)
        end

        local ok, res_code, res_headers = requestWithRedirects(target_url, sink_fn, extra_headers)
        if current_file then pcall(function() current_file:close() end); current_file = nil end

        local code = tonumber(res_code) or 0
        if ok and code == 304 then
            os.remove(dest_path)
            logger.info("Storefront: ReaderBackdrop catalog unchanged (HTTP 304 Not Modified) from", target_url)
            if StorefrontLogger then StorefrontLogger.info("Storefront: ReaderBackdrop catalog unchanged (HTTP 304 Not Modified)") end
            return true, "not_modified"
        elseif ok and code == 200 then
            local new_etag = res_headers and (res_headers.etag or res_headers.ETag or res_headers["etag"])
            if type(new_etag) == "string" and new_etag ~= "" then
                CatalogClient.setStoredReaderBackdropEtag(new_etag)
            end
            if StorefrontLogger then StorefrontLogger.info("Storefront: ReaderBackdrop catalog downloaded successfully (HTTP 200)") end
            return true, "updated"
        else
            os.remove(dest_path)
            local err_str = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            logger.warn("Storefront: ReaderBackdrop catalog fetch error from", target_url, err_str)
            if StorefrontLogger then StorefrontLogger.warn("Storefront: ReaderBackdrop catalog fetch error from " .. tostring(target_url) .. ": " .. tostring(err_str)) end
            last_err = err_str
        end
    end

    return false, last_err
end



function CatalogClient.fetchScreensaverCatalog(url_to_fetch)
    local urls_to_try = {
        url_to_fetch or DEFAULT_SCREENSAVER_CATALOG_URL,
        FALLBACK_SCREENSAVER_CATALOG_URL,
    }
    local final_cat_path = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
    local etag = nil
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(final_cat_path, "mode") == "file" then
        etag = CatalogClient.getStoredScreensaverEtag()
    end

    local last_err = "No screensaver catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        local response_body = {}
        local sink_fn = function()
            response_body = {}
            return newTableSink(response_body)
        end

        local extra_headers = nil
        if etag and etag ~= "" and target_url == urls_to_try[1] then
            extra_headers = { ["If-None-Match"] = etag }
        end

        logger.info("Storefront: fetching screensaver catalog from", target_url)
        if StorefrontLogger then
            StorefrontLogger.info("Storefront: fetching screensavers catalog from " .. tostring(target_url) .. (extra_headers and " (with ETag)" or ""))
        end

        local ok, res_code, res_headers = requestWithRedirects(target_url, sink_fn, extra_headers)
        local code = tonumber(res_code) or 0
        if ok and code == 304 then
            logger.info("Storefront: screensaver catalog unchanged (HTTP 304) from", target_url)
            if StorefrontLogger then StorefrontLogger.info("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified)") end
            return "not_modified", nil
        elseif ok and code == 200 then
            local new_etag = res_headers and (res_headers.etag or res_headers.ETag or res_headers["etag"])
            if type(new_etag) == "string" and new_etag ~= "" then
                CatalogClient.setStoredScreensaverEtag(new_etag)
            end
            local body = table.concat(response_body)
            local ok_dec, parsed = pcall(json.decode, body)
            if ok_dec and type(parsed) == "table" and #parsed > 0 then
                if StorefrontLogger then StorefrontLogger.info(string.format("Storefront: screensavers catalog downloaded and parsed (%d items)", #parsed)) end
                return parsed, nil
            else
                last_err = "Failed to parse screensaver catalog JSON"
                if StorefrontLogger then StorefrontLogger.warn("Storefront: failed to parse screensaver catalog JSON") end
            end
        else
            last_err = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            if StorefrontLogger then StorefrontLogger.warn("Storefront: screensavers catalog fetch error from " .. tostring(target_url) .. ": " .. tostring(last_err)) end
        end
    end
    return nil, last_err
end

function CatalogClient.cancelAsyncFetch()
    local UIManager = require("ui/uimanager")
    if CatalogClient._poll_func then
        UIManager:unschedule(CatalogClient._poll_func)
        CatalogClient._poll_func = nil
    end
    if CatalogClient._poll_fd then
        pcall(function()
            local ok_ffi, ffiutil = pcall(require, "ffi/util")
            if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end
            if ok_ffi and ffiutil then
                local read_fn = ffiutil.readAllFromFD or ffiutil.readFromFD
                if read_fn then pcall(read_fn, CatalogClient._poll_fd) end
            end
        end)
        CatalogClient._poll_fd = nil
    end
    if CatalogClient._async_pid then
        local pid = CatalogClient._async_pid
        CatalogClient._async_pid = nil
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end
        if ok_ffi and ffiutil then
            if ffiutil.terminateSubProcess then
                pcall(ffiutil.terminateSubProcess, pid)
            end
            if ffiutil.isSubProcessDone then
                pcall(ffiutil.isSubProcessDone, pid, true)
            end
        end
    end

    pcall(function()
        local DataStorage = require("datastorage")
        local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
        os.remove(cache_dir .. "/catalog_download.json.tmp")
        os.remove(cache_dir .. "/storefront_plugins.json.tmp")
        os.remove(cache_dir .. "/storefront_patches.json.tmp")
        os.remove(cache_dir .. "/storefront_fonts.json.tmp")
        os.remove(cache_dir .. "/storefront_screensavers_catalog.json.tmp")
        os.remove(cache_dir .. "/storefront_readerbackdrop_catalog.json.tmp")
    end)
end
CatalogClient.cancelCatalogFetch = CatalogClient.cancelAsyncFetch

function CatalogClient.isRefreshing()
    if CatalogClient._async_pid then
        return true
    end
    return false
end

function CatalogClient.processCatalogDataToStaging(catalog_data, staging_plugins_file, staging_patches_file, staging_fonts_file)
    if not catalog_data or type(catalog_data) ~= "table" then
        return false, "invalid catalog format"
    end
    
    local fetched_at = os.time()

    local function getOwnerLogin(owner)
        if type(owner) == "string" then return owner
        elseif type(owner) == "table" and owner.login then return tostring(owner.login)
        end
        return ""
    end

    -- 1. Plugins Stage: process and write first, then release
    local plugins = catalog_data.plugins or {}
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
            user_thumbs_up = tonumber(repo.user_thumbs_up or (repo.data and repo.data.user_thumbs_up)) or 0,
            user_thumbs_down = tonumber(repo.user_thumbs_down or (repo.data and repo.data.user_thumbs_down)) or 0,
            wilson_score = tonumber(repo.wilson_score or (repo.data and repo.data.wilson_score)) or 0,
            downloads = tonumber(repo.downloads or (repo.data and repo.data.downloads)) or 0,
            fetched_at = fetched_at,
            data = repo,
        })
    end
    catalog_data.plugins = nil
    plugins = nil

    local plugin_data = { fetched_at = fetched_at, repos = plugin_list }
    local ok_p, ser_p = pcall(json.encode, plugin_data)
    plugin_list = nil
    plugin_data = nil
    if not ok_p then return false, "plugin json encode failed" end
    local fp, err_p = io.open(staging_plugins_file, "w")
    if not fp then return false, "failed to write staging plugins" end
    fp:write(ser_p)
    fp:close()
    ser_p = nil
    collectgarbage("collect")

    -- 2. Patches Stage: process and write second, then release
    local patches = catalog_data.patches or {}
    if #patches == 0 then
        local bundled_path = CatalogClient.getBundledCatalogPath()
        if bundled_path then
            local bf = io.open(bundled_path, "rb")
            if bf then
                local bc = bf:read("*all")
                bf:close()
                local ok_b, bundled = pcall(json.decode, bc)
                bc = nil
                if ok_b and type(bundled) == "table" and type(bundled.patches) == "table" and #bundled.patches > 0 then
                    patches = bundled.patches
                end
                bundled = nil
                collectgarbage("collect")
            end
        end
        if #patches == 0 then
            local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
            local existing_patches_file = cache_dir .. "/storefront_patches.json"
            local ef = io.open(existing_patches_file, "rb")
            if ef then
                local ec = ef:read("*all")
                ef:close()
                local ok_e, existing = pcall(json.decode, ec)
                ec = nil
                if ok_e and type(existing) == "table" and type(existing.repos) == "table" and #existing.repos > 0 then
                    patches = existing.repos
                end
                existing = nil
                collectgarbage("collect")
            end
        end
    end

    local patch_list = {}
    for _, repo in ipairs(patches) do
        local repo_id = tonumber(repo.id or repo.repo_id) or 0
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
            user_thumbs_up = tonumber(repo.user_thumbs_up or (repo.data and repo.data.user_thumbs_up)) or 0,
            user_thumbs_down = tonumber(repo.user_thumbs_down or (repo.data and repo.data.user_thumbs_down)) or 0,
            wilson_score = tonumber(repo.wilson_score or (repo.data and repo.data.wilson_score)) or 0,
            downloads = tonumber(repo.downloads or (repo.data and repo.data.downloads)) or 0,
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
    catalog_data.patches = nil
    patches = nil

    local patch_data = { fetched_at = fetched_at, repos = patch_list }
    local ok_pt, ser_pt = pcall(json.encode, patch_data)
    patch_list = nil
    patch_data = nil
    if not ok_pt then return false, "patch json encode failed" end
    local fpt, err_pt = io.open(staging_patches_file, "w")
    if not fpt then return false, "failed to write staging patches" end
    fpt:write(ser_pt)
    fpt:close()
    ser_pt = nil
    collectgarbage("collect")

    -- 3. Fonts Stage: process and write third, then release
    local fonts = {}
    local bundled_path = CatalogClient.getBundledCatalogPath()
    if bundled_path then
        local bf = io.open(bundled_path, "rb")
        if bf then
            local bc = bf:read("*all")
            bf:close()
            local ok_b, bundled = pcall(json.decode, bc)
            bc = nil
            if ok_b and type(bundled) == "table" and type(bundled.fonts) == "table" then
                fonts = bundled.fonts
            end
            bundled = nil
            collectgarbage("collect")
        end
    end
    if #fonts == 0 then
        fonts = catalog_data.fonts or {}
    end
    catalog_data.fonts = nil

    if staging_fonts_file then
        local font_list = {}
        for _, repo in ipairs(fonts) do
            table.insert(font_list, {
                repo_id = tonumber(repo.id or repo.repo_id) or 0,
                kind = "font",
                name = tostring(repo.name or ""),
                font_family = tostring(repo.font_family or repo.name or ""),
                font_file = tostring(repo.font_file or ""),
                owner = getOwnerLogin(repo.owner),
                full_name = tostring(repo.full_name or ""),
                description = repo.description ~= json.null and tostring(repo.description or "") or "",
                category = tostring(repo.category or "Serif"),
                license = tostring(repo.license or "OFL"),
                stars = tonumber(repo.stargazers_count) or tonumber(repo.stars) or 0,
                download_url = tostring(repo.download_url or ""),
                html_url = tostring(repo.html_url or ""),
                fetched_at = fetched_at,
                data = repo,
            })
        end
        fonts = nil

        local font_data = { fetched_at = fetched_at, repos = font_list }
        local ok_f, ser_f = pcall(json.encode, font_data)
        font_list = nil
        font_data = nil
        if not ok_f then return false, "font json encode failed" end
        local ff, err_f = io.open(staging_fonts_file, "w")
        if not ff then return false, "failed to write staging fonts" end
        ff:write(ser_f)
        ff:close()
        ser_f = nil
        collectgarbage("collect")
    end

    return true, nil
end

function CatalogClient.fetchAndUpdateCacheAsync(url_to_fetch, callback, is_background)
    local GitHub = require("storefront_net_github")
    if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
        logger.info("Storefront: skipping background catalog update because Direct API mode is active")
        if callback then callback(false, "Direct API mode active") end
        return
    end

    if is_background then
        local StorefrontUtils = require("storefront_utils")
        local is_low, avail_kb = StorefrontUtils.isLowMemory()
        if is_low then
            local msg = string.format("Storefront: available memory is critically low (%d KB), skipping background catalog fetch to prevent OOM", avail_kb or 0)
            logger.warn(msg)
            if StorefrontLogger then StorefrontLogger.warn(msg) end
            if callback then callback(false, "low_memory") end
            return
        end
    end

    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and ((Device.isSuspended and Device:isSuspended()) or Device.screen_saver_mode) then
        logger.info("Storefront: skipping catalog fetch because device is suspended or in screensaver mode")
        if callback then callback(false, "device_suspended") end
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
    local ss_target_url = DEFAULT_SCREENSAVER_CATALOG_URL
    logger.info("Storefront: starting background catalog fetch from", target_url, "and screensavers from", ss_target_url)
    if StorefrontLogger then
        StorefrontLogger.info(string.format("Storefront: starting background catalog fetch (catalog: %s, screensavers: %s)", tostring(target_url), tostring(ss_target_url)))
    end

    local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
    util.makePath(cache_dir)

    local staging_raw_catalog = cache_dir .. "/catalog_download.json.tmp"
    local staging_plugins_file = cache_dir .. "/storefront_plugins.json.tmp"
    local staging_patches_file = cache_dir .. "/storefront_patches.json.tmp"
    local staging_fonts_file = cache_dir .. "/storefront_fonts.json.tmp"
    local staging_screensavers_file = cache_dir .. "/storefront_screensavers_catalog.json.tmp"
    local staging_rb_file = cache_dir .. "/storefront_readerbackdrop_catalog.json.tmp"

    local final_plugins_file = cache_dir .. "/storefront_plugins.json"
    local final_patches_file = cache_dir .. "/storefront_patches.json"
    local final_fonts_file = cache_dir .. "/storefront_fonts.json"
    local final_screensavers_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
    local final_rb_file = DataStorage:getDataDir() .. "/cache/storefront_readerbackdrop_catalog.json"

    os.remove(staging_raw_catalog)
    os.remove(staging_plugins_file)
    os.remove(staging_patches_file)
    os.remove(staging_fonts_file)
    os.remove(staging_screensavers_file)
    os.remove(staging_rb_file)

    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        logger.warn("Storefront: ffiutil.runInSubProcess unavailable, falling back to sync catalog fetch")
        local ok_dl, catalog_data_or_err = pcall(function() return CatalogClient.fetchCatalog(target_url) end)
        local ok_ss, ss_data_or_err = pcall(function() return CatalogClient.fetchScreensaverCatalog() end)

        local main_not_mod = (ok_dl and catalog_data_or_err == "not_modified")
        local ss_not_mod = (ok_ss and ss_data_or_err == "not_modified")

        if main_not_mod and ss_not_mod then
            CatalogClient.setLastFetchedScreensavers(os.time())
            local ok_c, Cache = pcall(require, "storefront_cache")
            if ok_c and Cache and Cache.touchLastFetched then
                Cache.touchLastFetched(os.time())
            end
            logger.info("Storefront: catalog unchanged (HTTP 304 Not Modified)")
            if StorefrontLogger then StorefrontLogger.info("Storefront: catalog unchanged (HTTP 304 Not Modified)") end
            if callback then callback(true, "not_modified") end
            return
        end

        local updated = false
        if ok_dl and catalog_data_or_err ~= "not_modified" and catalog_data_or_err then
            local ok_update, err_update = CatalogClient.updateCacheFromCatalog(catalog_data_or_err)
            if ok_update then updated = true end
        end

        if ok_ss and ss_data_or_err ~= "not_modified" and type(ss_data_or_err) == "table" and #ss_data_or_err > 0 then
            local ser_ss_ok, ser_ss = pcall(json.encode, ss_data_or_err)
            if ser_ss_ok and ser_ss then
                local sf = io.open(final_screensavers_file, "w")
                if sf then
                    sf:write(ser_ss)
                    sf:close()
                    updated = true
                    CatalogClient.setLastFetchedScreensavers(os.time())
                    pcall(function()
                        local ok_ss_ui, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                        if ok_ss_ui and StorefrontScreensavers and StorefrontScreensavers.invalidateMemCache then
                            StorefrontScreensavers.invalidateMemCache()
                        end
                    end)
                end
            end
        end

        -- Sync-fetch ReaderBackdrop catalog
        local rb_not_mod = false
        pcall(function()
            local ok_rb, rb_status = CatalogClient.fetchReaderBackdropCatalogToFile(final_rb_file)
            if ok_rb and rb_status == "updated" then
                updated = true
                CatalogClient.setLastFetchedScreensavers(os.time())
                pcall(function()
                    local ok_ss_ui, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                    if ok_ss_ui and StorefrontScreensavers and StorefrontScreensavers.invalidateMemCache then
                        StorefrontScreensavers.invalidateMemCache()
                    end
                end)
                if StorefrontLogger then StorefrontLogger.info("Storefront: ReaderBackdrop catalog synced (sync fallback)") end
            elseif ok_rb and rb_status == "not_modified" then
                rb_not_mod = true
            end
        end)

        if updated or main_not_mod or ss_not_mod or rb_not_mod then
            if callback then callback(true, updated and "updated" or "not_modified") end
        else
            local err_str = type(catalog_data_or_err) == "string" and catalog_data_or_err or tostring(catalog_data_or_err)
            if callback then callback(false, "Sync catalog fetch failed: " .. err_str) end
        end
        return
    end

    -- Run download AND JSON decoding AND disk writing inside child subprocess
    local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local ok, err = xpcall(function()
            collectgarbage("collect")
            local ok_dl, dl_status_or_err = CatalogClient.fetchCatalogToFile(target_url, staging_raw_catalog)
            local ok_ss, ss_status_or_err = CatalogClient.fetchScreensaverCatalogToFile(staging_screensavers_file)
            local ok_rb, rb_status_or_err = CatalogClient.fetchReaderBackdropCatalogToFile(staging_rb_file)

            local main_not_mod = (ok_dl and dl_status_or_err == "not_modified")
            local ss_not_mod = (ok_ss and ss_status_or_err == "not_modified")
            local rb_not_mod = (ok_rb and rb_status_or_err == "not_modified")

            if main_not_mod and ss_not_mod and rb_not_mod then
                if child_write_fd then ffiutil.writeToFD(child_write_fd, "OK_NOT_MODIFIED", true) end
                return
            end

            if not ok_dl and not main_not_mod then
                logger.warn("Storefront: remote catalog download failed (" .. tostring(dl_status_or_err) .. "), attempting fallback to bundled catalog")
                local bundled_path = CatalogClient.getBundledCatalogPath()
                if bundled_path then
                    local bf = io.open(bundled_path, "rb")
                    if bf then
                        local df = io.open(staging_raw_catalog, "wb")
                        if df then
                            df:write(bf:read("*all"))
                            df:close()
                            ok_dl = true
                            dl_status_or_err = "updated"
                        end
                        bf:close()
                        collectgarbage("collect")
                    end
                end
            end

            local main_proc_ok = false
            if ok_dl and dl_status_or_err == "updated" then
                local f = io.open(staging_raw_catalog, "rb")
                if f then
                    local content = f:read("*all")
                    f:close()
                    os.remove(staging_raw_catalog)

                    local ok_dec, parsed = pcall(json.decode, content)
                    content = nil
                    collectgarbage("collect")

                    if ok_dec and type(parsed) == "table" then
                        local ok_proc, proc_err = CatalogClient.processCatalogDataToStaging(parsed, staging_plugins_file, staging_patches_file, staging_fonts_file)
                        parsed = nil
                        collectgarbage("collect")
                        if ok_proc then
                            main_proc_ok = true
                        else
                            logger.warn("Storefront: failed to process catalog data to staging:", proc_err)
                        end
                    end
                end
            end

            local ss_proc_ok = false
            if ok_ss and ss_status_or_err == "updated" then
                local f_ss = io.open(staging_screensavers_file, "rb")
                if f_ss then
                    local ss_content = f_ss:read("*all")
                    f_ss:close()
                    local ok_dec_ss, parsed_ss = pcall(json.decode, ss_content)
                    ss_content = nil
                    if ok_dec_ss and type(parsed_ss) == "table" and #parsed_ss > 0 then
                        ss_proc_ok = true
                    else
                        os.remove(staging_screensavers_file)
                    end
                    parsed_ss = nil
                    collectgarbage("collect")
                end
            end

            -- Validate RB staging file
            local rb_proc_ok = false
            if ok_rb and rb_status_or_err == "updated" then
                local f_rb = io.open(staging_rb_file, "rb")
                if f_rb then
                    local rb_content = f_rb:read("*all")
                    f_rb:close()
                    local ok_dec_rb, parsed_rb = pcall(json.decode, rb_content)
                    rb_content = nil
                    if ok_dec_rb and type(parsed_rb) == "table" and #parsed_rb > 0 then
                        rb_proc_ok = true
                        if StorefrontLogger then
                            StorefrontLogger.info(string.format("Storefront: ReaderBackdrop catalog validated (%d items)", #parsed_rb))
                        end
                    else
                        os.remove(staging_rb_file)
                    end
                    parsed_rb = nil
                    collectgarbage("collect")
                end
            end

            collectgarbage("collect")

            local res_main = main_proc_ok and "updated" or (main_not_mod and "not_modified" or ("err:" .. tostring(dl_status_or_err)))
            local res_ss = ss_proc_ok and "updated" or (ss_not_mod and "not_modified" or ("err:" .. tostring(ss_status_or_err)))
            local res_rb = rb_proc_ok and "updated" or (rb_not_mod and "not_modified" or ("err:" .. tostring(rb_status_or_err)))

            local result_msg
            if main_not_mod and ss_not_mod and rb_not_mod then
                result_msg = "OK_NOT_MODIFIED"
            elseif main_proc_ok or ss_proc_ok or rb_proc_ok or (main_not_mod and ss_proc_ok) or (main_proc_ok and ss_not_mod) then
                result_msg = string.format("OK:main=%s,ss=%s,rb=%s", res_main, res_ss, res_rb)
            elseif main_not_mod or ss_not_mod or rb_not_mod then
                result_msg = string.format("OK_NOT_MODIFIED:main=%s,ss=%s,rb=%s", res_main, res_ss, res_rb)
            else
                result_msg = "ERR_DOWNLOAD: " .. tostring(dl_status_or_err)
            end
            if child_write_fd then ffiutil.writeToFD(child_write_fd, result_msg, true) end
        end, debug.traceback)

        if not ok then
            if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_FATAL: " .. tostring(err), true) end
        end
    end, true)

    if not pid then
        logger.warn("Storefront: failed to launch background process for catalog fetch")
        if StorefrontLogger then StorefrontLogger.warn("Storefront: failed to launch background process for catalog fetch") end
        if callback then callback(false, "Failed to launch background process") end
        return
    end

    CatalogClient._async_pid = pid
    CatalogClient._poll_fd = parent_read_fd

    local poll_attempts = 0
    local MAX_POLL_ATTEMPTS = 120  -- 2-minute hard ceiling
    local poll_func
    poll_func = function()
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device and ((Device.isSuspended and Device:isSuspended()) or Device.screen_saver_mode) then
            logger.info("Storefront: device entered suspend during catalog fetch, cancelling subprocess")
            CatalogClient.cancelCatalogFetch()
            if callback then callback(false, "device_suspended") end
            return
        end

        poll_attempts = poll_attempts + 1
        if poll_attempts > MAX_POLL_ATTEMPTS then
            CatalogClient.cancelCatalogFetch()
            logger.warn("Storefront: catalog subprocess timed out after 120s, aborting poll and terminating child")
            if StorefrontLogger then StorefrontLogger.warn("Storefront: catalog subprocess timed out") end
            if callback then callback(false, "subprocess timeout") end
            return
        end

        if CatalogClient._async_pid ~= pid then
            -- Fetch was cancelled or superseded
            if parent_read_fd and (ffiutil.readAllFromFD or ffiutil.readFromFD) then
                local close_func = ffiutil.readAllFromFD or ffiutil.readFromFD
                close_func(parent_read_fd)
            end
            CatalogClient._poll_func = nil
            CatalogClient._poll_fd = nil
            return
        end

        if ffiutil.isSubProcessDone(pid) then
            CatalogClient._async_pid = nil
            CatalogClient._poll_func = nil
            CatalogClient._poll_fd = nil

            local read_func = ffiutil.readAllFromFD or ffiutil.readFromFD
            local ok_read, raw_msg = pcall(function()
                if read_func and parent_read_fd then
                    return read_func(parent_read_fd)
                elseif read_func then
                    return read_func(pid)
                end
            end)
            local child_msg = (ok_read and type(raw_msg) == "string" and raw_msg ~= "") and raw_msg or "SUBPROCESS_NO_MSG"
            logger.info("Storefront: catalog subprocess finished with msg:", tostring(child_msg))
            if StorefrontLogger then StorefrontLogger.info("Storefront: catalog subprocess finished with msg: " .. tostring(child_msg)) end

            local function safeReplace(src, dest)
                local f_test = io.open(src, "rb")
                if not f_test then return false end
                f_test:close()
                os.remove(dest)
                local ok_ren = os.rename(src, dest)
                if ok_ren then return true end
                -- Fallback if rename fails (e.g. FAT32 lock)
                local sf, s_err = io.open(src, "rb")
                if not sf then return false end
                local df, d_err = io.open(dest, "wb")
                if not df then sf:close(); return false end
                
                while true do
                    local chunk = sf:read(16384)
                    if not chunk then break end
                    df:write(chunk)
                end
                
                sf:close()
                df:close()
                os.remove(src)
                return true
            end

            local ok_swap_p = safeReplace(staging_plugins_file, final_plugins_file)
            local ok_swap_pt = safeReplace(staging_patches_file, final_patches_file)
            local ok_swap_f = safeReplace(staging_fonts_file, final_fonts_file)
            local ok_swap_ss = safeReplace(staging_screensavers_file, final_screensavers_file)
            local ok_swap_rb = safeReplace(staging_rb_file, final_rb_file)

            local is_ok_not_modified = (child_msg == "OK_NOT_MODIFIED" or child_msg:find("^OK_NOT_MODIFIED") ~= nil)
            local is_ok = (child_msg == "OK" or child_msg:find("^OK") ~= nil)

            if is_ok_not_modified and not (ok_swap_p or ok_swap_pt or ok_swap_f or ok_swap_ss or ok_swap_rb) then
                CatalogClient.setLastFetchedScreensavers(os.time())
                local ok_c, Cache = pcall(require, "storefront_cache")
                if ok_c and Cache and Cache.touchLastFetched then
                    Cache.touchLastFetched(os.time())
                end
                logger.info("Storefront: catalog unchanged (HTTP 304 Not Modified)")
                if StorefrontLogger then
                    StorefrontLogger.info("Storefront: main catalog unchanged (HTTP 304 Not Modified)")
                    local s_count = 0
                    pcall(function()
                        local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                        if ok_ss and StorefrontScreensavers and StorefrontScreensavers.getCachedCount then
                            s_count = StorefrontScreensavers.getCachedCount()
                        end
                    end)
                    StorefrontLogger.info(string.format("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified, %d screensavers cached)", s_count))
                end
                if callback then callback(true, "not_modified") end
            elseif is_ok and (ok_swap_p or ok_swap_pt or ok_swap_f or ok_swap_ss or ok_swap_rb or is_ok_not_modified) then
                if ok_swap_p or ok_swap_pt or ok_swap_f then
                    Cache.invalidate()
                    if StorefrontLogger then StorefrontLogger.info("Storefront: main catalog cache updated and swapped into place") end
                elseif child_msg:find("main=not_modified") or is_ok_not_modified then
                    local ok_c, Cache = pcall(require, "storefront_cache")
                    if ok_c and Cache and Cache.touchLastFetched then
                        Cache.touchLastFetched(os.time())
                    end
                    if StorefrontLogger then StorefrontLogger.info("Storefront: main catalog unchanged (HTTP 304 Not Modified)") end
                end

                if ok_swap_ss or ok_swap_rb then
                    CatalogClient.setLastFetchedScreensavers(os.time())
                    local s_count = 0
                    pcall(function()
                        local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                        if ok_ss and StorefrontScreensavers then
                            StorefrontScreensavers.invalidateMemCache()
                            if StorefrontScreensavers.getCachedCount then
                                s_count = StorefrontScreensavers.getCachedCount()
                            end
                        end
                    end)
                    if StorefrontLogger then StorefrontLogger.info(string.format("Storefront: screensavers catalog updated (%d screensavers cached)", s_count)) end
                elseif child_msg:find("ss=not_modified") or is_ok_not_modified then
                    CatalogClient.setLastFetchedScreensavers(os.time())
                    local s_count = 0
                    pcall(function()
                        local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                        if ok_ss and StorefrontScreensavers and StorefrontScreensavers.getCachedCount then
                            s_count = StorefrontScreensavers.getCachedCount()
                        end
                    end)
                    if StorefrontLogger then StorefrontLogger.info(string.format("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified, %d screensavers cached)", s_count)) end
                elseif child_msg:find("ss=err") then
                    local ss_err_part = child_msg:match("ss=err:([^,;]+)") or "unknown"
                    if StorefrontLogger then StorefrontLogger.warn("Storefront: screensavers catalog update failed: " .. tostring(ss_err_part)) end
                end

                if ok_swap_rb then
                    if StorefrontLogger then StorefrontLogger.info("Storefront: ReaderBackdrop catalog swapped into final location") end
                elseif child_msg:find("rb=not_modified") or (is_ok_not_modified and not child_msg:find("rb=err")) then
                    if StorefrontLogger then StorefrontLogger.info("Storefront: ReaderBackdrop catalog unchanged (HTTP 304 Not Modified)") end
                elseif child_msg:find("rb=err") then
                    local rb_err_part = child_msg:match("rb=err:([^,;]+)") or "unknown"
                    if StorefrontLogger then StorefrontLogger.warn("Storefront: ReaderBackdrop catalog update failed: " .. tostring(rb_err_part)) end
                end

                collectgarbage("step", 100)
                logger.info("Storefront: background catalog update finished and cache swap complete")
                if StorefrontLogger then StorefrontLogger.info("Storefront: background catalog update finished and cache swap complete") end
                if callback then callback(true, "updated") end
            else
                os.remove(staging_plugins_file)
                os.remove(staging_patches_file)
                os.remove(staging_fonts_file)
                os.remove(staging_raw_catalog)
                os.remove(staging_screensavers_file)
                os.remove(staging_rb_file)

                local err_msg = "Catalog async fetch failed (msg: " .. tostring(child_msg) .. ")"
                logger.warn("Storefront " .. err_msg .. ", preserving existing catalog cache")
                if StorefrontLogger then StorefrontLogger.warn("Storefront " .. err_msg .. ", preserving existing catalog cache") end

                if callback then callback(false, child_msg or "async fetch failed") end
            end
        else
            UIManager:scheduleIn(1.0, poll_func)
        end
    end

    CatalogClient._poll_func = poll_func
    CatalogClient._poll_fd = parent_read_fd

    UIManager:scheduleIn(1.0, poll_func)
end

function CatalogClient.getBundledCatalogPath()
    local info = debug.getinfo(1, "S")
    local src = (info and info.source) and info.source:gsub("^@", "") or ""
    local dir = src:match("^(.*[/\\])") or ""

    local candidates = {
        dir .. "catalog.json",
        dir .. "../catalog.json",
    }

    local ok_sf, Storefront = pcall(require, "main")
    local instance_path = (ok_sf and Storefront and Storefront.instance and Storefront.instance.path) or nil
    if instance_path then
        table.insert(candidates, instance_path .. "/catalog.json")
        table.insert(candidates, instance_path .. "/storefront.koplugin/catalog.json")
    end

    local ok_pp, PluginPaths = pcall(require, "storefront_plugin_paths")
    if ok_pp and PluginPaths and PluginPaths.getLookupPaths then
        local lookup_paths = PluginPaths.getLookupPaths() or {}
        for _, p in ipairs(lookup_paths) do
            table.insert(candidates, p .. "/storefront.koplugin/catalog.json")
            table.insert(candidates, p .. "/storefront.koplugin/storefront.koplugin/catalog.json")
        end
    end

    table.insert(candidates, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/catalog.json")
    table.insert(candidates, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/storefront.koplugin/catalog.json")

    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

function CatalogClient.loadBundledCatalog()
    local path = CatalogClient.getBundledCatalogPath()
    if not path then
        logger.warn("Storefront: bundled catalog.json not found")
        return false, "bundled catalog.json not found"
    end

    local f, err = io.open(path, "rb")
    if not f then
        logger.warn("Storefront: failed to open bundled catalog", err)
        return false, err
    end

    local content = f:read("*all")
    f:close()

    if not content or content == "" then
        return false, "empty catalog file"
    end

    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        logger.warn("Storefront: failed to parse bundled catalog JSON", parsed)
        return false, "failed to parse catalog JSON"
    end

    logger.info("Storefront: seeding cache from bundled catalog.json at", path)
    return CatalogClient.updateCacheFromCatalog(parsed, true)
end

function CatalogClient.fetchAndUpdateCache(url_to_fetch)
    local GitHub = require("storefront_net_github")
    if GitHub and GitHub.isDirectApiEnabled and GitHub.isDirectApiEnabled() then
        logger.info("Storefront: catalog fetch skipped in Direct API mode")
        return false, "Direct API mode active"
    end
    local catalog, err = CatalogClient.fetchCatalog(url_to_fetch)
    local ss_data, ss_err = CatalogClient.fetchScreensaverCatalog()

    local main_not_mod = (catalog == "not_modified")
    local ss_not_mod = (ss_data == "not_modified")

    if main_not_mod and ss_not_mod then
        CatalogClient.setLastFetchedScreensavers(os.time())
        local ok_c, Cache = pcall(require, "storefront_cache")
        if ok_c and Cache and Cache.touchLastFetched then
            Cache.touchLastFetched(os.time())
        end
        if StorefrontLogger then
            StorefrontLogger.info("Storefront: main catalog unchanged (HTTP 304 Not Modified)")
            StorefrontLogger.info("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified)")
        end
        return true, "not_modified"
    end

    local updated = false
    if not catalog and not main_not_mod then
        logger.info("Storefront: remote catalog fetch failed, attempting fallback to bundled catalog.json")
        local ok_b, b_err = CatalogClient.loadBundledCatalog()
        if ok_b then updated = true end
    elseif catalog and catalog ~= "not_modified" then
        local ok, update_err = CatalogClient.updateCacheFromCatalog(catalog)
        if ok then
            updated = true
            if StorefrontLogger then StorefrontLogger.info("Storefront: main catalog cache updated and swapped into place") end
        end
    elseif main_not_mod then
        local ok_c, Cache = pcall(require, "storefront_cache")
        if ok_c and Cache and Cache.touchLastFetched then
            Cache.touchLastFetched(os.time())
        end
        if StorefrontLogger then StorefrontLogger.info("Storefront: main catalog unchanged (HTTP 304 Not Modified)") end
    end

    if ss_data and ss_data ~= "not_modified" and type(ss_data) == "table" and #ss_data > 0 then
        local final_screensavers_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
        local ser_ss_ok, ser_ss = pcall(json.encode, ss_data)
        if ser_ss_ok and ser_ss then
            local sf = io.open(final_screensavers_file, "w")
            if sf then
                sf:write(ser_ss)
                sf:close()
                updated = true
                CatalogClient.setLastFetchedScreensavers(os.time())
                pcall(function()
                    local ok_ss_ui, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                    if ok_ss_ui and StorefrontScreensavers and StorefrontScreensavers.invalidateMemCache then
                        StorefrontScreensavers.invalidateMemCache()
                    end
                end)
                if StorefrontLogger then
                    StorefrontLogger.info(string.format("Storefront: screensavers catalog updated (%d screensavers cached)", #ss_data))
                end
            end
        end
    elseif ss_not_mod then
        CatalogClient.setLastFetchedScreensavers(os.time())
        if StorefrontLogger then
            StorefrontLogger.info("Storefront: screensavers catalog unchanged (HTTP 304 Not Modified)")
        end
    end

    if updated then
        return true, "updated"
    elseif main_not_mod or ss_not_mod then
        return true, "not_modified"
    else
        return false, err or ss_err or "Catalog fetch failed"
    end
end

function CatalogClient.syncMissingFromBundledCatalog()
    local path = CatalogClient.getBundledCatalogPath()
    if not path then return end

    local f = io.open(path, "rb")
    if not f then return end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return end

    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then return end

    local Cache = require("storefront_cache")
    local changed = false

    local kinds = { "plugin", "patch", "font" }
    local plural_map = { plugin = "plugins", patch = "patches", font = "fonts" }

    for _, kind in ipairs(kinds) do
        local plural = plural_map[kind]
        local catalog_entries = parsed[plural]
        if type(catalog_entries) == "table" and #catalog_entries > 0 then
            local current_repos = Cache.listRepos(kind) or {}
            local existing_names = {}
            for _, r in ipairs(current_repos) do
                local n = r.name or r.full_name
                if n then existing_names[n:lower()] = true end
            end

            local new_entries = {}
            for _, cat_repo in ipairs(catalog_entries) do
                local name = cat_repo.name or cat_repo.full_name
                if name and not existing_names[name:lower()] then
                    table.insert(new_entries, cat_repo)
                end
            end

            if #new_entries > 0 then
                for _, ne in ipairs(new_entries) do
                    table.insert(current_repos, ne)
                end
                Cache.storeRepos(kind, current_repos)
                changed = true
            end
        end
    end
    return changed
end

return CatalogClient

