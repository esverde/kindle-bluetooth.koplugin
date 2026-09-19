# Bluetooth Controller 维护说明

本文记录插件的配置格式、输入设备边界、生命周期约束，以及所有依赖 KOReader
内部行为的**已核验事实**及其出处。

改动这个插件之前先读「已核验事实」一节 —— 里面每一条都是踩坑或翻源码换来的，
其中若干条曾经被"看起来更合理"的直觉推翻过，然后又被证据推翻回来。

> **这是维护者笔记，不是使用说明。** 面向用户的文档见仓库根目录的
> `README.md`（英文）/ `README.zh-CN.md`（中文）。这里只记实现过程中查证过的
> 事实与被否掉的方案，避免重复踩坑。
>
> | | `main`（本分支） | `classic` 分支 |
> | --- | --- | --- |
> | 链路 | BLE，经 kindle-hid-passthrough（用户态 Bumble） | 经典蓝牙，Amazon 原生栈（`lipc com.lab126.btfd`） |
> | 实测机型 | Scribe、Paperwhite 12 代、Kindle(2024) | 仅 Scribe |
> | 状态 | 在维护 | 归档，不再更新 |
>
> 两条链路的终点相同 —— 都是 `/dev/uhid` → evdev，所以插件消费输入的那部分代码
> 两边基本一致。差别只在**谁负责把链路建起来**，见 §11。
>
> ⚠️ **两个分支的 `bluetooth.lua` 数值不能互抄。** 轴量纲可能差 256 倍：16 位手柄
> 是 0–65535 / 中心 32768，8 位手柄是 ±127 / 中心 0。抄错的症状是「推不动」或
> 「碰一下就翻页」。换手柄一律重新实测，方法见 §11「实测数值」。

验证环境：KOReader **v2026.07.2**。

## 配置文件

**字段含义与示例见仓库根目录的 README**，这里只记它背后的规则。结构是**配置数组**，
生效的那份按设备名解析（§16）。

### 没有兜底：字段缺失或越界一律拒绝

`applyConfig` 是唯一的校验点，上表每一项都**必填且必须合法**，任何一项不过关就
整份配置被拒绝、打一行 `Invalid or missing config field: <字段名>`，运行中的旧配置
保持不变。**插件不会静默替换成内置默认值** —— 这是刻意的：静默替换会让"我改了配置
却没生效"变成无法排查的问题。

校验通过之后，输入热路径直接索引这些字段，不再逐个判类型（docs §9）。

**查真实节点号**：菜单「已连接设备」只显示名称与状态标签。节点号现在**不需要**填进
配置（§16），排错时看日志 —— 注意这行是 `logger.dbg`，要开 debug 才有：

```sh
grep "Found input device" /mnt/us/koreader/crash.log
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
- 守护进程存活性查询（`isDaemonRunning`）**不带缓存**，见 §12。
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
[FBInk] /dev/input/event3: `黑鲨双翼手柄L-XXXX`  = JOYSTICK | KEY | MENU_BUTTON | VOLUME_BUTTONS
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

- 情形 A：手柄没断，那次 close+reopen 纯属浪费，还会多弹一条重连提示。
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

## §6 不碰 Amazon 的蓝牙状态

**原则：射频归 khp 管，插件只做 evdev 消费者。**

khp 独占 `/dev/stpbt` 直驱蓝牙硬件（绕开内核 BT 子系统，见 §11）。插件再去
`lipc-set-prop com.lab126.btfd BTflightMode` 开关 Amazon 那套栈，等于两个进程抢
同一块射频 —— khp 自己踩过这个坑（上游 PR #192 *"Fix the Bluetooth toggle
getting stuck on or off"*）。

所以本分支没有 `getRealState` / `setBluetoothState` / 「蓝牙开关」菜单项。
那套 lipc 代码与其全部实测事实仍在**`classic` 分支的 `docs/README.md` §6**，
要重新引入之前先读那一节。

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

**这个 bug 真实发生过**：早先那个清理转储文件的功能（后来整个删掉了）曾因此在点击
菜单项时让 KOReader 直接退出。它躲过了五轮真机测试，因为那条菜单项从来没被点过
—— 教训是冒烟测试表必须覆盖每一个菜单项。

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
| `applyConfig` 用 `for k,v in pairs(cfg)` 整表拷贝 | 不逐字段枚举赋值 —— 那样每加一个配置项都要在这里同步一次，漏一个就是「改了配置不生效」。拷完再单独覆盖唯一那个可被菜单改的项 |
| `startDaemon` 先 `lfs.attributes` 判存在 | `khp/` 在 `.gitignore` 里，「新克隆后守护进程二进制不存在」是最可能的实际场景。少了这一判，`setsid` 会静默失败，症状退化成「点了没反应」 |
| `opened_fd` 字段 | 开设备时记下 fd，输入热路径上省一次表查。每次 open 后必须重读 —— 实测同一手柄在不同会话里拿到过 13 和 16 |
| `handleInputEvent` 的 fd 闸门 | 只认手柄那一个 fd，触屏事件在此被挡住，所以不需要额外的 `ABS_MT`（轴码 ≥ 47）预过滤。保留 `not self.opened_fd or` 判空是因为无法证明不存在 `ev.fd == nil` 的事件路径 |
| `closeDevice` 无参调用 | 只关自己开过的节点（回退到 `opened_path`），别去动别人的 fd |
| `onEvdevInputInsert` 里先 `unschedule` | 快速插拔时才不会堆叠出多个重连任务 |
| `onEvdevInputRemove` 立刻关闭 | 节点消失就放掉 fd，不必等下一次 `openDevice` 去发现它已经死了 |
| `axis_threshold` / `trigger_cooldown_ms` 直接读 `self.config` | 两者都是**必填无默认**（`applyConfig` 的 checks 表），校验过了热路径才敢直接索引 |
| `DEVICE_TAGS` 的 `_()` 写在字面量上 | 曾经「存原文、使用处再 `_()`」，但 `_()` 包运行期变量 gettext 提取不到，等于白调。现在四个串都是字面量，可被提取 |

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

BLE 链路已在 **Kindle Scribe、Paperwhite 12 代、Kindle(2024, Basic 5)** 三台上
实测可用。经典蓝牙那套（`classic` 分支）只在 Scribe 上测过。

共同点（`kindle-hid-passthrough --diagnostics` 实测，这个子命令只读，排错先跑它）：

| 项 | 值 |
| --- | --- |
| 传输 | `file:/dev/stpbt`，`chip backend: MtkChip` |
| `/dev/stpbt` | `crw-rw---- root bluetoot 192,0` |
| `/dev/uhid` | 存在；`/sys/bus/hid` 存在 |
| 已加载模块 | `wmt_cdev_bt`、`wmt_drv`（联发科 CONSYS，**不是** Linux BT 子系统） |

> **内核版本因机型而异**，`4.9.77-lab126` 与 `5.15.41-lab126` 都见过。任何以内核号
> 为前提的判断都要在目标机上用 `uname -r` 自己确认，别照抄 khp README 里的数字，
> 也别照抄这里的。

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

### 守护进程：安装与配置

目录结构、剪裁范围、`config.ini` 模板与「迁移时必须自己处理的三件事」全部写在
**README 的安装一节**，这里不重复。下面只记安装过程中查证过、README 放不下的东西。

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

**`/var/log/hid_passthrough.log` 是追加的，多次运行混在一起。** `grep … | tail -N`
拿到的可能是上一次运行的行 —— **看时间戳**，别把旧 run 当成当前状态。
（改配置后验证效果时最容易在这里骗自己。）

排错顺序：`tail -30 /var/log/hid_passthrough.log` → `ps aux | grep ld-linux-armhf`
→ `--diagnostics`。注意 `--diagnostics` **不打** `Config base path`，而且它那段
`===== Daemon log tail =====` 是历史日志，别拿来当当前状态读。

### 为什么 `[media_remote] enabled` 必须显式写成 `false`

这是「用手机音量键翻页」——把 Kindle 伪装成蓝牙音箱，手机连上来按音量键翻页。
本插件不用它，而**开着它会让 Kindle 对外可被发现、可被连接**。

二进制里 `media_remote_enabled` 出现在 `ClassicMixin._run_classic_handler` →
`_is_classic_allowed` → `adopt` / `"[Classic] Rejecting … (not allowed)"` 这条链上，
也出现在 `_has_devices` 的判断里。**实测 `false` 之后这三行全部消失**
（对照两次运行的时间戳）：

```
# enabled = true
[Media] Remote ready (A2DP sink + AVRCP target)
[Classic] HID Host ready (PSM 0x0011, 0x0013)
[Classic] Enabling Page Scan...          ← 对外可被发现
Serving devices (Classic: 0, BLE: 1)

