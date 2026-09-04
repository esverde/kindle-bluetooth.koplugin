# 统一双链路（经典蓝牙 + BLE/khp）实施计划

> 执行方式：任务逐个做，每个任务末尾都有独立的真机验证步骤和提交命令。
> 步骤用 `- [ ]` 便于打勾。

**目标：** 把 `main`（经典蓝牙）与 `ble`（BLE/khp）合成一个分支，配置文件支持多份手柄配置，运行时按当前配置的链路类型决定走 Amazon 蓝牙栈还是 khp 守护进程，并让菜单只显示当前配置用得上的项。

**做法：** 先从 `e97a38b` 取回经典蓝牙那 100 行让两套代码共存，再把单份配置改成配置数组，最后把菜单改成每次打开重建、按 `link` 与 `supports_dpad` 分流。不引入驱动/策略抽象——全程只有两个分支，`if self.config.link == "classic"`。

> **不要用 `git merge main`。** 实测 `merge-base(main, ble) == main` 的 tip，`main` 在基点之后 0 个提交——它已经是 `ble` 的祖先，merge 会直接输出 `Already up to date.`，一行都不带回来。经典蓝牙代码不在「另一个分支」，而是在共同历史里被 `56ee51d`（BLE 分支改为消费 khp 产出的 evdev 节点）删掉了。所以这是**定向恢复**，不是合并。
>
> 反过来说，这也意味着 `ble` 那 20 个提交的精简**不可能被 merge 冲掉**：`main` 侧没有任何一行能跟它们竞争。§1 的「冲突面」一节因此不成立，恢复过程中不会有 git 冲突，全部是手工添加。

**技术栈：** Lua 5.1 / LuaJIT（KOReader 插件），LuaJIT FFI（FBInk `fbink_input`），Amazon lipc（`com.lab126.btfd`），kindle-hid-passthrough（Bumble → `/dev/uhid` → evdev）。

**规格：** 见本文 §0，来自用户 2026-09-04 的需求陈述。本仓库没有独立 spec 文档，规格与计划同文。

## 全局约束

- 目标机型与手柄：Kindle Scribe + Xbox 手柄（经典蓝牙）；Kindle PW6 + 黑鲨双翼手柄L（BLE，经 khp）。两台机器共用同一个插件目录副本。
- `bluetooth.lua` 是手写文件，插件**只读、永不改写**（`docs/README.md` §10）。菜单改动一律进 `<settings>/bluetooth_controller.lua`。
- 配置校验只有一处（`applyConfig`），全部字段必填，一项不过关就整份拒绝、运行态不动。热路径不做二次校验。
- 开发机（Windows）**没有 luajit**，本仓库也没有测试框架。每个任务的验证都在 Kindle 上跑，语法检查用设备自带的 `/mnt/us/koreader/luajit -bl`。这是对 TDD 默认流程的有意偏离，理由见 §5。
- `khp/` 目录被 gitignore（约 18.7M 三方二进制），二进制缺失是最可能的现场故障，相关代码必须先判存在。
- 提交信息沿用仓库既有风格：`<emoji> <type>(<scope>): <中文摘要>`。

---

## §0 规格

1. `main` 与 `ble` 两分支合并为一个分支。
2. `bluetooth.lua` 支持多份配置。
3. 配置声明链路类型：`classic` 走 Kindle 官方蓝牙栈，`ble` 走 khp 守护进程。
4. 没有摇杆/方向键模式切换能力的手柄，不显示（或灰显）「摇杆模式」菜单项。
5. `classic` 配置下菜单提供「蓝牙开关」；`ble` 配置下提供「蓝牙守护进程」开关。

## §1 现状：两分支到底差什么

基线：`main` = `e97a38b`（634 行），`ble` = `ae3d547`（539 行）。`git diff --stat main ble` = 5 文件、+724/−270。

### 只在 `e97a38b` 里存在（需要取回）

| 符号 | main 行号 | 作用 |
|---|---|---|
| `require("dispatcher")` | 3 | 手势可绑定「切换 Kindle 蓝牙」 |
| `STATE_CACHE_INTERVAL = 2` | 19 | 蓝牙状态查询节流，菜单 `checked_func` 会高频调用 |
| `btLipc()` | 314-317 | 取 `powerd.lipc_handle` |
| `getRealState()` | 319-333 | 先 lipc 快路径，失败退 `lipc-get-prop` shell |
| `getDisplayState()` | 335-342 | 带 2 秒缓存的读取 |
| `setBluetoothState(enable)` | 344-359 | 只走 shell：`set_int_property` 没有可靠返回值 |
| `onDispatcherRegisterActions()` | 361-368 | 注册手势动作 |
| `onToggleBluetooth()` | 370-373 | 手势入口 |
| `parseDpadInput(ev)` | 444-448 | 十字键（`EV_ABS` HAT）方向解析 |
| `joystickModeItem()` 闭包 | 528-540 | 「摇杆模式」两个单选项 |
| 「蓝牙开关」菜单项 | 544-552 | |
| 「摇杆模式」菜单项 | 584-593 | 已有 `enabled_func = supports_dpad` 灰显 |
| 配置字段 | `bluetooth.lua` | `use_analog_mode`、`supports_dpad`、`dpad_map` |

### ble 独有（需要保留）

| 符号 | ble 行号 | 作用 |
|---|---|---|
| `DAEMON_START_DELAY = 6` | 21 | 实测节点约 5s 后出现 |
| `_daemon_binary` / `_daemon_pattern` | 68-69 | `init` 里算一次，匹配完整路径 |
| `isDaemonRunning` / `startDaemon` / `stopDaemon` | 287-308 | pgrep / setsid / pkill |
| `_daemonCheck()` | 311-316 | 起停不同步，延时回查 |
| 「蓝牙守护进程」菜单项 | 444-465 | |
| `onExit` 多一行 unschedule | 531 | |

