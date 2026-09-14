# Bluetooth Page Turner for Kindle

**English** · [简体中文](README.zh-CN.md)

A [KOReader](https://github.com/koreader/koreader) plugin that turns pages on a
Kindle with a Bluetooth Low Energy gamepad — analog stick, D-pad, or face
buttons.

Kindle's stock firmware cannot connect to BLE peripherals at all, so this plugin
pairs with [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)
(khp), a userspace Bluetooth stack that exposes the controller as a standard
Linux input device. The plugin then consumes that device directly and keeps the
Kindle awake while you read.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Configuration](#configuration)
- [Known controller profiles](#known-controller-profiles)
- [Menu reference](#menu-reference)
- [Important: Wi-Fi and Bluetooth share one chip](#important-wi-fi-and-bluetooth-share-one-chip)
- [Finding your controller's values](#finding-your-controllers-values)
- [Troubleshooting](#troubleshooting)
- [Branches](#branches)
- [License](#license)
- [Credits](#credits)

---

## Features

- **Page turns from stick, D-pad or buttons.** Any combination; you decide what
  each input does in a small config file.
- **Stick and D-pad modes.** Controllers that have both can switch between them
  from the menu.
- **No accidental multi-page flips.** A stick held at full deflection turns
  exactly one page; it unlocks only after every mapped axis returns to centre.
- **Stays awake while reading.** Page turns reset the Kindle's idle timer, so it
  will not sleep in your hands.
- **Automatic reconnect.** Turn the controller off and on again and it just
  works — no menu interaction required.
- **Battery level** of the controller shown in the menu.
- **Daemon control.** Start and stop the khp background service from inside
  KOReader.
- **Wi-Fi guard.** Prevents the one action that can wedge the radio (see
  [below](#important-wi-fi-and-bluetooth-share-one-chip)).

## Requirements

| | |
| --- | --- |
| **Device** | A jailbroken Kindle. Tested on **Kindle Scribe**, **Paperwhite (12th gen)** and **Kindle (2024)**. |
| **Reader** | KOReader, verified against **v2026.07.2**. |
| **Daemon** | kindle-hid-passthrough, **v3.15.2 or newer**. |
| **Controller** | Any BLE gamepad that presents a standard HID report. |

> **Why a jailbreak is unavoidable:** khp needs root to open `/dev/stpbt`, the
> raw Bluetooth transport, and to create `/dev/uhid` devices.

> **The plugin's own interface is Simplified Chinese only.** Menu entries and
> toasts are not translated, and there is no `l10n/` catalogue yet. Menu items
> are given below in English with the Chinese original alongside so you can find
> them on screen. Pull requests adding translations are welcome.

## How it works

```
BLE gamepad
    │  Bluetooth Low Energy (HID over GATT)
    ▼
kindle-hid-passthrough  ── userspace Bluetooth stack, talks to /dev/stpbt
    │  creates a virtual HID device via /dev/uhid
    ▼
/dev/input/eventN       ── an ordinary Linux input device
    │
    ▼
This plugin             ── reads events, sends page turns to KOReader
```

The plugin never touches Bluetooth itself. It only consumes the input device
that khp produces, which is why it stays small and why khp must be running for
anything to happen.

## Installation

### 1. Install KOReader

Follow the [official instructions](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)
for your device.

### 2. Install this plugin

Copy the repository into KOReader's plugin folder so that it ends up at:

```
/mnt/us/koreader/plugins/bluetooth.koplugin/
```

The directory name **must** end in `.koplugin`.

### 3. Install the daemon

Download the ARM build of kindle-hid-passthrough and place its contents in a
`khp/` sub-folder **inside the plugin directory**:

```
/mnt/us/koreader/plugins/bluetooth.koplugin/
├── main.lua
├── bluetooth.lua
└── khp/
    ├── kindle-hid-passthrough     ← launcher
    ├── dist/                      ← bundled runtime
    ├── config.ini
    └── devices.conf               ← created when you pair
```

You only need the launcher, `dist/`, and the two config files. The installer's
other options (button-mapper, the web UI, the upstart auto-start job) are **not
required** and are best skipped — they have caused boot loops on some firmware.

Then point khp's `config.ini` at its new home. Replace `<khp>` with the absolute
path of that `khp/` folder:

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

> `[media_remote] enabled = false` matters: leaving it on makes the Kindle
> discoverable and connectable over classic Bluetooth, which this plugin does
> not need.

### 4. Pair your controller

**Turn Wi-Fi on before pairing** — see [the Wi-Fi section](#important-wi-fi-and-bluetooth-share-one-chip)
for why. Then, over SSH:

```sh
cd /mnt/us/koreader/plugins/bluetooth.koplugin/khp
./kindle-hid-passthrough --pair
```

Put the controller in pairing mode and follow the prompts. The result is written
to `devices.conf` and persists across reboots.

> To add a second controller, just run `--pair` again. `devices.conf`
> accumulates entries and khp serves them all — whichever controller you switch
> on will connect.

### 5. Configure and start

Find out how the system names your controller:

```sh
cat /proc/bus/input/devices
```

Look for the `N: Name="..."` line. Any distinctive fragment of that name goes
into `match_name` in `bluetooth.lua` (see below). Then restart KOReader and
start the daemon from the menu.

## Configuration

All settings live in `bluetooth.lua` in the plugin directory. The plugin only
ever reads this file — it never writes to it.

The file returns an **array of profiles**, one per controller. On startup, and
whenever a controller connects, the plugin scans the input devices and uses the
**first profile in array order** whose `match_name` matches something present.
If both of your controllers are switched on, the one listed first wins.

There is no `device_path` field: the device number comes from the scan, so
`eventN` drifting between reboots no longer affects anything.

**Every field is required.** If one is missing or out of range, that profile is
rejected and the reason is logged; there are no silent fallbacks.

| Field | Meaning |
| --- | --- |
| `match_name` | A Lua pattern matched against the controller's system name. The first profile whose pattern matches a connected device wins. |
| `display_name` | What the menu shows for this controller. The raw system name includes a hardware address suffix and is unpleasantly long. |
| `trigger_cooldown_ms` | Minimum gap between two page turns, in milliseconds. |
| `invert_layout` | Swap previous/next. *Changeable from the menu.* |
| `supports_dpad` | Set `true` only if the controller has a D-pad. When `true`, `dpad_map` is also required. |
| `use_analog_mode` | `true` = stick, `false` = D-pad. *Changeable from the menu*, and ignored (forced to `true`) when `supports_dpad` is `false`. |
| `axis_threshold` | How far the stick must move before it counts. The one value worth tuning by feel. |
| `analog_center` | Resting value of each axis. Every axis in `analog_map` needs an entry. |
| `key_map` | Button code → direction. `1` = next page, `-1` = previous page. |
| `analog_map` | Axis code → direction for each end of travel. Axis `0` is X, axis `1` is Y. |
| `dpad_map` | D-pad axis code → direction. Only read when `supports_dpad` is `true`. |

> **Fields marked *changeable from the menu* behave differently after you use the
> menu once.** From then on the stored value wins and editing `bluetooth.lua`
> has no effect on them. The other fields are always read from the file.

After editing, use 重新加载设备 (*Reload device*) in the menu — no restart needed.

## Known controller profiles

Axis ranges differ wildly between controllers. **Never copy numbers between
profiles**; an 8-bit stick and a 16-bit stick differ by a factor of 256, and
getting it wrong means either "nothing happens" or "it flips pages when I
breathe on it".

Both examples below are entries in the same array — keep the ones you use and
delete the rest.

### Controller with stick and buttons, no D-pad

8-bit signed axes, centre `0`, full travel `±127`:

```lua
{
    match_name = "My Pad",
    display_name = "My Controller",
    trigger_cooldown_ms = 500,

    invert_layout = false,
    supports_dpad = false,

    axis_threshold = 95,
    analog_center = { [0] = 0, [1] = 0 },

    -- 1 = next page, -1 = previous page
    key_map = {
        [304] = 1,  [305] = 1,  [310] = 1,    -- A / B / L1
        [307] = -1, [308] = -1, [312] = -1,   -- X / Y / L2
    },

    analog_map = {
        [1] = { low_dir = -1, high_dir = 1 }, -- ABS_Y
        [0] = { low_dir = -1, high_dir = 1 }, -- ABS_X
    },
},
```

### Xbox Wireless Controller

16-bit axes, centre `32768`. **These values come from the same controller used
over classic Bluetooth and have not yet been re-measured over BLE** — treat them
as a starting point and verify with the method below.

```lua
{
    match_name = "Xbox",
    display_name = "Xbox Controller",
    trigger_cooldown_ms = 500,

    invert_layout = false,
    use_analog_mode = true,
    supports_dpad = true,

    axis_threshold = 16384,
    analog_center = { [0] = 32768, [1] = 32768 },

    key_map = {
        [304] = -1, [307] = -1,   -- A / X
        [305] = 1,  [308] = 1,    -- B / Y
    },

    dpad_map = {
        [17] = { [-1] = 1,  [1] = -1 },   -- ABS_HAT0Y
        [16] = { [-1] = -1, [1] = 1 },    -- ABS_HAT0X
    },

    analog_map = {
        [1] = { low_dir = 1,  high_dir = -1 },
        [0] = { low_dir = -1, high_dir = 1 },
    },
},
```

> **Only one controller is used at a time.** If both are switched on, both
> connect at the khp level, but the plugin reads input from the first matching
> profile only. The other still holds a Bluetooth link and drains its own
> battery, so switch off the one you are not using.

## Menu reference

**Settings → Network → 蓝牙翻页器** (Bluetooth Page Turner)

| Item | What it does |
| --- | --- |
| 蓝牙守护进程 — *Bluetooth daemon* | Start or stop khp. Checked when it is running. |
| 已连接设备 — *Connected devices* | Lists every gamepad-like input device found, with the active one tagged `[当前]` and its battery level shown. |
| 反转方向 — *Invert direction* | Swap previous and next. Persists across restarts. |
| 摇杆模式 — *Stick mode* | Choose 模拟摇杆 (stick) or 方向键 (D-pad). Greyed out when the controller has no D-pad. |
| 重新加载设备 — *Reload device* | Re-read `bluetooth.lua` and reopen the input device. |

When you start the daemon a toast says the daemon is starting, and roughly five
seconds later a second one says the controller is connected. **If that second
message never appears, the controller did not connect** — the usual cause is
Wi-Fi being off.

## Important: Wi-Fi and Bluetooth share one chip

On these Kindles, Wi-Fi and Bluetooth are two halves of a single combo chip, and
khp takes the Bluetooth half over completely. Two consequences follow, and both
matter in daily use.

### Wi-Fi must be on for the controller to connect

The chip's firmware is loaded when the Wi-Fi side powers up. khp does not load it
itself. With Wi-Fi off, khp starts, reports itself as running, and then never
connects to anything.

**Connect Wi-Fi first, then start the daemon.**

### Turning Wi-Fi on while the daemon runs wedges the radio

Bringing Wi-Fi up while khp holds the chip leaves the radio in a state that
**only a reboot clears** — Wi-Fi will not scan or connect until you restart the
Kindle.

The plugin guards against this: attempting to enable Wi-Fi while the daemon is
running shows 请先关闭蓝牙守护进程，再开 WiFi (*stop the Bluetooth daemon first*) and the request
is refused. Stop the daemon from the menu, then turn Wi-Fi on normally.

> **The guard cannot cover everything.** It only sees Wi-Fi changes made through
> KOReader. Turning Wi-Fi on from the Kindle's own settings screen bypasses it
> entirely — which also makes that screen your escape hatch if the daemon ever
> becomes impossible to stop.
>
> One more gap: if *Restore Wi-Fi connection on resume* is enabled, KOReader
> restores Wi-Fi once at startup on a path that runs before plugins load. Leaving
> that setting off (its default) avoids it.

This is a property of the hardware and of how khp claims it, not a defect in
this plugin. It is tracked upstream as
[khp issue #88](https://github.com/zampierilucas/kindle-hid-passthrough/issues/88).

## Finding your controller's values

Save this as `/mnt/us/evkeys.lua`:

```lua
local ffi = require("ffi")
ffi.cdef[[
struct input_event { long tv_sec; long tv_usec; unsigned short type; unsigned short code; int value; };
int open(const char *path, int flags);
long read(int fd, void *buf, unsigned long n);
]]
local path = ... or "/dev/input/event2"
local fd = ffi.C.open(path, 0)
assert(fd >= 0, "cannot open " .. path)
io.stdout:setvbuf("line")
local ev, size = ffi.new("struct input_event"), 16
print("reading " .. path .. " — Ctrl-C to stop")
while true do
    if ffi.C.read(fd, ev, size) == size and (ev.type == 1 or ev.type == 3) then
        print(string.format("%s code=%d value=%d",
            ev.type == 1 and "KEY" or "ABS", ev.code, ev.value))
    end
end
```

Run it with KOReader's own interpreter:

```sh
cd /mnt/us/koreader && ./luajit /mnt/us/evkeys.lua /dev/input/event2
```

- **Buttons** print `KEY code=N value=1` when pressed. Put `N` into `key_map`.
- **Stick** prints `ABS code=0` or `code=1` with the raw position. Push to each
  extreme to learn the range, let go to read the centre.
- **D-pad** prints `ABS code=16` or `code=17` with `value` of `-1`, `0` or `1`.

> **Do not map a button just because it appears in a capability bitmap.** HID
> descriptors routinely declare more buttons than the hardware actually has.
> Only map codes you have seen this tool print.

The daemon and this script can read the device at the same time, so pages will
still turn while you measure.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Daemon starts but the controller never connects | Wi-Fi is off. Connect Wi-Fi, then restart the daemon. |
| Wi-Fi will not scan or connect | The radio is wedged. Reboot the Kindle, then always stop the daemon before touching Wi-Fi. |
| Nothing happens when you press buttons | No profile matched. Compare `match_name` with the `N: Name=` line in `/proc/bus/input/devices`. |
| The wrong controller's settings are applied | Both controllers are on and the other profile is listed first. Switch one off, or reorder the array. |
| Stick turns several pages at once | `axis_threshold` is too low for this controller. |
| Stick does not turn pages at all | `axis_threshold` is too high, or `analog_center` is wrong for its range. |
| Menu entry missing entirely | The plugin failed to load — check `crash.log`. |
| `Invalid or missing config field: X` in the log | `bluetooth.lua` is missing field `X`, or its value is the wrong type. |

Logs worth reading:

```sh
grep 'BT Plugin' /mnt/us/koreader/crash.log | tail -40
tail -40 /mnt/us/koreader/plugins/bluetooth.koplugin/khp/hid_passthrough.log
```

## Branches

| Branch | Contents |
| --- | --- |
| `main` | This one. BLE controllers via kindle-hid-passthrough. Actively maintained. |
| `classic` | Earlier implementation for classic-Bluetooth controllers using the Kindle's own Bluetooth stack. Archived, no longer updated. |

`docs/NOTES.md` holds maintainer notes: measured facts, rejected designs and
the reasoning behind non-obvious code. It is a working log, not documentation.

## License

[GNU AGPL v3 or later](LICENSE), matching KOReader itself. In short: you may use,
modify and redistribute this plugin, but derivative works must stay under the
same licence and ship their source.

## Credits

- [KOReader](https://github.com/koreader/koreader) — the reader this plugs into.
- [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)
  by zampierilucas — the userspace Bluetooth stack that makes BLE possible on
  Kindle at all.
- [FBInk](https://github.com/NiLuJe/FBInk) by NiLuJe — its input classifier is
  what tells a gamepad apart from a touchscreen.
