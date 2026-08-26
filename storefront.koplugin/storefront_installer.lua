local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("storefront_cache")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GitHub = require("storefront_net_github")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local InstallStore = require("storefront_installs")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local PluginPaths = require("storefront_plugin_paths")
local StorefrontLogger = require("storefront_logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local ffiutil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local M = {}

local function ensureCacheDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = ok_ds and DataStorage:getDataDir() or ".config/koreader"
    local base = data_dir .. "/cache/Storefront"
    local util = require("util")
    util.makePath(base)
    return base
end

local function normalizeAssetVariantKey(filename)
    if not filename or filename == "" then return "" end
    local clean = filename:lower()
    clean = clean:gsub("%.zip$", "")
    -- Strip semver tags e.g. -v1.2.3, _v1.2.3, -1.2.3, .1.2.3, -2026.07
    -- Only match digits and dots in the version segment so variant suffixes (e.g. -arm, -x86) are preserved
    clean = clean:gsub("[%-_%.][vV]?%d+[%d%.]*", "")
    return clean
end

local function findMatchingAssetForUpdate(installed_asset_name, candidate_assets)
    if not candidate_assets or #candidate_assets == 0 then
        return nil
    end
    if #candidate_assets == 1 then
        return candidate_assets[1]
    end
    if not installed_asset_name or installed_asset_name == "" then
        return nil
    end

    local installed_clean = installed_asset_name:lower()
    -- 1. Exact filename match
    for _, asset in ipairs(candidate_assets) do
        if asset.name and asset.name:lower() == installed_clean then
            return asset
        end
    end

    -- 2. Version-stripped variant matching
    local installed_key = normalizeAssetVariantKey(installed_asset_name)
    if installed_key ~= "" then
        for _, asset in ipairs(candidate_assets) do
            if asset.name and normalizeAssetVariantKey(asset.name) == installed_key then
                return asset
            end
        end
    end

    return nil
end

local function downloadToFile(url, local_path)
    if not url or url == "" then
        return false, _("Missing URL")
    end
    if not local_path or local_path == "" then
        return false, _("Missing target path")
    end

    local dir = local_path:match("^(.*)/")
    if dir and dir ~= "" then
        util.makePath(dir)
    end

    local temp_path = local_path .. ".tmp"
    pcall(os.remove, temp_path)

    local file, err = io.open(temp_path, "wb")
    if not file then
        return false, err or "failed to open file for writing"
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 180)
    local request = {
        url = url,
        method = "GET",
        sink = socketutil.file_sink(file),
        redirect = true,
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT or "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
            ["Accept"] = "application/zip, application/octet-stream, */*",
        },
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    pcall(function() file:close() end)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        pcall(os.remove, temp_path)
        return false, status or code or "timeout"
    end

    if not headers then
        pcall(os.remove, temp_path)
        return false, status or code or "network error"
    end

    local res_code = tonumber(code) or 0
    if res_code ~= 200 then
        pcall(os.remove, temp_path)
        return false, status or ("HTTP " .. tostring(code))
    end

    pcall(os.remove, local_path)
    local rename_ok = os.rename(temp_path, local_path)
    if not rename_ok then
        local in_f = io.open(temp_path, "rb")
        local out_f = io.open(local_path, "wb")
        if in_f and out_f then
            out_f:write(in_f:read("*all"))
            in_f:close()
            out_f:close()
            pcall(os.remove, temp_path)
            return true, nil
        end
        pcall(os.remove, temp_path)
        return false, _("Failed to save downloaded file")
    end

    return true, nil
end

local function extractReleaseNameFallback(repo)
    if repo and repo.name then
        return repo.name
    end
    return "plugin"
end

