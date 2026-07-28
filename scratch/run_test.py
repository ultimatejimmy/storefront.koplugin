import subprocess

cmd = '''cd /mnt/c/Users/jpautz/squashfs-root/usr/lib/koreader && env SQUASHFS_ROOT=/mnt/c/Users/jpautz/squashfs-root LUA_PATH="/home/jpautz/.config/koreader/plugins/storefront.koplugin/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;" LUA_CPATH="./?.so;libs/?.so;lib/?.so;common/?.so;;" ./luajit /mnt/c/Users/jpautz/Documents/storefront/storefront.koplugin/scratch/test_all_fonts_details.lua'''

res = subprocess.run(["wsl", "bash", "-c", cmd], capture_output=True, text=True)
print("STDOUT:")
print(res.stdout)
print("STDERR:")
print(res.stderr)
