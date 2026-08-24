local DataStorage = require("datastorage")
local ok_ui, UIManager = pcall(require, "ui/uimanager")
local ok_toast, InfoMessage = pcall(require, "storefront_toast")
if not ok_toast then InfoMessage = { show = function() end } end
local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
local _ = require("gettext")
local http = require("socket.http")
local ok_https, https = pcall(require, "ssl.https")
if not ok_https then https = http end
local ltn12 = require("ltn12")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local GitHubClient = require("storefront_net_github")
local ok_json, json = pcall(require, "json")
local json_null = (ok_json and json and json.null) or nil

local function safeString(val)
    if type(val) == "string" and val ~= json_null then
        return val
    end
    return nil
end

local RepoContent = {}
RepoContent.pending_images = {}
RepoContent.cumulative_uncompressed_bytes = 0
local MAX_PAGE_PAYLOAD_BYTES = 12582912 -- 12 MB cumulative limit per page
local MAX_UNCOMPRESSED_PAYLOAD = 50331648 -- 48 MB max uncompressed RAM

local function countCJKCharacters(text)
    if not text or type(text) ~= "string" then return 0 end
    local count = 0
    for _ in text:gmatch("[\xE3-\xE9\xEC-\xED][\x80-\xBF][\x80-\xBF]") do
        count = count + 1
    end
    return count
end

local function stripImgDimensions(str)
    if not str or type(str) ~= "string" then return str end
    str = str:gsub("%s+width=[\"'][^\"']*[\"']", "")
    str = str:gsub("%s+width=%d+%%?", "")
    str = str:gsub("%s+height=[\"'][^\"']*[\"']", "")
    str = str:gsub("%s+height=%d+%%?", "")
    str = str:gsub("(style=[\"'][^\"']*)width:%s*[^;\"]+;?", "%1")
    str = str:gsub("(style=[\"'][^\"']*)height:%s*[^;\"]+;?", "%1")
    str = str:gsub("(style=[\"'][^\"']*)max%-width:%s*[^;\"]+;?", "%1")
    str = str:gsub("(style=[\"'][^\"']*)max%-height:%s*[^;\"]+;?", "%1")
    return str
end

local function getImageDimensions(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local header = f:read(24)
    if not header or #header < 24 then pcall(function() f:close() end) return nil, nil end
    
    if header:sub(1, 8) == "\137\80\78\71\13\10\26\10" then
        local w = header:byte(17)*16777216 + header:byte(18)*65536 + header:byte(19)*256 + header:byte(20)
        local h = header:byte(21)*16777216 + header:byte(22)*65536 + header:byte(23)*256 + header:byte(24)
        pcall(function() f:close() end)
        return w, h
    end
    
    if header:sub(1, 3) == "GIF" then
        local w = header:byte(8)*256 + header:byte(7)
        local h = header:byte(10)*256 + header:byte(9)
        pcall(function() f:close() end)
        return w, h
    end
    
    if header:sub(1, 2) == "\255\216" then
        f:seek("set", 2)
        local attempts = 0
        while attempts < 50 do
            attempts = attempts + 1
            local marker = f:read(2)
            if not marker or #marker < 2 or marker:byte(1) ~= 255 then break end
            local m = marker:byte(2)
            if m == 217 or m == 218 then break end
            local len_str = f:read(2)
            if not len_str or #len_str < 2 then break end
            local len = len_str:byte(1) * 256 + len_str:byte(2)
            
            if m >= 192 and m <= 207 and m ~= 196 and m ~= 200 and m ~= 204 then
                local info = f:read(5)
                if info and #info == 5 then
                    local h = info:byte(2) * 256 + info:byte(3)
                    local w = info:byte(4) * 256 + info:byte(5)
                    pcall(function() f:close() end)
                    return w, h
                end
            end
            f:seek("cur", len - 2)
        end
    end
    
    pcall(function() f:close() end)
    return nil, nil
end

local function isImageSafeForMemory(path, size_bytes)
    local w, h = getImageDimensions(path)
    if w and h then
        -- Max 24MB uncompressed RAM per image
        local uncompressed = w * h * 4
        return (uncompressed <= 24000000), uncompressed
    end
    local uncompressed_guess = size_bytes * 4
    return (size_bytes <= 3145728), uncompressed_guess -- Fallback guess (3 MB)
end

local downloadImage

function RepoContent.resetPayloadTracker()
    RepoContent.cumulative_page_bytes = 0
    RepoContent.cumulative_uncompressed_bytes = 0
    RepoContent.pending_images = {}
end

function RepoContent.processPendingImages(on_update_cb)
    if not RepoContent.pending_images or #RepoContent.pending_images == 0 then
        return
    end

    if RepoContent.cumulative_page_bytes >= MAX_PAGE_PAYLOAD_BYTES then
        logger.info("Storefront: 12MB cumulative image payload threshold reached.")
        RepoContent.pending_images = {}
        return
    end

    -- Strategy: download ALL pending images one-per-tick first, then rebuild the HTML
    -- ONCE with real img tags at the end. This avoids MuPDF squishing images:
    -- when a tiny placeholder gets swapped for a large image after layout is already
    -- fixed, MuPDF scales the image down to fit the remaining space on that page.
    -- By rebuilding only after all downloads are done, MuPDF gets a single fresh
    -- layout pass with real image dimensions and can flow them correctly across pages.

    local task = table.remove(RepoContent.pending_images, 1)

    if task and task.url and task.dest then
        if lfs.attributes(task.dest, "mode") ~= "file" and type(downloadImage) == "function" then
            local pcall_ok, dl_ok, final_dest = pcall(downloadImage, task.url, task.dest)
            local actual_dest = (dl_ok and type(final_dest) == "string") and final_dest or task.dest
            local sz = lfs.attributes(actual_dest, "size") or 0
            if pcall_ok and dl_ok and sz > 0 then
                RepoContent.cumulative_page_bytes = RepoContent.cumulative_page_bytes + sz
                local is_safe, uncompressed = isImageSafeForMemory(actual_dest, sz)
                if uncompressed then
                    RepoContent.cumulative_uncompressed_bytes = RepoContent.cumulative_uncompressed_bytes + uncompressed
                end
            end
        end
    end

    -- More images to download? Schedule next tick.
    if RepoContent.pending_images and #RepoContent.pending_images > 0 and RepoContent.cumulative_page_bytes < MAX_PAGE_PAYLOAD_BYTES then
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.4, function()
            RepoContent.processPendingImages(on_update_cb)
        end)
        return
    end

    -- All downloads done. Rebuild the HTML once with real img tags.
    local html_path = task and task.html_path
    if not html_path then return end

    local html_content = util.readFromFile(html_path)
    if not html_content then return end

    html_content = html_content:gsub('(<span[^>]*id="imgbox%-[^"]+"[^>]*>)(.-)(</span>)', function(span_tag, inner, closetag)
        local img_path = span_tag:match('id="imgbox%-([^"]+)"')
        if not img_path then return span_tag .. inner .. closetag end
        
        local sz = lfs.attributes(img_path, "size") or 0
        if sz == 0 then
            return '<span style="display: block; text-align: center; margin: 0.6em auto; color: red; font-style: italic;">[ Image Failed ]</span>'
        end
        local is_gif = img_path:lower():match("%.gif$") ~= nil
        if is_gif then
            return string.format('<a href="storefront-img:%s" style="display: block; text-align: center; margin: 0.6em auto; color: blue; text-decoration: underline;">[ View Animated GIF ]</a>', img_path)
        end
        local is_safe, uncompressed = isImageSafeForMemory(img_path, sz)
        if not is_safe or (uncompressed and (RepoContent.cumulative_uncompressed_bytes + uncompressed) > MAX_UNCOMPRESSED_PAYLOAD) then
            return string.format('<a href="storefront-img:%s" style="display: block; text-align: center; margin: 0.6em auto; color: blue; text-decoration: underline;">[ View Large Image ]</a>', img_path)
        end
        local filename = img_path:match("([^/]+)$") or ""
        return string.format('<br/><a href="storefront-img:%s" style="display: block; text-align: center; margin: 1.5em auto;"><img src="%s" style="max-width: 100%%; height: auto; display: block; margin: 0 auto;" /></a>', img_path, filename)
    end)

    util.writeToFile(html_content, html_path)

    if on_update_cb then
        pcall(on_update_cb, html_path)
    end
