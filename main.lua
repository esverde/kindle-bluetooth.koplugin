local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Event = require("ui/event")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local ffi = require("ffi")
local C = ffi.C

local AXIS_CENTER_DEFAULT = 32768
local AXIS_THRESHOLD_DEFAULT = 16384
local POWER_RESET_INTERVAL = 60  -- 系统休眠计时器重置间隔（秒）
local STATE_CACHE_INTERVAL = 2   -- 蓝牙开关状态缓存时长（秒）
local DEFAULT_PROFILE = "xbox_wireless_controller"
local ABS_MT_FIRST = 47          -- ABS_MT_SLOT，其后均为多点触控轴

-- Kindle 内部输入设备（永不当作手柄）
local SYSTEM_DEVICE_NAMES = {
    "pt_mt", "goodix-ts", "bd71828-pwrkey", "max77696-onkey",
    "gpio-keys", "hall_sensor", "accel",
}

-- 典型蓝牙手柄/键盘的设备名关键词
local CONTROLLER_KEYWORDS = {
    "controller", "gamepad", "joystick", "xbox", "playstation",
    "8bitdo", "wireless", "bluetooth", "hid", "keyboard",
}

-- 蓝牙栈崩溃时留在存储卡上的转储文件
local DUMP_PATTERNS = {
    "/mnt/us/audiomgrd_*.core",
    "/mnt/us/btmanagerd_*.core",
    "/mnt/us/Indexer_Dump_*.txt",
    "/mnt/us/documents/audiomgrd_*_crash_*",
    "/mnt/us/documents/btmanagerd_*_crash_*",
    "/mnt/us/documents/*btmanagerd*.sdr",
    "/mnt/us/documents/*audiomgrd*.sdr",
}

-- MODULE-LEVEL shared state (persists across all instances)
-- This is critical because KOReader may create multiple plugin instances
-- 所有节流用的时间都走 time.now()（单调钟）：Kindle 唤醒后会联网对时，
-- os.time() 往回跳会让"距上次多久"变成负数，把节流窗口永久冻住。
local _shared_last_trigger_time = nil      -- Time of last page turn (time_fts)
local _shared_last_power_reset_time = nil   -- Time of last screensaver timer reset (time_fts)
local _shared_hook_registered = false      -- Whether hook has been registered
local _shared_triggered = false            -- Whether joystick has triggered (must return to center to reset)
local _shared_axis_values = {}             -- Track all axis values for all-axes-centered check
local _current_active_controller = nil     -- Track the active controller instance for global hook delegate

-- 任何影响输入解析的变更（换设备、换配置、换模式）都必须清掉去抖状态
local function resetInputState()
    _shared_axis_values = {}
    _shared_triggered = false
end

local function nameMatches(lower_name, keywords)
    for _i, keyword in ipairs(keywords) do
        if lower_name:find(keyword, 1, true) then return true end
    end
    return false
end

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,

    -- Configuration loaded from bluetooth.lua (applyConfig 会用实例表覆盖)
    config = {},
    full_config = {},
    settings_file = nil,  -- Dynamically set in init()
    _config_loaded = false,  -- 配置文件读成功过才允许回写，见 saveFullConfig

    -- 默认值的唯一归宿（applyConfig 只在配置里有值时覆盖）
    wakeup_delay = 3,
    trigger_cooldown_ms = 500,

    -- Cached hardware state (see getDisplayState)
    _state_cached = false,
    _state_time = nil,

    -- Wakeup reconnect task handle
    _wakeup_task = nil,
}

function BluetoothController:init()
    if not Device:isKindle() then return end

    -- 用实例表，别写进类原型（loadSettings 失败时 applyConfig 不会跑）
    self.config = {}
    self.full_config = {}

    -- self.path 由 PluginLoader 注入（pluginloader.lua: plugin_module.path = plugin_root）
    self.settings_file = self.path .. "/bluetooth.lua"

    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Prevent duplicate hook registration on reload
    self:registerInputHook()

    -- Attempt initial device connection
    self:openDevice(false)
end

-- =======================================================
--  Settings Management
-- =======================================================

