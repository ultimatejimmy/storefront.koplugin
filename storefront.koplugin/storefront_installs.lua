local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local logger = require("logger")

local InstallStore = {}

local SETTINGS_DIR = DataStorage:getSettingsDir()
local SETTINGS_PATH = SETTINGS_DIR .. "/Storefront_installs.lua"
local settings = LuaSettings:open(SETTINGS_PATH)

local store_key = "installs"

-- Bumped on every successful write, so callers can cache derived data (e.g.
-- an installed-repo lookup) and only rebuild it when records actually change.
local generation = 0

local function normalizeData(data)
    if type(data) ~= "table" then
        data = {}
    end
    if data.plugins == nil then
        data = {
            plugins = data,
            patches = {},
            fonts = {},
            item_options = {},
        }
    else
        data.patches = data.patches or {}
        data.fonts = data.fonts or {}
        data.item_options = data.item_options or {}
    end
    return data
end

local cached_store_data = nil

local function readStore()
    if cached_store_data then
        return cached_store_data
    end
    local encoded = settings:readSetting(store_key)
    if type(encoded) ~= "string" or encoded == "" then
        cached_store_data = normalizeData({})
        return cached_store_data
    end
    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("Storefront installs decode error", decoded)
        cached_store_data = normalizeData({})
        return cached_store_data
    end
    cached_store_data = normalizeData(decoded)
    return cached_store_data
end

local in_batch = false
local batch_dirty = false

local function writeStore(data)
    local payload = normalizeData(data)
    cached_store_data = payload
    generation = generation + 1
    if in_batch then
        batch_dirty = true
        return true
    end
    local ok, encoded = pcall(function()
        return json.encode(payload)
    end)
    if not ok then
        logger.warn("Storefront installs encode error", encoded)
        return false
    end
    settings:saveSetting(store_key, encoded)
    settings:flush()
    return true
end

function InstallStore.beginBatch()
    in_batch = true
    batch_dirty = false
end

function InstallStore.endBatch()
    in_batch = false
    if batch_dirty and cached_store_data then
        local ok, encoded = pcall(function()
            return json.encode(cached_store_data)
        end)
        if ok then
            settings:saveSetting(store_key, encoded)
            settings:flush()
        else
            logger.warn("Storefront installs encode error", encoded)
        end
        batch_dirty = false
    end
end

function InstallStore.list()
    return readStore().plugins
end

-- Monotonic counter bumped on every write, so callers can cache data derived
-- from the store (e.g. an installed-repo lookup) and know when to rebuild it.
function InstallStore.getGeneration()
    return generation
end

function InstallStore.listPatches()
    return readStore().patches
end

function InstallStore.listFonts()
    return readStore().fonts
end

function InstallStore.save(entries)
    local data = readStore()
    data.plugins = entries or {}
    return writeStore(data)
end

function InstallStore.savePatches(entries)
    local data = readStore()
    data.patches = entries or {}
    return writeStore(data)
end

function InstallStore.saveFonts(entries)
    local data = readStore()
    data.fonts = entries or {}
    return writeStore(data)
end

local function isRecordEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.owner == b.owner
       and a.repo == b.repo
       and a.repo_full_name == b.repo_full_name
       and a.repo_description == b.repo_description
       and a.repo_id == b.repo_id
       and a.branch == b.branch
       and a.sha == b.sha
       and a.path == b.path
       and a.filename == b.filename
       and a.is_auto_matched == b.is_auto_matched
       and a.version == b.version
       and a.installed_version == b.installed_version
       and a.installed_tag == b.installed_tag
       and a.tag_name == b.tag_name
       and a.matched_at == b.matched_at
       and a.pending_download == b.pending_download
       and a.full_installed == b.full_installed
       and a.download_url == b.download_url
       and a.failed_attempts == b.failed_attempts
       and a.asset_filename == b.asset_filename
       and a.download_error == b.download_error
end

function InstallStore.upsert(plugin_id, record)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local data = readStore()
    local existing = data.plugins[plugin_id]
    if isRecordEqual(existing, record) then
        return true
    end
    data.plugins[plugin_id] = record
    return writeStore(data)
end

function InstallStore.upsertPatch(filename, record)
    if not filename or filename == "" then
        return false
    end
    local data = readStore()
    local existing = data.patches[filename]
    -- Preserve existing SHA if new record doesn't have one (e.g., during match operation).
    -- This ensures install SHA is not lost when matching an already-installed patch.
    if existing and existing.sha and not record.sha then
        record.sha = existing.sha
    end
    if isRecordEqual(existing, record) then
        return true
    end
    data.patches[filename] = record
    return writeStore(data)
end

function InstallStore.upsertFont(font_name, record)
    if not font_name or font_name == "" then
        return false
    end
    local data = readStore()
    font_name = font_name:lower()
    local existing = data.fonts[font_name]
    if isRecordEqual(existing, record) then
        return true
    end
    data.fonts[font_name] = record
    return writeStore(data)
end

function InstallStore.remove(plugin_id)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local data = readStore()
    if data.plugins[plugin_id] == nil then
        return true
    end
    data.plugins[plugin_id] = nil
    return writeStore(data)
end

function InstallStore.removePatch(filename)
    if not filename or filename == "" then
        return false
    end
    local data = readStore()
    if data.patches[filename] == nil then
        return true
    end
    data.patches[filename] = nil
    return writeStore(data)
end