end


local function getCacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/Storefront/readme"
    local ok, err = util.makePath(dir)
    if not ok then
        logger.warn("Storefront README cache dir failure", err)
    end
    return dir
end

local function buildRawUrl(owner, repo)
    return string.format("https://raw.githubusercontent.com/%s/%s/HEAD/README.md", owner, repo)
end

local function download(url)
    local response = {}
    local req_mod = url:match("^https:") and https or http
    local _, code = req_mod.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = {
            ["Accept"] = "text/plain",
            ["User-Agent"] = "KOReader-Storefront",
        },
    }
    return tonumber(code), table.concat(response)
end

-- Maps a Content-Type to the file extension MuPDF's image decoders expect.
-- Needed because plenty of image URLs carry no usable extension of their own
-- (e.g. camo.githubusercontent.com's proxy hashes), and the URL's apparent
-- extension can't be trusted anyway (e.g. a shields.io badge proxied through
-- camo keeps whatever extension we guessed even though camo actually served
-- SVG).
local CONTENT_TYPE_EXT = {
    ["image/png"] = "png",
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/bmp"] = "bmp",
}

-- Downloads `url` to `dest`. Returns `ok, final_path`: `final_path` may
-- differ from `dest` when the server's Content-Type reveals a different
-- (correct) extension than the one we guessed from the URL. Images that
-- turn out to be SVG (MuPDF's HTML box can't render them, whatever the
-- extension) are rejected -- this is the only reliable way to catch SVGs
-- served through camo, whose proxy URLs never contain ".svg".
local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

