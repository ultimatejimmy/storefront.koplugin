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

local function requestWithRedirects(target_url, sink_fn)
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
            if ok_req and code == 200 then
                return true, 200, response_headers
            elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
                break
            end

            if attempt < max_retries then
                local ok_sec, socket = pcall(require, "socket")
                if ok_sec and socket and socket.sleep then socket.sleep(0.1) end
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

    local last_err = "No catalog URLs attempted"
    for _, target_url in ipairs(urls_to_try) do
        logger.info("Storefront: fetching static catalog from", target_url)
        local response_body = {}
        local sink_fn = function()
            response_body = {}
            return newTableSink(response_body)
        end

        local ok, res_code = requestWithRedirects(target_url, sink_fn)
        local code = tonumber(res_code) or 0
        if ok and code == 200 then
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

        local ok, res_code = requestWithRedirects(target_url, sink_fn)
        if current_file then pcall(function() current_file:close() end); current_file = nil end

        local code = tonumber(res_code) or 0
        if ok and code == 200 then
            return true, nil
        else
            os.remove(dest_path)
            local err_str = tonumber(res_code) and ("HTTP " .. tostring(res_code)) or tostring(res_code)
            logger.warn("Storefront catalog fetch to file error from", target_url, err_str)
            last_err = err_str
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
    
    local plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}
    local fetched_at = os.time()

    -- Patches: if remote catalog feed has 0 patches, preserve existing cached patches or bundled patches!
    if #patches == 0 then
        local bundled_path = CatalogClient.getBundledCatalogPath()
        if bundled_path then
            local bf = io.open(bundled_path, "rb")
            if bf then
                local bc = bf:read("*all")
                bf:close()
                local ok_b, bundled = pcall(json.decode, bc)
                if ok_b and type(bundled) == "table" and type(bundled.patches) == "table" and #bundled.patches > 0 then
                    patches = bundled.patches
                end
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
                if ok_e and type(existing) == "table" and type(existing.repos) == "table" and #existing.repos > 0 then
                    patches = existing.repos
                end
            end
        end
    end

    -- Fonts are always sourced from the local bundled catalog.json, not the remote feed.
    -- The remote catalog (ultimatejimmy.github.io) only contains plugins and patches.
    local fonts = {}
    local bundled_path = CatalogClient.getBundledCatalogPath()
    if bundled_path then
        local bf = io.open(bundled_path, "rb")
        if bf then
            local bc = bf:read("*all")
            bf:close()
            local ok_b, bundled = pcall(json.decode, bc)
            if ok_b and type(bundled) == "table" and type(bundled.fonts) == "table" then
                fonts = bundled.fonts
            end
        end
    end
    -- Fall back to fonts in the remote data if bundled has none (shouldn't normally happen)
    if #fonts == 0 then
        fonts = catalog_data.fonts or {}
    end

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

    local plugin_data = { fetched_at = fetched_at, repos = plugin_list }
    local patch_data = { fetched_at = fetched_at, repos = patch_list }
    local font_data = { fetched_at = fetched_at, repos = font_list }

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

    if staging_fonts_file then
        local ok_f, ser_f = pcall(json.encode, font_data)
        if not ok_f then return false, "font json encode failed" end
        local ff, err_f = io.open(staging_fonts_file, "w")
        if not ff then return false, "failed to write staging fonts" end
        ff:write(ser_f)
        ff:close()
    end

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
    local staging_fonts_file = cache_dir .. "/storefront_fonts.json.tmp"

    local final_plugins_file = cache_dir .. "/storefront_plugins.json"
    local final_patches_file = cache_dir .. "/storefront_patches.json"
    local final_fonts_file = cache_dir .. "/storefront_fonts.json"

    os.remove(staging_raw_catalog)
    os.remove(staging_plugins_file)
    os.remove(staging_patches_file)
    os.remove(staging_fonts_file)

    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        logger.warn("Storefront: ffiutil.runInSubProcess unavailable, falling back to sync catalog fetch")
        local ok_dl, catalog_data = pcall(function() return CatalogClient.fetchCatalog(target_url) end)
        if ok_dl and catalog_data then
            local ok_update, err_update = CatalogClient.updateCacheFromCatalog(catalog_data)
            if callback then callback(ok_update, err_update) end
        else
            if callback then callback(false, "Sync catalog fetch failed") end
        end
        return
    end

    -- Run download AND JSON decoding AND disk writing inside child subprocess
    local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local ok, err = xpcall(function()
            local ok_dl, dl_err = CatalogClient.fetchCatalogToFile(target_url, staging_raw_catalog)
            if not ok_dl then
                logger.warn("Storefront: remote catalog download failed (" .. tostring(dl_err) .. "), attempting fallback to bundled catalog")
                local bundled_path = CatalogClient.getBundledCatalogPath()
                if bundled_path then
                    local bf = io.open(bundled_path, "rb")
                    if bf then
                        local df = io.open(staging_raw_catalog, "wb")
                        if df then
                            df:write(bf:read("*all"))
                            df:close()
                            ok_dl = true
                        end
                        bf:close()
                    end
                end
            end
            if not ok_dl then
                if child_write_fd then ffiutil.writeToFD(child_write_fd, "ERR_DOWNLOAD: " .. tostring(dl_err), true) end
                return
            end

            local f = io.open(staging_raw_catalog, "rb")
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

            local ok_proc, proc_err = CatalogClient.processCatalogDataToStaging(parsed, staging_plugins_file, staging_patches_file, staging_fonts_file)
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
        if StorefrontLogger then StorefrontLogger.warn("Storefront: failed to launch background process for catalog fetch") end
        if callback then callback(false, "Failed to launch background process") end
        return
    end

    CatalogClient._async_pid = pid

    local poll_func
    poll_func = function()
        if CatalogClient._async_pid ~= pid then
            -- Fetch was cancelled or superseded
            if parent_read_fd and (ffiutil.readAllFromFD or ffiutil.readFromFD) then
                local close_func = ffiutil.readAllFromFD or ffiutil.readFromFD
                close_func(parent_read_fd)
            end
            return
        end

        if ffiutil.isSubProcessDone(pid) then
            CatalogClient._async_pid = nil

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
            local ok_swap_f = safeReplace(staging_fonts_file, final_fonts_file)

            if child_msg == "OK" and (ok_swap_p or ok_swap_pt or ok_swap_f) then
                Cache.invalidate()
                logger.info("Storefront: background catalog update finished and cache swap complete")
                if StorefrontLogger then StorefrontLogger.info("Storefront: background catalog update finished and cache swap complete") end
                if callback then callback(true, nil) end
            else
                os.remove(staging_plugins_file)
                os.remove(staging_patches_file)
                os.remove(staging_fonts_file)
                os.remove(staging_raw_catalog)

                local err_msg = "Catalog async fetch failed (msg: " .. tostring(child_msg) .. ")"
                logger.warn("Storefront " .. err_msg .. ", preserving existing catalog cache")
                if StorefrontLogger then StorefrontLogger.warn("Storefront " .. err_msg .. ", preserving existing catalog cache") end

                if callback then callback(false, child_msg or "async fetch failed") end
            end
        else
            UIManager:scheduleIn(1.0, poll_func)
        end
    end

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
    if not catalog then
        logger.info("Storefront: remote catalog fetch failed, attempting fallback to bundled catalog.json")
        return CatalogClient.loadBundledCatalog()
    end
    local ok, update_err = CatalogClient.updateCacheFromCatalog(catalog)
    if not ok then
        return false, update_err
    end
    return true, nil
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

