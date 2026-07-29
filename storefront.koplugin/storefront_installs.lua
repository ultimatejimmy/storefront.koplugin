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

local function readStore()
    local encoded = settings:readSetting(store_key)
    if type(encoded) ~= "string" or encoded == "" then
        return normalizeData({})
    end
    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("Storefront installs decode error", decoded)
        return normalizeData({})
    end
    return normalizeData(decoded)
end

local function writeStore(data)
    local payload = normalizeData(data)
    local ok, encoded = pcall(function()
        return json.encode(payload)
    end)
    if not ok then
        logger.warn("Storefront installs encode error", encoded)
        return false
    end
    settings:saveSetting(store_key, encoded)
    settings:flush()
    generation = generation + 1
    return true
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
       and a.repo_id == b.repo_id
       and a.branch == b.branch
       and a.sha == b.sha
       and a.path == b.path
       and a.is_auto_matched == b.is_auto_matched
       and a.version == b.version
       and a.installed_version == b.installed_version
       and a.tag_name == b.tag_name
       and a.pending_download == b.pending_download
       and a.full_installed == b.full_installed
       and a.download_url == b.download_url
       and a.failed_attempts == b.failed_attempts
       and a.last_attempt_ts == b.last_attempt_ts
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
    for k in pairs(data.fonts) do
        if k:lower():gsub("[%s%-_]+", "") == clean_target then
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
    local opts = InstallStore.getItemOptions(item_key)
    return opts.allow_prerelease == true
end

function InstallStore.setPreReleaseAllowed(item_key, allowed)
    local opts = InstallStore.getItemOptions(item_key)
    opts.allow_prerelease = (allowed == true)
    return InstallStore.setItemOptions(item_key, opts)
end

function InstallStore.isReleaseIgnored(item_key, tag_name)
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