local function detectPluginFromArchive(reader, repo)
    if not reader then return nil, _("Invalid archive reader") end
    local meta_entry = nil
    local root_dirs = {}

    for entry in reader:iterate() do
        local path = entry.path
        if path then
            local root = path:match("^([^/]+)/")
            if root then root_dirs[root] = true end
            if path:match("_meta%.lua$") then
                meta_entry = entry
            end
        end
    end

    local plugin_dirname = nil
    if meta_entry then
        plugin_dirname = meta_entry.path:match("([^/]+%.koplugin)/_meta%.lua$")
            or meta_entry.path:match("([^/]+)/_meta%.lua$")
    end

    if not plugin_dirname then
        for root in pairs(root_dirs) do
            if root:match("%.koplugin$") then
                plugin_dirname = root
                break
            end
        end
    end

    if not plugin_dirname then
        local fallback = extractReleaseNameFallback(repo)
        if fallback and fallback ~= "" then
            plugin_dirname = fallback:match("%.koplugin$") and fallback or (fallback .. ".koplugin")
        end
    end

    if not plugin_dirname then
        return nil, _("Could not detect .koplugin folder in archive")
    end

    local prefix = nil
    if meta_entry then
        prefix = meta_entry.path:match("^(.*_meta%.lua)$"):gsub("_meta%.lua$", "")
    else
        prefix = plugin_dirname .. "/"
    end

    if plugin_dirname then
        if repo and repo.name and repo.name ~= "" then
            local repo_dirname = repo.name:match("%.koplugin$") and repo.name or (repo.name .. ".koplugin")
            local clean_repo_base = repo.name:gsub("%.koplugin$", "")
            if plugin_dirname:find(clean_repo_base, 1, true) then
                plugin_dirname = repo_dirname
            end
        end

        local koplugin_match = plugin_dirname:match("(.*%.koplugin)")
        if koplugin_match then
            plugin_dirname = koplugin_match
        else
            plugin_dirname = plugin_dirname:gsub("%-[%w_%-]+$", "")
            if not plugin_dirname:match("%.koplugin$") then
                plugin_dirname = plugin_dirname .. ".koplugin"
            end
        end
    end

    return {
        plugin_dirname = plugin_dirname,
        prefix = prefix,
        meta_entry = meta_entry,
    }
end

