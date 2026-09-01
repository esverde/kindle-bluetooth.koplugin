-- Bluetooth Controller Configuration File
-- 蓝牙手柄配置文件
-- 此文件位于插件同目录，用于存储多手柄配置信息

return {
    -- =====================================================
    -- 通用设置 (Common Settings)
    -- =====================================================
    common = {
        wakeup_delay = 3,                          -- 唤醒后延迟重连时间（秒）
        trigger_cooldown_ms = 500,                 -- 翻页触发冷却时间（毫秒）
        invert_layout = false,                     -- 是否反转翻页方向
        active_profile = "xbox_wireless_controller",  -- 当前活动配置
    },

    -- =====================================================
    -- 手柄配置文件 (Controller Profiles)
    -- =====================================================
    profiles = {
        -- Xbox Wireless Controller 配置
        ["xbox_wireless_controller"] = {
            name = "Xbox Wireless Controller",     -- 显示名称
            device_path = "/dev/input/event6",     -- 设备路径
            supports_dpad = true,                  -- 支持 D-Pad 模式切换
            use_analog_mode = true,                -- 当前使用模式 (true=模拟摇杆, false=D-Pad)

            -- 轴心配置 (范围: 0-65535, 中心值: 32768)
            axis_threshold = 16384,                -- 死区阈值
            analog_center = { [0] = 32768, [1] = 32768 },  -- 各轴中心值（可逐轴校准）

            -- 按键映射: 正数=下一页, 负数=上一页
            key_map = {
                [304] = -1, [307] = -1, -- 上一页按键
                [305] = 1, [308] = 1,   -- 下一页按键
            },

            -- D-Pad 模式映射 (codes: 16=X轴, 17=Y轴, values: -1/0/1)
            dpad_map = {
                [17] = { [-1] = 1, [1] = -1 },     -- Y轴: 上=上一页, 下=下一页
                [16] = { [-1] = -1, [1] = 1 }      -- X轴: 左=上一页, 右=下一页
            },

            -- 模拟摇杆映射 (codes: 0=X轴, 1=Y轴)
            analog_map = {
                [1] = { low_dir = 1, high_dir = -1 },   -- Y轴: 上=上一页, 下=下一页
                [0] = { low_dir = -1, high_dir = 1 }    -- X轴: 左=上一页, 右=下一页
            },
        },
    }
}
