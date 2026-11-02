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
    -- Normalize arguments: extract the actual plugin table or string
    if type(plugin) == "string" then
        plugin = { dirname = plugin }
    end
    if type(maybe_plugin) == "table" and (maybe_plugin.dirname or maybe_plugin.dir or maybe_plugin.root or maybe_plugin.shortname) then
        plugin = maybe_plugin
    elseif type(plugin) == "table" and not (plugin.dirname or plugin.dir or plugin.root or plugin.shortname) and type(maybe_plugin) == "table" then
        plugin = maybe_plugin
    elseif type(plugin) == "table" and plugin.name == "storefront" and type(maybe_plugin) == "table" then
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
        if rec and (rec.owner or rec.repo or rec.repo_full_name or rec.repo_id) then
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



Matcher.CORE_KOREADER_FONTS = {
    ["droid"] = true,
    ["droidsans"] = true,
    ["droidserif"] = true,
    ["droidsansfallback"] = true,
    ["droidsansmono"] = true,
    ["droidmono"] = true,
    ["freefont"] = true,
    ["freesans"] = true,
    ["freeserif"] = true,
    ["freemono"] = true,
    ["nerdfonts"] = true,
    ["symbolsnerdfont"] = true,
    ["nerdfont"] = true,
    ["fontawesome"] = true,
    ["noto"] = true,
    ["notosans"] = true,
    ["notoserif"] = true,
    ["notocjk"] = true,
    ["notosanscjk"] = true,
    ["notocoloremoji"] = true,
    ["notosanscjksc"] = true,
    ["notosanscjktc"] = true,
    ["notosanscjkjp"] = true,
    ["notosanscjk_sc"] = true,
    ["notosanscjk_tc"] = true,
    ["notosanscjk_jp"] = true,
    ["libertine"] = true,
    ["linuxlibertine"] = true,
    ["ebgaramond"] = true,
    ["garamond"] = true,
    ["charis"] = true,
    ["charissil"] = true,
    ["crimson"] = true,
    ["crimsonpro"] = true,
    ["baskervald"] = true,
    ["baskervaldx"] = true,
    ["andika"] = true,
    ["tinos"] = true,
    ["arimo"] = true,
    ["cousine"] = true,
    ["xits"] = true,
    ["c059"] = true,
    ["d050000l"] = true,
    ["n019003l"] = true,
    ["n021003l"] = true,
    ["n022003l"] = true,
    ["s050000l"] = true,
    ["z003034l"] = true,
    ["host"] = true,
}

local function cleanFontNameStr(name)
    if not name or type(name) ~= "string" then return "" end
    local clean = name:gsub("%.ttf$", ""):gsub("%.otf$", ""):gsub("%.asset$", "")
    clean = clean:gsub("[%-_%s]?[Ee]xtra[%-_%s]?[Bb]old[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Ee]xtra[%-_%s]?[Bb]old[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Uu]ltra[%-_%s]?[Bb]old[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Uu]ltra[%-_%s]?[Bb]old[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Ss]emi[%-_%s]?[Bb]old[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Ss]emi[%-_%s]?[Bb]old[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Dd]emi[%-_%s]?[Bb]old[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Dd]emi[%-_%s]?[Bb]old[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Bb]old[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Bb]old[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Bb]lack[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Bb]lack[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Mm]edium[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Mm]edium[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Ll]ight[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Ll]ight[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Tt]hin[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Tt]hin[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Bb]ook[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Bb]ook[%-_%s]?[Oo]blique$", "")
    clean = clean:gsub("[%-_%s]?[Ee]xtra[%-_%s]?[Bb]old$", "")
    clean = clean:gsub("[%-_%s]?[Uu]ltra[%-_%s]?[Bb]old$", "")
    clean = clean:gsub("[%-_%s]?[Ss]emi[%-_%s]?[Bb]old$", "")
    clean = clean:gsub("[%-_%s]?[Dd]emi[%-_%s]?[Bb]old$", "")
    clean = clean:gsub("[%-_%s]?[Ee]xtra[%-_%s]?[Ll]ight$", "")
    clean = clean:gsub("[%-_%s]?[Uu]ltra[%-_%s]?[Ll]ight$", "")
    clean = clean:gsub("[%-_%s]?[Bb]old$", "")
    clean = clean:gsub("[%-_%s]?[Bb]lack$", "")
    clean = clean:gsub("[%-_%s]?[Hh]eavy$", "")
    clean = clean:gsub("[%-_%s]?[Mm]edium$", "")
    clean = clean:gsub("[%-_%s]?[Ll]ight$", "")
    clean = clean:gsub("[%-_%s]?[Tt]hin$", "")
    clean = clean:gsub("[%-_%s]?[Hh]airline$", "")
    clean = clean:gsub("[%-_%s]?[Bb]ook$", "")
    clean = clean:gsub("[%-_%s]?[Rr]oman$", "")
    clean = clean:gsub("[%-_%s]?[Nn]ormal$", "")
    clean = clean:gsub("[%-_%s]?[Rr]egular$", "")
    clean = clean:gsub("[%-_%s]?[Ii]talic$", "")
    clean = clean:gsub("[%-_%s]?[Oo]blique$", "")
    return clean:lower():gsub("[%s%-_]+", "")
