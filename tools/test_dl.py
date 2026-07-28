import subprocess

lua_script = """
local ok_h, https = pcall(require, "ssl.https")
local http = ok_h and https or require("socket.http")

local response_body = {}
local headers = {
    ["Accept"] = "application/json",
    ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-Storefront/1.0)",
}

local res, code, headers_out = http.request{
    url = "https://ultimatejimmy.github.io/storefront.koplugin/catalog.json",
    method = "GET",
    headers = headers,
    sink = function(chunk, err)
        if chunk then table.insert(response_body, chunk) end
        return 1
    end
}

print("res:", res, "code:", code)
if type(headers_out) == "table" then
    for k, v in pairs(headers_out) do print("Header:", k, v) end
end
print("Body length:", #table.concat(response_body))
"""

cmd = f"""
cat << 'EOF' > /tmp/test_dl.lua
{lua_script}
EOF
cd /mnt/c/Users/jpautz/squashfs-root/usr/lib/koreader && ./luajit -e '
package.path = "./common/?.lua;./frontend/?.lua;./frontend/ui/?.lua;./frontend/ui/widget/?.lua;./?.lua;" .. package.path
package.cpath = "./libs/?.so;./?.so;" .. package.cpath
dofile("/tmp/test_dl.lua")
'
"""

res = subprocess.run(["wsl", "bash", "-c", cmd], capture_output=True, text=True)
print("STDOUT:", res.stdout)
print("STDERR:", res.stderr)