# enabled = false
Devices: 0 Classic, 1 BLE
Serving devices (Classic: 0, BLE: 1)     ← 只剩这两行，BLE 不受影响
```

注意 Classic 设备数是 0 时它**照样**开 page scan —— 也就是说这扇门跟你有没有
配 Classic 设备无关，只跟这个开关有关。

### 两条正常出现的 WARNING

**`no bundled uinput.ko for this Kindle; HID passthrough is unaffected`**
（连带 4 行 `model` / `codename` / `kernel` / `searched` 的诊断信息）——
它找的是 **uinput**，不是 uhid，用途是给 button-mapper 之类外部工具注入按键，
日志自己也写了 *"only needed to inject key events for external tools"* 和
*"HID passthrough is unaffected"*。我们剪裁时删掉了 `modules/`，且本来也不用
button-mapper，所以这条**必然出现且可以忽略**。

**`bumble.gatt_client: !!! received notification with no subscriber`** ——
手柄在 khp 订阅之前就发了一份 input report。看时间戳能确认这是个启动竞态：

```
30,592  [BLE] Restoring bonding...
30,635  !!! received notification with no subscriber   ← 此时还没订阅
31,197  [BLE] Subscribed to report 3
```

约 0.6 秒的窗口，丢掉的是这期间的按键。**如果守护进程启动的那一两秒里你正好
按着键，那次按下会丢** —— 除此之外无影响。

### 实测数值

| 项 | 实测值 | 出处 |
| --- | --- | --- |
| 常驻内存 | **Pss 32.0 MB / RSS 32.2 MB**，三次测量 32.0/32.2/32.3，稳定无泄漏 | 见下「内存占用与 OOM 顺序」 |
| 轴量纲 | **8 位有符号，中心 0，极值 ±127** | 原始字节，见下 |
| 按键码（**声明**） | 304 305 307 308 310 311 312 313 314 315 317 318 | `B: KEY` 位图解码 |
| 按键码（**实发**） | 304 305 307 308 310 **312** | 逐个实按 |
| 方向键 | **不存在**（物理上没有十字键） | 只按方向键时收不到 `code=16/17` |

「Bumble 太重」这个判断被 32 MB 推翻了 —— 和当年「菜单卡顿」量出
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

### 内存占用与 OOM 顺序：结论是不优化

**结论先写：什么都不做。** 下面是依据，免得「khp 是不是太重」这个念头再冒
出来时把整轮重新量一遍。

#### 怎么量

进程在 `ps` 里叫 `ld-linux-armhf.`（自带加载器，内核只留 15 字符），
**按进程名搜不到**，必须按命令行里的路径片段找 —— 和 `isDaemonRunning`
用的是同一个依据：

```sh
p=$(pgrep -f khp/dist/main.bin)

# RSS
awk '/^VmRSS/{print $2" kB"}' /proc/$p/status

# Pss（真正独占，共享库按比例摊）。本机没有 smaps_rollup，自己汇总
awk '/^Pss:/{s+=$2} END{printf "Pss=%d kB (%.1f MB)\n", s, s/1024}' /proc/$p/smaps

# 按映射拆，看钱花在哪
awk '/^[0-9a-f]+-[0-9a-f]+ /{n=(NF>=6?$6:"[anon]")} /^Pss:/{s[n]+=$2} \
     END{for(k in s) printf "%8d kB  %s\n", s[k], k}' /proc/$p/smaps | sort -rn | head -15
