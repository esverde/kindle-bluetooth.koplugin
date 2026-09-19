-- Bluetooth Page Turner for Kindle - a KOReader plugin
-- Copyright (C) 2026  esverde
-- Licensed under the GNU AGPL v3 or later; see LICENSE for the full text.

local DataStorage = require("datastorage")
local Device = require("device")
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
local RECONNECT_SETTLE_DELAY = 0.5

local _shared_last_trigger_time
local _shared_last_power_reset_time
local _shared_hook_registered = false
local _wifi_guard_installed = false
local _shared_triggered = false
local _deflected_axes = {}
local _current_active_controller
local _fbink_input
local _fbink_input_masks
local _fbink_input_checked = false

local function resetInputState()
    _deflected_axes = {}
    _shared_triggered = false
end

local function isNumberInRange(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

-- 必须判 nil：用 `or` 会把 false 覆盖值吃掉（docs §10）
local function override(settings, key, from_file)
    local saved = settings:readSetting(key)
    if saved == nil then saved = from_file end
    return saved == true
end

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,
}

function BluetoothController:init()
    if not Device:isKindle() then return end
    self.config = {}
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/bluetooth_controller.lua")
    -- 必须匹配完整路径，短模式会误伤别的进程（docs §12）
    self._daemon_binary = self.path .. "/khp/kindle-hid-passthrough"
    self._daemon_pattern = util.shell_escape({ self.path .. "/khp/dist/main.bin" })
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:registerInputHook()
    self:installWifiGuard()
    self:openDevice()
end

-- bluetooth.lua 返回配置数组，每份对应一个手柄。真正生效的那份由
-- resolveProfile 按「哪个手柄现在在线」决定（docs §16）
function BluetoothController:loadSettings()
    local loader = loadfile(self.path .. "/bluetooth.lua")
    if not loader then
        logger.warn("BT Plugin: bluetooth.lua missing or unparsable")
        return false
    end

    local ok, profiles = pcall(loader)
    if not ok or type(profiles) ~= "table" or type(profiles[1]) ~= "table" then
        logger.warn("BT Plugin: bluetooth.lua is not a profile list")
        return false
    end

    self.profiles = profiles
    self._active_profile = nil
    return true
end

-- 按配置顺序取第一个能匹配到在线设备的那份。两个手柄都开着时，数组里靠前的赢
function BluetoothController:resolveProfile()
    if not self.profiles then return nil end
    local devices = self:scanJoystickDevices()
    for _i, profile in ipairs(self.profiles) do
        if type(profile.match_name) == "string" then
            for _j, dev in ipairs(devices) do
                -- 手写的模式串可能非法（比如落单的 %），pcall 住免得崩掉整个插件
                local ok, hit = pcall(string.match, dev.name, profile.match_name)
                if not ok then
                    logger.warn("BT Plugin: bad match_name pattern: " .. profile.match_name)
                elseif hit then
                    return profile, dev.path
                end
            end
        end
    end
end

