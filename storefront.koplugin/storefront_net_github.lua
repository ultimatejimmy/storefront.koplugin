local http = require("socket.http")
local json = require("json")
local url = require("socket.url")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ok_su, socketutil = pcall(require, "socketutil")
if not ok_su or not socketutil then
    socketutil = {
        FILE_BLOCK_TIMEOUT = 15,
        FILE_TOTAL_TIMEOUT = 30,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end

local ok_cfg, StorefrontConfig = pcall(require, "storefront_config")
if not ok_cfg then
    ok_cfg, StorefrontConfig = pcall(require, "storefront_configuration")
end
if not ok_cfg then
    StorefrontConfig = {}
end

local function getHttpModule(url_str)
    if url_str and url_str:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

local GitHubClient = {}
local MAX_README_MARKDOWN_BYTES = 100000

local BASE_URL = "https://api.github.com"
local USER_AGENT = "KOReader-Storefront"

-- Token entered through the Settings UI (see storefront_settings_card.lua),
-- stored separately from storefront_configuration.lua so users don't have to
-- hand-edit a Lua file just to add a PAT. Kept in its own settings file (not
-- StorefrontSettings in main.lua) so this module has no dependency on it.
local AUTH_SETTINGS_PATH = DataStorage:getSettingsDir() .. "/Storefront_github.lua"
local AuthSettings = LuaSettings:open(AUTH_SETTINGS_PATH)
local TOKEN_KEY = "github_token"
local CATALOG_MODE_KEY = "catalog_mode"

local function joinQueryParts(parts)
    if not parts or #parts == 0 then
        return ""
    end
    return table.concat(parts, " ")
end

local function safeJsonDecode(body)
    if not body or body == "" then return false, nil end
    local decode_simple = (type(json.decode) == "table" and json.decode.simple)
    if decode_simple then
        local ok, parsed = pcall(json.decode, body, decode_simple)
        if ok and parsed ~= nil then
            return true, parsed
        end
    end
    local ok, parsed = pcall(json.decode, body)
    if ok and parsed ~= nil then
        return true, parsed
    end
    return false, parsed
end

local function newTableSink(target)
    return function(chunk, err)
        if chunk then
            target[#target + 1] = chunk
        end
        return 1, err
    end
end

-- Returns the configured PAT, preferring the one saved via the Settings UI
-- over the legacy storefront_configuration.lua file (kept for users who
-- already set that up).
function GitHubClient.getToken()
    local saved = AuthSettings:readSetting(TOKEN_KEY)
    if type(saved) == "string" and saved ~= "" then
        return saved
    end
    local auth = StorefrontConfig.auth and StorefrontConfig.auth.github
    local token = auth and auth.token
    if token and token ~= "" and token ~= "your_github_token" then
        return token
    end
    return nil
end

function GitHubClient.hasAuthToken()
    return GitHubClient.getToken() ~= nil
end

function GitHubClient.getCatalogMode()
    local saved = AuthSettings:readSetting(CATALOG_MODE_KEY)
    if saved == "direct" or saved == "static" then
        return saved
    end
    if GitHubClient.hasAuthToken() then
        return "direct"
    end
    return "static"
end

function GitHubClient.setCatalogMode(mode)
    if mode == "direct" or mode == "static" then
        AuthSettings:saveSetting(CATALOG_MODE_KEY, mode)
    else
        AuthSettings:delSetting(CATALOG_MODE_KEY)
    end
    AuthSettings:flush()
end

function GitHubClient.isDirectApiEnabled()
    return GitHubClient.getCatalogMode() == "direct"
end

-- Saves (or, when token is nil/empty, clears) the PAT entered via the
-- Settings UI.
function GitHubClient.setToken(token)
    token = token and token:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if token == "" then
        AuthSettings:delSetting(TOKEN_KEY)
    else
        AuthSettings:saveSetting(TOKEN_KEY, token)
    end
    AuthSettings:flush()
end

local function getAuthHeaders()
    local token = GitHubClient.getToken()
    if not token then
        return nil
    end
    local scheme = (StorefrontConfig.auth and StorefrontConfig.auth.github and StorefrontConfig.auth.github.scheme) or "token"
    return {
        ["Authorization"] = string.format("%s %s", scheme, token),
    }
end

local function request(path, query)
    local response_body = {}
    local target = BASE_URL .. path
    if query and query ~= "" then
        target = target .. "?" .. query
    end
    logger.dbg("Storefront HTTP", target)
    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = USER_AGENT,
    }
    local auth_headers = getAuthHeaders()
    if auth_headers then
        for key, value in pairs(auth_headers) do
            headers[key] = value
        end
    end
    local http_mod = getHttpModule(target)
    local code
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    pcall(function()
        _, code = http_mod.request{
            url = target,
            headers = headers,
            sink = newTableSink(response_body),
        }
    end)
    socketutil:reset_timeout()
    local body = table.concat(response_body)
    return tonumber(code) or 0, body
end

local function buildQuery(opts)
    local query_parts = {}
    if opts.q and opts.q ~= "" then
        table.insert(query_parts, "q=" .. url.escape(opts.q))
    end
    if opts.sort and opts.sort ~= "" then
        table.insert(query_parts, "sort=" .. opts.sort)
    end
    if opts.order and opts.order ~= "" then
        table.insert(query_parts, "order=" .. opts.order)
    end
    table.insert(query_parts, "page=" .. tostring(opts.page or 1))
    table.insert(query_parts, "per_page=" .. tostring(opts.per_page or 30))
    return table.concat(query_parts, "&")
end

local function buildTopicQuery(topics, extra_terms)
    local parts = {}
    if topics then
        for _, topic in ipairs(topics) do
            if topic and topic ~= "" then
                table.insert(parts, string.format("topic:%s", topic))
            end
        end
    end
    if extra_terms and extra_terms ~= "" then
        table.insert(parts, extra_terms)
    end
    return joinQueryParts(parts)
end

function GitHubClient.searchRepositories(opts)
    opts = opts or {}
    local query = buildQuery(opts)
    local code, body = request("/search/repositories", query)
    if code ~= 200 then
        logger.warn("GitHub search error", code, body)
        -- GitHub's search endpoint rejects fine-grained PATs outright (they're
        -- not in its list of supported token types), returning a 403 with this
        -- wording rather than an actual rate-limit response. Classic tokens work.
        local is_fine_grained_unsupported = code == 403
            and body
            and body:lower():find("fine%-grained", 1, true) ~= nil
        local err_info = {
            code = code,
            body = body,
            is_rate_limit = (code == 403 or code == 429) and not is_fine_grained_unsupported,
            is_fine_grained_unsupported = is_fine_grained_unsupported,
        }
        return nil, err_info
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub search decode error", parsed)
        return nil, { code = 0, body = "decode", is_rate_limit = false }
    end
    return parsed, nil
