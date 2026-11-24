--- storefront_conductor.lua
--- Cooperative and transparent Memory Conductor for KOReader plugins.
--- Prevents Kindle OOM / memory watchdog crashes by:
---   1. Transparently intercepting UIManager:scheduleIn / unschedule and
---      ffiutil.runInSubProcess / isSubProcessDone / terminateSubProcess.
---   2. Serializing background plugin work into a priority-ordered single lane.
---   3. Stabilizing LuaJIT heap before fork() to minimize Copy-On-Write RAM spikes.
---   4. Broadcasting Event("MemoryReclaim", level) and fanning out onMemoryReclaim
---      across active containers when available RAM drops below safe thresholds.

local logger = require("logger")

local ok_log, StorefrontLogger = pcall(require, "storefront_logger")
if not ok_log then StorefrontLogger = nil end

local Conductor = {}

-- Ensure a single shared instance regardless of require path (e.g. "storefront_conductor")
if not package.loaded["storefront_conductor"] then
    package.loaded["storefront_conductor"] = Conductor
end

local PRIORITY_WEIGHT = {
    foreground     = 3,
    interactive_bg = 2,
    idle_bg        = 1,
}

local DEFAULT_LOW_MEM_SOFT_KB     = 45 * 1024
local DEFAULT_LOW_MEM_CRITICAL_KB = 28 * 1024
local DEFAULT_STD_SOFT_KB         = 30 * 1024
local DEFAULT_STD_CRITICAL_KB     = 18 * 1024
local DEFAULT_COOLDOWN_S          = 1.5
local DEFAULT_SLOT_LEASE_S        = 45
local SUBPROCESS_PROBE_AFTER_S    = 5
local HARD_SUBPROCESS_CEILING_S   = 600
local MICRO_TIMER_THRESHOLD_S     = 0.25
local STABILIZE_COOLDOWN_S        = 2.0
local RECLAIM_SOFT_COOLDOWN_S     = 5.0
local RECLAIM_CRITICAL_COOLDOWN_S = 10.0

local KNOWN_PREFIXES = {
    "storefront",
    "xray",
    "nimbus",
    "sink",
    "backup",
    "beeline",
}

local _enabled = true
local _is_suspended = false
local _is_conductor_internal = false
local _meminfo_path_override = nil
local _clock_fn = nil
local _cooldown_s = DEFAULT_COOLDOWN_S
local _slot_lease_s = DEFAULT_SLOT_LEASE_S
local _last_bg_finish_ts = 0
local _last_stabilize_ts = -999
local _last_soft_reclaim_ts = -999
local _last_critical_reclaim_ts = -999

local _seq = 0
local _queue = {}
local _active_task = nil
local _active_fg_count = 0
local _pump_scheduled = false
local _registered_plugins = {}
local _active_subprocesses = {}
local _action_map = setmetatable({}, { __mode = "k" })

local _orig_scheduleIn = nil
local _orig_isSubProcessDone = nil

local function newStats()
    return {
        slots_requested = 0,
        slots_completed = 0,
        slots_deduplicated = 0,
        slots_rejected_low_mem = 0,
        slots_rejected_suspended = 0,
        slots_preempted = 0,
        lease_expirations = 0,
        reclaims_soft = 0,
        reclaims_critical = 0,
        subprocesses_tracked = 0,
    }
end

local _stats = newStats()

--- Returns monotonic seconds (immune to wall-clock NTP jumps on Wi-Fi reconnect).
---@return number
local function nowSeconds()
    if _clock_fn then
        return _clock_fn()
    end
    local ok_t, ktime = pcall(require, "ui/time")
    if ok_t and ktime and ktime.now and ktime.to_ms then
        local ok_now, ms = pcall(function() return ktime.to_ms(ktime.now()) end)
        if ok_now and type(ms) == "number" then
            return ms / 1000
        end
    end
    local ok_s, socket = pcall(require, "socket")
    if ok_s and socket and type(socket.gettime) == "function" then
        local ok_gt, gt = pcall(socket.gettime)
        if ok_gt and type(gt) == "number" then
            return gt
        end
    end
    return os.time()
end

local function logInfo(msg)
    logger.info("StorefrontConductor: " .. tostring(msg))
    if StorefrontLogger and StorefrontLogger.info then
        StorefrontLogger.info("StorefrontConductor: " .. tostring(msg))
    end
end

local function logWarn(msg)
    logger.warn("StorefrontConductor: " .. tostring(msg))
    if StorefrontLogger and StorefrontLogger.warn then
        StorefrontLogger.warn("StorefrontConductor: " .. tostring(msg))
    end
end

local function logDbg(msg)
    if logger.dbg then
        logger.dbg("StorefrontConductor: " .. tostring(msg))
    end