```

> `/proc/PID/smaps_rollup` 在这台机器上**不存在**，但 `/proc/PID/smaps`
> 存在。所以 Pss 拿得到，只是没有汇总快捷方式。别因为 rollup 缺失就断定
> 内核关了 `CONFIG_PROC_PAGE_MONITOR` —— 那是错的，我错过一次。

#### 成分（Pss 32812 kB 实测）

| 类别 | Pss | 性质 |
| --- | --- | --- |
| `[anon]` 14536 + `[heap]` 2992 | **17.1 MB** | Python 堆：对象、字典、bytecode。**真正占住**，本机无交换分区 |
| `main.bin` 9824 + `libpython3.11.so` 3076 + `libc.so.6` 976 + 零碎 | **14.4 MB** | 文件页，干净可回收。内存紧张时内核直接丢掉，从 `/mnt/us` 重读 |
| `[stack]` 100 + 尾部 | ~0.7 MB | |

**压力下的真实成本是 17 MB，不是 32 MB。** 而这 17 MB 全是 Python 运行时
数据 —— 恰好是 Bumble 调不动的部分。

#### 为什么 Bumble 调优不值得

| 手段 | 预期 | 为什么不做 |
| --- | --- | --- |
| Bumble 自身参数 | ~0 | 纯 Python 协议栈，内存是对象和已导入模块，没有 MB 级的缓冲区旋钮 |
| `MALLOC_ARENA_MAX=1` | **< 1 MB** | 只作用于 glibc arena，而 `[heap]` 仅 2.9 MB；大头 `[anon]` 是 pymalloc 自己 mmap 的，管不到。**我一度估成 1–3 MB，是错的** |
| `PYTHONOPTIMIZE=2` | 1–2 MB | 要重新打包 |
| 裁 `cryptography` 后端 | 5–10 MB | 要重新打包，且 SMP 依赖它，**极易搞坏 BLE 配对** |
| 不用 Python | 大头 | 不可行，理由见本节前面「为什么必须靠外部守护进程」 |

#### OOM：khp 排在 KOReader 之后，不需要保护

`free -m` 实测 `available 543 / total 970 MB`（56% 可用），**没有内存压力**。

`oom_score` 是 501，比按占用推算的 30–40 高一个数量级。我据此猜「`oom_score_adj`
被设成了大正数，khp 会优先被杀」—— **猜错了**。实测 `adj = 470`，而 470 是这台
机器上「普通应用」的环境默认值，khp 只是继承了父进程的值：

```
647  658  fastmetrics      ← Amazon 后台守护进程，被刻意设成「优先牺牲」档
647  653  appmgrd
647  652  contentpackd
647  651  dpmd / demd
649       dynconfig
470  588  java             ← Amazon 框架
470  516  reader.lua       ← KOReader 自己
470  501  ld-linux-armhf.  ← khp，第 9 位
470  471  koreader.sh / dropbear / sh
```

复现：

```sh
for d in /proc/[0-9]*; do
    [ -r $d/oom_score_adj ] && echo "$(cat $d/oom_score_adj)  $(cat $d/oom_score)  $(cat $d/comm)"
done 2>/dev/null | sort -rn | head -20
```

**所以「往 `/proc/<pid>/oom_score_adj` 写个小值来保护 khp」这个改动刻意不做。**
OOM killer 要轮到 khp，前面 6 个 Amazon 守护进程、java 框架（588）和 KOReader
本身（516）都已经死了 —— 翻页功能已经不存在，救 khp 没有任何意义。

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
ABS_MT_POSITION_X/Y（53/54），位图里没有。所以它被判为手柄，
`openDevice` 原样可用 —— **设备名是中文不影响**，分类只看能力位，不看名字。

### 已在真机验证

- FBInk 分类命中 `JOYSTICK`，节点出现在 `scanJoystickDevices` 的结果里
- `Loaded config for /dev/input/event3` → `Opened device /dev/input/event3`
- 「已连接设备」列出手柄，显示 `display_name` 与电量百分比
- **摇杆翻页正常**（`GotoViewRel` 无日志，靠肉眼确认）—— 删掉模式切换、
  `parseInputDirection` 的 `EV_ABS` 改成单路之后**重新验过一次**
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
- **精简后的 `config.ini` 与剪裁后的 `khp/` 一次跑通**：`searched:` 三条路径
  全在 `khp/` 下（base path 正确）、`Device: … (ble)`（`devices.conf` 生效、
  删 `[protocol]` 无害）、`[Media]` 与 `Page Scan` 缺席（`media_remote=false` 生效）、
  完整 BLE HID 链路 `Bonding restored` → `Found HID service` →
  `Created UHID device (rd_size=154)` → `Subscribed to report 3` →
  `receiving HID reports` → `battery: 100%`

**功能验证到此完整**，验证方法一节的菜单表每一项都点过。

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

上游源码印证了这个判断：`api_server.py` 的 `/stop` **只停 HID 层、留着 API
server**（好让下次 `/start` 快），所以它的插件必须区分三态。我们 `pkill` 整个
进程，就只有「在 / 不在」。**那个状态机是「用 API 停」的产物，不是守护进程的
固有性质。**

### 分界线：信号管控制，API 只管无其他来源的只读数据

上面那条**不是**「永不碰 API」。分界是：

| 用途 | 走哪条 | 理由 |
| --- | --- | --- |
| 起停守护进程 | **信号**（`pgrep` / `pkill`） | 只有两态，有更简单的替代 |
| 手柄电量 | **API**（`/status`） | **没有别的来源**：evdev 不带电量，`/sys/class/power_supply/` 里也没有 hid 电量节点（实测只有 Kindle 自己的 `bd71827_bat` 等三个），详见 §13 |

判据是「有没有更简单的替代」，不是「API 本身脏」。

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
- 重连**全自动**，不需要手动「重新加载设备」：`onEvdevInputInsert` 接住
  uevent，等 `RECONNECT_SETTLE_DELAY` 后 `Opened device`。

### 没有延时回查：两个方向本来就已经有反馈

曾经有个 `_daemonCheck`：点击后 `scheduleIn(6, …)`（停止是 1s）再查一次状态并
弹「守护进程已启动 / 已停止」。**整段删掉了**，因为它在造第二个喇叭：

| 动作 | 已经存在的反馈 |
| --- | --- |
| 起 | 节点出现 → `onEvdevInputInsert` → `_reconnect` 弹**「手柄已连接」** |
| 停 | 节点**同一秒**消失，手柄当场失效 —— 这就是「停了」对用户的全部含义 |

而它带来的是一个真 bug：停止的回查排在 **+1s**，此时进程往往还在退出中
（异常态下要 10s，见下），`isDaemonRunning()` 仍为真 → 弹出**「守护进程已启动」**
→ 用户以为没停掉，再点一次。实测日志里每次停止都被点了两遍。

那 10s 是 Bumble 的 HCI 命令超时：芯片没载固件时
`HCI_LE_CREATE_CONNECTION_CANCEL_COMMAND` 发不出去，必须等超时到期。三次实测
间隔 10.05 / 10.06 / 10.09 秒，与第二次点击无关（第二次点击落在 8s，早于超时）。

**把固定秒数改大是错的**：健康时停止是同一秒生效，等 12s 纯属白等；异常时又可能
不够。改成轮询也不对 —— 那是在给已有的反馈再包一层。

**不主动 `reloadDevice()`。** 节点是手柄连上时才出现的，而那条路已经由
`onEvdevInputInsert` 兜住（§2，已实测）。

### 上游那套等待为什么不能抄

khp 插件的 `_waitForState`（`koreader-plugin/hidpassthrough.koplugin/main.lua:870`）：

```lua
for i = 1, timeout do
    ffiutil.sleep(1)                -- 阻塞整个 UI 线程
    local state = self:getState()   -- 每 tick 一个 HTTP 请求
    if state == target then return true end
