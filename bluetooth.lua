
return {
    common = {
        wakeup_delay = 3,
        trigger_cooldown_ms = 500,
        invert_layout = false,
        active_profile = "xbox_wireless_controller",
    },

    profiles = {
        ["xbox_wireless_controller"] = {
            name = "Xbox Wireless Controller",
            device_path = "/dev/input/event6",
            supports_dpad = true,
            use_analog_mode = true,

            axis_threshold = 16384,
            analog_center = { [0] = 32768, [1] = 32768 },

            key_map = {
                [304] = -1, [307] = -1,
                [305] = 1, [308] = 1,
            },

            dpad_map = {
                [17] = { [-1] = 1, [1] = -1 },
                [16] = { [-1] = -1, [1] = 1 }
            },

            analog_map = {
                [1] = { low_dir = 1, high_dir = -1 },
                [0] = { low_dir = -1, high_dir = 1 }
            },
        },
    }
}