### ble 已做、main 没有的重构（合并时必须保留 ble 侧）

四轮 ponytail 精简共砍 95 行：删掉 `override` / `saveOverride` / `reloadDevice` 三个单调用点方法、类表上的空操作字段、`was_open`、`all_centered` 标志循环，以及大量单语句折行。**取回经典蓝牙代码时最大的风险就是从旧文件里连带抄回这些已删的东西**，任务 1 步骤 3 有明确的「不要抄」清单，步骤 7 有 grep 校验。

### 分支拓扑（实测，决定了恢复方式）

```
merge-base(main, ble) = e97a38b = main 的 tip
main 在基点之后：0 个提交
ble  在基点之后：20 个提交（含 4 轮 ponytail 精简，共砍 95 行）
```

`main` 是 `ble` 的祖先。两个后果：

1. **ble 的精简是安全的**，不存在被合并冲掉的可能——`main` 侧没有任何一行能与之竞争。
2. **不能用 merge 拿回经典蓝牙代码**。它是被 `56ee51d` 从共同历史里删掉的，`git merge main` 只会说 `Already up to date.`。唯一来源是 `git show e97a38b:main.lua`，得手工添加。

### 取回的代码是「老标准下审过的」

经典蓝牙那块在共同历史里经过 3 轮 ponytail（`23b8624`、`c3cf8c4`、`9b24f57`），不是没审过的代码。但 `ble` 后来那 4 轮引入了几条新规则，从没作用到这块上。恢复时必须顺手补上（任务 1 步骤 4）：

| 位置（`e97a38b:main.lua`） | 问题 | 处置 |
|---|---|---|
| `btLipc()` L314-317 | 4 行、单调用点（仅 `getRealState` L320） | 内联进 `getRealState`，与已删的 `override` / `saveOverride` / `reloadDevice` 同型，−4 行 |
| `setBluetoothState` L346-347 | `local val`、`local cmd` 各只用一次 | 合成一句 `os.execute(string.format(...))`，与已删的 `local command` 同型，−1 行 |
| 类表 L67 `_state_cached = false` | 跨实例共享的可变状态，和第 1 轮删掉的 `config = {}` 同型 | 删掉；`getDisplayState` 里 `self._state_time` 为 nil 时本来就会走真实读取，不需要初始值 |

**一条明确不能动的**：`onDispatcherRegisterActions()` 看着是 8 行单调用点，但不能内联、也不能改名。`koreader/frontend/dispatcher.lua:640` 会 `broadcastEvent(Event:new("DispatcherRegisterActions"))`，而 L648-653 的官方示例正是「定义同名方法 **并且** 在 init 里自己调一次」。改掉它会让插件在 Dispatcher 重建动作表时丢失注册。

## §2 设计决策

### 采纳

**配置数组，不是「配置 + 配置集」两层结构。** `bluetooth.lua` 直接 `return { {配置1}, {配置2} }`。数组元素就是今天的配置表，多加两个字段 `name` 和 `link`。

**配置选择：存过的优先，没存过就挑节点存在的第一个。** 两台机器共用同一份插件目录，各自的 `<settings>/bluetooth_controller.lua` 记住自己的选择，所以不需要按机型自动识别。首次安装时靠「节点存在」这个廉价判断把默认值猜对，猜错了进菜单点一下。

**覆盖值按配置名加前缀分桶。** `readSetting(cfg.name .. "/invert_layout")`。只有两个可覆盖字段、四个读写点，加前缀是一行的事；不值得为它引入嵌套表 + 迁移逻辑。

**菜单整体改 `sub_item_table_func`。** 已核对 `koreader/frontend/ui/widget/touchmenu.lua:875`：`item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table`，在 `onMenuSelect` 里通用处理，顶层插件条目同样生效。每次打开重建的好处：切换配置后菜单立刻跟上，不相关的项直接不发出来，不需要 `enabled_func` 灰显。

**`Dispatcher` 动作无条件注册。** 注册发生在 `init`，一个会话一次。若只在 `classic` 配置下注册，用户在 `ble` 配置下启动 KOReader 会导致已绑定的手势失效（动作查不到）。改成始终注册，`onToggleBluetooth` 里判链路，非 classic 就提示一句。

### 否掉的方案

| 方案 | 为什么不做 |
|---|---|
| 抽 `ClassicDriver` / `BleDriver` 接口 | 两个实现、永远两个。`if self.config.link == "classic"` 出现 3 次，比接口 + 两个文件短得多 |
| 按手柄名（`fbink_input_scan` 的 `device.name`）自动匹配配置 | 需要维护名字模式表，而 `device_path` 已经够用。真出现节点漂移再说 |
| 迁移旧的扁平覆盖值（`invert_layout` / `use_analog_mode`） | 只有一个用户、两个字段，最坏情况是进菜单重点一次。迁移代码是永久成本 |
| 每份配置独立的 `axis_threshold` 校准界面 | 配置文件手改一个数字就行，没人要求过 |
| `khp` 路径做成每配置可配 | `self.path .. "/khp/"` 是插件目录内的固定位置。多机型也一样 |

### 必须一起修掉的既有坑

`main` 的「摇杆模式」用 `enabled_func = supports_dpad` 灰显。若某台机器的覆盖值里存过 `use_analog_mode = false`，之后换成没有十字键的手柄，会得到「摇杆模式被灰显 + 走十字键解析路径 + 手柄不发 HAT 事件」= **完全不能翻页，且菜单里改不回来**。这是当初在 `ble` 分支整段删掉模式切换的原因（`c2b4f29`）。合并回来必须同时加一条：`supports_dpad` 为假时强制 `use_analog_mode = true`，忽略覆盖值。

