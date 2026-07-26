local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")
local RepoContent = require("storefront_repo_content")
local TextViewer = require("ui/widget/textviewer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local StorefrontImageModal = require("storefront_image_modal")
local InstallStore = require("storefront_installs")
local logger = require("logger")
local GestureRange = require("ui/gesturerange")
local util = require("util")
local ok_json, json = pcall(require, "json")
local json_null = (ok_json and json and json.null) or nil

local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local Input = Device.input

local StorefrontVersionDetailsDialog

local StorefrontDetailsDialog = InputContainer:extend{
    covers_fullscreen = true,
    Storefront = nil,
    repo = nil,
    patch = nil,
    kind = "plugin", -- "plugin", "patch", "update"
    update_item = nil, -- passed if updates tab
}

function StorefrontDetailsDialog:init()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()

    -- Full-screen dimen
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    -- Hardware back key closes the dialog
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end

    -- -----------------------------------------------------------------------
    -- 1. Back button (software)
    -- -----------------------------------------------------------------------
    local back_btn = Button:new{
        text = "< Back",
        text_font_size = 20,
        bordersize = sc(1),
        padding = sc(8),
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self,
        callback = function()
            self:onClose()
        end,
    }

    -- -----------------------------------------------------------------------
    -- 2. Title & Metadata
    -- -----------------------------------------------------------------------
    local function getInstallRecord()
        if self.patch then
            local patch_records = InstallStore.listPatches() or {}
            return patch_records[self.patch.filename]
        else
            local repo_name_lower = (self.repo.name or ""):lower()
            local install_records = InstallStore.list() or {}
            return install_records[repo_name_lower]
        end
    end

    local title_text = ""
    local meta_text  = ""
    local desc_text  = ""

    local owner = self.repo.owner
        or (type(self.repo.full_name) == "string" and self.repo.full_name:match("^([^/]+)/"))
        or (self.repo.data and self.repo.data.owner and (type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login))
        or (self.update_item and self.update_item.record and self.update_item.record.owner)
        or ""
    local repo_name = self.repo.name
        or (type(self.repo.full_name) == "string" and self.repo.full_name:match("^[^/]+/(.+)$"))
        or (self.update_item and self.update_item.record and self.update_item.record.repo)
        or ""
    local stars = tonumber(self.repo.stars) or (self.repo.data and tonumber(self.repo.data.stargazers_count)) or 0
    local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)

    local ts = self.repo.pushed_at or self.repo.updated_at
        or (self.repo.latest_release and type(self.repo.latest_release) == "table" and (self.repo.latest_release.published_at or self.repo.latest_release.created_at))
        or (self.repo.data and (self.repo.data.pushed_at or self.repo.data.updated_at or self.repo.data.created_at))
    local updated = (ts and type(ts) == "string") and ts:sub(1, 10) or ""

    local version_str
    if self.update_item then
        local remote = self.update_item.remote
        local plugin = self.update_item.plugin
        local remote_entry = self.update_item.remote_entry
        if remote then
            version_str = remote.release_tag_name or remote.tag_name or remote.remote_version or remote.version
        end
        if not version_str and remote_entry then
            version_str = remote_entry.sha and ("sha:" .. remote_entry.sha:sub(1, 7)) or remote_entry.version
        end
        if not version_str and plugin then
            version_str = plugin.version
        end
    end
    if not version_str and self.patch then
        version_str = self.patch.sha and ("sha:" .. self.patch.sha:sub(1, 7)) or self.patch.version
    end
    if not version_str then
        version_str = self.repo.latest_version or self.repo.version or self.repo.tag_name or self.repo.release_tag
    end
    if not version_str and self.repo.latest_release and type(self.repo.latest_release) == "table" then
        version_str = self.repo.latest_release.tag_name or self.repo.latest_release.release_tag_name or self.repo.latest_release.name or self.repo.latest_release.version
    end
    if not version_str and self.repo.data then
        if type(self.repo.data.latest_release) == "table" then
            version_str = self.repo.data.latest_release.tag_name or self.repo.data.latest_release.release_tag_name or self.repo.data.latest_release.name or self.repo.data.latest_release.version
        end
        if not version_str then
            version_str = self.repo.data.tag_name or self.repo.data.latest_version or self.repo.data.version
        end
    end

    local rec = getInstallRecord()
    if not version_str and rec then
        version_str = rec.version or rec.tag_name or rec.release_tag_name or (rec.sha and ("sha:" .. rec.sha:sub(1, 7)))
    end

    if not version_str and self.Storefront then
        if not self.patch and self.Storefront.listInstalledPlugins then
            local installed_plugins = self.Storefront:listInstalledPlugins()
            for _, p in ipairs(installed_plugins or {}) do
                local clean_p = p.dirname:gsub("%.koplugin$", ""):lower()
                local clean_repo = (self.repo.name or ""):gsub("%.koplugin$", ""):lower()
                if clean_p == clean_repo or p.dirname:lower() == (self.repo.name or ""):lower() then
                    if p.version then
                        version_str = p.version
                        break
                    end
                end
            end
        elseif self.patch and self.Storefront.listInstalledPatches then
            local installed_patches = self.Storefront:listInstalledPatches()
            for _, p in ipairs(installed_patches or {}) do
                if p.filename == self.patch.filename then
                    if p.sha then
                        version_str = "sha:" .. p.sha:sub(1, 7)
                        break
                    end
                end
            end
        end
    end

    if version_str and type(version_str) == "string" and version_str ~= "" then
        if version_str:find("^sha:") then
            -- keep sha:xxxxxxx format
        else
            version_str = version_str:gsub("^[vV]", "")
            if version_str ~= "" then
                version_str = "v" .. version_str
            else
                version_str = nil
            end
        end
    else
        version_str = nil
    end

    if self.patch then
        title_text = self.patch.filename or _("Patch")
        local repo_name = self.repo.full_name or self.repo.name or ""
        local meta_parts = {}
        if repo_name ~= "" then table.insert(meta_parts, repo_name) end
        if stars > 0 then table.insert(meta_parts, "★ " .. stars_fmt) end
        if updated ~= "" and version_str then
            table.insert(meta_parts, string.format("updated %s (%s)", updated, version_str))
        elseif updated ~= "" then
            table.insert(meta_parts, "updated " .. updated)
        elseif version_str then
            table.insert(meta_parts, version_str)
        end
        if self.patch.branch then
            table.insert(meta_parts, "branch " .. self.patch.branch)
        end
        meta_text = table.concat(meta_parts, "  ·  ")
        desc_text = self.patch.display_path or ""
    else
        title_text = self.repo.name or self.repo.full_name or _("Repository")
        local meta_parts = {}
        if owner ~= "" then table.insert(meta_parts, owner) end
        table.insert(meta_parts, "★ " .. stars_fmt)
        if updated ~= "" and version_str then
            table.insert(meta_parts, string.format("updated %s (%s)", updated, version_str))
        elseif updated ~= "" then
            table.insert(meta_parts, "updated " .. updated)
        elseif version_str then
            table.insert(meta_parts, version_str)
        end
        meta_text = table.concat(meta_parts, "  ·  ")
        desc_text = self.repo.description or ""
    end

    local folder_pill_widget = nil
    if self.update_item and self.update_item.plugin and self.update_item.plugin.dirname then
        if self.update_item.plugin.dirname ~= self.repo.name then
            local folder_name = self.update_item.plugin.dirname
            local folder_text = TextWidget:new{
                text = string.format("folder: %s", folder_name),
                face = Font:getFace("cfont", 14),
                bold = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            }
            folder_pill_widget = FrameContainer:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                bordersize = 0,
                radius = sc(4),
                padding = sc(4),
                padding_h = sc(14),
                folder_text,
            }
        end
    end

    local title_label = TextWidget:new{
        text = title_text,
        face = Font:getFace("NotoSerif-Regular.ttf", 28),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local meta_label = TextWidget:new{
        text = meta_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local desc_label = TextBoxWidget:new{
        text = desc_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = self.screen_w - sc(24),
    }

    -- -----------------------------------------------------------------------
    -- 3. Action button(s)
    -- -----------------------------------------------------------------------
    local action_btn_width = self.screen_w - sc(24)
    local is_installed = false
    local has_update   = false

    if (self.update_item and (self.update_item.is_installed_item or self.update_item.plugin))
       or (self.repo and (self.repo.is_installed_item or self.repo.is_installed or self.repo.is_default))
       or self.kind == "installed" then
        is_installed = true
    end

    if self.patch then
        local patch_map = InstallStore.listPatches() or {}
        if patch_map[self.patch.filename] ~= nil then is_installed = true end
    else
        local installed_lookup = self.Storefront and self.Storefront.getInstalledLookup and self.Storefront:getInstalledLookup()
        if installed_lookup then
            if self.repo.full_name and (installed_lookup[self.repo.full_name] or installed_lookup[self.repo.full_name:lower()]) then
                is_installed = true
            elseif self.repo.id and installed_lookup["id:" .. tostring(self.repo.id)] then
                is_installed = true
            elseif installed_lookup.unmatched and self.repo.name then
                local low_name = self.repo.name:lower()
                local base_name = low_name:gsub("%.koplugin$", "")
                if installed_lookup.unmatched[low_name] or installed_lookup.unmatched[base_name] then
                    is_installed = true
                end
            end
        end
        if not is_installed then
            local install_map = InstallStore.list() or {}
            local repo_name_lower = (self.repo.name or ""):lower()
            local rec = install_map[repo_name_lower] or install_map[self.repo.name]
            if rec and not (rec.owner or rec.repo_full_name or rec.repo_id) then
                is_installed = true
            end
        end
    end

    local is_default = false
    if self.update_item and self.update_item.is_default ~= nil then
        is_default = self.update_item.is_default
    elseif self.repo and self.repo.is_default ~= nil then
        is_default = self.repo.is_default
    elseif self.Storefront and self.Storefront.isDefaultPlugin then
        local plugin_obj = (self.update_item and self.update_item.plugin) or self.repo
        is_default = self.Storefront:isDefaultPlugin(plugin_obj)
    end
    if is_default then
        is_installed = true
        if desc_text == "" or desc_text == _("No README available.") then
            desc_text = _("Pre-installed core KOReader plugin.")
        end
    end

    if self.update_item and self.update_item.needs_update ~= nil then
        has_update = (self.update_item.needs_update == true)
    elseif self.kind == "update" then
        has_update = true
    end

    local main_action_btn
    local remove_btn_w = math.floor(action_btn_width * 0.23)
    local primary_btn_w = action_btn_width - remove_btn_w - sc(12)

    local function getInstallRecord()
        if self.patch then
            local patch_map = InstallStore.listPatches() or {}
            return patch_map[self.patch.filename]
        elseif self.update_item and self.update_item.record then
            return self.update_item.record
        else
            local records = InstallStore.list() or {}
            local repo_name_lower = (self.repo.name or ""):lower()
            if records[repo_name_lower] then
                return records[repo_name_lower]
            end
            local owner = self.repo.owner or (self.repo.data and self.repo.data.owner and (type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login))
            for dirname, rec in pairs(records) do
                if rec and rec.repo and rec.repo:lower() == repo_name_lower and (not owner or (rec.owner and rec.owner:lower() == owner:lower())) then
                    rec.dirname = dirname
                    return rec
                end
            end
            return nil
        end
    end

    local function doRemove()
        self:onClose()
        if self.patch then
            local record = (self.update_item and self.update_item.record) or getInstallRecord()
            local filename = self.patch.filename
            self.Storefront:deletePatch(filename, record)
        else
            local record = (self.update_item and self.update_item.record) or getInstallRecord()
            local dirname
            if self.update_item and self.update_item.plugin and self.update_item.plugin.dirname then
                dirname = self.update_item.plugin.dirname
            else
                dirname = (record and record.dirname) or self.repo.name
            end
            self.Storefront:deletePlugin(dirname, record)
        end
    end

    if has_update then
        local primary_btn = Button:new{
            text = _("Update"),
            text_font_size = 18,
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = sc(11),
            radius = sc(4),
            width = primary_btn_w,
            show_parent = self,
            callback = function()
                self:onClose()
                if self.patch then
                    self.Storefront:installPatchFromRepo(self.repo, self.patch)
                else
                    local rel = (self.update_item and (self.update_item.remote or self.update_item.remote_entry)) or self.repo.latest_release
                    local item_key = (self.repo and self.repo.name) or ""
                    local preferred_asset = InstallStore.getPreferredAsset(item_key)
                    local asset = nil
                    if rel and type(rel) == "table" then
                        if rel.assets and type(rel.assets) == "table" and #rel.assets > 0 then
                            if preferred_asset then
                                for _, a in ipairs(rel.assets) do
                                    if a.name and (a.name == preferred_asset or a.name:find(preferred_asset, 1, true)) then
                                        asset = a
                                        break
                                    end
                                end
                            end
                            if not asset and #rel.assets > 1 and self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                                self.Storefront:promptPluginInstallOptions(self.repo, rel)
                                return
                            end
                            if not asset then
                                for _, a in ipairs(rel.assets) do
                                    if a.name and a.name:match("%.zip$") and a.browser_download_url then
                                        asset = a
                                        break
                                    end
                                end
                                if not asset then asset = rel.assets[1] end
                            end
                        elseif rel.zipball_url then
                            asset = { name = (rel.tag_name or "release") .. ".zip", browser_download_url = rel.zipball_url }
                        elseif rel.tag_name then
                            local owner_name = self.repo.owner or "ultimatejimmy"
                            local tag_url = string.format("https://github.com/%s/%s/archive/refs/tags/%s.zip", owner_name, self.repo.name, rel.tag_name)
                            asset = { name = rel.tag_name .. ".zip", browser_download_url = tag_url }
                        end
                    end

                    if asset and type(self.Storefront.installPluginFromReleaseAsset) == "function" then
                        self.Storefront:installPluginFromReleaseAsset(self.repo, rel, asset)
                    else
                        self.Storefront:installPluginFromRepo(self.repo)
                    end
                end
            end,
        }
        if primary_btn.label_widget then
            primary_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end
        main_action_btn = HorizontalGroup:new{
            primary_btn,
            HorizontalSpan:new{ width = sc(12) },
            Button:new{
                text = _("Remove"),
                text_font_size = 18,
                bordersize = sc(1),
                padding = sc(11),
                radius = sc(4),
                width = remove_btn_w,
                show_parent = self,
                callback = doRemove,
            }
        }
    elseif is_installed then
        local is_item_disabled = false
        if self.patch and self.patch.filename then
            is_item_disabled = (self.patch.filename:match("%.disabled$") ~= nil)
        elseif self.repo and self.repo.name then
            local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
            local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or self.repo.name
            local p_name = dirname:gsub("%.koplugin$", "")
            is_item_disabled = plugins_disabled[p_name] == true
        end

        if is_default then
            local toggle_btn = Button:new{
                text = is_item_disabled and _("Enable") or _("Disable"),
                text_font_size = 18,
                text_font_color = is_item_disabled and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                background = is_item_disabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                bordersize = is_item_disabled and 0 or sc(1),
                padding = sc(11),
                radius = sc(4),
                width = action_btn_width,
                show_parent = self,
                callback = function()
                    self:onClose()
                    local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or (self.repo and self.repo.name)
                    if dirname and self.Storefront then
                        self.Storefront:togglePluginDisabled(dirname)
                        self.Storefront:reopenBrowser()
                    end
                end,
            }
            if toggle_btn.label_widget and is_item_disabled then
                toggle_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            end
            main_action_btn = toggle_btn
        else
            local toggle_btn_w = math.floor(action_btn_width * 0.28)
            local remove_btn_w = math.floor(action_btn_width * 0.23)
            local primary_btn_w = action_btn_width - toggle_btn_w - remove_btn_w - sc(16)

            local primary_btn = Button:new{
                text = _("Reinstall"),
                text_font_size = 18,
                text_font_color = Blitbuffer.COLOR_WHITE,
                background = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding = sc(11),
                radius = sc(4),
                width = primary_btn_w,
                show_parent = self,
                callback = function()
                    self:onClose()
                    if self.patch then
                        self.Storefront:installPatchFromRepo(self.repo, self.patch)
                    else
                        self.Storefront:installPluginFromRepo(self.repo)
                    end
                end,
            }
            if primary_btn.label_widget then
                primary_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            end

            local toggle_btn = Button:new{
                text = is_item_disabled and _("Enable") or _("Disable"),
                text_font_size = 18,
                bordersize = sc(1),
                padding = sc(11),
                radius = sc(4),
                width = toggle_btn_w,
                show_parent = self,
                callback = function()
                    self:onClose()
                    if self.patch then
                        local filename = self.patch.filename
                        if filename and self.Storefront then
                            self.Storefront:togglePatchDisabled(filename)
                            self.Storefront:reopenBrowser()
                        end
                    else
                        local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or (self.repo and self.repo.name)
                        if dirname and self.Storefront then
                            self.Storefront:togglePluginDisabled(dirname)
                            self.Storefront:reopenBrowser()
                        end
                    end
                end,
            }

            main_action_btn = HorizontalGroup:new{
                primary_btn,
                HorizontalSpan:new{ width = sc(8) },
                toggle_btn,
                HorizontalSpan:new{ width = sc(8) },
                Button:new{
                    text = _("Remove"),
                    text_font_size = 18,
                    bordersize = sc(1),
                    padding = sc(11),
                    radius = sc(4),
                    width = remove_btn_w,
                    show_parent = self,
                    callback = doRemove,
                }
            }
        end
    else
        main_action_btn = Button:new{
            text = self.patch and _("Install Patch") or _("Install"),
            text_font_size = 18,
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = sc(11),
            radius = sc(4),
            width = action_btn_width,
            show_parent = self,
            callback = function()
                self:onClose()
                if self.patch then
                    self.Storefront:installPatchFromRepo(self.repo, self.patch)
                else
                    local rel = self.repo and (self.repo.latest_release or (self.repo.data and self.repo.data.latest_release))
                    if rel and type(rel) == "table" and rel.assets and type(rel.assets) == "table" and #rel.assets > 1 and self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                        self.Storefront:promptPluginInstallOptions(self.repo, rel)
                    else
                        self.Storefront:installPluginFromRepo(self.repo)
                    end
                end
            end,
        }
        if main_action_btn.label_widget then
            main_action_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end
    end

    -- -----------------------------------------------------------------------
    -- 4. README / Release Notes Section Tabs & HTML Display
    -- -----------------------------------------------------------------------
    self.active_tab = self.default_tab or (self.kind == "update" and "release_notes" or "readme")

    local readme_w = self.screen_w - sc(24)

    local loadContent
    local function buildTabBar()
        local is_readme = (self.active_tab == "readme")
        local is_rel    = (self.active_tab == "release_notes")
        local is_ver    = (self.active_tab == "versions")

        local function makeTab(label, is_active, callback_fn)
            local txt_w = TextWidget:new{
                text = label,
                face = Font:getFace("cfont", 18),
                bold = is_active,
                fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(120),
            }
            local btn = Button:new{
                text = label,
                text_font_size = 18,
                text_font_bold = is_active,
                text_font_color = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(120),
                bordersize = 0,
                padding = sc(4),
                radius = 0,
                show_parent = self,
                callback = callback_fn,
            }
            local btn_w = txt_w:getSize().w + sc(8)
            local underline
            if is_active then
                underline = LineWidget:new{
                    background = Blitbuffer.COLOR_BLACK,
                    dimen = Geom:new{ w = btn_w, h = sc(3) },
                }
            else
                underline = VerticalSpan:new{ width = sc(3) }
            end

            return VerticalGroup:new{
                align = "center",
                btn,
                VerticalSpan:new{ width = sc(2) },
                underline,
            }
        end

        local readme_col = makeTab(_("README"), is_readme, function()
            if self.active_tab ~= "readme" then
                self.active_tab = "readme"
                if self.tab_bar_box then
                    self.tab_bar_box[1] = self:buildTabBar()
                end
                UIManager:setDirty(self, "ui")
                loadContent("readme")
            end
        end)

        local rel_col = makeTab(_("Release Notes"), is_rel, function()
            if self.active_tab ~= "release_notes" then
                self.active_tab = "release_notes"
                if self.tab_bar_box then
                    self.tab_bar_box[1] = self:buildTabBar()
                end
                UIManager:setDirty(self, "ui")
                loadContent("release_notes")
            end
        end)

        local ver_col = makeTab(_("Versions"), is_ver, function()
            if self.active_tab ~= "versions" then
                self.active_tab = "versions"
                if self.tab_bar_box then
                    self.tab_bar_box[1] = self:buildTabBar()
                end
                UIManager:setDirty(self, "ui")
                loadContent("versions")
            end
        end)

        return HorizontalGroup:new{
            align = "center",
            readme_col,
            HorizontalSpan:new{ width = sc(16) },
            rel_col,
            HorizontalSpan:new{ width = sc(16) },
            ver_col,
        }
    end

    self.buildTabBar = buildTabBar
    local tab_bar_box = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        buildTabBar(),
    }
    self.tab_bar_box = tab_bar_box
    local tab_bar = tab_bar_box

    local tab_bar_h = sc(26)

    -- Measure header area heights to compute available content box space
    local header_h = sc(8) + sc(1)   -- divider line gap
                   + sc(12)          -- gap above title
                   + title_label:getSize().h
                   + sc(4)
                   + meta_label:getSize().h
                   + (folder_pill_widget and (sc(6) + folder_pill_widget:getSize().h) or 0)
                   + sc(12)
                   + desc_label:getSize().h
                   + sc(16)
                   + (main_action_btn.getSize and main_action_btn:getSize().h or sc(44))
                   + sc(16)
                   + sc(1)           -- second divider
                   + tab_bar_h

    -- Back-button row height
    local back_h   = back_btn:getSize().h + sc(8)

    -- Pagination bar height
    local pager_h  = sc(44) + sc(12)

    -- FrameContainer padding (top+bottom)
    local frame_padding = sc(12) * 2

    local readme_h = self.screen_h - frame_padding - back_h - header_h - pager_h
    if readme_h < sc(80) then readme_h = sc(80) end

    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")

    local font_declarations = ""
    local serif_path = ffiutil.realpath("fonts/noto/NotoSerif-Regular.ttf")
    local serif_bold_path = ffiutil.realpath("fonts/noto/NotoSerif-Bold.ttf")
    local sans_path = ffiutil.realpath("fonts/noto/NotoSans-Regular.ttf")
    local sans_bold_path = ffiutil.realpath("fonts/noto/NotoSans-Bold.ttf")

    if serif_path and lfs.attributes(serif_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Serif'; src: url('%s'); }", serif_path)
    end
    if serif_bold_path and lfs.attributes(serif_bold_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Serif'; font-weight: bold; src: url('%s'); }", serif_bold_path)
    end
    if sans_path and lfs.attributes(sans_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Sans'; src: url('%s'); }", sans_path)
    end
    if sans_bold_path and lfs.attributes(sans_bold_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Sans'; font-weight: bold; src: url('%s'); }", sans_bold_path)
    end

    local serif_family = (serif_path and lfs.attributes(serif_path)) and "'Noto Serif', serif" or "serif"
    local sans_family = (sans_path and lfs.attributes(sans_path)) and "'Noto Sans', sans-serif" or "sans-serif"

    local function getAssetPath(filename)
        local rel = "assets/" .. filename
        local rp = ffiutil.realpath(rel)
        if rp and lfs.attributes(rp) then return rp end

        local rel_plugin = "plugins/storefront.koplugin/assets/" .. filename
        rp = ffiutil.realpath(rel_plugin)
        if rp and lfs.attributes(rp) then return rp end

        local data_path = require("datastorage"):getDataDir() .. "/plugins/storefront.koplugin/assets/" .. filename
        rp = ffiutil.realpath(data_path)
        if rp and lfs.attributes(rp) then return rp end

        return rel
    end

    local readme_css = string.format([=[
%s
@page { margin: 0; }
html, body { width: 100%% !important; margin: 0 !important; padding: 0 !important; }
body, .markdown-body, div { margin: 0 !important; padding: 0 !important; font-family: %s; color: #000000 !important; }
p, ul, ol, li, blockquote { font-family: %s !important; margin-top: 0.5em !important; margin-bottom: 0.5em !important; color: #000000 !important; }
h1, h2, h3, h4, h5, h6 { font-family: %s !important; margin-top: 0.8em !important; margin-bottom: 0.4em !important; color: #000000 !important; }
a { color: #000000 !important; text-decoration: underline; }
a.plain-link { color: #000000 !important; text-decoration: none !important; }
a.btn-primary { display: block !important; width: 100%% !important; background-color: #000000 !important; color: #ffffff !important; padding: 14px 0 !important; text-decoration: none !important; font-weight: bold !important; border-radius: 8px !important; text-align: center !important; font-size: 18px !important; box-sizing: border-box !important; }
img { max-width: 100%%; height: auto; margin-left: auto; margin-right: auto; }
table { width: 100%% !important; min-width: 100%% !important; table-layout: fixed !important; border-collapse: collapse !important; margin: 0 !important; padding: 0 !important; }
td { vertical-align: top; }
]=], font_declarations, sans_family, sans_family, serif_family)

    local html_box = HtmlBoxWidget:new{
        dimen = Geom:new{ w = readme_w, h = readme_h },
        dialog = self,
        html_link_tapped_callback = function(link)
            local href = (type(link) == "table" and (link.uri or link.url)) or (type(link) == "string" and link) or ""
            return self:onLinkTap(href)
        end,
    }

    -- -----------------------------------------------------------------------
    -- 5. Pagination controls
    -- -----------------------------------------------------------------------
    local page_indicator = TextWidget:new{
        text = "1 / 1",
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local prev_btn
    local next_btn

    local function updatePagination()
        local total   = html_box.page_count  or 1
        html_box.page_number = math.max(1, math.min(html_box.page_number or 1, total))
        local current = html_box.page_number
        if page_indicator.setText then
            page_indicator:setText(string.format("%d / %d", current, total), readme_w / 3)
        end
        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end
        if prev_btn.enableDisable then
            prev_btn:enableDisable(current > 1)
        end
        if next_btn.enableDisable then
            next_btn:enableDisable(current < total)
        end
        UIManager:setDirty(self, "ui")
    end

    prev_btn = Button:new{
        text = "< Prev",
        text_font_size = 16,
        padding = sc(8),
        bordersize = sc(1),
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self,
        callback = function()
            if self.active_tab == "versions" then
                if self.versions_page and self.versions_page > 1 then
                    self.versions_page = self.versions_page - 1
                    if self.loadContent then self.loadContent("versions") end
                end
            else
                if html_box.page_number and html_box.page_number > 1 then
                    html_box.page_number = html_box.page_number - 1
                    if rawget(html_box, "_bb") then html_box._bb = nil end
                    if rawget(html_box, "bb") then html_box.bb = nil end
                    updatePagination()
                end
            end
        end,
    }

    next_btn = Button:new{
        text = "Next >",
        text_font_size = 16,
        padding = sc(8),
        bordersize = sc(1),
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self,
        callback = function()
            if self.active_tab == "versions" then
                local total_rels = self.cached_releases and #self.cached_releases or 0
                local per_page = 4
                local total_pages = math.max(1, math.ceil(total_rels / per_page))
                if self.versions_page and self.versions_page < total_pages then
                    self.versions_page = self.versions_page + 1
                    if self.loadContent then self.loadContent("versions") end
                end
            else
                local total = html_box.page_count or 1
                if html_box.page_number and html_box.page_number < total then
                    html_box.page_number = html_box.page_number + 1
                    if rawget(html_box, "_bb") then html_box._bb = nil end
                    if rawget(html_box, "bb") then html_box.bb = nil end
                    updatePagination()
                end
            end
        end,
    }

    if prev_btn.enableDisable then
        prev_btn:enableDisable(false)
    end
    if next_btn.enableDisable then
        next_btn:enableDisable(false)
    end

    local pagination_bar = HorizontalGroup:new{
        align = "center",
        prev_btn,
        HorizontalSpan:new{ width = sc(24) },
        page_indicator,
        HorizontalSpan:new{ width = sc(24) },
        next_btn,
    }

    -- -----------------------------------------------------------------------
    -- 6. Trigger async content load (README or Release Notes)
    -- -----------------------------------------------------------------------
    local owner = self.repo.owner
    if not owner or owner == "" then
        if self.repo.data and self.repo.data.owner then
            owner = type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login
        end
    end
    if not owner or owner == "" then
        if self.update_item and self.update_item.record then
            owner = self.update_item.record.owner
        end
    end

    local repo_name = self.repo.name
    if not repo_name or repo_name == "" then
        if self.update_item and self.update_item.record then
            repo_name = self.update_item.record.repo
        end
    end
    local function buildPaginationControls()
        local is_versions = (self.active_tab == "versions")
        local cur = is_versions and (self.versions_page or 1) or (html_box.page_number or 1)
        local total = is_versions and (self.versions_total_pages or 1) or (html_box.page_count or 1)
        if total < 1 then total = 1 end

        local prev_btn = Button:new{
            text = _("< Prev"),
            bordersize = 0,
            padding = sc(6),
            text_font_size = 16,
            text_font_bold = (cur > 1),
            text_font_color = (cur > 1) and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(150),
            show_parent = self,
            callback = function()
                if is_versions then
                    if self.versions_page and self.versions_page > 1 then
                        self.versions_page = self.versions_page - 1
                        if self.loadContent then self.loadContent("versions") end
                    end
                else
                    if cur > 1 then
                        html_box.page_number = cur - 1
                        if rawget(html_box, "_bb") then html_box._bb = nil end
                        if rawget(html_box, "bb") then html_box.bb = nil end
                        updatePagination()
                        UIManager:setDirty(self, "ui")
                    end
                end
            end,
        }

        local page_str = string.format("%d / %d", cur, total)
        local page_label = TextWidget:new{
            text = page_str,
            face = Font:getFace("cfont", 18),
        }

        local next_btn = Button:new{
            text = _("Next >"),
            bordersize = 0,
            padding = sc(6),
            text_font_size = 16,
            text_font_bold = (cur < total),
            text_font_color = (cur < total) and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(150),
            show_parent = self,
            callback = function()
                if is_versions then
                    if self.versions_page and self.versions_page < (self.versions_total_pages or 1) then
                        self.versions_page = self.versions_page + 1
                        if self.loadContent then self.loadContent("versions") end
                    end
                else
                    if cur < total then
                        html_box.page_number = cur + 1
                        if rawget(html_box, "_bb") then html_box._bb = nil end
                        if rawget(html_box, "bb") then html_box.bb = nil end
                        updatePagination()
                        UIManager:setDirty(self, "ui")
                    end
                end
            end,
        }

        return HorizontalGroup:new{
            align = "center",
            prev_btn,
            HorizontalSpan:new{ width = sc(16) },
            page_label,
            HorizontalSpan:new{ width = sc(16) },
            next_btn,
        }
    end

    local pagination_box = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        buildPaginationControls(),
    }
    local pagination_bar = pagination_box

    updatePagination = function()
        pagination_box[1] = buildPaginationControls()
    end

    loadContent = function(tab_name)
        self.load_req_id = (self.load_req_id or 0) + 1
        local current_req_id = self.load_req_id

        html_box.page_number = 1
        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end

        if tab_name == "release_notes" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Release Notes...") .. "</p>", readme_css, sc(18))
        elseif tab_name == "versions" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Versions...") .. "</p>", readme_css, sc(18))
        else
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading README...") .. "</p>", readme_css, sc(18))
        end
        UIManager:setDirty(self, "ui")

        if (not owner or owner == "" or not repo_name or repo_name == "") and tab_name ~= "versions" then
            local msg = (tab_name == "release_notes") and _("No Release Notes available.") or _("No README available.")
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. msg .. "</p>", readme_css, sc(18))
            updatePagination()
            return
        end

        local function getReleasesFromCache(repo)
            if not repo then return {} end
            if repo.releases and type(repo.releases) == "table" and #repo.releases > 0 then
                return repo.releases
            end
            if repo.data and type(repo.data) == "table" and repo.data.releases and type(repo.data.releases) == "table" and #repo.data.releases > 0 then
                return repo.data.releases
            end

            local rels = {}
            local lat = repo.latest_release or (repo.data and repo.data.latest_release)
            if lat and type(lat) == "table" and (lat.tag_name or lat.name or lat.version) then
                table.insert(rels, lat)
            elseif repo.tag_name or repo.latest_version or repo.version then
                local tag = repo.tag_name or repo.latest_version or repo.version
                table.insert(rels, {
                    tag_name = tag,
                    name = tag,
                    body = repo.description or "",
                    published_at = repo.pushed_at or repo.updated_at or "",
                    prerelease = false,
                })
            end
            return rels
        end

        local function executeLoad()
            if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then
                return
            end

            local RepoContent = require("storefront_repo_content")
            local GitHubClient = require("storefront_net_github")

            if tab_name == "versions" then
                local item_key = self.patch and self.patch.filename or (self.repo and (self.repo.name or self.repo.full_name or repo_name))
                local allow_pre = InstallStore.isPreReleaseAllowed(item_key)

                local releases = self.raw_releases_cache
                if not releases and owner ~= "" and repo_name ~= "" then
                    local ok_gh, GitHubClient = pcall(require, "storefront_net_github")
                    if ok_gh and GitHubClient and type(GitHubClient.fetchReleases) == "function" then
                        local live_rels = GitHubClient.fetchReleases(owner, repo_name, { per_page = 30, max_pages = 2 })
                        if live_rels and #live_rels > 0 then
                            releases = live_rels
                        end
                    end
                end

                if not releases or #releases == 0 then
                    releases = getReleasesFromCache(self.repo)
                end
                self.raw_releases_cache = releases

                -- Filter out pre-releases if allow_pre is false
                local raw_list = releases or {}
                if #raw_list > 0 then
                    local filtered = {}
                    for _, rel in ipairs(raw_list) do
                        local tag = rel.tag_name or rel.name or ""
                        local is_pre = (rel.prerelease == true) or (tag:lower():find("beta") or tag:lower():find("alpha") or tag:lower():find("rc"))
                        if allow_pre or not is_pre then
                            table.insert(filtered, rel)
                        end
                    end
                    releases = filtered
                end

                if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then return end

                self.cached_releases = releases or {}
                local StorefrontListItem = require("storefront_list_item")
                self.versions_page = self.versions_page or 1

                local toggle_h = sc(40)
                local avail_h = readme_h - toggle_h
                local row_h = sc(68)
                local per_page = math.max(2, math.floor(avail_h / row_h))
                local total_rels = #self.cached_releases
                local total_pages = math.max(1, math.ceil(total_rels / per_page))
                self.versions_total_pages = total_pages
                self.versions_page = math.max(1, math.min(self.versions_page, total_pages))

                local list_items = {}

                -- Native Pre-release toggle row (Button + OverlapGroup)
                local pre_svg_icon = allow_pre and getAssetPath("toggle-right.svg") or getAssetPath("toggle-left.svg")
                local pre_label_w = TextWidget:new{
                    text = _("Allow pre-release updates"),
                    face = Font:getFace("cfont", 16),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local pre_icon_w = ImageWidget:new{
                    file = pre_svg_icon,
                    width = sc(28),
                    height = sc(28),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
                local toggle_row = OverlapGroup:new{
                    dimen = Geom:new{ w = readme_w - sc(24), h = sc(28) },
                    LeftContainer:new{
                        dimen = Geom:new{ w = readme_w - sc(24), h = sc(28) },
                        pre_label_w,
                    },
                    RightContainer:new{
                        dimen = Geom:new{ w = readme_w - sc(24), h = sc(28) },
                        pre_icon_w,
                    },
                }
                local toggle_frame = FrameContainer:new{
                    padding = sc(6),
                    padding_h = sc(12),
                    bordersize = sc(1),
                    radius = sc(4),
                    background = Blitbuffer.COLOR_WHITE,
                    toggle_row,
                }
                local toggle_btn = InputContainer:new{
                    toggle_frame,
                }
                toggle_btn.ges_events = {
                    StorefrontVersionToggleTap = {
                        GestureRange:new{
                            ges = "tap",
                            range = function()
                                local d = toggle_btn.dimen or toggle_frame:getSize()
                                return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                            end,
                        },
                    },
                }
                local dialog_self = self
                function toggle_btn:onStorefrontVersionToggleTap()
                    if item_key then
                        local current = InstallStore.isPreReleaseAllowed(item_key)
                        InstallStore.setPreReleaseAllowed(item_key, not current)
                        if dialog_self.loadContent then dialog_self.loadContent("versions") end
                    end
                    return true
                end

                table.insert(list_items, toggle_btn)
                table.insert(list_items, VerticalSpan:new{ width = sc(6) })

                if not releases or #releases == 0 then
                    table.insert(list_items, TextWidget:new{
                        text = _("No releases found for this repository."),
                        face = Font:getFace("cfont", 14),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    })
                else
                    local start_idx = (self.versions_page - 1) * per_page + 1
                    local end_idx = math.min(total_rels, self.versions_page * per_page)
                    for i = start_idx, end_idx do
                        local rel = releases[i]
                        local tag = rel.tag_name or rel.name or _("Release")
                        local is_pre = (rel.prerelease == true) or (tag:lower():find("beta") or tag:lower():find("alpha") or tag:lower():find("rc"))
                        local is_latest = (i == 1 and not is_pre)
                        local is_ignored = InstallStore.isReleaseIgnored(item_key, tag)

                        local badges = {}
                        if is_latest then table.insert(badges, "LATEST") end
                        if is_pre then table.insert(badges, "PRE-RELEASE") end
                        if is_ignored then table.insert(badges, "IGNORED") end

                        local badge_text = #badges > 0 and table.concat(badges, " ") or nil
                        local published = rel.published_at or rel.created_at or ""
                        if type(published) == "string" and #published >= 10 then published = published:sub(1, 10) end
                        local date_desc = published ~= "" and ("Published: " .. published) or _("No date")

                        local item = StorefrontListItem:new{
                            entry = {
                                is_entry = true,
                                name = tag,
                                description = date_desc,
                                badge = badge_text,
                                badge_icon = is_ignored and getAssetPath("eye-off.svg") or getAssetPath("eye.svg"),
                                callback = function()
                                    local owner_name = self.repo and self.repo.owner or (self.repo and self.repo.data and self.repo.data.owner and (type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login)) or ""
                                    local repo_n = self.repo and self.repo.name or ""
                                    local ver_dialog = StorefrontVersionDetailsDialog:new{
                                        Storefront = self.Storefront,
                                        parent_details = self,
                                        repo = self.repo,
                                        patch = self.patch,
                                        release = rel,
                                        owner = owner_name,
                                        repo_name = repo_n,
                                    }
                                    ver_dialog:show()
                                end,
                                on_badge_tap = function()
                                    if item_key and tag then
                                        InstallStore.toggleReleaseIgnored(item_key, tag)
                                        if self.loadContent then self.loadContent("versions") end
                                    end
                                end,
                            },
                            width = readme_w,
                            dialog = self,
                        }

                        table.insert(list_items, item)
                        if i < end_idx then
                            table.insert(list_items, LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = readme_w, h = Size.line.thin } })
                        end
                    end
                end

                local versions_group = VerticalGroup:new(list_items)

                updatePagination()
                if self.content_area_box then
                    self.content_area_box[1] = versions_group
                end
                if self.pagination_bar_container then
                    self.pagination_bar_container[1] = pagination_bar
                end

                UIManager:setDirty(self, "ui")
                return
            end

            if self.content_area_box then
                self.content_area_box[1] = html_box
            end
            if self.pagination_bar_container then
                self.pagination_bar_container[1] = pagination_bar
            end

            local ok, path
            if tab_name == "release_notes" then
                local rel_data = (self.update_item and (self.update_item.remote or self.update_item.remote_entry)) or self.repo.latest_release
                if RepoContent and type(RepoContent.fetchReleaseNotesHtml) == "function" then
                    local ok_pcall, res_ok, res_path = pcall(RepoContent.fetchReleaseNotesHtml, owner, repo_name, rel_data)
                    if ok_pcall then
                        ok, path = res_ok, res_path
                    else
                        logger.warn("Storefront: error fetching release notes", res_ok)
                        ok, path = false, nil
                    end
                end
            else
                if RepoContent and type(RepoContent.fetchReadmeHtml) == "function" then
                    local ok_pcall, res_ok, res_path = pcall(RepoContent.fetchReadmeHtml, owner, repo_name)
                    if ok_pcall then
                        ok, path = res_ok, res_path
                    else
                        logger.warn("Storefront: error fetching readme", res_ok)
                        ok, path = false, nil
                    end
                end
            end

            if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then
                return
            end

            if ok and path then
                local html_content = util.readFromFile(path)
                if html_content and html_content ~= "" then
                    local cache_dir = require("datastorage"):getDataDir() .. (tab_name == "release_notes" and "/cache/Storefront/release_notes" or "/cache/Storefront/readme")
                    html_box.page_number = 1
                    html_box:setContent(html_content, readme_css, sc(18), false, false, cache_dir)
                    if rawget(html_box, "_bb") then html_box._bb = nil end
                    if rawget(html_box, "bb") then html_box.bb = nil end
                    updatePagination()
                else
                    local msg = (tab_name == "release_notes") and _("Unable to read Release Notes.") or _("Unable to read README.")
                    html_box.page_number = 1
                    html_box:setContent("<p style='text-align:center;color:red;'>" .. msg .. "</p>", readme_css, sc(18))
                    updatePagination()
                end
            else
                local msg = (tab_name == "release_notes") and _("No Release Notes available.") or _("No README available.")
                html_box.page_number = 1
                html_box:setContent("<p style='text-align:center;color:gray;'>" .. msg .. "</p>", readme_css, sc(18))
                updatePagination()
            end
            UIManager:setDirty(self, "ui")
        end

        logger.info("Storefront Details: loadContent called for tab =", tab_name)
        if tab_name == "versions" then
            logger.info("Storefront Details: executing executeLoad immediately for versions tab")
            executeLoad()
        else
            UIManager:scheduleIn(0.01, function()
                if NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
                    NetworkMgr:runWhenOnline(executeLoad)
                else
                    executeLoad()
                end
            end)
        end
    end

    self.loadContent = loadContent
    loadContent(self.active_tab)

    self.content_area_box = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        width = readme_w,
        height = readme_h,
        html_box,
    }

    self.pagination_bar_container = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        pagination_bar,
    }

    -- -----------------------------------------------------------------------
    -- 7. Full-screen layout
    -- -----------------------------------------------------------------------
    local content_group_items = {
        align = "left",
        back_btn,
        VerticalSpan:new{ width = sc(8) },
        title_label,
        VerticalSpan:new{ width = sc(4) },
        meta_label,
    }

    if folder_pill_widget then
        table.insert(content_group_items, VerticalSpan:new{ width = sc(6) })
        table.insert(content_group_items, folder_pill_widget)
    end

    table.insert(content_group_items, VerticalSpan:new{ width = sc(12) })
    table.insert(content_group_items, desc_label)
    table.insert(content_group_items, VerticalSpan:new{ width = sc(16) })
    table.insert(content_group_items, main_action_btn)
    table.insert(content_group_items, VerticalSpan:new{ width = sc(16) })
    table.insert(content_group_items, LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = self.screen_w - sc(24), h = Size.line.thin } })
    table.insert(content_group_items, VerticalSpan:new{ width = sc(8) })
    table.insert(content_group_items, tab_bar)
    table.insert(content_group_items, VerticalSpan:new{ width = sc(8) })
    table.insert(content_group_items, self.content_area_box)
    table.insert(content_group_items, VerticalSpan:new{ width = sc(12) })
    table.insert(content_group_items, self.pagination_bar_container)

    local content_group = VerticalGroup:new(content_group_items)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = sc(12),
        width = self.screen_w,
        height = self.screen_h,
        content_group,
    }
end

function StorefrontDetailsDialog:onLinkTap(href)
    if href and type(href) == "string" then
        if href:find("^storefront%-img:") then
            local img_path = href:gsub("^storefront%-img:", "")
            local title_str = self.repo and (self.repo.name or self.repo.full_name) or _("Image View")
            local img_modal = StorefrontImageModal:new{
                image_path = img_path,
                title = title_str,
            }
            img_modal:show()
            return true
        elseif href == "storefront-toggle-prerelease" then
            local item_key = self.patch and self.patch.filename or (self.repo and (self.repo.name or self.repo.full_name))
            if item_key then
                local current = InstallStore.isPreReleaseAllowed(item_key)
                InstallStore.setPreReleaseAllowed(item_key, not current)
                if self.loadContent then self.loadContent("versions") end
            end
            return true
        elseif href:find("^storefront%-toggle%-ignore:") then
            local tag = href:match("^storefront%-toggle%-ignore:(.+)$")
            local item_key = self.patch and self.patch.filename or (self.repo and (self.repo.name or self.repo.full_name))
            if item_key and tag and tag ~= "" then
                InstallStore.toggleReleaseIgnored(item_key, tag)
                if self.loadContent then self.loadContent("versions") end
            end
            return true
        elseif href:find("^storefront%-select%-version:") then
            local idx_str = href:match("^storefront%-select%-version:(%d+)$")
            local idx = idx_str and tonumber(idx_str)
            if idx and self.cached_releases and self.cached_releases[idx] then
                local selected_rel = self.cached_releases[idx]
                local owner_name = self.repo and self.repo.owner or (self.repo and self.repo.data and self.repo.data.owner and (type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login)) or ""
                local repo_n = self.repo and self.repo.name or ""
                local ver_dialog = StorefrontVersionDetailsDialog:new{
                    Storefront = self.Storefront,
                    parent_details = self,
                    repo = self.repo,
                    patch = self.patch,
                    release = selected_rel,
                    owner = owner_name,
                    repo_name = repo_n,
                }
                ver_dialog:show()
            end
            return true
        end
    end
    return false
end

function StorefrontDetailsDialog:onClose()
    self.is_closed = true
    UIManager:close(self, "ui")
    return true
end

function StorefrontDetailsDialog:show()
    UIManager:show(self)
end

-- ---------------------------------------------------------------------------
-- Dedicated Full-Screen Version Details Dialog
-- ---------------------------------------------------------------------------
StorefrontVersionDetailsDialog = InputContainer:extend{
    covers_fullscreen = true,
    Storefront = nil,
    parent_details = nil,
    repo = nil,
    patch = nil,
    release = nil,
    owner = "",
    repo_name = "",
}

function StorefrontVersionDetailsDialog:init()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()

    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end

    local back_btn = Button:new{
        text = "< Back",
        text_font_size = 20,
        bordersize = sc(1),
        padding = sc(8),
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self,
        callback = function()
            self:onClose()
        end,
    }

    local rel = self.release or {}
    local tag = rel.tag_name or rel.name or _("Release")
    local is_pre = rel.prerelease == true
    local published = rel.published_at or rel.created_at or ""
    if type(published) == "string" and #published >= 10 then published = published:sub(1, 10) end

    local repo_title = self.repo and (self.repo.name or self.repo.full_name) or _("Repository")
    local title_label = TextWidget:new{
        text = repo_title,
        face = Font:getFace("NotoSerif-Regular.ttf", 28),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local meta_str = string.format("Version: %s%s%s", tag, is_pre and " (PRE-RELEASE)" or "", published ~= "" and ("  ·  Published: " .. published) or "")
    local meta_label = TextWidget:new{
        text = meta_str,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local item_key = self.patch and self.patch.filename or (self.repo and (self.repo.name or self.repo.full_name))
    local is_ignored = item_key and InstallStore.isReleaseIgnored(item_key, tag)

    local row_w = self.screen_w - sc(24)
    local ignore_btn_w = math.floor(row_w * 0.32)
    local primary_btn_w = row_w - ignore_btn_w - sc(12)

    local install_btn = Button:new{
        text = string.format(_("Install %s"), tag),
        text_font_size = 18,
        text_font_color = Blitbuffer.COLOR_WHITE,
        background = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        padding = sc(11),
        radius = sc(4),
        width = primary_btn_w,
        show_parent = self,
        callback = function()
            self:onClose()
            if self.parent_details then self.parent_details:onClose() end

            local item_key = self.repo_name or ""
            local preferred_asset = InstallStore.getPreferredAsset(item_key)
            local asset = nil
            if rel.assets and type(rel.assets) == "table" and #rel.assets > 0 then
                if preferred_asset then
                    for _, a in ipairs(rel.assets) do
                        if a.name and (a.name == preferred_asset or a.name:find(preferred_asset, 1, true)) then
                            asset = a
                            break
                        end
                    end
                end
                if not asset and #rel.assets > 1 and self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                    self.Storefront:promptPluginInstallOptions(self.repo, rel)
                    return
                end
                if not asset then
                    for _, a in ipairs(rel.assets) do
                        if a.name and a.name:match("%.zip$") and a.browser_download_url then
                            asset = a
                            break
                        end
                    end
                    if not asset then asset = rel.assets[1] end
                end
            elseif rel.zipball_url then
                asset = { name = (rel.tag_name or "release") .. ".zip", browser_download_url = rel.zipball_url }
            elseif rel.tag_name then
                local owner_name = self.owner ~= "" and self.owner or "ultimatejimmy"
                local tag_url = string.format("https://github.com/%s/%s/archive/refs/tags/%s.zip", owner_name, self.repo_name, rel.tag_name)
                asset = { name = rel.tag_name .. ".zip", browser_download_url = tag_url }
            end

            if asset and self.Storefront and type(self.Storefront.installPluginFromReleaseAsset) == "function" then
                self.Storefront:installPluginFromReleaseAsset(self.repo, rel, asset)
            elseif self.Storefront then
                self.Storefront:installPluginFromRepo(self.repo)
            end
        end,
    }
    if install_btn.label_widget then
        install_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    local ignore_icon_path = getAssetPath(is_ignored and "eye-off.svg" or "eye.svg")
    local ignore_icon_w = ImageWidget:new{
        file = ignore_icon_path,
        width = sc(18),
        height = sc(18),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local ignore_txt_w = TextWidget:new{
        text = is_ignored and _("Ignored") or _("Ignore"),
        face = Font:getFace("cfont", 16),
        bold = is_ignored,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local ignore_content = HorizontalGroup:new{
        align = "center",
        ignore_icon_w,
        HorizontalSpan:new{ width = sc(6) },
        ignore_txt_w,
    }

    local ignore_frame = FrameContainer:new{
        padding = sc(11),
        bordersize = sc(1),
        radius = sc(4),
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = ignore_btn_w - sc(24), h = ignore_content:getSize().h },
            ignore_content,
        },
    }

    local ignore_btn = InputContainer:new{
        ignore_frame,
    }
    ignore_btn.ges_events = {
        StorefrontVersionIgnoreTap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local d = ignore_btn.dimen or ignore_frame:getSize()
                    return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                end,
            },
        },
    }
    local vdialog_self = self
    function ignore_btn:onStorefrontVersionIgnoreTap()
        if item_key and tag then
            InstallStore.toggleReleaseIgnored(item_key, tag)
            if vdialog_self.parent_details and vdialog_self.parent_details.loadContent then
                vdialog_self.parent_details.loadContent("versions")
            end
            vdialog_self:onClose()
            if vdialog_self.parent_details then
                local owner_name = vdialog_self.owner
                local repo_n = vdialog_self.repo_name
                local ver_dialog = StorefrontVersionDetailsDialog:new{
                    Storefront = vdialog_self.Storefront,
                    parent_details = vdialog_self.parent_details,
                    repo = vdialog_self.repo,
                    patch = vdialog_self.patch,
                    release = rel,
                    owner = owner_name,
                    repo_name = repo_n,
                }
                ver_dialog:show()
            end
        end
        return true
    end

    local action_row = HorizontalGroup:new{
        install_btn,
        HorizontalSpan:new{ width = sc(12) },
        ignore_btn,
    }

    local header_h = back_btn:getSize().h + sc(8)
                   + title_label:getSize().h + sc(4)
                   + meta_label:getSize().h + sc(16)
                   + action_row:getSize().h + sc(16)
                   + sc(1) + sc(8)
    local pager_h = sc(44) + sc(12)
    local frame_padding = sc(12) * 2
    local readme_h = self.screen_h - frame_padding - header_h - pager_h
    if readme_h < sc(140) then readme_h = sc(140) end

    local readme_w = self.screen_w - sc(24)

    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")

    local font_declarations = ""
    local serif_path = ffiutil.realpath("fonts/noto/NotoSerif-Regular.ttf")
    local serif_bold_path = ffiutil.realpath("fonts/noto/NotoSerif-Bold.ttf")
    local sans_path = ffiutil.realpath("fonts/noto/NotoSans-Regular.ttf")
    local sans_bold_path = ffiutil.realpath("fonts/noto/NotoSans-Bold.ttf")

    if serif_path and lfs.attributes(serif_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Serif'; src: url('%s'); }", serif_path)
    end
    if serif_bold_path and lfs.attributes(serif_bold_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Serif'; font-weight: bold; src: url('%s'); }", serif_bold_path)
    end
    if sans_path and lfs.attributes(sans_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Sans'; src: url('%s'); }", sans_path)
    end
    if sans_bold_path and lfs.attributes(sans_bold_path) then
        font_declarations = font_declarations .. string.format("\n@font-face { font-family: 'Noto Sans'; font-weight: bold; src: url('%s'); }", sans_bold_path)
    end

    local serif_family = (serif_path and lfs.attributes(serif_path)) and "'Noto Serif', serif" or "serif"
    local sans_family = (sans_path and lfs.attributes(sans_path)) and "'Noto Sans', sans-serif" or "sans-serif"

    local readme_css = string.format([=[
%s
@page { margin: 0; }
html, body { width: 100%% !important; margin: 0 !important; padding: 0 !important; }
body, .markdown-body, div { margin: 0 !important; padding: 0 !important; font-family: %s; color: #000000 !important; }
p, ul, ol, li, blockquote { font-family: %s !important; margin-top: 0.5em !important; margin-bottom: 0.5em !important; color: #000000 !important; }
h1, h2, h3, h4, h5, h6 { font-family: %s !important; margin-top: 0.8em !important; margin-bottom: 0.4em !important; color: #000000 !important; }
a { color: #000000 !important; text-decoration: underline; }
a.plain-link { color: #000000 !important; text-decoration: none !important; }
]=], font_declarations, sans_family, sans_family, serif_family)

    local html_box = HtmlBoxWidget:new{
        dimen = Geom:new{ w = readme_w, h = readme_h },
        dialog = self,
        html_link_tapped_callback = function(link)
            local href = (type(link) == "table" and (link.uri or link.url)) or (type(link) == "string" and link) or ""
            if href:find("^storefront%-toggle%-ignore:") then
                local ig_tag = href:match("^storefront%-toggle%-ignore:(.+)$")
                if item_key and ig_tag then
                    InstallStore.toggleReleaseIgnored(item_key, ig_tag)
                    UIManager:setDirty(self, "ui")
                end
                return true
            end
            return false
        end,
    }

    local page_info_btn = Button:new{
        text = "1 / 1",
        text_font_size = 16,
        bordersize = 0,
        padding = sc(4),
        show_parent = self,
    }

    local function updatePagination()
        local total = html_box.page_count or 1
        html_box.page_number = math.max(1, math.min(html_box.page_number or 1, total))
        local current = html_box.page_number
        page_info_btn:setText(string.format("%d / %d", current, total))
        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end
        UIManager:setDirty(self, "ui")
    end

    prev_btn = Button:new{
        text = _("< Prev"),
        text_font_size = 16,
        bordersize = 0,
        padding = sc(4),
        show_parent = self,
        callback = function()
            if html_box.page_number and html_box.page_number > 1 then
                html_box.page_number = html_box.page_number - 1
                updatePagination()
            end
        end,
    }
    next_btn = Button:new{
        text = _("Next >"),
        text_font_size = 16,
        bordersize = 0,
        padding = sc(4),
        show_parent = self,
        callback = function()
            local total = html_box.page_count or 1
            if html_box.page_number and html_box.page_number < total then
                html_box.page_number = html_box.page_number + 1
                updatePagination()
            end
        end,
    }

    local pagination_bar = HorizontalGroup:new{
        align = "center",
        prev_btn,
        HorizontalSpan:new{ width = sc(12) },
        page_info_btn,
        HorizontalSpan:new{ width = sc(12) },
        next_btn,
    }

    local GitHubClient = require("storefront_net_github")
    local parts = {}

    table.insert(parts, "<h3 style='color:#000;margin-top:0;'> " .. _("Release Notes") .. "</h3>")
    if type(rel.body) == "string" and rel.body ~= json_null and rel.body:match("%S") then
        local notes_html = GitHubClient.markdownToHtml(rel.body, self.owner, self.repo_name)
        table.insert(parts, notes_html)
    else
        table.insert(parts, "<p style='color:#555;'>" .. _("No release notes provided for this version.") .. "</p>")
    end

    local html_content = table.concat(parts, "\n")
    html_box.page_number = 1
    html_box:setContent(html_content, readme_css, sc(18))
    page_info_btn:setText(string.format("%d / %d", html_box.page_number, math.max(1, html_box.page_count)))

    local content_group_items = {
        align = "left",
        back_btn,
        VerticalSpan:new{ width = sc(8) },
        title_label,
        VerticalSpan:new{ width = sc(4) },
        meta_label,
        VerticalSpan:new{ width = sc(16) },
        action_row,
        VerticalSpan:new{ width = sc(16) },
        LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = self.screen_w - sc(24), h = Size.line.thin } },
        VerticalSpan:new{ width = sc(8) },
        html_box,
        VerticalSpan:new{ width = sc(12) },
        pagination_bar,
    }

    local content_group = VerticalGroup:new(content_group_items)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = sc(12),
        width = self.screen_w,
        height = self.screen_h,
        content_group,
    }
end

function StorefrontVersionDetailsDialog:onClose()
    UIManager:close(self, "ui")
    return true
end

function StorefrontVersionDetailsDialog:show()
    UIManager:show(self)
end

return StorefrontDetailsDialog

