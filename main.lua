local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Event = require("ui/event")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local ffi = require("ffi")
local Input = require("device/input")
local bit = require("bit")
local C = ffi.C

local POWER_RESET_INTERVAL = 60
local STATE_CACHE_INTERVAL = 2
local RECONNECT_SETTLE_DELAY = 0.5  -- docs §9

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

local function isNumberInRange(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

local function isDevicePath(path)
    return type(path) == "string" and path:match("^/dev/input/event%d+$") ~= nil
end

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,

    config = {},
    settings = nil,     -- 菜单可改的两个覆盖值，见 docs §10

    opened_path = nil,
    opened_fd = nil,

    _state_cached = false,
    _state_time = nil,
}

function BluetoothController:init()
    if not Device:isKindle() then return end
    self.config = {}
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/bluetooth_controller.lua")
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerInputHook()
    self:openDevice(false)
end

-- bluetooth.lua 只读：插件从不改写它（docs §10）
function BluetoothController:loadSettings()
    local loader = loadfile(self.path .. "/bluetooth.lua")
    if not loader then
        logger.warn("BT Plugin: bluetooth.lua missing or unparsable")
        return false
    end

    local ok, file_config = pcall(loader)
    if not ok or type(file_config) ~= "table" then
        logger.warn("BT Plugin: Failed to evaluate config file")
        return false
    end

    return self:applyConfig(file_config)
end

-- 取值顺序：菜单写的覆盖值 > bluetooth.lua。不存在第三层兜底。
function BluetoothController:override(key, from_file)
    local value = self.settings:readSetting(key)
    if value == nil then return from_file end
    return value
end

-- 全部字段必填且必须合法，任何一项不过关就整份拒绝、运行态不动（docs §10）。
-- 这是唯一的校验点，通过之后输入热路径可以直接索引，不再逐字段重查。
function BluetoothController:applyConfig(cfg)
    local checks = {
        { "device_path",         isDevicePath(cfg.device_path) },
        { "trigger_cooldown_ms", isNumberInRange(cfg.trigger_cooldown_ms, 0, 60000) },
        { "axis_threshold",      isNumberInRange(cfg.axis_threshold, 0, 65535) },
        { "key_map",             type(cfg.key_map) == "table" },
        { "dpad_map",            type(cfg.dpad_map) == "table" },
        { "analog_map",          type(cfg.analog_map) == "table" },
        { "analog_center",       type(cfg.analog_center) == "table" },
    }
    for _, check in ipairs(checks) do
        if not check[2] then
            logger.warn("BT Plugin: Invalid or missing config field: " .. check[1])
            return false
        end
    end

    -- 每个映射到的轴都必须有中心值，否则 parseAnalogInput 会拿到 nil
    for code in pairs(cfg.analog_map) do
        if not isNumberInRange(cfg.analog_center[code], 0, 65535) then
            logger.warn("BT Plugin: Missing analog_center for axis " .. tostring(code))
            return false
        end
    end

    -- 整表拷贝，避免逐字段枚举（每加一个配置项都要同步一次），再覆盖三项
    self.config = {}
    for k, v in pairs(cfg) do
        self.config[k] = v
    end
    self.config.supports_dpad = cfg.supports_dpad == true
    self.config.invert_layout = self:override("invert_layout", cfg.invert_layout) == true
    -- 不能用 or：覆盖值为 false（方向键模式）时会被吃掉，退回文件里的 true
    self.config.use_analog_mode = self:override("use_analog_mode", cfg.use_analog_mode) == true
    resetInputState()
    logger.info("BT Plugin: Loaded config for " .. cfg.device_path)
    return true
end

