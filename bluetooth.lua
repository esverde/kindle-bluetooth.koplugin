-- 手写配置，插件只读。字段含义与校验规则见仓库 README。
--
-- 数组里每一份对应一个手柄。插件启动或手柄插入时扫描输入设备，按**本数组的顺序**
-- 取第一个 match_name 能匹配上在线设备的配置。两个手柄都开着时，靠前的那份赢。
--
-- 没有 device_path 这个字段：节点号由扫描结果给出，所以 eventN 漂移不影响使用。

return {
    {
        -- Lua 模式，匹配 evdev 设备名（khp 用手柄的蓝牙名字命名节点）
        match_name = "黑鲨",
        display_name = "黑鲨双翼手柄L",
        trigger_cooldown_ms = 500,

        invert_layout = false,    -- [可覆盖]：菜单改过之后，改这里不再生效
        supports_dpad = false,    -- 这个手柄没有十字键

        -- 8 位有符号，中心 0，极值 ±127
        axis_threshold = 95,
        analog_center = { [0] = 0, [1] = 0 },

        -- 1 = 下一页，-1 = 上一页
        key_map = {
            [304] = 1,  [305] = 1,  [310] = 1,    -- A / B / L1
            [307] = -1, [308] = -1, [312] = -1,   -- X / Y / L2
        },

        analog_map = {
            [1] = { low_dir = -1, high_dir = 1 }, -- ABS_Y
            [0] = { low_dir = -1, high_dir = 1 }, -- ABS_X
        },
    },

    {
        -- 数值取自经典蓝牙下的实测，**尚未在 BLE 下重新测过**，当起点用
        match_name = "Xbox",
        display_name = "Xbox 手柄",
        trigger_cooldown_ms = 500,

        invert_layout = false,    -- [可覆盖]
        use_analog_mode = true,   -- [可覆盖] 摇杆 / 方向键
        supports_dpad = true,

        -- 16 位无符号，中心 32768
        axis_threshold = 16384,
        analog_center = { [0] = 32768, [1] = 32768 },

        key_map = {
            [304] = -1, [307] = -1,   -- A / X
            [305] = 1,  [308] = 1,    -- B / Y
        },

        dpad_map = {
            [17] = { [-1] = 1,  [1] = -1 },   -- ABS_HAT0Y
            [16] = { [-1] = -1, [1] = 1 },    -- ABS_HAT0X
        },

        analog_map = {
            [1] = { low_dir = 1,  high_dir = -1 },
            [0] = { low_dir = -1, high_dir = 1 },
        },
    },
}
