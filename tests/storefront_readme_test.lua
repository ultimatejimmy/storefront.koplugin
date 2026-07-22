-- storefront_readme_test.lua
-- Unit tests for Storefront README Markdown-to-HTML converter
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

-- Mock dependencies for storefront_net_github loading headlessly
package.loaded["socket.http"] = {}
package.loaded["json"] = {}
package.loaded["socket.url"] = {}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["luasettings"] = { open = function() return { readSetting = function() end, saveSetting = function() end, delSetting = function() end, flush = function() end } end }

local GitHubClient = require("storefront_net_github")

print("=== Running README Markdown-to-HTML Unit Tests ===")

-- Test 1: Heading conversion
local html_h1 = GitHubClient.markdownToHtml("# My Plugin Header")
check("H1 header converted to <h1>", html_h1:find("<h1>My Plugin Header</h1>") ~= nil)
check("H1 header does NOT contain raw markdown '#'", html_h1:find("# My Plugin Header") == nil)

-- Test 2: Sub-headings H2 and H3
local html_h2_h3 = GitHubClient.markdownToHtml("## Installation\n### Requirements")
check("H2 header converted to <h2>", html_h2_h3:find("<h2>Installation</h2>") ~= nil)
check("H3 header converted to <h3>", html_h2_h3:find("<h3>Requirements</h3>") ~= nil)

-- Test 3: Unordered List conversion
local html_list = GitHubClient.markdownToHtml("- Feature 1\n- Feature 2")
check("Unordered list contains <ul>", html_list:find("<ul>") ~= nil)
check("Unordered list contains <li>Feature 1</li>", html_list:find("<li>Feature 1</li>") ~= nil)
check("Unordered list contains <li>Feature 2</li>", html_list:find("<li>Feature 2</li>") ~= nil)

-- Test 4: Bold and Italic formatting
local html_inline = GitHubClient.markdownToHtml("**Bold text** and *Italic text*")
check("Bold text converted to <b>Bold text</b>", html_inline:find("<b>Bold text</b>") ~= nil)
check("Italic text converted to <i>Italic text</i>", html_inline:find("<i>Italic text</i>") ~= nil)

-- Test 5: Links conversion
local html_link = GitHubClient.markdownToHtml("[GitHub Page](https://github.com)")
check("Markdown link converted to <a href=...>", html_link:find('<a href="https://github.com">GitHub Page</a>') ~= nil)

-- Test 6: Code blocks
local html_code = GitHubClient.markdownToHtml("```lua\nlocal x = 1\n```")
check("Code block converted to <pre><code>", html_code:find("<pre><code>") ~= nil)
check("Code block content preserved", html_code:find("local x = 1") ~= nil)

-- Test 8: Images conversion & relative URL resolution
local html_img = GitHubClient.markdownToHtml("![Screenshot](docs/screen.png)", "koreader", "coverbrowser")
check("Markdown image converted to <img src=...>", html_img:find('<img src="https://raw.githubusercontent.com/koreader/coverbrowser/HEAD/docs/screen.png" alt="Screenshot"/>') ~= nil)

-- Test 9: Ensure links do not break image syntax
local html_img_and_link = GitHubClient.markdownToHtml("![Pic](https://example.com/pic.png) [Link](https://example.com)")
check("Image tag created correctly alongside link", html_img_and_link:find('<img src="https://example.com/pic.png" alt="Pic"/>') ~= nil)
check("Link tag created correctly alongside image", html_img_and_link:find('<a href="https://example.com">Link</a>') ~= nil)

-- Test 10: Image modal storefront-img scheme interception
local mock_details_dialog = {
    repo = { name = "TestRepo" },
    onLinkTap = function(self, href)
        if href and type(href) == "string" and href:find("^storefront%-img:") then
            return true
        end
        return false
    end
}
check("storefront-img href is intercepted by onLinkTap", mock_details_dialog:onLinkTap("storefront-img:/cache/readme/test.png") == true)
check("normal HTTP link is NOT intercepted by storefront-img handler", mock_details_dialog:onLinkTap("https://github.com") == false)
local link_obj = { uri = "storefront-img:/cache/readme/test.png" }
local extracted_href = (type(link_obj) == "table" and (link_obj.uri or link_obj.url)) or (type(link_obj) == "string" and link_obj) or ""
check("link object uri extracted correctly", mock_details_dialog:onLinkTap(extracted_href) == true)

if failures > 0 then
    print(string.format("README TESTS FAILED: %d errors", failures))
    os.exit(1)
else
    print("ALL README TESTS PASSED")
end