## §3 文件结构

| 文件 | 责任 | 本计划的改动 |
|---|---|---|
| `main.lua` | 插件全部逻辑。KOReader 插件惯例是单文件，仓库现状也是，不拆 | 合并 + 配置选择 + 菜单分流，预计 539 → 约 660 行 |
| `bluetooth.lua` | 手写配置，只读 | 单配置 → 配置数组，两份配置各加 `name` / `link` |
| `_meta.lua` | 插件描述 | 描述改成双链路 |
| `docs/README.md` | 全部事实与决策记录 | 头部对照表改成「一个分支两套配置」，新增 §13 |
| `docs/plans/2026-09-04-unify-classic-ble.md` | 本文 | 新建 |

---

## 任务 0：固定基线

**文件：** 无改动

- [ ] **步骤 1：确认两分支状态干净**

```bash
git -C . status -sb
git log --oneline -1 main
git log --oneline -1 ble
```

期望：工作区干净；`main` = `e97a38b`，`ble` = `ae3d547`。若不符，先弄清多出来的提交是什么，不要直接往下走。

- [ ] **步骤 2：记录当前真机行为，作为回归对照**

在 PW6 上，KOReader 菜单 → 工具 → 蓝牙翻页器，确认现在有且只有这五项：

```
蓝牙守护进程 / 已连接设备 / 反转方向 / 重新加载设备 / 清理蓝牙垃圾
```

推摇杆能翻页、A/B/X/Y 与两个肩键能翻页。这是任务 1-5 每一步都要回到的基准。

- [ ] **步骤 3：开一条工作分支**

```bash
git checkout ble
git checkout -b unify
```

在 `unify` 上做完全部任务，验证通过再决定怎么落回 `main`（任务 6）。

---

## 任务 1：从 e97a38b 取回经典蓝牙代码

**文件：**
- 修改：`main.lua`（手工添加，无 git 冲突）

**接口：**
- 产出：`getRealState()`、`getDisplayState()`、`setBluetoothState(enable) -> boolean`、`onDispatcherRegisterActions()`、`onToggleBluetooth()`、`parseDpadInput(ev) -> number|nil` 五个方法加一个事件处理器回到 `main.lua`（`btLipc` 按上表内联，不恢复）；`isDaemonRunning()`、`startDaemon() -> boolean`、`stopDaemon()`、`_daemonCheck()` 保持不变。本任务结束时**配置仍是单份**，走现有的 `bluetooth.lua`，所以 dpad 与 classic 那两套代码存在但不可达。

- [ ] **步骤 1：把参照版本导出到临时文件**

```bash
git show e97a38b:main.lua > /tmp/classic-ref.lua
```

不要 `git merge main`，也不要 `git checkout e97a38b -- main.lua`——前者是空操作，后者会把 ble 的 20 个提交整份覆盖掉。全程只从这个参照文件里**抄需要的段落**。

- [ ] **步骤 2：确认起点没被动过**

```bash
git merge --no-commit --no-ff main    # 期望：Already up to date.（说明确实无可合并内容）
git diff --stat                        # 期望：空
```

- [ ] **步骤 3：按位置添加**

| 添加到 `main.lua` 的位置 | 内容（参照 `/tmp/classic-ref.lua` 的行号） |
|---|---|
| `require` 段末尾 | `local Dispatcher = require("dispatcher")`（参照 L3） |
| 常量段，`DAEMON_START_DELAY` 之后 | `local STATE_CACHE_INTERVAL = 2  -- 菜单 checked_func 会高频调用（docs §6）`（参照 L19） |
| `init` 里 `registerToMainMenu` 之后、`registerInputHook` 之前 | `self:onDispatcherRegisterActions()`（参照 L78） |
| `scanJoystickDevices` 之后、`isDaemonRunning` 之前 | `getRealState` / `getDisplayState` / `setBluetoothState`（参照 L319-359） |
| 同上，紧接其后 | `onDispatcherRegisterActions` / `onToggleBluetooth`（参照 L361-373） |
| `parseAnalogInput` 之前 | `parseDpadInput`（参照 L444-448）。**本任务不接线**，`parseInputDirection` 暂不改——留给任务 5 |
| `addToMainMenu` 里 | 「蓝牙开关」项（参照 L544-552）插到最前；「摇杆模式」项（参照 L584-593）连同 `joystickModeItem` 闭包（参照 L528-540）插在「反转方向」之后 |

**不要**从参照文件里抄这些（ble 已刻意删除或改写，抄回来就是回退）：`override`、`saveOverride`、`reloadDevice`、类表上的 `config = {}` / `settings = nil` / `opened_path` / `opened_fd` / `_state_cached`、`applyConfig` 的旧覆盖值读法、`parseAnalogInput` 的 `all_centered` 循环、`parseInputDirection`、`onExit`、`DEVICE_TAGS`、`handleInputEvent`、`cleanupBluetoothDumps`、`openDevice`、`closeDevice`、`isControllerDevice`。

- [ ] **步骤 4：按新标准精简抄进来的代码**

参照文件是老标准下的版本，`ble` 后 4 轮的规则没作用到它。三处必改（依据见 §1「取回的代码是老标准下审过的」）：

```lua
-- 1. btLipc 不要恢复，直接内联进 getRealState 开头：
function BluetoothController:getRealState()
    local powerd = Device:getPowerDevice()
    local lipc = powerd and powerd.lipc_handle
    if lipc then
        ...
```

```lua
-- 2. setBluetoothState 里两个单次使用的局部变量合成一句：
    if os.execute(string.format(
        "lipc-set-prop com.lab126.btfd BTflightMode %d", enable and 0 or 1)) ~= 0 then
```

