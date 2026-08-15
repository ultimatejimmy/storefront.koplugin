local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local StorefrontScreensavers = {}

local DEFAULT_SCREENSAVER_CATALOG_URL = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.json"

local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

local function requestWithRedirects(target_url, sink_fn)
    local ltn12 = require("ltn12")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local is_https = current_url:match("^https://") ~= nil
        local http_req = getHttpModule(current_url)
        local headers = {
            ["User-Agent"] = "KOReader-Storefront",
        }

        local sink = sink_fn()
        if not sink then return false, 0, nil end

        local params = {
            url = current_url,
            method = "GET",
            headers = headers,
            sink = sink,
        }
        if not is_https then params.redirect = true end

        local ok_req, res_code, response_headers = pcall(function()
            local _, c, h = http_req.request(params)
            return c, h
        end)

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            return true, 200, response_headers
        elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            local loc = response_headers and (response_headers.location or response_headers.Location)
            if loc and loc ~= "" then
                current_url = loc
                redirect_count = redirect_count + 1
            else
                break
            end
        else
            break
        end
    end
    return false, 0, nil
end

function StorefrontScreensavers.fetchCatalog(callback)
    local ltn12 = require("ltn12")
    local response_body = {}
    local sink_fn = function()
        response_body = {}
        return ltn12.sink.table(response_body)
    end

    local ok, code = requestWithRedirects(DEFAULT_SCREENSAVER_CATALOG_URL, sink_fn)
    if ok and code == 200 then
        local body_str = table.concat(response_body)
        local parsed_ok, data = pcall(json.decode, body_str)
        if parsed_ok and type(data) == "table" then
            callback(true, data)
            return
        end
    end

    -- Fallback dummy data if offline / initial test
    local fallback = {
        {
            id = "foggy-forest-pines",
            title = "Foggy Mountain Pines",
            author = "Unsplash (CC0)",
            category = "Nature",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/foggy-forest-pines.jpg",
        },
        {
            id = "minimalist-ocean-waves",
            title = "Minimalist Ocean Horizon",
            author = "Unsplash (CC0)",
            category = "Minimalist",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/minimalist-ocean-waves.jpg",
        },
        {
            id = "cosmic-nebula-monochrome",
            title = "Deep Space Nebula",
            author = "Unsplash (CC0)",
            category = "Sci-Fi",
            fullUrl = "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/images/cosmic-nebula-monochrome.jpg",
        },
    }
    callback(false, fallback)
end

function StorefrontScreensavers.fetchThumbnail(item, callback)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local lfs = require("libs/libkoreader-lfs")
    if lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        lfs.mkdir(cache_dir)
    end

    local thumb_path = cache_dir .. "/" .. item.id .. ".jpg"
    if lfs and lfs.attributes and lfs.attributes(thumb_path, "mode") == "file" then
        if callback then callback(thumb_path) end
        return thumb_path
    end

    if not item.thumbnailUrl or item._thumb_failed then return nil end

    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = requestWithRedirects(item.thumbnailUrl, sink_fn)
    if ok and code == 200 then
        local file = io.open(thumb_path, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()
            if callback then callback(thumb_path) end
            return thumb_path
        end
    end

    item._thumb_failed = true
    return nil
end

function StorefrontScreensavers.downloadAndSetScreensaver(item, callback)
    local info_dialog = InfoMessage:new{
        text = _("Downloading screensaver...") .. "\n" .. (item.title or item.name or ""),
        timeout = 2,
    }
    UIManager:show(info_dialog)

    local target_url = item.fullUrl or item.thumbnailUrl
    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = requestWithRedirects(target_url, sink_fn)
    if info_dialog and info_dialog.onClose then info_dialog:onClose() end

    if ok and code == 200 then
        local screensaver_dir = DataStorage:getDataDir() .. "/screensavers"
        local lfs = require("libs/libkoreader-lfs")
        if lfs and lfs.attributes and not lfs.attributes(screensaver_dir) then
            lfs.mkdir(screensaver_dir)
        end

        local filename = screensaver_dir .. "/" .. item.id .. ".jpg"
        local file = io.open(filename, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()

            UIManager:show(ConfirmBox:new{
                text = _("Screensaver downloaded successfully!\nSaved to: %s\n\nSet as active KOReader screensaver?", item.id .. ".jpg"),
                ok_text = _("Set Active"),
                cancel_text = _("Close"),
                callback = function()
                    local G_reader_settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
                    G_reader_settings:saveSetting("screensaver_type", "image")
                    G_reader_settings:saveSetting("screensaver_mode", "single")
                    G_reader_settings:saveSetting("screensaver_file", filename)
                    G_reader_settings:saveSetting("screensaver_image", filename)
                    G_reader_settings:flush()

                    UIManager:show(InfoMessage:new{
                        text = _("Screensaver updated successfully!"),
                        timeout = 3,
                    })
                end
            })
            if callback then callback(true) end
            return
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Failed to download screensaver."),
        timeout = 3,
    })
    if callback then callback(false) end
