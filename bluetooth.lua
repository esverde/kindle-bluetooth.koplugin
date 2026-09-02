-- 手写配置，插件只读、永不改写。字段含义见 docs/README.md。
-- 下面标注 [可覆盖] 的三项只是初始默认值：菜单改过之后，实际生效的是
-- <settings>/bluetooth_controller.lua 里的覆盖值，改这里不再有效（docs §10）。

return {
    common = {
        trigger_cooldown_ms = 500,
        invert_layout = false,                        -- [可覆盖] 反转方向
        active_profile = "xbox_wireless_controller",  -- [可覆盖] 切换配置
    },

    profiles = {
        ["xbox_wireless_controller"] = {
            name = "Xbox Wireless Controller",
            device_path = "/dev/input/event6",
            supports_dpad = true,
            use_analog_mode = true,   -- [可覆盖] 摇杆模式

            axis_threshold = 16384,
            analog_center = { [0] = 32768, [1] = 32768 },

            key_map = {
                [304] = -1, [307] = -1,
                [305] = 1, [308] = 1,
            },

            dpad_map = {
                [17] = { [-1] = 1, [1] = -1 },
                [16] = { [-1] = -1, [1] = 1 }
            },

            analog_map = {
                [1] = { low_dir = 1, high_dir = -1 },
                [0] = { low_dir = -1, high_dir = 1 }
            },
        },
    }
}
