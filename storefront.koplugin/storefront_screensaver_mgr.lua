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
    local ok_ss, StorefrontSettings = pcall(require, "storefront_settings")
    if ok_ss and StorefrontSettings then
        return StorefrontSettings.getSettings()
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

local _cached_cat_ref = nil
local _cached_cat_index = nil

local function getCatalogIndex(cat)
    if not cat or type(cat) ~= "table" then return nil end
    if _cached_cat_ref == cat and _cached_cat_index then
        return _cached_cat_index
    end
    local map = {}
    local authors = {}
    for _, item in ipairs(cat) do
        if item.id then map[tostring(item.id):lower()] = item end
        if item.filename then map[tostring(item.filename):lower()] = item end
        if item.author and item.author ~= "" then
            local auth_slug = item.author:lower():gsub("[%s_]+", "-")
            authors[auth_slug] = item.author
        end
    end
    _cached_cat_ref = cat
    _cached_cat_index = { map = map, authors = authors }
    return _cached_cat_index
end

local function extractScreensaverTitleAndAuthor(filename, catalog_idx)
    local item_id = filename:gsub("%..+$", "")
    local cat_map = catalog_idx and (catalog_idx.map or catalog_idx)
    local authors_map = catalog_idx and catalog_idx.authors
    local matched = cat_map and (cat_map[item_id:lower()] or cat_map[filename:lower()])
    if matched and matched.title and matched.title ~= "" then
        return matched.title, (matched.author or "")
    end

    local raw_name = item_id
    local author = ""
    local title = raw_name

    -- Fast O(1) prefix check against known catalog author slugs
    if authors_map and raw_name:find("-") then
        local lower_name = raw_name:lower()
        -- Try up to 4 hyphen-delimited prefix segments
        local parts = {}
        for part in raw_name:gmatch("[^%-]+") do
            table.insert(parts, part)
            if #parts >= 5 then break end
        end
        for num_parts = math.min(4, #parts - 1), 1, -1 do
            local slug_candidate = table.concat(parts, "-", 1, num_parts):lower()
            if authors_map[slug_candidate] then
                author = authors_map[slug_candidate]
                title = raw_name:sub(#slug_candidate + 2)
                break
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

function StorefrontScreensaverMgr.countLocalScreensavers(custom_dir)
    local dir = custom_dir or StorefrontScreensaverMgr.getScreensaverFolder()
    local lfs = getLfs()
    if not lfs or not lfs.attributes or lfs.attributes(dir, "mode") ~= "directory" then
        return 0
    end
    local count = 0
    pcall(function()
        for filename in lfs.dir(dir) do
            if filename:sub(1, 1) ~= "." then
                local lower = filename:lower()
                if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                    local fullpath = dir .. "/" .. filename
                    local attr = lfs.attributes(fullpath)
                    if attr and attr.mode == "file" and (attr.size or 0) > 0 then
                        count = count + 1
                    end
                end
            end
        end
    end)
    return count
end

function StorefrontScreensaverMgr.getActiveScreensaverIdentifiers()
    local settings = StorefrontScreensaverMgr.getScreensaverSettings()
    local lfs = getLfs()
    local protected_keys = {}

    local function addIdentifier(filepath_or_filename)
        if not filepath_or_filename or filepath_or_filename == "" then return end
        local fname = filepath_or_filename:match("([^/\\]+)$") or filepath_or_filename
        if fname:sub(1, 1) == "." then return end
        local stem = fname:gsub("%..+$", "")
        protected_keys[fname:lower()] = true
        protected_keys[stem:lower()] = true
    end

    if settings.effective_mode == "single" then
        addIdentifier(settings.file)
    elseif settings.effective_mode == "shuffle" then
        local dir = settings.dir or StorefrontScreensaverMgr.getScreensaverFolder()
        if lfs and lfs.attributes and lfs.attributes(dir, "mode") == "directory" then
            pcall(function()
                for filename in lfs.dir(dir) do
                    if filename:sub(1, 1) ~= "." then
                        local lower = filename:lower()
                        if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                            addIdentifier(filename)
                        end
                    end
                end
            end)
        end
    end

    -- Correlate with catalog entries if available
    local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
    if ok_ss and StorefrontScreensavers and StorefrontScreensavers.getCachedCatalog then
        local cat = StorefrontScreensavers.getCachedCatalog()
        if type(cat) == "table" then
            for _, item in ipairs(cat) do
                local id_str = item.id and tostring(item.id):lower()
                local fname_str = item.filename and tostring(item.filename):lower()
                if (id_str and protected_keys[id_str]) or (fname_str and (protected_keys[fname_str] or protected_keys[fname_str:gsub("%..+$", "")])) then
                    if id_str then protected_keys[id_str] = true end
                    if fname_str then
                        protected_keys[fname_str] = true
                        protected_keys[fname_str:gsub("%..+$", "")] = true
                    end
                end
            end
        end
    end

    return protected_keys
end

function StorefrontScreensaverMgr.listLocalScreensavers(custom_dir)
    local dir = custom_dir or StorefrontScreensaverMgr.getScreensaverFolder()
    local lfs = getLfs()
    local result = {}

    if not lfs or not lfs.attributes or lfs.attributes(dir, "mode") ~= "directory" then
        return result
    end

    -- Collect local files first
    local local_files = {}
    pcall(function()
        for filename in lfs.dir(dir) do
            if filename:sub(1, 1) ~= "." then
                local lower = filename:lower()
                if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") or lower:match("%.bmp$") or lower:match("%.webp$") then
                    local fullpath = dir .. "/" .. filename
                    local attr = lfs.attributes(fullpath)
                    if attr and attr.mode == "file" and (attr.size or 0) > 0 then
                        table.insert(local_files, {
                            filename = filename,
                            fullpath = fullpath,
                            size = attr.size or 0,
                            mtime = attr.modification or 0,
                        })
                    end
                end
            end
        end
    end)

    if #local_files == 0 then
        return result
    end

    local current_settings = StorefrontScreensaverMgr.getScreensaverSettings()
    local active_file = current_settings.file or ""

    local catalog_idx = nil
    local ok_ss, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
    if ok_ss and StorefrontScreensavers and StorefrontScreensavers.getCachedCatalog then
        local cat = StorefrontScreensavers.getCachedCatalog()
        if type(cat) == "table" then
            catalog_idx = getCatalogIndex(cat)
        end
    end
    local cat_map = catalog_idx and catalog_idx.map or {}

    local cache_dir = nil
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    end

    for _, file_info in ipairs(local_files) do
        local filename = file_info.filename
        local fullpath = file_info.fullpath
        local item_id = filename:gsub("%..+$", "")
        local matched = cat_map[item_id:lower()] or cat_map[filename:lower()]
        local clean_title, author = extractScreensaverTitleAndAuthor(filename, catalog_idx)

        local active_file_str = tostring(active_file or "")
        local is_active = (active_file_str ~= "" and (fullpath == active_file_str or filename == (active_file_str:match("([^/\\]+)$") or active_file_str)))

        local thumb_file = nil
        if cache_dir and lfs.attributes then
            local candidates = {
                cache_dir .. "/" .. tostring(item_id) .. ".png",
                cache_dir .. "/" .. tostring(item_id) .. ".jpg",
                cache_dir .. "/" .. tostring(item_id) .. ".jpeg",
            }
            if matched and matched.id and tostring(matched.id) ~= tostring(item_id) then
                table.insert(candidates, cache_dir .. "/" .. tostring(matched.id) .. ".png")
                table.insert(candidates, cache_dir .. "/" .. tostring(matched.id) .. ".jpg")
                table.insert(candidates, cache_dir .. "/" .. tostring(matched.id) .. ".jpeg")
            end
            for _, cp in ipairs(candidates) do
                local attr_c = lfs.attributes(cp)
                if attr_c and attr_c.mode == "file" and (attr_c.size or 0) > 0 then
                    thumb_file = cp
                    break
                end
            end
        end

        table.insert(result, {
            filename = filename,
            filepath = fullpath,
            title = clean_title,
            author = author,
            size = file_info.size,
            mtime = file_info.mtime,
            is_active_single = is_active,
            id = item_id,
            thumbnail_file = thumb_file,
            catalog_item = matched,
        })
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
            return true, (is_active and current_settings.effective_mode == "single")
        else
            return false, err
        end
    end
    return false, "File not found"
end

function StorefrontScreensaverMgr.autoFallbackAfterDelete(was_active_single, remaining_items)
    if not was_active_single then return end
    local remaining = remaining_items or StorefrontScreensaverMgr.listLocalScreensavers()
    if #remaining > 0 then
        StorefrontScreensaverMgr.setScreensaverMode("single", { file = remaining[1].filepath })
    else
        StorefrontScreensaverMgr.setScreensaverMode("cover")
    end
end

function StorefrontScreensaverMgr.downloadWallpaper(item, callback)
    local StorefrontScreensavers = require("storefront_screensavers_ui")
    if StorefrontScreensavers and StorefrontScreensavers.normalizeItem then
        StorefrontScreensavers.normalizeItem(item)
    end
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

    local tmp_file = filename .. ".tmp"
    local file_handle = nil
    local bytes_written = 0
    local sink_fn = function()
        if file_handle then
            pcall(function() file_handle:close() end)
            file_handle = nil
        end
        pcall(os.remove, tmp_file)
        file_handle = io.open(tmp_file, "wb")
        bytes_written = 0
        if not file_handle then return nil end
        return function(chunk, src_err)
            if chunk and file_handle then
                file_handle:write(chunk)
                bytes_written = bytes_written + #chunk
                return 1
            elseif not chunk and not src_err then
                if file_handle then
                    file_handle:close()
                    file_handle = nil
                end
                return 1
            else
                if file_handle then
                    file_handle:close()
                    file_handle = nil
                end
                return nil, src_err
            end
        end
    end

    local ok, code = StorefrontScreensavers.requestWithRedirects(target_url, sink_fn)
    if file_handle then
        pcall(function() file_handle:close() end)
        file_handle = nil
    end

    if ok and code == 200 and bytes_written > 64 then
        os.remove(filename)
        local ok_ren = pcall(os.rename, tmp_file, filename)
        if ok_ren then
            collectgarbage("step", 100)
            local is_rb = (item.source == "ReaderBackdrop") or (tostring(item.id or ""):match("^rb%-") ~= nil)
            if not is_rb then
                local ok_r, StorefrontRatings = pcall(require, "storefront_ratings")
                if ok_r and StorefrontRatings and StorefrontRatings.trackDownload then
                    StorefrontRatings.trackDownload(item, "screensaver")
                end
            end
            if callback then callback(true, filename) end
            return filename
        else
            pcall(os.remove, tmp_file)
        end
    else
        pcall(os.remove, tmp_file)
    end
    if callback then callback(false, "Download failed") end
    return nil
end

return StorefrontScreensaverMgr

