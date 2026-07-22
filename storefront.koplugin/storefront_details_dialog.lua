local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
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
local StorefrontImageModal = require("storefront_image_modal")
local InstallStore = require("storefront_installs")
local GestureRange = require("ui/gesturerange")
local util = require("util")

local Input = Device.input

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

    local owner = self.repo.owner or (self.repo.data and self.repo.data.owner and (type(self.repo.data.owner) == "string" and self.repo.data.owner or self.repo.data.owner.login)) or ""
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

    if self.patch then
        local patch_map = InstallStore.listPatches() or {}
        is_installed = patch_map[self.patch.filename] ~= nil
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
                    self.Storefront:installPluginFromRepo(self.repo)
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
                    self.Storefront:installPluginFromRepo(self.repo)
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
    local tab_bar_wrapper = HorizontalGroup:new{ align = "center" }

    local function buildTabBar()
        local is_readme = (self.active_tab == "readme")
        local is_rel    = (self.active_tab == "release_notes")

        local readme_label = TextWidget:new{
            text = _("README"),
            face = is_readme and Font:getFace("smallinfofontbold", 18) or Font:getFace("smallinfofont", 17),
            fgcolor = is_readme and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(100),
        }

        local rel_label = TextWidget:new{
            text = _("Release Notes"),
            face = is_rel and Font:getFace("smallinfofontbold", 18) or Font:getFace("smallinfofont", 17),
            fgcolor = is_rel and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(100),
        }

        local readme_underline = is_readme and LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = readme_label:getSize().w, h = sc(3) },
        } or VerticalSpan:new{ width = sc(3) }

        local rel_underline = is_rel and LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = rel_label:getSize().w, h = sc(3) },
        } or VerticalSpan:new{ width = sc(3) }

        local readme_group = VerticalGroup:new{
            align = "center",
            readme_label,
            VerticalSpan:new{ width = sc(3) },
            readme_underline,
        }

        local rel_group = VerticalGroup:new{
            align = "center",
            rel_label,
            VerticalSpan:new{ width = sc(3) },
            rel_underline,
        }

        local readme_btn = InputContainer:new{ readme_group }
        local rel_btn    = InputContainer:new{ rel_group }

        readme_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = readme_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        return Geom:new{ x = dim.x or 0, y = dim.y or 0, w = dim.w or 0, h = dim.h or 0 }
                    end,
                }
            }
        }
        readme_btn.onTap = function()
            if self.active_tab ~= "readme" then
                self.active_tab = "readme"
                tab_bar_wrapper[1] = buildTabBar()
                UIManager:setDirty(self, "ui")
                loadContent("readme")
            end
            return true
        end

        rel_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local dim = rel_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        return Geom:new{ x = dim.x or 0, y = dim.y or 0, w = dim.w or 0, h = dim.h or 0 }
                    end,
                }
            }
        }
        rel_btn.onTap = function()
            if self.active_tab ~= "release_notes" then
                self.active_tab = "release_notes"
                tab_bar_wrapper[1] = buildTabBar()
                UIManager:setDirty(self, "ui")
                loadContent("release_notes")
            end
            return true
        end

        return HorizontalGroup:new{
            align = "center",
            readme_btn,
            HorizontalSpan:new{ width = sc(36) },
            rel_btn,
        }
    end

    tab_bar_wrapper[1] = buildTabBar()

    local tab_bar = tab_bar_wrapper
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

    local readme_css = string.format([=[
%s
@page { margin: 0; }
body, .markdown-body, div { margin: 0 !important; padding: 0 !important; font-family: %s; }
p, ul, ol, li, blockquote { font-family: %s !important; margin-top: 0.5em !important; margin-bottom: 0.5em !important; }
h1, h2, h3, h4, h5, h6 { font-family: %s !important; margin-top: 0.8em !important; margin-bottom: 0.4em !important; }
img { max-width: 100%%; height: auto; display: block; margin-left: auto; margin-right: auto; }
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
        local current = html_box.page_number or 1
        local total   = html_box.page_count  or 1
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
            if html_box.page_number and html_box.page_number > 1 then
                html_box.page_number = html_box.page_number - 1
                if rawget(html_box, "_bb") then html_box._bb = nil end
                if rawget(html_box, "bb") then html_box.bb = nil end
                updatePagination()
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
            local total = html_box.page_count or 1
            if html_box.page_number and html_box.page_number < total then
                html_box.page_number = html_box.page_number + 1
                if rawget(html_box, "_bb") then html_box._bb = nil end
                if rawget(html_box, "bb") then html_box.bb = nil end
                updatePagination()
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

    loadContent = function(tab_name)
        self.load_req_id = (self.load_req_id or 0) + 1
        local current_req_id = self.load_req_id

        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end

        if tab_name == "release_notes" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Release Notes...") .. "</p>", readme_css, sc(18))
        else
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading README...") .. "</p>", readme_css, sc(18))
        end
        UIManager:setDirty(self, "ui")

        if not owner or owner == "" or not repo_name or repo_name == "" then
            local msg = (tab_name == "release_notes") and _("No Release Notes available.") or _("No README available.")
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. msg .. "</p>", readme_css, sc(18))
            updatePagination()
            return
        end

        local function executeLoad()
            if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then
                return
            end

            local ffiutil = require("ffi/util")
            local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
                local ok, path
                if tab_name == "release_notes" then
                    ok, path = RepoContent.fetchReleaseNotesHtml(owner, repo_name)
                else
                    ok, path = RepoContent.fetchReadmeHtml(owner, repo_name)
                end
                local result = ""
                if ok and path then
                    result = path
                end
                ffiutil.writeToFD(child_write_fd, result, true)
            end, true)

            if pid then
                local check_func
                check_func = function()
                    if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then
                        ffiutil.terminateSubProcess(pid)
                        if parent_read_fd then
                            ffiutil.readAllFromFD(parent_read_fd)
                        end
                        return
                    end
                    if ffiutil.isSubProcessDone(pid) then
                        local path = ffiutil.readAllFromFD(parent_read_fd)
                        if path and path ~= "" then
                            local html_content = util.readFromFile(path)
                            if html_content and html_content ~= "" then
                                local cache_dir = require("datastorage"):getDataDir() .. (tab_name == "release_notes" and "/cache/Storefront/release_notes" or "/cache/Storefront/readme")
                                html_box:setContent(html_content, readme_css, sc(18), false, false, cache_dir)
                                if rawget(html_box, "_bb") then html_box._bb = nil end
                                if rawget(html_box, "bb") then html_box.bb = nil end
                                updatePagination()
                            else
                                local msg = (tab_name == "release_notes") and _("Unable to read Release Notes.") or _("Unable to read README.")
                                html_box:setContent("<p style='text-align:center;color:red;'>" .. msg .. "</p>", readme_css, sc(18))
                                updatePagination()
                            end
                        else
                            local msg = (tab_name == "release_notes") and _("No Release Notes available.") or _("No README available.")
                            html_box:setContent("<p style='text-align:center;color:gray;'>" .. msg .. "</p>", readme_css, sc(18))
                            updatePagination()
                        end
                        UIManager:setDirty(self, "ui")
                    else
                        UIManager:scheduleIn(0.2, check_func)
                    end
                end
                UIManager:scheduleIn(0.2, check_func)
            else
                html_box:setContent("<p style='text-align:center;color:red;'>" .. _("Failed to start background process.") .. "</p>", readme_css, sc(18))
                updatePagination()
            end
        end

        if NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
            NetworkMgr:runWhenOnline(executeLoad)
        else
            executeLoad()
        end
    end

    -- Initial load for default active tab
    loadContent(self.active_tab)

    -- -----------------------------------------------------------------------
    -- 7. Full-screen layout
    -- -----------------------------------------------------------------------
    local content_group_items = {
        align = "left",
        back_btn,
        VerticalSpan:new{ width = sc(8) },
        LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = self.screen_w - sc(24), h = Size.line.thin } },
        VerticalSpan:new{ width = sc(12) },
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
    table.insert(content_group_items, html_box)
    table.insert(content_group_items, VerticalSpan:new{ width = sc(12) })
    table.insert(content_group_items, pagination_bar)

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
    if href and type(href) == "string" and href:find("^storefront%-img:") then
        local img_path = href:gsub("^storefront%-img:", "")
        local title_str = self.repo and (self.repo.name or self.repo.full_name) or _("Image View")
        local img_modal = StorefrontImageModal:new{
            image_path = img_path,
            title = title_str,
        }
        img_modal:show()
        return true
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

return StorefrontDetailsDialog
