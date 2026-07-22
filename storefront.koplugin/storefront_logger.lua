-- storefront_logger.lua
-- Dedicated logging utility for Storefront plugin troubleshooting

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Logger = {
    max_size = 512 * 1024, -- 512 KB
}

local write_count = 0

local function getLogFilePath()
    local dir = DataStorage:getDataDir() .. "/plugins/storefront.koplugin"
    local attr = lfs.attributes(dir, "mode")
    if attr ~= "directory" then
        dir = DataStorage:getSettingsDir()
    end
    return dir .. "/storefront.log"
end

local function writeLog(level, msg)
    pcall(function()
        local path = getLogFilePath()
        write_count = write_count + 1
        if write_count >= 50 then
            write_count = 0
            local f_size = io.open(path, "r")
            if f_size then
                local current_size = f_size:seek("end")
                f_size:close()
                if current_size > Logger.max_size then
                    os.remove(path .. ".old")
                    os.rename(path, path .. ".old")
                end
            end
        end

        local f = io.open(path, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. level .. "] " .. tostring(msg) .. "\n")
            f:close()
        end
    end)
end

function Logger.log(msg)
    writeLog("INFO", msg)
end

function Logger.info(msg)
    writeLog("INFO", msg)
end

function Logger.action(msg)
    writeLog("ACTION", msg)
end

function Logger.warn(msg)
    writeLog("WARN", msg)
end

function Logger.err(msg)
    writeLog("ERROR", msg)
end

function Logger.startSession()
    pcall(function()
        local path = getLogFilePath()
        local f = io.open(path, "a")
        if f then
            f:write("\n" .. string.rep("=", 40) .. "\n")
            f:write("--- Storefront Session Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ---\n")
            f:close()
        end
    end)
end

function Logger.reset()
    Logger.startSession()
end

function Logger.clear()
    pcall(function()
        local path = getLogFilePath()
        os.remove(path)
        os.remove(path .. ".old")
    end)
end

return Logger
