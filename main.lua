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
local Input = require("device/input")
local bit = require("bit")
local C = ffi.C

local AXIS_CENTER_DEFAULT = 32768
local AXIS_THRESHOLD_DEFAULT = 16384
local POWER_RESET_INTERVAL = 60
local DEFAULT_WAKEUP_DELAY = 3
local DEFAULT_TRIGGER_COOLDOWN_MS = 500
local STATE_CACHE_INTERVAL = 2
local DEFAULT_PROFILE = "xbox_wireless_controller"
local ABS_MT_FIRST = 47

local SYSTEM_DEVICE_NAMES = {
    "pt_mt", "goodix-ts", "bd71828-pwrkey", "max77696-onkey",
    "gpio-keys", "hall_sensor", "accel", "bma4xy_feature", "stylus-custom",
}

local DUMP_TARGETS = {
    { directory = "/mnt/us", pattern = "^audiomgrd_.*%.core$" },
    { directory = "/mnt/us", pattern = "^btmanagerd_.*%.core$" },
    { directory = "/mnt/us", pattern = "^Indexer_Dump_.*%.txt$" },
    { directory = "/mnt/us/documents", pattern = "^audiomgrd_.*_crash_.*$" },
    { directory = "/mnt/us/documents", pattern = "^btmanagerd_.*_crash_.*$" },
    { directory = "/mnt/us/documents", pattern = "^.*btmanagerd.*%.sdr$" },
    { directory = "/mnt/us/documents", pattern = "^.*audiomgrd.*%.sdr$" },
}

local _shared_last_trigger_time = nil
local _shared_last_power_reset_time = nil
local _shared_hook_registered = false
local _shared_triggered = false
local _shared_axis_values = {}
local _current_active_controller = nil
local _fbink_input
local _fbink_input_checked = false

local function resetInputState()
    _shared_axis_values = {}
    _shared_triggered = false
end

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isNumberInRange(value, minimum, maximum)
    return isFiniteNumber(value)
        and value >= minimum
        and value <= maximum
end

local function isDevicePath(path)
    return type(path) == "string" and path:match("^/dev/input/event%d+$") ~= nil
end

local function nameMatches(lower_name, keywords)
    if type(lower_name) ~= "string" then return false end
    for _, keyword in ipairs(keywords) do
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

    opened_path = nil,
    opened_by_plugin = false,
    wakeup_delay = DEFAULT_WAKEUP_DELAY,
    trigger_cooldown_ms = DEFAULT_TRIGGER_COOLDOWN_MS,

    _state_cached = false,
    _state_time = nil,

    _wakeup_task = nil,
    _hook_restore_task = nil,
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
    self._config_loaded = false
    local loader = loadfile(self.settings_file)
    if not loader then
        logger.warn("BT Plugin: Config file missing or unparsable, using defaults")
        return false
    end

    local ok, full_config = pcall(loader)
    if not ok or type(full_config) ~= "table" then
        logger.warn("BT Plugin: Failed to evaluate config file")
        return false
    end

    local previous_config = self.full_config
    self.full_config = full_config
    if not self:applyConfig() then
        self.full_config = previous_config
        return false
    end
    self._config_loaded = true
    return true
end

