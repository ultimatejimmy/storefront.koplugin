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
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
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
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local GestureRange = require("ui/gesturerange")
local util = require("util")
local ok_json, json = pcall(require, "json")
local json_null = (ok_json and json and json.null) or nil

local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local function getReaderFontSize()
    local font_size = nil
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        font_size = G_reader_settings:readSetting("font_size")
    end
    if not font_size then
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and type(UIManager.getActiveWidget) == "function" then
            local active = UIManager:getActiveWidget()
            if active and active.document and active.document.font_size then
                font_size = active.document.font_size
            end
        end
    end
    return tonumber(font_size) or 22
end

local function utf8Len(str)
    if not str or type(str) ~= "string" then return 0 end
    local len = 0
    local i = 1
    local byte_len = #str
    while i <= byte_len do
        local b = str:byte(i)
        if b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        len = len + 1
    end
    return len
end

-- Compute the largest font size where all button/tab labels in a group fit
-- within total_avail_width (including per-button padding and inter-button gaps).
-- face_name: the font face to measure with (default "cfont" for action buttons).
-- padding_per_item: horizontal padding added to each label's natural width.
local function calcGroupFontSize(texts, total_avail_width, gap, face_name, padding_per_item)
    face_name = face_name or "cfont"
    padding_per_item = padding_per_item or Device.screen:scaleBySize(22)
    local num = #texts
    if num == 0 then return 18 end
    local gaps_total = gap * math.max(0, num - 1)
    for _, sz in ipairs({ 18, 17, 16, 15, 14, 13, 12, 11, 10 }) do
        local face = Font:getFace(face_name, sz)
        local total_w = gaps_total
        for _, text in ipairs(texts) do
            local tw = TextWidget:new{ text = text, face = face, bold = true }
            total_w = total_w + tw:getSize().w + padding_per_item
        end
        if total_w <= total_avail_width then
            return sz
        end
    end
    return 10
end

-- Distribute total_avail_width proportionally across buttons, using a uniform
-- font_size (pre-computed via calcGroupFontSize) for measuring natural widths.
local function calcProportionalBtnWidths(button_texts, total_avail_width, gap, font_size)
    local num_btns = #button_texts
    if num_btns == 0 then return {} end
    if num_btns == 1 then return { total_avail_width } end

    font_size = font_size or 18
    local usable_width = total_avail_width - gap * (num_btns - 1)

    local ideal_widths = {}
    local total_ideal = 0
    local padding_per_btn = Device.screen:scaleBySize(22)
    local face = Font:getFace("cfont", font_size)

    for i, text in ipairs(button_texts) do
        local tw = TextWidget:new{ text = text, face = face, bold = true }
        local ideal = tw:getSize().w + padding_per_btn
        ideal_widths[i] = ideal
        total_ideal = total_ideal + ideal
    end

    local widths = {}
    local sum = 0
    for i = 1, num_btns do
        if i == num_btns then
            widths[i] = usable_width - sum
        else
            local w = math.floor(usable_width * (ideal_widths[i] / total_ideal))
            widths[i] = w
            sum = sum + w
        end
    end

    return widths
end



local Input = Device.input

local StorefrontVersionDetailsDialog

local StorefrontDetailsDialog = FocusManager:extend{
    covers_fullscreen = true,
    Storefront = nil,
    repo = nil,
    patch = nil,
    kind = "plugin", -- "plugin", "patch", "update"
    update_item = nil, -- passed if updates tab
    from_updates_tab = false,
    _ignore_toggled = false,
}

