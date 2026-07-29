-- storefront_font_test.lua
-- Unit tests for Storefront Font Installation, Sync Queue & InstallStore logic
package.path = "plugins/storefront.koplugin/?.lua;storefront.koplugin/?.lua;../?.lua;?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label)
    end
    io.stdout:flush()
end

-- Mock dependencies for headless testing
package.loaded["socket.http"] = {}
package.loaded["ssl.https"] = {}

local ok_json, real_json = pcall(require, "json")
if not ok_json or not real_json or type(real_json.decode) ~= "function" then
    -- Simple JSON mock for unit testing InstallStore serialization
    local json_mock = {}
    function json_mock.encode(tbl)
        if type(tbl) ~= "table" then return "{}" end
        local items = {}
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                table.insert(items, string.format("%q:%s", k, json_mock.encode(v)))
            elseif type(v) == "boolean" then
                table.insert(items, string.format("%q:%s", k, tostring(v)))
            elseif type(v) == "number" then
                table.insert(items, string.format("%q:%d", k, v))
            else
                table.insert(items, string.format("%q:%q", k, tostring(v)))
            end
        end
        return "{" .. table.concat(items, ",") .. "}"
    end

    function json_mock.decode(str)
        if not str or str == "" or str == "{}" then return {} end
        -- Basic mock deserialization for test records
        local res = { plugins = {}, patches = {}, fonts = {}, item_options = {} }
        if str:find("lora") then
            local is_pending = str:find('"pending_download":true') ~= nil
            local is_full = str:find('"full_installed":true') ~= nil
            res.fonts["lora"] = {
                font_name = "Lora",
                owner = "cyrealtype",
                pending_download = is_pending,
                full_installed = is_full,
                download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip"
            }
        end
        return res
    end
    package.loaded["json"] = json_mock
end

package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end }

local memory_store = {}
package.loaded["luasettings"] = {
    open = function()
        return {
            readSetting = function(self, k) return memory_store[k] end,
            saveSetting = function(self, k, v) memory_store[k] = v end,
            delSetting = function(self, k) memory_store[k] = nil end,
            flush = function() end,
        }
    end
}
package.loaded["gettext"] = function(s) return s end

print("=== Running Font System Unit Tests ===")

local InstallStore = require("storefront_installs")

-- Test 1: Font Upsert with pending_download & download_url
local ok_upsert = InstallStore.upsertFont("lora", {
    font_name = "Lora",
    owner = "cyrealtype",
    pending_download = true,
    download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip",
    full_installed = false,
})
check("InstallStore.upsertFont succeeds", ok_upsert == true)

local font_list = InstallStore.listFonts()
check("InstallStore.listFonts contains Lora", font_list and font_list["lora"] ~= nil)
check("Lora pending_download flag is true", font_list and font_list["lora"] and font_list["lora"].pending_download == true)
check("Lora download_url stored correctly", font_list and font_list["lora"] and font_list["lora"].download_url and font_list["lora"].download_url:find("Lora.zip", 1, true) ~= nil)

-- Test 2: Font Upsert update to full_installed
InstallStore.upsertFont("lora", {
    font_name = "Lora",
    owner = "cyrealtype",
    pending_download = false,
    download_url = "https://ultimatejimmy.github.io/fonts/Lora.zip",
    full_installed = true,
})
local font_list2 = InstallStore.listFonts()
check("Lora pending_download updated to false", font_list2 and font_list2["lora"] and font_list2["lora"].pending_download == false)
check("Lora full_installed updated to true", font_list2 and font_list2["lora"] and font_list2["lora"].full_installed == true)

-- Test 3: Font Removal
InstallStore.removeFont("lora")
local font_list3 = InstallStore.listFonts()
check("Lora font removed successfully", font_list3 and font_list3["lora"] == nil)

print("=== Font System Unit Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
