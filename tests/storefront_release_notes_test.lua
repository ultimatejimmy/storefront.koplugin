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
package.loaded["json"] = {}
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

if failures > 0 then
    print(string.format("RELEASE NOTES TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("ALL RELEASE NOTES TESTS PASSED")
end
