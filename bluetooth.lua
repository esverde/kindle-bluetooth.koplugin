-- 手写配置，插件只读。字段含义与校验规则见 docs 开头那张表与 §10、§11。

return {
    device_path = "/dev/input/event2",
    display_name = "黑鲨双翼手柄L",
    trigger_cooldown_ms = 500,

    invert_layout = false,    -- [可覆盖]：菜单改过之后，改这里不再生效

    -- 8 位有符号，中心 0，极值 ±127
    axis_threshold = 95,
    analog_center = { [0] = 0, [1] = 0 },

    -- 1 = 下一页，-1 = 上一页
    key_map = {
        [304] = 1,  [305] = 1,  [310] = 1,    -- A / B / L1 下一页
        [307] = -1, [308] = -1, [312] = -1,   -- X / Y / L2 上一页
    },

    analog_map = {
        [1] = { low_dir = -1, high_dir = 1 }, -- ABS_Y
        [0] = { low_dir = -1, high_dir = 1 }  -- ABS_X
    },
}