function BluetoothController:loadSettings()
    local loader = loadfile(self.settings_file)
    if not loader then
        logger.warn("BT Plugin: Config file missing or unparsable, using defaults")
        return
    end

    local ok, full_config = pcall(loader)
    if not ok or type(full_config) ~= "table" then
        logger.warn("BT Plugin: Failed to evaluate config file")
        return
    end

    self.full_config = full_config
    self._config_loaded = true
    self:applyConfig()
end

-- Apply the in-memory full_config to the active runtime fields (no file I/O)
function BluetoothController:applyConfig()
    -- 默认值只有类表上那一份（见 wakeup_delay / trigger_cooldown_ms）
    local common = self.full_config.common or {}
    self.wakeup_delay = common.wakeup_delay or self.wakeup_delay
    self.trigger_cooldown_ms = common.trigger_cooldown_ms or self.trigger_cooldown_ms
    self.active_profile = common.active_profile or DEFAULT_PROFILE

    -- 整表重建，避免上一份 profile 的键残留
    self.config = { invert_layout = common.invert_layout or false }
    resetInputState()

    local profile = self.full_config.profiles and self.full_config.profiles[self.active_profile]
    if not profile then
        logger.warn("BT Plugin: Profile '" .. tostring(self.active_profile) .. "' not found in bluetooth.lua")
        return
    end

    for k, v in pairs(profile) do
        self.config[k] = v
    end
    -- 两种键名拼写都受支持（手工编辑过的配置可能用的是 analog_threshold）
    self.config.analog_threshold = profile.axis_threshold or profile.analog_threshold or AXIS_THRESHOLD_DEFAULT
    logger.info("BT Plugin: Loaded profile '" .. (profile.name or self.active_profile) .. "'")
end

-- Save full configuration back to file（写法同 LuaSettings:flush）
function BluetoothController:saveFullConfig()
    -- 从没成功读到过配置时绝不回写：否则一次菜单操作就会把整份 profiles 覆盖成 {common={...}}
    if not self._config_loaded then
        logger.warn("BT Plugin: Refusing to overwrite config file that was never loaded successfully")
        return
    end

    -- 这份文件是用户手工维护的（注释会被 dump 抹掉），先留一份 .old 备份。
    -- 同 LuaSettings:backup：只在文件 60 秒内没被改过时才备份，避免刚写的内容被自己覆盖掉备份。
    local directory_updated
    if lfs.attributes(self.settings_file, "mode") == "file"
        and lfs.attributes(self.settings_file, "modification") < os.time() - 60 then
        os.rename(self.settings_file, self.settings_file .. ".old")
        directory_updated = true
    end

    -- dump(..., ordered=true) 保证键序稳定，配置文件不会每次改动都整体重排
    local ok, err = util.writeToFile(dump(self.full_config, nil, true), self.settings_file,
                                     true, true, directory_updated)
    if ok then
        logger.info("BT Plugin: Configuration saved")
    else
        logger.warn("BT Plugin: Failed to write config file -> " .. tostring(err))
    end
end

function BluetoothController:setCommonSetting(key, value)
    self.full_config = self.full_config or {}
    self.full_config.common = self.full_config.common or {}
    self.full_config.common[key] = value
    self:saveFullConfig()
end

function BluetoothController:setActiveProfileSetting(key, value)
    local profiles = self.full_config and self.full_config.profiles
    local profile = profiles and self.active_profile and profiles[self.active_profile]
    if profile then
        profile[key] = value
        self:saveFullConfig()
    end
end

-- =======================================================
--  Input Hook Management
-- =======================================================

function BluetoothController:registerInputHook()
    -- Always update active controller instance reference
    _current_active_controller = self

    -- Only register once per KOReader session (module-level check)
    if _shared_hook_registered then return end

    Device.input:registerEventAdjustHook(function(_input_instance, ev)
        if _current_active_controller then _current_active_controller:handleInputEvent(ev) end
    end)
    _shared_hook_registered = true
end

-- =======================================================
--  Device Connection Management
-- =======================================================

function BluetoothController:deviceExists(path)
    return path ~= nil and path ~= "" and lfs.attributes(path, "mode") ~= nil