```lua
-- 3. 类表上的 _state_cached = false 不要恢复。
--    getDisplayState 里 self._state_time 为 nil 时本来就走真实读取，不需要初始值。
```

`onDispatcherRegisterActions` 保持原样——它是 KOReader 的事件名约定，不能内联也不能改名（§1 末尾）。

- [ ] **步骤 5：语法检查**

把插件目录同步到 Kindle 后：

```sh
cd /mnt/us/koreader && ./luajit -bl plugins/bluetooth.koplugin/main.lua > /dev/null && echo OK
```

期望：打印 `OK`。任何 `unexpected symbol` 都是抄漏了 `end`。

- [ ] **步骤 6：真机验证——回到任务 0 的基准**

重启 KOReader，菜单里应该出现**七项**（多了「蓝牙开关」和「摇杆模式」）。逐项确认：

- 「蓝牙守护进程」仍能起停（起 6 秒后回查提示「守护进程已启动」）
- 「蓝牙开关」的勾选态反映真实蓝牙状态；点一下能关能开（PW6 上 lipc btfd 是存在的，与能不能连 BLE 无关）
- 「摇杆模式」此刻是灰的（`supports_dpad` 在 ble 的配置里不存在 → `nil == true` 为假）
- 摇杆和按键仍能翻页

- [ ] **步骤 7：确认精简没被回退**

```bash
git diff --stat                    # 期望：只有 main.lua，约 +105/−3
grep -nE 'function BluetoothController:(override|saveOverride|reloadDevice)\b' main.lua
grep -n 'local function btLipc' main.lua
grep -n 'all_centered' main.lua
```

后三条 grep 期望**全部无输出**。任何一条有输出，说明从参照文件里抄多了。

- [ ] **步骤 8：提交**

```bash
git add main.lua
git commit -m "✨ feat(classic): 从 e97a38b 取回经典蓝牙链路，按新标准精简"
```

---

## 任务 2：配置文件改成配置数组

**文件：**
- 修改：`bluetooth.lua`（整体重写）
- 修改：`main.lua`（`loadSettings`、`applyConfig`，新增 `pickProfile`）

**接口：**
- 消费：任务 1 产出的 `applyConfig(cfg)`
- 产出：`pickProfile(profiles) -> table|nil`；`self.config` 多出 `name`（字符串）和 `link`（`"classic"` 或 `"ble"`）两个字段，后续任务靠它们分流。`applyConfig` 的入参语义不变，仍是单份配置表。

- [ ] **步骤 1：改写 `bluetooth.lua`**

```lua
-- 手写配置，插件只读、永不改写。字段含义、校验规则、[可覆盖] 的语义见
-- docs 开头那张表与 §10。
-- 数组里每一份是一个手柄配置。菜单「手柄配置」里选中的那份生效，选择记在
-- <settings>/bluetooth_controller.lua 的 active_profile；没选过时取第一个
-- device_path 节点已存在的配置（docs §13）。
-- link 决定走哪条链路：classic = Amazon 蓝牙栈，ble = khp 守护进程。
-- 两份配置的轴量纲完全不同，别互相抄数值（docs §11）。

return {
    {
        name = "黑鲨双翼手柄L",
        link = "ble",
        device_path = "/dev/input/event3",
        trigger_cooldown_ms = 500,

        invert_layout = false,    -- [可覆盖] 反转方向
        supports_dpad = false,    -- 这个手柄没有十字键

        -- 8 位有符号，中心 0，极值 ±127；95 ≈ 3/4 行程
        axis_threshold = 95,
        analog_center = { [0] = 0, [1] = 0 },

        -- 只映射实按验证过的键；为什么不能照 B: KEY 位图映射见 docs §11
        key_map = {
            [304] = -1, [307] = -1, [310] = -1,   -- A / X / L1 上一页
            [305] = 1,  [308] = 1,  [312] = 1,    -- B / Y / L2 下一页
        },

        analog_map = {
            [1] = { low_dir = 1, high_dir = -1 }, -- ABS_Y
            [0] = { low_dir = -1, high_dir = 1 }, -- ABS_X
        },
    },
    {
        name = "Xbox 手柄",
        link = "classic",
        device_path = "/dev/input/event6",
        trigger_cooldown_ms = 500,

        invert_layout = false,    -- [可覆盖] 反转方向
        use_analog_mode = true,   -- [可覆盖] 摇杆模式
        supports_dpad = true,

        -- 16 位无符号，中心 32768
        axis_threshold = 16384,
        analog_center = { [0] = 32768, [1] = 32768 },

        key_map = {
            [304] = -1, [307] = -1,
            [305] = 1,  [308] = 1,
        },

        dpad_map = {
            [17] = { [-1] = 1,  [1] = -1 },
            [16] = { [-1] = -1, [1] = 1 },
        },

        analog_map = {
            [1] = { low_dir = 1, high_dir = -1 },
            [0] = { low_dir = -1, high_dir = 1 },
        },
    },
}
```

- [ ] **步骤 2：`loadSettings` 改成先挑配置**

把 `loadSettings` 末尾的 `return self:applyConfig(file_config)` 换成：

```lua
    -- 旧的扁平单配置格式没有 [1]，直接拒绝而不是当空数组静默失败
    if type(file_config[1]) ~= "table" then
        logger.warn("BT Plugin: bluetooth.lua is not a profile list, see docs §13")
        return false
    end

    local profile = self:pickProfile(file_config)
    if not profile then
        logger.warn("BT Plugin: No usable profile in bluetooth.lua")
        return false
    end
    return self:applyConfig(profile)
end
```

- [ ] **步骤 3：新增 `pickProfile`，放在 `loadSettings` 之后**

