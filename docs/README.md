# Bluetooth Controller 维护说明

本文记录插件的配置格式、输入设备边界、生命周期约束，以及所有依赖 KOReader
内部行为的**已核验事实**及其出处。

改动这个插件之前先读「已核验事实」一节 —— 里面每一条都是踩坑或翻源码换来的，
其中若干条曾经被"看起来更合理"的直觉推翻过，然后又被证据推翻回来。

验证环境：**Kindle Scribe**，KOReader **v2026.07.2**，原生蓝牙栈
（`ace_bt_cli` / `lipc` `com.lab126.btfd`，HID 经 `/dev/uhid` 落到 evdev）。

## 配置文件

配置文件为插件目录下的 `bluetooth.lua`。

### 通用设置

| 字段 | 说明 |
| --- | --- |
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

修改 profile 或设备路径后，应通过菜单重新加载设备。插件会先释放旧节点，再打开新节点。

配置加载会校验 profile 结构、输入节点格式和数值范围。非法配置不会替换当前运行配置；
冷却时间和轴阈值越界时使用默认值。插件不会自动修改 `device_path`，设备节点需要手动维护。

**查真实节点号**：菜单「已连接设备」只显示名称与状态标签，节点号看 `crash.log`：

```sh
grep "Found input device" /mnt/us/koreader/crash.log
# BT Plugin: Found input device: Xbox Wireless Controller at /dev/input/event6 (opened=true)
```

⚠️ **回写会抹掉注释**。任何一次改设置（反转方向、摇杆模式、切换配置）
都会用 `dump` 重写整个文件，手写的注释不会保留。想留注释请另存一份。

## 输入设备边界

KOReader 的事件 hook 会看到**所有**输入来源。插件靠两层过滤：

1. **设备识别**：FBInk 输入分类，只接受 `INPUT_JOYSTICK` 或 `INPUT_DPAD`，
   显式排除 `INPUT_TOUCHSCREEN`。
2. **事件归属**：只处理 `ev.fd` 等于插件自己打开的那个 fd 的事件。

没有第三层设备名黑名单 —— 见「已核验事实 §1」，FBInk 的能力分类已经足够。

只有成功匹配手柄映射的事件才会被 `ev.type = -1` 标记为已消费；其他设备的事件原样交回
KOReader。这是 in-app 版的 evdev 独占（grab）：不消费的话，"上一页"键会同时被 KOReader
自己处理，顶出底部菜单。

## 生命周期

- 插件**每个 ReaderUI 实例化一次**（打开文档时日志会再打一遍 `Loaded profile`）。
  模块级的 `_current_active_controller` 指向当前实例，hook 只注册一次并委派给它。
- 切换 profile、事件驱动重连、重新加载设备时，日志出现"关闭旧节点再打开新节点"是正常流程。
- 日志里的 `idx` 是 KOReader 内部输入设备数组下标，不是 `/dev/input/eventN`。
- `[ko-input] Forked off fake event generator` 是 KOReader 的电源/屏幕/热插拔事件基础设施，
  不是手柄设备，不要动它。
- `onExit` 会取消待执行的重连、关闭自己开的节点、释放模块级实例引用
  （不释放会让整棵 ReaderUI 活到进程退出）。

## 状态与配置写入

- 节流和去抖状态在模块级共享，避免 KOReader 重载时重复触发。
- 时间计算全部使用单调时钟（`time.now()`）。用 `os.time()` 会在 Kindle 联网校时
  往回跳时把节流窗口永久冻住（差值变负数，恒小于阈值）。
- 模拟摇杆同时使用"回到死区"和时间冷却两层去抖。
- 蓝牙状态查询带 2 秒缓存，避免菜单每次重绘都 fork 一个进程。
- 手柄掉线与重连**完全由 uevent 事件驱动**，没有任何定时轮询或唤醒重连（见 §3）。
- 只有成功读取过配置文件才允许回写（`_config_loaded` 闸门）。否则配置文件缺失或损坏时，
  第一次菜单操作就会把整份 profiles 覆盖成 `{common={...}}`。
- 配置先写 `.tmp` 并 fsync，再 `rename` 原子替换；原文件 60 秒内未被改过时留 `.old` 备份。

---

# 已核验事实