end

local function getUIManager()
    local ok, ui = pcall(require, "ui/uimanager")
    if ok and type(ui) == "table" then
        return ui
    end
    return nil
end

local function getUtils()
    local ok, utils = pcall(require, "storefront_utils")
    if ok and type(utils) == "table" then
        return utils
    end
    return nil
end

--- Schedules an internal Conductor timer without triggering the scheduleIn wrapper.
---@param delay number
---@param fn function
local function scheduleInternal(delay, fn)
    local UIManager = getUIManager()
    if not UIManager then return end
    local sched = _orig_scheduleIn or UIManager.scheduleIn
    if type(sched) ~= "function" then return end
    _is_conductor_internal = true
    local ok, err = pcall(sched, UIManager, delay, fn)
    _is_conductor_internal = false
    if not ok then
        logWarn("internal scheduleIn error: " .. tostring(err))
    end
end

--- Enables or disables the Conductor at runtime.
---@param enabled boolean
function Conductor.setEnabled(enabled)
    _enabled = (enabled ~= false)
end

--- Returns whether the Conductor is currently enabled.
---@return boolean
function Conductor.isEnabled()
    return _enabled
end

--- Overrides the /proc/meminfo path (primarily for unit tests).
---@param path string|nil
function Conductor.setMeminfoPath(path)
    _meminfo_path_override = path
end

--- Overrides the monotonic clock function (primarily for unit tests).
---@param fn function|nil Returns seconds as a number
function Conductor.setClock(fn)
    _clock_fn = fn
end

--- Sets the cooldown delay in seconds between background tasks (useful for testing).
---@param seconds number
function Conductor.setCooldown(seconds)
    _cooldown_s = tonumber(seconds) or DEFAULT_COOLDOWN_S
end

--- Sets the maximum lease duration in seconds for an active background slot.
---@param seconds number
function Conductor.setSlotLease(seconds)
    _slot_lease_s = tonumber(seconds) or DEFAULT_SLOT_LEASE_S
end

--- Returns a snapshot of lightweight session intervention counters.
---@return table
function Conductor.getStats()
    local copy = {}
    for k, v in pairs(_stats) do
        copy[k] = v
    end
    return copy
end

--- Returns memory thresholds (in KB) appropriate for the current device.
---@param meminfo_path string|nil
---@return table { soft_min_free_kb: number, critical_min_free_kb: number, is_low_memory_device: boolean }
function Conductor.getThresholds(meminfo_path)
    local path = meminfo_path or _meminfo_path_override
    local utils = getUtils()
    local is_low_dev = false
    if utils and utils.isLowMemoryDevice then
        local ok, res = pcall(utils.isLowMemoryDevice, path)
        if ok then is_low_dev = (res == true) end
    end
    if is_low_dev then
        return {
            soft_min_free_kb = DEFAULT_LOW_MEM_SOFT_KB,
            critical_min_free_kb = DEFAULT_LOW_MEM_CRITICAL_KB,
            is_low_memory_device = true,
        }
    end
    return {
        soft_min_free_kb = DEFAULT_STD_SOFT_KB,
        critical_min_free_kb = DEFAULT_STD_CRITICAL_KB,
        is_low_memory_device = false,
    }
end

--- Probes and prunes finished or hard-expired subprocesses without prematurely
--- dropping active multi-minute transfers.
local function pruneStaleSubprocesses()
    local now = nowSeconds()
    for pid, info in pairs(_active_subprocesses) do
        if info and info.started_at then
            local age = now - info.started_at
            if age > HARD_SUBPROCESS_CEILING_S then
                logWarn(string.format("subprocess pid=%s (%s) exceeded %ds hard ceiling, releasing lock",
                    tostring(pid), tostring(info.plugin), HARD_SUBPROCESS_CEILING_S))
                _active_subprocesses[pid] = nil
            elseif age >= SUBPROCESS_PROBE_AFTER_S and type(_orig_isSubProcessDone) == "function" then
                local ok_p, done = pcall(_orig_isSubProcessDone, pid, false)
                if ok_p and done == true then
                    _active_subprocesses[pid] = nil
                end
            end
        end
    end
end

--- Counts currently active tracked subprocesses.
---@return number
function Conductor.getActiveSubprocessCount()
    pruneStaleSubprocesses()
    local count = 0
    for _ in pairs(_active_subprocesses) do
        count = count + 1
    end
    return count
end

--- Returns whether the given plugin currently owns an active child subprocess.
---@param plugin_id string|nil
---@return boolean
function Conductor.hasActiveSubprocessForPlugin(plugin_id)
    if not plugin_id then return false end
    pruneStaleSubprocesses()
    for _, info in pairs(_active_subprocesses) do
        if info and info.plugin == plugin_id then
            return true
        end
    end
    return false
