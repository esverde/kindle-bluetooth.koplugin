-- 手写配置，插件只读、永不改写。字段含义、校验规则、[可覆盖] 的语义见
-- docs 开头那张表与 §10。
-- 本分支目标：Kindle PW6 + 黑鲨双翼手柄L（BLE，经 khp 落到 evdev）。全部
-- 数值取自真机实测；轴量纲与主分支完全不同，别混用两份配置（docs §11）。
-- 无摇杆/方向键模式切换 —— 这个手柄没有十字键（docs §11）。

return {
    device_path = "/dev/input/event2",
    trigger_cooldown_ms = 500,

    invert_layout = false,    -- [可覆盖] 反转方向

    -- 8 位有符号，中心 0，极值 ±127；95 ≈ 3/4 行程，唯一值得按手感调的数
    axis_threshold = 95,
    analog_center = { [0] = 0, [1] = 0 },

    -- 只映射实按验证过的键；为什么不能照 B: KEY 位图映射见 docs §11
    -- 方向值直接进 GotoViewRel：1 = 下一页，-1 = 上一页
    key_map = {
        [304] = 1,  [305] = 1,  [310] = 1,    -- A / B / L1 下一页
        [307] = -1, [308] = -1, [312] = -1,   -- X / Y / L2 上一页
    },

    analog_map = {
        [1] = { low_dir = -1, high_dir = 1 }, -- ABS_Y
        [0] = { low_dir = -1, high_dir = 1 }  -- ABS_X
    },
}