end

function Matcher.isDefaultFont(font, maybe_font, StorefrontRef)
    if type(font) == "string" then
        font = { font_name = font }
    end
    if type(maybe_font) == "table" and (maybe_font.font_name or maybe_font.name or maybe_font.font_family or maybe_font.repo) then
        font = maybe_font
    elseif type(font) == "table" and not (font.font_name or font.name or font.font_family or font.repo) and type(maybe_font) == "table" then
        font = maybe_font
    elseif type(font) == "table" and font.name == "storefront" and type(maybe_font) == "table" then
        font = maybe_font
    end
    if not font or type(font) ~= "table" then return false end

    if font.is_default ~= nil then
        return font.is_default == true
    end

    local candidates = {}
    if font.font_name and font.font_name ~= "" then table.insert(candidates, font.font_name) end
    if font.name and font.name ~= "" then table.insert(candidates, font.name) end
    if font.font_family and font.font_family ~= "" then table.insert(candidates, font.font_family) end
    if font.repo and font.repo ~= "" then table.insert(candidates, font.repo) end
    if font.full_name and font.full_name ~= "" then table.insert(candidates, font.full_name) end
    if font.font_file and font.font_file ~= "" then table.insert(candidates, font.font_file) end

    if #candidates == 0 then return false end

    local font_records = (InstallStore.listFonts and InstallStore.listFonts()) or {}

    -- 1. Explicit override check in Storefront records
    for _, cand in ipairs(candidates) do
        local clean = cleanFontNameStr(cand)
        local rec = font_records[cand] or font_records[cand:lower()] or (clean ~= "" and font_records[clean])
        if rec then
            if rec.installed_type == "user" or (rec.owner and rec.owner ~= "") or (rec.download_url and rec.download_url ~= "") then
                return false
            end
            if rec.installed_type == "core" or rec.is_default == true then
                return true
            end
        end
    end

    -- 2. Check known KOReader core bundled fonts set
    for _, cand in ipairs(candidates) do
        local low = cand:lower():gsub("%.ttf$", ""):gsub("%.otf$", ""):gsub("%.asset$", "")
        local clean = cleanFontNameStr(cand)
        if Matcher.CORE_KOREADER_FONTS[low] or Matcher.CORE_KOREADER_FONTS[clean] then
            return true
        end
    end

    return false
end

function Matcher.isDefaultPatch(patch)
    return false
end

function Matcher:init(Storefront)
    Storefront.CORE_KOREADER_PLUGINS = Matcher.CORE_KOREADER_PLUGINS
    Storefront.CORE_KOREADER_FONTS = Matcher.CORE_KOREADER_FONTS
    
    Storefront.isDefaultPlugin = function(self_or_plugin, plugin, maybe_plugin)
        return Matcher.isDefaultPlugin(self_or_plugin, plugin, maybe_plugin)
    end
    
    Storefront.isDefaultFont = function(self_or_font, font, maybe_font)
        return Matcher.isDefaultFont(self_or_font, font, maybe_font)
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

        -- Scrub orphan records from InstallStore that no longer exist on disk
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
        local disk_plugin_set = {}
        for _, plugin in ipairs(installed_plugins) do
            if plugin.dirname then
                disk_plugin_set[plugin.dirname] = true
                disk_plugin_set[plugin.dirname:gsub("%.koplugin$", "")] = true
            end
            if plugin.shortname then
                disk_plugin_set[plugin.shortname] = true
            end
        end

        local lookup_roots = (PluginPaths and PluginPaths.getLookupPaths and PluginPaths.getLookupPaths()) or {}
        for rec_key, _ in pairs(records) do
            local clean_key = rec_key:gsub("%.koplugin$", "")
            if not disk_plugin_set[rec_key] and not disk_plugin_set[clean_key] then
                local exists_on_disk = false
                if ok_lfs and lfs and lfs.attributes then
                    for _, root in ipairs(lookup_roots) do
                        if lfs.attributes(root .. "/" .. rec_key, "mode") == "directory"
                           or lfs.attributes(root .. "/" .. clean_key .. ".koplugin", "mode") == "directory" then
                            exists_on_disk = true
                            break
                        end
                    end
                end
                if not exists_on_disk then
                    InstallStore.remove(rec_key)
                    InstallStore.remove(clean_key)
                end
            end
        end

        local unmatched_plugins = {}
        for _, plugin in ipairs(installed_plugins) do
            local record = records[plugin.dirname]
            if record and record.source == "branch" then
                -- Explicitly branch-tracked plugins must not be auto-matched/overwritten
            elseif not (record and record.owner and record.repo) or record.is_auto_matched then
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
                            dirname = plugin.dirname,
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