end

function BluetoothController:openDevice(is_reload)
    local path = self.config.device_path
    if not path or path == "" then
        logger.warn("BT Plugin: No device path configured")
        return false
    end

    if self:isDeviceOpened(path) then
        if not is_reload then return true end
        -- 必须先关：节点已消失时若保留 fd，isDeviceOpened 会永远为真，
        -- handleInputEvent 的闸门就一直开着，去拦截并吞掉其它设备的事件（不重启无法恢复）。
        -- 代价是唤醒瞬间 open 偶发失败会丢掉一个本来还在工作的 fd，
        -- 但那种情况下一次唤醒或「重新加载设备」就能重连，是可恢复的一侧。
        self:closeDevice()
    end

    if not self:deviceExists(path) then
        logger.info("BT Plugin: Device " .. path .. " not found")
        return false
    end

    resetInputState()

    local success, err = pcall(Device.input.open, Device.input, path)
    if success then
        logger.info("BT Plugin: Opened device " .. path)
    else
        logger.warn("BT Plugin: Failed to open " .. path .. " -> " .. tostring(err))
    end
    return success
end

-- Close the currently configured device node, if open
function BluetoothController:closeDevice()
    local path = self.config.device_path
    if path and self:isDeviceOpened(path) then
        logger.info("BT Plugin: Closing device " .. path)
        pcall(Device.input.close, Device.input, path)
    end
end

function BluetoothController:reloadDevice()
    return self:openDevice(true)
end

-- Check if a device is currently opened
function BluetoothController:isDeviceOpened(path)
    return Device.input.opened_devices[path] ~= nil
end

-- Whether any configured profile claims this device node
function BluetoothController:isProfilePath(path)
    local profiles = self.full_config and self.full_config.profiles
    if not profiles then return false end
    for _id, profile in pairs(profiles) do
        if profile.device_path == path then return true end
    end
    return false
end

-- Scan for JOYSTICK / Bluetooth input devices from sysfs and KOReader registry
function BluetoothController:scanJoystickDevices()
    local devices = {}

    -- Scan sysfs /sys/class/input/event0 .. event15
    for i = 0, 15 do
        local name_file = io.open("/sys/class/input/event" .. i .. "/device/name", "r")
        if name_file then
            local raw_name = name_file:read("*line")
            name_file:close()

            local clean_name = raw_name and util.trim(raw_name)
            if clean_name and clean_name ~= "" then
                local dev_path = "/dev/input/event" .. i
                local lower_name = clean_name:lower()
                local is_opened = self:isDeviceOpened(dev_path)

                -- 排除 Kindle 内部硬件；其余只要已打开、被配置引用或名字像手柄就列出
                if not nameMatches(lower_name, SYSTEM_DEVICE_NAMES)
                    and (is_opened
                         or nameMatches(lower_name, CONTROLLER_KEYWORDS)
                         or self:isProfilePath(dev_path)) then
                    table.insert(devices, {
                        path = dev_path,
                        name = clean_name,
                        opened = is_opened,
                    })
                    logger.info("BT Plugin: Found input device: " .. clean_name .. " at " .. dev_path .. " (opened=" .. tostring(is_opened) .. ")")
                end
            end
        end
    end

    return devices
end

-- =======================================================
--  Hardware State Management
-- =======================================================

-- Query Bluetooth radio state (BTstate: 0=off, >0=on)
-- io.popen 在内存吃紧的 Kindle 上可能直接抛错，不能让它冒到菜单渲染路径上
function BluetoothController:getRealState()
    local ok, output = pcall(function()
        local pipe = io.popen("lipc-get-prop com.lab126.btfd BTstate")
        if not pipe then return nil end
        local result = pipe:read("*all")
        pipe:close()
        return result
    end)
    return ok and (tonumber(output) or 0) > 0
end

-- 菜单 checked_func 每次重绘都会调用，而 getRealState 要 fork 一个进程，故缓存
function BluetoothController:getDisplayState()
    if self._state_time and time.since(self._state_time) < time.s(STATE_CACHE_INTERVAL) then
        return self._state_cached
    end
    self._state_cached = self:getRealState()
    self._state_time = time.now()
    return self._state_cached