local function extractPluginToUserDir(reader, info, dest_root)
    if not reader or not info or not info.plugin_dirname then
        return false, _("Invalid extraction parameters")
    end

    local target_dir = dest_root .. "/" .. info.plugin_dirname
    util.makePath(target_dir)

    local prefix = info.prefix or ""
    local extracted_any = false

    for entry in reader:iterate() do
        local path = entry.path
        if path and path:sub(1, #prefix) == prefix then
            local rel_path = path:sub(#prefix + 1)
            if rel_path and rel_path ~= "" then
                local full_dst = target_dir .. "/" .. rel_path
                if entry.mode == "directory" then
                    util.makePath(full_dst)
                elseif entry.mode == "file" then
                    local parent = full_dst:match("^(.*)/")
                    if parent then util.makePath(parent) end
                    reader:extractToPath(entry.path, full_dst)
                    extracted_any = true
                end
            end
        end
    end

    if not extracted_any then
        return false, _("No plugin files were extracted")
    end

    return true, target_dir
end

function M:init(Storefront)
    function Storefront:resolveNewInstallDestination(callback, on_cancel)
        local REMEMBERED_PLUGIN_INSTALL_PATH_KEY = "remembered_plugin_install_path"
        local ok_cfg, StorefrontConfig = pcall(require, "storefront_config")
        if not ok_cfg then
            ok_cfg, StorefrontConfig = pcall(require, "storefront_configuration")
        end
        if not ok_cfg then
            StorefrontConfig = {}
        end

        local ok_settings, LuaSettings = pcall(require, "luasettings")
        local StorefrontSettings = ok_settings and LuaSettings:open(DataStorage:getSettingsDir() .. "/Storefront.lua")

        local config_override = StorefrontConfig.plugin_install_path
        local remembered_path = StorefrontSettings and StorefrontSettings:readSetting(REMEMBERED_PLUGIN_INSTALL_PATH_KEY)
        local hidden_paths = (StorefrontSettings and StorefrontSettings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY)) or {}

        local dest_root, needs_prompt, candidates, all_hidden =
            PluginPaths.resolveInstallDestination(config_override, remembered_path, hidden_paths)

        if all_hidden then
            self:showConfirmDialog{
                title = _("Install to Default?"),
                text = _("All of your custom plugin folders are currently hidden (see Manage plugin paths). Install to the default plugin folder anyway?"),
                ok_text = _("Install to default"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    callback(PluginPaths.getDefaultPluginsRoot())
                end,
                cancel_callback = function()
                    if on_cancel then on_cancel() end
                end,
            }
            return
        end

        if not needs_prompt then
            callback(dest_root)
            return
        end

        local options = {}
        for _, p in ipairs(candidates or {}) do
            table.insert(options, p)
        end
        table.insert(options, PluginPaths.getDefaultPluginsRoot())

        local remember_choice = false
        local dialog
        local buttons = {}
        for _, path_option in ipairs(options) do
            local chosen_path = path_option
            table.insert(buttons, {
                {
                    text = chosen_path,
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                        if remember_choice and StorefrontSettings then
                            StorefrontSettings:saveSetting(REMEMBERED_PLUGIN_INSTALL_PATH_KEY, chosen_path)
                            StorefrontSettings:flush()
                        end
                        callback(chosen_path)
                    end,
                },
            })
        end

        table.insert(buttons, {
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end,
            },
        })

        dialog = ButtonDialog:new{
            title = _("Multiple custom plugin folders are configured. Where should this plugin be installed?"),
            title_align = "center",
            buttons = buttons,
        }

        local CheckButton = require("ui/widget/checkbutton")
        local remember_checkbox = CheckButton:new{
            text = _("Always install here (don't ask again)"),
            checked = false,
            parent = dialog,
            callback = function()
                remember_choice = not remember_choice
            end,
        }
        dialog:addWidget(remember_checkbox)

        UIManager:show(dialog)
    end

    function Storefront:renderAssetPickerModal(repo, release, custom_assets, saved_ctx)
        local storefront_theme = require("storefront_theme")
        local sc = function(val) return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val end
        local item_key = repo and repo.name or ""
        local initial_preferred = InstallStore.getPreferredAsset(item_key)

        local selected_asset = custom_assets and custom_assets[1]
        if initial_preferred and custom_assets then
            for _, a in ipairs(custom_assets) do
                if a.name and (a.name == initial_preferred or a.name:find(initial_preferred, 1, true)) then
                    selected_asset = a
                    break
                end
            end
        end

        local sw = Device.screen:getWidth()
        local sh = Device.screen:getHeight()
        local dialog_w = math.min(sw - sc(20), sc(420))

        local ui_font_size = storefront_theme.face_label_size or 18
        local title_font_size = storefront_theme.title_font_size or 22

        local title_label = TextWidget:new{
            text = string.format(_("Choose Build — %s"), repo and repo.name or "Plugin"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local title_container = FrameContainer:new{
            padding = sc(12),
            bordersize = 0,
            title_label,
        }

        local list_vg = VerticalGroup:new{ align = "left" }
        local overlay
        local row_widgets = {}

        local function update_rows()
            for _, rw in ipairs(row_widgets) do
                local is_selected = selected_asset and rw.asset.name == selected_asset.name
                local indicator = is_selected and "● " or "○ "
                local size_fmt = rw.asset.size and string.format(" (%d KB)", math.floor(rw.asset.size / 1024)) or ""
                local display_text = indicator .. rw.asset.name .. size_fmt

                rw.text_widget:setText(display_text)
                rw.frame.bordersize = is_selected and (storefront_theme.border_btn or sc(2)) or sc(1)
            end
            UIManager:setDirty(overlay, "ui")
        end

        local card_padding = sc(6)
        local card_border = storefront_theme.border_window or sc(2)
        local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

        for _, asset in ipairs(custom_assets) do
            local is_selected = selected_asset and asset.name == selected_asset.name
            local indicator = is_selected and "● " or "○ "
            local size_fmt = asset.size and string.format(" (%d KB)", math.floor(asset.size / 1024)) or ""
            local display_text = indicator .. asset.name .. size_fmt

            local text_w = TextBoxWidget:new{
                text = display_text,
                face = Font:getFace("NotoSerif-Regular.ttf", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w - sc(32),
                alignment = "left",
            }

            local row_frame = FrameContainer:new{
                padding = sc(10),
                bordersize = is_selected and (storefront_theme.border_btn or sc(2)) or sc(1),
                radius = sc(8),
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_BLACK,
                width = inner_w - sc(12),
                text_w,
            }

            local asset_ref = asset
            table.insert(row_widgets, {
                asset = asset_ref,
                frame = row_frame,
                text_widget = text_w,
            })

            local item = InputContainer:new{
                align = "center",
                row_frame
            }

            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = row_frame:getSize().w or (inner_w - sc(12)),
                                h = row_frame:getSize().h or 0,
                            }
                        end
                    }
                }
            }

            item.onTap = function()
                selected_asset = asset_ref
                update_rows()
                return true
            end

            table.insert(list_vg, item)
            table.insert(list_vg, VerticalSpan:new{ width = sc(6) })
        end

        local install_btn = Button:new{
            text = _("Install"),
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            radius = storefront_theme.radius_btn or sc(18),
            padding = sc(10),
            width = math.floor((inner_w - sc(12)) / 2),
            show_parent = overlay,
            callback = function()
                UIManager:close(overlay, "ui")
                self.pending_install_context = saved_ctx
                if selected_asset then
                    self:installPluginFromReleaseAsset(repo, release, selected_asset)
                else
                    self:_installPluginFromRepoInternal(repo)
                end
            end,
        }
        if install_btn.label_widget then
            install_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end

        local cancel_btn = Button:new{
            text = _("Cancel"),
            bordersize = sc(1),
            radius = storefront_theme.radius_btn or sc(18),
            padding = sc(10),
            width = math.floor((inner_w - sc(12)) / 2),
            show_parent = overlay,
            callback = function()
                UIManager:close(overlay, "ui")
                if saved_ctx and saved_ctx.batch_callback then
                    local cb = saved_ctx.batch_callback
                    saved_ctx.batch_callback = nil
                    cb(false, "Cancelled asset selection")
                else
                    self.pending_install_context = nil
                end
            end,
        }

        local btn_row = HorizontalGroup:new{
            align = "center",
            install_btn,
            HorizontalSpan:new{ width = sc(8) },
            cancel_btn,
        }

        local content_vg = VerticalGroup:new{
            align = "center",
            title_container,
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = sc(8) },
            list_vg,
            VerticalSpan:new{ width = sc(8) },
            FrameContainer:new{ padding = sc(4), bordersize = 0, btn_row },
        }

        local card = FrameContainer:new{
            padding = sc(6),
            radius = storefront_theme.radius_window or sc(12),
            bordersize = storefront_theme.border_window or sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg,
        }

        overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = {
                Close = { { "Back" } }
            },
            CenterContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                card,
            },
        }

        overlay.onClose = function()
            UIManager:close(overlay, "ui")
            if saved_ctx and saved_ctx.batch_callback then
                local cb = saved_ctx.batch_callback
                saved_ctx.batch_callback = nil
                cb(false, "Cancelled asset selection")
            else
                self.pending_install_context = nil
            end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    function Storefront:promptPluginInstallOptions(repo, release_override, force_show_picker)
        if not repo then
            if self.pending_install_context and self.pending_install_context.batch_callback then
                local cb = self.pending_install_context.batch_callback
                self.pending_install_context.batch_callback = nil
                cb(false, "Missing repository metadata")
            end
            return
        end

        local owner = repo.owner or (repo.data and repo.data.owner and (type(repo.data.owner) == "string" and repo.data.owner or repo.data.owner.login))
        if not owner or not repo.name then
            UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for installation."), timeout = 4 })
            if self.pending_install_context and self.pending_install_context.batch_callback then
                local cb = self.pending_install_context.batch_callback
                self.pending_install_context.batch_callback = nil
                cb(false, "Missing repository metadata for installation")
            end
            return
        end

        local saved_ctx = self.pending_install_context

        NetworkMgr:runWhenOnline(function()
            self.pending_install_context = saved_ctx
            local ok_run, run_err = pcall(function()
                local release, release_err
                if release_override and type(release_override) == "table" then
                    release = release_override
                    local override_tag = release.tag_name or release.release_tag_name
                    if (not release.assets or #release.assets == 0) and override_tag then
                        local full_release = GitHub.fetchReleaseByTag and GitHub.fetchReleaseByTag(owner, repo.name, override_tag)
                        if full_release and type(full_release) == "table" and full_release.assets and #full_release.assets > 0 then
                            release = full_release
                        end
                    end
                else
                    local ctx_record = saved_ctx and saved_ctx.plugin and InstallStore.get(saved_ctx.plugin.dirname)
                    local allow_prerelease = self.isPreReleaseAllowedForPlugin and self:isPreReleaseAllowedForPlugin(repo, ctx_record, saved_ctx and saved_ctx.plugin and saved_ctx.plugin.dirname)

                    local catalog_mode = GitHub.getCatalogMode and GitHub.getCatalogMode() or "static"
                    local catalog_repo = Cache.getRepo and (
                        Cache.getRepo("plugin", repo.full_name or repo.name)
                        or (repo.owner and repo.name and Cache.getRepo("plugin", repo.owner .. "/" .. repo.name))
                    )
                    local catalog_release = (catalog_mode == "static" and not allow_prerelease) and (
                        (repo and repo.latest_release)
                        or (repo and repo.data and repo.data.latest_release)
                        or (catalog_repo and catalog_repo.latest_release)
                        or (catalog_repo and catalog_repo.data and catalog_repo.data.latest_release)
                    ) or nil

                    local has_catalog_assets = catalog_release and type(catalog_release) == "table"
                        and catalog_release.assets and type(catalog_release.assets) == "table" and #catalog_release.assets > 0

                    if has_catalog_assets then
                        release = catalog_release
                    else
                        local progress = self:showFetchingProgress(_("Fetching release info…"))
                        if allow_prerelease then
                            local rels, err = GitHub.fetchReleases(owner, repo.name, { per_page = 10, max_pages = 1 })
                            if rels and #rels > 0 then
                                for _, rel in ipairs(rels) do
                                    if not rel.draft then
                                        release = rel
                                        break
                                    end
                                end
                            end
                            if release and (not release.assets or #release.assets == 0) and release.tag_name then
                                local full_rel = GitHub.fetchReleaseByTag and GitHub.fetchReleaseByTag(owner, repo.name, release.tag_name)
                                if full_rel and type(full_rel) == "table" and full_rel.assets and #full_rel.assets > 0 then
                                    release = full_rel
                                end
                            end
                        end
                        if not release then
                            release, release_err = GitHub.fetchLatestRelease(owner, repo.name)
                        end
                        if progress and progress.close then
                            progress.close()
                        end
                    end
                end

                local assets = release and release.assets
                local custom_assets = {}
                local koplugin_assets = {}

                if type(assets) == "table" then
                    for _, asset in ipairs(assets) do
                        local name = asset and asset.name
                        local url = asset and asset.browser_download_url
                        if name and url and name:lower():match("%.zip$") then
                            table.insert(custom_assets, asset)
                            if name:lower():find("koplugin", 1, true) then
                                table.insert(koplugin_assets, asset)
                            end
                        end
                    end
                end

                local is_update = saved_ctx and saved_ctx.mode == "update"
                local target_candidates = (#koplugin_assets > 0) and koplugin_assets or custom_assets

                if #target_candidates == 1 then
                    self.pending_install_context = saved_ctx
                    self:installPluginFromReleaseAsset(repo, release, target_candidates[1])
                    return
                end

                if #target_candidates > 1 then
                    local prev_asset = nil
                    if is_update then
                        local plugin_dir = saved_ctx.plugin and saved_ctx.plugin.dirname
                        local rec = plugin_dir and InstallStore.get and InstallStore.get(plugin_dir)
                        prev_asset = (rec and rec.asset_filename)
                            or (plugin_dir and InstallStore.getPreferredAsset(plugin_dir))
                            or InstallStore.getPreferredAsset(repo.name)
                    else
                        prev_asset = InstallStore.getPreferredAsset(repo.name)
                    end

                    local matched_asset = findMatchingAssetForUpdate(prev_asset, target_candidates)
                    if matched_asset then
                        self.pending_install_context = saved_ctx
                        self:installPluginFromReleaseAsset(repo, release, matched_asset)
                        return
                    end

                    self:renderAssetPickerModal(repo, release, target_candidates, saved_ctx)
                    return
                end

                local tag_name = (release and release.tag_name and release.tag_name ~= "") and release.tag_name or nil
                local download_url = (release and release.zipball_url) or (tag_name and string.format("https://github.com/%s/%s/archive/refs/tags/%s.zip", owner, repo.name, tag_name))
                
                if download_url then
                    local source_code_name = string.format("Source code (%s.zip)", tag_name or "latest")
                    self.pending_install_context = saved_ctx
                    self:installPluginFromReleaseAsset(repo, release or { tag_name = tag_name }, {
                        name = source_code_name,
                        browser_download_url = download_url,
                    })
                else
                    self.pending_install_context = saved_ctx
                    self:_installPluginFromRepoInternal(repo)
                end
            end)
            if not ok_run then
                StorefrontLogger.err(string.format("promptPluginInstallOptions error: %s", tostring(run_err)))
                if saved_ctx and saved_ctx.batch_callback then
                    local cb = saved_ctx.batch_callback
                    saved_ctx.batch_callback = nil
                    cb(false, tostring(run_err))
                end
            end
        end)
    end

    function Storefront:installPluginFromRepo(repo)
        if not repo then
            return
        end
        self:promptPluginInstallOptions(repo, nil, true)
    end

    function Storefront:_installPluginFromRepoInternal(repo)
        local is_repo_batch = (_G.G_storefront_batch_updating == true) or (self.pending_install_context and self.pending_install_context.is_batch)

        if (repo.kind or "plugin") ~= "plugin" then
            if not is_repo_batch then
                UIManager:show(InfoMessage:new{
                    text = _("Installation is currently only supported for plugins."),
                    timeout = 4,
                })
            end
            if self.pending_install_context and self.pending_install_context.batch_callback then
                local cb = self.pending_install_context.batch_callback
                self.pending_install_context.batch_callback = nil
                cb(false, "Installation is currently only supported for plugins")
            end
            return
        end

        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if not owner or not repo.name then
            if not is_repo_batch then
                UIManager:show(InfoMessage:new{
                    text = _("Missing repository metadata for installation."),
                    timeout = 4,
                })
            end
            if self.pending_install_context and self.pending_install_context.batch_callback then
                local cb = self.pending_install_context.batch_callback
                self.pending_install_context.batch_callback = nil
                cb(false, "Missing repository metadata for installation")
            end
            return
        end

        StorefrontLogger.action(string.format("INSTALL direct repo starting: %s/%s", owner, repo.name))

        local url
        local branch = repo.default_branch or (repo.data and repo.data.default_branch) or "main"
        local release = repo.latest_release or (repo.data and repo.data.latest_release)

        if release and type(release) == "table" then
            if release.download_url and release.download_url ~= "" then
                url = release.download_url
            elseif release.assets and type(release.assets) == "table" and #release.assets > 0 then
                for _, asset in ipairs(release.assets) do
                    if asset.name and asset.name:match("%.zip$") and asset.browser_download_url then
                        url = asset.browser_download_url
                        break
                    end
                end
                if not url and release.assets[1] then
                    url = release.assets[1].browser_download_url
                end
            elseif release.zipball_url and release.zipball_url ~= "" then
                url = release.zipball_url
            elseif release.tag_name and release.tag_name ~= "" then
                url = string.format("https://github.com/%s/%s/archive/refs/tags/%s.zip", owner, repo.name, release.tag_name)
            end
        end

        if not url or url == "" then
            if GitHub.isDirectApiEnabled() then
                url = string.format("https://api.github.com/repos/%s/%s/zipball", owner, repo.name)
            else
                url = string.format("https://github.com/%s/%s/archive/refs/heads/%s.zip", owner, repo.name, branch)
            end
        end

        local cache_dir = ensureCacheDir()
        local downloads_dir = cache_dir .. "/downloads"
        if lfs.attributes(downloads_dir, "mode") ~= "directory" then
            lfs.mkdir(downloads_dir)
        end
        local zip_path = string.format("%s/%s-%d.zip", downloads_dir, repo.name, os.time())
        local plugin_display_name = repo and (repo.name or repo.full_name) or "plugin"

        local function doInstall(ok, err)
            if not ok then
                util.removeFile(zip_path)
                if not is_repo_batch then
                    UIManager:show(InfoMessage:new{
                        text = _("Download failed: ") .. tostring(err),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, tostring(err))
                end
                return
            end

            local reader = Archiver.Reader:new()
            if not reader:open(zip_path) then
                util.removeFile(zip_path)
                if not is_repo_batch then
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to open downloaded archive."),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, "Failed to open downloaded archive")
                end
                return
            end

            local info, detect_err = detectPluginFromArchive(reader, repo)
            if not info then
                reader:close()
                util.removeFile(zip_path)
                if not is_repo_batch then
                    UIManager:show(InfoMessage:new{
                        text = detect_err or _("Could not detect plugin inside archive."),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, detect_err or "Could not detect plugin inside archive")
                end
                return
            end

            if self.pending_install_context and self.pending_install_context.mode == "update" then
                local ctx_plugin = self.pending_install_context.plugin
                if ctx_plugin and ctx_plugin.dirname and ctx_plugin.dirname ~= "" then
                    info.plugin_dirname = ctx_plugin.dirname
                end
            end

            local function proceedWithInstall(dest_root)
                local install_display_name = info and info.plugin_name or (repo and repo.name) or "plugin"
                local batch_toast = self.pending_install_context and self.pending_install_context.batch_toast
                local install_progress
                if batch_toast then
                    if batch_toast.setText then
                        batch_toast:setText(string.format(_("Installing %s…"), install_display_name))
                    end
                elseif not is_repo_batch then
                    local Toast = require("storefront_toast")
                    install_progress = Toast.show(string.format(_("Installing %s…"), install_display_name), 0)
                    if UIManager.forceRePaint then UIManager:forceRePaint() end
                end

                local ok_extract, dest_or_err = extractPluginToUserDir(reader, info, dest_root)
                reader:close()
                util.removeFile(zip_path)

                if install_progress and install_progress.close then install_progress:close() end

                if not ok_extract then
                    if not is_repo_batch then
                        UIManager:show(InfoMessage:new{
                            text = _("Installation failed: ") .. tostring(dest_or_err),
                            timeout = 6,
                        })
                    end
                    if self.pending_install_context and self.pending_install_context.batch_callback then
                        local cb = self.pending_install_context.batch_callback
                        self.pending_install_context.batch_callback = nil
                        cb(false, tostring(dest_or_err))
                    end
                    return
                end

                info.plugin_name = info.plugin_name or ((info.plugin_dirname or "plugin"):gsub("%.koplugin$", ""))
                local msg
                if self.pending_install_context and self.pending_install_context.mode == "update" then
                    if info.plugin_version and info.plugin_version ~= "" then
                        msg = string.format(_("Updated plugin \"%s\" to version %s."), info.plugin_name, info.plugin_version)
                    else
                        msg = string.format(_("Updated plugin \"%s\"."), info.plugin_name)
                    end
                else
                    if info.plugin_version and info.plugin_version ~= "" then
                        msg = string.format(_("msg_installed_plugin_version"), info.plugin_name, info.plugin_version)
                    else
                        msg = string.format(_("msg_installed_plugin"), info.plugin_name)
                    end
                end

                local is_batch = (_G.G_storefront_batch_updating == true) or (self.pending_install_context and self.pending_install_context.is_batch == true)
                StorefrontLogger.action(msg)
                if not is_batch and not _G.G_storefront_batch_updating then
                    self:showRestartConfirmation(msg)
                end

                self:handlePostInstall(info, repo)
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end

            if self.pending_install_context and self.pending_install_context.mode == "update" then
                proceedWithInstall(self.pending_install_context.plugin.root)
            else
                self:resolveNewInstallDestination(proceedWithInstall, function()
                    reader:close()
                    util.removeFile(zip_path)
                    if self.pending_install_context and self.pending_install_context.batch_callback then
                        local cb = self.pending_install_context.batch_callback
                        self.pending_install_context.batch_callback = nil
                        cb(false, "Cancelled destination selection")
                    end
                end)
            end
        end

        local batch_toast = self.pending_install_context and self.pending_install_context.batch_toast
        local dl_msg = string.format(_("Downloading %s…\nTap screen to cancel."), plugin_display_name)

        local trap_widget
        if batch_toast then
            if batch_toast.setText then
                batch_toast:setText(dl_msg)
            end
            trap_widget = batch_toast
        else
            local Toast = require("storefront_toast")
            trap_widget = Toast.show(dl_msg, 0)
        end

        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, res = Trapper:dismissableRunInSubprocess(function()
                local dl_ok, dl_err = downloadToFile(url, zip_path)
                return { ok = dl_ok, err = dl_err }
            end, trap_widget)

            if trap_widget and trap_widget ~= batch_toast and trap_widget.close then
                trap_widget:close()
            end

            if not completed then
                util.removeFile(zip_path)
                local Toast = require("storefront_toast")
                Toast.show(_("Download cancelled."), 3)
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, "Cancelled by user")
                end
                return
            end
            doInstall(res and res.ok, res and res.err)
        end)
    end

    function Storefront:installPluginFromReleaseAsset(repo, release, asset)
        local is_batch = (_G.G_storefront_batch_updating == true) or (self.pending_install_context and self.pending_install_context.is_batch == true)

        if not repo or not asset or not asset.browser_download_url then
            if not is_batch then
                UIManager:show(InfoMessage:new{ text = _("Missing asset download URL."), timeout = 4 })
            end
            if self.pending_install_context and self.pending_install_context.batch_callback then
                local cb = self.pending_install_context.batch_callback
                self.pending_install_context.batch_callback = nil
                cb(false, "Missing asset download URL")
            end
            return
        end

        local asset_name = asset.name or _("release asset")
        StorefrontLogger.action(string.format("INSTALL release asset starting: %s (%s)", tostring(asset_name), tostring(repo.name)))

        local cache_dir = ensureCacheDir()
        local downloads_dir = cache_dir .. "/downloads"
        if lfs.attributes(downloads_dir, "mode") ~= "directory" then
            lfs.mkdir(downloads_dir)
        end
        local zip_path = string.format("%s/%s-%d.zip", downloads_dir, repo.name or "plugin", os.time())

        local display_name = repo and (repo.name or repo.full_name) or asset_name
        local size_str = (asset.size and asset.size > 0)
            and string.format(" (%d KB)", math.floor(asset.size / 1024))
            or ""

        local function doInstall(ok, err)
            if not ok then
                util.removeFile(zip_path)
                if not is_batch then
                    UIManager:show(InfoMessage:new{
                        text = _("Download failed: ") .. tostring(err),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, tostring(err))
                end
                return
            end

            local reader = Archiver.Reader:new()
            if not reader:open(zip_path) then
                util.removeFile(zip_path)
                if not is_batch then
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to open downloaded archive."),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, "Failed to open downloaded archive")
                end
                return
            end

            local info, detect_err = detectPluginFromArchive(reader, repo)
            if not info then
                reader:close()
                util.removeFile(zip_path)
                if not is_batch then
                    UIManager:show(InfoMessage:new{
                        text = detect_err or _("Could not detect plugin inside archive."),
                        timeout = 6,
                    })
                end
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, detect_err or "Could not detect plugin inside archive")
                end
                return
            end

            info.asset_filename = asset.name
            info.plugin_release_tag = (release and (release.tag_name or release.name)) or info.plugin_release_tag

            if self.pending_install_context and self.pending_install_context.mode == "update" then
                local ctx_plugin = self.pending_install_context.plugin
                if ctx_plugin and ctx_plugin.dirname and ctx_plugin.dirname ~= "" then
                    info.plugin_dirname = ctx_plugin.dirname
                end
            end

            local function proceedWithInstall(dest_root)
                local pname = info and info.plugin_name or (repo and repo.name) or "plugin"
                local batch_toast = self.pending_install_context and self.pending_install_context.batch_toast
                local install_progress
                if batch_toast then
                    if batch_toast.setText then
                        batch_toast:setText(string.format(_("Installing %s…"), pname))
                    end
                elseif not is_batch then
                    local Toast = require("storefront_toast")
                    install_progress = Toast.show(string.format(_("Installing %s…"), pname), 0)
                    if UIManager.forceRePaint then UIManager:forceRePaint() end
                end

                local ok_extract, dest_or_err = extractPluginToUserDir(reader, info, dest_root)
                reader:close()
                util.removeFile(zip_path)

                if install_progress and install_progress.close then install_progress:close() end

                if not ok_extract then
                    if not is_batch then
                        UIManager:show(InfoMessage:new{
                            text = _("Installation failed: ") .. tostring(dest_or_err),
                            timeout = 6,
                        })
                    end
                    if self.pending_install_context and self.pending_install_context.batch_callback then
                        local cb = self.pending_install_context.batch_callback
                        self.pending_install_context.batch_callback = nil
                        cb(false, tostring(dest_or_err))
                    end
                    return
                end

                info.plugin_name = info.plugin_name or ((info.plugin_dirname or "plugin"):gsub("%.koplugin$", ""))
                local msg
                if self.pending_install_context and self.pending_install_context.mode == "update" then
                    if info.plugin_version and info.plugin_version ~= "" then
                        msg = string.format(_("Updated plugin \"%s\" to version %s."), info.plugin_name, info.plugin_version)
                    else
                        msg = string.format(_("Updated plugin \"%s\"."), info.plugin_name)
                    end
                else
                    if info.plugin_version and info.plugin_version ~= "" then
                        msg = string.format(_("msg_installed_plugin_version"), info.plugin_name, info.plugin_version)
                    else
                        msg = string.format(_("msg_installed_plugin"), info.plugin_name)
                    end
                end

                StorefrontLogger.action(msg)
                if not is_batch and not _G.G_storefront_batch_updating then
                    self:showRestartConfirmation(msg)
                end

                self:handlePostInstall(info, repo)
                if self.updates_menu then
                    self:updateUpdatesDialog()
                end
            end

            if self.pending_install_context and self.pending_install_context.mode == "update" then
                proceedWithInstall(self.pending_install_context.plugin.root)
            else
                self:resolveNewInstallDestination(proceedWithInstall, function()
                    reader:close()
                    util.removeFile(zip_path)
                    if self.pending_install_context and self.pending_install_context.batch_callback then
                        local cb = self.pending_install_context.batch_callback
                        self.pending_install_context.batch_callback = nil
                        cb(false, "Cancelled destination selection")
                    end
                end)
            end
        end

        local batch_toast = self.pending_install_context and self.pending_install_context.batch_toast
        local dl_msg = string.format(_("Downloading %s%s…\nTap screen to cancel."), display_name, size_str)

        local trap_widget
        if batch_toast then
            if batch_toast.setText then
                batch_toast:setText(dl_msg)
            end
            trap_widget = batch_toast
        else
            local Toast = require("storefront_toast")
            trap_widget = Toast.show(dl_msg, 0)
        end

        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, res = Trapper:dismissableRunInSubprocess(function()
                local dl_ok, dl_err = downloadToFile(asset.browser_download_url, zip_path)
                return { ok = dl_ok, err = dl_err }
            end, trap_widget)

            if trap_widget and trap_widget ~= batch_toast and trap_widget.close then
                trap_widget:close()
            end

            if not completed then
                util.removeFile(zip_path)
                local Toast = require("storefront_toast")
                Toast.show(_("Download cancelled."), 3)
                if self.pending_install_context and self.pending_install_context.batch_callback then
                    local cb = self.pending_install_context.batch_callback
                    self.pending_install_context.batch_callback = nil
                    cb(false, "Cancelled by user")
                end
                return
            end
            doInstall(res and res.ok, res and res.err)
        end)
    end
end

M.downloadToFile = downloadToFile
M.detectPluginFromArchive = detectPluginFromArchive
M.extractPluginToUserDir = extractPluginToUserDir

return M
