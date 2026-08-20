local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log or not StorefrontLogger then
    StorefrontLogger = { info = function() end, warn = function() end, err = function() end, action = function() end, debug = function() end }
end

local StorefrontScreensavers = {}

local DEFAULT_SCREENSAVER_CATALOG_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.json"

local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

local function isNetworkOnline()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr then
        if type(NetworkMgr.isOnline) == "function" then
            local online = NetworkMgr:isOnline()
            if online == false or online == 0 then return false end
        end
        if type(NetworkMgr.isWifiOn) == "function" and not NetworkMgr:isWifiOn() then
            return false
        end
    end
    return true
end

local function requestWithRedirects(target_url, sink_fn)
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local max_retries = 3
        local attempt = 0
        local last_res_code, last_headers_res, last_ok_req, last_err

        while attempt < max_retries do
            attempt = attempt + 1
            local is_https = current_url:match("^https://") ~= nil
            local http_req = getHttpModule(current_url)
            local headers = {
                ["User-Agent"] = (ok_su and socketutil and socketutil.USER_AGENT) or "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
                ["Accept"] = "*/*",
            }

            local sink = sink_fn()
            if not sink then
                StorefrontLogger.err("requestWithRedirects: Failed to create sink for " .. tostring(current_url))
                return false, "failed to create sink", nil
            end

            if ok_su and socketutil and socketutil.set_timeout then
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 180)
            end

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

            if ok_su and socketutil and socketutil.reset_timeout then
                socketutil:reset_timeout()
            end

            last_ok_req = ok_req
            last_res_code = res_code
            last_headers_res = response_headers
            if not ok_req then
                last_err = tostring(res_code)
            end

            local code = tonumber(res_code) or 0
            if ok_req and code == 200 then
                StorefrontLogger.info(string.format("requestWithRedirects: SUCCESS (200) url=%s (attempt %d)", current_url, attempt))
                return true, 200, response_headers
            elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
                break
            else
                StorefrontLogger.warn(string.format("requestWithRedirects: attempt %d/%d failed (ok=%s, code=%s, err=%s) url=%s",
                    attempt, max_retries, tostring(ok_req), tostring(res_code), tostring(last_err), current_url))
            end

            if attempt < max_retries then
                local ok_sec, socket = pcall(require, "socket")
                if ok_sec and socket and socket.sleep then socket.sleep(0.15) end
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
                    else
                        current_url = location
                    end
                else
                    current_url = location
                end
                redirect_count = redirect_count + 1
                StorefrontLogger.info(string.format("requestWithRedirects: redirecting (%d) to %s", code, current_url))
            else
                StorefrontLogger.warn("requestWithRedirects: redirect status without Location header")
                return false, "redirect missing location", last_headers_res
            end
        else
            local err_desc = last_err or last_res_code or "Unknown network error"
            return false, err_desc, last_headers_res
        end
    end
    StorefrontLogger.warn("requestWithRedirects: exceeded max redirects for " .. tostring(target_url))
    return false, "too many redirects", nil
end

local cached_catalog_mem = nil