```lua
-- 存过的选择优先；没存过就挑节点已存在的第一个，让首次安装不必进菜单（docs §13）
function BluetoothController:pickProfile(profiles)
    local wanted = self.settings:readSetting("active_profile")
    for _, profile in ipairs(profiles) do
        if profile.name == wanted then return profile end
    end
    for _, profile in ipairs(profiles) do
        if lfs.attributes(profile.device_path, "mode") then return profile end
    end
    return profiles[1]
end
```

- [ ] **步骤 4：`applyConfig` 增加 `name` / `link` 校验**

在 `checks` 表最前面插两行：

```lua
        { "name",                type(cfg.name) == "string" and cfg.name ~= "" },
        { "link",                cfg.link == "classic" or cfg.link == "ble" },
```

- [ ] **步骤 5：把加载日志带上配置名**

`applyConfig` 末尾那行改成：

```lua
    logger.info("BT Plugin: Loaded profile " .. cfg.name .. " (" .. cfg.link .. ") on " .. cfg.device_path)
```

- [ ] **步骤 6：语法检查 + 真机验证**

```sh
cd /mnt/us/koreader && ./luajit -bl plugins/bluetooth.koplugin/main.lua > /dev/null && echo OK
grep 'BT Plugin: Loaded profile' /mnt/us/koreader/crash.log | tail -1
```

期望：日志打出 `Loaded profile 黑鲨双翼手柄L (ble) on /dev/input/event3`。摇杆和按键仍能翻页。

再验一次拒绝路径：临时把第一份配置的 `link` 改成 `"foo"`，重启，日志应出现 `Invalid or missing config field: link`，且插件不再打开设备。改回来。

- [ ] **步骤 7：提交**

```bash
git add bluetooth.lua main.lua
git commit -m "✨ feat(config): bluetooth.lua 改成配置数组，新增 name/link 字段"
```

---

## 任务 3：覆盖值按配置分桶

**文件：**
- 修改：`main.lua`（`applyConfig` 读覆盖值处、菜单写覆盖值处）

**接口：**
- 消费：任务 2 产出的 `self.config.name`
- 产出：覆盖值键名格式确定为 `"<配置名>/<字段名>"`，例如 `"黑鲨双翼手柄L/invert_layout"`。`active_profile` 是唯一的全局键，不加前缀。

- [ ] **步骤 1：`applyConfig` 里读覆盖值改成带前缀**

把任务 1 保留的那三行：

```lua
    local saved = self.settings:readSetting("invert_layout")
    if saved == nil then saved = cfg.invert_layout end
    self.config.invert_layout = saved == true
```

改成：

```lua
    -- 覆盖值按配置名分桶：两个手柄的「反转方向」是各自独立的（docs §13）
    local saved = self.settings:readSetting(cfg.name .. "/invert_layout")
    if saved == nil then saved = cfg.invert_layout end
    self.config.invert_layout = saved == true
```

- [ ] **步骤 2：「反转方向」菜单项的写入改成带前缀**

```lua
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            self.settings:saveSetting(
                self.config.name .. "/invert_layout", self.config.invert_layout)
            -- flush 自带原子写 + .old 备份 + fsync（luasettings.lua:270）
            self.settings:flush()
        end
```

- [ ] **步骤 3：「摇杆模式」的读写同样加前缀**

`joystickModeItem` 的 callback：

```lua
            callback = function()
                self.config.use_analog_mode = analog
                resetInputState()
                self.settings:saveSetting(self.config.name .. "/use_analog_mode", analog)
                self.settings:flush()
            end
```

`applyConfig` 里对应的读取（任务 1 从 main 带回来的那行）：

```lua
    -- 不能用 or：覆盖值为 false（方向键模式）时会被吃掉，退回文件里的 true
    local mode = self.settings:readSetting(cfg.name .. "/use_analog_mode")
    if mode == nil then mode = cfg.use_analog_mode end
    self.config.use_analog_mode = mode == true
```

- [ ] **步骤 4：真机验证——分桶是否真的隔离**

1. 当前配置（黑鲨）下打开「反转方向」，确认翻页方向反了。
2. 重启 KOReader，确认还是反的（持久化）。
3. 检查设置文件里的键名：

```sh
grep -o '"[^"]*invert_layout"' /mnt/us/koreader/settings/bluetooth_controller.lua
```

期望：`"黑鲨双翼手柄L/invert_layout"`，而不是裸的 `"invert_layout"`。

4. 关掉「反转方向」，确认恢复。

> 旧的裸键 `invert_layout` / `use_analog_mode` 会留在设置文件里成为死键，无害。刻意不写迁移代码（§2）。想清干净就手工删掉那两行。

- [ ] **步骤 5：提交**

```bash
git add main.lua
git commit -m "✨ feat(settings): 覆盖值按配置名分桶，避免两个手柄互相污染"
```

---

## 任务 4：菜单按链路与能力分流

**文件：**
- 修改：`main.lua`（`addToMainMenu` 整体重写，新增 `switchProfile`）

**接口：**
- 消费：任务 2 的 `pickProfile`、`self.config.link`、`self.config.supports_dpad`；任务 3 的前缀键
- 产出：`switchProfile(name)`；`addToMainMenu` 的插件条目从 `sub_item_table` 改为 `sub_item_table_func`

- [ ] **步骤 1：新增 `switchProfile`，放在 `pickProfile` 之后**

```lua
-- 切配置 = 存下选择再走一遍完整加载路径，不做增量更新（docs §13）
function BluetoothController:switchProfile(name)
    self.settings:saveSetting("active_profile", name)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = self:loadSettings() and self:openDevice(true) and _("已切换到 ") .. name
            or _("切换失败，见日志"),
        timeout = 2,
    })
end
```