每条都注明出处。`koreader/` 与 `koreader-base/` 是本地克隆（已 gitignore）。

## §1 FBInk 输入分类

**Scribe 上 7 个输入节点的实际分类**（设备日志，KOReader 启动时 FBInk 自己打印）：

```
event0: `bd71828-pwrkey`            = KEY | POWER_BUTTON
event1: `bma4xy_acc`                = ACCELEROMETER
event2: `bma4xy_feature`            = ROTATION_EVENT
event3: `WacomDigitizer`            = TABLET | ROTATION_EVENT
event4: `pt_mt`                     = TOUCHSCREEN
event5: `stylus-custom`             = TABLET | ROTATION_EVENT | SCALED_TABLET
event6: `Xbox Wireless Controller`  = JOYSTICK | KEY      ← 唯一命中
```

**结论：不需要设备名黑名单。** 内建设备一个都不带 `JOYSTICK`/`DPAD`，
`match = JOYSTICK|DPAD` 这一关就全挡住了。历史上那份
`SYSTEM_DEVICE_NAMES`（`pt_mt`、`bma4xy_feature`、`stylus-custom` …）
是给更早的**关键词子串匹配**扫描用的（当年靠 `find("wireless")`、`find("keyboard")`
这类模糊匹配，才会把内建设备捞进来），换成 FBInk 后从未生效过。

`INPUT_TOUCHSCREEN` 仍需显式排除：触屏也报 `ABS_X`/`ABS_Y`，轴码与摇杆冲突。

### 节点不存在时会往 stderr 打错误

`fbink_input_check` 打不开路径时会输出

```
[FBInk] [fbink_input_check] open `/dev/input/event6`: No such file or directory!
```

`NO_RECAP` 挡不住这一行（那只挡分类结果的 recap）。手柄没连时每次 `openDevice`
（含每次打开文档）都会写一行。所以 `openDevice` 在调用分类器前先用
`lfs.attributes` 判一次存在 —— 对功能是冗余的（FBInk 会返回 NULL），
但能免掉这行噪音和一次注定失败的库调用。

### SCAN_ONLY 不能省

`FBInk/fbink.h` 原文：

```c
SCAN_ONLY = 1U << 0U,   // Do *NOT* leave any fd's open'ed
// if the SCAN_ONLY bit is set, *no* fds will be returned, regardless of the filter.
```

分类照常进行，只是不返回 fd。**不带这个标志，`fbink_input_check` 会真的打开设备**，
返回结构体里的 `fd` 没人接管就是泄漏 —— 早先的代码只传 `NO_RECAP`，
于是每次设备识别、每次进「已连接设备」菜单都漏一个 fd。

### fbink_input_scan 返回全部节点

`fbink.h` 原文："Regardless of the filter you request, this will always contain
*all* the device's input devices. The `matched` field will be set to true if…"

所以**必须按 `matched` 字段过滤**，不能假设返回的都是命中项。两个函数都要求
`You *MUST* free the returned pointer after use (it's heap allocated)`。

## §2 输入设备热插拔（uevent）

整条链路逐环节核验：

| 环节 | 出处 | 事实 |
| --- | --- | --- |
| 监听器启动 | `koreader-base/input/input-kindle.h:134` | `generateFakeEvent` 里**无条件** fork |
| 过滤条件 | `input-kindle.h:95` | `SUBSYSTEM=input` 且 `DEVNAME` 前缀 `input/event` |
| 前缀语义 | `input/libue.h:92` | `UE_STR_EQ` 是 `strncmp(a, b, sizeof(b)-1)`，**前缀匹配** |
| 事件码 | `input/input.c:49` | `CODE_FAKE_USB_DEVICE_PLUGGED_IN = 10040` |
| Lua 映射 | `frontend/device/input.lua:295` | `10040 → UsbDevicePlugIn` |
| 广播 | `frontend/ui/uimanager.lua:67` | → `Event:new("EvdevInputInsert", "/dev/input/eventN")` |

**不限 UHID。** `input-kindle.h:88-94` 的注释明确写着 "Match any input subsystem event
with an evdev device node… We intentionally don't filter on devpath"。
所以原生蓝牙栈创建的节点同样会触发 —— **设备实测确认**：