end

--- Returns live system memory, LuaJIT heap usage, and Conductor queue telemetry.
---@param meminfo_path string|nil
---@return table
function Conductor.getMemoryStatus(meminfo_path)
    local path = meminfo_path or _meminfo_path_override
    local utils = getUtils()
    local mem = nil
    if utils and utils.getMemoryInfo then
        local ok, res = pcall(utils.getMemoryInfo, path)
        if ok then mem = res end
    end
    local thresholds = Conductor.getThresholds(path)
    local active_subs = Conductor.getActiveSubprocessCount()
    local luajit_heap_kb = math.floor(collectgarbage("count") or 0)

    return {
        total_kb = mem and mem.total_kb or 0,
        available_kb = mem and mem.available_kb or nil,
        free_kb = mem and mem.free_kb or 0,
        buffers_kb = mem and mem.buffers_kb or 0,
        cached_kb = mem and mem.cached_kb or 0,
        shmem_kb = mem and mem.shmem_kb or 0,
        luajit_heap_kb = luajit_heap_kb,
        is_low_memory_device = thresholds.is_low_memory_device,
        thresholds = thresholds,
        active_subprocesses = active_subs,
        active_foreground = _active_fg_count,
        queue_depth = #_queue,
        is_busy = (_active_task ~= nil) or (active_subs > 0) or (_active_fg_count > 0),
        stats = Conductor.getStats(),
    }
end

--- Extracts a plugin identifier from a Lua source path, or nil for core KOReader files.
---@param source string|nil
---@return string|nil
function Conductor.extractPluginFromSource(source)
    if type(source) ~= "string" or source == "" then
        return nil
    end
    local clean = source:gsub("^@", "")
    -- Never attribute internal Conductor frames to Storefront
    if clean:find("storefront_conductor%.lua") then
        return nil
    end
    -- Standard KOReader plugin directory: .../plugins/<name>.koplugin/...
    local ko_name = clean:match("([^/\\]+)%.koplugin[/\\]")
    if ko_name and ko_name ~= "" then
        return ko_name:lower()
    end
    -- Fallback for flat plugin directories / unit test paths (e.g. xray_fetch.lua)
    local basename = clean:match("([^/\\]+)$") or clean
    for _, prefix in ipairs(KNOWN_PREFIXES) do
        if basename:lower():find("^" .. prefix .. "_") then
            return prefix
        end
    end
    return nil
end

--- Walks the Lua call stack to identify which plugin initiated the current call.
---@param max_depth number|nil
---@return string|nil
function Conductor.identifyCallerPlugin(max_depth)
    max_depth = max_depth or 10
    for level = 2, max_depth do
        local info = debug.getinfo(level, "S")
        if not info then break end
        local plugin_id = Conductor.extractPluginFromSource(info.source)
        if plugin_id then
            return plugin_id
        end
    end
    return nil
end

