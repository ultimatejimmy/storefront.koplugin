--- StorefrontScreensaverDetail
--- Full-screen detail view for a single screensaver entry.
--- Layout mirrors StorefrontDetailsDialog: back button, bold title,
--- meta line (author · category · 👍/👎 rating widgets), description,
--- action buttons, a horizontal rule, and a large portrait image preview below.

local Blitbuffer   = require("ffi/blitbuffer")
local Button       = require("ui/widget/button")
local Device       = require("device")
local Font         = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local RightContainer   = require("ui/widget/container/rightcontainer")
local Geom         = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local ImageWidget  = require("ui/widget/imagewidget")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LineWidget   = require("ui/widget/linewidget")
local Size         = require("ui/size")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local TextWidget   = require("ui/widget/textwidget")
local UIManager    = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local OverlapGroup     = require("ui/widget/overlapgroup")
local DataStorage  = require("datastorage")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local function getAssetPath(filename)
    local info = debug.getinfo(1, "S")
    local dir  = info.source:match("^@(.*[/\\])") or ""
    return dir .. "assets/" .. filename
end

local StorefrontScreensaverDetail = InputContainer:extend{
    covers_fullscreen = true,
    item   = nil,   -- screensaver catalog entry table
    parent = nil,   -- Storefront main object (for showRatingDialog)
}