```
20:09:17  WARN  Polling for input events returned an error: 19 -> No such device
20:09:17  BT Plugin: Input device removed: /dev/input/event6
20:09:17  BT Plugin: Closing device /dev/input/event6
20:09:28  BT Plugin: Input device inserted: /dev/input/event6
20:09:29  BT Plugin: Opened device /dev/input/event6
```

顺带：设备掉线时 KOReader 自己的 poll 也会拿到 `ENODEV` 并关掉 fd
（`[ko-input] Closed input device … (matched by idx)`），但它**不会清 Lua 侧的
`Input.opened_devices`**，所以插件的 `closeDevice` 仍需执行。两条路径汇合正常，无报错。

## §3 休眠唤醒：不需要定时重连

结论：**插件没有唤醒后按时间重连的逻辑，两种休眠情形都由 §2 的事件覆盖。**

### 情形 A：手柄未掉线（33 秒短休眠实测）

```
20:14:43  Inhibiting user input                              ← 进入休眠
20:15:19  （无 removed / inserted 事件）
```

`/dev/input/event6` 在休眠期间**存活**，fd 仍然可用 —— 什么都不需要做。

### 情形 B：手柄在休眠期间掉线（两个周期实测）

```
20:25:19  Inhibiting user input
20:26:54  Input device removed: /dev/input/event6      ← 休眠 95 秒后掉线
20:26:54  Closing device /dev/input/event6
[ko-input] Closed input device with fd: 13 (matched by fd)
20:29:04  （唤醒）
20:29:10  Input device inserted: /dev/input/event6      ← 手柄重连
20:29:10  Opened device /dev/input/event6

第二个周期：休眠 94 秒后 removed，唤醒后 1 秒 inserted → Opened
```

两个关键事实：

1. **`remove` uevent 跨休眠正常投递** —— 休眠约 95 秒后准时打出，说明掉线那一刻
   CPU 与 uevent 监听器子进程都还活着。此前担心的"uevent 跨休眠丢失"不存在。
   fd 被干净释放（`matched by fd` 表示是插件主动关的，不是 ko-input 的错误清理）。
2. **重连由 `EvdevInputInsert` 完成**，时机取决于蓝牙链路何时恢复
   （实测唤醒后 1~6 秒）。深度休眠期间蓝牙栈挂起，手柄连不上，
   所以重连必然发生在唤醒之后 —— 正是 insert 事件的射程之内。

### 曾经存在的 onOutOfScreenSaver（已删除）

早先有一个"唤醒后按 `wakeup_delay` 秒定时重连"的兜底，实测证明它无用且有害：

- 情形 A：手柄没断，那次 close+reopen 纯属浪费，还会弹一个多余的
  "BT Controller Reconnected" 提示。
- 情形 B 周期 1：定时任务在 +3 秒跑，此时节点尚未创建 → 失败，
  并在日志里留下 `[FBInk] [fbink_input_check] open ...: No such file or directory!` 噪音。
- 情形 B 周期 2：insert 事件在 +1 秒先到，`unschedule` 把定时任务直接取消 → 从未执行。

**三种情形里它一次都没起过作用。** 万一遇到未知边缘情况，菜单里的
「重新加载设备」是一键补救，不需要为此保留自动化。

（历史记录：这段代码的必要性被反复误判过三次 —— 先说它是唯一重连路径、
再说它回收陈旧 fd、再说它防 uevent 丢失。三个理由分别被"日志区分不了必要与
运行"、"`openDevice` 每次打开文档都会自愈"、"remove uevent 实测正常投递"推翻。
换三个理由去保一段代码，本身就是该删的信号。）

## §4 UIManager 排程

- `scheduleIn(seconds, action, ...)` **不返回句柄**（`uimanager.lua:335`，只调用
  `schedule` 后无返回值）。早先代码 `self._wakeup_task = UIManager:scheduleIn(...)`
  永远得到 `nil`，两处 unschedule 从来没生效过。
- `unschedule(action)` **按函数对象匹配，并移除全部匹配项**（`uimanager.lua:440`）。
  因此用**方法引用**（`self._reconnect`）排程，一次 unschedule 就能清掉所有待执行的重连，
  不需要自己存句柄。
