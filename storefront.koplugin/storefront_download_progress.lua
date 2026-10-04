--- Download progress for Storefront installs.
--- Downloads run in a subprocess (Trapper), which can only report its final
--- result. While it runs, the parent polls the size of the partial file
--- downloadToFile() writes and shows it on the trap widget.
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local DownloadProgress = {}

---@param bytes number
---@return string
local function formatMB(bytes)
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

--- Start polling local_path and updating widget once per second.
---@param widget table|nil Toast with setText (and optionally setProgress)
---@param dl_msg string Message shown on the widget; progress goes after its first line
---@param local_path string Final path passed to downloadToFile
---@param total_bytes number|nil Expected size; nil or 0 shows downloaded MB only
---@return function stop Stops polling and clears the progress bar
function DownloadProgress.start(widget, dl_msg, local_path, total_bytes)
    if not widget or not widget.setText then
        return function() end
    end
    if not total_bytes or total_bytes <= 0 then
        total_bytes = nil
    end
    local head, tail = dl_msg:match("^(.-)\n(.*)$")
    head = head or dl_msg
    local active = true
    local in_poll = false
    local last_size = -1

    local function currentSize()
        local ok, size = pcall(function()
            return lfs.attributes(local_path .. ".tmp", "size")
                or lfs.attributes(local_path, "size")
        end)
        return ok and tonumber(size) or 0
    end

    local poll
    poll = function()
        -- in_poll guards against schedulers that run the callback synchronously
        if not active or in_poll then return end
        if UIManager.isShown and not UIManager:isShown(widget) then
            active = false
            return
        end
        in_poll = true
        local size = currentSize()
        if size ~= last_size then
            last_size = size
            local line, fraction
            if total_bytes then
                fraction = math.min(size / total_bytes, 1)
                line = string.format("%s / %s (%d%%)", formatMB(size), formatMB(total_bytes), math.floor(fraction * 100))
            else
                line = formatMB(size)
            end
            local text = head .. "\n" .. line .. (tail and ("\n" .. tail) or "")
            if fraction and widget.setProgress then
                widget:setProgress(fraction, text)
            else
                widget:setText(text)
            end
        end
        UIManager:scheduleIn(1, poll)
        in_poll = false
    end
    UIManager:scheduleIn(1, poll)

    return function()
        active = false
        if UIManager.unschedule then
            UIManager:unschedule(poll)
        end
        if widget.progress then
            widget.progress = nil
            widget._force_rebuild = true
        end
    end
end

return DownloadProgress
