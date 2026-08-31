local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")

local Event = require("ui/event")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local ffi = require("ffi")
local C = ffi.C

local AXIS_CENTER_DEFAULT = 32768
local AXIS_THRESHOLD_DEFAULT = 16384
local POWER_RESET_INTERVAL = 60  -- 系统休眠计时器重置间隔（秒）

-- MODULE-LEVEL shared state (persists across all instances)
-- This is critical because KOReader may create multiple plugin instances
local _shared_last_trigger_time = nil      -- Time of last page turn
local _shared_last_power_reset_time = 0    -- Timestamp of last screensaver timer reset
local _shared_hook_registered = false      -- Whether hook has been registered
local _shared_triggered = false            -- Whether joystick has triggered (must return to center to reset)
local _shared_axis_values = {}             -- Track all axis values for all-axes-centered check
local _current_active_controller = nil     -- Track the active controller instance for global hook delegate

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,

    -- State variables for Bluetooth toggle debouncing
    last_action_time = 0,
    target_state = false,

    -- Configuration loaded from bluetooth.lua
    config = {},
    full_config = {},
    settings_file = nil,  -- Dynamically set in getPluginDir()

    -- Hook activity state (per-instance, allows disabling without unregistering)
    _hook_active = true,

    -- Wakeup reconnect task handle
    _wakeup_task = nil,
}

function BluetoothController:init()
    if not Device:isKindle() then return end

    local plugin_dir = self:getPluginDir()
    self.settings_file = plugin_dir .. "/bluetooth.lua"

    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Prevent duplicate hook registration on reload
    self:registerInputHook()

    -- Attempt initial device connection
    self:ensureConnected()
end

-- =======================================================
--  Plugin Directory Detection
-- =======================================================

function BluetoothController:getPluginDir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    if script_path then
        return script_path:match("(.+)/[^/]+$") or script_path:match("(.+)\\[^\\]+$") or "."
    end
    return "."
end

-- =======================================================
--  Settings Management
-- =======================================================

function BluetoothController:loadSettings()
    local file = io.open(self.settings_file, "r")
    if not file then
        logger.warn("BT Plugin: Config file not found, using defaults")
        return
    end

    local content = file:read("*all")
    file:close()

    local loader = loadstring(content)
    if not loader then
        logger.warn("BT Plugin: Failed to parse config file")
        return
    end

    local full_config = loader()
    if not full_config then return end

    -- Load common settings
    if full_config.common then
        self.wakeup_delay = full_config.common.wakeup_delay or 3
        self.trigger_cooldown_ms = full_config.common.trigger_cooldown_ms or 500
        self.config.invert_layout = full_config.common.invert_layout or false
        self.active_profile = full_config.common.active_profile or "xbox_wireless_controller"
    end

    -- Load active profile configuration
    if full_config.profiles and full_config.profiles[self.active_profile] then
        local profile = full_config.profiles[self.active_profile]

        -- Merge profile settings into self.config
        self.config.device_path = profile.device_path
        self.config.supports_dpad = profile.supports_dpad
        self.config.use_analog_mode = profile.use_analog_mode
        self.config.key_map = profile.key_map
        self.config.dpad_map = profile.dpad_map
        self.config.analog_map = profile.analog_map
        self.config.analog_center = profile.analog_center
        self.config.analog_threshold = profile.axis_threshold

        logger.info("BT Plugin: Loaded profile '" .. (profile.name or self.active_profile) .. "'")
    else
        logger.warn("BT Plugin: Profile '" .. tostring(self.active_profile) .. "' not found in bluetooth.lua")
        logger.warn("BT Plugin: Please ensure bluetooth.lua exists and contains valid profile configuration")
    end

    -- Store full config for menu access
    self.full_config = full_config
end