downloadImage = function(url, dest, max_redirects)
    max_redirects = max_redirects or 5
    if max_redirects <= 0 then return false end
    dest = dest:gsub("\\", "/")

    -- Clean HTML tags from URL if any got through
    url = url:gsub("<[^>]+>", "")

    -- Immediately reject badge / shield / SVG URLs before network requests
    local lower_url = url:lower()
    if lower_url:find("%.svg") or lower_url:find("shields%.io") or lower_url:find("badge") or lower_url:find("liberapay") or lower_url:find("github%-actions") or lower_url:find("travis%-ci") or lower_url:find("codecov") then
        return false
    end

    -- Do not attempt to download directory paths like .../wiki/img or .../img
    local clean_check = lower_url:gsub("%?.*$", "")
    if clean_check:match("/img$") or clean_check:match("/images$") or clean_check:match("/wiki$") then
        return false
    end

    local urls_to_try = {}
    local w_owner, w_repo, w_path = url:match("^https?://raw%.githubusercontent%.com/wiki/([^/]+)/([^/]+)/(.+)$")
    if not w_owner then w_owner, w_repo, w_path = url:match("^https?://github%.com/([^/]+)/([^/]+)/wiki/(.+)$") end

    if w_owner and w_repo and w_path then
        table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", w_owner, w_repo, w_path))
        table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/%s/%s/master/%s", w_owner, w_repo, w_path))
        table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/%s/%s/main/%s", w_owner, w_repo, w_path))
        table.insert(urls_to_try, string.format("https://github.com/%s/%s/raw/master/%s", w_owner, w_repo, w_path))
        table.insert(urls_to_try, string.format("https://github.com/%s/%s/raw/main/%s", w_owner, w_repo, w_path))
        table.insert(urls_to_try, string.format("https://github.com/%s/%s/wiki/%s", w_owner, w_repo, w_path))
    else
        local r_owner, r_repo, r_branch, r_path = url:match("^https?://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
        if not r_owner then r_owner, r_repo, r_branch, r_path = url:match("^https?://github%.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$") end
        if not r_owner then r_owner, r_repo, r_branch, r_path = url:match("^https?://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$") end

        if r_owner and r_repo and r_branch and r_path then
            table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", r_owner, r_repo, r_branch, r_path))
            table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/%s/%s/master/%s", r_owner, r_repo, r_path))
            table.insert(urls_to_try, string.format("https://raw.githubusercontent.com/%s/%s/main/%s", r_owner, r_repo, r_path))
        end
    end
    table.insert(urls_to_try, url)

    for _, current_url in ipairs(urls_to_try) do
        local f, err = io.open(dest, "wb")
        if f then
            pcall(function() http.TIMEOUT = 4 end)
            local start_time = os.time()
            local downloaded_size = 0
            local file_sink = function(chunk, err_sink)
                if chunk then
                    downloaded_size = downloaded_size + #chunk
                    if downloaded_size > 4718592 or (os.time() - start_time) > 12 then
                        return nil, "abort"
                    end
                    local ok, w_err = f:write(chunk)
                    if not ok then return nil, w_err end
                    return 1
                end
                return 1, err_sink
            end
            local res, code, headers
            pcall(function()
                local req_mod = current_url:match("^https:") and https or http
                res, code, headers = req_mod.request{
                    url = current_url,
                    sink = file_sink,
                    headers = {
                        ["User-Agent"] = USER_AGENT,
                        ["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                    },
                    redirect = false,
                    timeout = 4,
                }
            end)
            pcall(function() file_sink(nil) end)
            pcall(function() f:close() end)

            if not res and downloaded_size > 0 then
                os.remove(dest)
                return false
            end

            code = tonumber(code)
            logger.info("Storefront image download:", current_url, "code=", code)

            if code == 200 then
                local sz = lfs.attributes(dest, "size") or 0
                if sz > 4194304 then
                    logger.warn("Storefront: image exceeds 4MB safety cap, removing to protect device memory:", current_url, sz)
                    os.remove(dest)
                else
                    local content_type = (headers and (headers["content-type"] or headers["Content-Type"]) or ""):lower()
                    if content_type:find("svg", 1, true) or content_type:find("html", 1, true) or content_type:find("text", 1, true) or content_type:find("json", 1, true) then
                        os.remove(dest)
                    else
                        local w_check, h_check = getImageDimensions(dest)
                        if not w_check or not h_check or w_check == 0 or h_check == 0 then
                            logger.warn("Storefront: downloaded file is not a valid image format:", current_url)
                            os.remove(dest)
                        else
                            return true, dest:gsub("\\", "/")
                        end
                    end
                end
            else
                local location = headers and (headers["location"] or headers["Location"])
                os.remove(dest)
                if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and location and location ~= "" then
                    local new_url = location
                    if not new_url:match("^https?://") then
                        local host = current_url:match("^(https?://[^/]+)")
                        if host then
                            new_url = (new_url:sub(1,1) == "/") and (host .. new_url) or (host .. "/" .. new_url)
                        end
                    end
                    local ok_redir, res_dest = downloadImage(new_url, dest, max_redirects - 1)
                    if ok_redir then
                        return true, res_dest
                    end
                end
            end
        end
    end
    return false
end

-- Resolves a possibly-relative image src against the repo's default branch
-- on raw.githubusercontent.com.
local function resolveImageUrl(raw_url, owner, repo, is_wiki)
    if not raw_url or raw_url == "" then return "" end

    if raw_url:find("raw%.githubusercontent%.com") and raw_url:find("/HEAD/") then
        raw_url = raw_url:gsub("/HEAD/", "/main/")
    end

    local b_owner, b_repo, b_branch, b_path = raw_url:match("^https?://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$")
    if b_owner and b_repo and b_branch and b_path then
        if b_branch == "HEAD" then b_branch = "main" end
        return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", b_owner, b_repo, b_branch, b_path)
    end

    local r_owner, r_repo, r_branch, r_path = raw_url:match("^https?://github%.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$")
    if r_owner and r_repo and r_branch and r_path then
        if r_branch == "HEAD" then r_branch = "main" end
        return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", r_owner, r_repo, r_branch, r_path)
    end

    local w_owner, w_repo, w_path = raw_url:match("^https?://github%.com/([^/]+)/([^/]+)/wiki/(.+)$")
    if w_owner and w_repo and w_path then
        return string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", w_owner, w_repo, w_path)
    end

    if raw_url:match("^https?://") or raw_url:match("^//") or raw_url:match("^data:") then
        if raw_url:sub(1, 2) == "//" then
            return "https:" .. raw_url
        end
        return raw_url
    end

    local rel = raw_url:gsub("^%./", ""):gsub("^/+", "")
    if is_wiki then
        return string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, rel)
    else
        return string.format("https://raw.githubusercontent.com/%s/%s/main/%s", owner, repo, rel)
    end
end

function RepoContent.stripMarkdown(text)
    text = safeString(text)
    if not text or text == "" then return "" end
    -- Remove HTML comments
    text = text:gsub("<!%-%-.-%-%->", "")
    -- Strip HTML tags completely
    text = text:gsub("<[^>]+>", "")
    -- Remove markdown images: ![alt](url)
    text = text:gsub("!%[[^%]]*%]%([^%)]*%)", "")
    -- Remove inline code fences: `code`
    text = text:gsub("`([^`]+)`", "%1")
    -- Remove blocks of code fences: ```
    text = text:gsub("```", "")
    -- Remove reference definitions: [label]: url
    text = text:gsub("%[%S+%]:%s*%S+", "")
    -- Replace ATX headings: # Header -> HEADER
    text = text:gsub("([^\n]*)\n([#]+)%s*([^\n]+)", function(before, level, title)
        return before .. "\n" .. title:upper()
    end)
    text = text:gsub("^([#]+)%s*([^\n]+)", function(level, title)
        return title:upper()
    end)
    -- Remove link styling while keeping text: [link text](url) -> link text
    text = text:gsub("%[([^%]]+)%]%([^%)]*%)", "%1")
    -- Remove reference style link: [link text][ref] -> link text
    text = text:gsub("%[([^%]]+)%]%[[^%]]*%]", "%1")
    -- Remove bold/italic markers: **bold**, __bold__
    text = text:gsub("%*%*([^*]+)%*%*", "%1")
    text = text:gsub("__([^_]+)__", "%1")
    text = text:gsub("%*([^*]+)%*", "%1")
    text = text:gsub("_([^_]+)_", "%1")
    -- Remove horizontal rules
    text = text:gsub("\n[-*#]%s*[-*#]%s*[-*#]%s*\n", "\n")
    return text
end

function RepoContent.fetchReadme(owner, repo)
    if not owner or not repo then
        return false, "missing owner/repo"
    end
    local url = buildRawUrl(owner, repo)
    local code, body = download(url)
    if code ~= 200 then
        return false, string.format("HTTP %s", tostring(code))
    end
    if not body or body == "" then
        return false, "empty body"
    end
    local dir = getCacheDir()
    local safe_owner = owner:gsub("[^%w_-]", "_")
    local safe_repo = repo:gsub("[^%w_-]", "_")
    local path = string.format("%s/%s_%s_README.md", dir, safe_owner, safe_repo)
    local ok, err = util.writeToFile(body, path)
    if not ok then
        return false, err or "write error"
    end
    return true, path
end

function RepoContent.fetchReadmeHtml(owner, repo, force_refresh)
    if not owner or not repo then
        return false, "missing owner/repo"
    end
    local dir = getCacheDir()
    local safe_owner = owner:gsub("[^%w_-]", "_")
    local safe_repo = repo:gsub("[^%w_-]", "_")
    local path = string.format("%s/%s_%s_README.html", dir, safe_owner, safe_repo)

    local attrs = lfs.attributes(path)

    -- Fetch HTML content
    local body, err = GitHubClient.fetchReadmeHtml(owner, repo)
    if not body then
        if attrs and attrs.mode == "file" then
            return true, path
        end
        return false, err or "fetch error"
    end
    
    if countCJKCharacters(body) > 20 then
        logger.info("Storefront: CJK text detected, displaying safe placeholder to protect device memory.")
        body = string.format('<div class="markdown-body"><p style="text-align:center; padding: 2.5em; color: gray;"><i>%s</i></p></div>', _("Can't load readme...."))
        local ok, write_err = util.writeToFile(body, path)
        return true, path
    end

    -- Hard-cap length before doing expensive regex formatting 
    if #body > 85000 then
        body = body:sub(1, 85000)
    end
    
    -- Strip explicit width and height attributes so images expand to full width
    body = stripImgDimensions(body)

    -- Strip flexbox container styles because MuPDF doesn't support them and they
    -- cause the engine to squish contents (like images) to microscopic sizes to avoid page breaks.
    body = body:gsub('(<div[^>]+style=["\'][^"\']*display:%s*flex[^"\']*["\'][^>]*>)', function(match)
        -- Just remove the style attribute entirely from flex containers
        return match:gsub('%s*style=["\'][^"\']*["\']', '')
    end)

    -- Download inline images locally for MuPDF HTML viewer widget
    local valid_img_count = 0
    body = body:gsub('(<img[^>]+src=["\'])([^"\']+)(["\'][^>]*>)', function(prefix, raw_url, suffix)
        prefix = stripImgDimensions(prefix)
        suffix = stripImgDimensions(suffix)
        local url = raw_url:gsub("&amp;", "&")
        
        -- Filter out badges, shields, and SVG icons early before counting
        local lower_url = url:lower()
        if lower_url:find("%.svg") or lower_url:find("shields%.io") or lower_url:find("badge") or lower_url:find("liberapay") or lower_url:find("github%-actions") or lower_url:find("travis%-ci") or lower_url:find("codecov") then
            return ""
        end

        url = resolveImageUrl(url, owner, repo)

        local clean_url = url:gsub("[^%w]", "_")
        if #clean_url > 40 then
            clean_url = clean_url:sub(-40)
        end
        local ext = url:match("%.([%w]+)$") or "png"
        ext = ext:lower()
        if ext == "svg" then return "" end

        valid_img_count = valid_img_count + 1

        local img_filename = string.format("%s_%s_img_%s.%s", safe_owner, safe_repo, clean_url, ext)
        local img_dest = dir .. "/" .. img_filename

        local cached_sz = lfs.attributes(img_dest, "size") or 0

        -- Synchronously fetch up to the first 4 valid content images at initial README load time
        if cached_sz == 0 and valid_img_count <= 4 and RepoContent.cumulative_page_bytes < MAX_PAGE_PAYLOAD_BYTES then
            if type(downloadImage) == "function" then
                local pcall_ok, dl_ok, final_dest = pcall(downloadImage, url, img_dest)
                if pcall_ok and dl_ok then
                    cached_sz = lfs.attributes(img_dest, "size") or 0
                end
            end
        end

        if cached_sz > 0 then
            local w_check, h_check = getImageDimensions(img_dest)
            if not w_check or not h_check or w_check == 0 or h_check == 0 then
                logger.info("Storefront: purging invalid non-image file from cache:", img_dest)
                os.remove(img_dest)
                cached_sz = 0
            end
        end

        if cached_sz > 0 then
            RepoContent.cumulative_page_bytes = RepoContent.cumulative_page_bytes + cached_sz
            
            local is_safe, uncompressed = isImageSafeForMemory(img_dest, cached_sz)
            if uncompressed then
                RepoContent.cumulative_uncompressed_bytes = RepoContent.cumulative_uncompressed_bytes + uncompressed
            end
            
            local is_gif = img_dest:lower():match("%.gif$") ~= nil
            if is_gif or not is_safe or RepoContent.cumulative_uncompressed_bytes > MAX_UNCOMPRESSED_PAYLOAD then
                local placeholder_text = is_gif and "[ View Animated GIF ]" or "[ View Large Image ]"
                return string.format('<a href="storefront-img:%s" style="display: block; text-align: center; margin: 0.6em auto; color: blue; text-decoration: underline;">%s</a>', img_dest, placeholder_text)
            else
                return string.format('<br/><a href="storefront-img:%s" style="display: block; text-align: center; margin: 1.5em auto;"><img src="%s" style="max-width: 100%%; height: auto; display: block; margin: 0 auto;" /></a>', img_dest, img_filename)
            end
        end

        if RepoContent.cumulative_page_bytes < MAX_PAGE_PAYLOAD_BYTES then
            -- Pass the prefix, filename, and suffix so we can rebuild the image tag later
            table.insert(RepoContent.pending_images, { url = url, dest = img_dest, html_path = path, prefix = prefix, filename = img_filename, suffix = suffix })
        end
        
        -- Default to a text placeholder so MuPDF doesn't OOM on missing/partial image files
        return string.format('<span id="imgbox-%s" style="display: block; text-align: center; margin: 0.6em auto; color: gray; font-style: italic;">[ Loading Image... ]</span>', img_dest)
    end)

    local ok, write_err = util.writeToFile(body, path)
    if not ok then
        return false, write_err or "write error"
    end
    return true, path
end

local function getDirStats(dir_path)
    local files = 0
    local bytes = 0
    if not lfs.attributes or lfs.attributes(dir_path, "mode") ~= "directory" then
        return files, bytes
    end
    local function scan(d)
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then
                local full = d .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "file" then
                        files = files + 1
                        bytes = bytes + (attr.size or 0)
                    elseif attr.mode == "directory" then
                        scan(full)
                    end
                end
            end
        end
    end
    scan(dir_path)
    return files, bytes
end

local function cleanDirRecursive(dir_path)
    local removed = 0
    local bytes = 0
    local errors = {}
    if not lfs.attributes or lfs.attributes(dir_path, "mode") ~= "directory" then
        return removed, bytes, errors
    end
    local function clean(d)
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then
                local full = d .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "file" then
                        local sz = attr.size or 0
                        if os.remove(full) then
                            removed = removed + 1
                            bytes = bytes + sz
                        else
                            table.insert(errors, full)
                        end
                    elseif attr.mode == "directory" then
                        clean(full)
                        lfs.rmdir(full)
                    end
                end
            end
        end
    end
    clean(dir_path)
    return removed, bytes, errors
end

function RepoContent.getReadmeCacheStats()
    local readme_dir = DataStorage:getDataDir() .. "/cache/Storefront/readme"
    local rel_dir = DataStorage:getDataDir() .. "/cache/Storefront/release_notes"
    local f1, b1 = getDirStats(readme_dir)
    local f2, b2 = getDirStats(rel_dir)
    return {
        files = f1 + f2,
        bytes = b1 + b2,
    }
end

-- Remove every cached README markdown file and associated images/HTML.
-- Returns a table with `removed` count, `bytes` freed, and `errors` list.
function RepoContent.clearReadmeCache()
    local readme_dir = DataStorage:getDataDir() .. "/cache/Storefront/readme"
    local rel_dir = DataStorage:getDataDir() .. "/cache/Storefront/release_notes"
    local r1, b1, e1 = cleanDirRecursive(readme_dir)
    local r2, b2, e2 = cleanDirRecursive(rel_dir)
    local errors = {}
    for _, e in ipairs(e1) do table.insert(errors, e) end
    for _, e in ipairs(e2) do table.insert(errors, e) end
    return { removed = r1 + r2, bytes = b1 + b2, errors = errors }
end

function RepoContent.openReadme(path)
    if not path then
        UIManager:show(InfoMessage:new{ text = _("Missing README path"), timeout = 4 })
        return
    end
    local text, err = util.readFromFile(path)
    if not text or text == "" then
        UIManager:show(InfoMessage:new{ text = _("Unable to read README file"), timeout = 4 })
        return
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        text = text,
        title = _("README"),
    })