function BluetoothController:applyConfig()
    local common = self.full_config.common
    if common ~= nil and type(common) ~= "table" then
        logger.warn("BT Plugin: Invalid common configuration")
        return false
    end
    common = common or {}

    local profiles = self.full_config.profiles
    if type(profiles) ~= "table" then
        logger.warn("BT Plugin: Missing profiles configuration")
        return false
    end

    local active_profile = common.active_profile
    if active_profile == nil then
        active_profile = DEFAULT_PROFILE
    elseif type(active_profile) ~= "string" or active_profile == "" then
        logger.warn("BT Plugin: Invalid active profile")
        return false
    end

    local profile = profiles[active_profile]
    if type(profile) ~= "table" or not isDevicePath(profile.device_path) then
        logger.warn("BT Plugin: Invalid profile '" .. tostring(active_profile) .. "'")
        return false
    end

    if self.opened_path and self.opened_path ~= profile.device_path
        and not self:closeDevice(self.opened_path) then
        return false
    end

    self.wakeup_delay = isNumberInRange(common.wakeup_delay, 1, 60)
        and common.wakeup_delay or DEFAULT_WAKEUP_DELAY
    self.trigger_cooldown_ms = isNumberInRange(common.trigger_cooldown_ms, 0, 60000)
        and common.trigger_cooldown_ms or DEFAULT_TRIGGER_COOLDOWN_MS
    self.active_profile = active_profile
    self.config = {
        invert_layout = common.invert_layout == true,
        device_path = profile.device_path,
        supports_dpad = profile.supports_dpad == true,
        use_analog_mode = profile.use_analog_mode == true,
    }

    for k, v in pairs(profile) do
        self.config[k] = v
    end
    self.config.invert_layout = common.invert_layout == true
    self.config.device_path = profile.device_path
    self.config.supports_dpad = profile.supports_dpad == true
    self.config.use_analog_mode = profile.use_analog_mode == true
    self.config.key_map = type(profile.key_map) == "table" and profile.key_map or {}
    self.config.dpad_map = type(profile.dpad_map) == "table" and profile.dpad_map or {}
    self.config.analog_map = type(profile.analog_map) == "table" and profile.analog_map or {}
    self.config.analog_center = type(profile.analog_center) == "table" and profile.analog_center or {}
    local analog_threshold = profile.axis_threshold
    if analog_threshold == nil then
        analog_threshold = profile.analog_threshold
    end
    self.config.analog_threshold = isNumberInRange(analog_threshold, 0, 65535)
        and analog_threshold or AXIS_THRESHOLD_DEFAULT
    resetInputState()
    local profile_name = type(profile.name) == "string" and profile.name or active_profile
    logger.info("BT Plugin: Loaded profile '" .. profile_name .. "'")
    return true
end

local function writeConfigAtomically(path, data, create_backup)
    local temporary_path = path .. ".tmp"
    local ok, err = util.writeToFile("return " .. data, temporary_path, true, false, true)
    if not ok then
        os.remove(temporary_path)
        return false, err
    end

    local backup_path = path .. ".old"
    if create_backup then
        local moved, move_err = os.rename(path, backup_path)
        if not moved then
            os.remove(temporary_path)
            return false, move_err
        end
    end

    local replaced, replace_err = os.rename(temporary_path, path)
    if replaced then return true end

    os.remove(temporary_path)
    if create_backup then
        local restored, restore_err = os.rename(backup_path, path)
        if not restored then
            return false, tostring(replace_err) .. " (restore failed: " .. tostring(restore_err) .. ")"
        end
    end
    return false, replace_err
end

function BluetoothController:saveFullConfig()
    if not self._config_loaded then
        logger.warn("BT Plugin: Refusing to overwrite config file that was never loaded successfully")
        return false
    end

    local modification = lfs.attributes(self.settings_file, "modification")
    local create_backup = type(modification) == "number"
        and modification < os.time() - 60
    local ok, err = writeConfigAtomically(
        self.settings_file,
        dump(self.full_config, nil, true),
        create_backup
    )
    if ok then
        logger.info("BT Plugin: Configuration saved")
    else
        logger.warn("BT Plugin: Failed to write config file -> " .. tostring(err))
    end
    return ok
end

function BluetoothController:setCommonSetting(key, value)
    self.full_config = self.full_config or {}
    self.full_config.common = self.full_config.common or {}
    self.full_config.common[key] = value
    return self:saveFullConfig()
end

function BluetoothController:setActiveProfileSetting(key, value)
    local profiles = self.full_config and self.full_config.profiles
    local profile = profiles and self.active_profile and profiles[self.active_profile]
    if type(profile) ~= "table" then
        logger.warn("BT Plugin: Cannot update missing active profile")
        return false
    end
    profile[key] = value
    return self:saveFullConfig()
end


function BluetoothController:registerInputHook()
    _current_active_controller = self

    if _shared_hook_registered then return end

    Device.input:registerEventAdjustHook(function(_input_instance, ev)
        if _current_active_controller then _current_active_controller:handleInputEvent(ev) end
    end)
    _shared_hook_registered = true
end

function BluetoothController:onToggleKeyRepeat()
    if self._hook_restore_task then
        UIManager:unschedule(self._hook_restore_task)
    end

    local task
    task = function()
        if self._hook_restore_task == task then self._hook_restore_task = nil end
        if _current_active_controller ~= self then return end
        if Device.input.eventAdjustHook == Input.eventAdjustHook then
            _shared_hook_registered = false
            self:registerInputHook()
        end
    end
    self._hook_restore_task = task
    UIManager:scheduleIn(0, task)
end