- `nextTick(action)` 就是 `scheduleIn(0, action)`（`uimanager.lua:353`）。

## §5 按键重复与 hook 链

- `registerEventAdjustHook` 是**追加**式链接：`old(ev); new(ev)`（`input.lua:422`），
  且**没有注销接口**。所以模块级实例引用必须在 `onExit` 里手动释放。
- `Kindle:toggleKeyRepeat(true)` 用 `self.input.eventAdjustHook = Input.eventAdjustHook`
  **整链清零**（`kindle/device.lua:617`）。插件的 `onToggleKeyRepeat` 里
  `eventAdjustHook == Input.eventAdjustHook` 这个判断恰好只在那一刻成立 —— 不是死代码。
- `toggleKeyRepeat(false)` 追加一个把 `KEY_REPEAT` 的 `ev.value` 置 -1 的 hook
  （`kindle/device.lua:623-624`）。它排在插件 hook **之后**，所以插件先看到 `value == 2`，
  必须自己判 `input_no_key_repeat`。这条两轮 review 都提议删，两次都是错的。
- **Scribe 副作用**：上面那次整链清零会把 `KindleScribe:init()` 注册的
  `KindleGyroTransform`（`kindle/device.lua:1880`）一起冲掉。这是 KOReader 自身的问题，
  不是本插件造成的 —— 表现为在 Scribe 上开关"禁用按键重复"后陀螺仪旋转失效。

## §6 lipc（蓝牙状态）

- `Device:getPowerDevice().lipc_handle` 是 KindlePowerD 持有的**长驻**句柄
  （`kindle/powerd.lua:18`）。自己 `lipc.init()` + `close()` 一个反而比想省掉的 fork 更贵。
- `get_int_property` **失败时返回 nil 而不抛错** —— KOReader 自己也是
  `get_int_property(...) or 0`（`kindle/device.lua:304`）。所以 `pcall` 成功不代表拿到值，
  必须判 `state`。
- `set_int_property` 的返回值在整个 KOReader 里**都被忽略**，没有可靠的成功信号。
  因此写状态只走 `os.execute("lipc-set-prop …")`，用退出码判断成败。
  **不要把 lipc 句柄用回写路径**（这件事发生过一次，然后被 review 抓出来）。
- 属性：`com.lab126.btfd` 的 `BTstate`（读，0=关）与 `BTflightMode`（写，0=开）。
  较新的工具链倾向用 `ace_bt_cli radiostate`；`btfd` 在 Scribe 现固件上仍可用。

## §7 KOReader API 用法

| 需求 | 正确做法 | 出处 |
| --- | --- | --- |
| 插件目录 | `self.path`（PluginLoader 注入） | `pluginloader.lua:248` |
| 序列化配置 | `dump(data, nil, true)`（`ordered=true` 保证键序稳定） | `luasettings.lua:273` |
| 写文件 | `util.writeToFile(data, path, force_flush, lua_dofile_ready)`，第 4 个参数会自动加 `return ` 前缀 | `util.lua:1141` |
| 备份策略 | 仅当原文件 mtime 早于 60 秒前才 rename 成 `.old` | `luasettings.lua:252` |
| shell 参数转义 | `util.shell_escape(array)`，单引号包裹并用空格拼接 | `util.lua:1437` |
| 去首尾空白 | `util.trim(s)` | `util.lua:52` |
| 判断设备已打开 | `Device.input.opened_devices[path] ~= nil`；这张表是 Input 原型上的类成员，**永不为 nil**，不需要判空 | `input.lua:204` |
| 遍历目录 | `for name in lfs.dir(dir) do`，**必须整体传给 for** | 见下 |

### lfs.dir 的返回值不能只接一个

`lfs.dir` 返回 **`(迭代器, 目录对象)`** 两个值，迭代器是无状态的，必须拿那个
userdata 当控制变量。所以下面这种"抽个 helper"的写法是错的：

```lua
-- 错：丢掉了第二个返回值
local ok, iterator = pcall(lfs.dir, directory)
return iterator
-- 用的时候报 bad argument #1 to '(for generator)' (directory metatable expected, got nil)
```

