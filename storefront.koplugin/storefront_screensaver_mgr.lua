local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local StorefrontScreensaverMgr = {}

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs then
        return lfs
    end
    return nil
end

local function getReaderSettings()
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        return _G.G_reader_settings
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local settings_dir = (ok_ds and DataStorage and DataStorage.getSettingsDir) and DataStorage:getSettingsDir() or "/tmp/koreader/settings"
    local settings_file = settings_dir .. "/settings.reader.lua"
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ls and LuaSettings and LuaSettings.open then
        return LuaSettings:open(settings_file)
    end
    return nil
end

local function getStorefrontSettings()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local settings_dir = (ok_ds and DataStorage and DataStorage.getSettingsDir) and DataStorage:getSettingsDir() or "/tmp/koreader/settings"
    local settings_file = settings_dir .. "/Storefront.lua"
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ls and LuaSettings and LuaSettings.open then
        return LuaSettings:open(settings_file)
    end
    return nil
end

local function isTrueSetting(settings, key)
    if not settings then return false end
    if type(settings.isTrue) == "function" then
        return settings:isTrue(key) == true
    end
    if type(settings.readSetting) == "function" then
        local val = settings:readSetting(key)
        return val == true or val == "true" or val == 1
    end
    return false
end

local function readSettingSafe(settings, key, default)
    if not settings or type(settings.readSetting) ~= "function" then
        return default
    end
    local val = settings:readSetting(key)
    if val == nil then return default end
    return val
end

local function saveSettingSafe(settings, key, val)
    if settings and type(settings.saveSetting) == "function" then
        settings:saveSetting(key, val)
    end
end

local function flushSafe(settings)
    if settings and type(settings.flush) == "function" then
        settings:flush()
    end
end

function StorefrontScreensaverMgr.getDefaultScreensaverFolder()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp/koreader"
    return data_dir .. "/screensavers"
end

function StorefrontScreensaverMgr.getCustomScreensaverFolder()
    local sf_settings = getStorefrontSettings()
    local custom_dir = readSettingSafe(sf_settings, "screensaver_custom_folder", nil)
    if not custom_dir or custom_dir == "" then
        local r_settings = getReaderSettings()
        local r_custom = readSettingSafe(r_settings, "screensaver_custom_dir", nil)
        if r_custom and r_custom ~= "" then
            custom_dir = r_custom
        end
    end
    if custom_dir and custom_dir ~= "" then
        local default_dir = StorefrontScreensaverMgr.getDefaultScreensaverFolder()
        if custom_dir:gsub("[/\\]+$", "") ~= default_dir:gsub("[/\\]+$", "") then
            return custom_dir:gsub("[/\\]+$", "")
        end
    end
    return nil
end

function StorefrontScreensaverMgr.isCustomScreensaverFolder()
    return StorefrontScreensaverMgr.getCustomScreensaverFolder() ~= nil
end

function StorefrontScreensaverMgr.setCustomScreensaverFolder(path)
    local sf_settings = getStorefrontSettings()
    local r_settings = getReaderSettings()
    local default_dir = StorefrontScreensaverMgr.getDefaultScreensaverFolder()

    if not path or path:match("^%s*$") then
        return StorefrontScreensaverMgr.resetCustomScreensaverFolder()
    end

    local clean_path = path:match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean_path == "" or clean_path == default_dir:gsub("[/\\]+$", "") then
        return StorefrontScreensaverMgr.resetCustomScreensaverFolder()
    end

    local lfs = getLfs()
    if lfs and lfs.attributes and not lfs.attributes(clean_path) then
        pcall(function() lfs.mkdir(clean_path) end)
    end

    saveSettingSafe(sf_settings, "screensaver_custom_folder", clean_path)
    flushSafe(sf_settings)

    saveSettingSafe(r_settings, "screensaver_dir", clean_path)
    saveSettingSafe(r_settings, "screensaver_random_dir", clean_path)
    saveSettingSafe(r_settings, "screensaver_images_dir", clean_path)
    saveSettingSafe(r_settings, "screensaver_folder", clean_path)
    saveSettingSafe(r_settings, "screensaver_custom_dir", clean_path)
    flushSafe(r_settings)
    return true
end

