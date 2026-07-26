local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local StorefrontToast = {}

function StorefrontToast.show(text, timeout)
    local msg = InfoMessage:new{
        text = text or "",
        timeout = timeout or 3,
    }
    UIManager:show(msg)
    return msg
end

function StorefrontToast.new(opts_or_text, timeout_arg)
    local text = opts_or_text
    local timeout = timeout_arg
    if type(opts_or_text) == "table" then
        text = opts_or_text.text or ""
        timeout = opts_or_text.timeout
    end
    return InfoMessage:new{
        text = text or "",
        timeout = timeout or 3,
    }
end

return StorefrontToast
