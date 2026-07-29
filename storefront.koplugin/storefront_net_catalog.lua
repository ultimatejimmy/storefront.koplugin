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

function CatalogClient.fetchCatalog(url_to_fetch)
    local socketutil = require("socketutil")

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

        local http_req = getHttpModule(target_url)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        -- ssl.https does not support redirect=true; socket.http does
        local is_https = target_url:match("^https://") ~= nil
        local ok_req, res_code = pcall(function()
            local params = {
                url = target_url,
                method = "GET",
                headers = headers,
                sink = newTableSink(response_body),
            }
            if not is_https then params.redirect = true end
            local _, c = http_req.request(params)
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
            local err_str
            if not ok_req then
                err_str = "pcall failed: " .. tostring(res_code)
            elseif tonumber(res_code) then
                err_str = "HTTP " .. tostring(res_code)
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
    local fonts   = catalog_data.fonts or {}
    
    logger.info("Storefront: updating cache from static catalog", "plugins:", #plugins, "patches:", #patches, "fonts:", #fonts)
    
    -- Store plugin repositories
    Cache.storeRepos("plugin", plugins)
    
    -- Store patch repositories
    Cache.storeRepos("patch", patches)
    
    -- Store font repositories
    Cache.storeRepos("font", fonts)
    
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
        local file, f_err = io.open(dest_path, "wb")
        if not file then
            logger.err("Storefront: failed to open dest_path for writing", f_err)
            last_err = "failed to open dest_path"
        else
            local http_req = getHttpModule(target_url)
            local is_https = target_url:match("^https://") ~= nil
            local headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = USER_AGENT,
            }

            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local ok_req, res_code = pcall(function()
                local params = {
                    url = target_url,
                    method = "GET",
                    headers = headers,
                    sink = socketutil.file_sink(file),
                }
                -- ssl.https does not support redirect=true
                if not is_https then params.redirect = true end
                local _, c = http_req.request(params)
                return c
            end)
            pcall(function() file:close() end)
            socketutil:reset_timeout()

            local code = tonumber(res_code) or 0
            if ok_req and code == 200 then
                return true, nil
            else
                os.remove(dest_path)
                local err_str
                if not ok_req then
                    err_str = "pcall failed: " .. tostring(res_code)
                elseif tonumber(res_code) then
                    err_str = "HTTP " .. tostring(res_code)
                else
                    err_str = tostring(res_code)
                end
                logger.warn("Storefront catalog fetch to file error from", target_url, err_str)
                last_err = err_str
            end
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

function CatalogClient.processCatalogDataToStaging(catalog_data, staging_plugins_file, staging_patches_file, staging_fonts_file)
    if not catalog_data or type(catalog_data) ~= "table" then
        return false, "invalid catalog format"
    end
    
    local plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}
    local fetched_at = os.time()

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
            local raw_msg = (read_func and parent_read_fd) and read_func(parent_read_fd) or (read_func and read_func(pid))
            local child_msg = (type(raw_msg) == "string" and raw_msg ~= "") and raw_msg or "SUBPROCESS_NO_MSG"
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
        DataStorage:getDataDir() .. "/plugins/storefront.koplugin/catalog.json",
        DataStorage:getDataDir() .. "/plugins/storefront.koplugin/storefront.koplugin/catalog.json",
    }

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
    return CatalogClient.updateCacheFromCatalog(parsed)
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

