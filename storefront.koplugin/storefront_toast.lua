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
    local text = ""
    local timeout = nil

    -- Handle colon invocation syntax (StorefrontToast:new(...) / InfoMessage:new(...))
    if opts_or_text == StorefrontToast or (type(opts_or_text) == "table" and opts_or_text.new == StorefrontToast.new) then
        opts_or_text = timeout_arg
        timeout_arg = nil
    end

    if type(opts_or_text) == "table" then
        text = opts_or_text.text or ""
        timeout = opts_or_text.timeout
    elseif type(opts_or_text) == "string" then
        text = opts_or_text
        timeout = timeout_arg
    end
    return InfoMessage:new{
        text = text or "",
        timeout = timeout or 3,
    }
end

return StorefrontToast
