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
local RECONNECT_SETTLE_DELAY = 0.5  -- docs §9
local DAEMON_START_DELAY = 6        -- 秒，实测节点约 5s 后出现（docs §12）

local DUMP_TARGETS = {
    { directory = "/mnt/us", patterns = {
        "^audiomgrd_.*%.core$", "^btmanagerd_.*%.core$", "^Indexer_Dump_.*%.txt$",
    } },
    { directory = "/mnt/us/documents", patterns = {
        "^audiomgrd_.*_crash_", "^btmanagerd_.*_crash_",
        "audiomgrd.*%.sdr$", "btmanagerd.*%.sdr$",
    } },
}

local _shared_last_trigger_time
local _shared_last_power_reset_time
local _shared_hook_registered = false
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

local function isDevicePath(path)
    return type(path) == "string" and path:match("^/dev/input/event%d+$") ~= nil
end

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,
}

function BluetoothController:init()
    if not Device:isKindle() then return end
    self.config = {}
    -- self.settings 存菜单可改的覆盖值，见 docs §10
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/bluetooth_controller.lua")
    -- 匹配完整路径而非 'ld-linux-armhf.'，算一次即可（docs §12）
    self._daemon_binary = self.path .. "/khp/kindle-hid-passthrough"
    self._daemon_pattern = util.shell_escape({ self.path .. "/khp/dist/main.bin" })
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
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

-- 唯一的校验点：全部字段必填，一项不过关就整份拒绝（docs §10、§9）
function BluetoothController:applyConfig(cfg)
    local checks = {
        { "device_path",         isDevicePath(cfg.device_path) },
        { "display_name",        type(cfg.display_name) == "string" and cfg.display_name ~= "" },
        { "trigger_cooldown_ms", isNumberInRange(cfg.trigger_cooldown_ms, 0, 60000) },
        { "axis_threshold",      isNumberInRange(cfg.axis_threshold, 0, 65535) },
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

    -- 每个映射到的轴都必须有中心值，否则 parseAnalogInput 会拿到 nil
    for code in pairs(cfg.analog_map) do
        if not isNumberInRange(cfg.analog_center[code], 0, 65535) then
            logger.warn("BT Plugin: Missing analog_center for axis " .. tostring(code))
            return false
        end
    end

    -- 整表拷贝而非逐字段枚举（docs §9），再覆盖唯一那项
    self.config = {}
    for k, v in pairs(cfg) do
        self.config[k] = v
    end
    -- 覆盖值 > bluetooth.lua，无第三层兜底；判 nil 而非 `or` 的理由见 docs §10
    local saved = self.settings:readSetting("invert_layout")
    if saved == nil then saved = cfg.invert_layout end
    self.config.invert_layout = saved == true
    resetInputState()
    logger.info("BT Plugin: Loaded config for " .. cfg.device_path)
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

    local matched = device.matched
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

    local usable = isControllerDevice(path)

    -- 关闭顺序的权衡见 docs §9
    if self:isDeviceOpened(path) and (is_reload or not usable)
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
            local is_opened = self:isDeviceOpened(path)
            table.insert(devices, { path = path, name = name, opened = is_opened })
            logger.info("BT Plugin: Found input device: " .. name .. " at " .. path .. " (opened=" .. tostring(is_opened) .. ")")
        end
    end
    C.free(found)

    table.sort(devices, function(left, right) return left.path < right.path end)
    return devices
end

-- khp 守护进程：只需要「在 / 不在」两态，用信号起停就够了（docs §12）
function BluetoothController:isDaemonRunning()
    return os.execute("pgrep -f " .. self._daemon_pattern .. " >/dev/null 2>&1") == 0
end

function BluetoothController:startDaemon()
    -- khp/ 被 gitignore，二进制缺失是最可能的实际场景（docs §9）
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
    -- SIGTERM，与 khp 自带 daemon.sh 的 stop() 一致
    os.execute("pkill -f " .. self._daemon_pattern)
    logger.info("BT Plugin: khp daemon stop requested")
end

-- 起停不同步，故延时回查（docs §12）
function BluetoothController:_daemonCheck()
    UIManager:show(InfoMessage:new{
        text = self:isDaemonRunning() and _("守护进程已启动") or _("守护进程已停止"),
        timeout = 2,
    })
end

function BluetoothController:_reconnect()
    if _current_active_controller ~= self then return end
    if self:openDevice(true) then
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
    if not self.opened_fd or ev.fd ~= self.opened_fd then return end

    local direction = self:parseInputDirection(ev)
    if not direction then return end

    self:pokeActivity()

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

    -- 本手柄只有摇杆，没有十字键，所以 EV_ABS 只有一条路（docs §11）
    if ev.type == C.EV_ABS then return self:parseAnalogInput(ev) end

    return nil
end

function BluetoothController:parseAnalogInput(ev)
    local analog_map = self.config.analog_map
    local mapping = analog_map[ev.code]
    if not mapping then return nil end

    local center = self.config.analog_center[ev.code]
    local threshold = self.config.axis_threshold
    local deviation = math.abs(ev.value - center)

    -- 表当集合用：全部映射轴都回中（集合空）才解锁，否则一次推杆会连翻（docs §4）
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
        if os.execute("rm -rf -- " .. util.shell_escape(paths) .. " 2>/dev/null") ~= 0 then
            logger.warn("BT Plugin: Failed to remove bluetooth dumps")
            return false
        end
    end
    logger.info("BT Plugin: Cleaned up bluetooth dump files")
    return true
end

-- [是否当前配置][是否已打开]
local DEVICE_TAGS = {
    [true]  = { [true] = _(" [当前]"),   [false] = _(" [已配置]") },
    [false] = { [true] = _(" [已连接]"), [false] = _(" [可用]") },
}

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
                    text = _("找不到守护进程，见 docs §12"), timeout = 3 })
                return
            end
            if not starting then self:stopDaemon() end
            UIManager:show(InfoMessage:new{
                text = starting and _("正在启动守护进程…") or _("正在停止守护进程…"),
                timeout = 2,
            })

            -- 不主动重开设备，那条路由 onEvdevInputInsert 兜住（docs §12）
            UIManager:unschedule(self._daemonCheck)
            UIManager:scheduleIn(starting and DAEMON_START_DELAY or 1, self._daemonCheck, self)
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
                local is_configured = dev.path == self.config.device_path
                local tag = DEVICE_TAGS[is_configured][dev.opened]
                -- 只替本机配置那一台的名字；其余保留 evdev 原名，方便认节点
                local name = is_configured and self.config.display_name or dev.name
                table.insert(items, { text = name .. tag })
            end
            return items
        end,
    })

    table.insert(sub_items, {
        text = _("反转方向"),
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            self.settings:saveSetting("invert_layout", self.config.invert_layout)
            -- flush 自带原子写 + .old 备份 + fsync（luasettings.lua:270）
            self.settings:flush()
        end
    })

    table.insert(sub_items, {
        text = _("重新加载设备"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = not self:loadSettings() and _("配置加载失败")
                    or self:openDevice(true) and _("设备已加载")
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
    UIManager:unschedule(self._daemonCheck)
    if _current_active_controller == self then
        self:closeDevice()
        _current_active_controller = nil
    end
    return true
end

return BluetoothController