-- Save full configuration back to file
function BluetoothController:saveFullConfig()
    if not self.full_config then return end

    local file = io.open(self.settings_file, "w")
    if not file then
        logger.warn("BT Plugin: Failed to open config file for writing")
        return
    end

    -- Recursive serializer with indentation
    local function serialize(obj, level)
        level = level or 0
        local indent = string.rep("    ", level)
        local next_indent = string.rep("    ", level + 1)

        if type(obj) == "table" then
            local result = "{\n"

            -- Collect and sort keys
            local keys = {}
            for k in pairs(obj) do table.insert(keys, k) end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)

            for _, k in ipairs(keys) do
                local v = obj[k]
                local key_str = type(k) == "number"
                    and "[" .. k .. "]"
                    or "[\"" .. tostring(k) .. "\"]"

                result = result .. next_indent .. key_str .. " = " .. serialize(v, level + 1) .. ",\n"
            end
            return result .. indent .. "}"
        elseif type(obj) == "string" then
            return string.format("%q", obj)
        else
            return tostring(obj)
        end
    end

    file:write("return " .. serialize(self.full_config))
    file:close()
    logger.info("BT Plugin: Configuration saved")
end

-- =======================================================
--  Input Hook Management
-- =======================================================

function BluetoothController:registerInputHook()
    -- Always update active controller instance reference
    _current_active_controller = self

    -- Only register once per KOReader session (module-level check)
    if _shared_hook_registered then
        self._hook_active = true  -- Re-activate if previously disabled
        return
    end

    local hook_func = function(_input_instance, ev)
        local controller = _current_active_controller
        -- Only process events when hook is active on current controller
        if controller and controller._hook_active then
            controller:handleInputEvent(ev)
        end
    end

    Device.input:registerEventAdjustHook(hook_func)
    _shared_hook_registered = true
end

-- =======================================================
--  Device Connection Management
-- =======================================================

function BluetoothController:ensureConnected()
    local path = self.config.device_path
    if not path or path == "" then return false end

    if self:isDeviceOpened(path) then return true end

    -- Check if device file exists
    if not self:deviceExists(path) then
        logger.info("BT Plugin: Device " .. path .. " not found")
        return false
    end

    local success, err = self:_attemptOpenDevice(path)
    if not success then
        logger.warn("BT Plugin: Failed to open -> " .. tostring(err))
    end

    return success
end

function BluetoothController:deviceExists(path)
    if not path or path == "" then return false end
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Helper: encapsulate critical section for opening device
function BluetoothController:_attemptOpenDevice(path)
    local input = Device.input
    if not input then return false, "No Input Module" end

    -- Reset shared state on new connection
    _shared_axis_values = {}
    _shared_triggered = false

    local success, err = pcall(function() input:open(path) end)

    if success then
        self:cleanupBluetoothDumps()
    end

    return success, err
end

