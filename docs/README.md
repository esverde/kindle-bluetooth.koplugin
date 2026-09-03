# Bluetooth Controller 维护说明

本文记录插件的配置格式、输入设备边界、生命周期约束，以及所有依赖 KOReader
内部行为的**已核验事实**及其出处。

改动这个插件之前先读「已核验事实」一节 —— 里面每一条都是踩坑或翻源码换来的，
其中若干条曾经被"看起来更合理"的直觉推翻过，然后又被证据推翻回来。

> **本分支（BLE）与主分支（经典蓝牙）目标机型不同，配置不可互换。**
>
> | | 主分支 `main` | 本分支 |
> | --- | --- | --- |
> | 机型 | Kindle Scribe | Kindle PW6（Paperwhite 12 代，`0xC7E`） |
> | 手柄 | Xbox Wireless Controller（经典蓝牙） | 黑鲨双翼手柄L（BLE） |
> | 蓝牙栈 | Amazon 原生（`ace_bt_cli` / `lipc com.lab126.btfd`） | kindle-hid-passthrough（用户态 Bumble） |
> | 轴量纲 | 0–65535，中心 32768 | **8 位有符号，中心 0，±127** |
> | 节点 | `/dev/input/event6` | `/dev/input/event3` |
>
> 两条链路的终点相同 —— 都是 `/dev/uhid` → evdev，所以插件消费输入的那部分代码
> 两边完全一致。差别只在**谁负责把 BLE 链路建起来**，见 §11。

验证环境：KOReader **v2026.07.2**。

## 配置文件

配置文件为插件目录下的 `bluetooth.lua`，**单手柄、扁平结构、无多 profile**。

| 字段 | 说明 |
| --- | --- |
| `device_path` | 手柄对应的 Linux 输入节点，例如 `/dev/input/event3`。 |
| `trigger_cooldown_ms` | 两次翻页触发之间的最小间隔，单位为毫秒（0~60000）。 |
| `invert_layout` | 是否反转上一页/下一页方向。**本分支唯一可被菜单覆盖的项**。 |
| `axis_threshold` | 模拟轴死区阈值（0~65535）。本分支为 `95`（行程 ±127）。 |
| `analog_center` | 模拟轴中心值，`analog_map` 里出现的每个轴码都必须有一项。本分支为 `0`。 |
| `key_map` | 按键码到翻页方向的映射；正数为下一页，负数为上一页。 |
| `analog_map` | 模拟轴映射；轴码 0/1，分别表示 X/Y 轴。 |

> 主分支还有 `supports_dpad` / `use_analog_mode` / `dpad_map` 三项，用于在菜单里
> 切换摇杆/方向键模式。**本分支没有** —— 黑鲨手柄只有摇杆 + 四个面键 + 两个
> 肩键，没有十字键，那条模式切换在这台机器上是不可达的死路径（§11）。

改完配置后用菜单「重新加载设备」生效，插件会先释放旧节点再打开新节点。

### 没有兜底：字段缺失或越界一律拒绝

`applyConfig` 是唯一的校验点，上表每一项都**必填且必须合法**，任何一项不过关就
整份配置被拒绝、打一行 `Invalid or missing config field: <字段名>`，运行中的旧配置
保持不变。**插件不会静默替换成内置默认值** —— 这是刻意的：静默替换会让"我改了配置
却没生效"变成无法排查的问题。

校验通过之后，输入热路径直接索引这些字段，不再逐个判类型（docs §9）。

**查真实节点号**：菜单「已连接设备」只显示名称与状态标签，节点号看 `crash.log`：

```sh
grep "Found input device" /mnt/us/koreader/crash.log
# BT Plugin: Found input device: 黑鲨双翼手柄L-BF5B at /dev/input/event3 (opened=true)
```

**`bluetooth.lua` 是只读的**，插件永不改写它，注释和格式随你怎么写。
菜单能改的那一项（反转方向）写到另一个文件，见 §10 ——
其中也包括「改了 `bluetooth.lua` 里那一项却不生效」这个后果。

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

- 插件**每个 ReaderUI 实例化一次**（打开文档时日志会再打一遍 `Loaded config for`）。
  模块级的 `_current_active_controller` 指向当前实例，hook 只注册一次并委派给它。
- 事件驱动重连、重新加载设备时，日志出现"关闭旧节点再打开新节点"是正常流程。
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
- 配置分两个文件：手写的只读，机器写的另存（见 §10）。落盘交给 `LuaSettings`，
  原子写、`.old` 备份、fsync 都由它负责，插件不再手写这套逻辑。

---

# 已核验事实

每条都注明出处。`koreader/` 与 `koreader-base/` 是本地克隆（已 gitignore）。

## §1 FBInk 输入分类

**PW6 上 4 个输入节点的实际分类**（设备日志，KOReader 启动时 FBInk 自己打印，
khp 守护进程运行、手柄已连）：