end
```

`START_TIMEOUT = 15`，e-ink 上最坏**冻结 15 秒**，期间翻页刷新全停。它的 `start()`
有 45 行、三态机、两处嵌套 `_waitForState`，那些复杂度全来自 `/stop` 只停 HID 层
（§12 开头）。

### 菜单勾选会有短暂残留，这是刻意接受的

停止之后若立刻重开菜单，`checked_func`（查的是进程存活性）可能仍显示勾选，直到
进程真的退出。**诚实的「立刻 uncheck」做不到**，两条路都被否过：

| 做法 | 为什么否 |
| --- | --- |
| 乐观状态（点了就记成关） | 反方向说谎：守护进程被崩溃 / OOM / 外部 kill 掉时，勾选会一直亮着 |
| 点击后 `updateItems()` 重绘 | 时序不对 —— 同一个 tick 里 `os.execute` 刚返回，SIGTERM 可能还没送达，`isDaemonRunning()` 仍为真，重绘出来还是勾选 |

而且这个残留窗口只在**异常态**（WiFi 关着起守护进程、芯片没载固件）才有 10s 量级；
健康时进程当场就退了。装了 §14 的 WiFi 守卫之后基本见不到。

### `isDaemonRunning` 刻意不带缓存

`checked_func` 每次菜单重绘都会调它，所以最初照主分支给蓝牙状态加缓存的做法，
也加了 2 秒缓存。后来删掉了：**代价与收益不成比例**。

- 收益：省掉一次 `pgrep` 的 fork，约几毫秒。
- 代价：两个状态字段（`_daemon_cached` / `_daemon_time`）、一个常量、
  以及两处手动失效（起停之后必须 `self._daemon_time = nil`，漏一处就会显示
  过期状态最多 2 秒）。

而 e-ink 菜单重绘本身就是 100ms 量级，几毫秒的 fork 是噪声 —— 而且这个开销
**从没量过**。主分支那个缓存包的是 `lipc` 加 `io.popen` 回退，量级不同，
不能直接类比过来。

`self.path` 在 `init` 里固定，所以 `_daemon_binary` 和 `_daemon_pattern`
（含 `shell_escape`）都在那里算一次，不用每次重新拼。

## §13 手柄电量：为什么走 HTTP、为什么用 wget

「已连接设备」里显示的 `98%` 来自 khp 的 API。三条路只有一条通：

| 路径 | 结论 |
| --- | --- |
| evdev | **不通**。输入事件里没有电量信息 |
| 内核 HID 电量（`/sys/class/power_supply/hid-*-battery`） | **不通**。实测该目录只有 `bd71827_ac`(Mains)、`bd71827_bat`(Kindle 自己的电池)、`max20342_moisture`(USB_WET)，**没有 hid 电量节点** |
| khp 的 `/status` | **通**，见下 |

数据链路：手柄的 GATT Battery Service（0x180F）→ khp 的 `ble.py` 订阅通知、
不通知的设备每 `BATTERY_POLL_INTERVAL = 300` 秒主动读一次 → `host.py` 的
`battery_level` → HTTP `/status`。所以**值最多滞后 5 分钟**，菜单场景够用。

### 用 `input_paths` 匹配，不用 MAC

`/status` 的实测输出（`3.15.2-202ef78`）：

```json
"connections": [{
  "address": "AA:BB:CC:DD:EE:FF",
  "input_paths": ["/dev/input/event2"],
  "battery_level": 98,
  "battery_updated": 1788515691.4
}]
```

`input_paths` 直接给出 evdev 节点，所以拿 `opened_path` 匹配即可 —— 那本来就是
本插件唯一认的设备身份（§9）。khp 自己的插件按 `address` 匹配，我们不需要多引入
一个身份维度。

> 顺带：`name` 是 `黑鲨双翼手柄L-XXXX`，尾巴 `XXXX` 来自 MAC 的后两字节。这就是
> `display_name` 要存在的原因（见开头字段表）。

### 用 `wget` 而不是 `socket.http`

**`koreader/common/socket/http.lua:122-130` 有个坑**：

```lua
function _M.open(host, port, create)
    local c = socket.try(create())
    ...
    h.try(c:settimeout(_M.TIMEOUT))   ← 覆盖掉 create 里设的超时