function BluetoothController:reloadDevice()
    local path = self.config.device_path
    if not path or path == "" then
        logger.warn("BT Plugin: No device path configured")
        return false
    end

    local input = Device.input

    -- Close if already open
    if self:isDeviceOpened(path) then
        logger.warn("BT Plugin: Reload - Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end

    -- Reset shared state on reload
    _shared_axis_values = {}
    _shared_triggered = false

    local success = pcall(function() input:open(path) end)

    -- Auto cleanup dump files after successful reload
    if success then
        self:cleanupBluetoothDumps()
    end

    return success
end

-- Scan for JOYSTICK / Bluetooth input devices from sysfs and KOReader registry
function BluetoothController:scanJoystickDevices()
    local devices = {}
    local seen_paths = {}

    -- Known Kindle internal system devices to ignore
    local system_devices = {
        ["pt_mt"] = true,
        ["goodix-ts"] = true,
        ["bd71828-pwrkey"] = true,
        ["max77696-onkey"] = true,
        ["gpio-keys"] = true,
        ["hall_sensor"] = true,
        ["accel"] = true,
    }

    -- Scan sysfs /sys/class/input/event0 .. event15
    for i = 0, 15 do
        local dev_path = "/dev/input/event" .. i
        local sys_name_path = "/sys/class/input/event" .. i .. "/device/name"
        local name_file = io.open(sys_name_path, "r")
        if name_file then
            local raw_name = name_file:read("*line")
            name_file:close()

            if raw_name and raw_name ~= "" then
                local clean_name = raw_name:gsub("^%s*(.-)%s*$", "%1")
                local lower_name = clean_name:lower()

                -- Filter out known Kindle internal hardware devices
                local is_system = false
                for sys_name, _ in pairs(system_devices) do
                    if lower_name:find(sys_name, 1, true) then
                        is_system = true
                        break
                    end
                end

                if not is_system then
                    local is_controller = false

                    -- Check 1: Match configured profiles
                    if self.full_config and self.full_config.profiles then
                        for _, profile in pairs(self.full_config.profiles) do
                            if profile.device_path == dev_path then
                                is_controller = true
                                break
                            end
                        end
                    end

                    -- Check 2: Match typical Bluetooth/gamepad device name keywords
                    if not is_controller then
                        if lower_name:find("controller") or lower_name:find("gamepad") or
                           lower_name:find("joystick") or lower_name:find("xbox") or
                           lower_name:find("playstation") or lower_name:find("8bitdo") or
                           lower_name:find("wireless") or lower_name:find("bluetooth") or
                           lower_name:find("hid") or lower_name:find("keyboard") then
                            is_controller = true
                        end
                    end

                    -- Check 3: Check if already opened in KOReader
                    local is_opened = self:isDeviceOpened(dev_path)
                    if is_opened then
                        is_controller = true
                    end

                    if is_controller and not seen_paths[dev_path] then
                        seen_paths[dev_path] = true
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
    end

    return devices
end

-- Check if a device is currently opened
function BluetoothController:isDeviceOpened(path)
    local input = Device.input
    if input and input.opened_devices then
        return input.opened_devices[path] ~= nil
    end
    return false
end

-- =======================================================
--  Hardware State Management
-- =======================================================

function BluetoothController:getRealState()
    local success, output = pcall(function()
        -- Query Bluetooth radio state (BTstate: 0=off, >0=on)
        local pipe = io.popen("lipc-get-prop com.lab126.btfd BTstate")
        if not pipe then return nil end
        local result = pipe:read("*all")
        pipe:close()
        return result
    end)

    if not success or not output then return false end

    return (tonumber(output) or 0) > 0
end

-- Returns cached state if within debounce window, otherwise queries hardware
function BluetoothController:getDisplayState()
    local elapsed = os.time() - self.last_action_time
    if elapsed < 2 then
        return self.target_state
    end
    return self:getRealState()
end

function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1  -- BTflightMode: 0 = BT on, 1 = BT off
    local cmd = string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val)
    local exit_code = os.execute(cmd)

    if exit_code ~= 0 then
        logger.warn("BT Plugin: Failed to execute: " .. cmd .. " (exit code: " .. tostring(exit_code) .. ")")
    end

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

function BluetoothController:onOutOfScreenSaver()
    logger.info("BT Plugin: Device wakeup detected, scheduling reload...")
    if self._wakeup_task then
        UIManager:unschedule(self._wakeup_task)
        self._wakeup_task = nil
    end

    local delay = self.wakeup_delay or 3
    self._wakeup_task = UIManager:scheduleIn(delay, function()
        self._wakeup_task = nil
        if self:deviceExists(self.config.device_path) then
            logger.info("BT Plugin: Wakeup - Device found, reloading...")
            if self:reloadDevice() then
                UIManager:show(InfoMessage:new{ text = _("BT Controller Reconnected"), timeout = 2 })
            end
        else
            logger.info("BT Plugin: Wakeup - Device not found, skipping reload")
        end
    end)
end

-- =======================================================
--  Input Event Processing
-- =======================================================

-- Reset Kindle system screensaver/sleep countdown (throttled)
function BluetoothController:pokeActivity()
    local now = os.time()
    if (now - _shared_last_power_reset_time) >= POWER_RESET_INTERVAL then
        _shared_last_power_reset_time = now
        local PowerD = Device:getPowerDevice()
        if PowerD and PowerD.resetT1Timeout then
            PowerD:resetT1Timeout()
        end
    end
end

