return {
    dialing = {
        { filename = "dial.lua", git = "dial.lua", override=true },
        { filename = "settings.lua", git = "dial_settings.lua", override=false },
    },
    alarming = {
        { filename = "alarm.lua", git = "alarm.lua", override=true },
        { filename = "settings.lua", git = "alarm_settings.lua", override=false },
    },
    server = {
        { filename = "server.lua", git = "sync/server.lua", override=true },
        { filename = "updater.lua", git = "sync/updater.lua", override=true },
    },
    auxiliary = {
        { filename = "auxiliary.lua", git = "auxiliary.lua", override=true },
    },
    shared = {
        { filename = "utils.lua", git = "utils.lua", override=true },
        { filename = "address_utils.lua", git = "address_utils.lua", override=true },
        { filename = "monitor_utils.lua", git = "monitor_utils.lua", override=true },
        { filename = "peripheral_utils.lua", git = "peripheral_utils.lua", override=true },
        { filename = "menu_utils.lua", git = "menu_utils.lua", override=true },
        { filename = "dialing_utils.lua", git = "dialing_utils.lua", override=true },
        { filename = "addresses.lua", git = "addresses.lua", override=true },
        { filename = "file_list.lua", git = "sync/file_list.lua", override=true },
        { filename = "client.lua", git = "sync/client.lua", override=true },
        { filename = "client_config.lua", git = "sync/client_config.lua", override=false },
    },
}
-- Outer table signifys the scope a PC is using, client should identifier which scope of files it requires
-- filename: Identifier and name it should have on the client
-- git: Relative location of the file in repo
-- override: If this file should override a local copy
