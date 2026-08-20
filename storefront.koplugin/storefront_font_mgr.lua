local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InstallStore = require("storefront_installs")
local StorefrontLogger = require("storefront_logger")
local UIManager = require("ui/uimanager")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local ffiutil = require("ffi/util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")

local M = {}

local function downloadFileToPath(url, target_path)
    if not url or url == "" or not target_path or target_path == "" then
        return false
    end

    local current_url = url
    local redirect_count = 0
    local max_redirects = 5

    while redirect_count < max_redirects do
        local response_body = {}
        local is_https = current_url:find("^https://")
        local http_req = is_https and (pcall(require, "ssl.https") and require("ssl.https") or http) or http

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local params = {
            url = current_url,
            method = "GET",
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
            },
            sink = ltn12.sink.table(response_body),
        }
        if not is_https then params.redirect = true end

        local ok_pcall, req_ok, code, headers_res = pcall(http_req.request, params)
        socketutil:reset_timeout()

        local res_code = tonumber(code) or 0
        StorefrontLogger.info(string.format("downloadFileToPath: ok=%s, req_ok=%s, code=%d, url=%s", tostring(ok_pcall), tostring(req_ok), res_code, current_url))

        if ok_pcall and req_ok and (res_code == 301 or res_code == 302 or res_code == 303 or res_code == 307 or res_code == 308) then
            local location = (type(headers_res) == "table") and (headers_res.location or headers_res.Location)
            StorefrontLogger.info(string.format("downloadFileToPath: redirecting (%d) to %s", res_code, tostring(location)))
            if location and location ~= "" then
                current_url = location
                redirect_count = redirect_count + 1
            else
                StorefrontLogger.warn("downloadFileToPath: redirect without location header")
                break
            end
        elseif ok_pcall and req_ok and res_code == 200 then
            local target = io.open(target_path, "wb")
            if not target then
                StorefrontLogger.err("downloadFileToPath: failed to open target file for writing: " .. tostring(target_path))
                return false
            end
            local total_bytes = 0
            for _, chunk in ipairs(response_body) do
                target:write(chunk)
                total_bytes = total_bytes + #chunk
            end
            target:close()
            StorefrontLogger.info(string.format("downloadFileToPath: SUCCESS downloaded %d bytes to %s", total_bytes, target_path))
            return true
        else
            StorefrontLogger.warn(string.format("downloadFileToPath: HTTP request failed, code=%d, err=%s", res_code, tostring(req_ok)))
            break
        end
    end

    return false
end

local function isNetworkOnline()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr then
        if type(NetworkMgr.isOnline) == "function" then
            local online = NetworkMgr:isOnline()
            if online == true or online == 1 then return true end
        end
        if type(NetworkMgr.isWifiOn) == "function" and NetworkMgr:isWifiOn() then return true end
        if type(NetworkMgr.isConnected) == "function" and NetworkMgr:isConnected() then return true end
    end
    return true
end

local function purgeFontCacheFiles()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not (ok_ds and DataStorage) then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local data_dir = DataStorage:getDataDir()

    local ok_fl, FontList = pcall(require, "fontlist")
    if ok_fl and FontList then
        if type(FontList.clearCache) == "function" then
            pcall(FontList.clearCache, FontList)
        end
    end

    local cache_files = {
        data_dir .. "/cache/fontlist/fontinfo.dat",
        data_dir .. "/cache/fontinfo.dat",
        data_dir .. "/cache/fontlist.dat",
        data_dir .. "/cache/font_cache.dat",
        data_dir .. "/cache/font_cache",
    }
    for _, path in ipairs(cache_files) do
        os.remove(path)
    end

    local fontlist_dir = data_dir .. "/cache/fontlist"
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(fontlist_dir, "mode") == "directory" then
        for f in lfs.dir(fontlist_dir) do
            if f ~= "." and f ~= ".." then
                os.remove(fontlist_dir .. "/" .. f)
            end
        end
    end

    StorefrontLogger.info("Storefront: font caches purged from disk")
end