end

function RepoContent.fetchReleaseNotesHtml(owner, repo, release_override)
    if type(owner) ~= "string" or type(repo) ~= "string" or owner == "" or repo == "" or owner == json_null or repo == json_null then
        return false, "missing owner/repo"
    end

    local clean_repo = repo:gsub("%.koplugin$", "")
    local cache_dir = DataStorage:getDataDir() .. "/cache/Storefront/release_notes"
    local ok_dir, err_dir = util.makePath(cache_dir)
    if not ok_dir then
        logger.warn("Storefront release notes cache dir failure", err_dir)
    end

    local safe_owner = owner:gsub("[^%w_-]", "_")
    local safe_repo  = clean_repo:gsub("[^%w_-]", "_")
    local path = string.format("%s/%s_%s_RELEASENOTES.html", cache_dir, safe_owner, safe_repo)

    local rel_data = (type(release_override) == "table" and release_override ~= json_null) and release_override or nil
    if not rel_data then
        -- Extract release info from Cache if available
        local repo_obj = nil
        local ok_cache, Cache = pcall(require, "storefront_cache")
        if ok_cache and Cache then
            Cache.init()
            repo_obj = Cache.getRepoByName(owner, repo) or Cache.getRepoByName(owner, clean_repo)
        end

        if repo_obj and type(repo_obj) == "table" then
            if type(repo_obj.latest_release) == "table" then
                rel_data = repo_obj.latest_release
            elseif repo_obj.data and type(repo_obj.data.latest_release) == "table" then
                rel_data = repo_obj.data.latest_release
            end
        end
    end

    local is_rel_table = (type(rel_data) == "table" and rel_data ~= json_null)
    local tag_name     = is_rel_table and safeString(rel_data.tag_name or rel_data.release_tag_name or rel_data.version)
    local rel_name     = is_rel_table and safeString(rel_data.name)
    local published_at = is_rel_table and safeString(rel_data.published_at or rel_data.created_at)
    local body         = is_rel_table and safeString(rel_data.body)

    -- If release notes body is missing from catalog/cache data, fetch live from GitHub API.
    -- If we already know the specific tag (e.g. from update scan), fetch THAT release, not
    -- fetchLatestRelease which always returns the latest stable.
    if not body or body == "" then
        local fetched_rel, err
        if tag_name and tag_name ~= "" and GitHubClient.fetchReleaseByTag then
            -- Known tag: fetch the specific release (handles prereleases correctly)
            fetched_rel, err = GitHubClient.fetchReleaseByTag(owner, repo, tag_name)
            if not fetched_rel and repo ~= clean_repo then
                fetched_rel, err = GitHubClient.fetchReleaseByTag(owner, clean_repo, tag_name)
            end
        end
        -- Fall back to latest release only when we have no specific tag to look up
        if not fetched_rel then
            fetched_rel, err = GitHubClient.fetchLatestRelease(owner, repo)
            if not fetched_rel and repo ~= clean_repo then
                fetched_rel, err = GitHubClient.fetchLatestRelease(owner, clean_repo)
            end
        end
        if fetched_rel and type(fetched_rel) == "table" then
            tag_name     = tag_name or safeString(fetched_rel.tag_name or fetched_rel.name)
            rel_name     = rel_name or safeString(fetched_rel.name)
            published_at = published_at or safeString(fetched_rel.published_at or fetched_rel.created_at)
            body         = safeString(fetched_rel.body)
        end
    end

    local clean_tag = tag_name and tag_name:gsub("^[vV]", "") or ""
    local clean_rel = rel_name and rel_name:gsub("^[vV]", "") or ""

    local tag_fmt = clean_tag ~= "" and ("v" .. clean_tag) or ""
    local header_title = ""

    if clean_rel == "" or clean_rel:lower() == clean_tag:lower() then
        header_title = tag_fmt ~= "" and tag_fmt or _("Latest Release")
    elseif rel_name and (rel_name:lower():find(clean_tag:lower(), 1, true) or (tag_fmt ~= "" and rel_name:lower():find(tag_fmt:lower(), 1, true))) then
        header_title = rel_name
    else
        if tag_fmt ~= "" then
            header_title = tag_fmt .. " — " .. rel_name
        else
            header_title = rel_name
        end
    end

    local pub_str = (published_at and type(published_at) == "string") and published_at:sub(1, 10) or ""

    local html_parts = {}
    table.insert(html_parts, "<div class=\"markdown-body\">")
    table.insert(html_parts, string.format("<h2>%s</h2>", header_title))
    if pub_str ~= "" then
        table.insert(html_parts, string.format("<p style=\"color:gray;margin-top:0.2em;\">" .. _("Published: %s") .. "</p>", pub_str))
    end
    table.insert(html_parts, "<hr style=\"margin-top:0.6em;margin-bottom:0.8em;\"/>")

    if body and type(body) == "string" and body:match("%S") then
        local body_html = GitHubClient.markdownToHtml(body, owner, clean_repo)
        table.insert(html_parts, body_html)
    else
        table.insert(html_parts, "<p style=\"color:gray;\">" .. _("No detailed release notes provided for this version.") .. "</p>")
    end
    table.insert(html_parts, "</div>")

    local full_html = table.concat(html_parts, "\n")
    local ok, write_err = util.writeToFile(full_html, path)
    if not ok then
        return false, write_err or "write error"
    end
    return true, path
