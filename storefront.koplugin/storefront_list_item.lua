local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end
local function sc(val) return Device.screen:scaleBySize(val) end
local DataStorage = require("datastorage")

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("^@(.*[/\\])") or ""
    local rel_path = dir .. "assets/" .. filename
    local data_dir = (DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or ""
    local paths_to_try = {
        rel_path,
        data_dir .. "/" .. rel_path,
        data_dir .. "/plugins/" .. rel_path,
    }
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    for _, p in ipairs(paths_to_try) do
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
            _asset_path_cache[filename] = p
            return p
        end
    end
    _asset_path_cache[filename] = rel_path
    return rel_path
end

local G_bundled_fonts_registered = false
local function ensureBundledFontsRegistered()
    -- Intentionally a no-op so Storefront does not inject bundled fallback fonts
    -- into KOReader's global FontList, which would cause them to appear in the
    -- reader's Book Font selection menu even when not installed by the user.
end

local _font_face_path_cache = {}

local function resolveFontItemFace(e, size)
    size = size or 22
    if not (e and (e.kind == "font" or e.is_font)) then
        return Font:getFace("NotoSerif-Regular.ttf", size)
    end

    local face = nil
    local font_folder = e.repo_name or e.font_name or e.name or e.font_family or ""
    local font_family = e.font_family or e.font_name or e.name or ""
    local font_file = e.font_file or ""

    local font_cache_key = font_folder .. "|" .. font_family .. "|" .. font_file
    local loaded_font_path = _font_face_path_cache[font_cache_key]

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or ""

    local folder_candidates = {}
    if font_folder ~= "" then table.insert(folder_candidates, font_folder) end
    if font_family ~= "" and font_family ~= font_folder then table.insert(folder_candidates, font_family) end
    if e.name and e.name ~= font_folder and e.name ~= font_family then table.insert(folder_candidates, e.name) end

    if loaded_font_path == nil then
        local info = debug.getinfo(1, "S")
        local script_dir = info and info.source and info.source:match("^@(.*[/\\])") or ""
        if script_dir:sub(-1) == "/" or script_dir:sub(-1) == "\\" then
            script_dir = script_dir:sub(1, -2)
        end

        local search_dirs = {}
        for _, f_name in ipairs(folder_candidates) do
            if script_dir ~= "" then
                table.insert(search_dirs, script_dir .. "/assets/bundled_fonts/" .. f_name)
                table.insert(search_dirs, script_dir .. "/assets/fonts/" .. f_name)
                table.insert(search_dirs, script_dir .. "/../assets/bundled_fonts/" .. f_name)
                table.insert(search_dirs, script_dir .. "/../assets/fonts/" .. f_name)
            end
            table.insert(search_dirs, "assets/bundled_fonts/" .. f_name)
            table.insert(search_dirs, "assets/fonts/" .. f_name)
            table.insert(search_dirs, "plugins/storefront.koplugin/assets/bundled_fonts/" .. f_name)
            table.insert(search_dirs, "plugins/storefront.koplugin/assets/fonts/" .. f_name)
            if data_dir ~= "" then
                table.insert(search_dirs, data_dir .. "/fonts/" .. f_name)
                table.insert(search_dirs, data_dir .. "/plugins/storefront.koplugin/assets/bundled_fonts/" .. f_name)
                table.insert(search_dirs, data_dir .. "/plugins/storefront.koplugin/assets/fonts/" .. f_name)
                table.insert(search_dirs, data_dir .. "/plugins/storefront.koplugin/storefront.koplugin/assets/bundled_fonts/" .. f_name)
                table.insert(search_dirs, data_dir .. "/plugins/storefront.koplugin/storefront.koplugin/assets/fonts/" .. f_name)
            end
            local ok_mgr, font_mgr = pcall(require, "storefront_font_mgr")
            if ok_mgr and font_mgr and font_mgr.getUserFontDirs then
                local udirs = font_mgr.getUserFontDirs()
                for _, udir in ipairs(udirs) do
                    table.insert(search_dirs, udir .. "/" .. f_name)
                end
            end
        end

        for _, dir_path in ipairs(search_dirs) do
            local rp = (ffiutil and ffiutil.realpath) and ffiutil.realpath(dir_path) or dir_path
            if rp and ok_lfs and lfs and lfs.attributes and lfs.attributes(rp, "mode") == "directory" then
                if font_file ~= "" then
                    local exact_p = rp .. "/" .. font_file
                    if lfs.attributes(exact_p, "mode") == "file" then
                        loaded_font_path = exact_p
                        break
                    end
                    local exact_asset = rp .. "/" .. font_file .. ".asset"
                    if lfs.attributes(exact_asset, "mode") == "file" then
                        loaded_font_path = exact_asset
                        break
                    end
                end

                local fallback_path = nil
                for file in lfs.dir(rp) do
                    if file ~= "." and file ~= ".." and (file:match("%.ttf$") or file:match("%.otf$") or file:match("%.ttf%.asset$") or file:match("%.otf%.asset$")) then
                        local lfile = file:lower()
                        local full_file_p = rp .. "/" .. file
                        if lfile:find("regular") then
                            loaded_font_path = full_file_p
                            break
                        elseif not lfile:find("italic") and not lfile:find("bold") and not lfile:find("oblique") then
                            fallback_path = full_file_p
                        elseif not fallback_path then
                            fallback_path = full_file_p
                        end
                    end
                end

                if loaded_font_path then break end
                if fallback_path then
                    loaded_font_path = fallback_path
                    break
                end
            end
        end

        _font_face_path_cache[font_cache_key] = loaded_font_path or false
    elseif loaded_font_path == false then
        loaded_font_path = nil
    end

    if loaded_font_path then
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(loaded_font_path, "mode") == "file" then
            local ok_fl, FontList = pcall(require, "fontlist")
            if ok_fl and FontList and FontList.getFontList then
                local fl = FontList:getFontList()
                if fl then
                    local found = false
                    for _, p in ipairs(fl) do
                        if p == loaded_font_path then found = true; break end
                    end
                    if not found then
                        table.insert(fl, loaded_font_path)
                    end
                end
            end
            local ok, f = pcall(Font.getFace, Font, loaded_font_path, size)
            if ok and f then face = f end
        end
    end

    if not face and font_file ~= "" then
        for _, f_name in ipairs(folder_candidates) do
            local candidate = data_dir .. "/fonts/" .. f_name .. "/" .. font_file
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(candidate, "mode") == "file" then
                local ok_fl, FontList = pcall(require, "fontlist")
                if ok_fl and FontList and FontList.getFontList then
                    local fl = FontList:getFontList()
                    if fl then
                        local found = false
                        for _, p in ipairs(fl) do
                            if p == candidate then found = true; break end
                        end
                        if not found then
                            table.insert(fl, candidate)
                        end
                    end
                end
                local ok, f = pcall(Font.getFace, Font, candidate, size)
                if ok and f then face = f; break end
            end
        end
    end

    if not face then
        local ok, f = pcall(Font.getFace, Font, "NotoSerif-Regular.ttf", size)
        if ok and f then face = f end
    end

    return face or Font:getFace("cfont", size)
end

local StorefrontListItem = InputContainer:extend{
    align = "left",
    entry = nil,
    width = nil,
    dialog = nil,
}

function StorefrontListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local content_width = self.width or math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
    local text_color = (entry.dim or entry.select_enabled == false) and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    local content_inner = content_width - 2 * Size.padding.default

    local is_clear_button = entry.is_clear_button == true
    local is_control = entry.callback and not entry.is_entry and entry.select_enabled ~= false and not is_clear_button

    if is_clear_button then
        -- Centered pill chip style matching toolbar chips
        
        local btn = Button:new{
            text = entry.text or "",
            text_font_size = 14,
            padding = sc(8),
            padding_left = sc(16),
            padding_right = sc(16),
            radius = sc(16),
            bordersize = sc(1),
            background = Blitbuffer.COLOR_WHITE,
            callback = entry.callback,
            show_parent = self.dialog,
        }
        local chip_h = btn:getSize().h + sc(8)
        self.frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(4),
            bordersize = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = content_width, h = chip_h },
                btn,
            },
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
        -- Wire tap directly to the button callback
        self.ges_events = {}
        self._clear_btn = btn
    elseif is_control then
        -- Control rows (Filter / Sort / Settings links) keep the existing TextBox representation with a frame
        local face = Font:getFace("smallinfofont")
        local text_box = TextBoxWidget:new{
            text = entry.text or "",
            width = content_inner,
            face = face,
            fgcolor = text_color,
            alignment = "left",
            justified = false,
            height_adjust = true,
        }
        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.button,
            radius = Size.radius.button,
            text_box,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    elseif not entry.is_entry then
        -- Info/status/warning rows
        local face = Font:getFace("smallinfofont")
        local text_box = TextBoxWidget:new{
            text = entry.text or "",
            width = content_inner,
            face = face,
            fgcolor = text_color,
            alignment = "left",
            justified = false,
            height_adjust = true,
        }
        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = 0,
            text_box,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    else
        -- Redesigned premium 3-line row layout for plugins/patches
        local name_text = entry.name or entry.text or ""
        local owner_text = entry.owner or ""
        local stars_text = entry.stars_fmt or "0"
        local updated_text = entry.updated or ""
        local desc_text = entry.description or ""
        local badge_text = entry.badge
        local badge_icon = entry.badge_icon

        local badge_w
        local right_reserve = 0
        

        if badge_icon or badge_text then
            local right_widgets = {}

            if badge_text then
                local is_update_btn = (badge_text == _("Update"))
                local is_current_btn = (badge_text == _("✓ Current"))
                local is_installed_badge = (badge_text == _("Installed"))
                local is_solid_inverted = (is_update_btn or is_installed_badge)
                local badge_fg = entry.bFg or (is_solid_inverted and Blitbuffer.COLOR_WHITE or (is_current_btn and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK))
                local badge_bg = entry.bBg or (is_solid_inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)

                local badge_txt_w = TextWidget:new{
                    text = badge_text,
                    face = Font:getFace("smallinfofont", 14),
                    bold = is_solid_inverted,
                    fgcolor = badge_fg,
                }
                local text_chip = FrameContainer:new{
                    padding_top = sc(4),
                    padding_bottom = sc(4),
                    padding_left = sc(8),
                    padding_right = sc(8),
                    bordersize = is_solid_inverted and 0 or sc(1),
                    background = badge_bg,
                    color = Blitbuffer.COLOR_BLACK,
                    radius = is_solid_inverted and sc(10) or sc(4),
                    badge_txt_w,
                }
                table.insert(right_widgets, text_chip)
            end

            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
            local has_icon = false
            if badge_icon then
                if ok_lfs and lfs and lfs.attributes then
                    has_icon = (lfs.attributes(badge_icon, "mode") == "file")
                else
                    has_icon = true
                end
            end

            if badge_icon and has_icon then
                local icon_w = ImageWidget:new{
                    file = badge_icon,
                    width = sc(22),
                    height = sc(22),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                }
                if #right_widgets > 0 then
                    table.insert(right_widgets, HorizontalSpan:new{ width = sc(8) })
                end
                table.insert(right_widgets, icon_w)
            end

            if #right_widgets == 1 then
                badge_w = right_widgets[1]
            else
                badge_w = HorizontalGroup:new(right_widgets)
            end
            right_reserve = badge_w:getSize().w + Size.padding.default
        end

        local thumb_reserve = 0
        if entry.thumbnail_file then
            thumb_reserve = sc(60) + sc(12)
        end
        local text_w = content_inner - right_reserve - thumb_reserve

        -- Line 1: Name
        local is_font_item = (entry.kind == "font" or entry.is_font)
        local name_face = is_font_item and resolveFontItemFace(entry, 22) or Font:getFace("NotoSerif-Regular.ttf", 22)
        local name_w = TextWidget:new{
            text = name_text,
            face = name_face,
            bold = not is_font_item,
            fgcolor = text_color,
            max_width = text_w,
        }

        -- Line 2: Meta Line (owner · ★ stars · 👍 score · updated)
        local meta_face = Font:getFace("cfont", 16)
        local meta_w
        if entry.is_update_item then
            local meta_parts = {}
            if entry.kind_label then table.insert(meta_parts, entry.kind_label) end
            if entry.version_transition then table.insert(meta_parts, entry.version_transition) end
            meta_w = TextWidget:new{
                text = table.concat(meta_parts, "  ·  "),
                face = meta_face,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }
        else
            local meta_items = {}
            local function add_sep()
                if #meta_items > 0 then
                    table.insert(meta_items, TextWidget:new{
                        text = "  ·  ",
                        face = meta_face,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    })
                end
            end

            if owner_text ~= "" then
                add_sep()
                table.insert(meta_items, TextWidget:new{ text = owner_text, face = meta_face, fgcolor = Blitbuffer.COLOR_BLACK })
            end

            if stars_text ~= "" and stars_text ~= "0" then
                add_sep()
                table.insert(meta_items, TextWidget:new{ text = "★ " .. stars_text, face = meta_face, fgcolor = Blitbuffer.COLOR_BLACK })
            end

            local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")
            local current_vote = (ok_ratings and StorefrontRatings) and StorefrontRatings.getUserVote(entry) or nil
            local is_up_active = (current_vote == "up")
            local is_down_active = (current_vote == "down")

            local live_r = (ok_ratings and StorefrontRatings) and StorefrontRatings.getRating(entry, entry) or { up = tonumber(entry.user_thumbs_up) or 0, down = tonumber(entry.user_thumbs_down) or 0 }
            local user_up = live_r.up
            local user_down = live_r.down
            local net_score = user_up - user_down
            if net_score ~= 0 or user_up > 0 or user_down > 0 then
                add_sep()
                
                local icon_file = is_up_active and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg")
                table.insert(meta_items, ImageWidget:new{
                    file = icon_file,
                    width = sc(14),
                    height = sc(14),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                })
                table.insert(meta_items, HorizontalSpan:new{ width = sc(3) })
                local score_fmt = math.abs(net_score) >= 1000 and string.format("%.1fk", net_score / 1000):gsub("%.0k", "k") or tostring(net_score)
                table.insert(meta_items, TextWidget:new{
                    text = score_fmt,
                    face = meta_face,
                    bold = is_up_active or is_down_active,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                })
            end

            if updated_text ~= "" then
                add_sep()
                table.insert(meta_items, TextWidget:new{ text = updated_text, face = meta_face, fgcolor = Blitbuffer.COLOR_BLACK })
            end

            if entry.kind_label then
                add_sep()
                local label_txt = (entry.kind == "font" or entry.is_font) and entry.kind_label:lower() or entry.kind_label
                table.insert(meta_items, TextWidget:new{ text = label_txt, face = meta_face, fgcolor = Blitbuffer.COLOR_BLACK })
            end

            meta_w = HorizontalGroup:new(meta_items)
        end

        local group
        if entry.is_update_item then
            group = VerticalGroup:new{
                align = "left",
                name_w,
                VerticalSpan:new{ width = 2 },
                meta_w,
            }
        else
            local desc_face = Font:getFace("cfont", 14)
            local desc_w = TextWidget:new{
                text = desc_text,
                face = desc_face,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }

            local group_items = { align = "left", name_w }
            if meta_w then
                table.insert(group_items, VerticalSpan:new{ width = 2 })
                table.insert(group_items, meta_w)
            end
            if desc_text ~= "" then
                table.insert(group_items, VerticalSpan:new{ width = 2 })
                table.insert(group_items, desc_w)
            end

            group = VerticalGroup:new(group_items)
        end

        local left_elements = {}
        if entry.thumbnail_file then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
            if ok_lfs and lfs and lfs.attributes and lfs.attributes(entry.thumbnail_file, "mode") == "file" then
                local thumb_w = nil
                local ok_screensavers, StorefrontScreensavers = pcall(require, "storefront_screensavers_ui")
                if ok_screensavers and StorefrontScreensavers and StorefrontScreensavers.createCoverImageWidget then
                    local ok_c, res_c = pcall(function()
                        return StorefrontScreensavers.createCoverImageWidget(entry.thumbnail_file, sc(60), sc(80))
                    end)
                    if ok_c and res_c then
                        thumb_w = res_c
                    end
                end
                if thumb_w then
                    table.insert(left_elements, thumb_w)
                    table.insert(left_elements, HorizontalSpan:new{ width = sc(12) })
                end
            end
        end
        table.insert(left_elements, group)
        local main_content_group = HorizontalGroup:new(left_elements)

        local row_widget
        local item_h = main_content_group:getSize().h
        if badge_w then
            local badge_h = badge_w:getSize().h
            local total_h = math.max(item_h, badge_h)
            row_widget = OverlapGroup:new{
                dimen = Geom:new{ w = content_inner, h = total_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    main_content_group,
                },
                RightContainer:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    badge_w,
                }
            }
        else
            row_widget = LeftContainer:new{
                dimen = Geom:new{ w = content_inner, h = item_h },
                main_content_group,
            }
        end

        self.frame = FrameContainer:new{
            padding = Size.padding.default,
            bordersize = 0,
            row_widget,
        }
        self[1] = self.frame
        self.dimen = self.frame:getSize()
    end

    if entry.callback or entry.hold_callback then
        local tap_range = function()
            return Geom:new{
                x = self.dimen.x,
                y = self.dimen.y,
                w = self.dimen.w,
                h = self.dimen.h,
            }
        end
        self.ges_events = {
            StorefrontTap = {
                GestureRange:new{
                    ges = "tap",
                    range = tap_range,
                },
            },
        }
        if entry.hold_callback then
            self.ges_events.StorefrontHold = {
                GestureRange:new{
                    ges = "hold",
                    range = tap_range,
                },
            }
        end
    end