local function getUserFontDirs()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_ds and DataStorage and ok_lfs and lfs) then
        return { "/tmp/fonts" }
    end

    local dirs = {}
    local seen = {}

    local function addDir(d)
        if not d or d == "" or type(d) ~= "string" then return end
        local abs_d = d
        local ok_fu, fu = pcall(require, "ffi/util")
        if ok_fu and fu and fu.realpath then
            local rp = fu.realpath(d)
            if rp and rp ~= "" then abs_d = rp end
        end
        if not seen[abs_d] then
            seen[abs_d] = true
            table.insert(dirs, abs_d)
        end
    end

    -- 1. Primary KOReader data fonts dir (used on Kindle, Android, and Desktop config)
    local primary_data_dir = DataStorage:getDataDir() .. "/fonts"
    addDir(primary_data_dir)

    -- 2. Check FontSettings / external font paths if available
    local ok_fs, FontSettings = pcall(require, "ui/elements/font_settings")
    if ok_fs and FontSettings and type(FontSettings.getPath) == "function" then
        local ok_call, paths_str = pcall(FontSettings.getPath, FontSettings)
        if ok_call and paths_str and type(paths_str) == "string" then
            for dir in string.gmatch(paths_str, "[^;]+") do
                if dir ~= "" and not dir:find("^/usr/share") and not dir:find("^/system") and not dir:find("^/ebrmain") then
                    addDir(dir)
                end
            end
        end
    end

    -- 3. Check desktop XDG/HOME standard font directories (Linux/WSL fallback)
    local xdg_data = os.getenv("XDG_DATA_HOME")
    if xdg_data and xdg_data ~= "" then
        addDir(xdg_data .. "/fonts")
    end
    local home = os.getenv("HOME")
    if home and home ~= "" then
        addDir(home .. "/.local/share/fonts")
    end

    -- 4. Check relative CWD 'fonts' folder if it exists as a directory
    if lfs.attributes and lfs.attributes("fonts", "mode") == "directory" then
        addDir("fonts")
    end

    return dirs
end

local G_installed_fonts_cache = nil