end

function StorefrontScreensavers.showDetails(item, parent_storefront)
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local ImageWidget = require("ui/widget/imagewidget")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Blitbuffer = require("ffi/blitbuffer")

    local sc = function(val) return Device.screen:scaleBySize(val) end

    local thumb_file = StorefrontScreensavers.fetchThumbnail(item)

    local meta_txt = TextWidget:new{
        text = string.format("%s  ·  %s", item.author or "Community", item.category or "General"),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local preview_widget
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    if thumb_file and ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_file, "mode") == "file" then
        preview_widget = ImageWidget:new{
            file = thumb_file,
            width = sc(180),
            height = sc(240),
            scale_factor = 0,
        }
    else
        preview_widget = TextWidget:new{
            text = "[ Wallpaper Preview Loading... ]",
            face = Font:getFace("cfont", 16),
        }
    end

    local dialog
    dialog = ButtonDialog:new{
        title = item.title or item.name or _("Screensaver Details"),
        widgets = {
            CenterContainer:new{
                dimen = require("ui/geometry"):new{ w = sc(280), h = sc(300) },
                VerticalGroup:new{
                    align = "center",
                    meta_txt,
                    VerticalSpan:new{ width = sc(8) },
                    preview_widget,
                }
            }
        },
        buttons = {
            {
                {
                    text = _("Download & Set Active"),
                    is_primary = true,
                    callback = function()
                        UIManager:close(dialog)
                        StorefrontScreensavers.downloadAndSetScreensaver(item)
                    end,
                },
            },
            {
                {
                    text = _("Rate Wallpaper"),
                    callback = function()
                        if parent_storefront and parent_storefront.showRatingDialog then
                            parent_storefront:showRatingDialog(item)
                        end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function StorefrontScreensavers.createCoverImageWidget(file_path, target_w, target_h)
    local ImageWidget = require("ui/widget/imagewidget")
    local RenderImage = require("ui/renderimage")
    local Blitbuffer  = require("ffi/blitbuffer")

    if not file_path or not target_w or not target_h then return nil end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)

    if not ok or not orig_bb then
        return nil
    end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()

    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then orig_bb:free() end
        return nil
    end

    local scale = math.max(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.max(1, math.ceil(orig_w * scale))
    local scaled_h = math.max(1, math.ceil(orig_h * scale))

    local scaled_bb = RenderImage:scaleBlitBuffer(orig_bb, scaled_w, scaled_h, true)
    if not scaled_bb then return nil end

    local final_w = scaled_bb:getWidth()
    local final_h = scaled_bb:getHeight()

    if final_w == target_w and final_h == target_h then
        return ImageWidget:new{
            image = scaled_bb,
            image_disposable = true,
            width = target_w,
            height = target_h,
        }
    end

    local crop_x = math.max(0, math.floor((final_w - target_w) / 2))
    local crop_y = math.max(0, math.floor((final_h - target_h) / 2))

    local cropped_bb = Blitbuffer.new(target_w, target_h, scaled_bb:getType())
    cropped_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)

    if scaled_bb.free then
        scaled_bb:free()
    end

    return ImageWidget:new{
        image = cropped_bb,
        image_disposable = true,
        width = target_w,
        height = target_h,
    }
end

return StorefrontScreensavers