local function getFBInkInput()
    if _fbink_input_checked then return _fbink_input end
    _fbink_input_checked = true

    local cdefs_loaded = pcall(require, "ffi/fbink_input_h")
    if not cdefs_loaded then
        logger.warn("BT Plugin: FBInk input classifier is unavailable")
        return nil
    end

    local loaded, library = pcall(ffi.loadlib, "fbink_input", 1)
    if not loaded then
        logger.warn("BT Plugin: Failed to load FBInk input classifier")
        return nil
    end
    _fbink_input = library
    return _fbink_input
end

local function getInputDeviceName(path)
    local event_name = path:match("^/dev/input/(event%d+)$")
    if not event_name then return nil end

    local name_file = io.open("/sys/class/input/" .. event_name .. "/device/name", "r")
    if not name_file then return nil end
    local name = name_file:read("*line")
    name_file:close()
    return name and util.trim(name)
end

function BluetoothController:isControllerDevice(path, device_name)
    local name = device_name or getInputDeviceName(path)
    local lower_name = type(name) == "string" and name:lower() or nil
    if nameMatches(lower_name, SYSTEM_DEVICE_NAMES) then
        return false
    end

    local library = getFBInkInput()
    if not library then return false end

    local ok, device = pcall(function()
        return library.fbink_input_check(
            path,
            bit.bor(C.INPUT_JOYSTICK, C.INPUT_DPAD),
            bit.bor(
                C.INPUT_POINTINGSTICK,
                C.INPUT_MOUSE,
                C.INPUT_TOUCHPAD,
                C.INPUT_TOUCHSCREEN,
                C.INPUT_TABLET,
                C.INPUT_SCALED_TABLET,
                C.INPUT_ACCELEROMETER,
                C.INPUT_KEYBOARD,
                C.INPUT_POWER_BUTTON,
                C.INPUT_SLEEP_COVER,
                C.INPUT_PAGINATION_BUTTONS,
                C.INPUT_HOME_BUTTON,
                C.INPUT_LIGHT_BUTTON,
                C.INPUT_MENU_BUTTON,
                C.INPUT_ROTATION_EVENT,
                C.INPUT_VOLUME_BUTTONS,
                C.INPUT_KINDLE_FRAME_TAP
            ),
            C.NO_RECAP
        )
    end)
    if not ok or device == nil then return false end

    local matched = device[0].matched == true
    C.free(device)
    return matched
end


function BluetoothController:deviceExists(path)
    return path ~= nil and path ~= "" and lfs.attributes(path, "mode") ~= nil
end

function BluetoothController:openDevice(is_reload)
    local path = self.config.device_path
    if not isDevicePath(path) then
        logger.warn("BT Plugin: Invalid device path")
        return false
    end

    if self.opened_path and self.opened_path ~= path
        and not self:closeDevice(self.opened_path) then
        return false
    end

    if self.opened_path == path and not self:isDeviceOpened(path) then
        self.opened_path = nil
        self.opened_by_plugin = false
    end

    if self:isDeviceOpened(path) then
        if not self:deviceExists(path) or not self:isControllerDevice(path) then
            if self.opened_path == path then
                if self.opened_by_plugin then self:closeDevice(path) end
                self.opened_path = nil
                self.opened_by_plugin = false
            end
            return false
        end
        self.opened_path = path
        if not self.opened_by_plugin or not is_reload then return true end
        if not self:closeDevice(path) then return false end
    end

    if not self:deviceExists(path) then
        logger.info("BT Plugin: Device " .. path .. " not found")
        return false
    end

    if not self:isControllerDevice(path) then
        logger.warn("BT Plugin: Device " .. path .. " is not a supported controller")
        return false
    end

    resetInputState()

    local success, err = pcall(Device.input.open, Device.input, path)
    if success and self:isDeviceOpened(path) then
        self.opened_path = path
        self.opened_by_plugin = true
        logger.info("BT Plugin: Opened device " .. path)
    else
        if self:isDeviceOpened(path) then
            self.opened_path = path
            self.opened_by_plugin = true
            self:closeDevice(path)
        end
        self.opened_path = nil
        self.opened_by_plugin = false
        logger.warn("BT Plugin: Failed to open " .. path .. " -> " .. tostring(err or "device was not registered"))
    end
    return success and self.opened_path == path and self:isDeviceOpened(path)
end