function BluetoothController:handleInputEvent(ev)
    -- Ignore all events if bluetooth controller device is not currently opened
    if not self:isDeviceOpened(self.config.device_path) then
        return
    end

    -- Ignore multi-touch ABS events (ABS_MT_* codes >= 47: ABS_MT_POSITION_X=53, ABS_MT_POSITION_Y=54, etc.)
    if ev.type == C.EV_ABS and ev.code >= 47 then
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

    local center = self:getAxisCenter(ev.code)
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
    local now = time:now()
    local now_ms = time.to_ms(now)

    if _shared_last_trigger_time then
        local last_ms = time.to_ms(_shared_last_trigger_time)
        local cooldown_ms = (self.trigger_cooldown_ms or 500)
        if (now_ms - last_ms) < cooldown_ms then
            return nil
        end
    end

    -- Trigger action
    _shared_triggered = true
    _shared_last_trigger_time = now

    if ev.value < center then
        return mapping.low_dir
    else
        return mapping.high_dir
    end
end

-- Get center value for an axis (supports per-axis calibration)
function BluetoothController:getAxisCenter(axis_code)
    local centers = self.config.analog_center
    if centers and centers[axis_code] then
        return centers[axis_code]
    end
    return AXIS_CENTER_DEFAULT
end

-- =======================================================
--  Bluetooth Dump File Cleanup
-- =======================================================

function BluetoothController:cleanupBluetoothDumps()
    local total_deleted = 0

    local cleanup_paths = {
        {
            dir = "/mnt/us",
            patterns = {
                "audiomgrd_*.core",
                "btmanagerd_*.core",
                "Indexer_Dump_*.txt"
            }
        },
        {
            dir = "/mnt/us/documents",
            patterns = {
                "audiomgrd_*_crash_*.tgz",
                "audiomgrd_*_crash_*.txt",
                "btmanagerd_*_crash_*.tgz",
                "btmanagerd_*_crash_*.txt",
                "audiomgrd_*_crash_*.sdr",
                "btmanagerd_*_crash_*.sdr"
            }
        }
    }

    for _, path_config in ipairs(cleanup_paths) do
        local dir = path_config.dir
        for _, pattern in ipairs(path_config.patterns) do
            local find_cmd = string.format("find '%s' -maxdepth 1 -name '%s' 2>/dev/null", dir, pattern)
            local pipe = io.popen(find_cmd)
            if pipe then
                local files = {}
                for file in pipe:lines() do
                    table.insert(files, file)
                end
                pipe:close()

                for _, file in ipairs(files) do
                    local rm_cmd = string.format("rm -rf '%s' 2>/dev/null", file)
                    local success = os.execute(rm_cmd)
                    if success == 0 or success == true then
                        total_deleted = total_deleted + 1
                        logger.info("BT Plugin: Deleted dump file: " .. file)
                    end
                end
            end
        end
    end

    logger.info("BT Plugin: Cleanup completed, deleted " .. total_deleted .. " files/folders")
    return total_deleted
end

