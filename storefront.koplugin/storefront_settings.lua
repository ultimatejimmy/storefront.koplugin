--- storefront_settings.lua
--- Centralized settings provider for Storefront.
--- Ensures a single shared LuaSettings instance across all Storefront modules
--- so multiple modules do not clobber each other's settings on flush.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local _settings = nil

local StorefrontSettings = {}

local function getSettingsPath()
    local ok, dir = pcall(function() return DataStorage:getSettingsDir() end)
    if not ok or not dir then
        dir = "./settings"
    end
    return dir .. "/Storefront.lua"
end

function StorefrontSettings.getSettings()
    if not _settings then
        _settings = LuaSettings:open(getSettingsPath())
    end
    return _settings
end

function StorefrontSettings:readSetting(key, default)
    return StorefrontSettings.getSettings():readSetting(key, default)
end

function StorefrontSettings:saveSetting(key, value)
    return StorefrontSettings.getSettings():saveSetting(key, value)
end

function StorefrontSettings:delSetting(key)
    local s = StorefrontSettings.getSettings()
    if s.delSetting then
        return s:delSetting(key)
    else
        return s:saveSetting(key, nil)
    end
end

function StorefrontSettings:has(key)
    local s = StorefrontSettings.getSettings()
    if s.has then
        return s:has(key)
    end
    return s:readSetting(key) ~= nil
end

function StorefrontSettings:hasNot(key)
    local s = StorefrontSettings.getSettings()
    if s.hasNot then
        return s:hasNot(key)
    end
    return not StorefrontSettings:has(key)
end

function StorefrontSettings:isTrue(key)
    local s = StorefrontSettings.getSettings()
    if s.isTrue then
        return s:isTrue(key)
    end
    return s:readSetting(key) == true
end

function StorefrontSettings:isFalse(key)
    local s = StorefrontSettings.getSettings()
    if s.isFalse then
        return s:isFalse(key)
    end
    return s:readSetting(key) == false
end

function StorefrontSettings:nilOrTrue(key)
    local s = StorefrontSettings.getSettings()
    if s.nilOrTrue then
        return s:nilOrTrue(key)
    end
    return StorefrontSettings:hasNot(key) or StorefrontSettings:isTrue(key)
end

function StorefrontSettings:nilOrFalse(key)
    local s = StorefrontSettings.getSettings()
    if s.nilOrFalse then
        return s:nilOrFalse(key)
    end
    return StorefrontSettings:hasNot(key) or StorefrontSettings:isFalse(key)
end

function StorefrontSettings:flush()
    return StorefrontSettings.getSettings():flush()
end

function StorefrontSettings:close()
    return StorefrontSettings.getSettings():close()
end

function StorefrontSettings.reset(new_settings)
    _settings = new_settings
end

-- Metatable fallback to forward any other methods or direct property accesses (.data, etc.)
-- to the underlying LuaSettings instance.
setmetatable(StorefrontSettings, {
    __index = function(_, k)
        local inst = StorefrontSettings.getSettings()
        local val = inst[k]
        if type(val) == "function" then
            return function(self, ...)
                if self == StorefrontSettings then
                    return val(inst, ...)
                else
                    return val(self, ...)
                end
            end
        end
        return val
    end,
    __newindex = function(_, k, v)
        local inst = StorefrontSettings.getSettings()
        inst[k] = v
    end,
})

return StorefrontSettings