function StorefrontScreensaverMgr.resetCustomScreensaverFolder()
    local sf_settings = getStorefrontSettings()
    local r_settings = getReaderSettings()
    local default_dir = StorefrontScreensaverMgr.getDefaultScreensaverFolder()

    saveSettingSafe(sf_settings, "screensaver_custom_folder", nil)
    flushSafe(sf_settings)

    saveSettingSafe(r_settings, "screensaver_dir", default_dir)
    saveSettingSafe(r_settings, "screensaver_random_dir", default_dir)
    saveSettingSafe(r_settings, "screensaver_images_dir", default_dir)
    saveSettingSafe(r_settings, "screensaver_folder", default_dir)
    saveSettingSafe(r_settings, "screensaver_custom_dir", nil)
    flushSafe(r_settings)
    return true
end

function StorefrontScreensaverMgr.getScreensaverFolder()
    local custom_dir = StorefrontScreensaverMgr.getCustomScreensaverFolder()
    local dir = custom_dir or StorefrontScreensaverMgr.getDefaultScreensaverFolder()
    local lfs = getLfs()
    if lfs and lfs.attributes and not lfs.attributes(dir) then
        pcall(function() lfs.mkdir(dir) end)
    end
    return dir
end

function StorefrontScreensaverMgr.getScreensaverSettings()
    local settings = getReaderSettings()
    local s_type = readSettingSafe(settings, "screensaver_type", "cover")
    local s_mode = readSettingSafe(settings, "screensaver_mode", "single")
    local s_file = readSettingSafe(settings, "screensaver_document_cover", nil)
        or readSettingSafe(settings, "screensaver_file", nil)
        or readSettingSafe(settings, "screensaver_image", "")
    local s_dir = StorefrontScreensaverMgr.getScreensaverFolder()
    
    local banner = readSettingSafe(settings, "screensaver_banner", nil)
    local is_banner = (banner == true or (type(banner) == "table" and banner.enabled ~= false))
    local stretch = isTrueSetting(settings, "screensaver_stretch_images") or isTrueSetting(settings, "screensaver_stretch")
    local invert = isTrueSetting(settings, "screensaver_invert") or isTrueSetting(settings, "screensaver_random_invert")
    local background = readSettingSafe(settings, "screensaver_img_background", "black")
    if background ~= "black" and background ~= "white" and background ~= "none" then
        background = "black"
    end

    local effective_mode = "cover"
    if s_type == "random_image" or (s_type == "image" and (s_mode == "random" or s_mode == "folder" or s_mode == "shuffle")) then
        effective_mode = "shuffle"
    elseif s_type == "document_cover" or s_type == "image_file" or s_type == "image" then
        effective_mode = "single"
    elseif s_type == "cover" then
        effective_mode = "cover"
    elseif s_type == "bookstatus" or s_type == "book_status" or s_type == "readingprogress" or s_type == "reading_progress" then
        effective_mode = "book_status"
    elseif s_type == "disable" or s_type == "blank" or s_type == "disabled" then
        effective_mode = "blank"
    else
        effective_mode = s_type or "cover"
    end

    return {
        type = s_type,
        mode = s_mode,
        file = s_file,
        dir = s_dir,
        effective_mode = effective_mode,
        banner = is_banner,
        stretch = stretch,
        invert = invert,
        background = background,
    }
end