- [ ] **步骤 2：`addToMainMenu` 改成每次打开重建**

外层结构换成：

```lua
function BluetoothController:addToMainMenu(menu_items)
    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        -- 用 _func 而非静态表：切配置后菜单立刻跟上，不相关的项直接不发出来
        -- （touchmenu.lua:875 对任意层级都生效，docs §13）
        sub_item_table_func = function() return self:buildMenuItems() end,
    }
end
```

- [ ] **步骤 3：把菜单内容搬进 `buildMenuItems`，按链路分流**

`buildMenuItems` 里的顺序与条件：

```lua
function BluetoothController:buildMenuItems()
    local sub_items = {}

    -- 只有一份配置时这一项没意义，不发
    table.insert(sub_items, self:profileMenuItem())

    if self.config.link == "classic" then
        table.insert(sub_items, { --[[ 「蓝牙开关」，任务 1 取回的那项 ]] })
    end

    -- 守护进程在跑就一直显示这一项，即使当前配置是 classic：否则从 ble 切到
    -- classic 之后 khp 还占着 32MB 和 BLE 射频，菜单里却没了关掉它的入口。
    -- classic 侧不需要对称处理 —— Amazon 自带设置界面能关蓝牙，khp 在设备上
    -- 除了这一项没有任何 UI（docs §13）
    if self.config.link == "ble" or self:isDaemonRunning() then
        table.insert(sub_items, { --[[ 「蓝牙守护进程」，ble 侧原有那项 ]] })
    end

    table.insert(sub_items, { --[[ 「已连接设备」 ]] })
    table.insert(sub_items, { --[[ 「反转方向」 ]] })

    -- 没有十字键就不发这一项：比灰显干净，也避免那个锁死的坑（§2）
    if self.config.supports_dpad then
        table.insert(sub_items, { --[[ 「摇杆模式」 ]] })
    end

    table.insert(sub_items, { --[[ 「重新加载设备」 ]] })
    table.insert(sub_items, { --[[ 「清理蓝牙垃圾」 ]] })
    return sub_items
end
```

注意「摇杆模式」项不再需要 `enabled_func`——它现在要么在、要么不在。

- [ ] **步骤 4：新增「手柄配置」子菜单**

```lua
-- 配置列表每次打开重读文件：改完 bluetooth.lua 不必重启 KOReader
function BluetoothController:profileMenuItem()
    return {
        text = _("手柄配置"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local loader = loadfile(self.path .. "/bluetooth.lua")
            local ok, profiles = pcall(loader or function() end)
            if not ok or type(profiles) ~= "table" or type(profiles[1]) ~= "table" then
                return { { text = _("配置文件无法读取"),
                          enabled_func = function() return false end } }
            end

            local items = {}
            for _i, profile in ipairs(profiles) do
                local name, link = profile.name, profile.link
                table.insert(items, {
                    text = string.format("%s (%s)", name, link),
                    checked_func = function() return self.config.name == name end,
                    callback = function() self:switchProfile(name) end,
                })
            end
            return items
        end,
    }
end
```

- [ ] **步骤 5：`onToggleBluetooth` 加链路判断**

```lua
function BluetoothController:onToggleBluetooth()
    if self.config.link ~= "classic" then
        UIManager:show(InfoMessage:new{ text = _("当前配置不走经典蓝牙"), timeout = 2 })
        return true
    end
    self:setBluetoothState(not self:getDisplayState())
    return true
end
```

- [ ] **步骤 6：语法检查**

```sh
cd /mnt/us/koreader && ./luajit -bl plugins/bluetooth.koplugin/main.lua > /dev/null && echo OK
```

- [ ] **步骤 7：真机验证——两条链路各走一遍**

在 PW6（当前是 BLE 配置）上：

1. 菜单应有：`手柄配置 / 蓝牙守护进程 / 已连接设备 / 反转方向 / 重新加载设备 / 清理蓝牙垃圾` —— **没有**「蓝牙开关」，**没有**「摇杆模式」。
2. 「手柄配置」里两项都在，`黑鲨双翼手柄L (ble)` 打勾。
3. 点 `Xbox 手柄 (classic)`。提示「已切换到 Xbox 手柄」或「切换失败」（PW6 上没有 event6 节点，切换失败是正常的——配置加载成功但打不开设备）。
4. **不退出菜单**，退回上一级再进来：这时应多出 `蓝牙开关` 和 `摇杆模式`。这一步是在验 `sub_item_table_func` 真的每次重建。
5. 切回黑鲨配置，确认 `蓝牙开关` 与 `摇杆模式` 消失、摇杆恢复翻页。

- [ ] **步骤 7b：验证守护进程不会被切配置藏起来**

这是步骤 3 的条件 `link == "ble" or isDaemonRunning()` 的用途，单独验：

1. 黑鲨配置下确认「蓝牙守护进程」是勾上的（守护进程在跑）。
2. 切到 Xbox 配置，退回菜单再进来。**「蓝牙守护进程」必须仍然在**，而且和「蓝牙开关」同时出现。
3. 点它把守护进程停掉，等 1 秒确认提示「守护进程已停止」。
4. 退回菜单再进来。**这次「蓝牙守护进程」应该消失了**（当前是 classic 配置，且守护进程已不在）。
5. 切回黑鲨配置，「蓝牙守护进程」回来，勾选态为空；点一下能重新起来。

若条件允许，在 Scribe 上重复：默认应自动落到 Xbox 配置（`pickProfile` 的节点存在判断），菜单里出现「蓝牙开关」与「摇杆模式」，「蓝牙守护进程」不出现。

- [ ] **步骤 8：提交**

```bash
git add main.lua
git commit -m "✨ feat(menu): 菜单改每次重建，按 link 与 supports_dpad 分流"
```

