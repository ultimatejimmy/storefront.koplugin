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
    local title_text = ""
    local meta_text  = ""
    local desc_text  = ""

    if self.patch then
        title_text = self.patch.filename or _("Patch")
        local repo_name = self.repo.full_name or self.repo.name or ""
        meta_text  = string.format("%s  ·  branch %s", repo_name, self.patch.branch or "HEAD")
        desc_text  = self.patch.display_path or ""
    else
        title_text = self.repo.name or self.repo.full_name or _("Repository")
        local owner  = self.repo.owner or (self.repo.data and self.repo.data.owner and self.repo.data.owner.login) or ""
        local stars  = tonumber(self.repo.stars) or (self.repo.data and tonumber(self.repo.data.stargazers_count)) or 0
        local stars_fmt = stars >= 1000 and string.format("%.1fk", stars / 1000):gsub("%.0k", "k") or tostring(stars)
        local ts     = self.repo.data and (self.repo.data.pushed_at or self.repo.data.updated_at or self.repo.data.created_at)
        local updated = (ts and type(ts) == "string") and ts:sub(1, 10) or ""

        local meta_parts = {}
        if owner   ~= "" then table.insert(meta_parts, owner) end
        table.insert(meta_parts, "★ " .. stars_fmt)
        if updated ~= "" then table.insert(meta_parts, "updated " .. updated) end
        meta_text = table.concat(meta_parts, "  ·  ")
        desc_text = self.repo.description or ""
    end

    local title_label = TextWidget:new{
        text = title_text,
        face = Font:getFace("NotoSerif-Regular.ttf", 28),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local meta_label = TextWidget:new{
        text = meta_text,
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
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
        local patch_map = self.Storefront.getPatchRecordsMap()
        is_installed = patch_map[self.patch.filename] ~= nil
    else
        local install_map = self.Storefront.getInstallRecordsMap()
        local repo_name_lower = (self.repo.name or ""):lower()
        is_installed = install_map[repo_name_lower] ~= nil
    end

    if self.kind == "update" or (self.update_item and self.update_item.needs_update) then
        has_update = true
    end

    local main_action_btn
    local remove_btn_w = math.floor(action_btn_width * 0.23)
    local primary_btn_w = action_btn_width - remove_btn_w - sc(12)

    local function getInstallRecord()
        if self.patch then
            return self.Storefront.getPatchRecordsMap()[self.patch.filename]
        else
            local repo_name_lower = (self.repo.name or ""):lower()
            return self.Storefront.getInstallRecordsMap()[repo_name_lower]
        end
    end

    local function doRemove()
        self:onClose()
        local record = getInstallRecord()
        if self.patch then
            self.Storefront:deletePatch(self.patch.filename, record)
        else
            local dirname = record and record.dirname or self.repo.name
            self.Storefront:deletePlugin(dirname, record)
        end
    end

    if has_update then
        main_action_btn = HorizontalGroup:new{
            Button:new{
                text = _("Update"),
                text_font_size = 18,
                background = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding = sc(11),
                radius = sc(4),
                width = primary_btn_w,
                show_parent = self,
                callback = function()
                    self:onClose()
                    if self.patch then
                        self.Storefront:promptPatchUpdateAction(self.update_item)
                    else
                        self.Storefront:promptUpdateAction(self.update_item.plugin or self.repo, self.update_item.record)
                    end
                end,
            },
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
        main_action_btn[1].label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    elseif is_installed then
        main_action_btn = HorizontalGroup:new{
            Button:new{
                text = _("Reinstall"),
                text_font_size = 18,
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
            },
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
        main_action_btn[1].label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    else
        main_action_btn = Button:new{
            text = self.patch and _("Install Patch") or _("Install"),
            text_font_size = 18,
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
        main_action_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    -- -----------------------------------------------------------------------
    -- 4. README inline display (using HtmlBoxWidget)
    -- -----------------------------------------------------------------------
    local readme_w = self.screen_w - sc(24)
    -- Measure header area heights to compute available readme space
    local header_h = sc(8) + sc(1)   -- divider line gap
                   + sc(12)          -- gap above title
                   + title_label:getSize().h
                   + sc(4)
                   + meta_label:getSize().h
                   + sc(12)
                   + desc_label:getSize().h
                   + sc(16)
                   + (main_action_btn.getSize and main_action_btn:getSize().h or sc(44))
                   + sc(16)
                   + sc(1)           -- second divider
                   + sc(12)
    -- Back-button row height
    local back_h   = back_btn:getSize().h + sc(8) -- back_btn + its top spacing

    -- Pagination bar height (approx two-button row)
    local pager_h  = sc(44) + sc(12) -- pagination bar + bottom gap

    -- FrameContainer padding (top+bottom)
    local frame_padding = sc(12) * 2

    local readme_h = self.screen_h - frame_padding - back_h - header_h - pager_h
    if readme_h < sc(80) then readme_h = sc(80) end

    local readme_css = "body { margin: 0 !important; padding: 0 !important; } img { max-width: 100%; height: auto; }"

    local html_box = HtmlBoxWidget:new{
        dimen = Geom:new{ w = readme_w, h = readme_h },
        dialog = self,
    }
    html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading README...") .. "</p>", readme_css, sc(18))

    -- -----------------------------------------------------------------------
    -- 5. Pagination controls
    -- -----------------------------------------------------------------------
    local page_indicator = TextWidget:new{
        text = "1 / 1",
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local prev_btn
    local next_btn

    local function updatePagination()
        local current = html_box.page_number or 1
        local total   = html_box.page_count  or 1
        page_indicator:setText(string.format("%d / %d", current, total), readme_w / 3)
        -- Free the cached bitmap so the widget re-renders the new page
        html_box:freeBb()
        if current <= 1 then
            prev_btn:disable()
        else
            prev_btn:enable()
        end
        if current >= total then
            next_btn:disable()
        else
            next_btn:enable()
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
                html_box:setPageNumber(html_box.page_number - 1)
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
                html_box:setPageNumber(html_box.page_number + 1)
                updatePagination()
            end
        end,
    }

    prev_btn:disable()
    next_btn:disable()

    local pagination_bar = HorizontalGroup:new{
        align = "center",
        prev_btn,
        HorizontalSpan:new{ width = sc(24) },
        page_indicator,
        HorizontalSpan:new{ width = sc(24) },
        next_btn,
    }

    -- -----------------------------------------------------------------------
    -- 6. Trigger async README load
    -- -----------------------------------------------------------------------
    local owner     = self.repo.owner or (self.repo.data and self.repo.data.owner and self.repo.data.owner.login)
    local repo_name = self.repo.name
    if owner and repo_name then
        NetworkMgr:runWhenOnline(function()
            local ok, path = RepoContent.fetchReadmeHtml(owner, repo_name)
            if ok and path then
                local html_content = util.readFromFile(path)
                if html_content and html_content ~= "" then
                    html_box:setContent(html_content, readme_css, sc(18))
                    updatePagination()
                else
                    html_box:setContent("<p style='text-align:center;color:red;'>" .. _("Unable to read README.") .. "</p>", readme_css, sc(18))
                end
            else
                html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("No README available.") .. "</p>", readme_css, sc(18))
            end
            UIManager:setDirty(self, "ui")
        end)
    else
        html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("No README available.") .. "</p>", readme_css, sc(18))
    end

    -- -----------------------------------------------------------------------
    -- 7. Full-screen layout
    -- -----------------------------------------------------------------------
    local content_group = VerticalGroup:new{
        align = "left",
        back_btn,
        VerticalSpan:new{ width = sc(8) },
        LineWidget:new{ background = Blitbuffer.COLOR_LIGHT_GRAY, dimen = Geom:new{ w = self.screen_w - sc(24), h = Size.line.thin } },
        VerticalSpan:new{ width = sc(12) },
        title_label,
        VerticalSpan:new{ width = sc(4) },
        meta_label,
        VerticalSpan:new{ width = sc(12) },
        desc_label,
        VerticalSpan:new{ width = sc(16) },
        main_action_btn,
        VerticalSpan:new{ width = sc(16) },
        LineWidget:new{ background = Blitbuffer.COLOR_LIGHT_GRAY, dimen = Geom:new{ w = self.screen_w - sc(24), h = Size.line.thin } },
        VerticalSpan:new{ width = sc(12) },
        html_box,
        VerticalSpan:new{ width = sc(12) },
        pagination_bar,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = sc(12),
        width = self.screen_w,
        height = self.screen_h,
        content_group,
    }
end

function StorefrontDetailsDialog:onClose()
    UIManager:close(self, "ui")
    return true
end

function StorefrontDetailsDialog:show()
    UIManager:show(self)
end

return StorefrontDetailsDialog
