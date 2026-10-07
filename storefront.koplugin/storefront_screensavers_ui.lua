local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = nil end

local StorefrontScreensavers = {}

local DEFAULT_SCREENSAVER_CATALOG_URL = "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.unified.lite.json"

local CATALOG_URL_CANDIDATES = {
    "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.unified.lite.json",
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.unified.lite.json",
    "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.lite.json",
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.lite.json",
    "https://ultimatejimmy.github.io/storefront-screensavers/screensavers.json",
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.json",
}

local READERBACKDROP_CATALOG_URL_CANDIDATES = {
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/readerbackdrop.lite.json",
    "https://ultimatejimmy.github.io/storefront-screensavers/readerbackdrop.lite.json",
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/readerbackdrop.json",
    "https://ultimatejimmy.github.io/storefront-screensavers/readerbackdrop.json",
}

local BASE_IMAGE_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images"

function StorefrontScreensavers.normalizeItem(item)
    if not item or type(item) ~= "table" then return item end
    if item._normalized then return item end
    if not item.id then return item end
    local id_str = tostring(item.id)
    if not item.source or item.source == "" then
        item.source = id_str:find("^rb%-") and "ReaderBackdrop" or "Storefront"
    end
    local is_remote = (item.source == "ReaderBackdrop") or (item.fullUrl and tostring(item.fullUrl):find("^https?://") ~= nil)
    local ext = item.ext
    if not ext or ext == "" then
        if item.fullUrl and tostring(item.fullUrl):lower():find("%.png") then
            ext = "png"
        else
            local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
            if cat_str:lower():find("transparent", 1, true) then
                ext = "png"
            else
                ext = "jpg"
            end
        end
    end
    item.ext = ext
    if not item.fullUrl or item.fullUrl == "" then
        item.fullUrl = string.format("%s/%s.%s", BASE_IMAGE_URL, id_str, ext)
    end
    if not item.thumbnailUrl or item.thumbnailUrl == "" then
        if is_remote and item.fullUrl and item.fullUrl ~= "" then
            item.thumbnailUrl = item.fullUrl
        else
            item.thumbnailUrl = string.format("%s/thumbnails/%s.%s", BASE_IMAGE_URL, id_str, ext)
        end
    end
    if not item.pluginThumbnailUrl or item.pluginThumbnailUrl == "" then
        if is_remote and item.thumbnailUrl and item.thumbnailUrl ~= "" then
            item.pluginThumbnailUrl = item.thumbnailUrl
        else
            item.pluginThumbnailUrl = string.format("%s/thumbnails/plugin/%s.%s", BASE_IMAGE_URL, id_str, ext)
        end
    end
    item.featured = (item.featured == 1 or item.featured == true)
    item._normalized = true
    return item
end

local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

local function requestWithRedirects(target_url, sink_fn, extra_headers)
    local ok_su, socketutil = pcall(require, "socketutil")
    local ltn12 = require("ltn12")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local is_https = current_url:match("^https://") ~= nil
        local http_req = getHttpModule(current_url)
        local headers = {
            ["User-Agent"] = (ok_su and socketutil and socketutil.USER_AGENT) or "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
            ["Accept"] = "application/json",
        }
        if extra_headers then
            for k, v in pairs(extra_headers) do
                headers[k] = v
            end
        end

        local sink = sink_fn()
        if not sink then return false, 0, nil end

        local params = {
            url = current_url,
            method = "GET",
            headers = headers,
            sink = sink,
        }
        if not is_https then params.redirect = true end

        if ok_su and socketutil and socketutil.set_timeout then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 180)
        end

        local ok_req, res_code, response_headers = pcall(function()
            local _, c, h = http_req.request(params)
            return c, h
        end)

        if ok_su and socketutil and socketutil.reset_timeout then
            socketutil:reset_timeout()
        end

        local code = tonumber(res_code) or 0
        if ok_req and (code == 200 or code == 304) then
            return true, code, response_headers
        elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            local loc = response_headers and (response_headers.location or response_headers.Location)
            if loc and loc ~= "" then
                current_url = loc
                redirect_count = redirect_count + 1
            else
                break
            end
        else
            break
        end
    end
    return false, 0, nil
end

local cached_catalog_mem = nil

function StorefrontScreensavers.invalidateMemCache()
    cached_catalog_mem = nil
end

