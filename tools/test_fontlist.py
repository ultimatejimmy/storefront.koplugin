import subprocess

cmd = """
cd /mnt/c/Users/jpautz/squashfs-root/usr/lib/koreader && ./luajit -e '
package.path = "./frontend/?.lua;./frontend/ui/?.lua;./frontend/ui/widget/?.lua;" .. package.path
local DataStorage = require("datastorage")
local FontList = require("fontlist")
print("FontList.fontdir:", FontList.fontdir)
print("DataStorage data dir:", DataStorage:getDataDir())
local fonts = FontList:getFontList()
print("Total fonts in FontList:", #fonts)
for i, f in ipairs(fonts) do
    if i <= 5 or f:find("Libron") or f:find("Jost") or f:find("storefront") then
        print(i, f)
    end
end
'
"""

res = subprocess.run(["wsl", "bash", "-c", cmd], capture_output=True, text=True)
print("STDOUT:\n", res.stdout)
print("STDERR:\n", res.stderr)