```
[FBInk] /dev/input/event0: `bd71828-pwrkey`     = KEY | POWER_BUTTON
[FBInk] /dev/input/event1: `pt_mt`              = TOUCHSCREEN
[FBInk] /dev/input/event2: `gesture_tap`        = KEY | KINDLE_FRAME_TAP
[FBInk] /dev/input/event3: `黑鲨双翼手柄L-BF5B`  = JOYSTICK | KEY | MENU_BUTTON | VOLUME_BUTTONS
```

只有 event3 带 `JOYSTICK`，`match = JOYSTICK|DPAD` 这一关就把其余三个全挡住了。
`MENU_BUTTON` / `VOLUME_BUTTONS` 来自 KEY_MENU(139) 与 KEY_VOLUMEUP/DOWN(114/115)，
和 `B: KEY` 位图解出来的一致（见 §11）。

主分支（Scribe）那台是 7 个节点，多出 `bma4xy_acc`（ACCELEROMETER）、
`bma4xy_feature`（ROTATION_EVENT）、`WacomDigitizer` 与 `stylus-custom`
（TABLET）—— PW6 没有陀螺仪和手写笔，所以 §5 里那条「整链清零会连带
干掉 `KindleScribe:init()` 注册的陀螺仪 hook」的副作用在本分支不存在。

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

> §2 与 §3 里的日志原文取自**主分支那台 Scribe**（Xbox 手柄 / `event6`），照录未改。
> 机制与蓝牙栈无关 —— uevent 过滤条件是 `SUBSYSTEM=input` + `DEVNAME` 前缀
> `input/event`（下表），**不看 devpath、不限 UHID**，所以 khp 经 `/dev/uhid`
> 创建的节点走的是同一条链。本分支对应 `event3`。

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
  「手柄已重新连接」提示。
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

## §6 lipc（蓝牙状态）—— 本分支已整段删除

主分支用 `lipc com.lab126.btfd` 的 `BTstate` / `BTflightMode` 读写 Amazon 原生栈的
开关状态，对应 `btLipc` / `getRealState` / `getDisplayState` / `setBluetoothState`、
`toggle_kindle_bluetooth` 这个 Dispatcher 动作，以及菜单里的「蓝牙开关」项。

**本分支把这些全部删掉了（-77 行）。理由不是精简，是正确性：**

BLE 链路由 kindle-hid-passthrough 建立，它**独占 `/dev/stpbt`** 直接驱动蓝牙硬件
（绕开内核 BT 子系统 —— PW6 上 `/sys/class/bluetooth/` 根本不存在，见 §11）。
插件再去 `lipc-set-prop com.lab126.btfd BTflightMode` 开关 Amazon 那套栈，
等于两个进程抢同一块射频。khp 自己就踩过这个坑（上游 PR #192
*"Fix the Bluetooth toggle getting stuck on or off"*）。

所以本分支的原则是：**射频归 khp 管，插件只做 evdev 消费者，不碰蓝牙状态。**

原始的 lipc 事实（`get_int_property` 失败返回 nil 而不抛错、`set_int_property`
没有可靠成功信号、`BTstate` 开启时返回 `2` 而不是 `1`、`liblipclua` 来自固件
`/usr/lib/lua/` 而非 KOReader 的 `common/`）全部仍然有效，**记录在主分支的
`docs/README.md` §6**。要在本分支重新引入蓝牙开关之前，先读那一节。

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
| `axis_threshold` / `trigger_cooldown_ms` 直接读 `self.config` | 两者都是**必填无默认**（`applyConfig` 的 checks 表），校验过了热路径才敢直接索引 |
| `DEVICE_TAGS` 存原文 | `_()` 在使用处调用；模块只加载一次，在表里翻译会把语言冻结在加载时刻 |

## §10 配置分两个文件

一个手写文件被机器改写，必然导致格式、键序、注释被序列化器重写。所以拆开：

| 文件 | 谁写 | 内容 |
| --- | --- | --- |
| `<插件目录>/bluetooth.lua` | **只有用户**，插件永不改写 | 全部配置字段（见开头那张表） |
| `<settings>/bluetooth_controller.lua` | 只有插件（`LuaSettings`） | `invert_layout` 一个覆盖值（主分支还有 `use_analog_mode`） |

取值顺序只有两层：**覆盖值 > `bluetooth.lua`**，由 `override(key, from_file)`
统一实现 —— 只在覆盖值为 `nil` 时回退，所以显式的 `false` 不会被误当作"未设置"。

### 后果：菜单改过的项，改 bluetooth.lua 不再生效

`invert_layout` 一旦在菜单里点过，就以覆盖文件为准。要交回文件控制，
删掉覆盖文件里对应的键，或直接删掉整个 `<settings>/bluetooth_controller.lua`。

这是 KOReader 自己的模型（`defaults.lua` 给默认、`settings.reader.lua` 存覆盖）。

### 陷阱：读覆盖值不能用 `or`

```lua
-- 错：覆盖值为 false 时会被吃掉，退回文件里的值
local v = self:override("invert_layout", cfg.invert_layout) or cfg.invert_layout
-- 对：override 内部只判 nil
function BluetoothController:override(key, from_file)
    local value = self.settings:readSetting(key)
    if value == nil then return from_file end
    return value
end
```