--- Checks whether the given plugin currently owns a visible foreground window.
---@param plugin_id string|nil
---@return boolean
function Conductor.isPluginInForeground(plugin_id)
    if not plugin_id then return false end
    local id_lower = tostring(plugin_id):lower()

    local reg = _registered_plugins[id_lower]
    if reg and type(reg.is_foreground) == "function" then
        local ok, fg = pcall(reg.is_foreground)
        if ok and fg == true then
            return true
        end
    end

    if id_lower == "storefront" then
        local main_mod = package.loaded["main"]
        if type(main_mod) == "table" and main_mod.instance and main_mod.instance.browser_menu ~= nil then
            return true
        end
    end

    local UIManager = getUIManager()
    if UIManager and type(UIManager._window_stack) == "table" then
        for _, entry in ipairs(UIManager._window_stack) do
            local widget = type(entry) == "table" and (entry.widget or entry) or nil
            if type(widget) == "table" then
                local wname = tostring(widget.name or widget.id or widget._plugin_id or ""):lower()
                if wname ~= "" and wname:find(id_lower, 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

--- Registers a plugin profile with the Conductor for targeted memory reclaim and cancellation.
---@param opts table { plugin: string, on_reclaim?: function(level), on_cancel_bg?: function(), is_foreground?: function():boolean }
---@return boolean
function Conductor.registerPlugin(opts)
    if type(opts) ~= "table" or type(opts.plugin) ~= "string" or opts.plugin == "" then
        return false
    end
    local id = opts.plugin:lower()
    _registered_plugins[id] = {
        plugin = id,
        on_reclaim = opts.on_reclaim,
        on_cancel_bg = opts.on_cancel_bg,
        is_foreground = opts.is_foreground,
    }
    return true
end

--- Unregisters a plugin profile (mainly for tests).
---@param plugin_id string
function Conductor.unregisterPlugin(plugin_id)
    if type(plugin_id) == "string" then
        _registered_plugins[plugin_id:lower()] = nil
    end
end

--- Runs built-in safe cache eviction for known plugins if they didn't register explicitly.
---@param level string "soft"|"critical"
---@param exclude_plugin string|nil
local function reclaimBuiltInProfiles(level, exclude_plugin)
    if exclude_plugin ~= "storefront" and not Conductor.isPluginInForeground("storefront") then
        local cache_mod = package.loaded["storefront_cache"]
        if type(cache_mod) == "table" and type(cache_mod.purgeMem) == "function" then
            pcall(cache_mod.purgeMem)
        end
        local ss_mod = package.loaded["storefront_screensavers_ui"]
        if type(ss_mod) == "table" and type(ss_mod.invalidateMemCache) == "function" then
            pcall(ss_mod.invalidateMemCache)
        end
    end
    if level == "critical" and exclude_plugin ~= "nimbus" and not Conductor.isPluginInForeground("nimbus") then
        local scanner_mod = package.loaded["nimbus_scanner"]
        if type(scanner_mod) == "table" and scanner_mod._mem_cache ~= nil then
            scanner_mod._mem_cache = nil
        end
    end
end

--- Directly invokes onMemoryReclaim(level) on all child widgets inside _window_stack containers
--- so a single plugin returning `true` cannot short-circuit WidgetContainer:propagateEvent.
---@param UIManager table|nil
---@param level string
local function fanOutWindowStackReclaim(UIManager, level)
    if not UIManager or type(UIManager._window_stack) ~= "table" then
        return
    end
    local visited = {}
    local function visit(node, depth)
        if type(node) ~= "table" or visited[node] or depth > 3 then
            return
        end
        visited[node] = true
        if type(node.onMemoryReclaim) == "function" then
            pcall(node.onMemoryReclaim, node, level)
        end
        for i = 1, #node do
            local child = node[i]
            if type(child) == "table" then
                visit(child, depth + 1)
            end
        end
    end
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = type(entry) == "table" and (entry.widget or entry) or nil
        if type(widget) == "table" then
            visit(widget, 1)
        end
    end
end

--- Evicts non-essential caches across plugins and runs LuaJIT garbage collection.
--- Broadcasts KOReader Event("MemoryReclaim", level) and fans out directly to all container children.
---@param level string|nil "soft"|"critical" (defaults to "soft")
---@param exclude_plugin string|nil Plugin ID to skip during reclaim
---@param force boolean|nil Bypass cooldown checks
---@return table { level: string, skipped?: boolean, before_avail_kb: number|nil, after_avail_kb: number|nil }
function Conductor.reclaimMemory(level, exclude_plugin, force)
    level = (level == "critical") and "critical" or "soft"
    local now = nowSeconds()

    if not force then
        if level == "soft" and (now - _last_soft_reclaim_ts) < RECLAIM_SOFT_COOLDOWN_S then
            local status = Conductor.getMemoryStatus()
            return {
                level = level,
                skipped = true,
                before_avail_kb = status.available_kb,
                after_avail_kb = status.available_kb,
            }
        elseif level == "critical" and (now - _last_critical_reclaim_ts) < RECLAIM_CRITICAL_COOLDOWN_S then
            local status = Conductor.getMemoryStatus()
            return {
                level = level,
                skipped = true,
                before_avail_kb = status.available_kb,
                after_avail_kb = status.available_kb,
            }
        end
    end

    if level == "critical" then
        _last_critical_reclaim_ts = now
        _stats.reclaims_critical = _stats.reclaims_critical + 1
    else
        _last_soft_reclaim_ts = now
        _stats.reclaims_soft = _stats.reclaims_soft + 1
    end

    local exclude_lower = exclude_plugin and tostring(exclude_plugin):lower() or nil
    local before = Conductor.getMemoryStatus()
    logInfo(string.format("reclaimMemory(%s) triggered (avail=%s KB, heap=%d KB)",
        level, tostring(before.available_kb), before.luajit_heap_kb))

    -- 1. Invoke explicitly registered plugin reclaim callbacks
    for id, profile in pairs(_registered_plugins) do
        if id ~= exclude_lower and type(profile.on_reclaim) == "function" then
            local ok, err = pcall(profile.on_reclaim, level)
            if not ok then
                logWarn("on_reclaim error in " .. id .. ": " .. tostring(err))
            end
        end
    end

    -- 2. Run built-in safe profiles for known plugins
    reclaimBuiltInProfiles(level, exclude_lower)

    -- 3. Fan out directly to all container children (immune to propagateEvent short-circuiting)
    local UIManager = getUIManager()
    fanOutWindowStackReclaim(UIManager, level)

    -- 4. Broadcast standard KOReader MemoryReclaim event for custom handleEvent listeners
    local ok_ev, Event = pcall(require, "ui/event")
    if UIManager and type(UIManager.broadcastEvent) == "function" and ok_ev and Event and type(Event.new) == "function" then
        pcall(function()
            UIManager:broadcastEvent(Event:new("MemoryReclaim", level))
        end)
    end

    -- 5. Reclaim unreferenced LuaJIT objects
    if level == "critical" then
        collectgarbage("collect")
    else
        collectgarbage("step", 200)
    end

    local after = Conductor.getMemoryStatus()
    return {
        level = level,
        before_avail_kb = before.available_kb,
        after_avail_kb = after.available_kb,
    }
end

--- Stabilizes parent LuaJIT heap before fork() to prevent Copy-On-Write RAM duplication.
--- Debounced to avoid back-to-back full-heap GC sweeps when requestSlot({ subprocess = true })
--- is immediately followed by ffiutil.runInSubProcess.
---@param caller_plugin string|nil
---@param force boolean|nil
---@return boolean ran_stabilize
function Conductor.stabilizeBeforeFork(caller_plugin, force)
    local now = nowSeconds()
    if not force and (now - _last_stabilize_ts) < STABILIZE_COOLDOWN_S then
        return false
    end
    _last_stabilize_ts = now
    local status = Conductor.getMemoryStatus()
    if status.available_kb and status.available_kb < status.thresholds.soft_min_free_kb then
        Conductor.reclaimMemory("soft", caller_plugin)
    end
    -- Zero out parent GC debt before fork() so parent doesn't dirty pages during child run
    collectgarbage("collect")
    return true
end

local function sortQueue()
    table.sort(_queue, function(a, b)
        if a.weight ~= b.weight then
            return a.weight > b.weight
        end
        return a.seq < b.seq
    end)
end

local pumpQueue

local function schedulePump(delay)
    if _pump_scheduled then return end
    local UIManager = getUIManager()
    if not UIManager then return end
    _pump_scheduled = true
    scheduleInternal(delay or 0.05, function()
        _pump_scheduled = false
        pumpQueue()
    end)
end

--- Cancels preemptible idle_bg tasks when a foreground task arrives under low memory.
local function preemptIdleWork()
    if _active_task and _active_task.priority == "idle_bg" then
        local task = _active_task
        _stats.slots_preempted = _stats.slots_preempted + 1
        if type(task.cancel) == "function" then
            pcall(task.cancel)
        end
        local reg = task.plugin and _registered_plugins[task.plugin]
        if reg and type(reg.on_cancel_bg) == "function" then
            pcall(reg.on_cancel_bg)
        end
        task.finished = true
        _active_task = nil
    end
end

local function executeTask(task)
    if task.cancelled then
        schedulePump(0)
        return
    end

    -- Check memory clearance for background tasks
    local status = Conductor.getMemoryStatus()
    local min_kb = task.min_free_kb
    if min_kb == nil then
        if task.priority == "idle_bg" then
            min_kb = status.thresholds.soft_min_free_kb
        elseif task.priority == "interactive_bg" then
            min_kb = status.thresholds.critical_min_free_kb
        else
            min_kb = 0
        end
    end

    if task.priority ~= "foreground" and status.available_kb and min_kb > 0 and status.available_kb < min_kb then
        Conductor.reclaimMemory("soft", task.plugin)
        status = Conductor.getMemoryStatus()
        if status.available_kb and status.available_kb < status.thresholds.critical_min_free_kb then
            Conductor.reclaimMemory("critical", task.plugin)
            status = Conductor.getMemoryStatus()
        end
        if status.available_kb and status.available_kb < status.thresholds.critical_min_free_kb and task.priority == "idle_bg" then
            _stats.slots_rejected_low_mem = _stats.slots_rejected_low_mem + 1
            logWarn(string.format("deferring/skipping %s:%s due to critical low memory (%d KB avail < %d KB)",
                tostring(task.plugin), tostring(task.task), status.available_kb, status.thresholds.critical_min_free_kb))
            if type(task.on_rejected) == "function" then
                pcall(task.on_rejected, "low_memory")
            end
            schedulePump(0.1)
            return
        end
    end

    if task.subprocess then
        Conductor.stabilizeBeforeFork(task.plugin)
    end

    if task.priority == "foreground" then
        _active_fg_count = _active_fg_count + 1
        local fg_done_called = false
        local function fgDone()
            if fg_done_called then return end
            fg_done_called = true
            _active_fg_count = math.max(0, _active_fg_count - 1)
            _stats.slots_completed = _stats.slots_completed + 1
            if _active_fg_count == 0 and #_queue > 0 then
                schedulePump(math.max(0.05, _cooldown_s))
            end
        end
        local fg_lease = tonumber(task.lease_s) or _slot_lease_s
        if fg_lease > 0 then
            scheduleInternal(fg_lease, function()
                if not fg_done_called then
                    fgDone()
                end
            end)
        end
        local ok, err = xpcall(function()
            task.run(fgDone)
        end, debug.traceback)
        if not ok then
            logWarn("foreground task error: " .. tostring(err))
            fgDone()
        elseif task.sync then
            fgDone()
        end
        return
    end

    _active_task = task
    task.started_at = nowSeconds()
    local lease_expired = false

    local function done()
        if task.finished then return end
        task.finished = true
        if _active_task == task then
            _active_task = nil
        end
        _stats.slots_completed = _stats.slots_completed + 1
        _last_bg_finish_ts = nowSeconds()
        collectgarbage("step", 100)
        if not lease_expired then
            schedulePump(math.max(0.05, _cooldown_s))
        end
    end

    local lease_s = tonumber(task.lease_s) or _slot_lease_s
    if lease_s > 0 then
        local function checkLease()
            if task.finished or _active_task ~= task then
                return
            end
            local elapsed = nowSeconds() - (task.started_at or 0)
            if Conductor.hasActiveSubprocessForPlugin(task.plugin) and elapsed < HARD_SUBPROCESS_CEILING_S then
                scheduleInternal(lease_s, checkLease)
                return
            end
            lease_expired = true
            _stats.lease_expirations = _stats.lease_expirations + 1
            logWarn(string.format("slot lease expired for %s:%s after %.1fs, releasing lock",
                tostring(task.plugin), tostring(task.task), elapsed))
            task.finished = true
            _active_task = nil
            schedulePump(0.1)
        end
        scheduleInternal(lease_s, checkLease)
    end

    local ok, err = xpcall(function()
        task.run(done)
    end, debug.traceback)
    if not ok then
        logWarn(string.format("task %s:%s failed: %s", tostring(task.plugin), tostring(task.task), tostring(err)))
        done()
    elseif task.sync then
        done()
    end
end

pumpQueue = function()
    if _is_suspended then return end
    if _active_task ~= nil then return end
    if _active_fg_count > 0 then
        schedulePump(0.25)
        return
    end
    if Conductor.getActiveSubprocessCount() > 0 then
        schedulePump(0.5)
        return
    end
    if #_queue == 0 then return end

    local now = nowSeconds()
    local next_task = _queue[1]
    if next_task.priority == "idle_bg" and _cooldown_s > 0 and _last_bg_finish_ts > 0 then
        local elapsed = now - _last_bg_finish_ts
        if elapsed < _cooldown_s then
            schedulePump(_cooldown_s - elapsed)
            return
        end
    end

    table.remove(_queue, 1)

    if next_task.cancelled then
        schedulePump(0)
        return
    end

    executeTask(next_task)
end

local function makeHandle(task)
    return {
        id = task.id,
        cancel = function()
            task.cancelled = true
            if _active_task == task then
                if type(task.cancel) == "function" then
                    pcall(task.cancel)
                end
                task.finished = true
                _active_task = nil
                schedulePump(0.05)
            end
        end,
    }
end

--- Requests a managed execution slot from the Conductor.
---@param opts table { plugin?: string, task?: string, priority?: string, min_free_kb?: number, lease_s?: number, dedupe_key?: string, subprocess?: boolean, sync?: boolean, run: function(done), cancel?: function(), on_rejected?: function(reason) }
---@return table slot_handle { id: number, cancel: function() }
function Conductor.requestSlot(opts)
    assert(type(opts) == "table" and type(opts.run) == "function", "Conductor.requestSlot requires opts.run function")

    local plugin_id = (opts.plugin and tostring(opts.plugin):lower()) or Conductor.identifyCallerPlugin() or "unknown"
    local priority = opts.priority or "idle_bg"
    if not PRIORITY_WEIGHT[priority] then
        priority = "idle_bg"
    end
    local weight = PRIORITY_WEIGHT[priority]

    _stats.slots_requested = _stats.slots_requested + 1

    if not _enabled then
        opts.run(function() end)
        return { id = 0, cancel = function() end }
    end

    if _is_suspended and priority == "idle_bg" then
        _stats.slots_rejected_suspended = _stats.slots_rejected_suspended + 1
        if type(opts.on_rejected) == "function" then
            pcall(opts.on_rejected, "suspended")
        end
        return { id = 0, cancel = function() end }
    end

    -- Deduplicate identical pending tasks in the queue before allocating a new slot
    local dedupe_key = opts.dedupe_key
    if dedupe_key and priority ~= "foreground" then
        for _, existing in ipairs(_queue) do
            if not existing.cancelled and existing.dedupe_key == dedupe_key then
                _stats.slots_deduplicated = _stats.slots_deduplicated + 1
                if weight > existing.weight then
                    existing.priority = priority
                    existing.weight = weight
                    sortQueue()
                end
                return makeHandle(existing)
            end
        end
    end

    _seq = _seq + 1
    local task = {
        id = _seq,
        seq = _seq,
        plugin = plugin_id,
        task = opts.task or "task",
        priority = priority,
        weight = weight,
        min_free_kb = opts.min_free_kb,
        lease_s = opts.lease_s,
        dedupe_key = dedupe_key,
        subprocess = (opts.subprocess == true),
        sync = (opts.sync == true),
        run = opts.run,
        cancel = opts.cancel,
        on_rejected = opts.on_rejected,
        orig_action = opts._orig_action,
        cancelled = false,
        finished = false,
    }

    local handle = makeHandle(task)

    if priority == "foreground" then
        local status = Conductor.getMemoryStatus()
        if status.available_kb and status.available_kb < status.thresholds.soft_min_free_kb then
            preemptIdleWork()
            Conductor.reclaimMemory("soft", plugin_id)
        end
        executeTask(task)
        return handle
    end

    table.insert(_queue, task)
    sortQueue()

    if _active_task == nil and _active_fg_count == 0 and Conductor.getActiveSubprocessCount() == 0 then
        pumpQueue()
    else
        schedulePump(0.25)
    end

    return handle
end

--- Notifies the Conductor that the device is suspending.
function Conductor.onSuspend()
    _is_suspended = true
    if _active_task and _active_task.priority == "idle_bg" then
        if type(_active_task.cancel) == "function" then
            pcall(_active_task.cancel)
        end
        _active_task.finished = true
        _active_task = nil
    end
    -- Drop queued idle_bg tasks on suspend
    for i = #_queue, 1, -1 do
        local t = _queue[i]
        if t.priority == "idle_bg" then
            t.cancelled = true
            _stats.slots_rejected_suspended = _stats.slots_rejected_suspended + 1
            if type(t.on_rejected) == "function" then
                pcall(t.on_rejected, "suspended")
            end
            table.remove(_queue, i)
        end
    end
    Conductor.reclaimMemory("soft")

    local total_interventions = _stats.slots_requested + _stats.reclaims_soft + _stats.reclaims_critical + _stats.subprocesses_tracked
    if total_interventions > 0 then
        logInfo(string.format(
            "session summary: slots=%d (done=%d, dedup=%d, low_mem=%d, preempt=%d), reclaims=%d/%d, forks=%d",
            _stats.slots_requested, _stats.slots_completed, _stats.slots_deduplicated,
            _stats.slots_rejected_low_mem, _stats.slots_preempted,
            _stats.reclaims_soft, _stats.reclaims_critical, _stats.subprocesses_tracked))
    end
end

--- Notifies the Conductor that the device has resumed from suspend.
function Conductor.onResume()
    _is_suspended = false
    if #_queue > 0 then
        schedulePump(1.0)
    end
end

--- Installs transparent runtime wrappers on UIManager and ffi/util.
--- Table-aware and idempotent: safe across module load, init(), and test mocks.
---@return boolean
function Conductor.installHooks()
    local UIManager = getUIManager()
    if UIManager and type(UIManager.scheduleIn) == "function" and not UIManager._sf_conductor_hooked then
        UIManager._sf_conductor_hooked = true
        local orig_scheduleIn = UIManager.scheduleIn
        local orig_unschedule = UIManager.unschedule
        _orig_scheduleIn = orig_scheduleIn

        UIManager.scheduleIn = function(self_ui, delay, action, ...)
            if not _enabled or _is_conductor_internal or type(action) ~= "function" then
                return orig_scheduleIn(self_ui, delay, action, ...)
            end

            local num_delay = tonumber(delay) or 0
            local caller_plugin = Conductor.identifyCallerPlugin()

            -- Pass through core KOReader timers, micro-timers, foreground plugins,
            -- and polling timers from a plugin that owns an active subprocess.
            if num_delay <= MICRO_TIMER_THRESHOLD_S
                or not caller_plugin
                or Conductor.isPluginInForeground(caller_plugin)
                or Conductor.hasActiveSubprocessForPlugin(caller_plugin) then
                return orig_scheduleIn(self_ui, delay, action, ...)
            end

            local extra_args = { ... }
            local extra_n = select("#", ...)
            local wrapped_fn
            wrapped_fn = function()
                local list = _action_map[action]
                if type(list) == "table" then
                    for i = #list, 1, -1 do
                        if list[i] == wrapped_fn then
                            table.remove(list, i)
                        end
                    end
                    if #list == 0 then
                        _action_map[action] = nil
                    end
                end
                if not _enabled or Conductor.isPluginInForeground(caller_plugin) or Conductor.hasActiveSubprocessForPlugin(caller_plugin) then
                    action(unpack(extra_args, 1, extra_n))
                    return
                end
                Conductor.requestSlot({
                    plugin = caller_plugin,
                    task = "scheduled_timer",
                    priority = "idle_bg",
                    sync = true,
                    dedupe_key = action,
                    _orig_action = action,
                    run = function()
                        action(unpack(extra_args, 1, extra_n))
                    end,
                })
            end

            if not _action_map[action] then
                _action_map[action] = {}
            end
            table.insert(_action_map[action], wrapped_fn)
            return orig_scheduleIn(self_ui, delay, wrapped_fn)
        end

        if type(orig_unschedule) == "function" then
            UIManager.unschedule = function(self_ui, action, ...)
                local removed_queued = false
                local removed_wrapped = false
                if type(action) == "function" then
                    for i = #_queue, 1, -1 do
                        if _queue[i].orig_action == action and not _queue[i].cancelled then
                            _queue[i].cancelled = true
                            removed_queued = true
                        end
                    end
                    local wrappers = _action_map[action]
                    if type(wrappers) == "table" then
                        _action_map[action] = nil
                        for _, wrapped in ipairs(wrappers) do
                            local ok_u, res = pcall(orig_unschedule, self_ui, wrapped, ...)
                            if ok_u and res then
                                removed_wrapped = true
                            end
                        end
                    end
                end
                local removed_orig = orig_unschedule(self_ui, action, ...)
                return (removed_wrapped or removed_orig or removed_queued) == true
            end
        end
    end

    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if ok_ffi and type(ffiutil) == "table" and type(ffiutil.runInSubProcess) == "function" and not ffiutil._sf_conductor_hooked then
        ffiutil._sf_conductor_hooked = true
        local orig_runInSubProcess = ffiutil.runInSubProcess
        local orig_isSubProcessDone = ffiutil.isSubProcessDone
        local orig_terminateSubProcess = ffiutil.terminateSubProcess
        _orig_isSubProcessDone = orig_isSubProcessDone

        ffiutil.runInSubProcess = function(func, with_pipe, double_fork, ...)
            local caller_plugin = nil
            if _enabled then
                caller_plugin = Conductor.identifyCallerPlugin()
                Conductor.stabilizeBeforeFork(caller_plugin)
            end
            local pid, fd = orig_runInSubProcess(func, with_pipe, double_fork, ...)
            if _enabled and pid and not double_fork then
                _stats.subprocesses_tracked = _stats.subprocesses_tracked + 1
                _active_subprocesses[pid] = {
                    plugin = caller_plugin or "unknown",
                    started_at = nowSeconds(),
                }
            end
            return pid, fd
        end

        local function onSubprocessFinished(pid)
            if pid and _active_subprocesses[pid] then
                _active_subprocesses[pid] = nil
                if Conductor.getActiveSubprocessCount() == 0 then
                    _last_bg_finish_ts = nowSeconds()
                    collectgarbage("step", 100)
                    if #_queue > 0 then
                        schedulePump(math.max(0.05, _cooldown_s))
                    end
                end
            end
        end

        if type(orig_isSubProcessDone) == "function" then
            ffiutil.isSubProcessDone = function(pid, ...)
                local done = orig_isSubProcessDone(pid, ...)
                if done then
                    onSubprocessFinished(pid)
                end
                return done
            end
        end

        if type(orig_terminateSubProcess) == "function" then
            ffiutil.terminateSubProcess = function(pid, ...)
                onSubprocessFinished(pid)
                return orig_terminateSubProcess(pid, ...)
            end
        end
    end

    logDbg("runtime hooks installed")
    return true
end

--- Resets internal Conductor state (intended strictly for unit tests).
function Conductor._resetForTests()
    _enabled = true
    _is_suspended = false
    _is_conductor_internal = false
    _meminfo_path_override = nil
    _clock_fn = nil
    _cooldown_s = 0
    _slot_lease_s = DEFAULT_SLOT_LEASE_S
    _last_bg_finish_ts = 0
    _last_stabilize_ts = -999
    _last_soft_reclaim_ts = -999
    _last_critical_reclaim_ts = -999
    _seq = 0
    _queue = {}
    _active_task = nil
    _active_fg_count = 0
    _pump_scheduled = false
    _registered_plugins = {}
    _active_subprocesses = {}
    _action_map = setmetatable({}, { __mode = "k" })
    _stats = newStats()
end

return Conductor
