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

function StorefrontScreensaverMgr.getScreensaverFolder()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp/koreader"
    local dir = data_dir .. "/screensavers"
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
    local s_file = readSettingSafe(settings, "screensaver_file", nil) or readSettingSafe(settings, "screensaver_image", "")
    local s_dir = readSettingSafe(settings, "screensaver_dir", nil)
        or readSettingSafe(settings, "screensaver_random_dir", nil)
        or readSettingSafe(settings, "screensaver_images_dir", nil)
        or readSettingSafe(settings, "screensaver_folder", nil)
        or StorefrontScreensaverMgr.getScreensaverFolder()
    
    local banner = readSettingSafe(settings, "screensaver_banner", nil)
    local is_banner = (banner == true or (type(banner) == "table" and banner.enabled ~= false))
    local stretch = isTrueSetting(settings, "screensaver_stretch")
    local invert = isTrueSetting(settings, "screensaver_invert") or isTrueSetting(settings, "screensaver_random_invert")

    local effective_mode = "cover"
    if s_type == "random_image" or (s_type == "image" and (s_mode == "random" or s_mode == "folder" or s_mode == "shuffle")) then
        effective_mode = "shuffle"
    elseif s_type == "image" then
        effective_mode = "single"
    elseif s_type == "cover" then
        effective_mode = "cover"
    elseif s_type == "book_status" or s_type == "reading_progress" then
        effective_mode = "book_status"
    elseif s_type == "blank" or s_type == "disabled" then
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

        saveSettingSafe(settings, "screensaver_type", "image")
        saveSettingSafe(settings, "screensaver_mode", "single")
        if target_file and target_file ~= "" then
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
    elseif mode == "cover" then
        saveSettingSafe(settings, "screensaver_type", "cover")
        saveSettingSafe(settings, "screensaver_mode", "single")
    elseif mode == "book_status" then
        saveSettingSafe(settings, "screensaver_type", "book_status")
    elseif mode == "blank" then
        saveSettingSafe(settings, "screensaver_type", "blank")
    end

    if params.banner ~= nil then
        saveSettingSafe(settings, "screensaver_banner", params.banner)
    end
    if params.stretch ~= nil then
        saveSettingSafe(settings, "screensaver_stretch", params.stretch)
    end
    if params.invert ~= nil then
        saveSettingSafe(settings, "screensaver_invert", params.invert)
        saveSettingSafe(settings, "screensaver_random_invert", params.invert)
    end

    flushSafe(settings)
    return true
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

    for filename in lfs.dir(dir) do
        if filename ~= "." and filename ~= ".." then
            local lower = filename:lower()
            if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                local fullpath = dir .. "/" .. filename
                local attr = lfs.attributes(fullpath)
                if attr and attr.mode == "file" then
                    local clean_title = filename:gsub("%..+$", ""):gsub("[-_]", " ")
                    clean_title = clean_title:gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end)

                    local active_file_str = tostring(active_file or "")
                    local is_active = (active_file_str ~= "" and (fullpath == active_file_str or filename == (active_file_str:match("([^/\\]+)$") or active_file_str)))

                    table.insert(result, {
                        filename = filename,
                        filepath = fullpath,
                        title = clean_title,
                        size = attr.size or 0,
                        mtime = attr.modification or 0,
                        is_active_single = is_active,
                        id = filename:gsub("%..+$", ""),
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
        local file = io.open(filename, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()
            if callback then callback(true, filename) end
            return filename
        end
    end

    if callback then callback(false, "Download failed (code " .. tostring(code) .. ")") end
    return nil
end

return StorefrontScreensaverMgr