end

function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1  -- BTflightMode: 0 = BT on, 1 = BT off
    local cmd = string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val)
    local exit_code = os.execute(cmd)

    if exit_code ~= 0 then
        logger.warn("BT Plugin: Failed to execute: " .. cmd .. " (exit code: " .. tostring(exit_code) .. ")")
        -- 不缓存未生效的状态，否则接下来 2 秒内菜单会显示硬件从未进入的状态
        UIManager:show(InfoMessage:new { text = _("蓝牙切换失败"), timeout = 2 })
        return
    end

    self._state_cached = enable
    self._state_time = time.now()
    local msg = enable and _("Bluetooth enabled") or _("Bluetooth disabled")
    UIManager:show(InfoMessage:new { text = msg, timeout = 2 })
end

function BluetoothController:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_kindle_bluetooth", {
        category = "none",
        event = "ToggleBluetooth",
        title = _("Toggle Kindle Bluetooth"),
        general = true
    })
end

-- =======================================================
--  System Event Handlers
-- =======================================================

-- 对应 onDispatcherRegisterActions 注册的 "ToggleBluetooth"（原先注册了但没有处理函数）
function BluetoothController:onToggleBluetooth()
    self:setBluetoothState(not self:getDisplayState())
    return true
end

function BluetoothController:onOutOfScreenSaver()
    logger.info("BT Plugin: Device wakeup detected, scheduling reload...")
    if self._wakeup_task then
        UIManager:unschedule(self._wakeup_task)
        self._wakeup_task = nil
    end

    -- UIManager:scheduleIn 不返回句柄（uimanager.lua:335），unschedule 要的是同一个函数本身
    local task
    task = function()
        if self._wakeup_task == task then self._wakeup_task = nil end
        if self:reloadDevice() then
            UIManager:show(InfoMessage:new{ text = _("BT Controller Reconnected"), timeout = 2 })
        end
    end
    self._wakeup_task = task
    UIManager:scheduleIn(self.wakeup_delay, task)
end

-- =======================================================
--  Input Event Processing
-- =======================================================

-- Reset Kindle system screensaver/sleep countdown (throttled)
function BluetoothController:pokeActivity()
    if not _shared_last_power_reset_time
        or time.since(_shared_last_power_reset_time) >= time.s(POWER_RESET_INTERVAL) then
        _shared_last_power_reset_time = time.now()
        local PowerD = Device:getPowerDevice()
        if PowerD and PowerD.resetT1Timeout then
            PowerD:resetT1Timeout()
        end
    end
end

-- ponytail: registerEventAdjustHook 只递交裸的 input_event（input.lua:1684），不带来源设备，
-- 所以"这个事件是不是手柄发的"无法真正判断，只能靠 isDeviceOpened + 映射表近似。
-- 后果：单点触控屏（非 protocol B，ABS_X=0/ABS_Y=1）会撞上 analog_map 的轴号，
-- 造成误翻页且吞掉触摸。要根治得让 KOReader 在事件上带 fd/设备标识。
function BluetoothController:handleInputEvent(ev)
    -- 这个 hook 会收到所有输入设备的事件，先用最便宜的整数比较筛掉多点触控
    -- (ABS_MT_* codes >= 47: ABS_MT_POSITION_X=53, ABS_MT_POSITION_Y=54, etc.)
    if ev.type == C.EV_ABS and ev.code >= ABS_MT_FIRST then
        return
    end

    -- Ignore all events if bluetooth controller device is not currently opened
    if not self:isDeviceOpened(self.config.device_path) then
        return
    end

    local direction = self:parseInputDirection(ev)
    if not direction then return end

    -- Keep screen/system awake
    self:pokeActivity()

    if self.config.invert_layout then
        direction = -direction
    end

    UIManager:sendEvent(Event:new("GotoViewRel", direction))
    ev.type = -1 -- Consume event
end