end

function GitHubClient.hasAuthToken()
    return GitHubClient.getToken() ~= nil
end

function GitHubClient.searchByTopics(topics, opts)
    opts = opts or {}
    local q = buildTopicQuery(topics, opts.extra)
    opts.q = q
    opts.sort = opts.sort or "stars"
    opts.order = opts.order or "desc"
    opts.per_page = opts.per_page or 100
    return GitHubClient.searchRepositories(opts)
end

function GitHubClient.fetchRepoTree(owner, repo, ref)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    ref = ref or "HEAD"
    local path = string.format("/repos/%s/%s/git/trees/%s", owner, repo, ref)
    local code, body = request(path, "recursive=1")
    if code ~= 200 then
        logger.warn("GitHub fetch tree error", owner .. "/" .. repo, ref, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub fetch tree decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchRepoMetadata(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch repo metadata error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub fetch repo metadata decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchLatestRelease(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s/releases/latest", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch latest release error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub fetch latest release decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchReleaseByTag(owner, repo, tag)
    if not owner or not repo or not tag then
        return nil, "missing parameters"
    end
    local path = string.format("/repos/%s/%s/releases/tags/%s", owner, repo, tag)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch release by tag error", owner .. "/" .. repo, tag, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub fetch release by tag decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

-- Fetch all releases of a repository (sorted from newest to oldest by GitHub).
-- Pagination is performed transparently up to `max_pages` to avoid hammering
-- the API for repositories with hundreds of releases.
function GitHubClient.fetchReleases(owner, repo, opts)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    opts = opts or {}
    local per_page = tonumber(opts.per_page) or 100
    local max_pages = tonumber(opts.max_pages) or 5
    local results = {}
    for page = 1, max_pages do
        local path = string.format("/repos/%s/%s/releases", owner, repo)
        local query = string.format("per_page=%d&page=%d", per_page, page)
        local code, body = request(path, query)
        if code ~= 200 then
            logger.warn("GitHub fetch releases error", owner .. "/" .. repo, code, body)
            if #results > 0 then
                return results, nil
            end
            return nil, { code = code, body = body }
        end
        local ok, parsed = safeJsonDecode(body)
        if not ok or type(parsed) ~= "table" then
            logger.warn("GitHub fetch releases decode error", parsed)
            if #results > 0 then
                return results, nil
            end
            return nil, "decode"
        end
        if #parsed == 0 then
            break
        end
        for _, rel in ipairs(parsed) do
            table.insert(results, rel)
        end
        if #parsed < per_page then
            break
        end
    end
    return results, nil
end

-- Fetch the list of commits between two refs (tags, branches, SHAs).
-- Uses the GitHub compare endpoint: /repos/{owner}/{repo}/compare/{base}...{head}
-- Returns the parsed JSON table (contains `commits`, `total_commits`, etc.) or nil + err.
function GitHubClient.fetchCompareCommits(owner, repo, base, head)
    if not owner or not repo or not base or not head then
        return nil, "missing parameters"
    end
    local path = string.format("/repos/%s/%s/compare/%s...%s", owner, repo, base, head)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub compare error", owner .. "/" .. repo, base .. "..." .. head, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = safeJsonDecode(body)
    if not ok then
        logger.warn("GitHub compare decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

local function markdownToHtml(md, owner, repo)
    if type(md) ~= "string" or md == "" or md == json.null then
        return "<div class=\"markdown-body\"><p>No release notes or README content provided.</p></div>"
    end

    -- Clean control characters and null bytes
    md = md:gsub("[%z\1-\8\11\12\14-\31]", "")

    -- Enforce max body length (50 KB) to avoid MuPDF memory exhaustion
    if #md > 50000 then
        md = md:sub(1, 50000) .. "\n\n*(Release notes truncated...)*"
    end

    -- Strip HTML comments
    md = md:gsub("<!%-%-.-%-%->", "")

    -- Convert unrecognized named HTML entities to UTF-8 characters
    local entity_map = {
        ["&nbsp;"] = " ",
        ["&mdash;"] = "—",
        ["&ndash;"] = "–",
        ["&hellip;"] = "…",
        ["&rsquo;"] = "’",
        ["&lsquo;"] = "‘",
        ["&rdquo;"] = "”",
        ["&ldquo;"] = "“",
        ["&bull;"] = "•",
        ["&copy;"] = "©",
        ["&trade;"] = "™",
        ["&check;"] = "✓",
    }
    for entity, repl in pairs(entity_map) do
        md = md:gsub(entity, repl)
    end

    -- Pre-convert Markdown Tables into HTML table blocks
    local function convertMarkdownTables(text)
        local raw_lines = {}
        for l in (text .. "\n"):gmatch("(.-)\r?\n") do
            table.insert(raw_lines, l)
        end

        local out_lines = {}
        local idx = 1
        while idx <= #raw_lines do
            local l1 = raw_lines[idx]
            local l2 = raw_lines[idx + 1]

            local is_l1_pipe = l1 and l1:find("|") ~= nil
            local is_l2_sep = l2 and l2:find("|") and (l2:gsub("^%s*|", ""):gsub("|%s*$", ""):match("^%s*[%-%s:|]+%s*$") and l2:find("%-"))

            if is_l1_pipe and is_l2_sep then
                local tbl_parts = {}
                table.insert(tbl_parts, "<table>")
                table.insert(tbl_parts, "<thead><tr>")

                local function splitCells(row_str)
                    local s = row_str:gsub("^%s*|", ""):gsub("|%s*$", "")
                    local cells = {}
                    local pos = 1
                    while true do
                        local p = s:find("|", pos, true)
                        if not p then
                            local c = (s:sub(pos):gsub("^%s+", ""):gsub("%s+$", ""))
                            table.insert(cells, c)
                            break
                        else
                            local c = (s:sub(pos, p - 1):gsub("^%s+", ""):gsub("%s+$", ""))
                            table.insert(cells, c)
                            pos = p + 1
                        end
                    end
                    return cells
                end

                for _, h in ipairs(splitCells(l1)) do
                    table.insert(tbl_parts, string.format("<th>%s</th>", h))
                end
                table.insert(tbl_parts, "</tr></thead><tbody>")

                idx = idx + 2

                while idx <= #raw_lines do
                    local row = raw_lines[idx]
                    if not row or not row:find("|") or row:match("^%s*$") then
                        break
                    end
                    table.insert(tbl_parts, "<tr>")
                    for _, c in ipairs(splitCells(row)) do
                        table.insert(tbl_parts, string.format("<td>%s</td>", c))
                    end
                    table.insert(tbl_parts, "</tr>")
                    idx = idx + 1
                end
                table.insert(tbl_parts, "</tbody></table>")
                table.insert(out_lines, table.concat(tbl_parts))
            else
                table.insert(out_lines, l1)
                idx = idx + 1
            end
        end
        return table.concat(out_lines, "\n")
    end

    md = convertMarkdownTables(md)

    local lines = {}
    local in_code_block = false
    local in_list = false

    for line in (md .. "\n"):gmatch("(.-)\r?\n") do
        if line:match("^%s*```") then
            if in_code_block then
                table.insert(lines, "</code></pre>")
                in_code_block = false
            else
                if in_list then table.insert(lines, "</ul>"); in_list = false end
                table.insert(lines, "<pre><code>")
                in_code_block = true
            end
        elseif in_code_block then
            local escaped = line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            table.insert(lines, escaped)
        else
            local processed = line

            -- Convert Markdown Images: ![alt](url) -> <img src="url" alt="alt"/>
            processed = processed:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt, src)
                if owner and repo and type(owner) == "string" and type(repo) == "string" and not src:find("^https?://") and not src:find("^data:") then
                    local clean_src = src:gsub("^%./", "")
                    if is_wiki then
                        src = string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, clean_src)
                    else
                        src = string.format("https://raw.githubusercontent.com/%s/%s/main/%s", owner, repo, clean_src)
                    end
                end
                return string.format('<img src="%s" alt="%s"/>', src, alt)
            end)

            -- Clean/resolve raw HTML img tags
            processed = processed:gsub("<img%s+(.-)/?>", function(attrs)
                local unescaped_attrs = attrs:gsub("&quot;", '"')
                if owner and repo and type(owner) == "string" and type(repo) == "string" then
                    unescaped_attrs = unescaped_attrs:gsub('src=["\']([^"\']+)["\']', function(src)
                        if not src:find("^https?://") and not src:find("^data:") then
                            local clean_src = src:gsub("^%./", "")
                            if is_wiki then
                                src = string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, clean_src)
                            else
                                src = string.format("https://raw.githubusercontent.com/%s/%s/main/%s", owner, repo, clean_src)
                            end
                        end
                        return string.format('src="%s"', src)
                    end)
                end
                return string.format('<img %s/>', unescaped_attrs)
            end)

            -- Convert details/summary HTML tags for MuPDF compatibility
            processed = processed:gsub("<details>", "<div>")
            processed = processed:gsub("</details>", "</div>")
            processed = processed:gsub("<summary>", "<p><b>")
            processed = processed:gsub("</summary>", "</b></p>")
            processed = processed:gsub("<br%s*/?>", "<br/>")

            local function isImageFile(str)
                if not str or type(str) ~= "string" then return false end
                local clean = str:gsub("^%s+", ""):gsub("%s+$", ""):lower()
                local ext = clean:match("%.([%w]+)$") or clean:match("%.([%w]+)%?")
                if ext then
                    if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp" or ext == "svg" or ext == "bmp" then
                        return true
                    end
                end
                if clean:find("^image:") or clean:find("^file:") or clean:find("^media:") then
                    return true
                end
                return false
            end

            -- Convert Gollum Wiki links: [[Title|Page-Name]] or [[Page-Name]] or [[image.png]]
            processed = processed:gsub("%[%[([^%]|]+)|([^%]]+)%]%]", function(arg1, arg2)
                local clean1 = arg1:gsub("^%s+", ""):gsub("%s+$", "")
                local clean2 = arg2:gsub("^%s+", ""):gsub("%s+$", "")
                if isImageFile(clean2) then
                    local src = clean2:gsub("^[Ii]mage:", ""):gsub("^[Ff]ile:", "")
                    if is_wiki and owner and repo and not src:find("^https?://") and not src:find("^data:") then
                        src = string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, src:gsub("^%./", ""))
                    end
                    return string.format('<img src="%s" alt="%s"/>', src, clean1)
                elseif isImageFile(clean1) then
                    local src = clean1:gsub("^[Ii]mage:", ""):gsub("^[Ff]ile:", "")
                    if is_wiki and owner and repo and not src:find("^https?://") and not src:find("^data:") then
                        src = string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, src:gsub("^%./", ""))
                    end
                    return string.format('<img src="%s" alt="%s"/>', src, clean2)
                else
                    local clean_target = clean2:gsub("%s+", "-")
                    return string.format('<a href="storefront-wiki:%s">%s</a>', clean_target, clean1)
                end
            end)

            processed = processed:gsub("%[%[([^%]]+)%]%]", function(target)
                local clean_target = target:gsub("^%s+", ""):gsub("%s+$", "")
                if isImageFile(clean_target) then
                    local src = clean_target:gsub("^[Ii]mage:", ""):gsub("^[Ff]ile:", "")
                    if is_wiki and owner and repo and not src:find("^https?://") and not src:find("^data:") then
                        src = string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, src:gsub("^%./", ""))
                    end
                    return string.format('<img src="%s" alt="%s"/>', src, clean_target)
                else
                    local clean_link = clean_target:gsub("%s+", "-")
                    return string.format('<a href="storefront-wiki:%s">%s</a>', clean_link, clean_target)
                end
            end)

            -- Convert Markdown links: [label](url)
            processed = processed:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(label, url_str)
                local wiki_page = url_str:match("^https?://github%.com/[^/]+/[^/]+/wiki/(.+)$")
                    or url_str:match("^/[^/]+/[^/]+/wiki/(.+)$")
                if wiki_page then
                    local clean_w = wiki_page:gsub("#.*$", "")
                    return string.format('<a href="storefront-wiki:%s">%s</a>', clean_w, label)
                end
                return string.format('<a href="%s">%s</a>', url_str, label)
            end)
            local saved_tags = {}
            processed = processed:gsub("<[^>]+>", function(tag)
                table.insert(saved_tags, tag)
                return "\0TAG" .. #saved_tags .. "\0"
            end)

            processed = processed:gsub("%*%*([^*]+)%*%*", function(b) return string.format("<b>%s</b>", b) end)
            processed = processed:gsub("__([^_]+)__", function(b) return string.format("<b>%s</b>", b) end)
            processed = processed:gsub("%*([^*]+)%*", function(i) return string.format("<i>%s</i>", i) end)
            processed = processed:gsub("_([^_]+)_", function(i) return string.format("<i>%s</i>", i) end)
            processed = processed:gsub("`([^`]+)`", function(c) return string.format("<code>%s</code>", c) end)

            processed = processed:gsub("%zTAG(%d+)%z", function(idx)
                return saved_tags[tonumber(idx)]
            end)

            -- Check for HTML table block tags so we don't wrap them in <p>
            local is_tbl_tag = processed:find("<table") or processed:find("</table>")
                or processed:find("<tr") or processed:find("</tr>")
                or processed:find("<th") or processed:find("</th>")
                or processed:find("<td") or processed:find("</td>")
                or processed:find("<thead") or processed:find("</thead>")
                or processed:find("<tbody") or processed:find("</tbody>")

            if is_tbl_tag then
                if in_list then table.insert(lines, "</ul>"); in_list = false end
                table.insert(lines, processed)
            else
                -- Headings
                local h6 = processed:match("^######%s+(.+)")
                local h5 = processed:match("^#####%s+(.+)")
                local h4 = processed:match("^####%s+(.+)")
                local h3 = processed:match("^###%s+(.+)")
                local h2 = processed:match("^##%s+(.+)")
                local h1 = processed:match("^#%s+(.+)")

                if h1 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h1>" .. h1 .. "</h1>")
                elseif h2 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h2>" .. h2 .. "</h2>")
                elseif h3 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h3>" .. h3 .. "</h3>")
                elseif h4 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h4>" .. h4 .. "</h4>")
                elseif h5 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h5>" .. h5 .. "</h5>")
                elseif h6 then
                    if in_list then table.insert(lines, "</ul>"); in_list = false end
                    table.insert(lines, "<h6>" .. h6 .. "</h6>")
                else
                    local item = processed:match("^%s*[%-%*]%s+(.+)")
                    if item then
                        if not in_list then
                            table.insert(lines, "<ul>")
                            in_list = true
                        end
                        table.insert(lines, "<li>" .. item .. "</li>")
                    else
                        if in_list then
                            table.insert(lines, "</ul>")
                            in_list = false
                        end
                        if processed:match("^%s*$") then
                            table.insert(lines, "<br/>")
                        else
                            table.insert(lines, "<p>" .. processed .. "</p>")
                        end
                    end
                end
            end
        end
    end

    if in_code_block then table.insert(lines, "</code></pre>") end
    if in_list then table.insert(lines, "</ul>") end

    return '<div class="markdown-body">\n' .. table.concat(lines, "\n") .. '\n</div>'