function StorefrontScreensaverMgr.setScreensaverMode(mode, params)
    params = params or {}
    local settings = getReaderSettings()
    local default_dir = StorefrontScreensaverMgr.getScreensaverFolder()

    if mode == "single" then
        local target_file = params.file
        if not target_file or target_file == "" then
            local list = StorefrontScreensaverMgr.listLocalScreensavers()
            if #list > 0 then
                target_file = list[1].filepath
            end
        end

        saveSettingSafe(settings, "screensaver_type", "document_cover")
        saveSettingSafe(settings, "screensaver_mode", "single")
        if target_file and target_file ~= "" then
            saveSettingSafe(settings, "screensaver_document_cover", target_file)
            saveSettingSafe(settings, "screensaver_file", target_file)
            saveSettingSafe(settings, "screensaver_image", target_file)
        end
    elseif mode == "shuffle" then
        local target_dir = params.dir or default_dir
        saveSettingSafe(settings, "screensaver_type", "random_image")
        saveSettingSafe(settings, "screensaver_mode", "random")
        saveSettingSafe(settings, "screensaver_dir", target_dir)
        saveSettingSafe(settings, "screensaver_random_dir", target_dir)
        saveSettingSafe(settings, "screensaver_images_dir", target_dir)
        saveSettingSafe(settings, "screensaver_folder", target_dir)
    elseif mode == "cover" then
        saveSettingSafe(settings, "screensaver_type", "cover")
        saveSettingSafe(settings, "screensaver_mode", "single")
    elseif mode == "book_status" then
        saveSettingSafe(settings, "screensaver_type", "bookstatus")
    elseif mode == "blank" then
        saveSettingSafe(settings, "screensaver_type", "disable")
    end

    if params.background ~= nil then
        saveSettingSafe(settings, "screensaver_img_background", params.background)
    end
    if params.banner ~= nil then
        saveSettingSafe(settings, "screensaver_banner", params.banner)
    end
    if params.stretch ~= nil then
        saveSettingSafe(settings, "screensaver_stretch_images", params.stretch)
        saveSettingSafe(settings, "screensaver_stretch", params.stretch)
    end
    if params.invert ~= nil then
        saveSettingSafe(settings, "screensaver_invert", params.invert)
        saveSettingSafe(settings, "screensaver_random_invert", params.invert)
    end

    flushSafe(settings)
    return true
end