**这个坑只在覆盖值是布尔时存在，而本分支的覆盖值全是布尔。**
主分支上它的实际症状是"选了方向键，重启后变回模拟摇杆"（那一项已删，见 §11）；
本分支等价的症状是"关掉反转方向，重启后又反转了"。只有重启才暴露 ——
所以验证表里专门列了「重启后仍然反转」这一项。

### 这次拆分与单手柄化删掉的代码

`LuaSettings:flush()`（`luasettings.lua:270`）本身就是
`backup()` + `writeToFile(dump(data, nil, true), file, true, true, dir_updated)`，
和插件此前手写的那套一字不差。所以：

- `writeConfigAtomically`、`saveFullConfig`、`_config_loaded` 闸门 → 删
- `setCommonSetting` / `setActiveProfileSetting` → 合并为一个 `saveOverride`
- `profiles` 嵌套、`active_profile`、`saveAnalogMode`、「切换配置」菜单项 → 删
- `AXIS_CENTER_DEFAULT`、`AXIS_THRESHOLD_DEFAULT`、`DEFAULT_PROFILE`
  与类表上的 `trigger_cooldown_ms` → 删，改为加载时校验

`DEFAULT_PROFILE` 尤其该删：它硬编码了一个具体手柄名，把 profile 改名而忘了同步
`active_profile` 就会导致插件拒绝启动 —— 那是"猜一个名字"，不是兜底。

## §11 BLE 链路（本分支专属）

### 目标机器

`kindle-hid-passthrough --diagnostics` 实测（这个子命令是只读的，排错先跑它）：

| 项 | 值 |
| --- | --- |
| 型号 | Kindle PW6（device code `0xC7E`） |
| 内核 | `5.15.41-lab126` |
| 固件 | `042-juno_1906_sangria_bellatrix4-483216` |
| 传输 | `file:/dev/stpbt`，`chip backend: MtkChip` |
| `/dev/stpbt` | `crw-rw---- root bluetoot 192,0` |
| `/dev/uhid` | 存在；`/sys/bus/hid` 存在 |
| 已加载模块 | `wmt_cdev_bt`、`wmt_drv`（联发科 CONSYS，**不是** Linux BT 子系统） |

> khp 的 README 说 MediaTek 11 代是 `4.9.77-lab126` —— PW6 是 12 代，实测
> `5.15.41`。别照抄 README 里的内核号。

### 为什么必须靠外部守护进程

**Kindle 原生栈不支持 BLE。** 这不是配置问题：PW6 上内核 BT 子系统压根没编进去，
实测四条命令全空 ——

```sh
ls /sys/class/bluetooth/     # No such file or directory
zcat /proc/config.gz         # 无 config.gz
lsmod | grep -E 'bluetooth|btmtk|hidp'   # 空
which hciconfig hcitool bluetoothctl btmgmt   # 空
```

Amazon 用的是 Bluedroid，走**厂商 HAL 直接操作 `/dev/stpbt`**，完全绕开 Linux BT
子系统。所以 BlueZ 那条路（内核做 SMP + HoGP，设备直接出 evdev）在这台机器上
不存在，**不必再试**。

顺带一条支持 §6 那个删除决定的实测：khp 跑起来时 Amazon 那套栈**根本没在运行** ——
`bsa_server: not running`、`btd: not running`、`btfd BTstate: 0`。khp 面对的是一块
干净的射频。插件若去 `lipc-set-prop BTflightMode` 把 Amazon 栈拉起来，那才是
主动制造冲突。

### 为什么不是 Sighery/kindlebt

调研过并放弃。`kindlebt` 是 Amazon 闭源 `ace_bt` 的开源包装，但：

- 上游 `manual/limitations.md` 原文：*"I've noticed issues connecting Bluetooth 4.2
  keyboards (HID)"*，而本手柄正是 BLE HID（HoGP，service `0x1812`）
- 公开 API 里**没有任何 pairing/bonding 函数**（`bondState_t` 只是个空 typedef）
- `ace_bt` **不能以 root 运行**，必须 root 启动后立刻 `setgid(1003); setuid(1003)`
  降权到 `bluetooth` 用户。KOReader 不是这个身份，所以躲不开拆独立进程 ——
  这也是上游 `turnkey` 被迫做成 gRPC daemon + 主进程双架构的原因
- kindlebt 作者自己在 README 里把 HID 场景**指向了 kindle-hid-passthrough**

顺带纠正两个容易被名字误导的仓库：`kindle-page-turner` 的 README 标题字面是
*"Example Go application for kindle-bt-api"*，硬编码作者自己 Pico 上的 LED
characteristic，**没有任何翻页逻辑**；`turnkey` 的输入设备只实现了一个智能戒指，
手势→翻页的映射尚未实现。三个仓库**都没有重连/掉线处理**。

