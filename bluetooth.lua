-- 手写配置，插件只读、永不改写。字段含义见 docs/README.md。
-- 所有字段都是必填且必须合法，插件不做兜底：缺失或越界会被拒绝加载并打日志。
-- 标注 [可覆盖] 的两项只是初始值：菜单改过之后以
-- <settings>/bluetooth_controller.lua 里的覆盖值为准（docs §10）。
--
-- 本分支目标：Kindle PW6 + 黑鲨双翼手柄L（BLE，经 kindle-hid-passthrough
-- 的 /dev/uhid 落地成 evdev 节点）。全部数值取自真机实测，见 docs §11。
-- 轴的量纲与主分支（Xbox / 0-65535 / 中心 32768）完全不同，别混用两份配置。

return {
    device_path = "/dev/input/event3",
    trigger_cooldown_ms = 500,

    invert_layout = false,    -- [可覆盖] 反转方向
    use_analog_mode = true,   -- [可覆盖] 摇杆模式
    supports_dpad = true,     -- ABS=307bf 含 bit 16/17（HAT0X/Y），docs §11

    -- 8 位有符号，中心 0，实测极值 ±127。95 ≈ 3/4 行程，是这份配置里
    -- 唯一值得按手感调的数：调低更灵敏，也更容易误翻。
    axis_threshold = 95,
    analog_center = { [0] = 0, [1] = 0 },

    -- 按键码取自 B: KEY 位图解码，设备共暴露十二个：
    -- 304 305 307 308 310 311 312 313 314 315 317 318
    -- 这里只映射四个面键加两个肩键，面键方向与主分支一致（肌肉记忆）
    key_map = {
        [304] = -1, [307] = -1, [310] = -1,   -- A / X / L1 上一页
        [305] = 1,  [308] = 1,  [311] = 1,    -- B / Y / R1 下一页
    },

    dpad_map = {
        [17] = { [-1] = 1, [1] = -1 },        -- HAT0Y 上=上一页，下=下一页
        [16] = { [-1] = -1, [1] = 1 }         -- HAT0X 左=上一页，右=下一页
    },

    analog_map = {
        [1] = { low_dir = 1, high_dir = -1 }, -- ABS_Y
        [0] = { low_dir = -1, high_dir = 1 }  -- ABS_X
    },
}
