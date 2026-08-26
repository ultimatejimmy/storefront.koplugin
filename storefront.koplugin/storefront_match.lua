local Cache = require("storefront_cache")
local InstallStore = require("storefront_installs")
local PluginPaths = require("storefront_plugin_paths")
local StorefrontUtils = require("storefront_utils")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")
local _ = require("gettext")
local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = { action = function() end, info = function() end } end

local Matcher = {}

Matcher.CORE_KOREADER_PLUGINS = {
    ["archiveviewer.koplugin"] = true,
    ["autodim.koplugin"] = true,
    ["autostandby.koplugin"] = true,
    ["autosuspend.koplugin"] = true,
    ["autoturn.koplugin"] = true,
    ["autowarmth.koplugin"] = true,
    ["batterystat.koplugin"] = true,
    ["bookshortcuts.koplugin"] = true,
    ["calibre.koplugin"] = true,
    ["cloudstorage.koplugin"] = true,
    ["coverbrowser.koplugin"] = true,
    ["coverimage.koplugin"] = true,
    ["docsettingtweak.koplugin"] = true,
    ["exporter.koplugin"] = true,
    ["externalkeyboard.koplugin"] = true,
    ["gestures.koplugin"] = true,
    ["hello.koplugin"] = true,
    ["hotkeys.koplugin"] = true,
    ["httpinspector.koplugin"] = true,
    ["japanese.koplugin"] = true,
    ["keepalive.koplugin"] = true,
    ["kosync.koplugin"] = true,
    ["movetoarchive.koplugin"] = true,
    ["newsdownloader.koplugin"] = true,
    ["opds.koplugin"] = true,
    ["perceptionexpander.koplugin"] = true,
    ["profiles.koplugin"] = true,
    ["qrclipboard.koplugin"] = true,
    ["readtimer.koplugin"] = true,
    ["ssh.koplugin"] = true,
    ["statistics.koplugin"] = true,
    ["systemstat.koplugin"] = true,
    ["terminal.koplugin"] = true,
    ["texteditor.koplugin"] = true,
    ["timesync.koplugin"] = true,
    ["vocabbuilder.koplugin"] = true,
    ["wallabag.koplugin"] = true,
}

function Matcher.isDefaultPlugin(plugin, maybe_plugin, StorefrontRef)
    if type(plugin) == "table" and plugin.name == "storefront" then
        plugin = maybe_plugin
    end
    if not plugin or type(plugin) ~= "table" then return false end

    local candidates = {}
    if plugin.dirname and plugin.dirname ~= "" then
        table.insert(candidates, plugin.dirname)
    end
    if plugin.shortname and plugin.shortname ~= "" then
        table.insert(candidates, plugin.shortname)
    end
    if plugin.name and plugin.name ~= "" then
        table.insert(candidates, plugin.name)
    end
    if plugin.fullname and plugin.fullname ~= "" then
        table.insert(candidates, plugin.fullname)
    end
    if plugin.meta and type(plugin.meta) == "table" then
        if plugin.meta.name then table.insert(candidates, plugin.meta.name) end
        if plugin.meta.fullname then table.insert(candidates, plugin.meta.fullname) end
    end
    if #candidates == 0 then return false end

    local records = (InstallStore.list and InstallStore.list()) or {}

    -- 1. Explicit installed_type override check in Storefront records
    for _, cand in ipairs(candidates) do
        local clean = cand:gsub("%.koplugin$", ""):lower()
        local koplugin_key = clean .. ".koplugin"
        local rec = records[cand] or records[clean] or records[koplugin_key]
        if rec then
            if rec.installed_type == "user" then
                return false
            end
            if rec.installed_type == "core" then
                return true
            end
        end
    end

    -- 2. Check known KOReader core bundled plugins set (takes priority over catalog matches)
    for _, cand in ipairs(candidates) do
        local clean = cand:gsub("%.koplugin$", ""):lower()
        local koplugin_key = clean .. ".koplugin"
        if Matcher.CORE_KOREADER_PLUGINS[koplugin_key] or Matcher.CORE_KOREADER_PLUGINS[clean] then
            return true
        end
    end

    -- 3. Check install records with owner/repo_full_name for user-installed items
    for _, cand in ipairs(candidates) do
        local clean = cand:gsub("%.koplugin$", ""):lower()
        local koplugin_key = clean .. ".koplugin"
        local rec = records[cand] or records[clean] or records[koplugin_key]
        if rec and (rec.owner or rec.repo_full_name or rec.repo_id) then
            return false
        end
    end

    -- 4. Check if plugin matches a non-core descriptor in Storefront's catalog
    for _, cand in ipairs(candidates) do
        local clean = cand:gsub("%.koplugin$", ""):lower()
        if type(Cache.getRepoByPluginName) == "function" and Cache.getRepoByPluginName(clean) then
            return false
        end
    end

    -- 5. Check non-standard custom plugin root path
    local default_root = (PluginPaths.getDefaultPluginsRoot and PluginPaths.getDefaultPluginsRoot()) or "plugins"
    if plugin.root and plugin.root ~= "plugins" and plugin.root ~= default_root then
        return false
    end

    return false