end

local function getWikiCacheDir(owner, repo)
    local dir = DataStorage:getDataDir() .. "/cache/Storefront/wiki"
    local safe_owner = owner:gsub("[^%w_-]", "_")
    local safe_repo = repo:gsub("[^%w_-]", "_")
    local repo_dir = string.format("%s/%s_%s", dir, safe_owner, safe_repo)
    local ok, err = util.makePath(repo_dir)
    if not ok then
        logger.warn("Storefront Wiki cache dir failure", err)
    end
    return repo_dir
end

RepoContent.getWikiCacheDir = getWikiCacheDir

local wiki_status_cache = {}

function RepoContent.checkWikiExists(owner, repo)
    if not owner or not repo or owner == "" or repo == "" then
        return false
    end
    local key = (owner .. "/" .. repo):lower()
    if wiki_status_cache[key] ~= nil then
        return wiki_status_cache[key]
    end

    local dir = getWikiCacheDir(owner, repo)
    local home_path = string.format("%s/Home.html", dir)
    if lfs.attributes(home_path, "mode") == "file" then
        wiki_status_cache[key] = true
        return true
    end

    local raw_home, err = GitHubClient.fetchWikiPageRaw(owner, repo, "Home")
    if raw_home and raw_home ~= "" then
        wiki_status_cache[key] = true
        return true
    end

    wiki_status_cache[key] = false
    return false