end

GitHubClient.markdownToHtml = markdownToHtml

-- Fetch the HTML representation of README.
-- Returns raw HTML string, or nil + error.
function GitHubClient.fetchReadmeHtml(owner, repo)
    if not owner or not repo then
        return nil, "missing parameters"
    end

    -- Fast CDN First: fetch raw README markdown and parse locally in <100ms
    local raw_url = string.format("https://raw.githubusercontent.com/%s/%s/HEAD/README.md", owner, repo)
    local raw_response = {}
    local raw_http_mod = getHttpModule(raw_url)
    local raw_code
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    pcall(function()
        _, raw_code = raw_http_mod.request{
            url = raw_url,
            headers = { ["User-Agent"] = USER_AGENT },
            sink = newTableSink(raw_response),
        }
    end)
    socketutil:reset_timeout()
    local raw_md = table.concat(raw_response)
    if tonumber(raw_code) == 200 and raw_md ~= "" then
        if #raw_md > MAX_README_MARKDOWN_BYTES then
            raw_md = raw_md:sub(1, MAX_README_MARKDOWN_BYTES)
                .. "\n\n(Readme truncated to protect device memory.)"
        end
        return markdownToHtml(raw_md, owner, repo), nil
    end

    -- Secondary Fallback: GitHub REST API HTML endpoint
    local path = string.format("/repos/%s/%s/readme", owner, repo)
    local response_body = {}
    local target = BASE_URL .. path
    local headers = {
        ["Accept"] = "application/vnd.github.html",
        ["User-Agent"] = USER_AGENT,
    }
    local auth_headers = getAuthHeaders()
    if auth_headers then
        for key, value in pairs(auth_headers) do headers[key] = value end
    end
    local target_http_mod = getHttpModule(target)
    local code
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    pcall(function()
        _, code = target_http_mod.request{
            url = target,
            headers = headers,
            sink = newTableSink(response_body),
        }
    end)
    socketutil:reset_timeout()
    local body = table.concat(response_body)
    if tonumber(code) == 200 and body ~= "" then
        
        -- 1. Nuke massive Base64 strings using a fast C-level pattern match
        body = body:gsub('src=["\']data:[^"\']+["\']', 'src=""')
        
        -- 2. Hard-cap HTML length so the Kindle CPU never hangs
        if #body > 80000 then
            body = body:sub(1, 80000) .. "\n\n<p><i>(Readme truncated to prevent device freeze...)</i></p>"
        end

        body = body:gsub('src=["\']([^"\']+)["\']', function(src)
            if not src:find("^https?://") and not src:find("^data:") and owner and repo then
                local clean_src = src:gsub("^%./", "")
                if clean_src:find("^blob/") or clean_src:find("^raw/") then
                    return string.format('src="https://raw.githubusercontent.com/%s/%s/%s"', owner, repo, clean_src:gsub("^blob/", ""):gsub("^raw/", ""))
                else
                    return string.format('src="https://raw.githubusercontent.com/%s/%s/HEAD/%s"', owner, repo, clean_src)
                end
            end
            return string.format('src="%s"', src)
        end)
        return body, nil
    end

    return nil, string.format("HTTP %s", tostring(raw_code or code))