function InstallStore.removeFont(font_name)
    if not font_name or font_name == "" then
        return false
    end
    local data = readStore()
    local clean_target = font_name:lower():gsub("[%s%-_]+", "")
    local alias_map = {
        ["nvbasker"] = {"librebaskerville", "baskerville", "nvbasker", "basker"},
        ["librebaskerville"] = {"librebaskerville", "baskerville", "nvbasker", "basker"},
        ["nvbitter"] = {"bitter", "nvbitter"},
        ["bitter"] = {"bitter", "nvbitter"},
        ["nvliterata"] = {"literata", "nvliterata"},
        ["literata"] = {"literata", "nvliterata"},
        ["gentiumbookplus"] = {"gentiumplus", "gentiumbookplus", "gentium"},
        ["gentiumplus"] = {"gentiumplus", "gentiumbookplus", "gentium"},
        ["opendyslexic"] = {"opendyslexic", "opendyslexic3"},
        ["readerly"] = {"readerly", "newsreader"},
        ["sourcerer"] = {"sourcerer", "sourceserif"},
    }
    local targets = alias_map[clean_target] or { clean_target }

    for k in pairs(data.fonts) do
        local k_clean = k:lower():gsub("[%s%-_]+", "")
        local is_match = false
        for _, t in ipairs(targets) do
            if k_clean:find(t, 1, true) or t:find(k_clean, 1, true) then
                is_match = true
                break
            end
        end
        if is_match then
            data.fonts[k] = nil
        end
    end
    data.fonts[font_name:lower()] = nil
    return writeStore(data)
end

function InstallStore.get(plugin_id)
    if not plugin_id or plugin_id == "" then
        return nil
    end
    local data = readStore()
    return data.plugins[plugin_id]
end

function InstallStore.getPatch(filename)
    if not filename or filename == "" then
        return nil
    end
    local data = readStore()
    return data.patches[filename]
end

function InstallStore.getFont(font_name)
    if not font_name or font_name == "" then
        return nil
    end
    local data = readStore()
    return data.fonts[font_name:lower()]
end

function InstallStore.clear()
    return writeStore({ plugins = {}, patches = {} })
end

function InstallStore.clearPatches()
    local data = readStore()
    data.patches = {}
    return writeStore(data)
end

function InstallStore.getItemOptions(item_key)
    if not item_key or item_key == "" then
        return { allow_prerelease = false, ignored_releases = {} }
    end
    item_key = item_key:lower()
    local data = readStore()
    local opts = (data.item_options and data.item_options[item_key]) or {}
    opts.ignored_releases = opts.ignored_releases or {}
    return opts
end

function InstallStore.setItemOptions(item_key, opts)
    if not item_key or item_key == "" then
        return false
    end
    item_key = item_key:lower()
    local data = readStore()
    data.item_options[item_key] = opts or {}
    return writeStore(data)
end

function InstallStore.isPreReleaseAllowed(item_key)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    if opts.allow_prerelease == true then return true end
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        opts = InstallStore.getItemOptions(clean_key)
        if opts.allow_prerelease == true then return true end
    end
    return false
end

function InstallStore.setPreReleaseAllowed(item_key, allowed)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.allow_prerelease = (allowed == true)
    InstallStore.setItemOptions(item_key, opts)
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        local clean_opts = InstallStore.getItemOptions(clean_key)
        clean_opts.allow_prerelease = (allowed == true)
        InstallStore.setItemOptions(clean_key, clean_opts)
    end
    return true
end

function InstallStore.isAllUpdatesIgnored(item_key)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    if opts.ignore_all_updates == true then return true end
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        opts = InstallStore.getItemOptions(clean_key)
        if opts.ignore_all_updates == true then return true end
    end
    return false
end

function InstallStore.setAllUpdatesIgnored(item_key, ignored)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.ignore_all_updates = (ignored == true)
    InstallStore.setItemOptions(item_key, opts)
    local clean_key = item_key:gsub("%.koplugin$", "")
    if clean_key ~= item_key then
        local clean_opts = InstallStore.getItemOptions(clean_key)
        clean_opts.ignore_all_updates = (ignored == true)
        InstallStore.setItemOptions(clean_key, clean_opts)
    end
    return true
end

function InstallStore.toggleAllUpdatesIgnored(item_key)
    if not item_key or item_key == "" then return false end
    local current = InstallStore.isAllUpdatesIgnored(item_key)
    return InstallStore.setAllUpdatesIgnored(item_key, not current)
end

function InstallStore.isReleaseIgnored(item_key, tag_name)
    if not item_key or item_key == "" then return false end
    if InstallStore.isAllUpdatesIgnored(item_key) then return true end
    if not tag_name or tag_name == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    return opts.ignored_releases[tag_name] == true
end

function InstallStore.toggleReleaseIgnored(item_key, tag_name)
    if not tag_name or tag_name == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.ignored_releases[tag_name] = not (opts.ignored_releases[tag_name] == true)
    return InstallStore.setItemOptions(item_key, opts)
end

function InstallStore.isReleaseIgnoredByRepo(owner, repo_name, tag_name)
    if not owner or not repo_name then return false end
    local item_key = string.format("%s/%s", owner, repo_name)
    if InstallStore.isAllUpdatesIgnored(item_key) or InstallStore.isAllUpdatesIgnored(repo_name) then
        return true
    end
    if not tag_name or tag_name == "" then return false end
    return InstallStore.isReleaseIgnored(item_key, tag_name)
        or InstallStore.isReleaseIgnored(repo_name, tag_name)
end

function InstallStore.getPreferredAsset(item_key)
    if not item_key or item_key == "" then return nil end
    local opts = InstallStore.getItemOptions(item_key)
    return opts.preferred_asset
end

function InstallStore.setPreferredAsset(item_key, asset_name)
    if not item_key or item_key == "" then return false end
    local opts = InstallStore.getItemOptions(item_key)
    opts.preferred_asset = asset_name
    return InstallStore.setItemOptions(item_key, opts)
end

return InstallStore