end

function RepoContent.fetchWikiSidebar(owner, repo, force_refresh)
    if not owner or not repo then
        return {}
    end
    local raw_sidebar = GitHubClient.fetchWikiPageRaw(owner, repo, "_Sidebar")
    local items = {}
    local seen = {}

    local function isImageTarget(str)
        if not str or type(str) ~= "string" then return false end
        local clean = str:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local ext = clean:match("%.([%w]+)$") or clean:match("%.([%w]+)%?")
        if ext then
            if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp" or ext == "svg" or ext == "bmp" then
                return true
            end
        end
        if clean:find("^image:") or clean:find("^file:") or clean:find("^media:") or clean:find("^img/") or clean:find("^images/") or clean:find("/img/") then
            return true
        end
        return false
    end

    local function addPageItem(title, target)
        if not target or target == "" then return end
        local clean_target = target:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^/+", "")
        clean_target = clean_target:gsub("^https?://github%.com/[^/]+/[^/]+/wiki/", "")

        if clean_target:find("|") then
            local p1, p2 = clean_target:match("^(.-)|(.-)$")
            if p1 and p2 then
                clean_target = p1:gsub("^%s+", ""):gsub("%s+$", "")
                if not title or title == target then
                    title = p2:gsub("^%s+", ""):gsub("%s+$", "")
                end
            end
        end

        local clean_title = (title and type(title) == "string") and title:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if clean_title:find("|") then
            local p1, p2 = clean_title:match("^(.-)|(.-)$")
            if p1 and p2 then
                clean_title = p1:gsub("^%s+", ""):gsub("%s+$", "")
            end
        end

        if isImageTarget(clean_target) or isImageTarget(clean_title) then
            return
        end

        local key = clean_target:lower():gsub("[^%w]", "")
        if key == "" then key = clean_target:lower() end

        if not seen[key] then
            seen[key] = true
            local display_title = (clean_title ~= "" and clean_title ~= clean_target) and clean_title or clean_target
            if display_title == clean_target then
                display_title = display_title:gsub("^(%d+)%.-", "%1. "):gsub("-", " ")
            end

            table.insert(items, {
                title = display_title,
                page = clean_target,
            })
        end
    end

    if raw_sidebar and raw_sidebar ~= "" then
        for line in (raw_sidebar .. "\n"):gmatch("(.-)\r?\n") do
            if not line:match("^%s*!%[") then
                local title, target = line:match("%[%[([^%]|]+)|([^%]]+)%]")
                if not title then
                    target = line:match("%[%[([^%]]+)%]")
                    title = target
                end
                if not target then
                    title, target = line:match("([^!]%[[^%]]+%]%(([^%)]+)%)")
                    if not target then
                        title, target = line:match("^%[([^%]]+)%]%(([^%)]+)%)")
                    end
                end
                if target then
                    addPageItem(title, target)
                end
            end
        end
    else
        addPageItem("Home", "Home")
        local raw_home = GitHubClient.fetchWikiPageRaw(owner, repo, "Home")
        if raw_home and raw_home ~= "" then
            local text_no_imgs = raw_home:gsub("!%[[^%]]*%]%([^%)]*%)", "")
            for title, target in text_no_imgs:gmatch("%[%[([^%]|]+)|([^%]]+)%]") do
                addPageItem(title, target)
            end
            for target in text_no_imgs:gmatch("%[%[([^%]]+)%]") do
                addPageItem(target, target)
            end
            for title, target in text_no_imgs:gmatch("%[([^%]]+)%]%(([^%)]+)%)") do
                if not target:find("^https?://") and not target:find("^#") and not target:find("^data:") then
                    addPageItem(title, target)
                end
            end
        end
    end

    return items