end

GitHubClient.markdownToHtml = markdownToHtml

function GitHubClient.fetchWikiPageRaw(owner, repo, page_name)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    page_name = (page_name and page_name ~= "") and page_name or "Home"
    local clean_page = page_name:gsub("%.md$", "")

    local candidate_pages = {
        clean_page,
        clean_page:gsub("%s+", "-"),
        clean_page:gsub("%s+", "%%20"),
        clean_page:gsub("^(%d+)%s*%.%s*", "%1.-"),
        clean_page:gsub("^(%d+)%s*%.%s*", "%1-"),
        clean_page:gsub("[^%w_%-.]", "-"),
    }

    local seen_pages = {}
    for _, name in ipairs(candidate_pages) do
        if not seen_pages[name] then
            seen_pages[name] = true

            local urls_to_try = {
                string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s.md", owner, repo, name),
                string.format("https://raw.githubusercontent.com/wiki/%s/%s/%s", owner, repo, name),
            }

            for _, wiki_url in ipairs(urls_to_try) do
                local response_body = {}
                local wiki_http_mod = getHttpModule(wiki_url)
                local code
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                pcall(function()
                    _, code = wiki_http_mod.request{
                        url = wiki_url,
                        headers = {
                            ["Accept"] = "text/plain",
                            ["User-Agent"] = USER_AGENT,
                        },
                        sink = newTableSink(response_body),
                    }
                end)
                socketutil:reset_timeout()
                code = tonumber(code)
                local body = table.concat(response_body)
                if code == 200 and body and body ~= "" then
                    return body, nil
                end
            end
        end
    end

    return nil, "HTTP 404: wiki page not found"
end

return GitHubClient
