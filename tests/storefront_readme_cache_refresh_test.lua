-- storefront_readme_cache_refresh_test.lua
-- Unit tests for Storefront README, Wiki, and Release Notes cache change detection and conditional refresh
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label)
    end
    io.stdout:flush()
end

local spec_helper = require("tests/spec_helper")

-- Mock KOReader environment
local mock_files = {}
local mock_http_responses = {}

local mock_lfs = {
    attributes = function(path, key)
        if mock_files[path] then
            local data = {
                mode = "file",
                size = #mock_files[path],
                modification = os.time(),
            }
            if key then return data[key] else return data end
        end
        return nil
    end,
    dir = function()
        return function() return nil end
    end,
    rmdir = function() return true end,
}

local mock_datastorage = {
    getDataDir = function() return "/tmp/test_cache_storefront" end,
    getSettingsDir = function() return "/tmp/test_cache_storefront" end,
}

local mock_util = {
    makePath = function() return true end,
    writeToFile = function(content, path)
        mock_files[path] = content
        return true
    end,
    readFromFile = function(path)
        return mock_files[path]
    end,
}

local mock_logger = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
    err = function() end,
}

local mock_socket_http = {
    request = function(params)
        local url = params.url
        local sink = params.sink
        local req_headers = params.headers or {}

        local resp = mock_http_responses[url] or { code = 404, body = "", headers = {} }
        
        -- Check conditional headers
        if req_headers["If-None-Match"] and resp.etag and req_headers["If-None-Match"] == resp.etag then
            return 1, 304, resp.headers or { etag = resp.etag }
        end

        if sink and resp.body then
            sink(resp.body)
        end
        return 1, resp.code or 200, resp.headers or { etag = resp.etag }
    end
}

-- Simple in-memory table store for index in tests so JSON encoding/decoding never fails
local json_module = require("json")
local mock_json = {
    encode = function(tbl)
        local function enc(v)
            if type(v) == "table" then
                local parts = {}
                for k, val in pairs(v) do
                    table.insert(parts, string.format("%q:%s", tostring(k), enc(val)))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            elseif type(v) == "string" then
                return string.format("%q", v)
            elseif type(v) == "number" or type(v) == "boolean" then
                return tostring(v)
            else
                return "null"
            end
        end
        return enc(tbl)
    end,
    decode = function(str)
        if json_module and type(json_module.decode) == "function" then
            local ok, res = pcall(json_module.decode, str)
            if ok and res then return res end
        end
        return {}
    end,
    null = {},
}

package.loaded["libs/libkoreader-lfs"] = mock_lfs
package.loaded["datastorage"] = mock_datastorage
package.loaded["util"] = mock_util
package.loaded["logger"] = mock_logger
package.loaded["socket"] = {}
package.loaded["socket.url"] = { escape = function(s) return s end, unescape = function(s) return s end }
package.loaded["socket.http"] = mock_socket_http
package.loaded["ssl.https"] = mock_socket_http
package.loaded["ltn12"] = { sink = { table = function(t) return function(chunk) if chunk then table.insert(t, chunk) end return 1 end end } }
package.loaded["json"] = mock_json
package.loaded["luasettings"] = { open = function() return { readSetting = function() end, saveSetting = function() end, delSetting = function() end, flush = function() end } end }
package.loaded["storefront_config"] = {}
package.loaded["storefront_cache"] = {
    init = function() end,
    getRepoByName = function() return nil end,
    listRepos = function() return {} end,
    countRepos = function() return 0 end,
    getLastFetched = function() return 0 end,
}
package.loaded["gettext"] = function(s) return s end
package.loaded["localization_storefront"] = { t = function(self, s) return s end }

local GitHubClient = require("storefront_net_github")
local RepoContent = require("storefront_repo_content")

print("=== Running README & Cache Refresh Unit Tests ===")

-- Test 1: GitHubClient.fetchReadmeRaw conditional request with ETag
local raw_url = "https://raw.githubusercontent.com/testowner/testrepo/HEAD/README.md"
mock_http_responses[raw_url] = {
    code = 200,
    body = "# Hello World\nInitial README content.",
    etag = "\"etag_initial\"",
    headers = { etag = "\"etag_initial\"" },
}