```

`create()` 里 `settimeout()` 会被随后的 `settimeout(_M.TIMEOUT)` 冲掉。所以
**khp 插件里那个 `create = function() … s:settimeout(…) end` 块是死代码**，真正
生效的是模块全局 `http.TIMEOUT`。而改模块全局有风险：中途抛异常没恢复的话，
别的 KOReader HTTP 调用会继承这个短超时。

`wget -qO- -T 2` 没有这个问题：超时可靠、无全局状态、少一层依赖，而且本文件
已经在 shell out（`pgrep` / `pkill` / `setsid` / `rm`），是同一个惯用法。

### 三个刻意不做

| 不做 | 理由 |
| --- | --- |
| 轮询 + 定时器 + 失败闩锁 | khp 插件要在状态栏常驻显示所以必须轮询（`BATTERY_POLL_INTERVAL` / `_startBatteryPoll` / `battery_unavailable`）。我们只在菜单里显示，**按需读**就够，那三样全省掉 |
| 显示 `battery_updated` 新鲜度 | 值本来就最多滞后 5 分钟，菜单场景无意义 |
| 为未配置的设备也读电量 | 得按 MAC 逐个查、多次 HTTP，而只有在用那台值得关心 |

### pcall 罩住全部可失败操作，不只罩 JSON 解析

第一版把 `popen` + `read` 留在 `readBatteryLevel` 里，只把解析放进 `pcall`。
结果是 **`popen` 那半裸着** —— `io.popen` 返回 nil 时后面的 `pipe:read` 会直接
崩掉菜单，所以又得补一行 `if not pipe then return nil end` 守卫。

现在的形状：popen + read + close + decode + 匹配全都在 `readBatteryLevel` 内部那个
被 `pcall` 包住的闭包里，函数本体只剩 `pgrep` 门禁。一个边界罩住全部，
于是 nil 守卫、`body or ""`、`data.connections or {}` 这些补丁全都不需要了
（少 7 行）。

**`or {}` 那类守卫删掉反而更好**：API 换结构时会走进 `logger.dbg` 留下线索，
加了 `or {}` 只会静默返回 nil，问题被藏起来。

### 两个必须保留的判断

**`isDaemonRunning()` 门禁。** `readBatteryLevel` 第一件事是 `pgrep`，守护进程
不在就直接返回，连 `wget` 都不 fork。这是最常见的情形，也避免了在 #88 那种射频
卡死状态下白等 2 秒。

**`type(conn.battery_level) == "number"` 判断不能删。** 手柄没有 Battery Service
时该字段是 JSON `null`，而 rapidjson 把 `null` 解成 `rapidjson.null`
（**userdata，不是 nil**）。少了这个判断，`string.format("%d", …)` 会直接报错。

### 已知副作用

KOReader 的**菜单搜索**也会调 `sub_item_table_func`（`touchmenu.lua:1005`），
所以搜索菜单时会多 fork 一次 `wget`。有 `pgrep` 门禁 + 2 秒超时，最坏 2 秒卡顿。
这和 `scanJoystickDevices` 被菜单搜索触发一次 FBInk 扫描是同一类既有行为，
不是本功能引入的。

### 只用 `/status`，其余端点不碰

`127.0.0.1:8321`，全为 GET。完整端点表见上游 `kindle_hid_passthrough/api_server.py`
的 `match path:`，不在这里抄一份。

本插件只调 `/status`。另两个偶尔手工排错有用：

- `/health` —— 只回 `{"ok":true}`，比 `/status` 轻
- `/logs?lines=200` —— 取日志尾部

> `/autostart?enable=1` 能免去手写 upstart 脚本，但**暂不建议开**：自启意味着
> 开机就攥着射频，于是每次开 WiFi 都得先停它（§12）。

### ⚠️ 守护进程运行期间不要开关 WiFi —— 会把射频卡死到重启

**这不是本插件的缺陷，也修不了。** 上游 issue
[#88](https://github.com/zampierilucas/kindle-hid-passthrough/issues/88)
（截至 2026-09 仍 open），作者 `zampierilucas` 本人的诊断：

> wifi and bluetooth share the same combo chip on the kindle, and this project
> takes the bt half over completely to bypass the stock stack. it doesnt
> coexist with wifi the way the stock driver expects, so toggling wifi off and
> on tries to cycle the shared chip while we're still holding it, and **it
> wedges til a reboot**.

机制：PW6 的 WiFi 与蓝牙是同一颗组合芯片（`/dev/stpbt` 是 MediaTek 的 BT
字符设备，见 §11「目标机器」）。khp 绕过 Amazon 的 Bluedroid，把 BT 那半
**完全独占**。WiFi 开关会尝试 cycle 整颗芯片，而 khp 还攥着它。

作者已明确表示不会修，理由是修法要让守护进程监听 WiFi 状态并动态重新初始化
BT 芯片，而那段代码是整个项目最脆弱的部分，为一个边缘场景改它会危及所有人的
重连。**所以这是长期约束，不要等上游。**

**症状**：WiFi 搜不到网络、连不上。**恢复**：只能重启 Kindle —— 一旦卡住，
停守护进程也救不回来。

**冲突只发生在 WiFi 状态转换的瞬间** —— khp 攥着芯片时去 cycle 它才会炸。
**稳定共存是正常的**（证据见下）。所以只需记住一条：

> **先把 WiFi 连好，再起守护进程；读书期间不动 WiFi。**

真要中途开关 WiFi，就先在菜单里关掉「蓝牙守护进程」。**没有「已停止」这类回查
提示**（那套延时回查整段删掉了，理由见 §12）；判据是手柄当场失效，以及重开菜单时
勾选已消失。

#### 「稳定共存没问题」的三条证据

结论不是推测，也不用自己搭测试：

1. **#88 报告人自己就是这么用的。** 原话：「Kindle-hid-passthrough **works well
   on my device**. It's just that every time after I turn off wifi while
   bluetooth is on…」—— 他用 AI 翻译插件，需要反复开关 WiFi，坏的只是**切换那
   一下**。他还明确说规避要在 "enabling **or** disabling wifi" 之前关蓝牙：
   **两个方向都算**，不只是关。
2. **khp 自己的装机流程就要求 WiFi 开着。** 配对与调试步骤依赖 SSH 登录设备。
   若两者互斥，上游文档根本写不出来。README 里唯一记载的冲突是**与 Amazon 自己
   的蓝牙栈**（占用期间不能听有声书），**不是 WiFi**。
3. **驱动层机制说得通**（下一节）。

#### 机制：`wmt_drv` 对共享芯片做引用计数

从上游 #179 与 #254 的内核信息拼出来的模块关系：

```
wmt_drv（MediaTek Wireless Management Task，管这颗组合芯片）
 ├─ wmt_cdev_bt      → /dev/stpbt   ← khp 抢的是这一半
 └─ wmt_chrdev_wifi  → wlan0