-- =======================================================
--  Menu Interface
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    local sub_items = {}

    -- 1. Bluetooth Toggle
    table.insert(sub_items, {
        text = _("蓝牙开关"),
        keep_menu_open = true,
        checked_func = function() return self:getDisplayState() end,
        callback = function(touchmenu_instance)
            local next_state = not self:getDisplayState()
            self.target_state = next_state
            self.last_action_time = os.time()
            touchmenu_instance:updateItems()
            self:setBluetoothState(next_state)
        end,
    })

    -- 2. Connected Devices (Sub-menu with device names and detailed info dialogs)
    table.insert(sub_items, {
        text = _("已连接设备"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local devices = self:scanJoystickDevices()
            local current_device = self.config.device_path
            local items = {}

            if #devices == 0 then
                table.insert(items, {
                    text = _("未发现蓝牙手柄"),
                    enabled_func = function() return false end,
                })
            else
                for _, dev in ipairs(devices) do
                    local is_current = (dev.path == current_device)
                    local status_tag = ""
                    local status_desc = ""

                    if is_current then
                        if dev.opened then
                            status_tag = _(" [当前]")
                            status_desc = _("已连接并在 KOReader 中打开")
                        else
                            status_tag = _(" [已配置]")
                            status_desc = _("已配置为此设备（未打开）")
                        end
                    else
                        if dev.opened then
                            status_tag = _(" [已连接]")
                            status_desc = _("已在 KOReader 中打开")
                        else
                            status_tag = _(" [可用]")
                            status_desc = _("系统蓝牙已连接（可配置使用）")
                        end
                    end

                    table.insert(items, {
                        text = dev.name .. status_tag,
                        callback = function()
                            local detail_msg = string.format(
                                _("设备名称: %s\n设备节点: %s\n连接状态: %s"),
                                dev.name,
                                dev.path,
                                status_desc
                            )
                            UIManager:show(InfoMessage:new{ text = detail_msg, timeout = 4 })
                        end,
                    })
                end
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

            if self.full_config and self.full_config.profiles then
                for profile_id, profile in pairs(self.full_config.profiles) do
                    table.insert(profiles, {
                        text = profile.name or profile_id,
                        checked_func = function()
                            return self.active_profile == profile_id
                        end,
                        callback = function()
                            self.active_profile = profile_id

                            if self.full_config and self.full_config.common then
                                self.full_config.common.active_profile = profile_id
                                self:saveFullConfig()
                            end

                            self:loadSettings()
                            if self:reloadDevice() then
                                UIManager:show(InfoMessage:new{
                                    text = _("已切换到 ") .. (profile.name or profile_id),
                                    timeout = 2
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("配置已切换，但未找到设备"),
                                    timeout = 2
                                })
                            end
                        end,
                    })
                end
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

            if self.full_config and self.full_config.common then
                self.full_config.common.invert_layout = self.config.invert_layout
                self:saveFullConfig()
            end
        end
    })

    -- 5. Joystick Mode (only enabled if controller supports D-Pad)
    table.insert(sub_items, {
        text = _("摇杆模式"),
        enabled_func = function()
            return self.config.supports_dpad == true
        end,
        sub_item_table = {
            {
                text = _("模拟摇杆"),
                checked_func = function() return self.config.use_analog_mode end,
                callback = function()
                    self.config.use_analog_mode = true
                    _shared_triggered = false

                    if self.full_config and self.full_config.profiles and self.active_profile then
                        local profile = self.full_config.profiles[self.active_profile]
                        if profile then
                            profile.use_analog_mode = true
                            self:saveFullConfig()
                        end
                    end
                end
            },
            {
                text = _("方向键"),
                checked_func = function() return not self.config.use_analog_mode end,
                callback = function()
                    self.config.use_analog_mode = false

                    if self.full_config and self.full_config.profiles and self.active_profile then
                        local profile = self.full_config.profiles[self.active_profile]
                        if profile then
                            profile.use_analog_mode = false
                            self:saveFullConfig()
                        end
                    end
                end
            }
        }
    })

    -- 6. Wakeup Delay
    table.insert(sub_items, {
        text = _("唤醒延迟"),
        keep_menu_open = true,
        callback = function()
            local current_delay = self.wakeup_delay or 3
            UIManager:show(SpinWidget:new{
                title_text = _("设置唤醒延迟（秒）"),
                value = current_delay,
                value_min = 1,
                value_max = 10,
                value_step = 1,
                value_hold_step = 2,
                ok_text = _("确定"),
                callback = function(spin)
                    self.wakeup_delay = spin.value

                    if self.full_config and self.full_config.common then
                        self.full_config.common.wakeup_delay = spin.value
                        self:saveFullConfig()
                    end

                    UIManager:show(InfoMessage:new{
                        text = _("唤醒延迟已设置为 ") .. spin.value .. _(" 秒"),
                        timeout = 2
                    })
                end
            })
        end,
    })

    -- 7. Reload device
    table.insert(sub_items, {
        text = _("重新加载设备"),
        callback = function()
            self:loadSettings()
            if self:reloadDevice() then
                UIManager:show(InfoMessage:new{ text = _("设备已加载"), timeout = 2 })
            else
                UIManager:show(InfoMessage:new{ text = _("加载失败"), timeout = 2 })
            end
        end
    })

    -- 8. Clean up Bluetooth dump files
    table.insert(sub_items, {
        text = _("清理蓝牙垃圾"),
        callback = function()
            local count = self:cleanupBluetoothDumps()
            UIManager:show(InfoMessage:new{
                text = string.format(_("已清理 %d 个文件"), count),
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
    return true
end

return BluetoothController