---

## 任务 5：接回十字键解析，并修掉锁死的坑

**文件：**
- 修改：`main.lua`（`applyConfig`、`parseInputDirection`）

**接口：**
- 消费：任务 1 保留的 `parseDpadInput(ev)`、任务 3 的 `use_analog_mode` 读取
- 产出：`parseInputDirection` 的 `EV_ABS` 分支恢复双路分派

- [ ] **步骤 1：`applyConfig` 增加 `dpad_map` 校验（只对声明支持的配置）**

`checks` 表里**不要**无条件加 `dpad_map`——BLE 那份配置没有这个字段，加了会整份被拒。在 `analog_center` 那个循环之后单独加：

```lua
    -- 声明有十字键就必须给 dpad_map，否则 parseDpadInput 会索引 nil
    if cfg.supports_dpad == true and type(cfg.dpad_map) ~= "table" then
        logger.warn("BT Plugin: supports_dpad is set but dpad_map is missing")
        return false
    end
```

- [ ] **步骤 2：`supports_dpad` 赋值 + 强制摇杆模式**

在 `invert_layout` 那几行旁边：

```lua
    self.config.supports_dpad = cfg.supports_dpad == true
    -- 没有十字键就锁死摇杆模式，忽略覆盖值：否则陈旧的 use_analog_mode = false
    -- 会配上一个不发 HAT 事件的手柄，变成完全不能翻页且菜单里改不回来（docs §13）
    if not self.config.supports_dpad then
        self.config.use_analog_mode = true
    end
```

**这一段必须排在任务 3 那段 `use_analog_mode` 读取之后**，否则覆盖值会把它冲掉。

- [ ] **步骤 3：`parseInputDirection` 恢复双路分派**

```lua
    if ev.type == C.EV_ABS then
        if self.config.use_analog_mode then return self:parseAnalogInput(ev) end
        return self:parseDpadInput(ev)
    end
```

顺手删掉 ble 分支留下的那行注释（`-- 本手柄只有摇杆，没有十字键，所以 EV_ABS 只有一条路`），它已经不成立了。

- [ ] **步骤 4：语法检查 + 真机验证锁死路径**

```sh
cd /mnt/us/koreader && ./luajit -bl plugins/bluetooth.koplugin/main.lua > /dev/null && echo OK
```

制造那个坑，确认已经填上：

1. 手工往设置文件里塞一个假覆盖值：

```sh
grep -n 'use_analog_mode' /mnt/us/koreader/settings/bluetooth_controller.lua
```

在里面加一行 `["黑鲨双翼手柄L/use_analog_mode"] = false,`（改前先备份）。

2. 重启 KOReader，用黑鲨配置。**摇杆必须仍能翻页**——`supports_dpad = false` 强制回了摇杆模式。
3. 菜单里不应出现「摇杆模式」。
4. 删掉那行假覆盖值。

若 Scribe 在手：用 Xbox 配置切到「方向键」模式，确认十字键能翻页、摇杆不再翻页；切回「模拟摇杆」，确认反过来。

- [ ] **步骤 5：提交**

```bash
git add main.lua
git commit -m "✨ feat(input): 接回十字键解析，无十字键时锁死摇杆模式"
```

---

## 任务 6：文档与分支收尾

**文件：**
- 修改：`docs/README.md`（头部对照表、§6、§11、新增 §13）
- 修改：`_meta.lua`
- 修改：`.gitignore`（`khp/` 那段说明改口径）

- [ ] **步骤 1：`_meta.lua` 描述改成双链路**

```lua
local _ = require("gettext")
return {
    fullname = _("蓝牙翻页器"),
    description = _([[用蓝牙手柄给 Kindle 翻页：支持多份手柄配置，经典蓝牙走系统蓝牙栈、BLE 走 kindle-hid-passthrough 守护进程；摇杆、十字键与按键映射，翻页时维持系统不休眠，手柄插拔自动重连。详见 docs §13。]]),
}
```

- [ ] **步骤 2：`docs/README.md` 头部对照表重写**

现在的表是「main 分支 vs ble 分支」，改成「经典蓝牙配置 vs BLE 配置」两列，行保留：目标机型、手柄、蓝牙栈、轴量纲、设备节点、菜单里的开关项。

- [ ] **步骤 3：§6 的「本分支已整段删除」注记删掉**

ble 分支当初把 §6（lipc 蓝牙开关）整段换成了一句指回 main 的注记。现在 lipc 代码回来了，把 main 的 §6 原文恢复，并补一句：这一节只对 `link = "classic"` 的配置生效。

- [ ] **步骤 4：§11 里「模式切换已整段删除」的记录改成历史注记**

那张删除记录表（原 `main.lua` 的 `dpad_map` / `supports_dpad` / `use_analog_mode` 三项）不要删——它记着**为什么保留会危险**。改成：当初在 ble 分支删过一次，现在按配置分流重新引入，锁死逻辑见 §13 与任务 5。

- [ ] **步骤 5：新增 §13**

必须写进去的事实（都是本计划里做过判断的地方，不写下来下次会重犯）：

