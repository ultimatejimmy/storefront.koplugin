-- storefront_conductor_test.lua
-- Unit tests for Storefront Memory Conductor (storefront_conductor.lua)

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

require("spec_helper")

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS\t" .. label)
    else
        failures = failures + 1
        print("FAIL\t" .. label)
    end
    io.stdout:flush()
end

-- Build a controllable UIManager mock with manual timer queue + broadcastEvent
local scheduled_timers = {}
local broadcast_events = {}
local mock_uimanager = {
    _window_stack = {},
    scheduleIn = function(self, delay, action)
        local entry = { delay = delay, action = action, cancelled = false }
        table.insert(scheduled_timers, entry)
        return entry
    end,
    unschedule = function(self, action)
        local removed = false
        for _, entry in ipairs(scheduled_timers) do
            if entry.action == action and not entry.cancelled then
                entry.cancelled = true
                removed = true
            end
        end
        return removed
    end,
    nextTick = function(self, action)
        if type(action) == "function" then action() end
    end,
    broadcastEvent = function(self, ev)
        table.insert(broadcast_events, ev)
    end,
    show = function() end,
    close = function() end,
    setDirty = function() end,
    forceRePaint = function() end,
}
package.loaded["ui/uimanager"] = mock_uimanager

local function flushTimers(limit, max_delay)
    limit = limit or 50
    max_delay = max_delay or 5
    local ran = 0
    local idx = 1
    while idx <= #scheduled_timers and ran < limit do
        local entry = scheduled_timers[idx]
        if entry.cancelled then
            table.remove(scheduled_timers, idx)
        elseif (tonumber(entry.delay) or 0) <= max_delay then
            table.remove(scheduled_timers, idx)
            if type(entry.action) == "function" then
                ran = ran + 1
                entry.action()
            end
            idx = 1
        else
            idx = idx + 1
        end
    end
end

-- Build a controllable ffi/util mock
local next_pid = 100
local running_pids = {}
local fork_count = 0
local terminated_pids = {}
local mock_ffiutil = {
    runInSubProcess = function(fn, with_pipe, double_fork)
        fork_count = fork_count + 1
        next_pid = next_pid + 1
        if not double_fork then
            running_pids[next_pid] = true
        end
        return next_pid, next_pid + 1000
    end,
    isSubProcessDone = function(pid, wait)
        return not running_pids[pid]
    end,
    terminateSubProcess = function(pid)
        running_pids[pid] = nil
        terminated_pids[pid] = true
    end,
    joinPath = function(...) return table.concat({ ... }, "/") end,
}
package.loaded["ffi/util"] = mock_ffiutil

print("=== Running Storefront Memory Conductor Unit Tests ===")

local Conductor = require("storefront_conductor")
Conductor.installHooks()

-- ----------------------------------------------------
-- Test 1: Memory Status & Kindle Shmem Thresholds
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    local tmp_mem = "/tmp/test_conductor_kindle_meminfo.txt"
    local f = io.open(tmp_mem, "w")
    if f then
        f:write([[
MemTotal:         247852 kB
MemFree:            4096 kB
Buffers:            1024 kB
Cached:            40960 kB
Shmem:             10240 kB
]])
        f:close()
        Conductor.setMeminfoPath(tmp_mem)
        local status = Conductor.getMemoryStatus()
        -- Available = 4096 + 1024 + (40960 - 10240) = 35840 kB (~35 MB)
        check("getMemoryStatus computes Kindle Shmem-adjusted available_kb", status.available_kb == 35840)
        check("getMemoryStatus detects low-memory device (256MB)", status.is_low_memory_device == true)
        check("getMemoryStatus sets Kindle soft threshold to 45MB", status.thresholds.soft_min_free_kb == 45 * 1024)
        check("getMemoryStatus sets Kindle critical threshold to 28MB", status.thresholds.critical_min_free_kb == 28 * 1024)
        check("getMemoryStatus reports luajit_heap_kb > 0", status.luajit_heap_kb > 0)
        os.remove(tmp_mem)
    else
        print("SKIP\tCould not write temp meminfo")
    end
end

