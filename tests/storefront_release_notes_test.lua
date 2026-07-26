-- storefront_release_notes_test.lua
-- Unit tests for Storefront Release Notes functionality
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label)
    end
end

-- Mock dependencies for headless testing
package.loaded["socket.http"] = {}
local json_null_sentinel = setmetatable({}, { __tostring = function() return "null" end })
package.loaded["json"] = { null = json_null_sentinel }
package.loaded["socket.url"] = {}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end }
package.loaded["luasettings"] = { open = function() return { readSetting = function() end, saveSetting = function() end, delSetting = function() end, flush = function() end } end }
package.loaded["gettext"] = function(s) return s end
local ok_lfs, lfs_mod = pcall(require, "lfs")
package.loaded["libs/libkoreader-lfs"] = ok_lfs and lfs_mod or { attributes = function() return nil end, dir = function() return function() return nil end end }
package.loaded["ui/uimanager"] = { show = function() end, close = function() end, setDirty = function() end }
package.loaded["ui/widget/infomessage"] = {}
package.loaded["apps/filemanager/filemanager"] = {}

local util = {}
util.makePath = function(path) return true end
util.writeToFile = function(content, path)
    util.last_written = content
    util.last_path = path
    return true
end
util.readFromFile = function(path) return util.last_written end

package.loaded["util"] = util

local GitHubClient = require("storefront_net_github")
local RepoContent = require("storefront_repo_content")

print("=== Running Release Notes Unit Tests ===")

local mock_repo = {
    name = "myplugin",
    owner = "testowner",
    latest_release = {
        tag_name = "v1.2.0",
        name = "v1.2.0 Great Release",
        published_at = "2026-07-22T12:00:00Z",
        body = "### What's Changed\n- Added cool feature A\n- Fixed bug B"
    }
}

package.loaded["storefront_cache"] = {
    init = function() end,
    getRepoByName = function(owner, name)
        if owner == "testowner" and name == "myplugin" then
            return mock_repo
        end
        return nil
    end
}

local ok, path = RepoContent.fetchReleaseNotesHtml("testowner", "myplugin")
check("fetchReleaseNotesHtml returned success", ok == true)
check("Release notes HTML path generated", path:find("testowner_myplugin_RELEASENOTES.html") ~= nil)

local html = util.last_written or ""
check("HTML contains release title", html:find("v1.2.0 Great Release") ~= nil or html:find("v1.2.0") ~= nil)
check("HTML contains published date", html:find("2026-07-22", 1, true) ~= nil)
check("Markdown body H3 converted to <h3>", html:find("<h3>What's Changed</h3>") ~= nil)
check("List item converted to <li>Added cool feature A</li>", html:find("<li>Added cool feature A</li>") ~= nil)

-- Test 2: Fallback when body is empty
local mock_empty_repo = {
    name = "emptyrepo",
    owner = "testowner",
    latest_release = {
        tag_name = "v1.0.0",
        published_at = "2026-01-01T00:00:00Z",
        body = ""
    }
}
-- Mock GitHubClient.fetchLatestRelease returning no body
GitHubClient.fetchLatestRelease = function(owner, repo)
    return { tag_name = "v1.0.0", published_at = "2026-01-01T00:00:00Z", body = "" }
end

local ok_empty, path_empty = RepoContent.fetchReleaseNotesHtml("testowner", "emptyrepo")
check("Empty body fetch returns success", ok_empty == true)
local html_empty = util.last_written or ""
check("Fallback text displayed for empty release notes", html_empty:find("No detailed release notes provided") ~= nil)

-- Test 3: json.null sentinel table in release notes body (zlibrary.koplugin scenario)
local json_null_repo = {
    name = "zlibrary",
    owner = "testowner",
    latest_release = {
        tag_name = "v2.0.0",
        name = json_null_sentinel,
        published_at = json_null_sentinel,
        body = json_null_sentinel
    }
}
GitHubClient.fetchLatestRelease = function(owner, repo)
    return { tag_name = "v2.0.0", name = json_null_sentinel, published_at = json_null_sentinel, body = json_null_sentinel }
end

local ok_null, path_null
local test_null_pass, err_msg = pcall(function()
    ok_null, path_null = RepoContent.fetchReleaseNotesHtml("testowner", "zlibrary", json_null_repo.latest_release)
end)

check("json.null body handled without fatal error", test_null_pass == true)
check("json.null fetch returned success", ok_null == true)
local html_null = util.last_written or ""
check("Fallback text displayed when body is json.null", html_null:find("No detailed release notes provided") ~= nil)

-- Test 4: markdownToHtml with json.null
local md_html_res = GitHubClient.markdownToHtml(json_null_sentinel, "testowner", "zlibrary")
check("markdownToHtml handles json.null without crashing", md_html_res:find("No release notes") ~= nil)

-- Test 5: stripMarkdown with json.null
local stripped = RepoContent.stripMarkdown(json_null_sentinel)
check("stripMarkdown handles json.null without crashing", stripped == "")

-- Test 6: Percent-encoded URLs in markdown links
local md_percent_link = "[Release Tag v1.0](https://github.com/foo/bar/releases/tag/v1.0%20beta%2Ftest)"
local res_percent_pass, res_percent_html = pcall(function()
    return GitHubClient.markdownToHtml(md_percent_link, "foo", "bar")
end)
check("Markdown URL with '%' does not crash gsub", res_percent_pass == true)
check("Percent-encoded link converted properly", res_percent_html and res_percent_html:find('href="https://github.com/foo/bar/releases/tag/v1.0%20beta%2Ftest"', 1, true) ~= nil)

-- Test 7: Named HTML entities conversion
local md_entities = "Notes with&nbsp;space and&mdash;dash and&rsquo;quote"
local html_entities = GitHubClient.markdownToHtml(md_entities, "foo", "bar")
check("Named HTML entity &nbsp; converted", html_entities:find("Notes with space") ~= nil)
check("Named HTML entity &mdash; converted", html_entities:find("—") ~= nil)
check("Named HTML entity &rsquo; converted", html_entities:find("’") ~= nil)

-- Test 8: Complex raw HTML tags & comments
local md_raw_html = "<!-- comment -->\n<details><summary>Click Me</summary>Some text</details>"
local html_raw = GitHubClient.markdownToHtml(md_raw_html, "foo", "bar")
check("HTML comment stripped", html_raw:find("comment") == nil)
check("raw <details> converted to <div>", html_raw:find("<div>") ~= nil)

-- Test 9: Non-table rel_data (boolean, number, json.null)
local pass_bool, ok_bool = pcall(function()
    return RepoContent.fetchReleaseNotesHtml("testowner", "myplugin", true)
end)
check("Boolean rel_data handled safely without crash", pass_bool == true and ok_bool == true)

local pass_num, ok_num = pcall(function()
    return RepoContent.fetchReleaseNotesHtml("testowner", "myplugin", 12345)
end)
check("Number rel_data handled safely without crash", pass_num == true and ok_num == true)

-- Test 10: Truncation of huge release notes
local huge_md = string.rep("Long line of release note text.\n", 2000)
local html_huge = GitHubClient.markdownToHtml(huge_md, "foo", "bar")
check("Huge release notes body truncated", html_huge:find("Release notes truncated") ~= nil)

if failures > 0 then
    print(string.format("RELEASE NOTES TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("ALL RELEASE NOTES TESTS PASSED")
end