function StorefrontScreensavers.clearCachedCatalog()
    cached_catalog_mem = nil
    pcall(function()
        local ok_net, CatalogClient = pcall(require, "storefront_net_catalog")
        if ok_net and CatalogClient then
            if CatalogClient.clearStoredScreensaverEtag then
                CatalogClient.clearStoredScreensaverEtag()
            end
            if CatalogClient.clearStoredReaderBackdropEtag then
                CatalogClient.clearStoredReaderBackdropEtag()
            end
        end
    end)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local cat_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
        local rb_file = DataStorage:getDataDir() .. "/cache/storefront_readerbackdrop_catalog.json"
        pcall(os.remove, cat_file)
        pcall(os.remove, rb_file)
    end
end

local function loadCatalogFile(file_path, default_source)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(file_path, "mode") == "file" then
        local f = io.open(file_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local ok_j, parsed = pcall(json.decode, content)
                if ok_j and type(parsed) == "table" and #parsed > 0 then
                    for _, item in ipairs(parsed) do
                        if default_source and (not item.source or item.source == "") then
                            item.source = default_source
                        end
                        StorefrontScreensavers.normalizeItem(item)
                    end
                    return parsed
                end
            end
        end
    end
    return nil
end

local function mergeCatalogs(sf_list, rb_list)
    local merged = {}
    local seen_ids = {}
    if sf_list then
        for _, item in ipairs(sf_list) do
            if item.id and not seen_ids[item.id] then
                seen_ids[item.id] = true
                if not item.source or item.source == "" then item.source = "Storefront" end
                table.insert(merged, item)
            end
        end
    end
    if rb_list then
        for _, item in ipairs(rb_list) do
            if item.id and not seen_ids[item.id] then
                seen_ids[item.id] = true
                if not item.source or item.source == "" then item.source = "ReaderBackdrop" end
                table.insert(merged, item)
            end
        end
    end
    return merged
end

local function fetchCandidateList(urls_to_try)
    local ltn12 = require("ltn12")
    for _, target_url in ipairs(urls_to_try) do
        local response_body = {}
        local sink_fn = function()
            response_body = {}
            return ltn12.sink.table(response_body)
        end
        local ok, code = requestWithRedirects(target_url, sink_fn)
        if ok and code == 200 then
            local body_str = table.concat(response_body)
            local parsed_ok, data = pcall(json.decode, body_str)
            if parsed_ok and type(data) == "table" and #data > 0 then
                return data, body_str
            end
        end
    end
    return nil, nil
end

function StorefrontScreensavers.getLastFetched()
    local ok_net, CatalogClient = pcall(require, "storefront_net_catalog")
    if ok_net and CatalogClient and CatalogClient.getLastFetchedScreensavers then
        local t = CatalogClient.getLastFetchedScreensavers()
        if t > 0 then return t end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local data_dir = DataStorage:getDataDir()
        local sf_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
        local rb_file = data_dir .. "/cache/storefront_readerbackdrop_catalog.json"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs and lfs.attributes then
            local t_sf = 0
            local t_rb = 0
            local attr_sf = lfs.attributes(sf_file)
            if attr_sf and attr_sf.modification then t_sf = attr_sf.modification end
            local attr_rb = lfs.attributes(rb_file)
            if attr_rb and attr_rb.modification then t_rb = attr_rb.modification end
            local max_t = math.max(t_sf, t_rb)
            if max_t > 0 then return max_t end
        end
    end
    return 0
end

function StorefrontScreensavers.getCachedCount()
    if cached_catalog_mem and type(cached_catalog_mem) == "table" and #cached_catalog_mem > 0 then
        return #cached_catalog_mem
    end
    local ok_set, StorefrontSettings = pcall(require, "storefront_settings")
    if ok_set and StorefrontSettings and StorefrontSettings.readSetting then
        local count = StorefrontSettings:readSetting("cached_screensaver_count")
        if count and tonumber(count) and tonumber(count) > 0 then
            return tonumber(count)
        end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local data_dir = DataStorage:getDataDir()
        local sf_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(sf_file, "mode") == "file" then
            return 1
        end
    end
    return 0
end

function StorefrontScreensavers.getCachedCatalog()
    if cached_catalog_mem and type(cached_catalog_mem) == "table" and #cached_catalog_mem > 0 then
        return cached_catalog_mem
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local data_dir = DataStorage:getDataDir()
        local sf_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
        local rb_file = data_dir .. "/cache/storefront_readerbackdrop_catalog.json"
        local sf_items = loadCatalogFile(sf_file, "Storefront")

        local merged = nil
        if sf_items and #sf_items > 0 then
            local is_unified = false
            for i = 1, math.min(#sf_items, 200) do
                if sf_items[i].source == "ReaderBackdrop" then
                    is_unified = true
                    break
                end
            end
            if is_unified then
                merged = sf_items
            else
                local rb_items = loadCatalogFile(rb_file, "ReaderBackdrop")
                merged = mergeCatalogs(sf_items, rb_items)
            end
        else
            local rb_items = loadCatalogFile(rb_file, "ReaderBackdrop")
            if rb_items and #rb_items > 0 then
                merged = rb_items
            end
        end

        if merged and #merged > 0 then
            cached_catalog_mem = merged
            pcall(function()
                local ok_set, StorefrontSettings = pcall(require, "storefront_settings")
                if ok_set and StorefrontSettings and StorefrontSettings.saveSetting then
                    StorefrontSettings:saveSetting("cached_screensaver_count", #merged)
                    StorefrontSettings:flush()
                end
            end)
            return merged
        end
    end
    return nil
end

function StorefrontScreensavers.fetchCatalog(callback)
    if StorefrontLogger then StorefrontLogger.info("Storefront: fetching screensavers catalog feed (Storefront + ReaderBackdrop)") end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp"

    local sf_items = nil
    local rb_items = nil

    -- 1. Fetch Storefront catalog
    local ok_net, CatalogClient = pcall(require, "storefront_net_catalog")
    if ok_net and CatalogClient and CatalogClient.fetchScreensaverCatalog then
        local data, err = CatalogClient.fetchScreensaverCatalog()
        if data == "not_modified" then
            local sf_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
            sf_items = loadCatalogFile(sf_file, "Storefront")
        elseif data and type(data) == "table" and #data > 0 then
            for _, item in ipairs(data) do
                if not item.source or item.source == "" then
                    item.source = "Storefront"
                end
                StorefrontScreensavers.normalizeItem(item)
            end
            sf_items = data
            pcall(function()
                local cat_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
                local f = io.open(cat_file, "w")
                if f then
                    f:write(json.encode(data))
                    f:close()
                end
            end)
        end
    end

    if not sf_items then
        local data, body_str = fetchCandidateList(CATALOG_URL_CANDIDATES)
        if data and type(data) == "table" and #data > 0 then
            for _, item in ipairs(data) do
                if not item.source or item.source == "" then
                    item.source = "Storefront"
                end
                StorefrontScreensavers.normalizeItem(item)
            end
            sf_items = data
            pcall(function()
                local cat_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
                local f = io.open(cat_file, "w")
                if f then
                    f:write(body_str or json.encode(data))
                    f:close()
                end
            end)
        else
            local sf_file = data_dir .. "/cache/storefront_screensavers_catalog.json"
            sf_items = loadCatalogFile(sf_file, "Storefront")
        end
    end

    local sf_is_unified = false
    if sf_items and #sf_items > 0 then
        for i = 1, math.min(#sf_items, 200) do
            if sf_items[i].source == "ReaderBackdrop" then
                sf_is_unified = true
                break
            end
        end
    end

    -- 2. Fetch ReaderBackdrop catalog only if not already in unified feed
    if not sf_is_unified then
        local rb_data, rb_body_str = fetchCandidateList(READERBACKDROP_CATALOG_URL_CANDIDATES)
        if rb_data and type(rb_data) == "table" and #rb_data > 0 then
            for _, item in ipairs(rb_data) do
                item.source = "ReaderBackdrop"
                StorefrontScreensavers.normalizeItem(item)
            end
            rb_items = rb_data
            pcall(function()
                local rb_file = data_dir .. "/cache/storefront_readerbackdrop_catalog.json"
                local f = io.open(rb_file, "w")
                if f then
                    f:write(rb_body_str or json.encode(rb_data))
                    f:close()
                end
            end)
        else
            local rb_file = data_dir .. "/cache/storefront_readerbackdrop_catalog.json"
            rb_items = loadCatalogFile(rb_file, "ReaderBackdrop")
        end
    end

    if (sf_items and #sf_items > 0) or (rb_items and #rb_items > 0) then
        local merged = (sf_is_unified and sf_items) or mergeCatalogs(sf_items, rb_items)
        cached_catalog_mem = merged
        pcall(function()
            local ok_set, StorefrontSettings = pcall(require, "storefront_settings")
            if ok_set and StorefrontSettings and StorefrontSettings.saveSetting then
                StorefrontSettings:saveSetting("cached_screensaver_count", #merged)
                StorefrontSettings:flush()
            end
        end)
        local ok_net, CatalogClient = pcall(require, "storefront_net_catalog")
        if ok_net and CatalogClient and CatalogClient.setLastFetchedScreensavers then
            CatalogClient.setLastFetchedScreensavers(os.time())
        end
        if StorefrontLogger then
            StorefrontLogger.info(string.format("Storefront: screensavers catalog merged (%d total: %d Storefront, %d ReaderBackdrop)",
                #merged, sf_items and #sf_items or 0, rb_items and #rb_items or 0))
        end
        if callback then callback(true, merged) end
        return
    end

    local local_cached = StorefrontScreensavers.getCachedCatalog()
    if local_cached then
        if callback then callback(true, local_cached) end
        return
    end

    -- Fallback dummy data if offline / initial test
    local fallback = {
        {
            id = "foggy-forest-pines",
            title = "Foggy Mountain Pines",
            author = "Unsplash (CC0)",
            category = "Nature",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/foggy-forest-pines.jpg",
        },
        {
            id = "minimalist-ocean-waves",
            title = "Minimalist Ocean Horizon",
            author = "Unsplash (CC0)",
            category = "Minimalist",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/minimalist-ocean-waves.jpg",
        },
        {
            id = "cosmic-nebula-monochrome",
            title = "Deep Space Nebula",
            author = "Unsplash (CC0)",
            category = "Sci-Fi",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/cosmic-nebula-monochrome.jpg",
        },
    }
    for _, item in ipairs(fallback) do
        StorefrontScreensavers.normalizeItem(item)
    end
    if callback then callback(false, fallback) end
end

function StorefrontScreensavers.getThumbnailPath(item)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
    local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil
    local raw_url = tostring(item.thumbnailUrl or ""):lower()
    local ext = (item.ext == "png" or is_transparent or raw_url:find("%.png")) and ".png" or ".jpg"
    return cache_dir .. "/" .. tostring(item.id) .. ext, is_transparent
end

function StorefrontScreensavers.fetchThumbnail(item, callback)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        pcall(lfs.mkdir, cache_dir)
    end

    local thumb_path, is_transparent = StorefrontScreensavers.getThumbnailPath(item)

    if ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_path, "mode") == "file" then
        if callback then callback(thumb_path) end
        return thumb_path
    end

    local fetch_url = (is_transparent and item.pluginThumbnailUrl) or item.thumbnailUrl
    if not fetch_url or item._thumb_failed then return nil end

    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = requestWithRedirects(fetch_url, sink_fn)
    -- Graceful fallback: If transparent pluginThumbnailUrl failed (e.g. 404), try standard thumbnailUrl
    if (not ok or code ~= 200) and is_transparent and item.pluginThumbnailUrl and item.thumbnailUrl and item.thumbnailUrl ~= fetch_url then
        ok, code = requestWithRedirects(item.thumbnailUrl, sink_fn)
    end

    if ok and code == 200 then
        local tmp_path = thumb_path .. ".tmp"
        local file = io.open(tmp_path, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()
            os.remove(thumb_path)
            local ok_ren = os.rename(tmp_path, thumb_path)
            if ok_ren then
                if callback then callback(thumb_path) end
                return thumb_path
            end
        end
    end

    item._thumb_failed = true
    return nil
end

function StorefrontScreensavers.fetchThumbnailAsync(item)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        pcall(lfs.mkdir, cache_dir)
    end

    local thumb_path, is_transparent = StorefrontScreensavers.getThumbnailPath(item)

    if ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_path, "mode") == "file" then
        return nil, nil, thumb_path
    end

    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not ok_ffi then ok_ffi, ffiutil = pcall(require, "ffiutil") end
    local can_fork = ok_ffi and ffiutil and ffiutil.runInSubProcess and ffiutil.isSubProcessDone

    local fetch_url = (is_transparent and item.pluginThumbnailUrl) or item.thumbnailUrl
    if not fetch_url or item._thumb_failed then return nil, nil, nil end

    if not can_fork then
        local res = StorefrontScreensavers.fetchThumbnail(item)
        return nil, nil, res
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local ok, path_or_err = pcall(function()
            local ltn12 = require("ltn12")
            local img_data = {}
            local sink_fn = function()
                img_data = {}
                return ltn12.sink.table(img_data)
            end
            local ok_req, code = requestWithRedirects(fetch_url, sink_fn)
            if (not ok_req or code ~= 200) and is_transparent and item.pluginThumbnailUrl and item.thumbnailUrl and item.thumbnailUrl ~= fetch_url then
                ok_req, code = requestWithRedirects(item.thumbnailUrl, sink_fn)
            end
            if ok_req and code == 200 then
                local tmp_path = thumb_path .. ".tmp"
                local file = io.open(tmp_path, "wb")
                if file then
                    file:write(table.concat(img_data))
                    file:close()
                    os.remove(thumb_path)
                    local ok_ren = os.rename(tmp_path, thumb_path)
                    if ok_ren then
                        return thumb_path
                    end
                end
            end
            return nil
        end)
        local msg = (ok and path_or_err) and ("OK:" .. tostring(path_or_err)) or "ERR"
        if child_write_fd then
            ffiutil.writeToFD(child_write_fd, msg, true)
        end
    end, true)

    if not pid then
        local res = StorefrontScreensavers.fetchThumbnail(item)
        return nil, nil, res
    end

    return pid, parent_read_fd, nil
end

StorefrontScreensavers.requestWithRedirects = requestWithRedirects

function StorefrontScreensavers.downloadAsSingle(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading screensaver..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
            local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil
            local params = { file = result }
            if is_transparent then
                params.background = "none"
            end
            StorefrontScreensaverMgr.setScreensaverMode("single", params)
            StorefrontToast.show(_("Wallpaper set as active KOReader screensaver!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadToShufflePool(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading to shuffle pool..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            StorefrontScreensaverMgr.setScreensaverMode("shuffle")
            StorefrontToast.show(_("Added to shuffle pool & Folder Shuffle enabled!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadOnly(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading screensaver..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            StorefrontToast.show(_("Wallpaper saved to collection!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadAndSetScreensaver(item, callback)
    StorefrontScreensavers.downloadAsSingle(item, callback)
end

function StorefrontScreensavers.showDetails(item, parent_storefront)
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local ImageWidget = require("ui/widget/imagewidget")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Blitbuffer = require("ffi/blitbuffer")

    local sc = function(val) return Device.screen:scaleBySize(val) end

    local thumb_file = StorefrontScreensavers.fetchThumbnail(item)

    local StorefrontUtils = require("storefront_utils")
    local cat_str = table.concat(StorefrontUtils.getMappedScreensaverCategories(item.category), ", ")
    local meta_txt = TextWidget:new{
        text = string.format("%s  ·  %s", item.author or _("Community"), cat_str),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local preview_widget
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    if thumb_file and ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_file, "mode") == "file" then
        local ok_c, res_c = pcall(function()
            return StorefrontScreensavers.createCoverImageWidget(thumb_file, sc(180), sc(240))
        end)
        if ok_c and res_c then
            preview_widget = res_c
        end
    end

    if not preview_widget then
        preview_widget = TextWidget:new{
            text = _("[ Wallpaper Preview Loading... ]"),
            face = Font:getFace("cfont", 16),
        }
    end

    local tags_str = ""
    if item.tags then
        if type(item.tags) == "table" and #item.tags > 0 then
            local display_tags = {}
            for i = 1, math.min(#item.tags, 5) do
                table.insert(display_tags, "#" .. tostring(item.tags[i]))
            end
            tags_str = table.concat(display_tags, "  ")
        elseif type(item.tags) == "string" and item.tags ~= "" then
            tags_str = item.tags
        end
    end

    local dialog_vg = VerticalGroup:new{
        align = "center",
        meta_txt,
    }

    if tags_str ~= "" then
        table.insert(dialog_vg, VerticalSpan:new{ width = sc(3) })
        table.insert(dialog_vg, TextWidget:new{
            text = tags_str,
            face = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = sc(260),
        })
    end

    table.insert(dialog_vg, VerticalSpan:new{ width = sc(8) })
    table.insert(dialog_vg, preview_widget)

    local dialog
    dialog = ButtonDialog:new{
        title = item.title or item.name or _("Screensaver Details"),
        widgets = {
            CenterContainer:new{
                dimen = require("ui/geometry"):new{ w = sc(280), h = sc(320) },
                dialog_vg
            }
        },
        buttons = {
            {
                {
                    text = _("Download & Set Active"),
                    is_primary = true,
                    callback = function()
                        UIManager:close(dialog)
                        StorefrontScreensavers.downloadAndSetScreensaver(item)
                    end,
                },
            },
            {
                {
                    text = _("Rate Wallpaper"),
                    callback = function()
                        if parent_storefront and parent_storefront.showRatingDialog then
                            parent_storefront:showRatingDialog(item)
                        end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function StorefrontScreensavers.createCoverImageWidget(file_path, target_w, target_h)
    local ImageWidget = require("ui/widget/imagewidget")
    local RenderImage = require("ui/renderimage")
    local Blitbuffer  = require("ffi/blitbuffer")

    if not file_path or not target_w or not target_h then return nil end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)

    if not ok or not orig_bb then
        return nil
    end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()

    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then pcall(function() orig_bb:free() end) end
        return nil
    end

    -- Scale with cover mode (fill target box edge-to-edge, center-cropped)
    local scale = math.max(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.max(1, math.ceil(orig_w * scale))
    local scaled_h = math.max(1, math.ceil(orig_h * scale))

    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(orig_bb, scaled_w, scaled_h, false)
    end)
    if orig_bb.free then pcall(function() orig_bb:free() end) end
    if not ok_scale or not scaled_bb then return nil end

    local crop_x = math.max(0, math.floor((scaled_bb:getWidth() - target_w) / 2))
    local crop_y = math.max(0, math.floor((scaled_bb:getHeight() - target_h) / 2))

    -- Detect whether the source buffer carries an alpha channel.
    -- TYPE_BB8A=2 (8-bit gray + alpha), TYPE_BBRGB32=5 (RGB + alpha)
    local src_type = (scaled_bb.getType and scaled_bb:getType()) or 0
    local has_alpha = (src_type == 2 or src_type == 5)

    -- Always use a plain 8-bit grayscale destination (native e-ink format)
    local dest_bb = Blitbuffer.new(target_w, target_h, Blitbuffer.TYPE_BB8 or 1)
    pcall(function() dest_bb:fill(Blitbuffer.COLOR_WHITE) end)

    if has_alpha then
        -- Draw a checkerboard pattern so transparent areas are visually distinct.
        -- Two grays that are subtle on e-ink: white (0xFF) and light-gray (0xDD).
        local tile = 6  -- checkerboard tile size in pixels
        local color_a = Blitbuffer.COLOR_WHITE
        local color_b = Blitbuffer.COLOR_GRAY_D  -- 0xDD, a soft light gray
        pcall(function()
            local y = 0
            while y < target_h do
                local row_flip = math.floor(y / tile) % 2
                local x = 0
                while x < target_w do
                    local col_flip = math.floor(x / tile) % 2
                    local w = math.min(tile - (x % tile), target_w - x)
                    local h = math.min(tile - (y % tile), target_h - y)
                    local c = ((row_flip + col_flip) % 2 == 0) and color_a or color_b
                    dest_bb:paintRect(x, y, w, h, c)
                    x = x + w
                end
                y = y + math.min(tile - (y % tile), target_h - y)
            end
        end)
        -- Alpha-composite the image over the checkerboard
        pcall(function()
            if dest_bb.alphablitFrom then
                dest_bb:alphablitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
            else
                dest_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
            end
        end)
    else
        -- Fully opaque source — plain flat copy is faster
        pcall(function()
            dest_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
        end)
    end

    if scaled_bb.free then
        pcall(function() scaled_bb:free() end)
    end

    return ImageWidget:new{
        image = dest_bb,
        image_disposable = true,
        width = target_w,
        height = target_h,
    }
end


function StorefrontScreensavers.getThumbnailsCacheStats()
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local files = 0
    local bytes = 0
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(cache_dir, "mode") == "directory" then
        for entry in lfs.dir(cache_dir) do
            if entry ~= "." and entry ~= ".." then
                local full = cache_dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" then
                    files = files + 1
                    bytes = bytes + (attr.size or 0)
                end
            end
        end
    end
    return {
        files = files,
        bytes = bytes,
    }
end

function StorefrontScreensavers.clearThumbnailsCache()
    StorefrontScreensavers.clearCachedCatalog()
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local removed = 0
    local bytes = 0
    local errors = {}
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(cache_dir, "mode") == "directory" then
        for entry in lfs.dir(cache_dir) do
            if entry ~= "." and entry ~= ".." then
                local full = cache_dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" then
                    local sz = attr.size or 0
                    if os.remove(full) then
                        removed = removed + 1
                        bytes = bytes + sz
                    else
                        table.insert(errors, full)
                    end
                end
            end
        end
    end
    return { removed = removed, bytes = bytes, errors = errors }
end

return StorefrontScreensavers
