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
local STATE_CACHE_INTERVAL = 2
local DEFAULT_PROFILE = "xbox_wireless_controller"
-- 节点刚建好时驱动可能还没就绪，等一下再打开（externalkeyboard.koplugin 同值）
local RECONNECT_SETTLE_DELAY = 0.5

local DUMP_TARGETS = {
    { directory = "/mnt/us", patterns = {
        "^audiomgrd_.*%.core$", "^btmanagerd_.*%.core$", "^Indexer_Dump_.*%.txt$",
    } },
    { directory = "/mnt/us/documents", patterns = {
        "^audiomgrd_.*_crash_", "^btmanagerd_.*_crash_",
        "audiomgrd.*%.sdr$", "btmanagerd.*%.sdr$",
    } },
}

local _shared_last_trigger_time = nil
local _shared_last_power_reset_time = nil
local _shared_hook_registered = false
local _shared_triggered = false
local _shared_axis_values = {}
local _current_active_controller = nil
local _fbink_input
local _fbink_input_masks
local _fbink_input_checked = false

local function resetInputState()
    _shared_axis_values = {}
    _shared_triggered = false
end

-- NaN 与 ±inf 都过不了这两个比较，不需要单独判
local function isNumberInRange(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

local function dirEntries(directory)
    local ok, iterator = pcall(lfs.dir, directory)
    if ok and type(iterator) == "function" then return iterator end
    return function() return nil end
end

local function isDevicePath(path)
    return type(path) == "string" and path:match("^/dev/input/event%d+$") ~= nil
end

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,

    config = {},
    full_config = {},
    settings_file = nil,
    _config_loaded = false,

    opened_path = nil,
    opened_fd = nil,   -- 开设备时记下，输入热路径上省一次表查

    -- 默认值的唯一归宿
    trigger_cooldown_ms = 500,

    _state_cached = false,
    _state_time = nil,
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

    local active_profile = common.active_profile or DEFAULT_PROFILE
    if type(active_profile) ~= "string" or active_profile == "" then
        logger.warn("BT Plugin: Invalid active profile")
        return false
    end

    local profile = profiles[active_profile]
    if type(profile) ~= "table" or not isDevicePath(profile.device_path) then
        logger.warn("BT Plugin: Invalid profile '" .. tostring(active_profile) .. "'")
        return false
    end

    self.trigger_cooldown_ms = isNumberInRange(common.trigger_cooldown_ms, 0, 60000)
        and common.trigger_cooldown_ms or self.trigger_cooldown_ms
    self.active_profile = active_profile

    -- 这里是配置的唯一校验点，输入热路径上不再逐字段重查
    self.config = {}
    for k, v in pairs(profile) do
        self.config[k] = v
    end
    self.config.invert_layout = common.invert_layout == true
    self.config.supports_dpad = profile.supports_dpad == true
    self.config.use_analog_mode = profile.use_analog_mode == true
    self.config.key_map = type(profile.key_map) == "table" and profile.key_map or {}
    self.config.dpad_map = type(profile.dpad_map) == "table" and profile.dpad_map or {}
    self.config.analog_map = type(profile.analog_map) == "table" and profile.analog_map or {}
    self.config.analog_center = type(profile.analog_center) == "table" and profile.analog_center or {}
    local threshold = profile.axis_threshold or profile.analog_threshold
    self.config.analog_threshold = isNumberInRange(threshold, 0, 65535)
        and threshold or AXIS_THRESHOLD_DEFAULT
    resetInputState()
    local profile_name = type(profile.name) == "string" and profile.name or active_profile
    logger.info("BT Plugin: Loaded profile '" .. profile_name .. "'")
    return true
end

-- 先写 .tmp 再 rename：同文件系统上 rename 原子，故 tmp 写成功后无需回滚。
-- 备份只在原文件 60 秒内未被改过时留（同 LuaSettings:backup），免得覆盖掉刚写的那份。
local function writeConfigAtomically(path, data)
    local temporary_path = path .. ".tmp"
    local ok, err = util.writeToFile("return " .. data, temporary_path, true, false, true)
    if not ok then
        os.remove(temporary_path)
        return false, err
    end

    local modification = lfs.attributes(path, "modification")
    if type(modification) == "number" and modification < os.time() - 60 then
        os.rename(path, path .. ".old")
    end
    return os.rename(temporary_path, path)
end

function BluetoothController:saveFullConfig()
    if not self._config_loaded then
        logger.warn("BT Plugin: Refusing to overwrite config file that was never loaded successfully")
        return false
    end

    local ok, err = writeConfigAtomically(self.settings_file, dump(self.full_config, nil, true))
    if ok then
        logger.info("BT Plugin: Configuration saved")
    else
        logger.warn("BT Plugin: Failed to write config file -> " .. tostring(err))
    end
    return ok
end

function BluetoothController:setCommonSetting(key, value)
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

-- 切换 input_no_key_repeat 会重建整条 eventAdjustHook 链，下一个 tick 里把自己挂回去。
-- 任务跑得晚也无害：它自己会检查还是不是当前实例。
function BluetoothController:onToggleKeyRepeat()
    UIManager:nextTick(function()
        if _current_active_controller == self
            and Device.input.eventAdjustHook == Input.eventAdjustHook then
            _shared_hook_registered = false
            self:registerInputHook()
        end
    end)
end

-- 掩码要等 cdefs 加载后才能取，故与库一并缓存
local function getFBInkInput()
    if _fbink_input_checked then return _fbink_input, _fbink_input_masks end
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
    -- 要求命中 JOYSTICK/DPAD 就足以排掉全部 Kindle 内建设备（Scribe 实测：电源键、
    -- 加速度计、手写笔、触屏各自是 KEY/ACCELEROMETER/TABLET/TOUCHSCREEN），
    -- 所以不需要设备名黑名单；触屏另行排除是因为它也报 ABS_X/ABS_Y。
    -- SCAN_ONLY 不能省：不带它 FBInk 会真打开设备，那个 fd 没人接管就是泄漏。
    _fbink_input_masks = {
        match = bit.bor(C.INPUT_JOYSTICK, C.INPUT_DPAD),
        exclude = C.INPUT_TOUCHSCREEN,
        settings = bit.bor(C.NO_RECAP, C.SCAN_ONLY),
    }
    return _fbink_input, _fbink_input_masks
end

function BluetoothController:isControllerDevice(path)
    local library, masks = getFBInkInput()
    if not library then return false end

    local ok, device = pcall(library.fbink_input_check,
        path, masks.match, masks.exclude, masks.settings)
    if not ok or device == nil then return false end

    local matched = device.matched == true
    C.free(device)
    return matched
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

    local was_open = self:isDeviceOpened(path)
    -- FBInk 能分类它就已证明节点存在，不必再 stat 一次
    local usable = self:isControllerDevice(path)

    -- 节点不可用时必须关：留着死 fd 会让 handleInputEvent 的闸门永远指向一个
    -- 不存在的设备，不重启无法恢复。代价是偶发的 open 失败会丢一个还在工作的
    -- fd，但那一侧能靠下次唤醒或「重新加载设备」恢复 —— 选可恢复的那一侧。
    if was_open and (is_reload or not usable) then
        if not self:closeDevice(path) then return false end
        was_open = false
    end

    if not usable then
        logger.info("BT Plugin: Device " .. path .. " unavailable or not a supported controller")
        return false
    end

    if not was_open then
        resetInputState()
        local ok, err = pcall(Device.input.open, Device.input, path)
        if not (ok and self:isDeviceOpened(path)) then
            self.opened_path = nil
            self.opened_fd = nil
            logger.warn("BT Plugin: Failed to open " .. path .. " -> " .. tostring(err or "device was not registered"))
            return false
        end
        logger.info("BT Plugin: Opened device " .. path)
    end

    self.opened_path = path
    self.opened_fd = Device.input.opened_devices[path]
    return true
end

-- 无参调用只关自己开过的节点：别去动别人的 fd
function BluetoothController:closeDevice(path)
    path = path or self.opened_path
    if not path then return true end

    if self:isDeviceOpened(path) then
        logger.info("BT Plugin: Closing device " .. path)
        local ok, err = pcall(Device.input.close, Device.input, path)
        if self:isDeviceOpened(path) then
            logger.warn("BT Plugin: Failed to close " .. path .. " -> " .. tostring(err or "still open"))
            return false
        end
        if not ok then
            logger.warn("BT Plugin: Close raised on " .. path .. " -> " .. tostring(err))
        end
    end

    if self.opened_path == path then
        self.opened_path = nil
        self.opened_fd = nil
    end
    return true
end

function BluetoothController:reloadDevice()
    return self:openDevice(true)
end

function BluetoothController:isDeviceOpened(path)
    return Device.input.opened_devices[path] ~= nil
end

-- fbink_input_scan 会返回*全部* /dev/input 节点（含名字），命中与否看 matched
function BluetoothController:scanJoystickDevices()
    local devices = {}
    local library, masks = getFBInkInput()
    if not library then return devices end

    local count = ffi.new("size_t[1]")
    local ok, found = pcall(library.fbink_input_scan,
        masks.match, masks.exclude, masks.settings, count)
    if not ok or found == nil then return devices end

    for i = 0, tonumber(count[0]) - 1 do
        local device = found[i]
        local name = ffi.string(device.name)
        if device.matched then
            local path = ffi.string(device.path)
            local is_opened = self:isDeviceOpened(path)
            table.insert(devices, { path = path, name = name, opened = is_opened })
            logger.info("BT Plugin: Found input device: " .. name .. " at " .. path .. " (opened=" .. tostring(is_opened) .. ")")
        end
    end
    C.free(found)

    table.sort(devices, function(left, right) return left.path < right.path end)
    return devices
end


-- 复用 KindlePowerD 的长驻句柄；自己 init+close 一个比它想省的 fork 更贵
local function btLipc()
    local powerd = Device:getPowerDevice()
    return powerd and powerd.lipc_handle
end

function BluetoothController:getRealState()
    local lipc = btLipc()
    if lipc then
        -- 取不到属性时返回 nil 而不抛错，所以必须判 state
        local ok, state = pcall(lipc.get_int_property, lipc, "com.lab126.btfd", "BTstate")
        if ok and type(state) == "number" then return state > 0 end
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

-- 写状态只走 shell：set_int_property 没有可靠的成功返回值，
-- os.execute 的退出码是唯一能据以判断成败的信号
function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1
    local cmd = string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val)
    if os.execute(cmd) ~= 0 then
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