function StorefrontScreensaverDetail:init()
    local sc = function(val) return Device.screen:scaleBySize(val) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end

    local item = self.item or {}

    -- -----------------------------------------------------------------------
    -- 1. Back button
    -- -----------------------------------------------------------------------
    local back_btn = Button:new{
        text       = _("< Back"),
        text_font_size = 20,
        bordersize = 0,
        background = nil,
        show_parent = self,
        callback   = function() self:onClose() end,
    }

    -- -----------------------------------------------------------------------
    -- 2. Title
    -- -----------------------------------------------------------------------
    local title_label = TextWidget:new{
        text   = item.title or item.name or _("Screensaver"),
        face   = Font:getFace("NotoSerif-Regular.ttf", 28) or Font:getFace("cfont", 28),
        bold   = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- -----------------------------------------------------------------------
    -- 3. Meta line: author · category · 👍 score 👎
    -- -----------------------------------------------------------------------
    local meta_face = Font:getFace("cfont", 16)
    local meta_items = {}

    local function add_sep()
        if #meta_items > 0 then
            table.insert(meta_items, TextWidget:new{
                text    = "  ·  ",
                face    = meta_face,
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        end
    end

    if item.author and item.author ~= "" then
        table.insert(meta_items, TextWidget:new{
            text    = item.author,
            face    = meta_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    end

    if item.category and item.category ~= "" then
        add_sep()
        table.insert(meta_items, TextWidget:new{
            text    = item.category,
            face    = meta_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    end

    -- Inline rating widgets (mirrors details dialog)
    local ok_ratings, StorefrontRatings = pcall(require, "storefront_ratings")
    local up_btn_ref, down_btn_ref, score_frame_ref

    if ok_ratings and StorefrontRatings then
        local current_vote = StorefrontRatings.getUserVote(item)
        local is_up_active   = (current_vote == "up")
        local is_down_active = (current_vote == "down")
        local live_r = StorefrontRatings.getRating(item)
        local net_score = live_r.up - live_r.down

        local up_img_frame = FrameContainer:new{
            bordersize = 0, padding = 0,
            ImageWidget:new{
                file       = is_up_active and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg"),
                width      = sc(16), height = sc(16),
                scale_factor = 0, is_icon = true, alpha = true,
            },
        }
        local down_img_frame = FrameContainer:new{
            bordersize = 0, padding = 0,
            ImageWidget:new{
                file       = is_down_active and getAssetPath("thumbs-down-filled.svg") or getAssetPath("thumbs-down.svg"),
                width      = sc(16), height = sc(16),
                scale_factor = 0, is_icon = true, alpha = true,
            },
        }
        score_frame_ref = FrameContainer:new{
            bordersize = 0, padding = 0,
            TextWidget:new{
                text    = tostring(net_score),
                face    = Font:getFace("cfont", 14),
                bold    = is_up_active or is_down_active,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
        up_btn_ref   = up_img_frame
        down_btn_ref = down_img_frame

        local self_ref = self

        local function refresh_rating()
            self_ref._vote_toggled = true
            current_vote   = StorefrontRatings.getUserVote(item)
            local nu_a = (current_vote == "up")
            local nd_a = (current_vote == "down")
            local nr   = StorefrontRatings.getRating(item)
            local ns   = nr.up - nr.down

            if up_img_frame[1] and up_img_frame[1].free then up_img_frame[1]:free() end
            up_img_frame[1] = ImageWidget:new{
                file = nu_a and getAssetPath("thumbs-up-filled.svg") or getAssetPath("thumbs-up.svg"),
                width = sc(16), height = sc(16), scale_factor = 0, is_icon = true, alpha = true,
            }
            if down_img_frame[1] and down_img_frame[1].free then down_img_frame[1]:free() end
            down_img_frame[1] = ImageWidget:new{
                file = nd_a and getAssetPath("thumbs-down-filled.svg") or getAssetPath("thumbs-down.svg"),
                width = sc(16), height = sc(16), scale_factor = 0, is_icon = true, alpha = true,
            }
            if score_frame_ref[1] and score_frame_ref[1].free then score_frame_ref[1]:free() end
            score_frame_ref[1] = TextWidget:new{
                text = tostring(ns), face = Font:getFace("cfont", 14),
                bold = nu_a or nd_a, fgcolor = Blitbuffer.COLOR_BLACK,
            }
            UIManager:setDirty(self_ref, "ui")
        end

        local up_ic = InputContainer:new{ up_img_frame }
        up_ic.ges_events = { SfssUpTap = { GestureRange:new{ ges = "tap", range = function()
            local d = up_ic.dimen or up_img_frame:getSize()
            return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
        end } } }
        function up_ic:onSfssUpTap()
            current_vote = StorefrontRatings.getUserVote(item)
            StorefrontRatings.submitVote(item, current_vote == "up" and "none" or "up", "screensaver")
            refresh_rating()
            return true
        end

        local down_ic = InputContainer:new{ down_img_frame }
        down_ic.ges_events = { SfssDownTap = { GestureRange:new{ ges = "tap", range = function()
            local d = down_ic.dimen or down_img_frame:getSize()
            return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
        end } } }
        function down_ic:onSfssDownTap()
            current_vote = StorefrontRatings.getUserVote(item)
            StorefrontRatings.submitVote(item, current_vote == "down" and "none" or "down", "screensaver")
            refresh_rating()
            return true
        end

        add_sep()
        table.insert(meta_items, up_ic)
        table.insert(meta_items, HorizontalSpan:new{ width = sc(3) })
        table.insert(meta_items, score_frame_ref)
        table.insert(meta_items, HorizontalSpan:new{ width = sc(3) })
        table.insert(meta_items, down_ic)
    end
    local meta_label = HorizontalGroup:new(meta_items)

    -- -----------------------------------------------------------------------
    -- 4. Description (optional freeform text only)
    -- -----------------------------------------------------------------------
    local desc_text = item.description or ""
    local desc_label = (desc_text ~= "") and TextBoxWidget:new{
        text   = desc_text,
        face   = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width  = sw - sc(24),
        height_adjust = true,
    } or nil

    -- -----------------------------------------------------------------------
    -- 5. Action buttons (mirrors details dialog proportional layout)
    -- -----------------------------------------------------------------------
    local btn_area_w = sw - sc(24)
    local btn_h      = sc(44)
    local btn_gap    = sc(8)

    local StorefrontScreensaversUI = require("storefront_screensavers_ui")

    local primary_btn = Button:new{
        text           = _("Download & Set Active"),
        text_font_size = 18,
        text_font_color = Blitbuffer.COLOR_WHITE,
        background     = Blitbuffer.COLOR_BLACK,
        bordersize     = 0,
        padding        = 0,
        radius         = sc(4),
        width          = math.floor(btn_area_w * 0.55),
        height         = btn_h,
        show_parent    = self,
        callback       = function()
            self:onClose()
            StorefrontScreensaversUI.downloadAndSetScreensaver(item)
        end,
    }
    if primary_btn.label_widget then
        primary_btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    local share_btn = Button:new{
        text           = _("Community"),
        text_font_size = 16,
        bordersize     = sc(1),
        padding        = 0,
        radius         = sc(4),
        width          = math.floor(btn_area_w * 0.42) - btn_gap,
        height         = btn_h,
        show_parent    = self,
        callback       = function()
            local ok_ui, InfoMessage = pcall(require, "ui/widget/infomessage")
            if ok_ui then
                UIManager:show(InfoMessage:new{
                    text = _("Submit your own wallpapers at:\nhttps://ultimatejimmy.github.io/storefront-screensavers"),
                    timeout = 5,
                })
            end
        end,
    }

    local action_row = HorizontalGroup:new{
        primary_btn,
        HorizontalSpan:new{ width = btn_gap },
        share_btn,
    }

    -- -----------------------------------------------------------------------
    -- 6. Divider
    -- -----------------------------------------------------------------------
    local divider = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen      = Geom:new{ w = sw - sc(24), h = Size.line.thin },
    }

    -- -----------------------------------------------------------------------
    -- 7. Portrait image preview centred below the divider
    -- -----------------------------------------------------------------------
    local thumb_file = StorefrontScreensaversUI.fetchThumbnail(item)

    -- Measure remaining vertical space
    local header_h = back_btn:getSize().h
                   + sc(8)
                   + title_label:getSize().h
                   + sc(4)
                   + meta_label:getSize().h
                   + (desc_label and (sc(12) + desc_label:getSize().h) or 0)
                   + sc(16)
                   + btn_h
                   + sc(16)
                   + Size.line.thin
                   + sc(16)
    local frame_padding = sc(12) * 2
    local avail_h = sh - frame_padding - header_h
    if avail_h < sc(60) then avail_h = sc(60) end

    -- Portrait aspect ~3:4 (e-reader screen)
    local img_h = math.min(avail_h - sc(8), sc(320))
    local img_w = math.floor(img_h * 3 / 4)

    local preview_widget
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    if thumb_file and ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_file, "mode") == "file" then
        preview_widget = StorefrontScreensaversUI.createCoverImageWidget(thumb_file, img_w, img_h)
        if not preview_widget then
            preview_widget = ImageWidget:new{
                file         = thumb_file,
                width        = img_w,
                height       = img_h,
                scale_factor = 0,
            }
        end
    else
        preview_widget = TextWidget:new{
            text    = _("[ Loading preview... ]"),
            face    = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end

    local image_container = CenterContainer:new{
        dimen  = Geom:new{ w = sw - sc(24), h = img_h },
        preview_widget,
    }

    -- Tap the image to open a full-screen image modal
    local ok_modal, StorefrontImageModal = pcall(require, "storefront_image_modal")
    if ok_modal and StorefrontImageModal and thumb_file then
        local tap_wrapper = InputContainer:new{ image_container }
        tap_wrapper.ges_events = {
            SfssImgTap = {
                GestureRange:new{
                    ges   = "tap",
                    range = function()
                        local d = tap_wrapper.dimen or image_container:getSize()
                        return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or 0, h = d.h or 0 }
                    end,
                },
            },
        }
        function tap_wrapper:onSfssImgTap()
            local modal = StorefrontImageModal:new{
                image_path = thumb_file,
                title      = item.title or item.name or _("Screensaver"),
            }
            modal:show()
            return true
        end
        image_container = tap_wrapper
    end

    -- -----------------------------------------------------------------------
    -- 8. Assemble full-screen layout (mirrors details dialog)
    -- -----------------------------------------------------------------------
    local content_items = {
        align = "left",
        back_btn,
        VerticalSpan:new{ width = sc(8) },
        title_label,
        VerticalSpan:new{ width = sc(4) },
        meta_label,
        VerticalSpan:new{ width = sc(16) },
        action_row,
        VerticalSpan:new{ width = sc(16) },
        divider,
        VerticalSpan:new{ width = sc(16) },
        image_container,
    }
    if desc_label then
        table.insert(content_items, 5, VerticalSpan:new{ width = sc(8) })
        table.insert(content_items, 6, desc_label)
    end
    local content_group = VerticalGroup:new(content_items)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = sc(12),
        width      = sw,
        height     = sh,
        content_group,
    }
end

function StorefrontScreensaverDetail:onClose()
    self.is_closed = true
    UIManager:close(self)
    if self._vote_toggled and self.parent and type(self.parent.reopenBrowser) == "function" then
        self.parent:reopenBrowser()
    else
        UIManager:setDirty(nil, "full")
    end
end

function StorefrontScreensaverDetail:onSwipe(arg, ges)
    if ges and ges.direction == "east" then
        self:onClose()
        return true
    end
end

function StorefrontScreensaverDetail:show()
    UIManager:show(self)
end

return StorefrontScreensaverDetail
