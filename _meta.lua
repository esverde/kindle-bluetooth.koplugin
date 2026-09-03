local _ = require("gettext")
return {
    fullname = _("蓝牙翻页器"),
    description = _([[用 BLE 手柄给 Kindle 翻页：支持摇杆与按键映射，翻页时维持系统不休眠，手柄插拔自动重连，并可在菜单里起停守护进程。需先安装 kindle-hid-passthrough 建立 BLE 链路，详见 docs §11。]]),
}