function BluetoothController:parseInputDirection(ev)
    -- Handle key press events
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        return self.config.key_map and self.config.key_map[ev.code]
    end

    -- Handle axis events
    if ev.type == C.EV_ABS then
        if self.config.use_analog_mode then
            return self:parseAnalogInput(ev)
        else
            return self:parseDpadInput(ev)
        end
    end

    return nil
end

-- Parse D-pad discrete axis input (codes 16, 17 with values -1, 0, 1)
function BluetoothController:parseDpadInput(ev)
    if ev.value == 0 then return nil end
    local axis_map = self.config.dpad_map and self.config.dpad_map[ev.code]
    return axis_map and axis_map[ev.value]
end

-- Parse analog joystick input (codes 0, 1 with values 0-65535)
-- Uses COMBINED debouncing: state-based (must return to deadzone) + time-based
function BluetoothController:parseAnalogInput(ev)
    if not self.config.analog_map then return nil end
    local mapping = self.config.analog_map[ev.code]
    if not mapping then return nil end

    local center = (self.config.analog_center or {})[ev.code] or AXIS_CENTER_DEFAULT
    local threshold = self.config.analog_threshold or AXIS_THRESHOLD_DEFAULT
    local deviation = math.abs(ev.value - center)

    _shared_axis_values[ev.code] = deviation

    -- Check if within dead zone
    if deviation <= threshold then
        -- Only reset triggered state if ALL mapped axes are in dead zone
        if _shared_triggered then
            local all_centered = true
            for axis_code, axis_deviation in pairs(_shared_axis_values) do
                if self.config.analog_map[axis_code] and axis_deviation > threshold then
                    all_centered = false
                    break
                end
            end
            if all_centered then
                _shared_triggered = false
            end
        end
        return nil
    end

    -- State-based debouncing: must have returned to center
    if _shared_triggered then return nil end

    -- Time-based debouncing: check cooldown
    if _shared_last_trigger_time
        and time.since(_shared_last_trigger_time) < time.ms(self.trigger_cooldown_ms) then
        return nil
    end

    -- Trigger action
    _shared_triggered = true
    _shared_last_trigger_time = time.now()

    if ev.value < center then
        return mapping.low_dir
    else
        return mapping.high_dir
    end
end

-- =======================================================
--  Bluetooth Dump File Cleanup
-- =======================================================

function BluetoothController:cleanupBluetoothDumps()
    os.execute("rm -rf " .. table.concat(DUMP_PATTERNS, " ") .. " 2>/dev/null")
    logger.info("BT Plugin: Cleaned up bluetooth dump files")
end

-- =======================================================
--  Menu Interface
-- =======================================================

-- 设备状态 → (标签, 说明)，索引为 [是否当前配置][是否已在 KOReader 打开]
-- 这里存原文，_() 在使用处调用：模块只加载一次，在此翻译会把语言冻结在加载时刻
local DEVICE_STATUS = {
    [true] = {
        [true]  = { " [当前]",   "已连接并在 KOReader 中打开" },
        [false] = { " [已配置]", "已配置为此设备（未打开）" },
    },
    [false] = {
        [true]  = { " [已连接]", "已在 KOReader 中打开" },
        [false] = { " [可用]",   "系统蓝牙已连接（可配置使用）" },
    },
}