function BluetoothController:_reconnect()
    if _current_active_controller ~= self then return end
    if self:reloadDevice() then
        UIManager:show(InfoMessage:new{ text = _("BT Controller Reconnected"), timeout = 2 })
    end
end

-- uevent 监听器（koreader-base input/input-kindle.h:95）对任何 input/eventN 的
-- add/remove 都发事件，不限 UHID —— 原生蓝牙栈实测有效，掉线/重连全靠这两个事件。
-- 没有唤醒定时重连：实测休眠时节点存活则 fd 仍可用，节点被销毁则重连时会发 insert，
-- 两种情况都不需要按时间盲试。
function BluetoothController:onEvdevInputInsert(path)
    if path ~= self.config.device_path then return end
    logger.info("BT Plugin: Input device inserted: " .. path)
    -- unschedule 先行，快速插拔时才不会堆叠出多个重连任务
    UIManager:unschedule(self._reconnect)
    UIManager:scheduleIn(RECONNECT_SETTLE_DELAY, self._reconnect, self)
end

-- 节点消失就立刻放掉 fd，不必等下次 openDevice 去发现它已经死了
function BluetoothController:onEvdevInputRemove(path)
    if path ~= self.opened_path then return end
    logger.info("BT Plugin: Input device removed: " .. path)
    UIManager:unschedule(self._reconnect)
    self:closeDevice(path)
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
    -- 只认手柄那一个 fd；触屏事件在这里就被挡住，不需要额外的 ABS_MT 预过滤
    if not self.opened_fd or ev.fd ~= self.opened_fd then
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
        -- KOReader 自己的重复键过滤 hook 排在我们之后（registerEventAdjustHook 是追加），
        -- 所以这里必须自己认这个设置
        if ev.value == 2 and G_reader_settings:isTrue("input_no_key_repeat") then
            return nil
        end
        return self.config.key_map[ev.code]
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
    local axis_map = self.config.dpad_map[ev.code]
    return axis_map and axis_map[ev.value]
