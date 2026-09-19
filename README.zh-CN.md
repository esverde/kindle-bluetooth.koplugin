# Kindle 蓝牙翻页器

[English](README.md) · **简体中文**

一个 [KOReader](https://github.com/koreader/koreader) 插件,用低功耗蓝牙(BLE)手柄
给 Kindle 翻页 —— 摇杆、十字键、面键都可以。

Kindle 原生固件**根本连不上 BLE 外设**,所以本插件搭配
[kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)
(下称 khp)使用。khp 是一套用户态蓝牙协议栈,把手柄变成一个标准的 Linux 输入设备;
插件直接消费这个设备,并在你翻页时阻止 Kindle 休眠。

---

## 目录

- [功能](#功能)
- [环境要求](#环境要求)
- [工作原理](#工作原理)
- [安装](#安装)
- [配置](#配置)
- [已知手柄配置](#已知手柄配置)
- [菜单说明](#菜单说明)
- [重要:WiFi 与蓝牙共用一颗芯片](#重要wifi-与蓝牙共用一颗芯片)
- [如何测出你手柄的键值](#如何测出你手柄的键值)
- [排错](#排错)
- [分支](#分支)
- [许可证](#许可证)
- [致谢](#致谢)

---

## 功能

- **摇杆、十字键、面键都能翻页。** 任意组合,每个输入对应什么方向由一个小配置文件决定。
- **摇杆 / 方向键两种模式。** 两者都有的手柄可以在菜单里切换。
- **不会误翻多页。** 摇杆推到底不放只翻一页,必须等所有映射到的轴回中之后才解锁。
- **看书时不休眠。** 每次翻页都会重置 Kindle 的空闲计时。
- **自动重连。** 手柄关掉再开,自己就接上了,不用进菜单。
- **手柄电量**显示在菜单里。
- **守护进程开关。** 在 KOReader 里直接起停 khp 后台服务。
- **WiFi 守卫。** 拦住那个唯一会把射频卡死的操作(见[下文](#重要wifi-与蓝牙共用一颗芯片))。

## 环境要求

| | |
| --- | --- |
| **设备** | 已越狱的 Kindle。已实测:**Kindle Scribe**、**Paperwhite 12 代**、**Kindle(2024)**。 |
| **阅读器** | KOReader,验证版本 **v2026.07.2**。 |
| **守护进程** | kindle-hid-passthrough,**v3.15.2 或更新**。 |
| **手柄** | 任何提供标准 HID 报告的 BLE 手柄。 |

> **为什么必须越狱:** khp 需要 root 权限打开 `/dev/stpbt`(裸蓝牙传输通道),
> 以及创建 `/dev/uhid` 设备。

## 工作原理

```
BLE 手柄
    │  低功耗蓝牙（HID over GATT）
    ▼
kindle-hid-passthrough  ── 用户态蓝牙协议栈，直接驱动 /dev/stpbt
    │  经 /dev/uhid 创建虚拟 HID 设备
    ▼
/dev/input/eventN       ── 一个普通的 Linux 输入设备
    │
    ▼
本插件                   ── 读事件，向 KOReader 发翻页指令
```

插件本身**完全不碰蓝牙**,只消费 khp 产出的那个输入设备。这既是它能保持小巧的原因,
也是为什么 khp 不跑就什么都不会发生。

## 安装

### 1. 安装 KOReader

按[官方说明](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)
安装到你的设备。

### 2. 安装本插件

把仓库复制到 KOReader 的插件目录,最终路径为:

```
/mnt/us/koreader/plugins/bluetooth.koplugin/
```

目录名**必须**以 `.koplugin` 结尾。

### 3. 安装守护进程

下载 kindle-hid-passthrough 的 ARM 版本,把内容放进**插件目录下的** `khp/` 子目录:

```
/mnt/us/koreader/plugins/bluetooth.koplugin/
├── main.lua
├── bluetooth.lua
└── khp/
    ├── kindle-hid-passthrough     ← 启动器
    ├── dist/                      ← 打包的运行时
    ├── config.ini
    └── devices.conf               ← 配对后自动生成
```

只需要启动器、`dist/` 和那两个配置文件。安装器的其他选项(按键映射器、网页界面、
开机自启任务)**都不需要**,而且建议跳过 —— 它们在某些固件上导致过开机循环。

然后把 khp 的 `config.ini` 指向新位置。把 `<khp>` 换成那个 `khp/` 目录的绝对路径:

```ini
[paths]
cache_dir = <khp>/cache
devices_config = <khp>/devices.conf

[connection]
reconnect_delay = 5
hci_reset_timeout = 10
connect_timeout = 30
transport_timeout = 30

[media_remote]
enabled = false

[logging]
log_file = <khp>/hid_passthrough.log
```

> `[media_remote] enabled = false` 很重要:开着它会让 Kindle 通过经典蓝牙对外
> 可被发现、可被连接,而本插件用不到这个功能。

### 4. 配对手柄

**配对前先打开 WiFi** —— 原因见 [WiFi 那一节](#重要wifi-与蓝牙共用一颗芯片)。
然后通过 SSH:

```sh
cd /mnt/us/koreader/plugins/bluetooth.koplugin/khp
./kindle-hid-passthrough --pair
```

把手柄置于配对模式,按提示操作。结果写入 `devices.conf`,重启后仍然有效。

> 要加第二个手柄,再跑一次 `--pair` 即可。`devices.conf` 会累积条目,khp 会同时
> 服务全部 —— 你开哪个手柄,哪个就连上。

### 5. 配置并启动

查出系统给手柄起的名字:

```sh
cat /proc/bus/input/devices
```

找到 `N: Name="..."` 那一行。把名字里有辨识度的一段填进 `bluetooth.lua` 的
`match_name`(见下),然后重启 KOReader,从菜单启动守护进程。

## 配置

所有设置都在插件目录下的 `bluetooth.lua` 里。插件**只读这个文件,从不改写它**。

文件返回一个**配置数组**,每份对应一个手柄。启动时以及手柄连上时,插件会扫描输入
设备,**按数组顺序**取第一个 `match_name` 能匹配上在线设备的配置。两个手柄都开着
时,排在前面的那份赢。

**没有 `device_path` 字段**:节点号来自扫描结果,所以 `eventN` 在重启后漂移不再
影响任何事情。

**每一个字段都是必填的。** 缺失或越界会导致那份配置被拒绝并在日志里说明原因,
没有任何静默兜底。

| 字段 | 含义 |
| --- | --- |
| `match_name` | Lua 模式,用来匹配手柄的系统设备名。**数组里第一个匹配上在线设备的配置生效**。 |
| `display_name` | 菜单里显示的名字。系统给出的原始名字带有硬件地址后缀,又长又难认。 |
| `trigger_cooldown_ms` | 两次翻页之间的最小间隔,单位毫秒。 |
| `invert_layout` | 交换上一页/下一页。*可在菜单里修改。* |
| `supports_dpad` | 只有手柄确实带十字键时才设 `true`。为 `true` 时 `dpad_map` 也必填。 |
| `use_analog_mode` | `true` = 摇杆,`false` = 方向键。*可在菜单里修改*;当 `supports_dpad` 为 `false` 时被强制为 `true` 并忽略存储值。 |
| `axis_threshold` | 摇杆推多远才算数。这是唯一值得按手感调的数。 |
| `analog_center` | 每个轴的静止值。`analog_map` 里出现的每个轴都必须有一项。 |
| `key_map` | 按键码 → 方向。`1` = 下一页,`-1` = 上一页。 |
| `analog_map` | 轴码 → 两端行程各对应什么方向。轴 `0` 是 X,轴 `1` 是 Y。 |
| `dpad_map` | 十字键轴码 → 方向。只在 `supports_dpad` 为 `true` 时读取。 |

> **标了「可在菜单里修改」的字段,一旦你在菜单里动过一次,行为就变了。** 此后以
> 存储的值为准,改 `bluetooth.lua` 对这些字段不再生效。其余字段永远以文件为准。
>
> 这是本项目历史上踩过的坑:「关掉反转方向,重启后又反转了」。

改完之后用菜单里的**重新加载设备**生效,不必重启。

## 已知手柄配置

不同手柄的轴量纲差别极大。**绝对不要在不同配置之间抄数值** —— 8 位摇杆和 16 位
摇杆差 256 倍,抄错的结果要么是「怎么推都没反应」,要么是「碰一下就翻好几页」。

下面这份随仓库发货的 [`bluetooth.lua`](bluetooth.lua) **就是**参考:它是一份可以
直接用的、带注释的配置数组,包含下表两份配置,也正是插件真正读取的那个文件。打开它,
留下与你手柄对应的那份,其余删掉,再按[如何测出你手柄的键值](#如何测出你手柄的键值)
添加自己的。

| 配置 | 轴 | 十字键 | 状态 |
| --- | --- | --- | --- |
| 只有摇杆和按键、没有十字键的手柄 | 8 位有符号,中心 `0`,行程 `±127` | 无 | 已在 BLE 下实测 |
| Xbox 无线手柄 | 16 位,中心 `32768` | 有 | **数值沿用自经典蓝牙,尚未在 BLE 下重新测过** —— 当起点用,务必自行验证 |

> **同一时刻只会使用一个手柄。** 两个都开着时 khp 层面会各连各的,但插件只读第一
> 个匹配上的那份配置对应的设备。另一个仍然占着蓝牙链路、耗着自己的电,所以不用的
> 那个建议关掉。

## 菜单说明

**设置 → 网络 → 蓝牙翻页器**

| 菜单项 | 作用 |
| --- | --- |
| **蓝牙守护进程** | 起停 khp。正在运行时显示勾选。 |
| **已连接设备** | 列出所有被识别为手柄的输入设备,标出当前配置的那个并显示其电量。 |
| **反转方向** | 交换上一页/下一页。重启后仍然有效。 |
| **摇杆模式** | 在摇杆和方向键之间选。手柄没有十字键时此项灰显。 |
| **重新加载设备** | 重读 `bluetooth.lua` 并重新打开输入设备。 |

启动守护进程后会先看到「正在启动守护进程…」,大约五秒后出现「手柄已连接」。
**如果第二条提示始终不出现,说明手柄没连上** —— 最常见的原因是 WiFi 没开。

## 重要:WiFi 与蓝牙共用一颗芯片

这几款 Kindle 上,WiFi 和蓝牙是同一颗组合芯片的两半,而 khp 把蓝牙那半完全接管了。
由此产生两个后果,日常使用都会遇到。

### WiFi 必须开着,手柄才连得上

芯片的固件是在 WiFi 那侧上电时载入的,khp 自己不会载。WiFi 关着时,khp 能启动、
状态显示为运行中,但**永远连不上任何设备**。

**先连好 WiFi,再启动守护进程。**

### 守护进程运行时去开 WiFi 会把射频卡死

khp 攥着芯片时把 WiFi 拉起来,会让射频进入一种**只有重启才能恢复**的状态 ——
在你重启 Kindle 之前,WiFi 既扫不到网络也连不上。

插件对此做了防护:守护进程运行时尝试开启 WiFi,会提示**「请先关闭蓝牙守护进程,
再开 WiFi」**并拒绝该操作。先从菜单关掉守护进程,再正常打开 WiFi 即可。

> **这道防护覆盖不了所有路径。** 它只看得见通过 KOReader 发起的 WiFi 变更。
> 从 Kindle 自带的设置界面开 WiFi 会完全绕过它 —— 反过来说,万一守护进程卡死
> 关不掉,那个界面就是你的逃生出口。
>
> 还有一个缺口:如果开启了「唤醒时恢复 WiFi 连接」,KOReader 会在启动时走一条
> 早于插件加载的路径恢复 WiFi。保持该设置关闭(默认就是关的)即可避开。

这是硬件特性加上 khp 接管方式共同决定的,不是本插件的缺陷。上游记录在
[khp issue #88](https://github.com/zampierilucas/kindle-hid-passthrough/issues/88)。

## 如何测出你手柄的键值

把下面的内容保存为 `/mnt/us/evkeys.lua`:

```lua
local ffi = require("ffi")
ffi.cdef[[
struct input_event { long tv_sec; long tv_usec; unsigned short type; unsigned short code; int value; };
int open(const char *path, int flags);
long read(int fd, void *buf, unsigned long n);
]]
local path = ... or "/dev/input/event2"
local fd = ffi.C.open(path, 0)
assert(fd >= 0, "打不开 " .. path)
io.stdout:setvbuf("line")
local ev, size = ffi.new("struct input_event"), 16
print("读取 " .. path .. "，Ctrl-C 退出")
while true do
    if ffi.C.read(fd, ev, size) == size and (ev.type == 1 or ev.type == 3) then
        print(string.format("%s code=%d value=%d",
            ev.type == 1 and "KEY" or "ABS", ev.code, ev.value))
    end
end
```

用 KOReader 自带的解释器运行:

```sh
cd /mnt/us/koreader && ./luajit /mnt/us/evkeys.lua /dev/input/event2
```

- **按键**按下时打印 `KEY code=N value=1`,把 `N` 填进 `key_map`。
- **摇杆**打印 `ABS code=0` 或 `code=1` 以及原始位置值。推到两端可知量纲范围,
  松手可读出中心值。
- **十字键**打印 `ABS code=16` 或 `code=17`,`value` 为 `-1`、`0`、`1`。

> **不要因为某个按键出现在能力位图里就去映射它。** HID 描述符经常声明出比硬件
> 实际拥有的更多按键。只映射你亲眼看见这个工具打印出来的码。

守护进程和这个脚本可以同时读设备,所以测量期间翻页仍然正常。

## 排错

| 现象 | 可能原因 |
| --- | --- |
| 守护进程起来了但手柄一直连不上 | WiFi 没开。连好 WiFi 后重启守护进程。 |
| WiFi 扫不到、连不上 | 射频被卡死了。重启 Kindle,之后务必先停守护进程再动 WiFi。 |
| 按键毫无反应 | 没有配置匹配上。拿 `match_name` 和 `/proc/bus/input/devices` 里的 `N: Name=` 对一下。 |
| 生效的是另一个手柄的设置 | 两个手柄都开着,而另一份配置排在前面。关掉一个,或调整数组顺序。 |
| 摇杆一推翻好几页 | 对这个手柄来说 `axis_threshold` 太低。 |
| 摇杆完全不翻页 | `axis_threshold` 太高,或 `analog_center` 与实际量纲不符。 |
| 菜单里根本没有这一项 | 插件加载失败,查 `crash.log`。 |
| 日志里出现 `Invalid or missing config field: X` | `bluetooth.lua` 缺字段 `X`,或它的类型不对。 |

值得一看的日志:

```sh
grep 'BT Plugin' /mnt/us/koreader/crash.log | tail -40
tail -40 /mnt/us/koreader/plugins/bluetooth.koplugin/khp/hid_passthrough.log
```

## 分支

| 分支 | 内容 |
| --- | --- |
| `main` | 当前分支。经 kindle-hid-passthrough 支持 BLE 手柄,持续维护。 |
| `classic` | 早期实现,用 Kindle 自带蓝牙栈支持经典蓝牙手柄。已归档,不再更新。 |

`docs/NOTES.md` 是维护者笔记:实测得到的事实、被否掉的方案,以及那些不显然的
代码背后的理由。它是工作记录,不是使用说明。

## 许可证

[GNU AGPL v3 或更新版本](LICENSE),与 KOReader 本身一致。简单说:可以自由使用、
修改、再分发,但衍生作品必须同样开源并采用相同许可。

## 致谢

- [KOReader](https://github.com/koreader/koreader) —— 本插件依附的阅读器。
- [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)
  作者 zampierilucas —— 让 Kindle 用上 BLE 的那套用户态蓝牙协议栈。
- [FBInk](https://github.com/NiLuJe/FBInk) 作者 NiLuJe —— 它的输入分类器负责把
  手柄和触摸屏区分开。