end



function Matcher.isDefaultPatch(patch)
    return false
end

function Matcher:init(Storefront)
    Storefront.CORE_KOREADER_PLUGINS = Matcher.CORE_KOREADER_PLUGINS
    
    Storefront.isDefaultPlugin = function(self_or_plugin, plugin, maybe_plugin)
        if self_or_plugin == Storefront or (type(self_or_plugin) == "table" and self_or_plugin.name == "storefront") then
            return Matcher.isDefaultPlugin(plugin or maybe_plugin, nil, self_or_plugin)
        else
            return Matcher.isDefaultPlugin(self_or_plugin, plugin, nil)
        end
    end
    
    Storefront.isDefaultPatch = function(sf, patch)
        return Matcher.isDefaultPatch(patch)
    end

    
    Storefront.autoMatchInstalled = function(sf)
        -- 1. Plugins
        local records = (InstallStore.list and InstallStore.list()) or {}

        local current_gen = InstallStore.getGeneration and InstallStore.getGeneration() or 0
        if sf._auto_matched_gen == current_gen then
            return
        end
        sf._auto_matched_gen = current_gen

        if InstallStore.beginBatch then
            InstallStore.beginBatch()
        end

        -- Scrub any stale auto-matched records for core bundled plugins
        for plugin_key, _ in pairs(Matcher.CORE_KOREADER_PLUGINS) do
            local clean = plugin_key:gsub("%.koplugin$", "")
            local rec1 = InstallStore.get(plugin_key)
            if rec1 and rec1.is_auto_matched then
                InstallStore.remove(plugin_key)
            end
            local rec2 = InstallStore.get(clean)
            if rec2 and rec2.is_auto_matched then
                InstallStore.remove(clean)
            end
        end
        StorefrontLogger.info("AUTO-MATCH starting for installed plugins and patches")

        local installed_plugins = sf:listInstalledPlugins()
        local records = (InstallStore.list and InstallStore.list()) or {}

        local unmatched_plugins = {}
        for _, plugin in ipairs(installed_plugins) do
            local record = records[plugin.dirname]
            if not (record and record.owner and record.repo) or record.is_auto_matched then
                table.insert(unmatched_plugins, plugin)
            end
        end

        if #unmatched_plugins > 0 then
            local cached_plugins = Cache.listRepos("plugin")
            local name_map = {}

            local function isBetterMatch(existing, candidate)
                if not existing then return true end
                local ex_stars = StorefrontUtils.repoStarsValue(existing)
                local ca_stars = StorefrontUtils.repoStarsValue(candidate)
                if ca_stars ~= ex_stars then
                    return ca_stars > ex_stars
                end
                local ex_fork = existing.fork or (existing.data and existing.data.fork) or false
                local ca_fork = candidate.fork or (candidate.data and candidate.data.fork) or false
                if ex_fork ~= ca_fork then
                    return not ca_fork
                end
                return false
            end

            for _, repo in ipairs(cached_plugins) do
                if repo.name then
                    local low_name = repo.name:lower()
                    if isBetterMatch(name_map[low_name], repo) then
                        name_map[low_name] = repo
                    end
                    local clean = repo.name:gsub("%.koplugin$", ""):lower()
                    if isBetterMatch(name_map[clean], repo) then
                        name_map[clean] = repo
                    end
                end
            end

            for _, plugin in ipairs(unmatched_plugins) do
                local clean_dirname = plugin.dirname:gsub("%.koplugin$", ""):lower()
                local koplugin_key = clean_dirname .. ".koplugin"

                -- Skip auto-matching if it's a core KOReader plugin
                local is_core = Matcher.CORE_KOREADER_PLUGINS[koplugin_key] or Matcher.CORE_KOREADER_PLUGINS[clean_dirname]
                if not is_core and sf:isDefaultPlugin(plugin) then
                    is_core = true
                end

                if not is_core then
                    local repo = name_map[clean_dirname] or name_map[plugin.dirname:lower()]

                    if repo then
                        local existing_rec = records[plugin.dirname]
                        local matched_at = (existing_rec and existing_rec.matched_at) or os.time()
                        local record = {
                            owner = repo.owner,
                            repo = repo.name,
                            repo_full_name = repo.full_name,
                            repo_description = repo.description,
                            repo_id = repo.repo_id,
                            branch = repo.data and repo.data.default_branch or "main",
                            matched_at = matched_at,
                            is_auto_matched = true,
                            version = existing_rec and existing_rec.version or nil,
                            installed_version = existing_rec and existing_rec.installed_version or nil,
                            installed_tag = existing_rec and existing_rec.installed_tag or nil,
                            tag_name = existing_rec and existing_rec.tag_name or nil,
                        }
                        InstallStore.upsert(plugin.dirname, record)
                        StorefrontLogger.action(string.format("AUTO-MATCHED plugin %s -> %s", tostring(plugin.dirname), tostring(repo.full_name or repo.name)))
                    end
                end
            end
        end

        -- 2. Patches
        local patch_records = (InstallStore.listPatches and InstallStore.listPatches()) or {}
        local installed_patches = sf:listInstalledPatches()

        for _, patch in ipairs(installed_patches) do
            local record = patch_records[patch.filename]
            if not (record and record.owner and record.repo and record.path) then
                local repo, file_map = Cache.findPatchRepoAndFile(patch.filename)
                if repo and file_map then
                    local existing_patch_rec = patch_records[patch.filename]
                    local matched_at = (existing_patch_rec and existing_patch_rec.matched_at) or os.time()
                    local record = {
                        filename = patch.filename,
                        owner = repo.owner,
                        repo = repo.name,
                        repo_full_name = repo.full_name,
                        repo_id = repo.repo_id,
                        repo_description = repo.description,
                        branch = file_map.branch or repo.data and repo.data.default_branch or "HEAD",
                        path = file_map.path,
                        download_url = file_map.download_url,
                        sha = file_map.sha,
                        matched_at = matched_at,
                        is_auto_matched = true,
                    }
                    InstallStore.upsertPatch(patch.filename, record)
                    StorefrontLogger.action(string.format("AUTO-MATCHED patch %s -> %s (%s)", tostring(patch.filename), tostring(repo.full_name or repo.name), tostring(file_map.path or "")))
                end
            end
        end

        -- 3. Fonts
        local font_records = (InstallStore.listFonts and InstallStore.listFonts()) or {}
        local installed_fonts = (sf.listInstalledFonts and sf:listInstalledFonts()) or {}

        for _, font in ipairs(installed_fonts) do
            local font_name = font.font_name or font.name or font.repo or ""
            if font_name ~= "" then
                local record = font_records[font_name:lower()]
                if not (record and record.owner and (record.download_url or record.repo)) then
                    local cat_repo = Cache.getRepoByName(font.owner or "", font_name) or Cache.getRepoByName("", font_name)
                    if cat_repo then
                        local existing_font_rec = font_records[font_name:lower()]
                        local matched_at = (existing_font_rec and existing_font_rec.matched_at) or os.time()
                        local new_record = {
                            font_name = cat_repo.font_family or cat_repo.name or font_name,
                            owner = cat_repo.owner or font.owner,
                            repo = cat_repo.name or font_name,
                            full_name = cat_repo.full_name or font.full_name or font_name,
                            download_url = cat_repo.download_url or (existing_font_rec and existing_font_rec.download_url),
                            full_installed = true,
                            matched_at = matched_at,
                            is_auto_matched = true,
                            version = cat_repo.version or (existing_font_rec and existing_font_rec.version) or "1.0",
                            installed_at = (existing_font_rec and existing_font_rec.installed_at) or font.installed_at or os.time(),
                        }
                        InstallStore.upsertFont(font_name, new_record)
                        StorefrontLogger.action(string.format("AUTO-MATCHED font %s -> %s", tostring(font_name), tostring(cat_repo.full_name or cat_repo.name)))
                    end
                end
            end
        end

        if InstallStore.endBatch then
            InstallStore.endBatch()
        end
    end
    
    Storefront.cancelMatchContext = function(sf)
        sf.match_context = nil
    end
end

return Matcher