function BluetoothController:closeDevice(path)
    path = path or self.opened_path or self.config.device_path
    if not path then return true end
    if path ~= self.opened_path then return true end

    if not self.opened_by_plugin then
        self.opened_path = nil
        self.opened_by_plugin = false
        return true
    end

    if self:isDeviceOpened(path) then
        logger.info("BT Plugin: Closing device " .. path)
        local ok, err = pcall(Device.input.close, Device.input, path)
        if not ok then
            if not self:isDeviceOpened(path) then
                self.opened_path = nil
                self.opened_by_plugin = false
            end
            logger.warn("BT Plugin: Failed to close " .. path .. " -> " .. tostring(err))
            return false
        end
    end

    if self:isDeviceOpened(path) then
        logger.warn("BT Plugin: Device " .. path .. " remained open")
        return false
    end
    if self.opened_path == path then
        self.opened_path = nil
        self.opened_by_plugin = false
    end
    return true
end

function BluetoothController:reloadDevice()
    return self:openDevice(true)
end

function BluetoothController:isDeviceOpened(path)
    local opened_devices = Device.input.opened_devices
    return path ~= nil and opened_devices ~= nil and opened_devices[path] ~= nil
end

function BluetoothController:scanJoystickDevices()
    local devices = {}

    local ok, iterator = pcall(lfs.dir, "/sys/class/input")
    if not ok or type(iterator) ~= "function" then return devices end

    for entry in iterator do
        local event_id = entry:match("^event(%d+)$")
        if event_id then
            local dev_path = "/dev/input/event" .. event_id
            local clean_name = getInputDeviceName(dev_path)
            if clean_name and clean_name ~= "" and self:isControllerDevice(dev_path, clean_name) then
                local is_opened = self:isDeviceOpened(dev_path)
                table.insert(devices, {
                    path = dev_path,
                    name = clean_name,
                    opened = is_opened,
                })
                logger.info("BT Plugin: Found input device: " .. clean_name .. " at " .. dev_path .. " (opened=" .. tostring(is_opened) .. ")")
            end
        end
    end

    table.sort(devices, function(left, right) return left.path < right.path end)
    return devices
end


function BluetoothController:getRealState()
    local native_ok, native_state = pcall(function()
        local has_lipc, lipc = pcall(require, "liblipclua")
        if not has_lipc then return nil end
        local handle = lipc.init("com.github.koreader.bluetooth_controller")
        if not handle then return nil end
        local ok, state = pcall(
            handle.get_int_property,
            handle,
            "com.lab126.btfd",
            "BTstate"
        )
        handle:close()
        if not ok then return nil end
        return state
    end)
    if native_ok and type(native_state) == "number" then
        return native_state > 0
    end

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
    local native_ok, native_result = pcall(function()
        local has_lipc, lipc = pcall(require, "liblipclua")
        if not has_lipc then return false end
        local handle = lipc.init("com.github.koreader.bluetooth_controller")
        if not handle then return false end
        local ok = pcall(
            handle.set_int_property,
            handle,
            "com.lab126.btfd",
            "BTflightMode",
            val
        )
        handle:close()
        return ok
    end)

    local success = native_ok and native_result
    if not success then
        local exit_code = os.execute(cmd)
        success = exit_code == 0
    end

    if not success then
        logger.warn("BT Plugin: Failed to change Bluetooth state")
        UIManager:show(InfoMessage:new { text = _("蓝牙切换失败"), timeout = 2 })
        return false
    end

    self._state_cached = enable
    self._state_time = time.now()
    local msg = enable and _("Bluetooth enabled") or _("Bluetooth disabled")
    UIManager:show(InfoMessage:new { text = msg, timeout = 2 })
    return true
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

function BluetoothController:handleInputEvent(ev)
    if ev.type == C.EV_ABS and ev.code >= ABS_MT_FIRST then
        return
    end

    local controller_path = self.opened_path
    local opened_devices = Device.input.opened_devices
    local controller_fd = controller_path and opened_devices and opened_devices[controller_path]
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
    ev.type = -1
end

function BluetoothController:parseInputDirection(ev)
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        if ev.value == 2 and G_reader_settings
            and G_reader_settings:isTrue("input_no_key_repeat") then
            return nil
        end
        local key_map = self.config.key_map
        local direction = type(key_map) == "table" and key_map[ev.code]
        return isFiniteNumber(direction) and direction or nil
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
    local dpad_map = self.config.dpad_map
    local axis_map = type(dpad_map) == "table" and dpad_map[ev.code]
    local direction = type(axis_map) == "table" and axis_map[ev.value]
    return isFiniteNumber(direction) and direction or nil