1. 配置数组的结构与 `name` / `link` 两个字段的语义。
2. `pickProfile` 的两级回退顺序，以及「为什么不按手柄名自动匹配」。
3. 覆盖值键名格式 `"<配置名>/<字段名>"`，以及刻意不迁移旧裸键。
4. `sub_item_table_func` 在任意层级生效，出处 `koreader/frontend/ui/widget/touchmenu.lua:875`；顺带记一句：KOReader 的菜单搜索也会调用 `sub_item_table_func`（`touchmenu.lua:1005`），所以「已连接设备」那一项会在搜索时触发一次 FBInk 扫描——已知行为，非本次引入。
5. 为什么用「不发出菜单项」而不是 `enabled_func` 灰显。
6. 「蓝牙开关」与「蓝牙守护进程」为什么不合并成一项（`text` / `checked_func` / `callback` 三处都要分支，比插入处的一个分支长），以及两者同步性的差异：`setBluetoothState` 可乐观更新 + `touchmenu_instance:updateItems()` 立刻重画，`startDaemon` 只能弹提示 + `scheduleIn(DAEMON_START_DELAY)` 回查。
7. 「蓝牙守护进程」的显示条件是 `link == "ble" or isDaemonRunning()` 而非单纯看 `link`，以及为什么 classic 侧不做对称处理。
8. `getDisplayState()` 有 2 秒缓存而 `isDaemonRunning()` 刻意没有缓存——守护进程会被外部因素干掉，缓存会让菜单显示过时状态。代价是每次菜单重画 fork 一次 `pgrep`，是已知取舍，不要当漏加缓存去"修"。
9. `supports_dpad = false` 时强制 `use_analog_mode = true` 的原因（那个锁死场景的完整复现步骤）。
10. `Dispatcher` 动作为什么无条件注册，以及 `onDispatcherRegisterActions` 为什么不能内联或改名（`koreader/frontend/dispatcher.lua:640` 会广播同名事件）。
11. 被否掉的方案表（§2 那张表整个搬过去）。

- [ ] **步骤 6：`.gitignore` 里 `khp/` 的注释改口径**

现在写的是「本分支目标」，改成「`link = "ble"` 的配置才需要」。

- [ ] **步骤 7：提交文档**

```bash
git add docs _meta.lua .gitignore
git commit -m "📝 docs(unify): 双链路配置说明，新增 §13"
```

- [ ] **步骤 8：落回 main**

```bash
git checkout main
git merge --ff-only unify   # unify 从 ble 出发，ble 已含 main，应能快进
git log --oneline -3
```

若 `--ff-only` 失败，说明 `main` 在此期间有新提交，用普通 merge 并重跑任务 1 步骤 3-4 的验证。

- [ ] **步骤 9：退役 `ble` 分支**

`ble` 的历史已在 `main` 里，但打个标签方便回溯「只有 BLE、代码最精简」的那个状态：

```bash
git tag -a ble-only -m "合并进 main 前的纯 BLE 分支（539 行）"
git push origin main --tags
git push origin --delete ble    # 确认远端 main 已含 ble 全部提交后再执行
git branch -d ble unify
```

- [ ] **步骤 10：两台机器各跑一遍完整验收**

| 检查项 | PW6（BLE） | Scribe（经典） |
|---|---|---|
| 启动后自动选中的配置 | 黑鲨双翼手柄L | Xbox 手柄 |
| 「蓝牙开关」 | 不出现 | 出现，能开能关 |
| 「蓝牙守护进程」 | 出现，能起能停 | 不出现 |
| 「摇杆模式」 | 不出现 | 出现，两种模式都能翻页 |
| 摇杆翻页 | 能，且推住只翻一页 | 能，且推住只翻一页 |
| 按键翻页 | A/B/X/Y + L1/L2 | A/B/X/Y |
| 「反转方向」持久化 | 重启后仍生效 | 重启后仍生效，且与 PW6 互不影响 |
| 手柄断开重连 | 自动重连提示 | 自动重连提示 |

---

## §5 自检

**规格覆盖**

| 规格 | 任务 |
|---|---|
| ① 两分支合并 | 任务 1（代码）+ 任务 6 步骤 8-9（分支收尾） |
| ② 多配置 | 任务 2（数组 + 选择）+ 任务 3（覆盖值分桶）+ 任务 4 步骤 4（切换菜单） |
| ③ classic/ble 分流 | 任务 4 步骤 3、5 |
| ④ 无模式切换能力不显示 | 任务 4 步骤 3 + 任务 5 步骤 2 |
| ⑤ classic 开关蓝牙 / ble 开关守护进程 | 任务 4 步骤 3 |

**类型与命名一致性**

- `pickProfile(profiles)` 在任务 2 定义，任务 4 步骤 7 的验证引用它，名字一致。
- `switchProfile(name)` 参数是配置名字符串（不是配置表），任务 4 步骤 4 的 callback 传的是 `name`，一致。
- 覆盖值前缀分隔符统一是 `/`，出现在任务 3 步骤 1-3 与任务 5 步骤 4 的验证命令里。
- 任务 3 与任务 5 都改 `applyConfig` 里 `use_analog_mode` 相关的代码，**先后顺序有依赖**（任务 5 的强制赋值必须在任务 3 的读取之后），任务 5 步骤 2 已写明。

**关于没有单元测试**

本计划刻意没有测试任务，理由：开发机上没有 luajit（`luajit` 不在 PATH），KOReader 插件的依赖（`device`、`uimanager`、`luasettings`、FBInk FFI）要在宿主机跑起来得桩掉八个 require，而这套逻辑真正的输入是一个物理手柄的 evdev 流——桩出来的假事件通过了，说明不了真机通过。四轮重构全靠真机验证发现问题，没有一次是靠读代码发现的。

若后续要盲改 `parseAnalogInput` / `parseInputDirection`（这两个是纯函数化程度最高、也最容易改错的），值得单独做一件事：装 luajit，写 `spec/parse_spec.lua` 桩掉 require 并断言方向解析，把 `.gitignore` 里的 `test/` 改成不拦 `spec/`。现在不做。

调试键值用的现成办法记在 §5 附：设备上 `./luajit /mnt/us/evkeys.lua` 直接打十进制 `type/code/value`，是校准 `axis_threshold` 和补 `key_map` 的入口。