本仓库 `4adbeaf` 那份 `ble_defs.lua` / `ble_manager.lua` / `ble_service.lua`
是基于 kindlebt 的旧尝试，三层互相对不上（`ble_service.lua:39` 的 cdef 被删空、
导出符号与 `adapter.c` 不一致、线格式一个 `[type:1][len:2]` 一个 `[len:1]`），
且 `libkindlebt_adapter.so` 的源码已对不上二进制。**不要试图复活它。**

### 链路与分工

```
黑鲨手柄 ──BLE HID(GATT notify)──> Bumble(用户态栈, /dev/stpbt)
         ──> /dev/uhid ──> 内核解析 HID descriptor ──> /dev/input/event3
                                                            │
                                              本插件（普通 evdev 消费者）
```

**射频归 khp，插件只读 evdev。** 插件不碰蓝牙状态（§6），不实现 GATT，
不加载任何 `.so`。终点和主分支一样是 evdev，所以 §1–§5、§7–§10 全部适用。

### 守护进程：手动剪裁安装

版本钉在 **v3.15.2 / `BUILD_SHA = 202ef78`**（`dist/kindle_hid_passthrough/BUILD_SHA`）。
守护进程本体**不进本仓库** —— 21M 三方二进制进 git 历史是永久成本，而且上游在活跃
修变砖级 bug（PR #230 修 `install.sh` 把 `/` 留在读写挂载、PR #246 修 btd 被 SIGSTOP
后再也解冻不了），钉死版本会让这些修复静默到不了手上。这个仓库还为此死过一次：
`4adbeaf` 里的 `libkindlebt_adapter.so` 与它的 `adapter.c` 符号名已经对不上。

**整个目录可迁移，不需要任何环境变量；但 `config.ini` 里的绝对路径必须改。**

- **启动器**（ARM 静态 ELF）用 `/proc/self/exe` + `readlink` 定位自己，再按相对路径
  加载 `dist/ld-linux-armhf.so.3` 和 `dist/main.bin`。里面**没有任何 `/mnt/us` 硬编码**。
- **base path** 由 `Config._determine_base_path` 解析，顺序是
  `os.environ["KINDLE_HID_BASE"]` → **exe 所在目录** → 硬编码默认值
  `/mnt/us/kindle_hid_passthrough`。实测从 `khp/` 直接跑（不设任何环境变量）
  就打出 `Config base path: /mnt/us/koreader/plugins/bluetooth.koplugin/khp`
  —— 所以 `KINDLE_HID_BASE` 是可用的覆盖手段，但迁移**用不到**它。
  （另有 `KINDLE_HID_DEBUG` 可用于排错。`--help` 里没有对应的命令行开关。）
- **但 `config.ini` 内部两条是绝对路径**，base path 变了它们不会跟着变：

  ```ini
  cache_dir      = <base>/cache
  devices_config = <base>/devices.conf
  ```

  不改的症状是**静默用旧目录**（日志里 `Using device from
  /mnt/us/kindle_hid_passthrough/devices.conf: …`），此时删旧目录就断。迁移时：

  ```sh
  cp -a /mnt/us/kindle_hid_passthrough/cache /mnt/us/kindle_hid_passthrough/devices.conf .
  sed -i 's#/mnt/us/kindle_hid_passthrough#'"$PWD"'#g' config.ini
  ```

所以全部放一处即可：

| 位置 | 内容 | 大小 |
| --- | --- | --- |
| `<插件目录>/khp/` | `kindle-hid-passthrough`（**必须 `chmod +x`**）、`libsyscall_wrapper.so`、`dist/`、`config.ini`、`cache/`、`devices.conf` | 18.7M |

> `dist/kindle_hid_passthrough/config.ini`（661B）**保留**。`_module_search_dirs`
> 证明 `<base>/dist/kindle_hid_passthrough/` 是打包资源查找目录（`modules/` 也在
> 那儿），那份 config 可能是 freeze 时带进来的默认值，也可能是 fallback ——
> 从二进制里分不出来。为省 661 字节去赌一个未知不值得。

从 release 包里**丢弃**这些（21M → 18.7M）：

| 丢弃 | 大小 | 理由 |
| --- | --- | --- |
| `dist/kindle_hid_passthrough/modules/` | 1.3M | 12 个 `uhid-*.ko`，是给 8–10 代**内核没编 `CONFIG_UHID`** 的机器补的。PW6 内核 5.15.41 原生支持（`--diagnostics` 里 `/dev/uhid: True`、`/sys/bus/hid: True`）。守护进程日志自己也写了：*"only needed to inject key events for external tools like kindle-button-mapper"* |
| `button-mapper/` | 878K | 上游 boot loop 成因之一，见下 |
| `koreader-plugin/` | 201K | 与本插件功能重叠（也做按键→动作映射），且它的 KOReader 动作需要开 HTTP Inspector |
| `illusion/` | 88K | WAF app 相关 |
| `assets/` | 6K | udev 规则 / upstart / WAF `config.xml`，三样都不装 |
| `scripts/` | 60K | `hid-passthrough-daemon.sh` 的路径按 `/mnt/us/kindle_hid_passthrough` 写死，挪目录就不对；开关由插件自己做 |

