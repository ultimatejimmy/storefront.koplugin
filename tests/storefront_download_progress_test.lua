-- tests/storefront_download_progress_test.lua
-- Tests the download progress poller shown while a plugin downloads in a subprocess

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

    local function newWidget(with_bar)
        local w = { texts = {}, fractions = {} }
        function w:setText(text) table.insert(self.texts, text) end
        if with_bar then
            function w:setProgress(fraction, text)
                self.progress = fraction
                table.insert(self.fractions, fraction)
                self:setText(text)
            end
        end
        return w
    end

    local msg = "Downloading foo…\nTap screen to cancel."
    local MB = 1024 * 1024

    -- Test 1: known size draws a bar and a percentage
    local w = newWidget(true)
    local stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 4 * MB)
    file_size = MB
    step()
    assertTest(w.fractions[1] == 0.25, "Known size reports fraction 0.25", w.fractions[1])
    assertTest(w.texts[1] == "Downloading foo…\n1.0 MB / 4.0 MB (25%)\nTap screen to cancel.",
        "Known size text keeps title and cancel hint", w.texts[1])

    -- Test 2: unchanged size does not redraw
    step()
    assertTest(#w.texts == 1, "Unchanged size skips redraw", #w.texts)

    -- Test 3: size over total is clamped to 100%
    file_size = 5 * MB
    step()
    assertTest(w.fractions[2] == 1, "Fraction clamped to 1", w.fractions[2])

    -- Test 4: stop unschedules and clears the bar
    stop()
    assertTest(#queue == 0, "Stop removes pending poll", #queue)
    assertTest(w.progress == nil, "Stop clears progress bar")

    -- Test 5: unknown size shows downloaded MB only, without a bar
    w = newWidget(true)
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", nil)
    file_size = 3 * MB / 2
    step()
    assertTest(#w.fractions == 0, "Unknown size draws no bar")
    assertTest(w.texts[1] == "Downloading foo…\n1.5 MB\nTap screen to cancel.", "Unknown size shows MB", w.texts[1])
    stop()

    -- Test 6: widget without setProgress falls back to text
    w = newWidget(false)
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 2 * MB)
    file_size = MB
    step()
    assertTest(w.texts[1] and w.texts[1]:find("(50%)", 1, true) ~= nil, "Text-only widget shows percentage", w.texts[1])
    stop()

    -- Test 7: polling stops once the widget is dismissed
    w = newWidget(true)
    stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 2 * MB)
    shown = false
    step()
    assertTest(#w.texts == 0 and #queue == 0, "Dismissed widget stops polling")
    shown = true
    stop()

    -- Test 8: a synchronous scheduler must not recurse forever
    UIManager.scheduleIn = function(_, _, fn) fn() end
    w = newWidget(true)
    local ok = pcall(function()
        stop = DownloadProgress.start(w, msg, "/tmp/foo.zip", 2 * MB)
        stop()
    end)
    assertTest(ok and #w.texts == 1, "Synchronous scheduler polls once without recursion", #w.texts)

    -- Test 9: missing widget is a no-op
    local noop = DownloadProgress.start(nil, msg, "/tmp/foo.zip", MB)
    assertTest(type(noop) == "function" and pcall(noop), "Nil widget returns a callable no-op")

    UIManager.scheduleIn, UIManager.unschedule, UIManager.isShown = orig_schedule, orig_unschedule, orig_isShown
    lfs.attributes = orig_attributes

    print(string.format("\nDownload Progress Tests Complete: %d Passed, %d Failed\n", passed, failed))
    if failed > 0 then error(string.format("%d download progress test(s) failed", failed)) end
end

run()