local raw_md, err, res_etag, is_mod, code = GitHubClient.fetchReadmeRaw("testowner", "testrepo", nil)
check("fetchReadmeRaw fetches initial content", code == 200 and raw_md:find("Hello World") ~= nil)
check("fetchReadmeRaw returns ETag", res_etag == "\"etag_initial\"")
check("fetchReadmeRaw marks as modified", is_mod == true)

-- Test 2: GitHubClient.fetchReadmeRaw returns 304 when ETag matches
local raw_md_304, err_304, res_etag_304, is_mod_304, code_304 = GitHubClient.fetchReadmeRaw("testowner", "testrepo", "\"etag_initial\"")
check("fetchReadmeRaw returns 304 on matching ETag", code_304 == 304)
check("fetchReadmeRaw marks modified as false on 304", is_mod_304 == false)

-- Test 3: GitHubClient.fetchReadmeHtml returns modified=false on 304
local html_body, html_err, html_etag, html_mod = GitHubClient.fetchReadmeHtml("testowner", "testrepo", "\"etag_initial\"")
check("fetchReadmeHtml returns modified=false on 304", html_mod == false)

-- Test 4: RepoContent.fetchReadmeHtml initial caching
local ok, path, has_changed = RepoContent.fetchReadmeHtml("testowner", "testrepo", false)
check("RepoContent.fetchReadmeHtml initial download succeeds", ok == true)
check("RepoContent.fetchReadmeHtml marks initial load as changed", has_changed == true)
check("Cached HTML exists in mock storage", mock_files[path] ~= nil)

-- Test 5: RepoContent.fetchReadmeHtml on-demand re-check with unchanged remote
local ok2, path2, has_changed2 = RepoContent.fetchReadmeHtml("testowner", "testrepo", false)
check("RepoContent.fetchReadmeHtml re-check succeeds", ok2 == true)
check("RepoContent.fetchReadmeHtml marks unchanged content as has_changed = false", has_changed2 == false)

-- Test 6: RepoContent.fetchReadmeHtml when remote README changes
mock_http_responses[raw_url] = {
    code = 200,
    body = "# Hello World\nUpdated README content with new features!",
    etag = "\"etag_v2\"",
    headers = { etag = "\"etag_v2\"" },
}

local ok3, path3, has_changed3 = RepoContent.fetchReadmeHtml("testowner", "testrepo", false)
check("RepoContent.fetchReadmeHtml detects remote modification", has_changed3 == true)
check("Updated cached HTML contains new content", mock_files[path3]:find("Updated README content") ~= nil)

-- Test 7: Release notes caching and change detection
local release_v1 = {
    tag_name = "v1.0.0",
    name = "Release 1.0.0",
    published_at = "2026-08-01T00:00:00Z",
    body = "Initial release notes.",
}
local r_ok, r_path, r_changed = RepoContent.fetchReleaseNotesHtml("testowner", "testrepo", release_v1, false)
check("Release notes initial generation succeeds", r_ok == true and r_changed == true)

local r_ok2, r_path2, r_changed2 = RepoContent.fetchReleaseNotesHtml("testowner", "testrepo", release_v1, false)
check("Release notes with unchanged tag/published_at returns has_changed = false", r_changed2 == false)

local release_v2 = {
    tag_name = "v1.1.0",
    name = "v1.1.0",
    published_at = "2026-08-10T00:00:00Z",
    body = "New version release notes.",
}
local r_ok3, r_path3, r_changed3 = RepoContent.fetchReleaseNotesHtml("testowner", "testrepo", release_v2, false)
check("Release notes with new tag returns has_changed = true", r_changed3 == true)
check("Updated release notes HTML contains new tag", mock_files[r_path3]:find("1.1.0") ~= nil)

-- Test 8: Cache clearing cleans files and index
local clear_res = RepoContent.clearReadmeCache()
check("clearReadmeCache runs without error", clear_res ~= nil)

if failures > 0 then
    print(string.format("\nFAILED: %d tests failed.", failures))
    os.exit(1)
else
    print("\nALL CACHE REFRESH & CHANGE DETECTION TESTS PASSED!")
end