function StorefrontDetailsDialog:init()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()

    -- Full-screen dimen
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    if self.repo then
        if self.repo.has_wiki ~= nil then
            self.has_wiki = self.repo.has_wiki
        elseif self.repo.data and type(self.repo.data) == "table" and self.repo.data.has_wiki ~= nil then
            self.has_wiki = self.repo.data.has_wiki
        end
    end

    self.key_events = self.key_events or {}
    self.key_events.Close = { { "Back" }, { "Escape" } }
    self.key_events.NextPage = {
        { "PageDown" },
    }
    self.key_events.PrevPage = {
        { "PageUp" },
    }
    if Input and Input.group then
        if Input.group.PgFwd then
            table.insert(self.key_events.NextPage, { Input.group.PgFwd })
        end
        if Input.group.PgBack then
            table.insert(self.key_events.PrevPage, { Input.group.PgBack })
        end
        if Input.group.Back then
            table.insert(self.key_events.Close, { Input.group.Back })
        end
    end

    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        }
    }

    -- -----------------------------------------------------------------------
    -- 1. Back button (software)
    -- -----------------------------------------------------------------------
    local back_btn = Button:new{
        text = _("< Back"),
        text_font_size = 20,
        bordersize = 0,
        background = nil,
        show_parent = self,
        callback = function()
            self:onClose()
        end,
    }
    self.back_btn = back_btn

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

    local item_key
    if self.patch then
        item_key = self.patch.filename
    elseif self.update_item and self.update_item.plugin and self.update_item.plugin.dirname then
        item_key = self.update_item.plugin.dirname
    elseif owner ~= "" and repo_name ~= "" then
        item_key = string.format("%s/%s", owner, repo_name)
    elseif self.repo and self.repo.name then
        item_key = self.repo.name
    end

    if self.has_wiki == nil then
        if self.repo then
            if self.repo.has_wiki ~= nil then
                self.has_wiki = (self.repo.has_wiki == true)
            elseif self.repo.data and self.repo.data.has_wiki ~= nil then
                self.has_wiki = (self.repo.data.has_wiki == true)
            end
        end
        if self.has_wiki == nil and self.update_item and self.update_item.record and self.update_item.record.has_wiki ~= nil then
            self.has_wiki = (self.update_item.record.has_wiki == true)
        end
    end
    if self.has_wiki == nil and owner ~= "" and repo_name ~= "" then
        UIManager:scheduleIn(0.2, function()
            if self.has_wiki == nil and RepoContent and type(RepoContent.checkWikiExists) == "function" then
                local ok_check, has_w = pcall(RepoContent.checkWikiExists, owner, repo_name)
                if ok_check and has_w then
                    self.has_wiki = true
                    if self.tab_bar_box then
                        self.tab_bar_box[1] = self:buildTabBar()
                        UIManager:setDirty(self, "ui")
                    end
                end
            end
        end)
    end
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
    if not version_str and self.repo then
        version_str = self.repo.latest_version or self.repo.version or self.repo.tag_name or self.repo.release_tag
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
    end

    local rec = getInstallRecord()
    if not version_str and rec then
        version_str = rec.version or rec.installed_version or rec.installed_tag or rec.tag_name or rec.release_tag_name or (rec.sha and ("sha:" .. rec.sha:sub(1, 7)))
    end

    if not version_str and self.Storefront then
        if not self.patch and self.Storefront.listInstalledPlugins then
            local installed_plugins = self.Storefront:listInstalledPlugins()
            local repo_name = self.repo and self.repo.name or ""
            for _, p in ipairs(installed_plugins or {}) do
                local clean_p = p.dirname:gsub("%.koplugin$", ""):lower()
                local clean_repo = repo_name:gsub("%.koplugin$", ""):lower()
                if (clean_repo ~= "" and clean_p == clean_repo) or (repo_name ~= "" and p.dirname:lower() == repo_name:lower()) then
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
        local repo_name = (self.repo and (self.repo.full_name or self.repo.name)) or ""
        local meta_parts = {}
        if repo_name ~= "" then table.insert(meta_parts, repo_name) end
        if stars > 0 then table.insert(meta_parts, "★ " .. stars_fmt) end
        if updated ~= "" and version_str then
            table.insert(meta_parts, string.format(_("updated %s (%s)"), updated, version_str))
        elseif updated ~= "" then
            table.insert(meta_parts, string.format(_("updated %s"), updated))
        elseif version_str then
            table.insert(meta_parts, version_str)
        end
        if self.patch.branch then
            table.insert(meta_parts, "branch " .. self.patch.branch)
        end
        meta_text = table.concat(meta_parts, "  ·  ")
        desc_text = self.patch.display_path or ""
    else
        title_text = (self.repo and (self.repo.name or self.repo.full_name))
            or (self.update_item and (self.update_item.name or (self.update_item.plugin and self.update_item.plugin.name)))
            or _("Repository")
        local meta_parts = {}
        if owner and owner ~= "" then table.insert(meta_parts, owner) end
        if stars > 0 then table.insert(meta_parts, "★ " .. stars_fmt) end
        if updated ~= "" and version_str then
            table.insert(meta_parts, string.format(_("updated %s (%s)"), updated, version_str))
        elseif updated ~= "" then
            table.insert(meta_parts, string.format(_("updated %s"), updated))
        elseif version_str then
            table.insert(meta_parts, version_str)
        end
        desc_text = (self.repo and self.repo.description) or (self.update_item and self.update_item.description) or ""
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

    local is_font = false
    if self.kind == "font" or self.kind == "fonts" then
        is_font = true
    elseif self.repo and (self.repo.kind == "font" or self.repo.is_font) then
        is_font = true
    elseif self.update_item and (self.update_item.kind == "font" or self.update_item.is_font) then
        is_font = true
    end

    local title_face
    if is_font then
        local ok_sli, StorefrontListItem = pcall(require, "storefront_list_item")
        local font_entry = self.repo or self.update_item or { name = title_text, is_font = true }
        if ok_sli and type(StorefrontListItem) == "table" and type(StorefrontListItem.resolveFontItemFace) == "function" then
            title_face = StorefrontListItem.resolveFontItemFace(font_entry, 28)
        end
    end
    title_face = title_face or Font:getFace("NotoSerif-Regular.ttf", 28) or Font:getFace("cfont", 28)
    local title_label = TextWidget:new{
        text = title_text,
        face = title_face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local repo_id = (self.repo and (self.repo.id or self.repo.repo_id or (self.repo.data and (self.repo.data.id or self.repo.data.repo_id))))
        or (self.update_item and (self.update_item.repo_id or self.update_item.id or (self.update_item.record and (self.update_item.record.id or self.update_item.record.repo_id)) or (self.update_item.plugin and (self.update_item.plugin.repo_id or self.update_item.plugin.id))))
        or (self.patch and (self.patch.repo_id or self.patch.id))

    local meta_group_items = {}

    if owner and owner ~= "" then
        table.insert(meta_group_items, TextWidget:new{
            text = owner,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    elseif self.patch then
        local r_name = (self.repo and (self.repo.full_name or self.repo.name)) or ""
        if r_name ~= "" then
            table.insert(meta_group_items, TextWidget:new{
                text = r_name,
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        end
    end

    if stars > 0 then
        if #meta_group_items > 0 then
            table.insert(meta_group_items, TextWidget:new{
                text = "  ·  ",
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        end
        table.insert(meta_group_items, TextWidget:new{
            text = "★ " .. stars_fmt,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    end

    local item_target = self.repo or self.patch or self.update_item or repo_id
    if item_target then
        local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")
        if ok_ratings and StorefrontRatings then
            local current_vote = StorefrontRatings.getUserVote(item_target)
            local is_up_active = (current_vote == "up")
            local is_down_active = (current_vote == "down")

            local live_rating = StorefrontRatings.getRating(item_target)
            local cur_up = live_rating.up
            local cur_down = live_rating.down

            if #meta_group_items > 0 then
                table.insert(meta_group_items, TextWidget:new{
                    text = "  ·  ",
                    face = Font:getFace("cfont", 16),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                })
            end

            local dialog_self = self
            local item_kind = self.kind or (self.patch and "patch" or "plugin")

            local up_frame = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                ImageWidget:new{
                    file = is_up_active and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg"),
                    width = sc(16),
                    height = sc(16),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                },
            }
            local down_frame = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                ImageWidget:new{
                    file = is_down_active and getAssetPath("thumbs-down-filled.svg") or getAssetPath("thumbs-down.svg"),
                    width = sc(16),
                    height = sc(16),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                },
            }
            local net_score = cur_up - cur_down
            local is_voted = is_up_active or is_down_active
            local score_frame = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                TextWidget:new{
                    text = tostring(net_score),
                    face = Font:getFace("cfont", 14),
                    bold = is_voted,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            }

            local function refresh_dialog()
                dialog_self._vote_toggled = true
                current_vote = StorefrontRatings.getUserVote(item_target)
                local new_up_active = (current_vote == "up")
                local new_down_active = (current_vote == "down")
                local new_rating = StorefrontRatings.getRating(item_target)
                local new_up = new_rating.up
                local new_down = new_rating.down
                local new_score = new_up - new_down
                local new_voted = new_up_active or new_down_active

                if up_frame[1] and up_frame[1].free then up_frame[1]:free() end
                up_frame[1] = ImageWidget:new{
                    file = new_up_active and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg"),
                    width = sc(16),
                    height = sc(16),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                if down_frame[1] and down_frame[1].free then down_frame[1]:free() end
                down_frame[1] = ImageWidget:new{
                    file = new_down_active and getAssetPath("thumbs-down-filled.svg") or getAssetPath("thumbs-down.svg"),
                    width = sc(16),
                    height = sc(16),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                if score_frame[1] and score_frame[1].free then score_frame[1]:free() end
                score_frame[1] = TextWidget:new{
                    text = tostring(new_score),
                    face = Font:getFace("cfont", 14),
                    bold = new_voted,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                if rawget(up_frame, "_bb") then up_frame._bb = nil end
                if rawget(down_frame, "_bb") then down_frame._bb = nil end
                if rawget(score_frame, "_bb") then score_frame._bb = nil end

                UIManager:setDirty(dialog_self, "ui")
            end

            local up_btn = InputContainer:new{ up_frame }
            up_btn.ges_events = {
                StorefrontUpVoteTap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local d = up_btn.dimen or up_frame:getSize()
                            return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                        end,
                    },
                },
            }
            function up_btn:onStorefrontUpVoteTap()
                current_vote = StorefrontRatings.getUserVote(item_target)
                local next_vote = (current_vote == "up") and "none" or "up"
                StorefrontRatings.submitVote(item_target, next_vote, item_kind)
                refresh_dialog()
                return true
            end

            local down_btn = InputContainer:new{ down_frame }
            down_btn.ges_events = {
                StorefrontDownVoteTap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local d = down_btn.dimen or down_frame:getSize()
                            return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                        end,
                    },
                },
            }
            function down_btn:onStorefrontDownVoteTap()
                current_vote = StorefrontRatings.getUserVote(item_target)
                local next_vote = (current_vote == "down") and "none" or "down"
                StorefrontRatings.submitVote(item_target, next_vote, item_kind)
                refresh_dialog()
                return true
            end

            table.insert(meta_group_items, up_btn)
            table.insert(meta_group_items, HorizontalSpan:new{ width = sc(3) })
            table.insert(meta_group_items, score_frame)
            table.insert(meta_group_items, HorizontalSpan:new{ width = sc(3) })
            table.insert(meta_group_items, down_btn)
        end
    end

    if updated ~= "" or version_str or (self.patch and self.patch.branch) then
        if #meta_group_items > 0 then
            table.insert(meta_group_items, TextWidget:new{
                text = "  ·  ",
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        end
        local updated_parts = {}
        if updated ~= "" and version_str then
            table.insert(updated_parts, string.format(_("updated %s (%s)"), updated, version_str))
        elseif updated ~= "" then
            table.insert(updated_parts, string.format(_("updated %s"), updated))
        elseif version_str then
            table.insert(updated_parts, version_str)
        end
        if self.patch and self.patch.branch then
            table.insert(updated_parts, "branch " .. self.patch.branch)
        end
        table.insert(meta_group_items, TextWidget:new{
            text = table.concat(updated_parts, "  ·  "),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    end

    local meta_label = HorizontalGroup:new(meta_group_items)
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

    if is_font then
        if self.Storefront and self.Storefront.isFontInstalled then
            is_installed = self.Storefront:isFontInstalled(self.repo or (self.repo and self.repo.name) or "")
        else
            local ok_fm, font_mgr = pcall(require, "storefront_font_mgr")
            if ok_fm and font_mgr and font_mgr.isFontInstalled then
                is_installed = font_mgr.isFontInstalled(self.repo or (self.repo and self.repo.name) or "")
            else
                local font_map = InstallStore.listFonts and InstallStore.listFonts() or {}
                local font_name = self.repo and (self.repo.name or self.repo.font_family)
                if font_name and (font_map[font_name:lower()] or font_map[font_name]) then
                    is_installed = true
                end
            end
        end
    elseif self.patch or (self.repo and self.repo.kind == "patch") then
        local patch_map = InstallStore.listPatches() or {}
        if self.patch and patch_map[self.patch.filename] ~= nil then is_installed = true end
    else
        if (self.update_item and (self.update_item.is_installed_item or self.update_item.plugin))
           or (self.repo and (self.repo.is_installed_item or self.repo.is_installed or self.repo.is_default))
           or self.kind == "installed" then
            is_installed = true
        end
        local installed_lookup = self.Storefront and self.Storefront.getInstalledLookup and self.Storefront:getInstalledLookup()
        if installed_lookup and self.repo then
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
        if not is_installed and self.repo then
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

    local function isItemIgnored()
        if not item_key then return false end
        if InstallStore.isAllUpdatesIgnored(item_key) then return true end
        if owner ~= "" and repo_name ~= "" then
            if InstallStore.isAllUpdatesIgnored(string.format("%s/%s", owner, repo_name)) then return true end
        end
        if repo_name ~= "" and InstallStore.isAllUpdatesIgnored(repo_name) then return true end
        return false
    end

    if self.kind == "update" or self.from_updates_tab or isItemIgnored() then
        has_update = true
    elseif self.update_item and self.update_item.needs_update ~= nil then
        has_update = (self.update_item.needs_update == true)
    end

    local function toggleItemIgnored()
        local new_state = not isItemIgnored()
        local keys_to_set = {}
        if item_key then table.insert(keys_to_set, item_key) end
        if owner ~= "" and repo_name ~= "" then table.insert(keys_to_set, string.format("%s/%s", owner, repo_name)) end
        if repo_name ~= "" then table.insert(keys_to_set, repo_name) end
        if self.patch and self.patch.filename then table.insert(keys_to_set, self.patch.filename) end
        if self.update_item and self.update_item.plugin and self.update_item.plugin.dirname then
            table.insert(keys_to_set, self.update_item.plugin.dirname)
        end
        for _, k in ipairs(keys_to_set) do
            InstallStore.setAllUpdatesIgnored(k, new_state)
        end
        if self.Storefront then
            if self.Storefront.softRefreshCurrentBrowserView then
                self.Storefront:softRefreshCurrentBrowserView()
            end
            self.Storefront._ignore_toggled_in_details = true
        end
    end

    local function doRemove()
        if not self.Storefront then return end
        self:onClose()
        if is_font then
            local font_name = (self.repo and (self.repo.name or self.repo.font_family))
                or (self.update_item and (self.update_item.name or self.update_item.font_family))
            if font_name then
                local font_map = InstallStore.listFonts and InstallStore.listFonts() or {}
                local rec = font_map[font_name:lower()] or font_map[font_name]
                if type(self.Storefront.deleteFont) == "function" then
                    self.Storefront:deleteFont(font_name, rec, self.repo or self.update_item)
                end
            end
        elseif self.patch or self.kind == "patch" or (self.repo and self.repo.kind == "patch") then
            local patch_filename = (self.patch and self.patch.filename)
                or (self.update_item and (self.update_item.filename or (self.update_item.patch and self.update_item.patch.filename)))
                or (self.repo and self.repo.filename)
            if patch_filename and type(self.Storefront.deletePatch) == "function" then
                self.Storefront:deletePatch(patch_filename)
            end
        else
            local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname)
                or (self.repo and self.repo.name)
            if dirname then
                if not dirname:find("%.koplugin$") then
                    dirname = dirname .. ".koplugin"
                end
                if type(self.Storefront.deletePlugin) == "function" then
                    self.Storefront:deletePlugin(dirname, true)
                end
            end
        end
    end

    local function refreshDetailsDialog()
        self._is_replacing = true
        if self.Storefront then
            self.Storefront._ignore_toggled_in_details = true
        end
        self:onClose()
        UIManager:nextTick(function()
            local new_dialog = StorefrontDetailsDialog:new{
                Storefront = self.Storefront,
                repo = self.repo,
                patch = self.patch,
                kind = self.kind,
                update_item = self.update_item,
                default_tab = self.active_tab,
                from_updates_tab = self.from_updates_tab,
                _ignore_toggled = self._ignore_toggled,
                _vote_toggled = self._vote_toggled,
            }
            new_dialog:show()
        end)
    end
    self.refreshDetailsDialog = refreshDetailsDialog

    if has_update then
        local is_item_disabled = false
        if self.patch and self.patch.filename then
            is_item_disabled = (self.patch.filename:match("%.disabled$") ~= nil)
        elseif (self.repo and self.repo.name) or (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) then
            local plugins_disabled = G_reader_settings:readSetting("plugins_disabled") or {}
            local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or (self.repo and self.repo.name)
            local p_name = dirname and dirname:gsub("%.koplugin$", "")
            if p_name then
                is_item_disabled = plugins_disabled[p_name] == true
            end
        end

        local is_updates_ignored = isItemIgnored()
        local primary_text = _("Update")
        local toggle_text = is_item_disabled and _("Enable") or _("Disable")
        local ignore_text = is_updates_ignored and _("Updates Ignored") or _("Ignore Updates")
        local remove_text = _("Remove")

        local btn_texts = is_default and { primary_text, toggle_text, ignore_text }
                                      or { primary_text, toggle_text, ignore_text, remove_text }
        local gap = sc(8)
        local btn_font_size = calcGroupFontSize(btn_texts, action_btn_width, gap)
        local widths = calcProportionalBtnWidths(btn_texts, action_btn_width, gap, btn_font_size)
        local action_btn_h = sc(44)

        local primary_btn = Button:new{
            text = primary_text,
            text_font_size = btn_font_size,
            text_font_color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_BLACK,
            bordersize = sc(1),
            border_color = Blitbuffer.COLOR_BLACK,
            padding = 0,
            radius = sc(4),
            width = widths[1],
            height = action_btn_h,
            show_parent = self,
            callback = function()
                self:onClose()
                if self.patch then
                    self.Storefront:installPatchFromRepo(self.repo, self.patch)
                else
                    local rel = (self.update_item and (self.update_item.remote or self.update_item.remote_entry)) or (self.repo and (self.repo.latest_release or (self.repo.data and self.repo.data.latest_release)))
                    if self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                        self.Storefront:promptPluginInstallOptions(self.repo, rel, false)
                    else
                        self.Storefront:installPluginFromRepo(self.repo)
                    end
                end
            end,
        }
        if primary_btn.label_widget then
            primary_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        end

        local toggle_btn = Button:new{
            text = toggle_text,
            text_font_size = btn_font_size,
            bordersize = sc(1),
            padding = 0,
            radius = sc(4),
            width = widths[2],
            height = action_btn_h,
            show_parent = self,
            callback = function()
                self:onClose()
                if self.patch then
                    local filename = self.patch.filename
                    if filename and self.Storefront then
                        self.Storefront:togglePatchDisabled(filename)
                    end
                else
                    local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or (self.repo and self.repo.name)
                    if dirname and self.Storefront then
                        self.Storefront:togglePluginDisabled(dirname)
                    end
                end
            end,
        }

        local ignore_btn = Button:new{
            text = ignore_text,
            text_font_size = btn_font_size,
            bordersize = sc(1),
            padding = 0,
            radius = sc(4),
            width = widths[3],
            height = action_btn_h,
            show_parent = self,
            callback = function()
                toggleItemIgnored()
                self._ignore_toggled = true
                refreshDetailsDialog()
            end,
        }

        if is_default then
            main_action_btn = HorizontalGroup:new{
                primary_btn,
                HorizontalSpan:new{ width = gap },
                toggle_btn,
                HorizontalSpan:new{ width = gap },
                ignore_btn,
            }
        else
            main_action_btn = HorizontalGroup:new{
                primary_btn,
                HorizontalSpan:new{ width = gap },
                toggle_btn,
                HorizontalSpan:new{ width = gap },
                ignore_btn,
                HorizontalSpan:new{ width = gap },
                Button:new{
                    text = remove_text,
                    text_font_size = btn_font_size,
                    bordersize = sc(1),
                    padding = 0,
                    radius = sc(4),
                    width = widths[4],
                    height = action_btn_h,
                    show_parent = self,
                    callback = doRemove,
                }
            }
        end
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
                    end
                end,
            }
            if toggle_btn.label_widget and is_item_disabled then
                toggle_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            end
            main_action_btn = toggle_btn
        elseif is_font then
            local primary_text = _("Reinstall")
            local remove_text = _("Remove")
            local btn_texts = { primary_text, remove_text }
            local gap = sc(12)
            local btn_font_size = calcGroupFontSize(btn_texts, action_btn_width, gap)
            local widths = calcProportionalBtnWidths(btn_texts, action_btn_width, gap, btn_font_size)
            local action_btn_h = sc(44)

            local primary_btn = Button:new{
                text = primary_text,
                text_font_size = btn_font_size,
                text_font_color = Blitbuffer.COLOR_WHITE,
                background = Blitbuffer.COLOR_BLACK,
                bordersize = sc(1),
                border_color = Blitbuffer.COLOR_BLACK,
                padding = 0,
                radius = sc(4),
                width = widths[1],
                height = action_btn_h,
                show_parent = self,
                callback = function()
                    self:onClose()
                    self.Storefront:installFontFromRepo(self.repo)
                end,
            }
            if primary_btn.label_widget then
                primary_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            end

            main_action_btn = HorizontalGroup:new{
                primary_btn,
                HorizontalSpan:new{ width = gap },
                Button:new{
                    text = remove_text,
                    text_font_size = btn_font_size,
                    bordersize = sc(1),
                    padding = 0,
                    radius = sc(4),
                    width = widths[2],
                    height = action_btn_h,
                    show_parent = self,
                    callback = doRemove,
                }
            }
        else
            local is_updates_ignored = isItemIgnored()
            local primary_text = _("Reinstall")
            local toggle_text = is_item_disabled and _("Enable") or _("Disable")
            local ignore_text = is_updates_ignored and _("Updates Ignored") or _("Ignore Updates")
            local remove_text = _("Remove")

            local btn_texts = is_default and { primary_text, toggle_text, ignore_text }
                                          or { primary_text, toggle_text, ignore_text, remove_text }
            local gap = sc(8)
            local btn_font_size = calcGroupFontSize(btn_texts, action_btn_width, gap)
            local widths = calcProportionalBtnWidths(btn_texts, action_btn_width, gap, btn_font_size)
            local action_btn_h = sc(44)

            local primary_btn = Button:new{
                text = primary_text,
                text_font_size = btn_font_size,
                text_font_color = Blitbuffer.COLOR_WHITE,
                background = Blitbuffer.COLOR_BLACK,
                bordersize = sc(1),
                border_color = Blitbuffer.COLOR_BLACK,
                padding = 0,
                radius = sc(4),
                width = widths[1],
                height = action_btn_h,
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
                text = toggle_text,
                text_font_size = btn_font_size,
                bordersize = sc(1),
                padding = 0,
                radius = sc(4),
                width = widths[2],
                height = action_btn_h,
                show_parent = self,
                callback = function()
                    self:onClose()
                    if self.patch then
                        local filename = self.patch.filename
                        if filename and self.Storefront then
                            self.Storefront:togglePatchDisabled(filename)
                        end
                    else
                        local dirname = (self.update_item and self.update_item.plugin and self.update_item.plugin.dirname) or (self.repo and self.repo.name)
                        if dirname and self.Storefront then
                            self.Storefront:togglePluginDisabled(dirname)
                        end
                    end
                end,
            }

            local ignore_btn = Button:new{
                text = ignore_text,
                text_font_size = btn_font_size,
                bordersize = sc(1),
                padding = 0,
                radius = sc(4),
                width = widths[3],
                height = action_btn_h,
                show_parent = self,
                callback = function()
                    toggleItemIgnored()
                    self._ignore_toggled = true
                    refreshDetailsDialog()
                end,
            }

            if is_default then
                main_action_btn = HorizontalGroup:new{
                    primary_btn,
                    HorizontalSpan:new{ width = gap },
                    toggle_btn,
                    HorizontalSpan:new{ width = gap },
                    ignore_btn,
                }
            else
                main_action_btn = HorizontalGroup:new{
                    primary_btn,
                    HorizontalSpan:new{ width = gap },
                    toggle_btn,
                    HorizontalSpan:new{ width = gap },
                    ignore_btn,
                    HorizontalSpan:new{ width = gap },
                    Button:new{
                        text = remove_text,
                        text_font_size = btn_font_size,
                        bordersize = sc(1),
                        padding = 0,
                        radius = sc(4),
                        width = widths[4],
                        height = action_btn_h,
                        show_parent = self,
                        callback = doRemove,
                    }
                }
            end
        end
    else
        main_action_btn = Button:new{
            text = is_font and _("Install Font") or (self.patch and _("Install Patch") or _("Install")),
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
                if is_font then
                    self.Storefront:installFontFromRepo(self.repo)
                elseif self.patch then
                    self.Storefront:installPatchFromRepo(self.repo, self.patch)
                else
                    local rel = self.repo and (self.repo.latest_release or (self.repo.data and self.repo.data.latest_release))
                    if self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                        self.Storefront:promptPluginInstallOptions(self.repo, rel, true)
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
    self.active_tab = self.default_tab or (is_font and "sample_text" or (self.kind == "update" and "release_notes" or "readme"))

    local readme_w = self.screen_w - sc(24)

    local loadContent

    -- Shared font size for the content tab bar: the largest size where all
    -- tab labels fit within the available content width.
    local content_tab_labels = { _("README"), _("Release Notes"), _("Versions") }
    if self.has_wiki ~= false then
        table.insert(content_tab_labels, _("Wiki"))
    end
    local content_tab_gap = sc(12)
    -- Tab padding inside Button: sc(4) each side = sc(8) total + sc(8) underline gutter
    local content_tab_font_size = calcGroupFontSize(
        content_tab_labels, readme_w, content_tab_gap, "cfont", sc(16)
    )

    local function makeTab(label, is_active, callback_fn)
        local txt_w = TextWidget:new{
            text = label,
            face = Font:getFace("cfont", content_tab_font_size),
            bold = is_active,
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(120),
        }
        local btn = Button:new{
            text = label,
            text_font_size = content_tab_font_size,
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

    local function buildTabBar()
        if is_font then
            local sample_col = makeTab(_("Sample Text"), true, function() end)

            local reader_default = getReaderFontSize()
            self.preview_font_size = tonumber(self.preview_font_size) or reader_default
            local cur_font_size = self.preview_font_size

            local dec_btn = Button:new{
                text = " – ",
                text_font_bold = true,
                text_font_size = 16,
                padding = sc(4),
                bordersize = 0,
                show_parent = self,
                callback = function()
                    if self.preview_font_size > 12 then
                        self.preview_font_size = self.preview_font_size - 1
                        if self.tab_bar_box then
                            if rawget(self.tab_bar_box, "_bb") then self.tab_bar_box._bb = nil end
                            if rawget(self.tab_bar_box, "bb") then self.tab_bar_box.bb = nil end
                            self.tab_bar_box[1] = self.buildTabBar()
                        end
                        if self.loadContent then
                            self.loadContent("sample_text", false, true)
                        end
                        UIManager:setDirty(self, "ui")
                    end
                end,
            }

            local reset_btn = Button:new{
                text = string.format("%d pt", cur_font_size),
                text_font_bold = true,
                text_font_size = 15,
                padding = sc(4),
                bordersize = 0,
                show_parent = self,
                callback = function()
                    if self.preview_font_size ~= reader_default then
                        self.preview_font_size = reader_default
                        if self.tab_bar_box then
                            if rawget(self.tab_bar_box, "_bb") then self.tab_bar_box._bb = nil end
                            if rawget(self.tab_bar_box, "bb") then self.tab_bar_box.bb = nil end
                            self.tab_bar_box[1] = self.buildTabBar()
                        end
                        if self.loadContent then
                            self.loadContent("sample_text", false, true)
                        end
                        UIManager:setDirty(self, "ui")
                    end
                end,
            }

            local inc_btn = Button:new{
                text = " + ",
                text_font_bold = true,
                text_font_size = 16,
                padding = sc(4),
                bordersize = 0,
                show_parent = self,
                callback = function()
                    if self.preview_font_size < 48 then
                        self.preview_font_size = self.preview_font_size + 1
                        if self.tab_bar_box then
                            if rawget(self.tab_bar_box, "_bb") then self.tab_bar_box._bb = nil end
                            if rawget(self.tab_bar_box, "bb") then self.tab_bar_box.bb = nil end
                            self.tab_bar_box[1] = self.buildTabBar()
                        end
                        if self.loadContent then
                            self.loadContent("sample_text", false, true)
                        end
                        UIManager:setDirty(self, "ui")
                    end
                end,
            }

            local controls_group = HorizontalGroup:new{
                align = "center",
                dec_btn,
                HorizontalSpan:new{ width = sc(2) },
                reset_btn,
                HorizontalSpan:new{ width = sc(2) },
                inc_btn,
            }

            local sample_w = sample_col:getSize().w
            local controls_w = controls_group:getSize().w
            local gap = readme_w - sample_w - controls_w
            if gap < sc(8) then gap = sc(8) end

            self._font_size_btns = { dec_btn, reset_btn, inc_btn }
            self.tab_buttons = { sample_col[1], dec_btn, reset_btn, inc_btn }
            if self.updateFocusLayout then self:updateFocusLayout() end

            return HorizontalGroup:new{
                align = "center",
                sample_col,
                HorizontalSpan:new{ width = gap },
                controls_group,
            }
        end

        local is_readme = (self.active_tab == "readme")
        local is_rel    = (self.active_tab == "release_notes")
        local is_ver    = (self.active_tab == "versions")
        local is_wiki   = (self.active_tab == "wiki")

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

        local wiki_col = makeTab(_("Wiki"), is_wiki, function()
            if self.active_tab ~= "wiki" then
                self.active_tab = "wiki"
                if self.tab_bar_box then
                    self.tab_bar_box[1] = self:buildTabBar()
                end
                UIManager:setDirty(self, "ui")
                loadContent("wiki")
            end
        end)

        local tab_group_items = {
            readme_col,
            HorizontalSpan:new{ width = content_tab_gap },
            rel_col,
            HorizontalSpan:new{ width = content_tab_gap },
            ver_col,
        }

        if self.has_wiki ~= false then
            table.insert(tab_group_items, HorizontalSpan:new{ width = content_tab_gap })
            table.insert(tab_group_items, wiki_col)
        end

        local tab_buttons = {}
        if is_font then
            if sample_col and sample_col[1] then table.insert(tab_buttons, sample_col[1]) end
            if self._font_size_btns then
                for _, b in ipairs(self._font_size_btns) do
                    table.insert(tab_buttons, b)
                end
            end
        else
            if readme_col and readme_col[1] then table.insert(tab_buttons, readme_col[1]) end
            if rel_col and rel_col[1] then table.insert(tab_buttons, rel_col[1]) end
            if ver_col and ver_col[1] then table.insert(tab_buttons, ver_col[1]) end
            if wiki_col and wiki_col[1] and self.has_wiki ~= false then table.insert(tab_buttons, wiki_col[1]) end
        end
        self.tab_buttons = tab_buttons
        if self.updateFocusLayout then self:updateFocusLayout() end

        return HorizontalGroup:new(tab_group_items)
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
    local header_h = back_btn:getSize().h
                   + sc(8)
                   + title_label:getSize().h
                   + sc(4)
                   + meta_label:getSize().h
                   + (folder_pill_widget and (sc(6) + folder_pill_widget:getSize().h) or 0)
                   + sc(12)
                   + desc_label:getSize().h
                   + sc(16)
                   + (main_action_btn.getSize and main_action_btn:getSize().h or sc(44))
                   + sc(16)
                   + Size.line.thin
                   + sc(8)
                   + tab_bar_h
                   + sc(8)

    -- Pagination bar height (top gap + bar height + bottom margin gap)
    local pager_h  = sc(12) + sc(36) + sc(12)

    -- FrameContainer padding (top+bottom)
    local frame_padding = sc(12) * 2

    local readme_h = self.screen_h - frame_padding - header_h - pager_h
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
img { display: block !important; max-width: 100%% !important; height: auto !important; margin-left: auto !important; margin-right: auto !important; }
table { width: 100%% !important; min-width: 100%% !important; border-collapse: collapse !important; margin: 0.6em 0 !important; border: 1px solid #666666 !important; }
th { background-color: #e0e0e0 !important; font-weight: bold !important; border: 1px solid #888888 !important; padding: 5px 8px !important; text-align: left !important; }
td { vertical-align: top !important; border: 1px solid #cccccc !important; padding: 5px 8px !important; }
tr:nth-child(even) td { background-color: #f5f5f5 !important; }
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
        text = _("1 / 1"),
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local prev_btn
    local next_btn

    local function updatePagination()
        local is_versions = (self.active_tab == "versions")
        local total = is_versions and (self.versions_total_pages or 1) or (html_box.page_count or 1)
        if total < 1 then total = 1 end
        local cur = is_versions and (self.versions_page or 1) or (html_box.page_number or 1)
        cur = math.max(1, math.min(cur, total))
        if not is_versions then
            html_box.page_number = cur
        end

        if page_indicator and page_indicator.setText then
            page_indicator:setText(string.format("%d / %d", cur, total), readme_w / 3)
        end
        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end
        if prev_btn and prev_btn.enableDisable then
            prev_btn:enableDisable(cur > 1)
        end
        if next_btn and next_btn.enableDisable then
            next_btn:enableDisable(cur < total)
        end
        UIManager:setDirty(self, "ui")
    end

    prev_btn = Button:new{
        text = _("< Prev"),
        text_font_size = 16,
        padding = sc(8),
        bordersize = 0,
        background = nil,
        show_parent = self,
        callback = function()
            self:onPrevPage()
        end,
    }

    next_btn = Button:new{
        text = _("Next >"),
        text_font_size = 16,
        padding = sc(8),
        bordersize = 0,
        background = nil,
        show_parent = self,
        callback = function()
            self:onNextPage()
        end,
    }

    self.prev_btn = prev_btn
    self.next_btn = next_btn

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

    self._html_box = html_box
    self._updatePagination = updatePagination
    loadContent = function(tab_name, force_refresh, keep_page_number)
        self.loadContent = loadContent
        self.load_req_id = (self.load_req_id or 0) + 1
        local current_req_id = self.load_req_id

        local saved_page_number = keep_page_number and (html_box.page_number or 1) or 1
        html_box.page_number = saved_page_number
        if rawget(html_box, "_bb") then html_box._bb = nil end
        if rawget(html_box, "bb") then html_box.bb = nil end

        if self.kind == "font" or tab_name == "sample_text" then
            local font_family = self.repo.font_family or self.repo.font_face or self.repo.name or "Sample Font"
            local font_file = self.repo.font_file or self.repo.font_filename or (self.repo.name and (self.repo.name .. "-Regular.ttf")) or ""
            local font_cat = self.repo.category or self.repo.kind_label or "E-Reader Font"
            local font_lic = self.repo.license or "SIL Open Font License"
            local font_author = (owner and owner ~= "") and owner or (self.repo.author or "Open Source Community")

            local reader_default = getReaderFontSize()
            self.preview_font_size = tonumber(self.preview_font_size) or reader_default
            local cur_font_size = self.preview_font_size
            local is_default_sz = (cur_font_size == reader_default)

            local search_dirs = {
                DataStorage:getDataDir() .. "/fonts/" .. (self.repo.name or ""),
                "assets/fonts/" .. (self.repo.name or ""),
                "plugins/storefront.koplugin/assets/fonts/" .. (self.repo.name or ""),
                DataStorage:getDataDir() .. "/plugins/storefront.koplugin/assets/fonts/" .. (self.repo.name or ""),
                DataStorage:getDataDir() .. "/plugins/storefront.koplugin/storefront.koplugin/assets/fonts/" .. (self.repo.name or ""),
            }

            local loaded_font_path = nil
            for _, dir in ipairs(search_dirs) do
                local rp = ffiutil.realpath and ffiutil.realpath(dir) or dir
                if rp and lfs.attributes(rp, "mode") == "directory" then
                    if font_file and font_file ~= "" then
                        local exact_p = rp .. "/" .. font_file
                        if lfs.attributes(exact_p, "mode") == "file" then
                            loaded_font_path = exact_p
                            break
                        end
                    end
                    local fallback_path = nil
                    for file in lfs.dir(rp) do
                        if file ~= "." and file ~= ".." and (file:match("%.ttf$") or file:match("%.otf$")) then
                            local lfile = file:lower()
                            if lfile:find("regular") then
                                loaded_font_path = rp .. "/" .. file
                                break
                            elseif not lfile:find("italic") and not lfile:find("bold") and not lfile:find("oblique") then
                                fallback_path = rp .. "/" .. file
                            elseif not fallback_path then
                                fallback_path = rp .. "/" .. file
                            end
                        end
                    end
                    if loaded_font_path then break end
                    if fallback_path then
                        loaded_font_path = fallback_path
                        break
                    end
                end
                if loaded_font_path then break end
            end

            local custom_font_face_rule = ""
            local css_family_name = font_family
            if loaded_font_path then
                css_family_name = "CustomPreviewFont"
                -- mupdf expects bare absolute paths in url() - not file:// URIs
                local safe_url = loaded_font_path:gsub("'", "%%27")
                custom_font_face_rule = string.format("\n@font-face { font-family: 'CustomPreviewFont'; src: url('%s'); }", safe_url)
            end

            local specimen_css = readme_css .. custom_font_face_rule .. string.format(
                "\n.specimen-text, .specimen-text * { font-family: '%s', serif, sans-serif !important; }",
                css_family_name)

            local specimen_html = string.format([[
<div class="specimen-text">
  <h2 style="margin-bottom: 4px; font-size: 1.8em;">%s</h2>
  <p style="color: #555555; font-size: 0.85em; margin-top: 0; margin-bottom: 12px;">%s &nbsp;&middot;&nbsp; %s &nbsp;&middot;&nbsp; %s</p>
  <hr style="border: 0; border-top: 1px solid #cccccc; margin: 8px 0;" />
  
  <h3 style="margin-top: 12px; margin-bottom: 6px; font-size: 1.2em;">%s</h3>
  <p style="font-size: 1.1em; letter-spacing: 1px; line-height: 1.4; margin-bottom: 12px;">
    ABCDEFGHIJKLMNOPQRSTUVWXYZ<br/>
    abcdefghijklmnopqrstuvwxyz<br/>
    0123456789 (!@#$%%^&amp;*.,?:;)
  </p>

  <hr style="border: 0; border-top: 1px solid #cccccc; margin: 8px 0;" />
  <h3 style="margin-top: 12px; margin-bottom: 6px; font-size: 1.2em;">%s</h3>
  <p style="font-size: 1.1em; line-height: 1.35; margin-bottom: 8px;">%s</p>
  <p style="font-size: 1.0em; line-height: 1.35; margin-bottom: 12px;">%s</p>

  <hr style="border: 0; border-top: 1px solid #cccccc; margin: 8px 0;" />
  <h3 style="margin-top: 12px; margin-bottom: 6px; font-size: 1.2em;">%s</h3>
  <p style="font-size: 1.0em; line-height: 1.45; text-align: justify; margin-bottom: 10px;">
    %s
  </p>
  <p style="font-size: 1.0em; line-height: 1.45; text-align: justify; margin-bottom: 10px;">
    %s
  </p>
</div>
]], font_family,
    string.format(_("Category: %s"), font_cat),
    string.format(_("License: %s"), font_lic),
    string.format(_("By: %s"), font_author),
    _("Alphabet & Numbers"),
    _("Pangram Preview"),
    _("The quick brown fox jumps over the lazy dog."),
    _("Pack my box with five dozen liquor jugs."),
    _("Reading Passage Specimen"),
    _("It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife. However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters."),
    _("\"My dear Mr. Bennet,\" said his lady to him one day, \"have you heard that Netherfield Park is let at last?\" Mr. Bennet replied that he had not. \"But it is,\" returned she; \"for Mrs. Long has just been here, and she told me all about it.\" Mr. Bennet made no answer.")
)

            local ok_set, set_err = pcall(function()
                html_box:setContent(specimen_html, specimen_css, sc(cur_font_size))
            end)
            if not ok_set then
                logger.warn("Storefront Details: font specimen setContent failed", set_err)
                local fallback_css = readme_css .. string.format("\n.specimen-text { font-family: '%s', serif, sans-serif !important; }", font_family)
                pcall(function()
                    html_box:setContent(specimen_html, fallback_css, sc(cur_font_size))
                end)
            end
            if keep_page_number then
                local total_pages = html_box.page_count or 1
                html_box.page_number = math.max(1, math.min(saved_page_number, total_pages))
            end
            updatePagination()
            return
        end

        if tab_name == "release_notes" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Release Notes...") .. "</p>", readme_css, sc(18))
        elseif tab_name == "versions" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Versions...") .. "</p>", readme_css, sc(18))
        elseif tab_name == "wiki" then
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading Wiki...") .. "</p>", readme_css, sc(18))
        else
            html_box:setContent("<p style='text-align:center;color:gray;'>" .. _("Loading README...") .. "</p>", readme_css, sc(18))
        end
        if self.content_area_box then
            self.content_area_box[1] = html_box
        end
        if self.pagination_bar_container and pagination_bar then
            self.pagination_bar_container[1] = pagination_bar
        end
        updatePagination()
        UIManager:setDirty(self, "ui")

        if (not owner or owner == "" or not repo_name or repo_name == "") and tab_name ~= "versions" then
            local msg = (tab_name == "release_notes") and _("No Release Notes available.") or (tab_name == "wiki" and _("No Wiki available.") or _("No README available."))
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
                local allow_pre = item_key and InstallStore.isPreReleaseAllowed(item_key) or false

                local raw_releases = self.cached_releases
                if not raw_releases or force_refresh then
                    local cached = getReleasesFromCache(self.repo)
                    if cached and #cached > 1 then
                        self.cached_releases = cached
                        raw_releases = cached
                    else
                        local fetched, err = GitHubClient.fetchReleases(owner, repo_name)
                        if fetched and #fetched > 0 then
                            self.cached_releases = fetched
                            raw_releases = fetched
                        else
                            -- Fall back to cached release for display without poisoning self.cached_releases permanently
                            raw_releases = cached
                        end
                    end
                end

                raw_releases = raw_releases or {}
                local releases = {}
                for _, rel in ipairs(raw_releases) do
                    local tag = rel.tag_name or rel.name or ""
                    local is_pre = (rel.prerelease == true) or (tag:lower():find("beta") or tag:lower():find("alpha") or tag:lower():find("rc"))
                    if allow_pre or not is_pre then
                        table.insert(releases, rel)
                    end
                end

                if self.is_closed or self.load_req_id ~= current_req_id or self.active_tab ~= tab_name then return end

                local StorefrontListItem = require("storefront_list_item")
                self.versions_page = self.versions_page or 1

                local toggle_h = sc(46)
                local avail_h = readme_h - toggle_h
                local row_h = sc(72)
                local per_page = math.max(1, math.floor(avail_h / row_h))
                local total_rels = #releases
                local total_pages = math.max(1, math.ceil(total_rels / per_page))
                self.versions_total_pages = total_pages
                self.versions_per_page = per_page
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
                toggle_btn.show_parent = self
                toggle_btn.isFocusable = function() return true end
                toggle_btn.onFocus = function()
                    toggle_frame.bordersize = sc(2)
                    toggle_frame.color = Blitbuffer.COLOR_BLACK
                    toggle_frame.background = Blitbuffer.Color8(230)
                    UIManager:setDirty(self.show_parent or self, "fast")
                    return true
                end
                toggle_btn.onUnfocus = function()
                    toggle_frame.bordersize = sc(1)
                    toggle_frame.color = nil
                    toggle_frame.background = Blitbuffer.COLOR_WHITE
                    UIManager:setDirty(self.show_parent or self, "fast")
                    return true
                end
                toggle_btn.onTapSelect = function()
                    return toggle_btn:onStorefrontVersionToggleTap()
                end
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
                        local next_val = not current
                        InstallStore.setPreReleaseAllowed(item_key, next_val)
                        if dialog_self.repo and dialog_self.repo.name then InstallStore.setPreReleaseAllowed(dialog_self.repo.name, next_val) end
                        if dialog_self.repo and dialog_self.repo.full_name then InstallStore.setPreReleaseAllowed(dialog_self.repo.full_name, next_val) end
                        if dialog_self.update_item and dialog_self.update_item.plugin and dialog_self.update_item.plugin.dirname then InstallStore.setPreReleaseAllowed(dialog_self.update_item.plugin.dirname, next_val) end
                        if dialog_self.loadContent then dialog_self.loadContent("versions") end
                    end
                    return true
                end

                table.insert(list_items, toggle_btn)
                table.insert(list_items, VerticalSpan:new{ width = sc(6) })

                local tab_focus_items = { toggle_btn }

                if #releases == 0 then
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
                            show_parent = self,
                        }

                        table.insert(list_items, item)
                        table.insert(tab_focus_items, item)
                        if i < end_idx then
                            table.insert(list_items, LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{ w = readme_w, h = Size.line.thin } })
                        end
                    end
                end

                self.tab_item_widgets = tab_focus_items
                if self.updateFocusLayout then self:updateFocusLayout() end

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

            local function buildViewerHeader()
                if tab_name ~= "wiki" then
                    html_box.dimen = Geom:new{ w = readme_w, h = readme_h }
                    return html_box
                end

                local bar_h = sc(28)
                local hr_h = Size.line.thin
                local header_h_offset = bar_h + sc(4) + hr_h + sc(4)
                html_box.dimen = Geom:new{ w = readme_w, h = readme_h - header_h_offset }

                local dialog_self = self
                local page_title = self.active_wiki_page or "Home"
                local selector_btn = Button:new{
                    text = page_title .. "  ▾",
                    text_font_size = 15,
                    text_font_bold = true,
                    padding = sc(4),
                    padding_h = sc(10),
                    bordersize = sc(1),
                    radius = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    show_parent = self,
                    callback = function()
                        local Menu = require("ui/widget/menu")
                        local pages_menu
                        local menu_items = {}
                        local items = self.wiki_sidebar_items or {}
                        if #items == 0 then
                            items = { { title = "Home", page = "Home" } }
                        end
                        for _, item in ipairs(items) do
                            table.insert(menu_items, {
                                text = item.title or item.page,
                                callback = function()
                                    if pages_menu then
                                        UIManager:close(pages_menu)
                                    end
                                    if item.page ~= self.active_wiki_page then
                                        self.wiki_history = self.wiki_history or {}
                                        if self.active_wiki_page then
                                            table.insert(self.wiki_history, self.active_wiki_page)
                                        end
                                        self.active_wiki_page = item.page
                                        if self.loadContent then self.loadContent("wiki") end
                                    end
                                end,
                            })
                        end
                        local menu_w = math.min(self.screen_w - sc(32), sc(500))
                        pages_menu = Menu:new{
                            title = _("Wiki Pages"),
                            item_table = menu_items,
                            width = menu_w,
                            radius = 0,
                            rect_radius = 0,
                            bordersize = sc(2),
                        }
                        local function zeroRadius(w, depth)
                            if not w or type(w) ~= "table" or (depth and depth > 4) then return end
                            if rawget(w, "radius") then w.radius = 0 end
                            if rawget(w, "rect_radius") then w.rect_radius = 0 end
                            for k, v in pairs(w) do
                                if type(v) == "table" and k ~= "parent" and k ~= "show_parent" and k ~= "dialog" and k ~= "_parent" and k ~= "ui" then
                                    if type(k) == "number" or k == "frame" or k == "cover_frame" or k == "container" or k == "title_bar" or k == "title_frame" or k == "movable_container" then
                                        zeroRadius(v, (depth or 0) + 1)
                                    end
                                end
                            end
                        end
                        zeroRadius(pages_menu)
                        UIManager:show(pages_menu)
                    end,
                }

                local refresh_icon = ImageWidget:new{
                    file = getAssetPath("rotate-cw.svg"),
                    width = sc(18),
                    height = sc(18),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                local refresh_frame = FrameContainer:new{
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = sc(1),
                    radius = 0,
                    padding = sc(3),
                    padding_h = sc(6),
                    refresh_icon,
                }

                local refresh_btn = InputContainer:new{
                    refresh_frame,
                }
                refresh_btn.ges_events = {
                    TapRefreshWiki = {
                        GestureRange:new{
                            ges = "tap",
                            range = function()
                                local d = refresh_btn.dimen or refresh_frame:getSize()
                                return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                            end,
                        },
                    },
                }
                function refresh_btn:onTapRefreshWiki()
                    if dialog_self.loadContent then dialog_self.loadContent("wiki", true) end
                    return true
                end

                local back_arrow_icon = ImageWidget:new{
                    file = getAssetPath("arrow-left.svg"),
                    width = sc(18),
                    height = sc(18),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }

                local back_wiki_frame = FrameContainer:new{
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = sc(1),
                    radius = 0,
                    padding = sc(3),
                    padding_h = sc(6),
                    back_arrow_icon,
                }

                local back_wiki_btn = InputContainer:new{
                    back_wiki_frame,
                }
                back_wiki_btn.ges_events = {
                    TapBackWiki = {
                        GestureRange:new{
                            ges = "tap",
                            range = function()
                                local d = back_wiki_btn.dimen or back_wiki_frame:getSize()
                                return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                            end,
                        },
                    },
                }
                function back_wiki_btn:onTapBackWiki()
                    if dialog_self.wiki_history and #dialog_self.wiki_history > 0 then
                        local prev_page = table.remove(dialog_self.wiki_history)
                        dialog_self.active_wiki_page = prev_page
                        if dialog_self.loadContent then dialog_self.loadContent("wiki") end
                    else
                        pcall(function() InfoMessage:show(_("No previous page in history")) end)
                    end
                    return true
                end

                local right_btn_group = HorizontalGroup:new{
                    back_wiki_btn,
                    HorizontalSpan:new{ width = sc(6) },
                    refresh_btn,
                }

                local header_bar = OverlapGroup:new{
                    dimen = Geom:new{ w = readme_w, h = bar_h },
                    LeftContainer:new{
                        dimen = Geom:new{ w = readme_w, h = bar_h },
                        selector_btn,
                    },
                    RightContainer:new{
                        dimen = Geom:new{ w = readme_w, h = bar_h },
                        right_btn_group,
                    },
                }

                return VerticalGroup:new{
                    align = "left",
                    header_bar,
                    VerticalSpan:new{ width = sc(4) },
                    LineWidget:new{
                        background = Blitbuffer.COLOR_DARK_GRAY,
                        dimen = Geom:new{ w = readme_w, h = hr_h },
                    },
                    VerticalSpan:new{ width = sc(4) },
                    html_box,
                }
            end

            if self.content_area_box then
                self.content_area_box[1] = buildViewerHeader()
            end
            if self.pagination_bar_container then
                self.pagination_bar_container[1] = pagination_bar
            end

            self.tab_item_widgets = nil
            if self.updateFocusLayout then self:updateFocusLayout() end

            if RepoContent and type(RepoContent.resetPayloadTracker) == "function" then
                RepoContent.resetPayloadTracker()
            end

            local cache_dir, expected_path
            if tab_name == "release_notes" then
                cache_dir = require("datastorage"):getDataDir() .. "/cache/Storefront/release_notes"
                local clean_repo = repo_name:gsub("%.koplugin$", "")
                local safe_owner = owner:gsub("[^%w_-]", "_")
                local safe_repo  = clean_repo:gsub("[^%w_-]", "_")
                expected_path = string.format("%s/%s_%s_RELEASENOTES.html", cache_dir, safe_owner, safe_repo)
            elseif tab_name == "wiki" then
                self.active_wiki_page = self.active_wiki_page or "Home"
                if RepoContent and type(RepoContent.getWikiCacheDir) == "function" then
                    cache_dir = RepoContent.getWikiCacheDir(owner, repo_name)
                else
                    cache_dir = require("datastorage"):getDataDir() .. "/cache/Storefront/wiki"
                end
                local safe_page = self.active_wiki_page:gsub("[^%w_-]", "_")
                expected_path = string.format("%s/%s.html", cache_dir, safe_page)
            else
                cache_dir = require("datastorage"):getDataDir() .. "/cache/Storefront/readme"
                local safe_owner = owner:gsub("[^%w_-]", "_")
                local safe_repo = repo_name:gsub("[^%w_-]", "_")
                expected_path = string.format("%s/%s_%s_README.html", cache_dir, safe_owner, safe_repo)
            end

            -- Render cached content immediately if available
            html_box.page_number = 1
            local cached_html = (not force_refresh and lfs.attributes(expected_path, "mode") == "file") and util.readFromFile(expected_path) or nil

            if cached_html and cached_html ~= "" then
                pcall(function()
                    html_box:setContent(cached_html, readme_css, sc(18), false, false, cache_dir)
                end)
            else
                local loading_msg = (tab_name == "wiki") and _("Loading Wiki...") or ((tab_name == "release_notes") and _("Loading Release Notes...") or _("Loading README..."))
                pcall(function()
                    html_box:setContent(string.format('<div class="markdown-body"><p style="text-align:center;color:gray;margin-top:2em;">%s</p></div>', loading_msg), readme_css, sc(18))
                end)
            end
            if rawget(html_box, "_bb") then html_box._bb = nil end
            if rawget(html_box, "bb") then html_box.bb = nil end
            updatePagination()

            -- Perform network fetch asynchronously without blocking the UI main loop
            UIManager:scheduleIn(0.05, function()
                if self.is_closed or self.active_tab ~= tab_name then return end
                local ok, path
                if tab_name == "release_notes" then
                    local rel_data = (self.update_item and (self.update_item.remote or self.update_item.remote_entry)) or self.repo.latest_release
                    if RepoContent and type(RepoContent.fetchReleaseNotesHtml) == "function" then
                        local ok_pcall, res_ok, res_path = pcall(RepoContent.fetchReleaseNotesHtml, owner, repo_name, rel_data, force_refresh)
                        if ok_pcall then ok, path = res_ok, res_path end
                    end
                elseif tab_name == "wiki" then
                    if RepoContent and type(RepoContent.fetchWikiSidebar) == "function" then
                        pcall(function() self.wiki_sidebar_items = RepoContent.fetchWikiSidebar(owner, repo_name, force_refresh) end)
                    end
                    if RepoContent and type(RepoContent.fetchWikiPageHtml) == "function" then
                        local ok_pcall, res_ok, res_path = pcall(RepoContent.fetchWikiPageHtml, owner, repo_name, self.active_wiki_page, force_refresh)
                        if ok_pcall then ok, path = res_ok, res_path end
                    end
                else
                    if RepoContent and type(RepoContent.fetchReadmeHtml) == "function" then
                        local ok_pcall, res_ok, res_path = pcall(RepoContent.fetchReadmeHtml, owner, repo_name, force_refresh)
                        if ok_pcall then ok, path = res_ok, res_path end
                    end
                end

                if ok and path then
                    local fresh_html = util.readFromFile(path)
                    if fresh_html and fresh_html ~= "" and self.active_tab == tab_name and self._html_box then
                        pcall(function()
                            self._html_box:setContent(fresh_html, readme_css, sc(18), false, false, cache_dir)
                        end)
                        if rawget(self._html_box, "_bb") then self._html_box._bb = nil end
                        if rawget(self._html_box, "bb") then self._html_box.bb = nil end
                        if self._updatePagination then self._updatePagination() end
                        UIManager:setDirty(self, "ui")
                        UIManager:setDirty(self._html_box, "ui")
                        pcall(collectgarbage, "collect")

                        if RepoContent and type(RepoContent.processPendingImages) == "function" then
                            UIManager:scheduleIn(0.5, function()
                                RepoContent.processPendingImages(function(updated_html_path)
                                    UIManager:scheduleIn(0.1, function()
                                        if self.active_tab == tab_name and self._html_box then
                                            local updated_html = util.readFromFile(updated_html_path)
                                            if updated_html and updated_html ~= "" then
                                                pcall(function()
                                                    self._html_box:setContent(updated_html, readme_css, sc(18), false, false, cache_dir)
                                                end)
                                                if rawget(self._html_box, "_bb") then self._html_box._bb = nil end
                                                if rawget(self._html_box, "bb") then self._html_box.bb = nil end
                                                if self._updatePagination then self._updatePagination() end
                                                UIManager:setDirty(self, "ui")
                                                UIManager:setDirty(self._html_box, "ui")
                                                pcall(collectgarbage, "collect")
                                            end
                                        end
                                    end)
                                end)
                            end)
                        end
                    end
                elseif not cached_html then
                    local err_msg = (tab_name == "wiki") and _("Unable to load wiki page. Tap refresh to retry.") or _("Unable to read README. Tap refresh to retry.")
                    if self.active_tab == tab_name and self._html_box then
                        pcall(function()
                            self._html_box:setContent(string.format('<div class="markdown-body"><p style="text-align:center;color:red;margin-top:2em;">%s</p></div>', err_msg), readme_css, sc(18))
                        end)
                        if self._updatePagination then self._updatePagination() end
                        UIManager:setDirty(self, "ui")
                    end
                end
            end)
            UIManager:setDirty(self, "ui")
        end

        logger.info("Storefront Details: loadContent called for tab =", tab_name)
        UIManager:scheduleIn(0.01, function()
            if NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
                NetworkMgr:runWhenOnline(executeLoad)
            else
                executeLoad()
            end
        end)
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
    table.insert(content_group_items, VerticalSpan:new{ width = sc(12) })

    local content_group = VerticalGroup:new(content_group_items)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = sc(12),
        width = self.screen_w,
        height = self.screen_h,
        content_group,
    }

    local action_btn_list = {}
    if main_action_btn then
        if main_action_btn.show_parent then
            table.insert(action_btn_list, main_action_btn)
        elseif type(main_action_btn) == "table" then
            for _, child in ipairs(main_action_btn) do
                if child and child.show_parent then
                    table.insert(action_btn_list, child)
                end
            end
        end
    end
    self.action_buttons = action_btn_list

    self:updateFocusLayout()
end

function StorefrontDetailsDialog:updateFocusLayout()
    local layout = {}
    if self.back_btn then
        table.insert(layout, { self.back_btn })
    end
    if self.action_buttons and #self.action_buttons > 0 then
        table.insert(layout, self.action_buttons)
    end
    if self.tab_buttons and #self.tab_buttons > 0 then
        table.insert(layout, self.tab_buttons)
    end
    if self.tab_item_widgets and #self.tab_item_widgets > 0 then
        for _, w in ipairs(self.tab_item_widgets) do
            table.insert(layout, { w })
        end
    end
    local pager_row = {}
    if self.prev_btn then table.insert(pager_row, self.prev_btn) end
    if self.next_btn then table.insert(pager_row, self.next_btn) end
    if #pager_row > 0 then
        table.insert(layout, pager_row)
    end
    self.layout = layout
    if not self.selected then
        self.selected = { x = 1, y = 1 }
    end
end

function StorefrontDetailsDialog:getFocusItem()
    if not self.layout or not self.selected then
        return nil
    end
    if self.layout[self.selected.y] then
        return self.layout[self.selected.y][self.selected.x]
    end
    return nil
end

function StorefrontDetailsDialog:onPress()
    local item = self:getFocusItem()
    if item then
        if item.onTapSelect then
            return item:onTapSelect()
        elseif item.callback then
            item.callback()
            return true
        end
    end
    if FocusManager and FocusManager.onPress then
        return FocusManager.onPress(self)
    end
    return false
end

function StorefrontDetailsDialog:onLinkTap(href)
    if href and type(href) == "string" then
        if href == "storefront-font-size:dec" then
            local reader_default = getReaderFontSize()
            self.preview_font_size = tonumber(self.preview_font_size) or reader_default
            if self.preview_font_size > 12 then
                self.preview_font_size = self.preview_font_size - 1
                UIManager:nextTick(function()
                    if not self.is_closed and self.loadContent then
                        self.loadContent("sample_text", false, true)
                    end
                end)
            end
            return true
        elseif href == "storefront-font-size:inc" then
            local reader_default = getReaderFontSize()
            self.preview_font_size = tonumber(self.preview_font_size) or reader_default
            if self.preview_font_size < 48 then
                self.preview_font_size = self.preview_font_size + 1
                UIManager:nextTick(function()
                    if not self.is_closed and self.loadContent then
                        self.loadContent("sample_text", false, true)
                    end
                end)
            end
            return true
        elseif href == "storefront-font-size:reset" then
            local reader_default = getReaderFontSize()
            if self.preview_font_size ~= reader_default then
                self.preview_font_size = reader_default
                UIManager:nextTick(function()
                    if not self.is_closed and self.loadContent then
                        self.loadContent("sample_text", false, true)
                    end
                end)
            end
            return true
        elseif href:find("^storefront%-img:") then
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
                local next_val = not current
                InstallStore.setPreReleaseAllowed(item_key, next_val)
                if self.repo and self.repo.name then InstallStore.setPreReleaseAllowed(self.repo.name, next_val) end
                if self.repo and self.repo.full_name then InstallStore.setPreReleaseAllowed(self.repo.full_name, next_val) end
                if self.update_item and self.update_item.plugin and self.update_item.plugin.dirname then InstallStore.setPreReleaseAllowed(self.update_item.plugin.dirname, next_val) end
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
        elseif href:find("^storefront%-wiki:") or (self.active_tab == "wiki" and href and type(href) == "string") then
            local clean_page = href:gsub("^storefront%-wiki:", "")
            clean_page = clean_page:gsub("^https?://github%.com/[^/]+/[^/]+/wiki/", "")
            clean_page = clean_page:gsub("^/[^/]+/[^/]+/wiki/", "")
            clean_page = clean_page:gsub("^%./", ""):gsub("^/+", "")
            clean_page = clean_page:gsub("#.*$", "")
            clean_page = clean_page:gsub("%%20", " ")
            clean_page = clean_page:gsub("^%s+", ""):gsub("%s+$", "")

            local is_external = (href:find("^https?://") or href:find("^http://") or href:find("^mailto:")) and not href:find("github%.com/[^/]+/[^/]+/wiki/")

            if not is_external and clean_page and clean_page ~= "" then
                self.wiki_history = self.wiki_history or {}
                if self.active_wiki_page then
                    table.insert(self.wiki_history, self.active_wiki_page)
                end
                self.active_wiki_page = clean_page
                self.active_tab = "wiki"
                if self.tab_bar_box then
                    self.tab_bar_box[1] = self:buildTabBar()
                end
                if self.loadContent then
                    self.loadContent("wiki")
                end
                return true
            end
        end
    end
    return false
end

function StorefrontDetailsDialog:onNextPage()
    if self.active_tab == "versions" then
        if self.versions_page and self.versions_page < (self.versions_total_pages or 1) then
            self.versions_page = self.versions_page + 1
            if self.loadContent then self.loadContent("versions") end
            return true
        end
    else
        local html_box = self._html_box
        if html_box then
            local total = html_box.page_count or 1
            local cur = html_box.page_number or 1
            if cur < total then
                html_box.page_number = cur + 1
                if rawget(html_box, "_bb") then html_box._bb = nil end
                if rawget(html_box, "bb") then html_box.bb = nil end
                if self._updatePagination then self._updatePagination() end
                UIManager:setDirty(self, "ui")
                return true
            end
        end
    end
    return false
end

function StorefrontDetailsDialog:onPrevPage()
    if self.active_tab == "versions" then
        if self.versions_page and self.versions_page > 1 then
            self.versions_page = self.versions_page - 1
            if self.loadContent then self.loadContent("versions") end
            return true
        end
    else
        local html_box = self._html_box
        if html_box then
            local cur = html_box.page_number or 1
            if cur > 1 then
                html_box.page_number = cur - 1
                if rawget(html_box, "_bb") then html_box._bb = nil end
                if rawget(html_box, "bb") then html_box.bb = nil end
                if self._updatePagination then self._updatePagination() end
                UIManager:setDirty(self, "ui")
                return true
            end
        end
    end
    return false
end

function StorefrontDetailsDialog:onSwipe(arg, ges_ev)
    local ev = (type(arg) == "table" and arg) or (type(ges_ev) == "table" and ges_ev)
    local direction = ev and ev.direction
    if direction == "left" or direction == "west" then
        return self:onNextPage()
    elseif direction == "right" or direction == "east" then
        return self:onPrevPage()
    end
    return false
end

function StorefrontDetailsDialog:onClose()
    self.is_closed = true
    UIManager:close(self, "ui")
    local sf = self.Storefront
    local needs_refresh = self._ignore_toggled
        or self._vote_toggled
        or (sf and (sf._ignore_toggled_in_details or sf._vote_toggled_in_details))
    if needs_refresh and not self._is_replacing
            and sf
            and type(sf.refreshCurrentBrowserTab) == "function" then
        if sf._ignore_toggled_in_details then
            sf._ignore_toggled_in_details = nil
        end
        if sf._vote_toggled_in_details then
            sf._vote_toggled_in_details = nil
        end
        UIManager:nextTick(function()
            sf:refreshCurrentBrowserTab()
        end)
    end
    return true
end

function StorefrontDetailsDialog:show()
    UIManager:show(self)
end

-- ---------------------------------------------------------------------------
-- Dedicated Full-Screen Version Details Dialog
-- ---------------------------------------------------------------------------
StorefrontVersionDetailsDialog = FocusManager:extend{
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

    self.key_events = self.key_events or {}
    self.key_events.Close = { { "Back" }, { "Escape" } }
    self.key_events.NextPage = {
        { "PageDown" },
    }
    self.key_events.PrevPage = {
        { "PageUp" },
    }
    if Input and Input.group then
        if Input.group.PgFwd then
            table.insert(self.key_events.NextPage, { Input.group.PgFwd })
        end
        if Input.group.PgBack then
            table.insert(self.key_events.PrevPage, { Input.group.PgBack })
        end
        if Input.group.Back then
            table.insert(self.key_events.Close, { Input.group.Back })
        end
    end

    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        }
    }

    local back_btn = Button:new{
        text = _("< Back"),
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
        face = Font:getFace("cfont", 28),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local row_w = self.screen_w - sc(24)
    local ignore_btn_w = math.floor(row_w * 0.32)
    local primary_btn_w = row_w - ignore_btn_w - sc(12)

    local MAX_TAG_DISPLAY = 24
    local tag_display = tag
    if #tag > MAX_TAG_DISPLAY then
        tag_display = tag:sub(1, MAX_TAG_DISPLAY) .. "…"
    end

    local meta_str = string.format("Version: %s%s%s", tag, is_pre and " (PRE-RELEASE)" or "", published ~= "" and ("  ·  Published: " .. published) or "")
    local meta_label = TextBoxWidget:new{
        text = meta_str,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = row_w,
    }

    local item_key = self.patch and self.patch.filename or (self.repo and (self.repo.name or self.repo.full_name))
    local is_ignored = item_key and InstallStore.isReleaseIgnored(item_key, tag)

    local install_btn_text = string.format(_("Install %s"), tag_display)
    local btn_font_size = calcGroupFontSize({ install_btn_text }, primary_btn_w, 0, "cfont", sc(22))
    btn_font_size = math.max(btn_font_size, 11)

    local install_btn = Button:new{
        text = install_btn_text,
        text_font_size = btn_font_size,
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
            if self.Storefront and type(self.Storefront.promptPluginInstallOptions) == "function" then
                self.Storefront:promptPluginInstallOptions(self.repo, rel, true)
            else
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
    ignore_btn.frame = ignore_frame
    ignore_btn.show_parent = self
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
            if vdialog_self.parent_details then
                vdialog_self.parent_details._ignore_toggled = true
            end
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
    ignore_btn.isFocusable = function(self) return true end
    ignore_btn.onFocus = function(self)
        if self.frame then self.frame.invert = true; UIManager:setDirty(self.show_parent or self, "fast") end
        return true
    end
    ignore_btn.onUnfocus = function(self)
        if self.frame then self.frame.invert = false; UIManager:setDirty(self.show_parent or self, "fast") end
        return true
    end
    ignore_btn.onTapSelect = function(self)
        return self:onStorefrontVersionIgnoreTap()
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
                    if self.parent_details then
                        self.parent_details._ignore_toggled = true
                    end
                    UIManager:setDirty(self, "ui")
                end
                return true
            end
            return false
        end,
    }

    local page_info_btn = Button:new{
        text = _("1 / 1"),
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
    self._html_box = html_box
    self._updatePagination = updatePagination

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

    self.layout = {
        { back_btn },
        { install_btn, ignore_btn },
        { prev_btn, next_btn },
    }
    self.selected = { x = 1, y = 1 }
end

function StorefrontVersionDetailsDialog:onNextPage()
    local html_box = self._html_box
    if html_box then
        local total = html_box.page_count or 1
        local cur = html_box.page_number or 1
        if cur < total then
            html_box.page_number = cur + 1
            if rawget(html_box, "_bb") then html_box._bb = nil end
            if rawget(html_box, "bb") then html_box.bb = nil end
            if self._updatePagination then self._updatePagination() end
            UIManager:setDirty(self, "ui")
            return true
        end
    end
    return false
end

function StorefrontVersionDetailsDialog:onPrevPage()
    local html_box = self._html_box
    if html_box then
        local cur = html_box.page_number or 1
        if cur > 1 then
            html_box.page_number = cur - 1
            if rawget(html_box, "_bb") then html_box._bb = nil end
            if rawget(html_box, "bb") then html_box.bb = nil end
            if self._updatePagination then self._updatePagination() end
            UIManager:setDirty(self, "ui")
            return true
        end
    end
    return false
end

function StorefrontVersionDetailsDialog:onSwipe(arg, ges_ev)
    local ev = (type(arg) == "table" and arg) or (type(ges_ev) == "table" and ges_ev)
    local direction = ev and ev.direction
    if direction == "left" or direction == "west" then
        return self:onNextPage()
    elseif direction == "right" or direction == "east" then
        return self:onPrevPage()
    end
    return false
end

function StorefrontVersionDetailsDialog:onClose()
    if self._html_box then
        if rawget(self._html_box, "_bb") then self._html_box._bb = nil end
        if rawget(self._html_box, "bb") then self._html_box.bb = nil end
        self._html_box = nil
    end
    UIManager:close(self, "ui")
    pcall(collectgarbage, "collect")
    return true
end

function StorefrontVersionDetailsDialog:show()
    UIManager:show(self)
end

return StorefrontDetailsDialog
