-- tests/storefront_download_progress_test.lua
-- Tests the download progress text poller shown while a plugin downloads in a subprocess

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local DownloadProgress = require("storefront_download_progress")

local function run()
    print("==================================================")
    print("  RUNNING STOREFRONT DOWNLOAD PROGRESS TEST SUITE ")
    print("==================================================")

    local passed = 0
    local failed = 0

    local function assertTest(condition, name, msg)
        if condition then
            passed = passed + 1
            print(" [PASS] " .. name)
        else
            failed = failed + 1
            print(" [FAIL] " .. name .. (msg and (" - " .. tostring(msg)) or ""))
        end
    end

    -- Deferred scheduler so each poll can be stepped manually
    local queue = {}
    local orig_schedule, orig_unschedule, orig_isShown = UIManager.scheduleIn, UIManager.unschedule, UIManager.isShown
    local orig_attributes = lfs.attributes
    local shown = true
    local file_size = 0
    UIManager.scheduleIn = function(_, _, fn) table.insert(queue, fn) end
    UIManager.unschedule = function(_, fn)
        for i = #queue, 1, -1 do
            if queue[i] == fn then table.remove(queue, i) end
        end
    end
    UIManager.isShown = function() return shown end
    lfs.attributes = function(path, attr)
        if attr == "size" and path:match("%.tmp$") then return file_size end
        return nil
    end

    local function step()
        local fn = table.remove(queue, 1)
        if fn then fn() end
    end

    local function newWidget()
        local w = { texts = {} }
        function w:setText(text) table.insert(self.texts, text) end
        return w
    end

    local msg = "Downloading foo…\nTap screen to cancel."
    local MB = 1024 * 1024

    -- Test 1: known size reports progress text with percentage
    local w = newWidget()
    local stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 4 * MB)
    file_size = MB
    step()
    assertTest(w.texts[1] == "Downloading foo…\n1.0 MB / 4.0 MB (25%)\nTap screen to cancel.",
        "Known size text shows xx/xx MB and percentage", w.texts[1])

    -- Test 2: unchanged size does not redraw
    step()
    assertTest(#w.texts == 1, "Unchanged size skips redraw", #w.texts)

    -- Test 3: size over total clamps percentage to 100%
    file_size = 5 * MB
    step()
    assertTest(w.texts[2] and w.texts[2]:find("(100%)", 1, true) ~= nil,
        "Percentage clamped to 100% when size exceeds total", w.texts[2])

    -- Test 4: stop unschedules pending poll
    stop()
    assertTest(#queue == 0, "Stop removes pending poll", #queue)

    -- Test 5: unknown size shows downloaded MB only
    w = newWidget()
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", nil)
    file_size = 3 * MB / 2
    step()
    assertTest(w.texts[1] == "Downloading foo…\n1.5 MB\nTap screen to cancel.",
        "Unknown size shows downloaded MB", w.texts[1])
    stop()

    -- Test 6: polling stops once the widget is dismissed
    w = newWidget()
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 2 * MB)
    shown = false
    step()
    assertTest(#w.texts == 0 and #queue == 0, "Dismissed widget stops polling")
    shown = true
    stop()

    -- Test 7: a synchronous scheduler must not recurse forever
    UIManager.scheduleIn = function(_, _, fn) fn() end
    w = newWidget()
    local ok = pcall(function()
        stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 2 * MB)
        stop()
    end)
    assertTest(ok and #w.texts == 1, "Synchronous scheduler polls once without recursion", #w.texts)
    UIManager.scheduleIn = function(_, _, fn) table.insert(queue, fn) end

    -- Test 8: missing widget is a no-op
    local noop = DownloadProgress.start(nil, msg, "/tmp/foo.zip", MB)
    assertTest(type(noop) == "function" and pcall(noop), "Nil widget returns a callable no-op")

    -- Test 9: sub-megabyte known size uses KB units
    w = newWidget()
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 200 * 1024)
    file_size = 50 * 1024
    step()
    assertTest(w.texts[1] == "Downloading foo…\n50 KB / 200 KB (25%)\nTap screen to cancel.",
        "Sub-MB known size formats in KB", w.texts[1])
    stop()

    -- Test 10: sub-megabyte unknown size uses KB units
    w = newWidget()
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", nil)
    file_size = 350 * 1024
    step()
    assertTest(w.texts[1] == "Downloading foo…\n350 KB\nTap screen to cancel.",
        "Sub-MB unknown size formats in KB", w.texts[1])
    stop()

    -- Test 11: string total_bytes is coerced to number without error
    w = newWidget()
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", tostring(2 * MB))
    file_size = MB
    step()
    assertTest(w.texts[1] and w.texts[1]:find("1.0 MB / 2.0 MB (50%)", 1, true) ~= nil,
        "Numeric string total_bytes computes fraction", w.texts[1])
    stop()

    UIManager.scheduleIn, UIManager.unschedule, UIManager.isShown = orig_schedule, orig_unschedule, orig_isShown
    lfs.attributes = orig_attributes

    print(string.format("\nDownload Progress Tests Complete: %d Passed, %d Failed\n", passed, failed))
    if failed > 0 then error(string.format("%d download progress test(s) failed", failed)) end
end

run()
