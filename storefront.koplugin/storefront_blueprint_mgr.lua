--- Storefront Blueprint Manager Module
--- Handles generation, serialization, validation, and diff calculation
--- for declarative Storefront Blueprint configurations (.blueprint).
---
--- @module StorefrontBlueprintMgr

local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local util = require("util")

local InstallStore = require("storefront_installs")
local ok_match, Matcher = pcall(require, "storefront_match")

local M = {}

M.SCHEMA_URL = "https://ultimatejimmy.github.io/storefront.koplugin/schema/v1.blueprint.json"
M.GENERATOR = "Storefront"
M.FORMAT_VERSION = 1

--- Returns the filesystem path to the blueprints directory.
--- @return string
function M.getBlueprintsDir()
    local ok_ds, DataStorageMod = pcall(require, "datastorage")
    local base_dir = (ok_ds and DataStorageMod and DataStorageMod.getDataDir and DataStorageMod:getDataDir()) or "/tmp/koreader"
    local dir = base_dir .. "/blueprints"
    if util and util.makePath then
        pcall(util.makePath, dir)
    end
    return dir
end

--- Generates a blueprint table from current system state.
--- @param options? table Optional configuration { name, author, description, version_strategy, include_plugins, include_patches, include_fonts, include_screensavers, include_settings, pinned_items, Storefront }
--- @return table blueprint
function M.generateBlueprint(options)
    options = options or {}
    local version_strategy = options.version_strategy or "latest"
    local name = options.name
    if not name or name == "" then
        name = "KOReader Setup " .. os.date("%Y-%m-%d")
    end

    local bp = {
        ["$schema"] = M.SCHEMA_URL,
        generator = M.GENERATOR,
        format_version = M.FORMAT_VERSION,
        name = name,
        author = options.author or "User",
        created_at = os.time(),
        created_by = "Storefront",
        version_strategy = version_strategy,
        description = options.description or "",
        plugins = {},
        patches = {},
        fonts = {},
        screensavers = {},
        settings = {},
    }

    local Storefront = options.Storefront

    -- 1. Plugins
    if options.include_plugins ~= false then
        local raw_records = (InstallStore and InstallStore.list and InstallStore.list()) or {}
        local installed_list = nil
        if Storefront and type(Storefront.listInstalledPlugins) == "function" then
            local ok_list, list = pcall(Storefront.listInstalledPlugins, Storefront)
            if ok_list and type(list) == "table" then
                installed_list = list
            end
        end

        if installed_list then
            -- Live device environment: ONLY export plugins actually installed on disk.
            -- Skip core default plugins shipped with KOReader.
            for _, p in ipairs(installed_list) do
                local is_default = false
                if ok_match and Matcher and Matcher.isDefaultPlugin then
                    local ok_def, def = pcall(Matcher.isDefaultPlugin, p)
                    if ok_def and def then is_default = true end
                end
                if not is_default and Storefront and Storefront.isDefaultPlugin then
                    local ok_def, def = pcall(Storefront.isDefaultPlugin, Storefront, p)
                    if ok_def and def then is_default = true end
                end
                if not is_default and p.dirname then
                    local clean_name = p.dirname:gsub("%.koplugin$", ""):lower()
                    if ok_match and Matcher and Matcher.CORE_KOREADER_PLUGINS then
                        if Matcher.CORE_KOREADER_PLUGINS[p.dirname:lower()]
                           or Matcher.CORE_KOREADER_PLUGINS[clean_name]
                           or Matcher.CORE_KOREADER_PLUGINS[clean_name .. ".koplugin"] then
                            is_default = true
                        end
                    end
                end

                if not is_default then
                    local pid = p.dirname or p.dir or p.plugin_id or p.name
                    local rec = raw_records[pid]
                        or (p.dirname and raw_records[p.dirname:gsub("%.koplugin$", "")])
                        or (p.shortname and raw_records[p.shortname])
                        or (p.name and raw_records[p.name])

                    local repo_str = nil
                    if rec and rec.owner and rec.repo then
                        repo_str = string.format("%s/%s", rec.owner, rec.repo)
                    elseif p.meta and p.meta.repo then
                        repo_str = p.meta.repo
                    end

                    -- Only export plugins that have a valid resolvable repository.
                    -- Core KOReader plugins and local custom plugins without a repo cannot be shared/installed.
                    if repo_str and repo_str ~= "" then
                        local is_pinned = false
                        if options.pinned_items and options.pinned_items[pid] ~= nil then
                            is_pinned = (options.pinned_items[pid] == true)
                        else
                            is_pinned = (version_strategy == "pinned")
                        end

                        local current_ver = (rec and (rec.installed_version or rec.version)) or p.version or ""
                        local current_tag = (rec and (rec.installed_tag or rec.tag_name)) or (p.meta and p.meta.version) or ""
                        local current_sha = (rec and rec.sha) or ""

                        local plugin_entry = {
                            id = pid,
                            name = (rec and rec.name) or p.fullname or p.name or pid,
                            repo = repo_str,
                            version = is_pinned and (current_ver ~= "" and current_ver or "latest") or "latest",
                            pinned_tag = current_tag ~= "" and current_tag or nil,
                            pinned_sha = current_sha ~= "" and current_sha or nil,
                            source = (rec and rec.source) or "release",
                            preferred_asset = (rec and rec.preferred_asset) or (InstallStore and InstallStore.getPreferredAsset and InstallStore.getPreferredAsset(pid)),
                        }
                        table.insert(bp.plugins, plugin_entry)
                    end
                end
            end
        else
            -- Headless unit test fallback when Storefront is not provided:
            -- iterate over raw_records from mock InstallStore
            for pid, rec in pairs(raw_records) do
                if type(rec) == "table" and (rec.owner and rec.repo) then
                    local is_pinned = false
                    if options.pinned_items and options.pinned_items[pid] ~= nil then
                        is_pinned = (options.pinned_items[pid] == true)
                    else
                        is_pinned = (version_strategy == "pinned")
                    end

                    local current_ver = rec.installed_version or rec.version or ""
                    local current_tag = rec.installed_tag or rec.tag_name or ""
                    local current_sha = rec.sha or ""

                    local plugin_entry = {
                        id = pid,
                        name = rec.name or pid,
                        repo = string.format("%s/%s", rec.owner, rec.repo),
                        version = is_pinned and (current_ver ~= "" and current_ver or "latest") or "latest",
                        pinned_tag = current_tag ~= "" and current_tag or nil,
                        pinned_sha = current_sha ~= "" and current_sha or nil,
                        source = rec.source or "release",
                        preferred_asset = rec.preferred_asset or (InstallStore and InstallStore.getPreferredAsset and InstallStore.getPreferredAsset(pid)),
                    }
                    table.insert(bp.plugins, plugin_entry)
                end
            end
        end

        -- Sort plugins deterministically by name
        table.sort(bp.plugins, function(a, b)
            return (a.name or a.id):lower() < (b.name or b.id):lower()
        end)
    end

    -- 2. Patches
    if options.include_patches ~= false then
        local raw_patches = (InstallStore and InstallStore.listPatches and InstallStore.listPatches()) or {}
        local installed_patches = nil
        if Storefront and type(Storefront.listInstalledPatches) == "function" then
            local ok_pt, pt_list = pcall(Storefront.listInstalledPatches, Storefront)
            if ok_pt and type(pt_list) == "table" then
                installed_patches = pt_list
            end
        end

        local disk_patches_map = nil
        if installed_patches then
            disk_patches_map = {}
            for _, pt in ipairs(installed_patches) do
                if pt.filename then
                    disk_patches_map[pt.filename] = pt
                    disk_patches_map[pt.filename:gsub("%.disabled$", "")] = pt
                    disk_patches_map[pt.filename .. ".disabled"] = pt
                end
            end
        end

        for fname, prec in pairs(raw_patches) do
            if type(prec) == "table" and (not disk_patches_map or disk_patches_map[fname]) then
                local is_pinned = false
                if options.pinned_items and options.pinned_items[fname] ~= nil then
                    is_pinned = (options.pinned_items[fname] == true)
                else
                    is_pinned = (version_strategy == "pinned")
                end

                local repo_str = nil
                if prec.owner and prec.repo then
                    repo_str = string.format("%s/%s", prec.owner, prec.repo)
                end

                local patch_entry = {
                    filename = fname,
                    name = prec.name or fname,
                    repo = repo_str,
                    version = is_pinned and (prec.version or "latest") or "latest",
                    pinned_sha = prec.sha or nil,
                }
                table.insert(bp.patches, patch_entry)
            end
        end

        table.sort(bp.patches, function(a, b)
            return (a.filename or ""):lower() < (b.filename or ""):lower()
        end)
    end

    -- 3. Fonts
    if options.include_fonts ~= false then
        local raw_fonts = (InstallStore and InstallStore.listFonts and InstallStore.listFonts()) or {}
        local installed_fonts = nil
        if Storefront and type(Storefront.listInstalledFonts) == "function" then
            local ok_f, f_list = pcall(Storefront.listInstalledFonts, Storefront)
            if ok_f and type(f_list) == "table" then
                installed_fonts = f_list
            end
        end

        local disk_fonts_map = nil
        if installed_fonts then
            disk_fonts_map = {}
            for _, f in ipairs(installed_fonts) do
                local fname = f.name or f.font_name or f.family or f.font_family or ""
                if fname ~= "" then
                    disk_fonts_map[fname:lower()] = true
                end
            end
        end

        local ok_match, Matcher = pcall(require, "storefront_match")
        local isDefaultFont = function(f)
            if ok_match and Matcher and Matcher.isDefaultFont then
                return Matcher.isDefaultFont(f)
            end
            return false
        end

        for font_key, frec in pairs(raw_fonts) do
            if type(frec) == "table" and not isDefaultFont(frec) and not isDefaultFont(font_key) and (not disk_fonts_map or disk_fonts_map[font_key:lower()] or (frec.name and disk_fonts_map[frec.name:lower()])) then
                local font_entry = {
                    name = frec.name or font_key,
                    family = frec.family or frec.name or font_key,
                    source = frec.source or "storefront",
                }
                table.insert(bp.fonts, font_entry)
            end
        end

        table.sort(bp.fonts, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end

    -- 4. Screensavers
    if options.include_screensavers ~= false then
        local ok_ss, StorefrontScreensaverMgr = pcall(require, "storefront_screensaver_mgr")
        if ok_ss and StorefrontScreensaverMgr and StorefrontScreensaverMgr.listLocalScreensavers then
            local local_ss = StorefrontScreensaverMgr.listLocalScreensavers()
            if type(local_ss) == "table" then
                for _, s in ipairs(local_ss) do
                    local ss_entry = {
                        name = s.title or s.name or s.filename or "Wallpaper",
                        category = s.category or "Wallpapers",
                        filename = s.filename or s.file,
                    }
                    table.insert(bp.screensavers, ss_entry)
                end
            end
        end
    end

    -- 5. Portable Preferences & Settings
    if options.include_settings ~= false then
        local ok_ss, StorefrontSettings = pcall(require, "storefront_settings")
        local sf_settings = ok_ss and StorefrontSettings and StorefrontSettings.getSettings and StorefrontSettings.getSettings()
        if not sf_settings then
            local ok_ds, DataStorageMod = pcall(require, "datastorage")
            local settings_dir = (ok_ds and DataStorageMod and DataStorageMod.getSettingsDir) and DataStorageMod:getSettingsDir() or "/tmp/koreader/settings"
            local ok_ls, LuaSettingsMod = pcall(require, "luasettings")
            if ok_ls and LuaSettingsMod and LuaSettingsMod.open then
                sf_settings = LuaSettingsMod:open(settings_dir .. "/Storefront.lua")
            end
        end
        if sf_settings and sf_settings.readSetting then
            local notif_enabled = sf_settings:readSetting("notification_enabled")
            if notif_enabled == nil then
                notif_enabled = sf_settings:readSetting("notifications_enabled")
            end
            if notif_enabled == nil then
                notif_enabled = true
            else
                notif_enabled = (notif_enabled == true or notif_enabled == "true" or notif_enabled == 1)
            end
            bp.settings.storefront = {
                include_zero_star_forks = sf_settings:readSetting("include_zero_star_forks") == true,
                notifications_enabled = notif_enabled,
                notification_frequency = sf_settings:readSetting("notification_frequency") or "weekly",
                catalog_mode = sf_settings:readSetting("catalog_mode") or "static",
            }
        end
    end

    return bp
end

--- Validates a blueprint table against schema rules.
--- @param bp table
--- @return boolean valid, string? error_message
function M.validateBlueprint(bp)
    if type(bp) ~= "table" then
        return false, "Blueprint payload is not a valid table or JSON object"
    end
    if bp.generator ~= M.GENERATOR then
        return false, string.format("Invalid generator '%s' (expected '%s')", tostring(bp.generator), M.GENERATOR)
    end
    if not bp.format_version or tonumber(bp.format_version) == nil or tonumber(bp.format_version) < 1 then
        return false, "Missing or invalid format_version"
    end
    if not bp.name or type(bp.name) ~= "string" or bp.name == "" then
        return false, "Missing blueprint name"
    end
    if bp.plugins and type(bp.plugins) ~= "table" then
        return false, "Invalid plugins list"
    end
    if bp.patches and type(bp.patches) ~= "table" then
        return false, "Invalid patches list"
    end
    if bp.fonts and type(bp.fonts) ~= "table" then
        return false, "Invalid fonts list"
    end
    return true, nil
end

--- Parses and validates a blueprint JSON string.
--- @param json_str string
--- @return boolean ok, table|string blueprint_or_error
function M.parseBlueprint(json_str)
    if not json_str or json_str == "" then
        return false, "Empty blueprint payload"
    end
    local ok_dec, decoded = pcall(json.decode, json_str)
    if not ok_dec or type(decoded) ~= "table" then
        return false, "Malformed JSON syntax"
    end
    local valid, err = M.validateBlueprint(decoded)
    if not valid then
        return false, err
    end
    return true, decoded
end

--- Saves a blueprint table to a `.blueprint` file.
--- @param bp table
--- @param filepath? string Optional target path; defaults to <blueprintsDir>/<sanitized_name>.blueprint
--- @return boolean success, string filepath_or_error
function M.saveToFile(bp, filepath)
    local valid, err = M.validateBlueprint(bp)
    if not valid then
        return false, err
    end

    if not filepath or filepath == "" then
        local safe_name = (bp.name or "setup"):gsub("[^%w%-_]", "_"):lower()
        if safe_name == "" then safe_name = "storefront_setup" end
        local dir = M.getBlueprintsDir()
        local candidate = string.format("%s/%s.blueprint", dir, safe_name)
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if lfs and lfs.attributes and lfs.attributes(candidate, "mode") then
            -- Avoid clobbering an existing export with the same default name
            candidate = string.format("%s/%s_%s.blueprint", dir, safe_name, os.date("%H%M%S"))
        end
        filepath = candidate
    end

    -- Ensure directory exists
    local parent_dir = filepath:match("^(.*[/\\])")
    if parent_dir and util and util.makePath then
        pcall(util.makePath, parent_dir)
    end

    local ok_enc, encoded = pcall(json.encode, bp)
    if not ok_enc or not encoded then
        return false, "Failed to encode blueprint to JSON"
    end

    local f, io_err = io.open(filepath, "w")
    if not f then
        return false, io_err or "Unable to open file for writing"
    end
    f:write(encoded)
    f:close()

    logger.info("Storefront: Exported blueprint to " .. filepath)
    return true, filepath
end

--- Loads and validates a blueprint from a file path.
--- @param filepath string
--- @return boolean success, table|string blueprint_or_error
function M.loadFromFile(filepath)
    if not filepath or filepath == "" then
        return false, "Invalid filepath"
    end
    local f, io_err = io.open(filepath, "r")
    if not f then
        return false, io_err or "Unable to read blueprint file"
    end
    local content = f:read("*a")
    f:close()
    return M.parseBlueprint(content)
end

--- Lists all available `.blueprint` files in the default blueprints directory.
--- @return table array of { name = string, path = string, modification = number }
function M.listSavedBlueprints()
    local dir = M.getBlueprintsDir()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if not ok_lfs or not lfs or not lfs.dir then
        return {}
    end

    local results = {}
    for fname in lfs.dir(dir) do
        if fname:match("%.blueprint$") then
            local fullpath = dir .. "/" .. fname
            local attrs = lfs.attributes(fullpath)
            local mod_time = (attrs and attrs.modification) or 0
            table.insert(results, {
                filename = fname,
                path = fullpath,
                modification = mod_time,
            })
        end
    end

    table.sort(results, function(a, b)
        return a.modification > b.modification
    end)
    return results
end

--- Calculates a diff between a blueprint and the local device state.
--- @param bp table The blueprint to inspect
--- @param Storefront? table Optional Storefront instance
--- @return table diff { summary, plugins, patches, fonts, screensavers }
function M.diffBlueprint(bp, Storefront)
    local diff = {
        summary = {
            total = 0,
            missing = 0,
            updates = 0,
            installed = 0,
        },
        plugins = {},
        patches = {},
        fonts = {},
        screensavers = {},
    }

    -- 1. Check local plugins
    local installed_plugins_map = {}
    local has_real_sf_plugins = (Storefront and type(Storefront.listInstalledPlugins) == "function")
    if has_real_sf_plugins then
        local ok_list, list = pcall(Storefront.listInstalledPlugins, Storefront)
        if ok_list and type(list) == "table" then
            for _, p in ipairs(list) do
                if p.dirname then
                    installed_plugins_map[p.dirname] = p
                    installed_plugins_map[p.dirname:gsub("%.koplugin$", "")] = p
                    installed_plugins_map[p.dirname:lower()] = p
                    installed_plugins_map[p.dirname:gsub("%.koplugin$", ""):lower()] = p
                end
                if p.dir then installed_plugins_map[p.dir] = p end
                if p.plugin_id then installed_plugins_map[p.plugin_id] = p end
                if p.shortname then
                    installed_plugins_map[p.shortname] = p
                    installed_plugins_map[p.shortname:lower()] = p
                end
                if p.name then
                    installed_plugins_map[p.name] = p
                    installed_plugins_map[p.name:lower()] = p
                end
                if p.fullname then
                    installed_plugins_map[p.fullname] = p
                    installed_plugins_map[p.fullname:lower()] = p
                end
            end
        end
    end

    local install_store_plugins = (InstallStore and InstallStore.list and InstallStore.list()) or {}
    if not has_real_sf_plugins then
        -- Headless unit test fallback when Storefront is not provided:
        -- use mock records from InstallStore
        for pid, rec in pairs(install_store_plugins) do
            if not installed_plugins_map[pid] then
                installed_plugins_map[pid] = rec
                installed_plugins_map[pid:gsub("%.koplugin$", "")] = rec
                installed_plugins_map[pid:lower()] = rec
                installed_plugins_map[pid:gsub("%.koplugin$", ""):lower()] = rec
            end
        end
    else
        -- Real Storefront provided: ONLY enrich plugins that actually exist on disk!
        for pid, p in pairs(installed_plugins_map) do
            local rec = install_store_plugins[pid]
                or install_store_plugins[pid .. ".koplugin"]
                or (p.dirname and install_store_plugins[p.dirname])
                or (p.shortname and install_store_plugins[p.shortname])
            if rec then
                p.installed_version = p.installed_version or rec.installed_version or rec.version
                p.installed_tag = p.installed_tag or rec.installed_tag or rec.tag_name
                p.sha = p.sha or rec.sha
            end
        end
    end

    if bp.plugins and type(bp.plugins) == "table" then
        for _, p in ipairs(bp.plugins) do
            local is_core = false
            if ok_match and Matcher and Matcher.CORE_KOREADER_PLUGINS then
                local pid_clean = p.id and p.id:gsub("%.koplugin$", ""):lower()
                if (p.id and Matcher.CORE_KOREADER_PLUGINS[p.id:lower()])
                   or (pid_clean and Matcher.CORE_KOREADER_PLUGINS[pid_clean])
                   or (pid_clean and Matcher.CORE_KOREADER_PLUGINS[pid_clean .. ".koplugin"]) then
                    is_core = true
                end
            end

            if not is_core then
                diff.summary.total = diff.summary.total + 1
                local local_match = installed_plugins_map[p.id]
                    or (p.id and installed_plugins_map[p.id:gsub("%.koplugin$", "")])
                    or (p.id and installed_plugins_map[p.id:lower()])
                    or (p.id and installed_plugins_map[p.id:gsub("%.koplugin$", ""):lower()])
                    or (p.name and installed_plugins_map[p.name])
                    or (p.name and installed_plugins_map[p.name:lower()])
                local item_diff = {
                    id = p.id,
                    name = p.name or p.id,
                    repo = p.repo,
                    blueprint_version = p.version or "latest",
                    pinned_tag = p.pinned_tag,
                    pinned_sha = p.pinned_sha,
                    source = p.source or "release",
                    preferred_asset = p.preferred_asset,
                    local_version = nil,
                    status = "missing", -- "missing" | "installed" | "update"
                    selected = true,
                }

                if local_match then
                    local local_ver = local_match.version or local_match.installed_version or local_match.installed_tag or ""
                    item_diff.local_version = local_ver

                    if p.version == "latest" then
                        item_diff.status = "installed"
                        item_diff.selected = false
                        diff.summary.installed = diff.summary.installed + 1
                    elseif p.pinned_tag and local_match.installed_tag and p.pinned_tag ~= local_match.installed_tag then
                        item_diff.status = "update"
                        item_diff.selected = true
                        diff.summary.updates = diff.summary.updates + 1
                    elseif p.pinned_sha and local_match.sha and p.pinned_sha ~= local_match.sha then
                        item_diff.status = "update"
                        item_diff.selected = true
                        diff.summary.updates = diff.summary.updates + 1
                    else
                        item_diff.status = "installed"
                        item_diff.selected = false
                        diff.summary.installed = diff.summary.installed + 1
                    end
                else
                    item_diff.status = "missing"
                    item_diff.selected = true
                    diff.summary.missing = diff.summary.missing + 1
                end
                table.insert(diff.plugins, item_diff)
            end
        end
    end

    -- 2. Check local patches
    local installed_patches_map = {}
    local has_real_sf_patches = (Storefront and type(Storefront.listInstalledPatches) == "function")
    if has_real_sf_patches then
        local ok_pt, plist = pcall(Storefront.listInstalledPatches, Storefront)
        if ok_pt and type(plist) == "table" then
            for _, pt in ipairs(plist) do
                if pt.filename then
                    installed_patches_map[pt.filename] = pt
                    installed_patches_map[pt.filename:gsub("%.disabled$", "")] = pt
                    installed_patches_map[pt.filename .. ".disabled"] = pt
                end
            end
        end
    end

    local install_store_patches = (InstallStore and InstallStore.listPatches and InstallStore.listPatches()) or {}
    if not has_real_sf_patches then
        for fname, prec in pairs(install_store_patches) do
            installed_patches_map[fname] = prec
        end
    else
        for fname, pt in pairs(installed_patches_map) do
            local prec = install_store_patches[fname] or install_store_patches[fname:gsub("%.disabled$", "")]
            if prec then
                pt.sha = pt.sha or prec.sha
                pt.version = pt.version or prec.version
            end
        end
    end

    if bp.patches and type(bp.patches) == "table" then
        for _, patch in ipairs(bp.patches) do
            diff.summary.total = diff.summary.total + 1
            local local_match = installed_patches_map[patch.filename]
                or (patch.filename and installed_patches_map[patch.filename:gsub("%.disabled$", "")])
                or (patch.filename and installed_patches_map[patch.filename .. ".disabled"])
            local item_diff = {
                filename = patch.filename,
                name = patch.name or patch.filename,
                repo = patch.repo,
                blueprint_version = patch.version or "latest",
                pinned_sha = patch.pinned_sha,
                status = "missing",
                selected = true,
            }

            if local_match then
                if patch.pinned_sha and local_match.sha and patch.pinned_sha ~= local_match.sha then
                    item_diff.status = "update"
                    item_diff.selected = true
                    diff.summary.updates = diff.summary.updates + 1
                else
                    item_diff.status = "installed"
                    item_diff.selected = false
                    diff.summary.installed = diff.summary.installed + 1
                end
            else
                item_diff.status = "missing"
                item_diff.selected = true
                diff.summary.missing = diff.summary.missing + 1
            end
            table.insert(diff.patches, item_diff)
        end
    end

    -- 3. Check local fonts
    local installed_fonts_map = {}
    local has_real_sf_fonts = (Storefront and type(Storefront.listInstalledFonts) == "function")
    if has_real_sf_fonts then
        local ok_f, flist = pcall(Storefront.listInstalledFonts, Storefront)
        if ok_f and type(flist) == "table" then
            for _, f in ipairs(flist) do
                local fname = f.name or f.font_name or f.family or f.font_family or ""
                if fname ~= "" then
                    installed_fonts_map[fname:lower()] = f
                end
            end
        end
    end

    local install_store_fonts = (InstallStore and InstallStore.listFonts and InstallStore.listFonts()) or {}
    if not has_real_sf_fonts then
        for f_name, frec in pairs(install_store_fonts) do
            installed_fonts_map[f_name:lower()] = frec
        end
    else
        for f_name, f in pairs(installed_fonts_map) do
            local frec = install_store_fonts[f_name]
            if frec then
                f.sha = f.sha or frec.sha
                f.version = f.version or frec.version
            end
        end
    end

    if bp.fonts and type(bp.fonts) == "table" then
        for _, font in ipairs(bp.fonts) do
            diff.summary.total = diff.summary.total + 1
            local key = (font.name or ""):lower()
            local local_match = installed_fonts_map[key] or (font.family and installed_fonts_map[font.family:lower()])
            local item_diff = {
                name = font.name,
                family = font.family,
                source = font.source,
                status = local_match and "installed" or "missing",
                selected = not local_match,
            }
            if local_match then
                diff.summary.installed = diff.summary.installed + 1
            else
                diff.summary.missing = diff.summary.missing + 1
            end
            table.insert(diff.fonts, item_diff)
        end
    end

    -- 4. Check local screensavers
    if bp.screensavers and type(bp.screensavers) == "table" then
        local ok_ss, StorefrontScreensaverMgr = pcall(require, "storefront_screensaver_mgr")
        local local_ss_map = {}
        if ok_ss and StorefrontScreensaverMgr and StorefrontScreensaverMgr.listLocalScreensavers then
            local ss_list = StorefrontScreensaverMgr.listLocalScreensavers()
            if type(ss_list) == "table" then
                for _, s in ipairs(ss_list) do
                    local fname = s.filename or s.file or ""
                    if fname ~= "" then
                        local basename = fname:match("([^/\\]+)$") or fname
                        local_ss_map[basename:lower()] = true
                    end
                end
            end
        end

        for _, ss in ipairs(bp.screensavers) do
            diff.summary.total = diff.summary.total + 1
            local fname = ss.filename or ss.name or ""
            local basename = fname:match("([^/\\]+)$") or fname
            local is_installed = local_ss_map[basename:lower()] == true
            local item_diff = {
                name = ss.name,
                category = ss.category,
                filename = ss.filename,
                status = is_installed and "installed" or "missing",
                selected = not is_installed,
            }
            if is_installed then
                diff.summary.installed = diff.summary.installed + 1
            else
                diff.summary.missing = diff.summary.missing + 1
            end
            table.insert(diff.screensavers, item_diff)
        end
    end

    return diff
end

return M