end

function RepoContent.fetchWikiPageHtml(owner, repo, page_name, force_refresh)
    if not owner or not repo then
        return false, "missing owner/repo"
    end
    pcall(RepoContent.autoCleanCache)
    page_name = (page_name and page_name ~= "") and page_name or "Home"
    local safe_page = page_name:gsub("[^%w_-]", "_")
    local dir = getWikiCacheDir(owner, repo)
    local path = string.format("%s/%s.html", dir, safe_page)

    local ext = page_name:lower():match("%.([%w]+)$")
    if ext and (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp" or ext == "svg" or ext == "bmp") then
        local img_url = resolveImageUrl(page_name, owner, repo, true)
        local safe_owner = owner:gsub("[^%w_-]", "_")
        local safe_repo = repo:gsub("[^%w_-]", "_")
        local clean_url = img_url:gsub("[^%w]", "_")
        if #clean_url > 40 then clean_url = clean_url:sub(-40) end
        local img_filename = string.format("%s_%s_wiki_img_%s.%s", safe_owner, safe_repo, clean_url, ext)
        local img_dest = dir .. "/" .. img_filename
        local cached_sz = lfs.attributes(img_dest, "size") or 0
        if cached_sz > 0 then
            RepoContent.cumulative_page_bytes = RepoContent.cumulative_page_bytes + cached_sz
        elseif RepoContent.cumulative_page_bytes < MAX_PAGE_PAYLOAD_BYTES then
            table.insert(RepoContent.pending_images, { url = img_url, dest = img_dest, html_path = path })
        end
        local html = string.format('<div class="markdown-body"><p><b>%s</b></p><hr/><a href="storefront-img:%s"><img src="%s"/></a></div>', page_name, img_dest, img_filename)
        util.writeToFile(html, path)
        return true, path
    end

    local attrs = lfs.attributes(path)

    local raw_md, err = GitHubClient.fetchWikiPageRaw(owner, repo, page_name)
    if not raw_md or raw_md == "" then
        if attrs and attrs.mode == "file" then
            return true, path
        end
        return false, err or "wiki page not found"
    end

    local body = GitHubClient.markdownToHtml(raw_md, owner, repo, true)

    -- Strip explicit width and height attributes so images expand to full width
    body = body:gsub("(<img[^>]+)%s+width=[\"'][^\"']*[\"']", "%1")
    body = body:gsub("(<img[^>]+)%s+height=[\"'][^\"']*[\"']", "%1")
    body = body:gsub("(<img[^>]+style=[\"'][^\"']*[%s\"';])width:%s*[^;\"]+;?", "%1")

    -- Download inline images locally if needed
    body = body:gsub('(<img[^>]+src=["\'])([^"\']+)(["\'][^>]*>)', function(prefix, raw_url, suffix)
        local url = raw_url:gsub("&amp;", "&")
        if url:lower():match("%.svg") ~= nil then return "" end
        url = resolveImageUrl(url, owner, repo, true)

        local clean_url = url:gsub("[^%w]", "_")
        if #clean_url > 40 then clean_url = clean_url:sub(-40) end
        local ext = url:match("%.([%w]+)$") or "png"
        ext = ext:lower()
        if ext == "svg" then return "" end

        local safe_owner = owner:gsub("[^%w_-]", "_")
        local safe_repo = repo:gsub("[^%w_-]", "_")
        local img_filename = string.format("%s_%s_wiki_img_%s.%s", safe_owner, safe_repo, clean_url, ext)
        local img_dest = dir .. "/" .. img_filename

        local cached_sz = lfs.attributes(img_dest, "size") or 0
        if cached_sz > 0 then
            RepoContent.cumulative_page_bytes = RepoContent.cumulative_page_bytes + cached_sz
            
            local is_safe, uncompressed = isImageSafeForMemory(img_dest, cached_sz)
            if uncompressed then
                RepoContent.cumulative_uncompressed_bytes = RepoContent.cumulative_uncompressed_bytes + uncompressed
            end
            
            if not is_safe or RepoContent.cumulative_uncompressed_bytes > MAX_UNCOMPRESSED_PAYLOAD then
                local placeholder = '<span style="color: blue; text-decoration: underline;">[ View Large Image ]</span>'
                return string.format('<a href="storefront-img:%s">%s</a>', img_dest, placeholder)
            else
                local img_html = prefix .. img_filename .. suffix
                return string.format('<a href="storefront-img:%s">%s</a>', img_dest, img_html)
            end
        end

        if RepoContent.cumulative_page_bytes < MAX_PAGE_PAYLOAD_BYTES then
            -- Pass the prefix, filename, and suffix so we can rebuild the image tag later
            table.insert(RepoContent.pending_images, { url = url, dest = img_dest, html_path = path, prefix = prefix, filename = img_filename, suffix = suffix })
        end
        
        -- Default to a text placeholder so MuPDF doesn't OOM on missing/partial image files
        local safe_dest = img_dest:gsub("([^%w])", "%%%1")
        local placeholder = string.format('<span id="placeholder-%s" style="color: gray; font-style: italic;">[ Loading Image... ]</span>', safe_dest)
        return string.format('<a href="storefront-img:%s">%s</a>', img_dest, placeholder)
    end)

    local ok, write_err = util.writeToFile(body, path)
    if not ok then
        return false, write_err or "write error"
    end
    return true, path
end

function RepoContent.autoCleanCache(max_size_mb, max_age_days)
    max_size_mb = max_size_mb or 50
    max_age_days = max_age_days or 30
    local max_bytes = max_size_mb * 1024 * 1024
    local max_age_secs = max_age_days * 86400

    local cache_dirs = {
        DataStorage:getDataDir() .. "/cache/Storefront/readme",
        DataStorage:getDataDir() .. "/cache/Storefront/wiki",
    }

    local files = {}
    local total_size = 0
    local now = os.time()

    for _, base_dir in ipairs(cache_dirs) do
        if lfs.attributes(base_dir, "mode") == "directory" then
            local function scanDir(d)
                for entry in lfs.dir(d) do
                    if entry ~= "." and entry ~= ".." then
                        local full = d .. "/" .. entry
                        local attr = lfs.attributes(full)
                        if attr then
                            if attr.mode == "file" then
                                local age = now - (attr.modification or 0)
                                if age > max_age_secs then
                                    os.remove(full)
                                else
                                    total_size = total_size + (attr.size or 0)
                                    table.insert(files, { path = full, mtime = attr.modification or 0, size = attr.size or 0 })
                                end
                            elseif attr.mode == "directory" then
                                scanDir(full)
                            end
                        end
                    end
                end
            end
            scanDir(base_dir)
        end
    end

    if total_size > max_bytes then
        table.sort(files, function(a, b) return a.mtime < b.mtime end)
        for _, file in ipairs(files) do
            if total_size <= max_bytes then break end
            if os.remove(file.path) then
                total_size = total_size - file.size
            end
        end
    end
end

function RepoContent.getWikiCacheStats()
    local dir = DataStorage:getDataDir() .. "/cache/Storefront/wiki"
    local files, bytes = getDirStats(dir)
    return {
        files = files,
        bytes = bytes,
    }
end

function RepoContent.clearWikiCache()
    local dir = DataStorage:getDataDir() .. "/cache/Storefront/wiki"
    local removed, bytes, errors = cleanDirRecursive(dir)
    return { removed = removed, bytes = bytes, errors = errors }
end

return RepoContent

