#!/bin/bash
LUAJIT=$(which luajit || echo "/mnt/c/Users/jpautz/squashfs-root/usr/lib/koreader/luajit")
if [ ! -f "$LUAJIT" ]; then
    LUAJIT="/mnt/c/Users/jpautz/squashfs-root/luajit"
fi
cd /home/jpautz/.config/koreader/plugins/storefront.koplugin
FAIL=0
for f in *.lua; do
    ERR=$($LUAJIT -b "$f" /dev/null 2>&1)
    if [ -n "$ERR" ]; then
        echo "FAIL $f"
        echo "$ERR"
        FAIL=1
    fi
done
if [ $FAIL -eq 0 ]; then
    echo "ALL_SYNTAX_OK"
fi
