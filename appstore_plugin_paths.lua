-- appstore_plugin_paths.lua
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local DEFAULT_PLUGIN_PATH = "plugins"

local M = {}

local function normalize(path)
    if not path or path == "" then
        return path
    end
    return (path:gsub("/+$", ""))
end

function M.getDefaultPluginsRoot()
    return DataStorage:getDataDir() .. "/plugins"
end

-- Same lookup order as frontend/pluginloader.lua's PluginLoader:_discover:
-- the bundled "plugins" directory, then every entry configured in the
-- extra_plugin_paths setting (existing directories only, "plugins" itself
-- excluded from the extra list to avoid double-scanning).
function M.getLookupPaths()
    local paths = { DEFAULT_PLUGIN_PATH }
    local extra = G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then
        extra = { extra }
    end
    if type(extra) == "table" then
        for _, p in ipairs(extra) do
            if normalize(p) ~= normalize(DEFAULT_PLUGIN_PATH)
                and lfs.attributes(p, "mode") == "directory" then
                table.insert(paths, p)
            end
        end
    end
    return paths
end

-- Lookup paths minus the bundled "plugins" dir and minus the historical
-- default data-dir location -- i.e. directories the user genuinely
-- configured on top of the defaults.
function M.getCustomLookupPaths()
    local default_root_norm = normalize(M.getDefaultPluginsRoot())
    local custom = {}
    for _, p in ipairs(M.getLookupPaths()) do
        local norm_p = normalize(p)
        if norm_p ~= normalize(DEFAULT_PLUGIN_PATH) and norm_p ~= default_root_norm then
            table.insert(custom, p)
        end
    end
    return custom
end

local function pathInLookup(path)
    if not path or path == "" then
        return false
    end
    local norm_path = normalize(path)
    if norm_path == normalize(DEFAULT_PLUGIN_PATH) then
        return true
    end
    for _, p in ipairs(M.getLookupPaths()) do
        if normalize(p) == norm_path then
            return true
        end
    end
    return false
end

-- Resolves the directory a freshly installed (non-update) plugin should be
-- written to.
--
-- config_override: string|nil  -- `plugin_install_path` from appstore_configuration.lua
-- remembered_path:  string|nil -- previously remembered choice (AppStoreSettings)
--
-- Returns dest_root (string|nil), needs_prompt (boolean), candidates (table|nil,
-- only set when needs_prompt is true).
function M.resolveInstallDestination(config_override, remembered_path)
    if config_override and config_override ~= "" and pathInLookup(config_override) then
        return config_override, false
    end

    if remembered_path and remembered_path ~= "" and pathInLookup(remembered_path) then
        return remembered_path, false
    end

    local custom = M.getCustomLookupPaths()
    if #custom == 1 then
        return custom[1], false
    elseif #custom >= 2 then
        return nil, true, custom
    end

    return M.getDefaultPluginsRoot(), false
end

return M