end

function BluetoothController:parseAnalogInput(ev)
    local analog_map = self.config.analog_map
    if type(analog_map) ~= "table" or type(ev.value) ~= "number" then return nil end
    local mapping = analog_map[ev.code]
    if type(mapping) ~= "table"
        or not isFiniteNumber(mapping.low_dir)
        or not isFiniteNumber(mapping.high_dir) then
        return nil
    end

    local centers = self.config.analog_center
    local center = type(centers) == "table" and centers[ev.code]
    if not isNumberInRange(center, 0, 65535) then
        center = AXIS_CENTER_DEFAULT
    end
    local threshold = self.config.analog_threshold
    if not isNumberInRange(threshold, 0, 65535) then
        threshold = AXIS_THRESHOLD_DEFAULT
    end
    local deviation = math.abs(ev.value - center)

    _shared_axis_values[ev.code] = deviation

    if deviation <= threshold then
        if _shared_triggered then
            local all_centered = true
            for axis_code, axis_deviation in pairs(_shared_axis_values) do
                if analog_map[axis_code] and axis_deviation > threshold then
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
    local paths = {}
    for _, target in ipairs(DUMP_TARGETS) do
        local ok, iterator = pcall(lfs.dir, target.directory)
        if ok and type(iterator) == "function" then
            for name in iterator do
                if name:match(target.pattern) then
                    table.insert(paths, target.directory .. "/" .. name)
                end
            end
        end
    end

    for _, path in ipairs(paths) do
        local command = "rm -rf -- " .. util.shell_escape({ path }) .. " 2>/dev/null"
        if os.execute(command) ~= 0 then
            logger.warn("BT Plugin: Failed to remove bluetooth dump")
            return false
        end
    end
    logger.info("BT Plugin: Cleaned up bluetooth dump files")
    return true
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
                local device_name, device_path, device_status_desc = dev.name, dev.path, status_desc

                table.insert(items, {
                    text = device_name .. status_tag,
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = string.format(
                                _("设备名称: %s\n设备节点: %s\n连接状态: %s"),
                                device_name, device_path, device_status_desc),
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
                if type(profile_id) == "string"
                    and type(profile) == "table"
                    and isDevicePath(profile.device_path) then
                    local selected_profile_id = profile_id
                    local selected_profile_name = type(profile.name) == "string"
                        and profile.name or profile_id
                    table.insert(profiles, {
                        text = selected_profile_name,
                        checked_func = function()
                            return self.active_profile == selected_profile_id
                        end,
                        callback = function()
                            if not self:closeDevice() then
                                UIManager:show(InfoMessage:new{
                                    text = _("旧设备关闭失败"),
                                    timeout = 2,
                                })
                                return
                            end
                            self.full_config.common = self.full_config.common or {}
                            local previous_profile = self.full_config.common.active_profile
                            self.full_config.common.active_profile = selected_profile_id
                            if not self:applyConfig() then
                                self.full_config.common.active_profile = previous_profile
                                UIManager:show(InfoMessage:new{
                                    text = _("配置切换失败"),
                                    timeout = 2,
                                })
                                return
                            end
                            self:saveFullConfig()
                            UIManager:show(InfoMessage:new{
                                text = self:reloadDevice()
                                    and _("已切换到 ") .. selected_profile_name
                                    or _("配置已切换，但未找到设备"),
                                timeout = 2,
                            })
                        end,
                    })
                end
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
            local loaded = self:loadSettings()
            local message
            if not loaded then
                message = _("配置加载失败")
            elseif self:reloadDevice() then
                message = _("设备已加载")
            else
                message = _("加载失败")
            end
            UIManager:show(InfoMessage:new{
                text = message,
                timeout = 2,
            })
        end
    })

    table.insert(sub_items, {
        text = _("清理蓝牙垃圾"),
        callback = function()
            local cleaned = self:cleanupBluetoothDumps()
            UIManager:show(InfoMessage:new{
                text = cleaned and _("已清理蓝牙转储垃圾文件") or _("清理蓝牙转储失败"),
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
    if self._hook_restore_task then
        UIManager:unschedule(self._hook_restore_task)
        self._hook_restore_task = nil
    end
    if _current_active_controller == self then
        self:closeDevice()
        _current_active_controller = nil
    end
    return true
end

return BluetoothController