```sh
cd /mnt/us/koreader/plugins/bluetooth.koplugin/khp
chmod +x kindle-hid-passthrough
setsid ./kindle-hid-passthrough --daemon > /dev/null 2>&1 < /dev/null &
sleep 8 && grep -E "Keystore|Serving devices" /var/log/hid_passthrough.log | tail -4
```

期待 `Serving devices (Classic: 0, BLE: 1)`。确认迁移是否彻底则**直接看文件**，
不用重启守护进程：

```sh
grep -A3 '\[paths\]' config.ini && ls -l devices.conf && ls cache/
```

### 排错：三个会误导人的现象

**重定向 stdout 会得到一个空日志。** Python 在 stdout 不是 TTY 时走块缓冲，
守护进程一直活着就一直不 flush，`> /tmp/khp.log` 拿到的是空文件。
**看它自己那份日志**（`config.ini` 的 `log_file`，默认 `/var/log/hid_passthrough.log`，
在 tmpfs 上、重启即失）。

**两份日志内容不一样，别在错的那份里 grep。** `>>>` 前缀那些行
（`Detected Kindle …`、`Config base path: …`、`Using device from …/devices.conf: …`）
是**控制台输出，不走 Python logger**，`/var/log/hid_passthrough.log` 里没有。
要看它们只能前台跑：`./kindle-hid-passthrough --daemon 2>&1 | head -8`。

**`[1]+ Done` 不代表守护进程死了。** `setsid` 在不是进程组长时 fork 后自己立刻退出，
shell 报告的是那个 wrapper。判据看 `ps aux | grep ld-linux-armhf`。

**`Address already in use`（`api_server.py:49 server_bind`）说明已经有一个实例在跑**，
API 端口 8321 被占。先 `pkill -f ld-linux-armhf`。

排错顺序：`tail -30 /var/log/hid_passthrough.log` → `ps aux | grep ld-linux-armhf`
→ `--diagnostics`。注意 `--diagnostics` **不打** `Config base path`，而且它那段
`===== Daemon log tail =====` 是历史日志，别拿来当当前状态读。

### 不要装的三样（即使用官方安装器）

| 跳过 | 理由 |
| --- | --- |
| WAF app（`installWAFApp`，option 6）/ Button Mapper（option 8） | 上游 boot loop 的成因。#226（PW6 5.19.5）与 #250（11 代）崩的都是 `mesquite` / `pillowd`，触发者是 BTManager 的 WAF scriptlet；变砖机制见 PR #230：`installAll` shell out 到 button-mapper 安装器，那个跑在 `set -e` 下可能在 `mntroot rw` 窗口里 abort，把 `/` 留在读写挂载，加上 `core_pattern` 是裸 `core` |
| 开机自启（`installUpstart`，option 5） | 会一直占着射频（上游默认关闭，原文 *"leaves the Bluetooth radio free for audio"*） |
| udev 规则（`installUdevRules`，option 4） | **对本手柄无效，装了也白装** —— 见下 |

#### udev 规则为什么对本手柄无效

`assets/99-hid-keyboard.rules` + `scripts/dev_is_keyboard.sh` 的作用是给**键盘**打
`ID_INPUT_KEYBOARD` 标记，闸门是 **KEY_Q（bit 16）**：

```sh
LAST_WORD=$(cat "$CAPS/key" | tr ' ' '\n' | tail -1)
Q_BIT=$(( 0x$LAST_WORD & 0x10000 ))
```

本手柄的 `B: KEY=6fdb0000 0 0 0 1000 40000800 c0000 0 0 0`，**最右一组（bit 0–31）
是 `0`**，所以 `Q_BIT = 0`，不会被打标记。既不产生效果，就没有理由去改 `/etc`。

> 曾经写过「装了这条规则会让 KOReader 也把手柄当键盘打开 → 双 fd → 翻两页」——
> **那是错的**，前提不成立，因为手柄拿不到键盘标记。这个双 fd 隐患只在
> 真配一个蓝牙键盘时才存在；那时候要用 khp 自带的 sysfs 版本，不要用网上流传的
> `evtest` 版本（Kindle 上不一定有 `evtest`）。

规则里另一行 `KERNEL=="uhid", MODE="0660", GROUP="bluetooth"` 是把 `/dev/uhid` 放权
给 `bluetooth` 组；以 root 跑守护进程时用不上。

`start()` 只用裸 `&`，没有 `nohup`/`setsid`，SSH 断开会跟着 SIGHUP 走 ——
所以上面用 `setsid` 自己拉。**进程名是 `ld-linux-armhf.so.3` 而不是
`kindle-hid-passthrough`**（跑在打包的动态加载器下），所以：

```sh
ps aux | grep 'ld-linux-armhf' | grep -v grep   # 查
pkill -f ld-linux-armhf                          # 停
```

### 实测数值