local function extractScreensaverTitleAndAuthor(filename, catalog_map)
    local item_id = filename:gsub("%..+$", "")
    local matched = catalog_map and (catalog_map[item_id:lower()] or catalog_map[filename:lower()])
    if matched and matched.title and matched.title ~= "" then
        return matched.title, (matched.author or "")
    end

    local raw_name = item_id
    local author = ""
    local title = raw_name

    -- Check if catalog has known authors that prefix this filename
    if catalog_map then
        for _, entry in pairs(catalog_map) do
            if entry.author and entry.author ~= "" then
                local auth_slug = entry.author:lower():gsub("[%s_]+", "-")
                if raw_name:lower():sub(1, #auth_slug + 1) == auth_slug .. "-" then
                    author = entry.author
                    title = raw_name:sub(#auth_slug + 2)
                    break
                end
            end
        end
    end

    -- If author wasn't found from catalog, check if filename starts with author handle (e.g. whisperingsea4-...)
    if title == raw_name and raw_name:find("-") then
        local first_part, rest = raw_name:match("^([%w_]+)%-(.+)$")
        if first_part and rest then
            if rest:find("-") or rest:find("_") or first_part:match("%d$") then
                author = first_part
                title = rest
            end
        end
    end

    local clean_title = title:gsub("[-_]", " ")
    clean_title = clean_title:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)

    return clean_title, author
end

function StorefrontScreensaverMgr.listLocalScreensavers(custom_dir)
    local dir = custom_dir or StorefrontScreensaverMgr.getScreensaverFolder()
    local lfs = getLfs()
    local result = {}

    if not lfs or not lfs.attributes or lfs.attributes(dir, "mode") ~= "directory" then
        return result
    end

    local current_settings = StorefrontScreensaverMgr.getScreensaverSettings()
    local active_file = current_settings.file or ""

    local catalog_map = {}
    local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
    if ok_ss and StorefrontScreensavers and StorefrontScreensavers.getCachedCatalog then
        local cat = StorefrontScreensavers.getCachedCatalog()
        if type(cat) == "table" then
            for _, item in ipairs(cat) do
                if item.id then catalog_map[tostring(item.id):lower()] = item end
                if item.filename then catalog_map[tostring(item.filename):lower()] = item end
            end
        end
    end

    local cache_dir = nil
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    end

    for filename in lfs.dir(dir) do
        if filename ~= "." and filename ~= ".." then
            local lower = filename:lower()
            if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                local fullpath = dir .. "/" .. filename
                local attr = lfs.attributes(fullpath)
                if attr and attr.mode == "file" then
                    local item_id = filename:gsub("%..+$", "")
                    local matched = catalog_map[item_id:lower()] or catalog_map[filename:lower()]
                    local clean_title, author = extractScreensaverTitleAndAuthor(filename, catalog_map)

                    local active_file_str = tostring(active_file or "")
                    local is_active = (active_file_str ~= "" and (fullpath == active_file_str or filename == (active_file_str:match("([^/\\]+)$") or active_file_str)))

                    local thumb_file = nil
                    if cache_dir and lfs.attributes then
                        local p_png = cache_dir .. "/" .. tostring(item_id) .. ".png"
                        local p_jpg = cache_dir .. "/" .. tostring(item_id) .. ".jpg"
                        if lfs.attributes(p_png, "mode") == "file" then
                            thumb_file = p_png
                        elseif lfs.attributes(p_jpg, "mode") == "file" then
                            thumb_file = p_jpg
                        end
                    end

                    table.insert(result, {
                        filename = filename,
                        filepath = fullpath,
                        title = clean_title,
                        author = author,
                        size = attr.size or 0,
                        mtime = attr.modification or 0,
                        is_active_single = is_active,
                        id = item_id,
                        thumbnail_file = thumb_file or fullpath,
                        catalog_item = matched,
                    })
                end
            end
        end
    end

    table.sort(result, function(a, b)
        return (a.mtime or 0) > (b.mtime or 0)
    end)

    return result
end

function StorefrontScreensaverMgr.isWallpaperDownloaded(item)
    if not item then return false, nil end
    local dir = StorefrontScreensaverMgr.getScreensaverFolder()
    local lfs = getLfs()
    if not lfs or not lfs.attributes then return false, nil end

    local id = tostring(item.id or item.name or "")
    if id == "" then return false, nil end

    local candidates = {
        dir .. "/" .. id .. ".jpg",
        dir .. "/" .. id .. ".png",
        dir .. "/" .. id .. ".jpeg",
    }
    if item.filename then
        table.insert(candidates, 1, dir .. "/" .. item.filename)
    end

    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "file" then
            return true, path
        end
    end
    return false, nil
end

function StorefrontScreensaverMgr.deleteLocalScreensaver(filepath)
    if not filepath or filepath == "" then return false end
    local lfs = getLfs()
    if lfs and lfs.attributes and lfs.attributes(filepath, "mode") == "file" then
        local current_settings = StorefrontScreensaverMgr.getScreensaverSettings()
        local is_active = (current_settings.file == filepath or filepath:match("([^/\\]+)$") == (current_settings.file or ""):match("([^/\\]+)$"))

        local ok, err = os.remove(filepath)
        if ok then
            if is_active and current_settings.effective_mode == "single" then
                local remaining = StorefrontScreensaverMgr.listLocalScreensavers()
                if #remaining > 0 then
                    StorefrontScreensaverMgr.setScreensaverMode("single", { file = remaining[1].filepath })
                else
                    StorefrontScreensaverMgr.setScreensaverMode("cover")
                end
            end
            return true
        else
            return false, err
        end
    end
    return false, "File not found"
end

function StorefrontScreensaverMgr.downloadWallpaper(item, callback)
    local StorefrontScreensavers = require("storefront_screensavers_ui")
    local dir = StorefrontScreensaverMgr.getScreensaverFolder()

    local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
    local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil
    local raw_url = tostring(item.fullUrl or item.thumbnailUrl or ""):lower()
    local ext = (is_transparent or raw_url:find("%.png")) and ".png" or ".jpg"

    local filename = dir .. "/" .. tostring(item.id) .. ext
    local target_url = item.fullUrl or item.thumbnailUrl
    if not target_url or target_url == "" then
        if callback then callback(false, "No download URL available") end
        return
    end

    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = StorefrontScreensavers.requestWithRedirects(target_url, sink_fn)
    if ok and code == 200 then
        local tmp_file = filename .. ".tmp"
        local file = io.open(tmp_file, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()
            os.remove(filename)
            local ok_ren = os.rename(tmp_file, filename)
            if ok_ren then
                local ok_r, StorefrontRatings = pcall(require, "storefront_ratings")
                if ok_r and StorefrontRatings and StorefrontRatings.trackDownload then
                    StorefrontRatings.trackDownload(item, "screensaver")
                end
                if callback then callback(true, filename) end
                return filename
            end
        end
    end

    if callback then callback(false, "Download failed (code " .. tostring(code) .. ")") end
    return nil
end

return StorefrontScreensaverMgr