```

`wmt_drv` 按引用计数决定芯片供电。**稳定态下 WiFi 与 BT 各持一份，互不干扰**；
炸只发生在「一方释放、而另一方的持有者不被 Amazon 的栈感知」的瞬间。

#179 给了直接证据：

> closing `/dev/stpbt` **drops the power to the MTK chip** via the
> `wmt_cdev_bt` module, wiping its firmware

即**开关**会动整颗芯片，而**保持不动不会**。这同时解释了两个现象：

| 现象 | 原因 |
| --- | --- |
| Scribe 上关 WiFi 会连带关掉经典蓝牙 | 两半都归 Amazon，它知道 BT 也挂在这颗芯片上，于是有序地一起关。**这是正确行为，不是 bug** |
| PW6 + khp 上 cycle WiFi 会卡死 | khp 攥着 BT 那半，Amazon 的栈不知道还有人持有，照旧去 cycle → 引用计数与真实持有者不一致 |

两者是同一枚硬币，差别**只在于谁拥有芯片**。

#### 刻意不做：用 KOReader 的网络事件自动避让

KOReader 确实提供了前置钩子，`manager.lua:73` 的注释明确说是给插件用的：

```
manager.lua:74   broadcastEvent(Event:new("NetworkConnecting"))
manager.lua:77   return self:turnOnWifi(...)            ← 实际动作在广播之后
manager.lua:413  broadcastEvent(Event:new("NetworkDisconnecting"))
manager.lua:425  self:turnOffWifi(complete_callback)    ← 同样在广播之后
```

所以技术上可以在这两个事件里先停守护进程，约 15 行。**不做**，三个理由：

1. **没有静默切换需要防。** `wifi_enable_action` 默认走 `promptWifiOn()`
   （`manager.lua:605-616`），KOReader 开 WiFi 前会弹窗；`auto_restore_wifi`
   与 `auto_disable_wifi` 默认关闭。**每次 WiFi 切换都是用户的有意识动作**，
   所以不存在「翻页神秘失灵」的场景。
2. **它覆盖不了 Kindle 原生界面。** 从 Amazon 自己的设置里关 WiFi，KOReader
   收不到任何事件。而**部分机制防护会侵蚀那条真正有效的纪律** —— 装了之后容易
   误以为「随便关 WiFi 没事了」，然后在原生界面上踩一次。
3. **工作流方案是 0 行且覆盖全部路径。** 上面那一句话就够了。

真正该修的地方在 khp 里（让守护进程监听 WiFi 状态并动态重新初始化芯片），
上游作者已明确拒绝，理由是那段是项目最脆弱的代码。**不要等上游。**

> 唯一没有证据覆盖的是**睡眠唤醒**：没有 issue 提到，机制上也推不出来（取决于
> Amazon 的 suspend/resume 会不会重新 associate WiFi）。不必专门测 —— 正常用
> 几天没再卡死就是过了。

#### KOReader 那两个自动开关 WiFi 的设置：默认就是关的

有两个设置会在你不碰任何东西的时候 cycle 射频。**但它们默认关闭，绝大多数情况
下不需要动**——这里记下来只是为了排除嫌疑，别把它们当成本问题的原因。

| KOReader 设置项 | 内部键 | 为什么危险 |
|---|---|---|
| Restore Wi-Fi connection on resume | `auto_restore_wifi` | 帮助文字原文是「automatically and **silently** re-connect to Wi-Fi on startup or on resume」。带手柄看书时唤醒极其频繁，等于随机时刻 cycle 射频（`manager.lua:984-993`） |
| Disable Wi-Fi connection when inactive | `auto_disable_wifi` | 空闲一段时间后自动关 WiFi（`networklistener.lua:85-185`）。KOReader 自己的帮助文字就说这项在原生 Kindle 上「unlikely to function properly」 |

**菜单路径**：设置齿轮 → 网络 → 第 3、4 项，紧跟在「Wi-Fi 连接」和「代理」
之后（`reader_menu_order.lua:132-137`）。两项在 Kindle 上一定显示，因为两个
gate 都过：`getNetworkInterfaceName()` 在 Kindle 上硬编码返回 `"wlan0"`
（`device/kindle/device.lua:449`），`hasWifiRestore = yes`（同文件 L394）。

查当前值：

```sh
grep -E 'auto_(restore|disable)_wifi' /mnt/us/koreader/settings.reader.lua
```

**没有输出是正常的，且意味着两项都是关的。** `defaults.lua` 里没有这两个键，
代码用 `flipNilOrFalse` + `isTrue`，默认 nil 即关；KOReader 只把改过的设置
落盘。所以「grep 不到」不是没找对地方，是压根没开过。

#### 顺带排除的一个误判方向

这与 §11 里那个 `media_remote=false` 无关。那一项关的是 khp 自己的经典蓝牙
页面扫描，属于 khp 内部行为；本条冲突发生在**芯片层**，khp 只要在跑就成立，
和 khp 的任何配置项都无关。

---

## §14 WiFi 守卫：全仓库唯一一处 monkey patch

守护进程运行时开 WiFi 会把射频卡死到重启（§12）。`installWifiGuard` 在 `init`
里替换 `NetworkMgr.turnOnWifi`，守护进程在跑就弹提示并拒绝。

**这是本仓库唯一一处 monkey patch。** 其余所有对接都走文档化扩展点
（`registerEventAdjustHook`、`registerToMainMenu`、`onEvdevInputInsert`、
`onDispatcherRegisterActions`）。这一处不同：`turnOnWifi` 是 KOReader 内部函数，
**没有任何兼容性承诺**。所以下面两条依赖必须写下来，KOReader 升级后照着核对。

### 依赖一：事件钩子拦不住，只能替换函数

`NetworkConnecting` / `NetworkDisconnecting` 是**通知，不是否决权**：

```
manager.lua:74    broadcastEvent(Event:new("NetworkConnecting"))
manager.lua:77    return self:turnOnWifi(wifi_cb, interactive)   ← 无条件执行
manager.lua:413   broadcastEvent(Event:new("NetworkDisconnecting"))
manager.lua:425   self:turnOffWifi(complete_callback)            ← 同样
```

处理器返回 true 只停止继续传播，拦不住后面那行。所以只能替换函数本身。

### 依赖二：必须返回 `false`，否则 WiFi 会被永久锁死

```lua
manager.lua:67   function NetworkMgr:requestToTurnOnWifi(...)
manager.lua:68       if self.pending_connection then return EBUSY end
manager.lua:75       self.pending_connection = true          ← 先置位
manager.lua:77       return self:turnOnWifi(...)             ← 才调下去