| 项 | 实测值 | 出处 |
| --- | --- | --- |
| 常驻内存 | **RSS 33060 KB ≈ 32.3 MB**（VSZ 37728 KB，CPU 2.4%，总内存 956 MB） | `ps aux` |
| 轴量纲 | **8 位有符号，中心 0，极值 ±127** | `event3` 原始字节，见下 |
| 按键码（**声明**） | 304 305 307 308 310 311 312 313 314 315 317 318 | `B: KEY` 位图解码 |
| 按键码（**实发**） | 304 305 307 308 310 **312** | 逐个实按 |
| 方向键 | **不存在**（物理上没有十字键） | 只按方向键时收不到 `code=16/17` |

「Bumble 太重」这个判断被 32 MB / 3.3% 推翻了 —— 和当年「菜单卡顿」量出
`fbink_input_scan` 只花 2.2ms 是同一类：先量，再判。

**轴量纲的解码过程**（32 位 ARM 的 `input_event` = `tv_sec`+`tv_usec`+`type`+`code`+`value`，共 16 字节）：

```
0300 0000 7f00 0000   type=3(EV_ABS) code=0(ABS_X) value=+127
0300 0000 81ff ffff   type=3          code=0        value=-127
0300 0100 cfff ffff   type=3          code=1(ABS_Y) value=-49
```

**按键位图的解码过程**。`/proc/bus/input/devices` 的 `B: KEY` 按 unsigned long
分组打印，**最右一组是 bit 0–31，往左每组 +32**：

```
B: KEY=6fdb0000 0 0 0 1000 40000800 c0000 0 0 0
        └ bit 288-319                    └ bit 96-127
0x6fdb0000 → 组内 bit 16,17,19,20,22,23,24,25,26,27,29,30
           → +288 = 304,305,307,308,310,311,312,313,314,315,317,318
```

### ⚠️ 位图只能用来排除，不能用来确认

**这个手柄的 HID report descriptor 声明的能力比它实际有的多。** 两处实证：

| 声明 | 实际 |
| --- | --- |
| `ABS=307bf` 含 bit 16/17（ABS_HAT0X/Y） | **物理上没有十字键**，只按方向键时一个 `code=16/17` 都不发 |
| `B: KEY` 声明 12 个键 | 实按只有 6 个发：304 305 307 308 310 312。**311(BTN_TR) 不发** —— 这是「左翼」单体，311 属于右翼那一半 |

所以位图的正确用法是：**没声明的一定不发**（可用于排除），**声明了的不一定发**
（不可用于确认）。这一条是踩出来的 —— 按位图把 `supports_dpad` 设成 `true`、
把肩键映射成 `310/311`，两处都错，各自的症状是「切到方向键模式后彻底翻不了页」
和「一个肩键是死键」。**凡是要写进 `key_map` 的码，逐个实按。**

（`supports_dpad` 这个字段后来整个删掉了 —— 见下。）

抓键码的办法（`g4=0100` 是 EV_KEY，`g5` 是键码小端，`g6=0100` 是按下）：

```sh
cat /dev/input/event3 | xxd | grep ' 0100 '
# 3601=310(BTN_TL)  3701=311(BTN_TR)  3801=312(BTN_TL2)  3901=313(BTN_TR2)
```

反过来，旧配置（`4adbeaf`）里那些**猜的**值倒是全对：`axis_center = 0`、
`axis_max = 127`、`supports_dpad = false`，以及肩键那对 **310/312**。

### FBInk 会把 event3 判成 JOYSTICK

逐条走 `fbink_input_scan.c` 的 `test_pointers` if/else 链：

| 分支 | 需要的位 | event3 | 结果 |
| --- | --- | --- | --- |
| `has_abs_coordinates` | ABS_X(0) && ABS_Y(1) | 都有 | 进入判定 |
| `stylus_or_pen` | BTN_TOOL_PEN | 无 | 跳过 |
| `finger_but_no_pen` | BTN_TOOL_FINGER | 无 | 跳过 |
| `has_mouse_button` | BTN_LEFT/RIGHT/MIDDLE (272-274) | 无 | 跳过 |
| `has_touch` | BTN_TOUCH (330) | 无（位图只印到 bit 319 那组，说明 ≥320 全 0） | 跳过 |
| `has_joystick_axes_or_buttons` | `BTN_A \|\| BTN_TRIGGER \|\| BTN_1 \|\| ABS_RX \|\| …` | BTN_A(304) ✓、ABS_RX(3) ✓ | **is_joystick** |

`exclude = INPUT_TOUCHSCREEN` 不会误命中：`has_mt_coordinates` 要
ABS_MT_POSITION_X/Y（53/54），位图里没有。所以 `isControllerDevice` 返回 true，
`openDevice` 原样可用 —— **设备名是中文不影响**，分类只看能力位，不看名字。

### 已在真机验证