-- 唯一的校验点：全部必填，一项不过关整份拒绝，不加兜底（docs §10）
function BluetoothController:applyConfig(cfg)
    local checks = {
        { "match_name",          type(cfg.match_name) == "string" and cfg.match_name ~= "" },
        { "display_name",        type(cfg.display_name) == "string" and cfg.display_name ~= "" },
        { "trigger_cooldown_ms", isNumberInRange(cfg.trigger_cooldown_ms, 0, 60000) },
        { "axis_threshold",      isNumberInRange(cfg.axis_threshold, 0, 65535) },
        { "supports_dpad",       type(cfg.supports_dpad) == "boolean" },
        { "key_map",             type(cfg.key_map) == "table" },
        { "analog_map",          type(cfg.analog_map) == "table" },
        { "analog_center",       type(cfg.analog_center) == "table" },
    }
    for _, check in ipairs(checks) do
        if not check[2] then
            logger.warn("BT Plugin: Invalid or missing config field: " .. check[1])
            return false
        end
    end

    for code in pairs(cfg.analog_map) do
        if not isNumberInRange(cfg.analog_center[code], 0, 65535) then
            logger.warn("BT Plugin: Missing analog_center for axis " .. tostring(code))
            return false
        end
    end

    if cfg.supports_dpad and type(cfg.dpad_map) ~= "table" then
        logger.warn("BT Plugin: supports_dpad is set but dpad_map is missing")
        return false
    end

    self.config = {}
    for k, v in pairs(cfg) do
        self.config[k] = v
    end
    -- 覆盖值按 match_name 分桶：两个手柄的「反转方向」互不影响（docs §16）
    self.config.invert_layout =
        override(self.settings, cfg.match_name .. "/invert_layout", cfg.invert_layout)
    -- 没有十字键就锁死摇杆模式，忽略覆盖值：否则一份陈旧的 use_analog_mode = false
    -- 会配上一个不发 HAT 事件的手柄，变成完全不能翻页且菜单里改不回来（docs §11）
    self.config.use_analog_mode = not cfg.supports_dpad
        or override(self.settings, cfg.match_name .. "/use_analog_mode", cfg.use_analog_mode)
    resetInputState()
    logger.info("BT Plugin: Using profile " .. cfg.display_name)
    return true
end

function BluetoothController:registerInputHook()
    _current_active_controller = self

    if _shared_hook_registered then return end

    Device.input:registerEventAdjustHook(function(_input_instance, ev)
        if _current_active_controller then _current_active_controller:handleInputEvent(ev) end
    end)
    _shared_hook_registered = true
end

-- 守护进程攥着 CONSYS 芯片时开 WiFi 会让射频卡死到重启，抢在动作之前拦下来。
-- 这是全仓库唯一一处 monkey patch，它依赖的两个 KOReader 行为见 docs §14
function BluetoothController:installWifiGuard()
    if _wifi_guard_installed then return end
    local NetworkMgr = require("ui/network/manager")

    -- turnOnWifi 是菜单/手势与插件自动联网的汇聚点；restoreWifiAsync 绕开它，
    -- 走的是唤醒时的 auto_restore_wifi 那条静默路径（networklistener.lua:224）
    for _i, name in ipairs({ "turnOnWifi", "restoreWifiAsync" }) do
        local original = NetworkMgr[name]
        if type(original) ~= "function" then
            logger.warn("BT Plugin: NetworkMgr." .. name .. " missing, guard not installed")
        else
            _wifi_guard_installed = true
            NetworkMgr[name] = function(mgr, ...)
                if _current_active_controller
                    and _current_active_controller:isDaemonRunning() then
                    UIManager:show(InfoMessage:new{
                        text = _("请先关闭蓝牙守护进程，再开 WiFi"),
                        timeout = 4,
                    })
                    -- turnOnWifi 必须返回 false：这是 KOReader 的「连接失败」契约，
                    -- enableWifi 据此调 _abortWifiConnection 清掉 pending_connection，
                    -- 返回 nil 会让之后所有开 WiFi 都被 EBUSY 挡死（manager.lua:68、375）。
                    -- restoreWifiAsync 是 fire-and-forget，没有返回值契约，false 无害
                    return false
                end
                return original(mgr, ...)
            end
        end
    end
end

-- 切换 input_no_key_repeat 会清空整条 hook 链（docs §5）
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
    _fbink_input_masks = {
        match = bit.bor(C.INPUT_JOYSTICK, C.INPUT_DPAD),
        exclude = C.INPUT_TOUCHSCREEN,
        settings = bit.bor(C.NO_RECAP, C.SCAN_ONLY),
    }
    return _fbink_input, _fbink_input_masks
end

function BluetoothController:openDevice()
    -- 路径来自扫描而非配置：scanJoystickDevices 只列已被 FBInk 判定为手柄的节点，
    -- 所以不必再单独 isControllerDevice 一次（docs §16）
    local profile, path = self:resolveProfile()
    if not profile then
        logger.info("BT Plugin: No configured controller is present")
        self:closeDevice()
        return false
    end

    if profile ~= self._active_profile then
        if not self:applyConfig(profile) then return false end
        self._active_profile = profile
    end

    if self.opened_path and self.opened_path ~= path
        and not self:closeDevice(self.opened_path) then
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
        local _ok, err = pcall(Device.input.close, Device.input, path)
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
            table.insert(devices, { path = path, name = name })
            -- dbg 而非 info：resolveProfile 每次 evdev 插入都会扫一遍（docs §16）
            logger.dbg("BT Plugin: Found input device: " .. name .. " at " .. path)
        end
    end
    C.free(found)
    return devices
