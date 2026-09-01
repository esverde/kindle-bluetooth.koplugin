# Bluetooth Controller 维护说明

本文记录插件的配置格式、输入设备边界和生命周期约束。源码只保留会影响输入安全或事件语义的少量注释。

## 配置文件

配置文件为插件目录下的 `bluetooth.lua`。

### 通用设置

| 字段 | 说明 |
| --- | --- |
| `common.wakeup_delay` | Kindle 唤醒后重新连接设备前的等待秒数。 |
| `common.trigger_cooldown_ms` | 两次翻页触发之间的最小间隔，单位为毫秒。 |
| `common.invert_layout` | 是否反转上一页/下一页方向。 |
| `common.active_profile` | 当前使用的 profile ID。 |

### 手柄 profile

| 字段 | 说明 |
| --- | --- |
| `name` | 菜单中显示的手柄名称。 |
| `device_path` | 手柄对应的 Linux 输入节点，例如 `/dev/input/event6`。 |
| `supports_dpad` | 是否支持 D-Pad 模式。 |
| `use_analog_mode` | 是否使用模拟摇杆模式；关闭时使用 D-Pad 映射。 |
| `axis_threshold` | 模拟轴死区阈值；旧配置中的 `analog_threshold` 也兼容。 |
| `analog_center` | 模拟轴中心值，通常为每轴 `32768`。 |
| `key_map` | 按键码到翻页方向的映射；正数为下一页，负数为上一页。 |
| `dpad_map` | D-Pad 轴码和值到翻页方向的映射；轴码 16/17，值为 -1/0/1。 |
| `analog_map` | 模拟轴映射；轴码 0/1，分别表示 X/Y 轴。 |

修改 profile 或设备路径后，应通过菜单重新加载设备。插件会先关闭旧节点，再打开新节点。

## 输入设备边界

KOReader 的事件 hook 会看到多个输入来源。插件使用两层过滤：

1. 扫描菜单中的候选设备时排除 Kindle 内部设备：`pt_mt`、`goodix-ts`、`bd71828-pwrkey`、`max77696-onkey`、`gpio-keys`、`hall_sensor`、`accel`、`bma4xy_feature` 和 `stylus-custom`。
2. 真正处理事件时，只接受当前 profile 的 `device_path` 在 KOReader 中打开的 fd，并要求事件自身的 `ev.fd` 相同。

因此，触摸屏、手写笔、旋转传感器、系统按键以及 `fake_events` 都不会进入手柄映射、唤醒计时、翻页或事件消费流程。多点触控轴码从 47 开始，也会在 fd 检查前快速丢弃。

只有成功匹配手柄映射的事件才会被标记为已消费；其他设备事件原样交回 KOReader。

## 生命周期与性能

Kindle 版 KOReader 会打开系统输入设备，也会创建 `fake_events`。fake event generator 是 KOReader 用于系统电源、屏幕和输入设备热插拔事件的基础设施，不是手柄设备，不应关闭。

切换 profile、唤醒重连或重新加载设备时，日志出现关闭旧节点再打开新节点属于正常流程。日志中的 `idx` 是 KOReader 内部输入设备数组索引，不是 `/dev/input/eventN`。

插件复用 KOReader 原生事件循环，只做一次当前 fd 查表和整数比较，不创建额外线程或轮询器。这是当前插件侧最小的输入过滤开销。

## 状态与配置写入

- 节流和去抖状态在插件模块级共享，避免 KOReader 重载时重复触发。
- 时间计算使用单调时间，避免 Kindle 联网校时影响冷却窗口。
- 模拟摇杆同时使用“回到死区”和时间冷却两层去抖。
- 蓝牙状态查询带短缓存；设备唤醒后按计划重新连接。
- 只有成功读取过配置文件才允许回写；写入前按条件保留 `.old` 备份，并以稳定键序输出配置。