local function listInstalledFonts()
    local generation = InstallStore.getGeneration and InstallStore.getGeneration() or 0
    if G_installed_fonts_cache and G_installed_fonts_cache.generation == generation then
        return G_installed_fonts_cache.fonts
    end
    local font_map = InstallStore.listFonts and InstallStore.listFonts() or {}
    local result = {}
    local seen = {}

    for _, rec in pairs(font_map) do
        local key = (rec.font_name or rec.repo or ""):lower()
        if key ~= "" then
            seen[key] = true
        end
        table.insert(result, rec)
    end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_ds and ok_lfs then
        local search_roots = getUserFontDirs()
        for _, fonts_root in ipairs(search_roots) do
            if lfs.attributes(fonts_root, "mode") == "directory" then
                for file in lfs.dir(fonts_root) do
                    if file ~= "." and file ~= ".." and not file:match("%.deleted$") then
                        local p = fonts_root .. "/" .. file
                        local mode = lfs.attributes(p, "mode")
                        if mode == "directory" then
                            local key = file:lower()
                            if not seen[key] then
                                local has_font = false
                                for subf in lfs.dir(p) do
                                    if (subf:match("%.ttf$") or subf:match("%.otf$")) and not subf:match("%.deleted$") then
                                        has_font = true
                                        break
                                    end
                                end
                                if has_font then
                                    seen[key] = true
                                    table.insert(result, {
                                        font_name = file,
                                        repo = file,
                                        full_name = file,
                                        installed_at = os.time(),
                                        version = "1.0",
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    G_installed_fonts_cache = {
        generation = generation,
        fonts = result,
    }
    return result
end

function M:init(Storefront)
    Storefront.listInstalledFonts = listInstalledFonts

    function Storefront:syncPendingFontDownloads()
        if not isNetworkOnline() then
            return
        end

        local now = os.time()
        local font_map = InstallStore.listFonts() or {}
        local pending = {}
        for font_key, rec in pairs(font_map) do
            if rec and rec.pending_download then
                local font_name = rec.font_name or rec.repo or font_key
                local last_attempt = rec.last_attempt_ts or 0
                local failed_attempts = rec.failed_attempts or 0

                if failed_attempts >= 3 then
                    rec.pending_download = false
                    rec.download_error = "HTTP download failed after 3 attempts"
                    InstallStore.upsertFont(font_name, rec)
                elseif not (last_attempt > 0 and (now - last_attempt) < 3600) then
                    local download_url = rec.download_url
                    if download_url and download_url:find("ultimatejimmy.github.io/fonts/", 1, true) then
                        download_url = download_url:gsub("ultimatejimmy.github.io/fonts/", "ultimatejimmy.github.io/storefront.koplugin/fonts/")
                        rec.download_url = download_url
                    end
                    if not download_url or download_url == ""
                       or download_url:find("raw.githubusercontent.com", 1, true)
                       or download_url:find("github.com/google/fonts/raw", 1, true) then
                        local ok_cache, Cache = pcall(require, "storefront_cache")
                        if ok_cache and Cache then
                            local cat_repo = Cache.getRepoByName(rec.owner or "", font_name) or Cache.getRepoByName("", font_name)
                            if cat_repo and cat_repo.download_url then
                                download_url = cat_repo.download_url
                                rec.download_url = download_url
                            end
                        end
                    end

                    if download_url and download_url ~= "" then
                        table.insert(pending, rec)
                    end
                end
            end
        end

        if #pending == 0 then
            return
        end

        local fonts_root = DataStorage:getDataDir() .. "/fonts"
        local user_font_dirs = getUserFontDirs()

        local function copySingleFile(src_file, dst_file)
            local sf = io.open(src_file, "rb")
            if sf then
                local content = sf:read("*all")
                sf:close()
                local df = io.open(dst_file, "wb")
                if df then
                    df:write(content)
                    df:close()
                    return true
                end
            end
            return false
        end

        local function copyToAllTargets(src_file, item_name, f_target_name)
            for _, udir in ipairs(user_font_dirs) do
                if udir ~= fonts_root then
                    pcall(util.makePath, udir .. "/" .. f_target_name)
                    copySingleFile(src_file, udir .. "/" .. f_target_name .. "/" .. item_name)
                    copySingleFile(src_file, udir .. "/" .. item_name)
                end
            end
        end

        local synced_count = 0
        for _, rec in ipairs(pending) do
            local font_name = rec.font_name or rec.repo or ""
            local download_url = rec.download_url
            if font_name ~= "" and download_url then
                local font_target_dir = fonts_root .. "/" .. font_name
                if lfs.attributes(font_target_dir, "mode") ~= "directory" then
                    lfs.mkdir(font_target_dir)
                end

                local tmp_path = DataStorage:getDataDir() .. "/cache/Storefront/" .. font_name .. "_download.tmp"
                util.makePath(DataStorage:getDataDir() .. "/cache/Storefront")

                rec.last_attempt_ts = os.time()
                if downloadFileToPath(download_url, tmp_path) then
                    local is_zip = download_url:match("%.zip$") or download_url:match("%.zip%?")
                    local extracted_count = 0

                    if is_zip then
                        local ok_arch, Archiver = pcall(require, "ffi/archiver")
                        if ok_arch and Archiver and Archiver.Reader then
                            pcall(function()
                                local reader = Archiver.Reader:new()
                                if reader and reader:open(tmp_path) then
                                    for entry in reader:iterate() do
                                        if entry.mode == "file" then
                                            local f_name = entry.path:match("([^/]+)$") or entry.path
                                            if f_name:match("%.ttf$") or f_name:match("%.otf$") then
                                                local dst_sub = font_target_dir .. "/" .. f_name
                                                local dst_flat = fonts_root .. "/" .. f_name
                                                local parent = dst_sub:match("^(.*)/")
                                                if parent and parent ~= "" then util.makePath(parent) end
                                                if reader:extractToPath(entry.path, dst_sub) then
                                                    copySingleFile(dst_sub, dst_flat)
                                                    copyToAllTargets(dst_sub, f_name, font_name)
                                                    extracted_count = extracted_count + 1
                                                end
                                            end
                                        end
                                    end
                                    reader:close()
                                end
                            end)
                            if extracted_count == 0 and lfs.attributes(font_target_dir, "mode") == "directory" then
                                for f in lfs.dir(font_target_dir) do
                                    if f:match("%.ttf$") or f:match("%.otf$") then
                                        extracted_count = extracted_count + 1
                                    end
                                end
                            end
                        end
                    else
                        local ext = download_url:match("%.([^%.%?]+)$") or "ttf"
                        local dst_name = font_name:gsub("%s+", "_") .. "-Regular." .. ext
                        local dst_sub = font_target_dir .. "/" .. dst_name
                        copySingleFile(tmp_path, dst_sub)
                        copyToAllTargets(dst_sub, dst_name, font_name)
                        extracted_count = 1
                    end

                    os.remove(tmp_path)

                    if extracted_count > 0 then
                        rec.pending_download = false
                        rec.full_installed = true
                        rec.failed_attempts = 0
                        rec.download_error = nil
                        rec.updated_at = os.time()
                        InstallStore.upsertFont(font_name, rec)
                        synced_count = synced_count + 1
                    end
                else
                    rec.failed_attempts = (rec.failed_attempts or 0) + 1
                    if rec.failed_attempts >= 3 then
                        rec.pending_download = false
                        rec.download_error = "HTTP download failed after 3 attempts"
                        StorefrontLogger.warn(string.format("Font download for %s reached 3 failed attempts; disabling retry.", font_name))
                    else
                        StorefrontLogger.info(string.format("Font download for %s failed (attempt %d/3); will retry in 1 hour.", font_name, rec.failed_attempts))
                    end
                    InstallStore.upsertFont(font_name, rec)
                end
            end
        end

        if synced_count > 0 then
            purgeFontCacheFiles()
            StorefrontLogger.info(string.format("Synced %d pending font downloads in background", synced_count))
        end
    end

    function Storefront:installFont(font_name, download_url, repo)
        repo = repo or { name = font_name, font_family = font_name, download_url = download_url }
        return self:_installFontFromRepoInternal(repo)
    end

    function Storefront:installFontFromRepo(repo)
        if not repo then return end
        return self:_installFontFromRepoInternal(repo)
    end

    function Storefront:_installFontFromRepoInternal(repo)
        local asset_folder_name = repo.name or repo.font_family or repo.full_name
        local font_name = repo.font_family or repo.name or repo.full_name
        local download_url = repo.download_url

        if not download_url or download_url == "" then
            local ok_cache, Cache = pcall(require, "storefront_cache")
            if ok_cache and Cache then
                local cat_repo = Cache.getRepoByName(repo.owner or "", font_name) or Cache.getRepoByName("", font_name)
                if cat_repo and cat_repo.download_url then
                    download_url = cat_repo.download_url
                end
            end
        end

        if not font_name or font_name == "" or not asset_folder_name or asset_folder_name == "" then
            UIManager:show(InfoMessage:new{ text = _("Missing font metadata."), timeout = 4 })
            return
        end

        local fonts_root = DataStorage:getDataDir() .. "/fonts"
        util.makePath(fonts_root)

        local font_target_dir = fonts_root .. "/" .. font_name
        util.makePath(font_target_dir)

        local user_font_dirs = getUserFontDirs()
        for _, udir in ipairs(user_font_dirs) do
            if udir ~= fonts_root then
                pcall(util.makePath, udir .. "/" .. font_name)
            end
        end

        local function copySingleFile(src_file, dst_file)
            local sf = io.open(src_file, "rb")
            if sf then
                local content = sf:read("*all")
                sf:close()
                local df = io.open(dst_file, "wb")
                if df then
                    df:write(content)
                    df:close()
                    return true
                end
            end
            return false
        end

        local function copyToAllTargets(src_file, item_name)
            for _, udir in ipairs(user_font_dirs) do
                if udir ~= fonts_root then
                    pcall(util.makePath, udir .. "/" .. font_name)
                    copySingleFile(src_file, udir .. "/" .. font_name .. "/" .. item_name)
                    copySingleFile(src_file, udir .. "/" .. item_name)
                end
            end
        end

        local installed_count = 0
        local is_full = false
        local is_pending = false

        if isNetworkOnline() and download_url and download_url ~= "" then
            local tmp_path = DataStorage:getDataDir() .. "/cache/Storefront/" .. font_name .. "_install.tmp"
            util.makePath(DataStorage:getDataDir() .. "/cache/Storefront")

            if downloadFileToPath(download_url, tmp_path) then
                local is_zip = download_url:match("%.zip$") or download_url:match("%.zip%?")
                if is_zip then
                    local ok_arch, Archiver = pcall(require, "ffi/archiver")
                    if ok_arch and Archiver and Archiver.Reader then
                        pcall(function()
                            local reader = Archiver.Reader:new()
                            if reader and reader:open(tmp_path) then
                                local entries = {}
                                for entry in reader:iterate() do
                                    if entry.mode == "file" then
                                        local f_name = entry.path:match("([^/]+)$") or entry.path
                                        if f_name:match("%.ttf$") or f_name:match("%.otf$") then
                                            table.insert(entries, { entry_path = entry.path, name = f_name })
                                        end
                                    end
                                end

                                table.sort(entries, function(a, b)
                                    local a_reg = a.name:lower():find("regular") and 1 or 0
                                    local b_reg = b.name:lower():find("regular") and 1 or 0
                                    return a_reg > b_reg
                                end)

                                for _, item in ipairs(entries) do
                                    local dst_sub = font_target_dir .. "/" .. item.name
                                    local dst_flat = fonts_root .. "/" .. item.name
                                    local parent = dst_sub:match("^(.*)/")
                                    if parent and parent ~= "" then util.makePath(parent) end
                                    if reader:extractToPath(item.entry_path, dst_sub) then
                                        copySingleFile(dst_sub, dst_flat)
                                        copyToAllTargets(dst_sub, item.name)
                                        installed_count = installed_count + 1
                                    end
                                end
                                reader:close()
                            end
                        end)
                    end
                else
                    local ext = download_url:match("%.([^%.%?]+)$") or "ttf"
                    local dst_name = font_name:gsub("%s+", "_") .. "-Regular." .. ext
                    local dst_file = font_target_dir .. "/" .. dst_name
                    copySingleFile(tmp_path, dst_file)
                    copySingleFile(tmp_path, fonts_root .. "/" .. dst_name)
                    copyToAllTargets(dst_file, dst_name)
                    installed_count = 1
                end
                os.remove(tmp_path)
                if installed_count > 0 then
                    is_full = true
                end
            end
        end

        if installed_count == 0 then
            local info = debug.getinfo(1, "S")
            local script_dir = info and info.source and info.source:match("^@(.*[/\\])") or ""
            if script_dir:sub(-1) == "/" or script_dir:sub(-1) == "\\" then
                script_dir = script_dir:sub(1, -2)
            end

            local candidate_src_dirs = {}
            if script_dir ~= "" then
                table.insert(candidate_src_dirs, script_dir .. "/assets/bundled_fonts/" .. asset_folder_name)
                table.insert(candidate_src_dirs, script_dir .. "/assets/fonts/" .. asset_folder_name)
                table.insert(candidate_src_dirs, script_dir .. "/../assets/bundled_fonts/" .. asset_folder_name)
                table.insert(candidate_src_dirs, script_dir .. "/../assets/fonts/" .. asset_folder_name)
            end
            table.insert(candidate_src_dirs, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/assets/bundled_fonts/" .. asset_folder_name)
            table.insert(candidate_src_dirs, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/assets/fonts/" .. asset_folder_name)
            table.insert(candidate_src_dirs, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/storefront.koplugin/assets/bundled_fonts/" .. asset_folder_name)
            table.insert(candidate_src_dirs, DataStorage:getDataDir() .. "/plugins/storefront.koplugin/storefront.koplugin/assets/fonts/" .. asset_folder_name)
            table.insert(candidate_src_dirs, "assets/bundled_fonts/" .. asset_folder_name)
            table.insert(candidate_src_dirs, "assets/fonts/" .. asset_folder_name)

            for _, src_dir in ipairs(candidate_src_dirs) do
                local real_src = (ffiutil and ffiutil.realpath) and ffiutil.realpath(src_dir) or src_dir
                if not real_src or real_src == "" then real_src = src_dir end
                if real_src and lfs.attributes(real_src, "mode") == "directory" then
                    for file in lfs.dir(real_src) do
                        if file ~= "." and file ~= ".." and (file:match("%.ttf$") or file:match("%.otf$") or file:match("%.ttf%.asset$") or file:match("%.otf%.asset$")) then
                            local src_file = real_src .. "/" .. file
                            local dst_name = file:gsub("%.asset$", "")
                            local dst_file = font_target_dir .. "/" .. dst_name
                            copySingleFile(src_file, dst_file)
                            copySingleFile(src_file, fonts_root .. "/" .. dst_name)
                            copyToAllTargets(src_file, dst_name)
                            installed_count = installed_count + 1
                        end
                    end
                    if installed_count > 0 then break end
                end
            end
            if installed_count > 0 then
                is_pending = (download_url ~= nil and download_url ~= "")
            end
        end

        if installed_count == 0 then
            UIManager:show(InfoMessage:new{ text = string.format(_("Font files not found for %s."), font_name), timeout = 5 })
            return
        end

        purgeFontCacheFiles()

        InstallStore.upsertFont(font_name, {
            font_name = font_name,
            owner = repo.owner,
            repo = repo.name,
            full_name = repo.full_name,
            download_url = download_url,
            full_installed = is_full,
            pending_download = is_pending,
            installed_at = os.time(),
            version = repo.version or "1.0",
        })

        local msg
        if is_full then
            msg = string.format(_("Installed full font family \"%s\" (%d file(s))."), font_name, installed_count)
        elseif is_pending then
            msg = string.format(_("Installed Regular font style offline for \"%s\". Full font family queued for download when reconnected."), font_name)
        else
            msg = string.format(_("Installed font \"%s\" (%d file(s))."), font_name, installed_count)
        end
        self:showRestartConfirmation(msg)
    end

    function Storefront:deleteFont(font_name, record, repo_or_file)
        if not font_name or font_name == "" then
            return
        end
        local display_name = font_name
        self:showDeleteConfirmationDialog(display_name, "font", nil, function()
            local ok, err = pcall(function()
                local fonts_root = DataStorage:getDataDir() .. "/fonts"

                local function purgePath(target_path)
                    if not target_path or target_path == "" then return end
                    local mode = lfs.attributes(target_path, "mode")
                    if not mode then return end

                    if mode == "directory" then
                        for f in lfs.dir(target_path) do
                            if f ~= "." and f ~= ".." then
                                local p = target_path .. "/" .. f
                                local m = lfs.attributes(p, "mode")
                                if m == "directory" then
                                    purgePath(p)
                                elseif m == "file" then
                                    pcall(os.remove, p)
                                end
                            end
                        end
                        local ok_ffi, ffiutil = pcall(require, "ffi/util")
                        if ok_ffi and ffiutil and type(ffiutil.purgeDir) == "function" then
                            pcall(ffiutil.purgeDir, target_path)
                        end
                        pcall(lfs.rmdir, target_path)
                    elseif mode == "file" then
                        pcall(os.remove, target_path)
                    end
                end

                local stems = {}
                local function addStem(str)
                    if str and type(str) == "string" and str ~= "" then
                        local name_only = str:gsub("%.[^%.]+$", "")
                        local clean = name_only:lower():gsub("[%s%-_]+", "")
                        if clean ~= "" then
                            stems[clean] = true
                            for word in name_only:lower():gmatch("[%a%d]+") do
                                if #word >= 4 and word ~= "font" and word ~= "regular" and word ~= "bold" and word ~= "italic" then
                                    stems[word] = true
                                end
                            end
                        end
                    end
                end

                addStem(font_name)
                if record then
                    addStem(record.font_name)
                    addStem(record.repo)
                    addStem(record.font_file)
                end
                if type(repo_or_file) == "table" then
                    addStem(repo_or_file.name)
                    addStem(repo_or_file.font_family)
                    addStem(repo_or_file.font_file)
                elseif type(repo_or_file) == "string" then
                    addStem(repo_or_file)
                end

                local font_family_aliases = {
                    ["bitter"] = { "nv bitter", "bitter", "nv_bitter" },
                    ["nv bitter"] = { "nv bitter", "bitter", "nv_bitter" },
                    ["literata"] = { "nv literata", "literata", "nv_literata" },
                    ["nv literata"] = { "nv literata", "literata", "nv_literata" },
                    ["libre baskerville"] = { "nv basker", "libre baskerville", "librebaskerville", "baskerville", "basker" },
                    ["nv basker"] = { "nv basker", "libre baskerville", "librebaskerville", "baskerville", "basker" },
                    ["gentium plus"] = { "gentium book plus", "gentium plus", "gentiumbookplus", "gentium" },
                    ["gentium book plus"] = { "gentium book plus", "gentium plus", "gentiumbookplus", "gentium" },
                    ["readerly"] = { "readerly", "newsreader" },
                    ["sourcerer"] = { "sourcerer", "source serif" },
                }

                local low_name = font_name:lower()
                if font_family_aliases[low_name] then
                    for _, alias in ipairs(font_family_aliases[low_name]) do
                        addStem(alias)
                    end
                end

                local root_dirs_seen = {}
                local root_dirs = {}
                local function addRootDir(d)
                    if not d or d == "" then return end
                    local abs_d = d
                    local ok_fu, fu = pcall(require, "ffi/util")
                    if ok_fu and fu and fu.realpath then
                        local rp = fu.realpath(d)
                        if rp and rp ~= "" then abs_d = rp end
                    end
                    if not root_dirs_seen[abs_d] then
                        root_dirs_seen[abs_d] = true
                        table.insert(root_dirs, abs_d)
                    end
                end
                addRootDir(fonts_root)
                local ok_fu2, fu2 = pcall(require, "ffi/util")
                if ok_fu2 and fu2 and fu2.realpath then
                    local cwd_fonts = fu2.realpath("fonts")
                    addRootDir(cwd_fonts)
                end
                addRootDir("fonts")
                addRootDir("/home/" .. (os.getenv("USER") or os.getenv("LOGNAME") or "") .. "/.config/koreader/fonts")
                addRootDir(DataStorage:getDataDir() .. "/../fonts")
                local user_all_dirs = getUserFontDirs()
                for _, udir in ipairs(user_all_dirs) do
                    addRootDir(udir)
                end

                local storefront_cache_dir = DataStorage:getDataDir() .. "/cache/Storefront"
                if lfs.attributes(storefront_cache_dir, "mode") == "directory" then
                    local tmp = storefront_cache_dir .. "/" .. font_name .. "_install.tmp"
                    pcall(os.remove, tmp)
                end

                for _, root in ipairs(root_dirs) do
                    if lfs.attributes(root, "mode") == "directory" then
                        purgePath(root .. "/" .. font_name)
                        if record and record.font_file and record.font_file ~= "" then
                            purgePath(root .. "/" .. record.font_file)
                        end
                        if type(repo_or_file) == "table" and repo_or_file.font_file and repo_or_file.font_file ~= "" then
                            purgePath(root .. "/" .. repo_or_file.font_file)
                        end
                        for file in lfs.dir(root) do
                            if file ~= "." and file ~= ".." then
                                if file:match("%.deleted$") then
                                    purgePath(root .. "/" .. file)
                                else
                                    local file_clean = file:gsub("%.[^%.]+$", ""):lower():gsub("[%s%-_]+", "")
                                    local is_match = false
                                    for stem in pairs(stems) do
                                        if file_clean:sub(1, #stem) == stem or stem:sub(1, #file_clean) == file_clean or file_clean:find(stem, 1, true) or stem:find(file_clean, 1, true) then
                                            is_match = true
                                            break
                                        end
                                    end
                                    if is_match then
                                        purgePath(root .. "/" .. file)
                                    end
                                end
                            end
                        end
                    end
                end

                local ok_fl, FontList = pcall(require, "fontlist")
                if ok_fl and FontList then
                    if FontList.fontlist then
                        for stem in pairs(stems) do
                            for i = #FontList.fontlist, 1, -1 do
                                local p = FontList.fontlist[i]
                                local p_clean = p:lower():gsub("[%s%-_]+", "")
                                if p_clean:find(stem, 1, true) then
                                    table.remove(FontList.fontlist, i)
                                end
                            end
                        end
                    end
                    if FontList.fontinfo then
                        for stem in pairs(stems) do
                            for k in pairs(FontList.fontinfo) do
                                local k_clean = k:lower():gsub("[%s%-_]+", "")
                                if k_clean:find(stem, 1, true) or stem:find(k_clean, 1, true) then
                                    FontList.fontinfo[k] = nil
                                end
                            end
                        end
                    end
                    if FontList.fontnames then
                        for stem in pairs(stems) do
                            for k in pairs(FontList.fontnames) do
                                local k_clean = k:lower():gsub("[%s%-_]+", "")
                                if k_clean:find(stem, 1, true) or stem:find(k_clean, 1, true) then
                                    FontList.fontnames[k] = nil
                                end
                            end
                        end
                    end
                end

                purgeFontCacheFiles()

                InstallStore.removeFont(font_name)
                self._repo_descriptors_cache = nil
                self:invalidateInstalledPluginsCache()
            end)

            if not ok then
                logger.warn("Storefront: error deleting font:", err)
            end

            self:showRestartConfirmation(string.format(_("Font '%s' deleted."), display_name))

            if self.updates_menu then
                self:updateUpdatesDialog()
            end
            self:softRefreshCurrentBrowserView()
        end)
    end
end

M.downloadFileToPath = downloadFileToPath
M.purgeFontCacheFiles = purgeFontCacheFiles
M.listInstalledFonts = listInstalledFonts
M.getUserFontDirs = getUserFontDirs

return M