正确做法就是直接写 `for name in lfs.dir(dir) do`（KOReader 全仓库都是这个写法，
如 `pluginloader.lua:203`、`readhistory.lua:127`），目录不存在时 `lfs.dir` 会抛错，
所以外面套一层 `lfs.attributes(dir, "mode") == "directory"` 判断
（同 `externalkeyboard.koplugin` 的做法）。

**这个 bug 真实发生过**：`cleanupBluetoothDumps` 曾因此在点击「清理蓝牙垃圾」时
让 KOReader 直接退出。它躲过了五轮真机测试，因为那条菜单项从来没被点过 ——
教训是冒烟测试表必须覆盖每一个菜单项。

## §8 日志

- `logger.info` 是**默认级别**（`frontend/logger.lua`），不需要开 debug 就会输出。
- stdout/stderr 全部重定向进 `crash.log`，上限 500KB（`koreader.sh:334`：
  `./reader.lua "$@" >>crash.log 2>&1`）。
- 设备上路径：`/mnt/us/koreader/crash.log`，过滤用 `grep "BT Plugin"`。

### 这两行不是错误

```
[ko-input] Closed input device with fd: 16 @ idx: 4 (matched by idx)
WARN  Polling for input events returned an error: 19 -> No such device
```

设备消失时的**正常流程**，KOReader 源码里明确预期了这条路径。`errno 19` 是
`ENODEV`；ko-input 的 `waitForInput` 捕获它并在 C 层自行关掉 fd
（`matched by idx` = 内部按数组下标清理，`matched by fd` = Lua 侧显式请求关闭）。

随后插件的 `closeDevice` 调 `Input:close(path)`，C 层返回 `(false, ENODEV)`，
而 `input.lua:389` 的包装函数把这种情况**当成成功**并清掉表项 —— 它的注释原文：

```lua
if ok or err == C.ENODEV then
    -- Either the call succeeded,
    -- or the backend had already caught an ENODEV in waitForInput and closed the fd internally.
    -- (Because the EvdevInputRemove Event comes from an UsbDevicePlugOut uevent forwarded as an... *input* EV_KEY event ;)).
    -- Regardless, that device is gone, so clear its spot in the hashmap.
```

注释里直接点了 `EvdevInputRemove` —— 也就是本插件走的正是上游设计好的那条路。

## §9 代码中不显然的取舍

代码里只留一行指针，理由在这里。

### openDevice 的关闭顺序（最容易被"优化"回去的一处）

发现节点不可用时，**先关闭旧 fd 再验证**，而不是先验证再关闭。

| 顺序 | 失败时的后果 |
| --- | --- |
| 先关后验（现状） | 偶发的 open 失败会丢一个还在工作的 fd —— 下次插拔事件或「重新加载设备」即可恢复 |
| 先验后关 | 节点已消失时会保留死 fd，`isDeviceOpened` 永远为真，输入闸门一直指向不存在的设备 —— **不重启无法恢复** |

选可恢复的那一侧。这个顺序被两轮 code review 给出过相反结论，改动前请先读这张表。

### 其余各处

| 代码位置 | 取舍 |
| --- | --- |
| `RECONNECT_SETTLE_DELAY = 0.5` | 节点刚建好时驱动可能还没就绪；与 `externalkeyboard.koplugin` 取同值。这是硬件时序旋钮，机器不同可能要调 |
| `isNumberInRange` | 不单独判 NaN/±inf —— 它们过不了 `>=` / `<=` 比较 |
| `applyConfig` 的字段归一化 | 全局唯一的配置校验点，因此输入热路径（`parseInputDirection` 及以下）不再逐字段查类型 |
| `opened_fd` 字段 | 开设备时记下 fd，输入热路径上省一次表查。每次 open 后必须重读 —— 实测同一手柄在不同会话里拿到过 13 和 16 |
| `handleInputEvent` 的 fd 闸门 | 只认手柄那一个 fd，触屏事件在此被挡住，所以不需要额外的 `ABS_MT`（轴码 ≥ 47）预过滤。保留 `not self.opened_fd or` 判空是因为无法证明不存在 `ev.fd == nil` 的事件路径 |
| `closeDevice` 无参调用 | 只关自己开过的节点（回退到 `opened_path`，不回退到 `config.device_path`），别去动别人的 fd |
| `onEvdevInputInsert` 里先 `unschedule` | 快速插拔时才不会堆叠出多个重连任务 |
| `onEvdevInputRemove` 立刻关闭 | 节点消失就放掉 fd，不必等下一次 `openDevice` 去发现它已经死了 |
| `btLipc` | 复用 KindlePowerD 的长驻句柄；自己 `lipc.init()` + `close()` 一个比它想省掉的 fork 更贵 |
| `trigger_cooldown_ms` 在类表上 | 默认值的唯一归宿，`applyConfig` 只在配置里有合法值时覆盖 |
| `DEVICE_TAGS` 存原文 | `_()` 在使用处调用；模块只加载一次，在表里翻译会把语言冻结在加载时刻 |