- FBInk 分类命中 `JOYSTICK`，`isControllerDevice` 返回 true
- `Loaded config for /dev/input/event3` → `Opened device /dev/input/event3`
- 「已连接设备」列出手柄、「清理蓝牙垃圾」正常
- **摇杆翻页正常**（`GotoViewRel` 无日志，靠肉眼确认）
- **四个面键与两个肩键（310/312）翻页正常**
- **重启后配置正常加载**
- **「反转方向」重启后仍然反转**（`Saved override invert_layout`）—— §10 的
  关键验证点，历史上正是这里踩过「读覆盖值用 `or` 会把 `false` 吃掉」的坑
- **守护进程菜单开关**（§12）：起停各一次，`Input device removed` /
  `inserted` → `Opened device` 全自动衔接
- **`onEvdevInputRemove` 在「节点被拔掉」方向也成立**：§2 里那批日志是手柄
  自己掉线触发的，这次是**提供节点的进程被杀**触发的 —— 同一个 handler、
  不同触发源，都能正确释放 fd
- khp 迁移彻底：`config.ini` 两条路径指向 `khp/`，`devices.conf` 与
  `cache/{pairing_keys.json,04_33_85_2C_BF_5B.json}` 均在 `khp/` 内

**功能验证到此完整**，验证方法一节的菜单表每一项都点过。

### 摇杆/方向键模式切换：本分支整个删掉了

黑鲨手柄只有摇杆 + 四个面键 + 两个肩键，**没有十字键**，所以模式切换在这台
机器上是不可达的死路径。删掉的东西：

| 位置 | 删掉的 |
| --- | --- |
| `bluetooth.lua` | `supports_dpad`、`use_analog_mode`、`dpad_map` |
| `applyConfig` | `dpad_map` 的类型校验、`supports_dpad` 与 `use_analog_mode` 两行赋值 |
| `parseInputDirection` | `EV_ABS` 的二选一分支，直接走 `parseAnalogInput` |
| `main.lua` | `parseDpadInput`、`joystickModeItem`、「摇杆模式」菜单项 |

**留着它不是中性的，它是一个陷阱的来源。** `supports_dpad = false` 会让「摇杆
模式」菜单项变灰，于是**若在 `supports_dpad` 还是 `true` 的那几个版本里误切过
「方向键」**，覆盖值 `false` 已经落进 `<settings>/bluetooth_controller.lua`，
而菜单已经灰了、切不回来 —— 症状是完全不翻页。删掉整条路径之后
`use_analog_mode` 根本不再被读取，这个坑就**不可能发生**了
（残留的旧覆盖值会被静默忽略，无需清理）。

> 曾经的判断是「保留 dpad 代码，删了每次 `git merge main` 都要处理冲突」。
> 那个权衡算错了：主分支的 dpad 代码是完成态、极少改动，冲突成本接近零；
> 而保留它的代价是一个能把人锁死的 footgun。**merge 便利不值得用一个已知
> 陷阱去换。**

### `event3` 这个节点号会漂移

已实测： 重新配对+重启守护进程后 sysfs 变成
`uhid/0005:0000:0000.0002/input/input4` —— **`inputN` 单调递增（3 → 4），
但 evdev handler 仍是 `event3`**，因为 `eventN` 会回收复用。所以只要 3 个内建
节点（event0/1/2）不变、且不同时接第二个 HID 设备，手柄就稳定落在 event3。
多接一个就会漂移。掉线重连本身由 `onEvdevInputInsert` 兜住（§2），
但**换了节点号要改 `bluetooth.lua`**（节点号看 §「查真实节点号」）。

## §12 守护进程开关：为什么用信号而不是 HTTP API

khp 的守护进程在 `127.0.0.1:8321` 暴露一个 HTTP API（`/status` `/start` `/stop`），
它自带的 KOReader 插件就是走这条路的。**本插件不用它，用 `pgrep` + `pkill`。**

### 理由

**上游自己的停止方式就是信号。** `scripts/hid-passthrough-daemon.sh` 的 `stop()`：

```sh
PID=$(pgrep -f "$LD_PROCESS")
kill -TERM "$PID"
```

**那个「三态」是用 API 停的产物，不是守护进程的性质。** khp 插件要区分
`off`（API 不可达）/ `api_only`（API 活着但 HID 层停了）/ `on`，是因为它的 `/stop`
**故意只停 HID 层、留着 API server** 好让下次启动快。我们用信号停整个进程，
就只剩「进程在 / 不在」两态，状态机整个不需要存在。

**它需要 API 是因为它做的事多得多** —— 配对、扫描、设备列表、按键映射，那些都得
跟守护进程对话。本插件只要开关，进程存活性 `pgrep` 就够，
`socket.http` + 超时 + JSON 解析 + 轮询状态机全是白背的复杂度。

### 一处比上游更准

khp 脚本用 `pgrep -f "ld-linux-armhf."`，这个模式**太宽** —— 会命中任何用同名
动态加载器起的进程。我们知道自己装在哪，所以匹配完整路径：

```lua
util.shell_escape({ self.path .. "/khp/dist/main.bin" })
```

（`self.path` 由 PluginLoader 注入，见 §7。）

### 起停都不是同步的

