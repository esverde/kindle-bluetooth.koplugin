-- 手写配置，插件只读、永不改写。字段含义见 docs/README.md。
-- 所有字段都是必填且必须合法，插件不做兜底：缺失或越界会被拒绝加载并打日志。
-- 标注 [可覆盖] 的两项只是初始值：菜单改过之后以
-- <settings>/bluetooth_controller.lua 里的覆盖值为准（docs §10）。

return {
    device_path = "/dev/input/event6",
    trigger_cooldown_ms = 500,

    invert_layout = false,    -- [可覆盖] 反转方向
    use_analog_mode = true,   -- [可覆盖] 摇杆模式
    supports_dpad = true,

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
}