manager.lua:373  local status = self:requestToTurnOnWifi(...)
manager.lua:375  if status == false then
manager.lua:377      self:_abortWifiConnection()             ← 清 pending_connection
```

**拦截时返回 nil 会让 `pending_connection` 永久停在 true** —— 之后哪怕关掉守护
进程，WiFi 也再开不起来，除非重启 KOReader。返回 `false` 走的是 KOReader 自己的
「连接失败」契约，`_abortWifiConnection`（`manager.lua:44-63`）会把状态清干净。

升级 KOReader 后要核对的就是这两处行号对应的行为还在不在。

**已在真机验证**（2026-09-13，KOReader 日志）：

```
22:45:12  khp daemon start requested
22:45:28  WARN  NetworkMgr:enableWifi: Connection failed!   ← 第 1 次拦截
22:45:38  WARN  NetworkMgr:enableWifi: Connection failed!   ← 第 2 次仍是「拦截」
22:45:47  khp daemon stop requested
22:46:12  Wi-Fi successfully restored (after 6.25 seconds)!
```

**第二行 WARN 是决定性证据。** 若 `pending_connection` 没被清掉，第二次尝试会
落进 EBUSY 分支打出 `A previous connection attempt is still ongoing!`
（`manager.lua:381`），而不是再一次 `Connection failed!`（`manager.lua:376`）。
它打的是后者，说明 `_abortWifiConnection` 在第一次拦截后确实清干净了。最后一行
则证明守卫解除后 WiFi 能正常连上。

升级 KOReader 后重跑这个序列即可回归：起守护进程 → 连开两次 WiFi → 停守护进程
→ 开 WiFi。日志里出现 EBUSY 那句就说明契约变了。

### 为什么打在 `turnOnWifi` 而不是别处

它是三条路径的共同汇聚点：

```
菜单 / 手势   → toggleWifiOn(433)      → enableWifi(358) → requestToTurnOnWifi(67) ┐
插件自动联网  → beforeWifiAction(605)  → promptWifiOn(460) → …                     ├→ turnOnWifi
```

打在 `toggleWifiOn` 会漏掉自动联网那条。

### 第二处：`restoreWifiAsync`（`auto_restore_wifi` 的路径）

**`restoreWifiAsync` 绕开 `turnOnWifi`**，所以第一处补丁拦不到它。它有两个调用点：

| 调用点 | 时机 | 能否补丁 |
| --- | --- | --- |
| `networklistener.lua:224` | **每次唤醒**（`onResume`） | **能** —— 这是真正危险的那条 |
| `manager.lua:159` | KOReader 启动时（模块加载期） | **不能** —— 早于插件加载 |

唤醒那条才是重点：Kindle 一天唤醒几十次，`auto_restore_wifi` 开着 + 守护进程在跑
= 随机时刻静默卡死射频。**这是「本机没有静默切换路径」那个结论的唯一例外。**

> 曾经写过「`restoreWifiAsync` 只有 `manager.lua:159` 一个调用点，补丁没有意义」
> —— **那是错的**，当时只 grep 了 `manager.lua`，漏掉了 `networklistener.lua`。

它是 fire-and-forget，**没有返回值契约**，所以拦截时不调用原函数即可；返回 `false`
也无害（与 `turnOnWifi` 共用同一个包装）。

### 两条仍然覆盖不到的路径

| 路径 | 说明 |
| --- | --- |
| **Kindle 原生设置界面** | KOReader 完全不知情。这同时是**逃生出口** —— 万一守护进程卡死关不掉，还能从原生界面开 WiFi |
| **KOReader 启动时的那次 `restoreWifiAsync`** | `manager.lua:159` 在模块加载期执行，早于插件。而守护进程用 `setsid` 脱离了进程组，能跨 KOReader 重启存活，所以这个组合真实存在。对策只能是保持 `auto_restore_wifi` 关闭（默认就是关的，见 §12） |

### 副作用：作用域是全局的

补丁替换的是全局单例上的方法，**整个 KOReader 会话都受影响** —— OPDS、进度同步、
词典下载这些要联网的功能都会撞上守卫。这是设计意图（我们就是要拦所有路径），
但不要以为它只管菜单里手动点的那一次。

不需要在 `onExit` 里卸载：守卫靠 `_current_active_controller` 判断，插件退出时
该变量置 nil，补丁自动失效。补丁只活在进程里，重启 KOReader 即恢复。

### `type(original) ~= "function"` 的防御不能删

KOReader 要是改名或删掉 `turnOnWifi`，没有这一判就会把 `nil` 当函数存下来，
之后每次开 WiFi 都崩。有了它，最坏只是少一个守卫并留一行 warn。

---

## §16 多手柄配置：按名字解析，而不是按节点路径

`bluetooth.lua` 从单份扁平表改成了**配置数组**，生效的那份由 `resolveProfile`
按「哪个手柄现在在线」决定。

### khp 本身就支持多设备

这是设计的前提，源码证据在 `host.py`：

```python
def _parse_devices(self):          # devices.conf 里的每一行
    ... self.classic_devices.append / self.ble_devices.append
    log.info(f"Devices: {len(self.classic_devices)} Classic, {len(self.ble_devices)} BLE")