end

function StorefrontListItem:onStorefrontTap(arg, ges)
    if self.entry and self.entry.on_badge_tap and ges and ges.pos then
        
        local right_edge = (self.dimen and self.dimen.x or 0) + (self.dimen and self.dimen.w or 0)
        local badge_width = sc(70)
        if ges.pos.x >= (right_edge - badge_width) then
            self.entry.on_badge_tap()
            return true
        end
    end
    if self.entry and self.entry.callback then
        self.entry.callback()
    elseif self.dialog and self.dialog.onEntryActivated then
        self.dialog:onEntryActivated(self.entry)
    end
    return true
end

function StorefrontListItem:onStorefrontHold()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

function StorefrontListItem:isFocusable()
    if not self.entry then
        return false
    end
    if self.entry.select_enabled == false then
        return false
    end
    return self.entry.callback ~= nil or self.entry.hold_callback ~= nil
end

function StorefrontListItem:onFocus()
    if not self.frame then
        return true
    end
    self.frame.invert = true
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

function StorefrontListItem:onUnfocus()
    if not self.frame then
        return true
    end
    self.frame.invert = false
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

function StorefrontListItem:onTapSelect()
    if self.entry and self.entry.callback then
        self.entry.callback()
    elseif self.dialog and self.dialog.onEntryActivated then
        self.dialog:onEntryActivated(self.entry)
    end
    return true
end

function StorefrontListItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

StorefrontListItem.resolveFontItemFace = resolveFontItemFace

return StorefrontListItem