---

# 验证方法

本地没有 x86 Lua 解释器时，改完只能靠人工复核 —— 上机前务必做第 0 步。

## 0. 语法预检

`koreader/luajit` 是 ARM 二进制，**在设备上能跑**：

```sh
cd /mnt/us/koreader
./luajit -bl plugins/kindle-bluetooth.koplugin/main.lua > /dev/null && echo "SYNTAX OK"
./luajit -bl plugins/kindle-bluetooth.koplugin/bluetooth.lua > /dev/null && echo "CONFIG OK"
```

## 1. 部署与回滚

```sh
# 先留一份能用的
cp -r /mnt/us/koreader/plugins/kindle-bluetooth.koplugin /mnt/us/kbt-backup
# 回滚
rm -rf /mnt/us/koreader/plugins/kindle-bluetooth.koplugin
cp -r /mnt/us/kbt-backup /mnt/us/koreader/plugins/kindle-bluetooth.koplugin
```

## 2. 冒烟测试

| 步骤 | 操作 | 期待日志 |
| --- | --- | --- |
| 加载 | 启动 KOReader | `Loaded profile '<名字>'` |
| 打开 | 同上（`init` 里就会开） | `Opened device /dev/input/eventN` |
| 扫描 | 菜单 → 工具 → 蓝牙翻页器 → 已连接设备 | `Found input device: … (opened=true)`，且**只列手柄** |
| 热插拔 | 关手柄，等 3 秒，再开 | `Input device removed:` → `Input device inserted:` → `Opened device` |
| 休眠（手柄不断） | 短休眠后唤醒 | **无**任何 BT Plugin 日志；手柄直接可用 |
| 休眠（手柄掉线） | 休眠 2 分钟以上再唤醒 | 休眠中 `Input device removed:`；唤醒后 `Input device inserted:` → `Opened device` |

**每一个菜单项都要点一遍**，别只测主路径 —— 曾有一次崩溃就是因为「清理蓝牙垃圾」
五轮测试里一次都没被点过：

| 菜单项 | 期待日志 |
| --- | --- |
| 蓝牙开关 | 提示"Bluetooth enabled/disabled"；失败则 `Failed to change Bluetooth state` |
| 已连接设备 | `Found input device: …` |
| 切换配置 | `Loaded profile '…'` → `Configuration saved` |
| 反转方向 / 摇杆模式 | `Configuration saved` |
| 重新加载设备 | `Loaded profile` → `Opened device` |
| 清理蓝牙垃圾 | `Cleaned up bluetooth dump files` |

功能验证：摇杆推一下能翻页，**且触屏依然正常**（后者验证 fd 闸门 ——
触屏失灵说明 `opened_fd` 匹配错了，事件被误吃）。

## 3. 打开失败排错

| 日志 | 原因 |
| --- | --- |
| `FBInk input classifier is unavailable` / `Failed to load FBInk input classifier` | FBInk 输入库没加载。会导致 `isControllerDevice` 恒为 false，**任何设备都打不开** |
| `Device … unavailable or not a supported controller` | 节点不存在，或 FBInk 不认它是 JOYSTICK/DPAD。先做"扫描"一步拿真实节点号 |
| `Invalid device path` | `device_path` 不符合 `/dev/input/eventN` 格式 |
| `Failed to open … -> …` | 节点在但打不开，通常是权限或已被独占 |

「已连接设备」菜单**不依赖 `device_path`**（`fbink_input_scan` 扫全部节点），
所以配置里节点号写错时，仍可用它查出正确的节点号。
