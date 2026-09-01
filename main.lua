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
local POWER_RESET_INTERVAL = 60
local STATE_CACHE_INTERVAL = 2
local DEFAULT_PROFILE = "xbox_wireless_controller"
local ABS_MT_FIRST = 47

local SYSTEM_DEVICE_NAMES = {
    "pt_mt", "goodix-ts", "bd71828-pwrkey", "max77696-onkey",
    "gpio-keys", "hall_sensor", "accel", "bma4xy_feature", "stylus-custom",
}

local CONTROLLER_KEYWORDS = {
    "controller", "gamepad", "joystick", "xbox", "playstation",
    "8bitdo", "wireless", "bluetooth", "hid", "keyboard",
}

local DUMP_PATTERNS = {
    "/mnt/us/audiomgrd_*.core",
    "/mnt/us/btmanagerd_*.core",
    "/mnt/us/Indexer_Dump_*.txt",
    "/mnt/us/documents/audiomgrd_*_crash_*",
    "/mnt/us/documents/btmanagerd_*_crash_*",
    "/mnt/us/documents/*btmanagerd*.sdr",
    "/mnt/us/documents/*audiomgrd*.sdr",
}

local _shared_last_trigger_time = nil
local _shared_last_power_reset_time = nil
local _shared_hook_registered = false
local _shared_triggered = false
local _shared_axis_values = {}
local _current_active_controller = nil

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

    config = {},
    full_config = {},
    settings_file = nil,
    _config_loaded = false,

    wakeup_delay = 3,
    trigger_cooldown_ms = 500,

    _state_cached = false,
    _state_time = nil,

    _wakeup_task = nil,
}

function BluetoothController:init()
    if not Device:isKindle() then return end
    self.config = {}
    self.full_config = {}
    self.settings_file = self.path .. "/bluetooth.lua"
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerInputHook()
    self:openDevice(false)
end


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

function BluetoothController:applyConfig()
    local common = self.full_config.common or {}
    self.wakeup_delay = common.wakeup_delay or self.wakeup_delay
    self.trigger_cooldown_ms = common.trigger_cooldown_ms or self.trigger_cooldown_ms
    self.active_profile = common.active_profile or DEFAULT_PROFILE

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
    self.config.analog_threshold = profile.axis_threshold or profile.analog_threshold or AXIS_THRESHOLD_DEFAULT
    logger.info("BT Plugin: Loaded profile '" .. (profile.name or self.active_profile) .. "'")
end

function BluetoothController:saveFullConfig()
    if not self._config_loaded then
        logger.warn("BT Plugin: Refusing to overwrite config file that was never loaded successfully")
        return
    end

    local directory_updated
    if lfs.attributes(self.settings_file, "mode") == "file"
        and lfs.attributes(self.settings_file, "modification") < os.time() - 60 then
        os.rename(self.settings_file, self.settings_file .. ".old")
        directory_updated = true
    end

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


function BluetoothController:registerInputHook()
    _current_active_controller = self

    if _shared_hook_registered then return end

    Device.input:registerEventAdjustHook(function(_input_instance, ev)
        if _current_active_controller then _current_active_controller:handleInputEvent(ev) end
    end)
    _shared_hook_registered = true
end


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
-- Close stale fds before reopening so the event gate stays tied to the live device.
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

function BluetoothController:isDeviceOpened(path)
    return Device.input.opened_devices[path] ~= nil
end

function BluetoothController:isProfilePath(path)
    local profiles = self.full_config and self.full_config.profiles
    if not profiles then return false end
    for _id, profile in pairs(profiles) do
        if profile.device_path == path then return true end
    end
    return false
end

function BluetoothController:scanJoystickDevices()
    local devices = {}

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

function BluetoothController:getDisplayState()
    if self._state_time and time.since(self._state_time) < time.s(STATE_CACHE_INTERVAL) then
        return self._state_cached
    end
    self._state_cached = self:getRealState()
    self._state_time = time.now()
    return self._state_cached
end

function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1
    local cmd = string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val)
    local exit_code = os.execute(cmd)

    if exit_code ~= 0 then
        logger.warn("BT Plugin: Failed to execute: " .. cmd .. " (exit code: " .. tostring(exit_code) .. ")")
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

-- Only the configured controller fd is handled.
function BluetoothController:handleInputEvent(ev)
    if ev.type == C.EV_ABS and ev.code >= ABS_MT_FIRST then
        return
    end

    local controller_fd = Device.input.opened_devices[self.config.device_path]
    if not controller_fd or ev.fd ~= controller_fd then
        return
    end

    local direction = self:parseInputDirection(ev)
    if not direction then return end

    self:pokeActivity()

    if self.config.invert_layout then
        direction = -direction
    end

    UIManager:sendEvent(Event:new("GotoViewRel", direction))
    ev.type = -1 -- Consume handled event
end

function BluetoothController:parseInputDirection(ev)
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        return self.config.key_map and self.config.key_map[ev.code]
    end

    if ev.type == C.EV_ABS then
        if self.config.use_analog_mode then
            return self:parseAnalogInput(ev)
        else
            return self:parseDpadInput(ev)
        end
    end

    return nil
end

function BluetoothController:parseDpadInput(ev)
    if ev.value == 0 then return nil end
    local axis_map = self.config.dpad_map and self.config.dpad_map[ev.code]
    return axis_map and axis_map[ev.value]
end

function BluetoothController:parseAnalogInput(ev)
    if not self.config.analog_map then return nil end
    local mapping = self.config.analog_map[ev.code]
    if not mapping then return nil end

    local center = (self.config.analog_center or {})[ev.code] or AXIS_CENTER_DEFAULT
    local threshold = self.config.analog_threshold or AXIS_THRESHOLD_DEFAULT
    local deviation = math.abs(ev.value - center)

    _shared_axis_values[ev.code] = deviation

    if deviation <= threshold then
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

    if _shared_triggered then return nil end

    if _shared_last_trigger_time
        and time.since(_shared_last_trigger_time) < time.ms(self.trigger_cooldown_ms) then
        return nil
    end

    _shared_triggered = true
    _shared_last_trigger_time = time.now()

    if ev.value < center then
        return mapping.low_dir
    else
        return mapping.high_dir
    end
end


function BluetoothController:cleanupBluetoothDumps()
    os.execute("rm -rf " .. table.concat(DUMP_PATTERNS, " ") .. " 2>/dev/null")
    logger.info("BT Plugin: Cleaned up bluetooth dump files")
end


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

    table.insert(sub_items, {
        text = _("蓝牙开关"),
        keep_menu_open = true,
        checked_func = function() return self:getDisplayState() end,
        callback = function(touchmenu_instance)
            self:setBluetoothState(not self:getDisplayState())
            touchmenu_instance:updateItems()
        end,
    })

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

    table.insert(sub_items, {
        text = _("反转方向"),
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            self:setCommonSetting("invert_layout", self.config.invert_layout)
        end
    })

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
    if _current_active_controller == self then
        _current_active_controller = nil
    end
    return true
end

return BluetoothController
