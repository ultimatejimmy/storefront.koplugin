local storefront_utils = {}

function storefront_utils.softWrapLongTokens(text, max_len)
    max_len = tonumber(max_len) or 60
    if not text or text == "" then
        return ""
    end
    text = tostring(text)
    return text:gsub("(%S+)", function(token)
        if #token <= max_len then
            return token
        end
        if token:match("[\128-\255]") then
            return token
        end
        local parts = {}
        local i = 1
        while i <= #token do
            parts[#parts + 1] = token:sub(i, i + max_len - 1)
            i = i + max_len
        end
        return table.concat(parts, "\n")
    end)
end

function storefront_utils.normalizeMetaPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = path:gsub("^/+", "")
    if normalized == "_meta.lua" then
        return normalized
    end
    if normalized:match("/_meta%.lua$") then
        return normalized
    end
    if not normalized:match("%.koplugin$") then
        normalized = normalized .. ".koplugin"
    end
    return normalized .. "/_meta.lua"
end

function storefront_utils.sanitizeMetaPath(path, fallback)
    if path and path ~= "" then
        local normalized = storefront_utils.normalizeMetaPath(path)
        if normalized then
            return normalized
        end
    end
    if fallback and fallback ~= "" then
        return storefront_utils.normalizeMetaPath(fallback)
    end
end

function storefront_utils.firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
end

local function parseVersionDescriptor(v_str)
    v_str = tostring(v_str):gsub("^[vV]", "")
    local main_str, pre_str = v_str:match("^([%d%.]+)%-?(.*)$")
    if not main_str or main_str == "" then
        main_str = v_str
        pre_str = ""
    end

    local nums = {}
    for part in main_str:gmatch("%d+") do
        table.insert(nums, tonumber(part) or 0)
    end

    local pre_info = nil
    if pre_str and pre_str ~= "" then
        local pre_type, pre_num = pre_str:match("^([a-zA-Z]+)(%d*)$")
        if not pre_type then
            pre_type = pre_str
            pre_num = "0"
        end
        local ranks = {
            dev = 1,
            alpha = 2,
            beta = 3,
            preview = 4,
            rc = 5,
        }
        pre_info = {
            type_rank = ranks[pre_type:lower()] or 0,
            type_name = pre_type:lower(),
            num = tonumber(pre_num) or 0,
        }
    end

    return {
        nums = nums,
        pre = pre_info,
    }
end

function storefront_utils.isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    v1_str = tostring(v1_str):gsub("^[vV]", "")
    v2_str = tostring(v2_str):gsub("^[vV]", "")
    if v1_str == v2_str then
        return false
    end

    local d1 = parseVersionDescriptor(v1_str)
    local d2 = parseVersionDescriptor(v2_str)

    local max_len = math.max(#d1.nums, #d2.nums)
    for i = 1, max_len do
        local a = d1.nums[i] or 0
        local b = d2.nums[i] or 0
        if a > b then
            return true
        end
        if a < b then
            return false
        end
    end

    if not d1.pre and d2.pre then
        return true
    end
    if d1.pre and not d2.pre then
        return false
    end

    if d1.pre and d2.pre then
        if d1.pre.type_rank ~= d2.pre.type_rank then
            return d1.pre.type_rank > d2.pre.type_rank
        end
        if d1.pre.type_name ~= d2.pre.type_name then
            return d1.pre.type_name > d2.pre.type_name
        end
        if d1.pre.num ~= d2.pre.num then
            return d1.pre.num > d2.pre.num
        end
    end

    return false
end

function storefront_utils.normalizeDescription(value)
    if type(value) ~= "string" then
        return ""
    end
    if value:match("^function:%s*0x%x+$") then
        return ""
    end
    return value
end

function storefront_utils.parseGitHubTimestamp(value)
    if type(value) ~= "string" then
        return 0
    end
    local year, month, day, hour, min, sec = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return 0
    end
    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    }) or 0
end

function storefront_utils.repoStarsValue(repo)
    if type(repo) ~= "table" then return 0 end
    local s = tonumber(repo.stars)
    if s and s > 0 then return s end
    if repo.data then
        s = tonumber(repo.data.stargazers_count) or tonumber(repo.data.stars)
        if s and s > 0 then return s end
    end
    return s or 0
end

function storefront_utils.repoIsFork(repo)
    if type(repo) ~= "table" then return false end
    if repo.fork ~= nil then return repo.fork == true end
    if repo.data and repo.data.fork ~= nil then return repo.data.fork == true end
    return false
end

function storefront_utils.getMappedScreensaverCategories(cat_str)
    if not cat_str or cat_str == "" then
        return { "Fine Art" }
    end
    local result = {}
    local seen = {}
    for part in string.gmatch(tostring(cat_str), "[^,]+") do
        local c = part:match("^%s*(.-)%s*$"):lower()
        local mapped = nil
        if c:find("transparent") or c:find("overlay") then
            mapped = "Transparent"
        elseif c:find("space") or c:find("astronomy") or c:find("sci") then
            mapped = "Sci-Fi"
        elseif c:find("nature") or c:find("landscape") then
            mapped = "Nature"
        elseif c:find("pop") or c:find("culture") then
            mapped = "Pop Culture"
        elseif c:find("cozy") or c:find("minimal") then
            mapped = "Minimalist"
        elseif c:find("abstract") or c:find("dark") then
            mapped = "Abstract"
        elseif c:find("anime") then
            mapped = "Anime"
        elseif c:find("architect") or c:find("miniature") then
            mapped = "Architecture"
        elseif c:find("fantasy") then
            mapped = "Fantasy"
        elseif c:find("quote") then
            mapped = "Quotes"
        elseif c:find("art") or c:find("ceramic") or c:find("drawing") or c:find("paint") or c:find("print") or c:find("sculpture") or c:find("installation") or c:find("funerary") then
            mapped = "Fine Art"
        else
            local clean = part:match("^%s*(.-)%s*$")
            if clean ~= "" then
                mapped = clean:sub(1,1):upper() .. clean:sub(2):lower()
            else
                mapped = "Fine Art"
            end
        end
        if mapped and not seen[mapped:lower()] then
            seen[mapped:lower()] = true
            table.insert(result, mapped)
        end
    end
    if #result == 0 then table.insert(result, "Fine Art") end
    return result
end

return storefront_utils