-- LuaSettings:flush 自带原子写 + .old 备份 + fsync（luasettings.lua:270）
function BluetoothController:saveOverride(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    logger.info("BT Plugin: Saved override " .. key)
end

function BluetoothController:registerInputHook()
    _current_active_controller = self

    if _shared_hook_registered then return end

    Device.input:registerEventAdjustHook(function(_input_instance, ev)
        if _current_active_controller then _current_active_controller:handleInputEvent(ev) end
    end)
    _shared_hook_registered = true
end

-- 切换 input_no_key_repeat 会清空整条 hook 链，下一个 tick 把自己挂回去（docs §5）
function BluetoothController:onToggleKeyRepeat()
    UIManager:nextTick(function()
        if _current_active_controller == self
            and Device.input.eventAdjustHook == Input.eventAdjustHook then
            _shared_hook_registered = false
            self:registerInputHook()
        end
    end)
end

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
    -- 掩码与 SCAN_ONLY 的理由见 docs §1
    _fbink_input_masks = {
        match = bit.bor(C.INPUT_JOYSTICK, C.INPUT_DPAD),
        exclude = C.INPUT_TOUCHSCREEN,
        settings = bit.bor(C.NO_RECAP, C.SCAN_ONLY),
    }
    return _fbink_input, _fbink_input_masks
end

local function isControllerDevice(path)
    -- 先判存在：节点不在时 FBInk 会往 stderr 打一行错误（docs §1）
    if lfs.attributes(path, "mode") == nil then return false end

    local library, masks = getFBInkInput()
    if not library then return false end

    local device = library.fbink_input_check(path, masks.match, masks.exclude, masks.settings)
    if device == nil then return false end

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
    local usable = isControllerDevice(path)

    -- 关闭顺序的权衡见 docs §9
    if was_open and (is_reload or not usable)
        and not self:closeDevice(path) then
        return false
    end

    if not usable then
        logger.info("BT Plugin: Device " .. path .. " unavailable or not a supported controller")
        return false
    end

    if not self:isDeviceOpened(path) then
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

function BluetoothController:closeDevice(path)
    path = path or self.opened_path
    if not path then return true end

    if self:isDeviceOpened(path) then
        logger.info("BT Plugin: Closing device " .. path)
        local _, err = pcall(Device.input.close, Device.input, path)
        if self:isDeviceOpened(path) then
            logger.warn("BT Plugin: Failed to close " .. path .. " -> " .. tostring(err or "still open"))
            return false
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

-- scan 返回*全部*节点，命中与否看 matched（docs §1）
function BluetoothController:scanJoystickDevices()
    local devices = {}
    local library, masks = getFBInkInput()
    if not library then return devices end

    local count = ffi.new("size_t[1]")
    local found = library.fbink_input_scan(masks.match, masks.exclude, masks.settings, count)
    if found == nil then return devices end

    for i = 0, tonumber(count[0]) - 1 do
        local device = found[i]
        if device.matched then
            local name = ffi.string(device.name)
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

local function btLipc()
    local powerd = Device:getPowerDevice()
    return powerd and powerd.lipc_handle
end

function BluetoothController:getRealState()
    local lipc = btLipc()
    if lipc then
        local ok, state = pcall(lipc.get_int_property, lipc, "com.lab126.btfd", "BTstate")
        if ok and type(state) == "number" then return state > 0 end
    end

    -- 走到这里说明 lipc 快路径失效了（docs §6），值得留一行
    logger.info("BT Plugin: lipc BTstate unavailable, using shell")
    local ok, pipe = pcall(io.popen, "lipc-get-prop com.lab126.btfd BTstate")
    if not ok or not pipe then return false end
    local output = pipe:read("*all")
    pipe:close()
    return (tonumber(output) or 0) > 0
end

function BluetoothController:getDisplayState()
    if self._state_time and time.since(self._state_time) < time.s(STATE_CACHE_INTERVAL) then
        return self._state_cached
    end
    self._state_cached = self:getRealState()
    self._state_time = time.now()
    return self._state_cached
end

-- 只走 shell：set_int_property 没有可靠的成功返回值（docs §6）
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
    local msg = enable and _("蓝牙已开启") or _("蓝牙已关闭")
    UIManager:show(InfoMessage:new { text = msg, timeout = 2 })
    return true
end

function BluetoothController:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_kindle_bluetooth", {
        category = "none",
        event = "ToggleBluetooth",
        title = _("切换 Kindle 蓝牙"),
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
        UIManager:show(InfoMessage:new{ text = _("手柄已重新连接"), timeout = 2 })
    end
end

-- 掉线与重连全靠这两个事件，没有唤醒定时重连（docs §2、§3）
function BluetoothController:onEvdevInputInsert(path)
    if path ~= self.config.device_path then return end
    logger.info("BT Plugin: Input device inserted: " .. path)
    UIManager:unschedule(self._reconnect)
    UIManager:scheduleIn(RECONNECT_SETTLE_DELAY, self._reconnect, self)
end

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
        Device:getPowerDevice():resetT1Timeout()
    end
end

function BluetoothController:handleInputEvent(ev)
    -- 只认手柄那一个 fd（docs §9）
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
        -- KOReader 的重复键过滤 hook 排在我们之后，必须自己认（docs §5）
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
    local threshold = self.config.axis_threshold
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
        and time.since(_shared_last_trigger_time) < time.ms(self.config.trigger_cooldown_ms) then
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
        -- lfs.dir 必须整体传给 for：它返回 (迭代器, 目录对象)，少了后者迭代器会报错
        if lfs.attributes(target.directory, "mode") == "directory" then
            for name in lfs.dir(target.directory) do
                for _, pattern in ipairs(target.patterns) do
                    if name:match(pattern) then
                        table.insert(paths, target.directory .. "/" .. name)
                        break
                    end
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

-- [是否当前配置][是否已打开]；存原文，_() 在使用处调用
local DEVICE_TAGS = {
    [true]  = { [true] = " [当前]",   [false] = " [已配置]" },
    [false] = { [true] = " [已连接]", [false] = " [可用]" },
}

function BluetoothController:addToMainMenu(menu_items)
    local function joystickModeItem(text, analog)
        return {
            text = text,
            checked_func = function()
                return self.config.use_analog_mode == analog
            end,
            callback = function()
                self.config.use_analog_mode = analog
                resetInputState()
                self:saveOverride("use_analog_mode", analog)
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
                local tag = DEVICE_TAGS[dev.path == self.config.device_path][dev.opened]
                table.insert(items, { text = dev.name .. _(tag) })
            end
            return items
        end,
    })

    table.insert(sub_items, {
        text = _("反转方向"),
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            self:saveOverride("invert_layout", self.config.invert_layout)
        end
    })

    table.insert(sub_items, {
        text = _("摇杆模式"),
        enabled_func = function()
            return self.config.supports_dpad
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