end

function BluetoothController:isDaemonRunning()
    return os.execute("pgrep -f " .. self._daemon_pattern .. " >/dev/null 2>&1") == 0
end

function BluetoothController:startDaemon()
    if lfs.attributes(self._daemon_binary, "mode") ~= "file" then
        logger.warn("BT Plugin: khp binary missing at " .. self._daemon_binary)
        return false
    end
    -- setsid 让它脱离 KOReader 的进程组，否则 KOReader 退出会把它一起带走
    os.execute(string.format("setsid %s --daemon >/dev/null 2>&1 </dev/null &",
        util.shell_escape({ self._daemon_binary })))
    logger.info("BT Plugin: khp daemon start requested")
    return true
end

function BluetoothController:stopDaemon()
    os.execute("pkill -f " .. self._daemon_pattern)
    logger.info("BT Plugin: khp daemon stop requested")
end

-- 电量只能从 khp 的 API 拿：evdev 不带这个信息，内核也没建 hid 电量节点（docs §13）。
-- 取值整段在 pcall 里跑：popen 失败、连不上、API 换结构一律当「没有电量」
function BluetoothController:readBatteryLevel()
    if not self.opened_path or not self:isDaemonRunning() then return nil end

    local ok, level = pcall(function()
        local pipe = io.popen("wget -qO- -T 2 http://127.0.0.1:8321/status 2>/dev/null")
        local body = pipe:read("*all")
        pipe:close()
        for _i, conn in ipairs(require("rapidjson").decode(body).connections) do
            for _j, path in ipairs(conn.input_paths) do
                if path == self.opened_path then
                    -- JSON null 被解成 rapidjson.null（userdata），不是 nil
                    return type(conn.battery_level) == "number" and conn.battery_level
                end
            end
        end
    end)
    if ok then return level end
    logger.dbg("BT Plugin: battery read failed: " .. tostring(level))
end

-- 只在真正从「没开」变成「开了」时才提示：insert 事件对任何输入设备都会来，
-- 不加这个判断会在触屏等无关节点插入时弹出误导性的提示
function BluetoothController:_reconnect()
    if _current_active_controller ~= self then return end
    local was_open = self.opened_path ~= nil
    if self:openDevice() and not was_open then
        UIManager:show(InfoMessage:new{ text = _("手柄已连接"), timeout = 2 })
    end
end

-- 不比对路径：节点号由解析决定，插进来的这个可能正是要用的那个
function BluetoothController:onEvdevInputInsert(path)
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

function BluetoothController:handleInputEvent(ev)
    if not self.opened_fd or ev.fd ~= self.opened_fd then return end

    local direction = self:parseInputDirection(ev)
    if not direction then return end

    -- 翻页即活动：节流着喂看门狗，免得读到一半自动休眠
    if not _shared_last_power_reset_time
        or time.since(_shared_last_power_reset_time) >= time.s(POWER_RESET_INTERVAL) then
        _shared_last_power_reset_time = time.now()
        Device:getPowerDevice():resetT1Timeout()
    end

    UIManager:sendEvent(Event:new("GotoViewRel",
        self.config.invert_layout and -direction or direction))
    ev.type = -1
end

function BluetoothController:parseInputDirection(ev)
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        -- KOReader 的重复键过滤 hook 排在我们之后，必须自己认（docs §5）
        if ev.value == 2 and G_reader_settings:isTrue("input_no_key_repeat") then return nil end
        return self.config.key_map[ev.code]
    end

    if ev.type == C.EV_ABS then
        if self.config.use_analog_mode then return self:parseAnalogInput(ev) end
        return self:parseDpadInput(ev)
    end

    return nil