end

function BluetoothController:parseAnalogInput(ev)
    local analog_map = self.config.analog_map
    local mapping = analog_map[ev.code]
    if not mapping then return nil end

    local center = self.config.analog_center[ev.code] or AXIS_CENTER_DEFAULT
    local threshold = self.config.analog_threshold
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
        for name in dirEntries(target.directory) do
            for _, pattern in ipairs(target.patterns) do
                if name:match(pattern) then
                    table.insert(paths, target.directory .. "/" .. name)
                    break
                end
            end
        end
    end

    if #paths > 0 then
        local command = "rm -rf -- " .. util.shell_escape(paths) .. " 2>/dev/null"
        if os.execute(command) ~= 0 then
            logger.warn("BT Plugin: Failed to remove bluetooth dumps")
            return false
        end
    end
    logger.info("BT Plugin: Cleaned up bluetooth dump files")
    return true
end


-- 索引为 [是否当前配置][是否已在 KOReader 打开]；存原文，_() 在使用处调用
local DEVICE_TAGS = {
    [true]  = { [true] = " [当前]",   [false] = " [已配置]" },
    [false] = { [true] = " [已连接]", [false] = " [可用]" },
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

            -- 节点号直接列出来：那是要填回 bluetooth.lua 的东西，别藏在弹窗里
            local items = {}
            for _i, dev in ipairs(devices) do
                local tag = DEVICE_TAGS[dev.path == self.config.device_path][dev.opened]
                table.insert(items, { text = dev.name .. _(tag) .. "  " .. dev.path })
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
                if type(profile) == "table" and isDevicePath(profile.device_path) then
                    local name = type(profile.name) == "string" and profile.name or profile_id
                    table.insert(profiles, {
                        text = name,
                        checked_func = function()
                            return self.active_profile == profile_id
                        end,
                        callback = function()
                            self.full_config.common = self.full_config.common or {}
                            local previous_profile = self.full_config.common.active_profile
                            self.full_config.common.active_profile = profile_id
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
                                text = self:reloadDevice() and _("已切换到 ") .. name
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
        text = _("重新加载设备"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = not self:loadSettings() and _("配置加载失败")
                    or self:reloadDevice() and _("设备已加载")
                    or _("加载失败"),
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
    UIManager:unschedule(self._reconnect)
    if _current_active_controller == self then
        self:closeDevice()
        _current_active_controller = nil
    end
    return true
end

return BluetoothController