-- ----------------------------------------------------
-- Test 2: Caller Plugin Identification
-- ----------------------------------------------------
do
    check("extractPluginFromSource detects .koplugin path", Conductor.extractPluginFromSource("@/mnt/us/koreader/plugins/xray.koplugin/xray_fetch.lua") == "xray")
    check("extractPluginFromSource detects sink.koplugin", Conductor.extractPluginFromSource("@plugins/sink.koplugin/main.lua") == "sink")
    check("extractPluginFromSource detects known prefix in flat path", Conductor.extractPluginFromSource("@/tmp/nimbus_sync.lua") == "nimbus")
    check("extractPluginFromSource returns nil for core KOReader path", Conductor.extractPluginFromSource("@frontend/ui/uimanager.lua") == nil)
    check("extractPluginFromSource returns nil for storefront_conductor.lua itself", Conductor.extractPluginFromSource("@plugins/storefront.koplugin/storefront_conductor.lua") == nil)
end

-- ----------------------------------------------------
-- Test 3: Priority Queue, Single-Lane Serialization & Tracked Foreground
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    scheduled_timers = {}
    local tmp_mem = "/tmp/test_conductor_healthy.txt"
    local f = io.open(tmp_mem, "w")
    if f then
        f:write("MemTotal: 524288 kB\nMemAvailable: 120000 kB\n")
        f:close()
        Conductor.setMeminfoPath(tmp_mem)
    end

    local order = {}
    local done1, done2, done3, done_fg

    Conductor.requestSlot({
        plugin = "backup",
        task = "idle_1",
        priority = "idle_bg",
        run = function(done)
            table.insert(order, "backup:idle_1")
            done1 = done
        end,
    })

    Conductor.requestSlot({
        plugin = "xray",
        task = "idle_2",
        priority = "idle_bg",
        run = function(done)
            table.insert(order, "xray:idle_2")
            done2 = done
        end,
    })

    Conductor.requestSlot({
        plugin = "sink",
        task = "dirty_push",
        priority = "interactive_bg",
        run = function(done)
            table.insert(order, "sink:dirty_push")
            done3 = done
        end,
    })

    -- Foreground task executes immediately and holds new idle_bg work until done_fg()
    Conductor.requestSlot({
        plugin = "beeline",
        task = "user_open",
        priority = "foreground",
        run = function(done)
            table.insert(order, "beeline:fg")
            done_fg = done
        end,
    })

    check("First idle_bg starts immediately and foreground preempts queue", #order == 2 and order[1] == "backup:idle_1" and order[2] == "beeline:fg")

    done1()
    flushTimers()
    check("Queued background tasks wait while foreground slot is still active", #order == 2)

    done_fg()
    flushTimers()
    check("interactive_bg runs ahead of queued idle_bg after foreground completes", #order == 3 and order[3] == "sink:dirty_push")

    done3()
    flushTimers()
    check("queued idle_bg runs after interactive_bg completes", #order == 4 and order[4] == "xray:idle_2")
    if done2 then done2() end
    os.remove(tmp_mem)
end

-- ----------------------------------------------------
-- Test 4: Low-Memory Reclaim Recovery, Cooldown & Critical Rejection
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    scheduled_timers = {}
    broadcast_events = {}
    local fake_t = 100
    Conductor.setClock(function() return fake_t end)

    local tmp_mem = "/tmp/test_conductor_lowmem.txt"
    local function writeMem(avail_kb)
        local f = io.open(tmp_mem, "w")
        if f then
            f:write(string.format("MemTotal: 247852 kB\nMemFree: %d kB\nBuffers: 0 kB\nCached: 0 kB\n", avail_kb))
            f:close()
        end
    end

    -- Case A: Memory starts at 32MB (<45MB soft), reclaim frees memory to 55MB -> task proceeds!
    writeMem(32 * 1024)
    Conductor.setMeminfoPath(tmp_mem)

    local reclaim_called = 0
    Conductor.registerPlugin({
        plugin = "nimbus",
        on_reclaim = function(level)
            reclaim_called = reclaim_called + 1
            writeMem(55 * 1024)
        end,
    })

    local ran_after_reclaim = false
    Conductor.requestSlot({
        plugin = "storefront",
        task = "catalog_sync",
        priority = "idle_bg",
        sync = true,
        run = function()
            ran_after_reclaim = true
        end,
    })

    check("Low memory triggers registered on_reclaim callback", reclaim_called == 1)
    check("Low memory broadcasts MemoryReclaim event", #broadcast_events >= 1 and broadcast_events[1].name == "MemoryReclaim")
    check("Task proceeds once reclaim raises available RAM above threshold", ran_after_reclaim == true)

    -- Reclaim cooldown prevents thrashing within 5s
    local skipped_res = Conductor.reclaimMemory("soft")
    check("reclaimMemory respects 5s soft cooldown", skipped_res.skipped == true and reclaim_called == 1)

    -- Case B: Memory stays critically low (15MB < 28MB) even after reclaim -> idle_bg rejected
    Conductor._resetForTests()
    scheduled_timers = {}
    Conductor.setClock(function() return fake_t end)
    writeMem(15 * 1024)
    Conductor.setMeminfoPath(tmp_mem)

    local rejected_reason = nil
    local ran_when_critical = false
    Conductor.requestSlot({
        plugin = "xray",
        task = "bg_scan",
        priority = "idle_bg",
        run = function()
            ran_when_critical = true
        end,
        on_rejected = function(reason)
            rejected_reason = reason
        end,
    })

    check("Critical low memory rejects idle_bg task without crashing", ran_when_critical == false and rejected_reason == "low_memory")
    check("Stats track low_memory rejection", Conductor.getStats().slots_rejected_low_mem == 1)
    os.remove(tmp_mem)
end

-- ----------------------------------------------------
-- Test 5: Direct onMemoryReclaim Fan-Out (Immune to return true)
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    broadcast_events = {}
    local fake_t = 200
    Conductor.setClock(function() return fake_t end)

    local child_a_called = false
    local child_b_called = false
    mock_uimanager._window_stack = {
        {
            widget = {
                {
                    onMemoryReclaim = function(self, level)
                        child_a_called = true
                        return true -- Would short-circuit WidgetContainer:propagateEvent!
                    end,
                },
                {
                    onMemoryReclaim = function(self, level)
                        child_b_called = true
                        return false
                    end,
                },
            }
        }
    }

    Conductor.reclaimMemory("soft", nil, true)
    check("Direct fan-out calls child B even if child A returns true", child_a_called and child_b_called)
    mock_uimanager._window_stack = {}
end

-- ----------------------------------------------------
-- Test 6: Subprocess CoW Lockout, Lease Extension, Kernel Probe & double_fork
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    scheduled_timers = {}
    local fake_t = 1000
    Conductor.setClock(function() return fake_t end)
    Conductor.setCooldown(1.5)

    local tmp_mem = "/tmp/test_conductor_fork.txt"
    local f = io.open(tmp_mem, "w")
    if f then
        f:write("MemTotal: 524288 kB\nMemAvailable: 120000 kB\n")
        f:close()
        Conductor.setMeminfoPath(tmp_mem)
    end

    -- double_fork=true should NOT lock _active_subprocesses
    local df_pid = mock_ffiutil.runInSubProcess(function() end, false, true)
    check("double_fork=true does not lock active subprocesses", df_pid ~= nil and Conductor.getActiveSubprocessCount() == 0)

    -- Regular subprocess locks lane and extends past 120s while still alive
    local pid = mock_ffiutil.runInSubProcess(function() end, true)
    check("runInSubProcess registers active subprocess", Conductor.getActiveSubprocessCount() == 1)

    local bg_ran_during_fork = false
    Conductor.requestSlot({
        plugin = "sink",
        task = "bg_pull",
        priority = "idle_bg",
        sync = true,
        run = function()
            bg_ran_during_fork = true
        end,
    })

    flushTimers(5)
    check("Background task is held while another plugin's subprocess is running", bg_ran_during_fork == false)

    -- Advance monotonic clock by 180s while PID is still running -> must stay locked
    fake_t = 1180
    check("Subprocess stays locked at 180s while kernel reports still running", Conductor.getActiveSubprocessCount() == 1)

    -- Simulate a leaked PID that actually exited without caller polling -> probe reaps it automatically
    running_pids[pid] = nil
    check("pruneStaleSubprocesses reaps finished PID via live kernel probe", Conductor.getActiveSubprocessCount() == 0)

    -- Now start another PID and finish it via isSubProcessDone -> test post-subprocess cooldown
    local pid2 = mock_ffiutil.runInSubProcess(function() end, true)
    running_pids[pid2] = nil
    local is_done = mock_ffiutil.isSubProcessDone(pid2)
    check("isSubProcessDone clears active subprocess count", is_done == true and Conductor.getActiveSubprocessCount() == 0)

    -- Advance clock by 0.5s (< 1.5s cooldown) -> should still wait
    fake_t = 1180.5
    flushTimers(5)
    check("Post-subprocess 1.5s float cooldown holds next idle_bg at 0.5s", bg_ran_during_fork == false)

    -- Advance clock past 1.5s cooldown -> executes!
    fake_t = 1182.1
    flushTimers(10)
    check("Held background task executes after post-subprocess cooldown", bg_ran_during_fork == true)
    os.remove(tmp_mem)
end

-- ----------------------------------------------------
-- Test 7: Double stabilizeBeforeFork Debounce
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    local fake_t = 2000
    Conductor.setClock(function() return fake_t end)
    local tmp_mem = "/tmp/test_conductor_stab.txt"
    local f = io.open(tmp_mem, "w")
    if f then
        f:write("MemTotal: 524288 kB\nMemAvailable: 120000 kB\n")
        f:close()
        Conductor.setMeminfoPath(tmp_mem)
    end

    local first = Conductor.stabilizeBeforeFork("nimbus")
    local second = Conductor.stabilizeBeforeFork("nimbus")
    fake_t = 2003
    local third = Conductor.stabilizeBeforeFork("nimbus")
    check("stabilizeBeforeFork debounces back-to-back calls within 2s", first == true and second == false and third == true)
    os.remove(tmp_mem)
end

-- ----------------------------------------------------
-- Test 8: UIManager:unschedule Return Value & Multi-Schedule Cancellation
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    scheduled_timers = {}

    local fire_count = 0
    local function my_bg_timer()
        fire_count = fire_count + 1
    end

    check("UIManager:unschedule returns false when timer not scheduled", mock_uimanager:unschedule(my_bg_timer) == false)

    mock_uimanager:scheduleIn(10, my_bg_timer)
    mock_uimanager:scheduleIn(20, my_bg_timer)
    local removed = mock_uimanager:unschedule(my_bg_timer)
    flushTimers(20, 30)
    check("UIManager:unschedule returns true and cancels all wrapped instances", removed == true and fire_count == 0)
end

-- ----------------------------------------------------
-- Test 9: Queue Deduplication (dedupe_key) & Stats
-- ----------------------------------------------------
do
    Conductor._resetForTests()
    scheduled_timers = {}
    local tmp_mem = "/tmp/test_conductor_dedupe.txt"
    local f = io.open(tmp_mem, "w")
    if f then
        f:write("MemTotal: 524288 kB\nMemAvailable: 120000 kB\n")
        f:close()
        Conductor.setMeminfoPath(tmp_mem)
    end

    local blocker_done
    Conductor.requestSlot({
        plugin = "storefront",
        task = "blocker",
        priority = "idle_bg",
        run = function(done) blocker_done = done end,
    })

    local inbox_runs = 0
    Conductor.requestSlot({
        plugin = "beeline",
        task = "inbox_poll",
        priority = "idle_bg",
        dedupe_key = "beeline:inbox",
        sync = true,
        run = function() inbox_runs = inbox_runs + 1 end,
    })
    Conductor.requestSlot({
        plugin = "beeline",
        task = "inbox_poll",
        priority = "idle_bg",
        dedupe_key = "beeline:inbox",
        sync = true,
        run = function() inbox_runs = inbox_runs + 1 end,
    })

    blocker_done()
    flushTimers()
    local stats = Conductor.getStats()
    check("dedupe_key coalesces duplicate pending tasks", inbox_runs == 1 and stats.slots_deduplicated == 1)
    check("getStats tracks completed slots", stats.slots_completed == 2)
    os.remove(tmp_mem)
end

print("=== Storefront Memory Conductor Tests Summary ===")
print(string.format("Total Failures: %d", failures))
if failures > 0 then
    os.exit(1)
end