`setsid … --daemon … &` 和 `pkill` 之后 shell 立刻返回，`os.execute` 的退出码
**没有意义**。实测时序（设备日志）：

```
23:12:37  khp daemon stop requested
23:12:37  Input device removed: /dev/input/event3      ← 同一秒
23:12:37  Closing device /dev/input/event3
          [ko-input] Closed input device with fd: 12 (matched by fd)
23:12:49  khp daemon start requested
23:12:54  Input device inserted: /dev/input/event3      ← +5s
23:12:54  Opened device /dev/input/event3               ← settle 0.5s 内
```

- **停是同步的**：`pkill` 的那一秒 uevent 就到，fd 立刻释放。
- **起要约 5s**：守护进程自身约 3s 就绪，之后还要重连 BLE、建 uhid 节点。
  所以 `DAEMON_START_DELAY = 6` 不是拍的 —— 它刚好落在节点出现之后，
  那句「守护进程已启动」才会在设备真的回来之后弹出。改这个常量前先看这段时序。
- 重连**全自动**，不需要手动「重新加载设备」：`onEvdevInputInsert` 接住
  uevent，等 `RECONNECT_SETTLE_DELAY` 后 `Opened device`。

所以：

- 点击后先弹「正在启动/停止…」
- `UIManager:scheduleIn(6, …)` 再查一次并报结果 —— **不用阻塞 sleep**。
  khp 插件那边是 `ffiutil.sleep(1)` 循环 + `START_TIMEOUT = 15`，会**卡住
  KOReader UI 线程最多 15 秒**，e-ink 上就是整机假死。
- 延时回调**只弹 InfoMessage，不碰菜单控件** —— 用户可能已经关掉菜单，
  在死控件上 `updateItems` 是自找麻烦。状态由 `checked_func` 下次重绘时自然刷新。
- 回调**存成 `self._daemon_check` 字段**而不是匿名闭包，这样 `onExit` 能
  `unschedule` 掉。匿名闭包会持有 `self`，也就连带持有 ReaderUI ——
  这类泄漏在本仓库出现过一次。
  （`UIManager:unschedule(nil)` 是安全空操作：每个已排程任务的 `action` 都非 nil，
  `uimanager.lua:440` 的比较不会命中。）

**不主动 `reloadDevice()`。** 节点是手柄连上时才出现的，可能晚于那 6 秒；
而那条路已经由 `onEvdevInputInsert` 兜住（§2，已实测）。

`checked_func` 会在每次菜单重绘时被调用，所以 `isDaemonRunning` 带 2 秒缓存
（`DAEMON_CACHE_INTERVAL`），否则每次重绘都 fork 一个 `pgrep` —— 与主分支给
蓝牙状态加缓存是同一个理由。

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
| 加载 | 启动 KOReader | `Loaded config for /dev/input/eventN` |
| 打开 | 同上（`init` 里就会开） | `Opened device /dev/input/eventN` |
| 扫描 | 菜单 → 工具 → 蓝牙翻页器 → 已连接设备 | `Found input device: … (opened=true)`，且**只列手柄** |
| 热插拔 | 关手柄，等 3 秒，再开 | `Input device removed:` → `Input device inserted:` → `Opened device` |
| 休眠（手柄不断） | 短休眠后唤醒 | **无**任何 BT Plugin 日志；手柄直接可用 |
| 休眠（手柄掉线） | 休眠 2 分钟以上再唤醒 | 休眠中 `Input device removed:`；唤醒后 `Input device inserted:` → `Opened device` |

**每一个菜单项都要点一遍**，别只测主路径 —— 曾有一次崩溃就是因为「清理蓝牙垃圾」
五轮测试里一次都没被点过：

| 菜单项 | 期待日志 | 另外确认 |
| --- | --- | --- |
| 蓝牙守护进程 → 开 | `khp daemon start requested` → 约 5s 后 `Input device inserted` → `Opened device` | 提示「已启动」；此时会连着弹一条「手柄已重新连接」，两条 toast 各占一次 e-ink 刷新，属正常 |
| 蓝牙守护进程 → 关 | `khp daemon stop requested` → 同一秒 `Input device removed` → `Closing device` | 提示「已停止」；`ko-input` 打出 `Closed input device with fd: N` |
| 已连接设备 | `Found input device: …` | 只列手柄，不含触屏/frame tap |
| 反转方向 | `Saved override invert_layout` | **重启后仍然反转** |
| 重新加载设备 | `Loaded config for` → `Closing device` → `Opened device` | — |
| 清理蓝牙垃圾 | `Cleaned up bluetooth dump files` | — |

（主分支还有一项「摇杆模式 → 方向键」，本分支已删，见 §11。）

「另外确认」里那个**重启后**是配置拆分（§10）的关键验证点：覆盖值存在
`<settings>/bluetooth_controller.lua`，读取时若误用 `or` 而非判 `nil`，
显式的 `false` 就会被 `bluetooth.lua` 里的值顶掉 —— 表现是"关掉反转方向，
重启后又反转了"。这一项**只有重启才暴露**。

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
