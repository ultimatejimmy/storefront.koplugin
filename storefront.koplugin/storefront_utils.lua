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

function storefront_utils.isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    v1_str = tostring(v1_str):gsub("^[vV]", "")
    v2_str = tostring(v2_str):gsub("^[vV]", "")
    if v1_str == v2_str then
        return false
    end

    local function normalizeVersion(v_str)
        local parts = {}
        for part in tostring(v_str):gmatch("([^.-]+)") do
            local num = tonumber(part)
            if num then
                table.insert(parts, num)
            else
                table.insert(parts, 0)
            end
        end
        return parts
    end

    local v1 = normalizeVersion(v1_str)
    local v2 = normalizeVersion(v2_str)
    local max_len = math.max(#v1, #v2)
    for i = 1, max_len do
        local a = v1[i] or 0
        local b = v2[i] or 0
        if a > b then
            return true
        end
        if a < b then
            return false
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

return storefront_utils