async def _serve(self):            # 按协议起 handler，不是按设备
    if self.ble_devices:
        tasks.append(asyncio.create_task(self._run_ble_handler(), ...))
```

`self.sessions` 按地址索引，`_create_uhid_device` / `_destroy_uhid_node(address)`
表明**每个会话各有一个 uhid 节点**。所以两个手柄都开着时，khp 会各连各的，系统里
出现两个 `eventN`。配第二个手柄只需再跑一次 `--pair`，`devices.conf` 会累积。

### 为什么改成按名字匹配

原来靠 `device_path` 认设备。两个手柄共用一台机器时这行不通 —— 节点号既会漂移，
又无法区分谁是谁。而 `scanJoystickDevices` 本来就能拿到设备名（khp 用手柄的蓝牙
名字命名 uhid 节点，这个名字是稳定的）。

于是 `match_name`（Lua 模式）取代了 `device_path`，**顺带消灭了 `eventN` 漂移
这个长期痛点**：路径改为由扫描结果给出。

> 早先否决过这个做法，理由是「要维护名字模式表，而 `device_path` 已经够用」。
> **那个前提在两个手柄之后不成立了**，所以否决翻案。原判断没错，是条件变了。

### 顺带简化掉的东西

`openDevice` 里的 `isControllerDevice(path)` 整段删了：路径现在只可能来自
`scanJoystickDevices`，而它只列已被 FBInk 判定为手柄的节点，再查一次是多余的。
`isDevicePath` 也随 `device_path` 一起删除。

### 三处不能省的判断

| 位置 | 为什么 |
| --- | --- |
| `resolveProfile` 里 `pcall(string.match, ...)` | `match_name` 是手写的模式串，落单的 `%` 会让 `:match` 抛错。不 pcall 住就是一个配置笔误崩掉整个插件 |
| `_reconnect` 的 `was_open` 判断 | `onEvdevInputInsert` 不再按路径过滤（节点号由解析决定），任何输入设备插入都会触发。没有这个判断，触屏之类的无关节点插入也会弹「手柄已连接」 |
| 覆盖值键名带 `match_name` 前缀 | 两个手柄的「反转方向」「摇杆模式」必须各存各的，否则换手柄会串味 |

### 冲突时的取舍：数组顺序优先

两个手柄都在线时按**数组顺序**取第一个匹配的，而不是按「哪个先连上」。理由是前者
由用户完全掌控且可预期；后者取决于开机顺序，同样的配置每次行为可能不同。

### 方案 B：两个手柄同时可用（未做）

当前实现同一时刻只用一个手柄。要让两个同时翻页，需要在此基础上：

1. `opened_path` / `opened_fd` 从单值改成表，按 fd 索引
2. `handleInputEvent` 按 `ev.fd` 查出对应的那份配置，而不是用单一的 `self.config`
3. **连翻抑制状态必须按设备分开** —— `_deflected_axes` 与 `_shared_triggered`
   现在是模块级共享的，两个手柄会互相干扰：A 推着杆没回中，B 就翻不了页

约 +40 行，而且改的是全项目最经过实测、出错代价最高的输入热路径。**刻意先不做**：
实际用法大概率是「这台机器现在用哪个手柄」，而不是两个同时翻页；真需要时在现有
结构上追加即可，不用推倒重来。

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

**每一个菜单项都要点一遍**，别只测主路径 —— 曾有一次崩溃是因为某个菜单项在五轮
测试里一次都没被点过：

| 菜单项 | 期待日志 | 另外确认 |
| --- | --- | --- |
| 蓝牙守护进程 → 开 | `khp daemon start requested` → 约 5s 后 `Input device inserted` → `Opened device` | 提示「正在启动守护进程…」，随后「手柄已连接」。**没有第二条就是没连上**（多半 WiFi 关着，见 §12） |
| 蓝牙守护进程 → 关 | `khp daemon stop requested` → 同一秒 `Input device removed` → `Closing device` | 手柄当场失效；`ko-input` 打出 `Closed input device with fd: N` |
| 已连接设备 | `Found input device: …` | 只列手柄；显示 `display_name` + 电量百分比 |
| 反转方向 | 设置文件出现 `invert_layout` | **重启后仍然反转** |
| 重新加载设备 | `Loaded config for` → `Closing device` → `Opened device` | — |

WiFi 守卫另测（§14）：起守护进程 → 连开两次 WiFi → 停守护进程 → 开 WiFi。
两次拦截都该打 `NetworkMgr:enableWifi: Connection failed!`，出现 EBUSY 那句即回归。

「另外确认」里那个**重启后**是配置拆分（§10）的关键验证点：覆盖值存在
`<settings>/bluetooth_controller.lua`，读取时若误用 `or` 而非判 `nil`，
显式的 `false` 就会被 `bluetooth.lua` 里的值顶掉 —— 表现是"关掉反转方向，
重启后又反转了"。这一项**只有重启才暴露**。

功能验证：摇杆推一下能翻页，**且触屏依然正常**（后者验证 fd 闸门 ——
触屏失灵说明 `opened_fd` 匹配错了，事件被误吃）。

## 3. 打开失败排错

| 日志 | 原因 |
| --- | --- |
| `FBInk input classifier is unavailable` / `Failed to load FBInk input classifier` | FBInk 输入库没加载。`scanJoystickDevices` 会返回空表，于是解析不出任何配置，**任何设备都打不开** |
| `Device … unavailable or not a supported controller` | 节点不存在，或 FBInk 不认它是 JOYSTICK/DPAD。先做"扫描"一步拿真实节点号 |
| `Failed to open … -> …` | 节点在但打不开，通常是权限或已被独占 |

「已连接设备」菜单列的是 `fbink_input_scan` 扫到的全部手柄节点，
所以配置里节点号写错时，仍可用它查出正确的节点号。