function StorefrontScreensavers.getCachedCatalog()
    if cached_catalog_mem and type(cached_catalog_mem) == "table" and #cached_catalog_mem > 0 then
        return cached_catalog_mem
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local cat_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(cat_file, "mode") == "file" then
            local f = io.open(cat_file, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content and content ~= "" then
                    local ok_j, parsed = pcall(json.decode, content)
                    if ok_j and type(parsed) == "table" then
                        cached_catalog_mem = parsed
                        return parsed
                    end
                end
            end
        end
    end
    return nil
end

function StorefrontScreensavers.fetchCatalog(callback)
    StorefrontLogger.info("Storefront: fetching screensavers catalog from " .. DEFAULT_SCREENSAVER_CATALOG_URL)
    local ltn12 = require("ltn12")
    local response_body = {}
    local sink_fn = function()
        response_body = {}
        return ltn12.sink.table(response_body)
    end

    local ok, code_or_err = requestWithRedirects(DEFAULT_SCREENSAVER_CATALOG_URL, sink_fn)
    if ok and code_or_err == 200 then
        local body_str = table.concat(response_body)
        local parsed_ok, data = pcall(json.decode, body_str)
        if parsed_ok and type(data) == "table" then
            cached_catalog_mem = data
            StorefrontLogger.info(string.format("Storefront: screensavers catalog fetched successfully (%d items)", #data))
            pcall(function()
                local ok_ds, DataStorage = pcall(require, "datastorage")
                if ok_ds and DataStorage and DataStorage.getDataDir then
                    local cat_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
                    local f = io.open(cat_file, "w")
                    if f then
                        f:write(body_str)
                        f:close()
                    end
                end
            end)
            callback(true, data)
            return
        else
            StorefrontLogger.warn("Storefront: failed to parse screensavers catalog JSON: " .. tostring(data))
        end
    else
        StorefrontLogger.warn(string.format("Storefront: failed to fetch screensavers catalog (err=%s)", tostring(code_or_err)))
    end

    local local_cached = StorefrontScreensavers.getCachedCatalog()
    if local_cached then
        StorefrontLogger.info(string.format("Storefront: using disk cached screensavers catalog (%d items)", #local_cached))
        callback(true, local_cached)
        return
    end

    -- Fallback dummy data if offline / initial test
    StorefrontLogger.warn("Storefront: using fallback dummy screensavers catalog")
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
    callback(false, fallback)
end

function StorefrontScreensavers.fetchThumbnail(item, callback)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local lfs = require("libs/libkoreader-lfs")
    if lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        lfs.mkdir(cache_dir)
    end

    -- Safely check if item is in Transparent category
    local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
    local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil

    -- Use matching extension from URL or category
    local raw_url = tostring(item.thumbnailUrl or ""):lower()
    local ext = (is_transparent or raw_url:find("%.png")) and ".png" or ".jpg"
    local thumb_path = cache_dir .. "/" .. tostring(item.id) .. ext

    if lfs and lfs.attributes and lfs.attributes(thumb_path, "mode") == "file" then
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

    local ok, code_or_err = requestWithRedirects(fetch_url, sink_fn)
    if ok and code_or_err == 200 then
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
    StorefrontLogger.warn(string.format("fetchThumbnail failed for item '%s' (id=%s, url=%s, err=%s)",
        tostring(item.title or item.name), tostring(item.id), tostring(fetch_url), tostring(code_or_err)))
    return nil
end

StorefrontScreensavers.requestWithRedirects = requestWithRedirects

local function formatDownloadError(item, err_detail)
    local title_str = item and (item.title or item.name) or ""
    local err_str = tostring(err_detail or "")
    local code_num = tonumber(err_str:match("(%d%d%d)")) or tonumber(err_detail)

    local reason = nil
    if not isNetworkOnline() then
        reason = _("No internet connection. Please check your Wi-Fi.")
    elseif err_str:lower():find("timeout") or err_str:find("SINK_TIMEOUT") or code_num == 0 then
        reason = _("Connection timed out. Please try again.")
    elseif code_num == 404 then
        reason = _("Image file not found on server (404).")
    elseif code_num == 403 or code_num == 429 then
        reason = string.format(_("Server rate limit or access denied (%s)."), tostring(code_num))
    elseif code_num and code_num >= 500 and code_num < 600 then
        reason = string.format(_("Server error (%s)."), tostring(code_num))
    elseif err_str ~= "" then
        reason = err_str
    else
        reason = _("Network error occurred.")
    end

    if title_str ~= "" then
        return string.format(_("Failed to download '%s': %s"), title_str, reason)
    else
        return string.format(_("Failed to download screensaver: %s"), reason)
    end
end

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
            local error_msg = formatDownloadError(item, result)
            StorefrontToast.show(error_msg, 4)
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
            local error_msg = formatDownloadError(item, result)
            StorefrontToast.show(error_msg, 4)
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
            local error_msg = formatDownloadError(item, result)
            StorefrontToast.show(error_msg, 4)
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

    -- Create destination buffer matching source buffer color type
    local bb_type = (scaled_bb.getType and scaled_bb:getType()) or Blitbuffer.TYPE_BPP24
    local dest_bb = Blitbuffer.new(target_w, target_h, bb_type)
    pcall(function() dest_bb:fill(Blitbuffer.COLOR_WHITE) end)

    pcall(function()
        dest_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
    end)

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