end

-- 十字键走 EV_ABS 的 HAT 轴（16/17），value 为 ±1，回中是 0
function BluetoothController:parseDpadInput(ev)
    if ev.value == 0 then return nil end
    local axis_map = self.config.dpad_map[ev.code]
    return axis_map and axis_map[ev.value]
end

function BluetoothController:parseAnalogInput(ev)
    local analog_map = self.config.analog_map
    local mapping = analog_map[ev.code]
    if not mapping then return nil end

    local center = self.config.analog_center[ev.code]
    local threshold = self.config.axis_threshold
    local deviation = math.abs(ev.value - center)

    -- 表当集合用：集合空（全轴回中）才解锁，否则一次推杆会连翻（docs §4）
    if deviation <= threshold then
        _deflected_axes[ev.code] = nil
        if next(_deflected_axes) == nil then _shared_triggered = false end
        return nil
    end
    _deflected_axes[ev.code] = true

    if _shared_triggered then return nil end

    if _shared_last_trigger_time
        and time.since(_shared_last_trigger_time) < time.ms(self.config.trigger_cooldown_ms) then
        return nil
    end

    _shared_triggered = true
    _shared_last_trigger_time = time.now()

    return ev.value < center and mapping.low_dir or mapping.high_dir
end

function BluetoothController:addToMainMenu(menu_items)
    local sub_items = {}

    table.insert(sub_items, {
        text = _("蓝牙守护进程"),
        keep_menu_open = true,
        checked_func = function() return self:isDaemonRunning() end,
        callback = function()
            local starting = not self:isDaemonRunning()
            if starting and not self:startDaemon() then
                UIManager:show(InfoMessage:new{
                    text = _("找不到守护进程，请检查插件目录下的 khp/"), timeout = 3 })
                return
            end
            if not starting then self:stopDaemon() end
            -- 不做延时回查：起来了由 onEvdevInputInsert → _reconnect 报「手柄已重新
            -- 连接」，停掉了节点当场消失，两个方向都已有反馈（docs §12）
            UIManager:show(InfoMessage:new{
                text = starting and _("正在启动守护进程…") or _("正在停止守护进程…"),
                timeout = 2,
            })
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
                local is_active = dev.path == self.opened_path
                local name = is_active and self.config.display_name or dev.name
                local level = is_active and self:readBatteryLevel()
                local pct = level and string.format(" %d%%", level) or ""
                table.insert(items, {
                    text = name .. pct .. (is_active and _(" [当前]") or _(" [可用]")),
                })
            end
            return items
        end,
    })

    -- 覆盖值按 match_name 分桶；没有生效的配置时这两项无处可写，故灰显
    local function saveOverride(key, value)
        self.settings:saveSetting(self.config.match_name .. "/" .. key, value)
        self.settings:flush()
    end
    local function hasProfile() return self.config.match_name ~= nil end

    table.insert(sub_items, {
        text = _("反转方向"),
        enabled_func = hasProfile,
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            saveOverride("invert_layout", self.config.invert_layout)
        end
    })

    -- 没有十字键的手柄这一项灰显。灰显是安全的：applyConfig 已强制锁死摇杆模式，
    -- 不会出现「改不回来又收不到 HAT 事件」那个死局（docs §11）
    local function modeItem(text, analog)
        return {
            text = text,
            checked_func = function() return self.config.use_analog_mode == analog end,
            callback = function()
                self.config.use_analog_mode = analog
                resetInputState()
                saveOverride("use_analog_mode", analog)
            end,
        }
    end

    table.insert(sub_items, {
        text = _("摇杆模式"),
        enabled_func = function() return hasProfile() and self.config.supports_dpad end,
        sub_item_table = {
            modeItem(_("模拟摇杆"), true),
            modeItem(_("方向键"), false),
        },
    })

    table.insert(sub_items, {
        text = _("重新加载设备"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = not self:loadSettings() and _("配置加载失败")
                    or self:openDevice() and _("设备已加载")
                    or _("加载失败"),
                timeout = 2,
            })
        end
    })

    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "network",
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