function BluetoothController:addToMainMenu(menu_items)
    -- 「模拟摇杆」/「方向键」只差一个布尔值
    local function joystickModeItem(text, analog)
        return {
            text = text,
            checked_func = function()
                return (self.config.use_analog_mode == true) == analog
            end,
            callback = function()
                self.config.use_analog_mode = analog
                resetInputState()
                self:setActiveProfileSetting("use_analog_mode", analog)
            end,
        }
    end

    local sub_items = {}

    -- 1. Bluetooth Toggle
    table.insert(sub_items, {
        text = _("蓝牙开关"),
        keep_menu_open = true,
        checked_func = function() return self:getDisplayState() end,
        callback = function(touchmenu_instance)
            self:setBluetoothState(not self:getDisplayState())
            touchmenu_instance:updateItems()
        end,
    })

    -- 2. Connected Devices (Sub-menu with device names and detailed info dialogs)
    table.insert(sub_items, {
        text = _("已连接设备"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local devices = self:scanJoystickDevices()
            if #devices == 0 then
                return { {
                    text = _("未发现蓝牙手柄"),
                    enabled_func = function() return false end,
                } }
            end

            local items = {}
            for _i, dev in ipairs(devices) do
                local is_current = (dev.path == self.config.device_path)
                local status_tag, status_desc = unpack(DEVICE_STATUS[is_current][dev.opened])
                status_tag, status_desc = _(status_tag), _(status_desc)

                table.insert(items, {
                    text = dev.name .. status_tag,
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = string.format(
                                _("设备名称: %s\n设备节点: %s\n连接状态: %s"),
                                dev.name, dev.path, status_desc),
                            timeout = 4,
                        })
                    end,
                })
            end
            return items
        end,
    })

    -- 3. Switch Profile
    table.insert(sub_items, {
        text = _("切换配置"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local profiles = {}

            for profile_id, profile in pairs((self.full_config or {}).profiles or {}) do
                table.insert(profiles, {
                    text = profile.name or profile_id,
                    checked_func = function()
                        return self.active_profile == profile_id
                    end,
                    callback = function()
                        -- 换 profile 可能换设备节点：旧节点不关掉，KOReader 会继续轮询它，
                        -- 而它的事件会被套上新 profile 的映射照样翻页
                        self:closeDevice()
                        self:setCommonSetting("active_profile", profile_id)
                        self:applyConfig()
                        UIManager:show(InfoMessage:new{
                            text = self:reloadDevice()
                                and _("已切换到 ") .. (profile.name or profile_id)
                                or _("配置已切换，但未找到设备"),
                            timeout = 2,
                        })
                    end,
                })
            end

            return profiles
        end,
    })

    -- 4. Invert direction
    table.insert(sub_items, {
        text = _("反转方向"),
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            self:setCommonSetting("invert_layout", self.config.invert_layout)
        end
    })

    -- 5. Joystick Mode (only enabled if controller supports D-Pad)
    table.insert(sub_items, {
        text = _("摇杆模式"),
        enabled_func = function()
            return self.config.supports_dpad == true
        end,
        sub_item_table = {
            joystickModeItem(_("模拟摇杆"), true),
            joystickModeItem(_("方向键"), false),
        }
    })

    -- 6. Wakeup Delay
    table.insert(sub_items, {
        text = _("唤醒延迟"),
        keep_menu_open = true,
        callback = function()
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("设置唤醒延迟（秒）"),
                value = self.wakeup_delay,
                value_min = 1,
                value_max = 10,
                value_step = 1,
                value_hold_step = 2,
                ok_text = _("确定"),
                callback = function(spin)
                    self.wakeup_delay = spin.value
                    self:setCommonSetting("wakeup_delay", spin.value)

                    UIManager:show(InfoMessage:new{
                        text = _("唤醒延迟已设置为 ") .. spin.value .. _(" 秒"),
                        timeout = 2
                    })
                end
            })
        end,
    })

    -- 7. Reload device (也重读配置文件，方便手工编辑 bluetooth.lua 后生效)
    table.insert(sub_items, {
        text = _("重新加载设备"),
        callback = function()
            self:loadSettings()
            UIManager:show(InfoMessage:new{
                text = self:reloadDevice() and _("设备已加载") or _("加载失败"),
                timeout = 2,
            })
        end
    })

    -- 8. Clean up Bluetooth dump files
    table.insert(sub_items, {
        text = _("清理蓝牙垃圾"),
        callback = function()
            self:cleanupBluetoothDumps()
            UIManager:show(InfoMessage:new{
                text = _("已清理蓝牙转储垃圾文件"),
                timeout = 2
            })
        end
    })

    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

function BluetoothController:onExit()
    if self._wakeup_task then
        UIManager:unschedule(self._wakeup_task)
        self._wakeup_task = nil
    end
    -- 松开模块级强引用，否则整棵 ReaderUI 会跟着这个实例一起活到进程退出
    if _current_active_controller == self then
        _current_active_controller = nil
    end
    return true
end

return BluetoothController
