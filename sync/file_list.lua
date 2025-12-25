return {
    manifest = {
        { filename = "file_list.lua", git = "sync/file_list.lua", override=true },
    },
    dialing = {
        { filename = "dial.lua", git = "dial.lua", override=true },
        { filename = "dial_comm.lua", git = "dial_comm.lua", override=true },
        { filename = "dial_gate.lua", git = "dial_gate.lua", override=true },
        { filename = "dial_ui.lua", git = "dial_ui.lua", override=true },
        { filename = "dial_timers.lua", git = "dial_timers.lua", override=true },
        { filename = "dial_flow.lua", git = "dial_flow.lua", override=true },
        { filename = "dial_events.lua", git = "dial_events.lua", override=true },
        { filename = "settings.lua", git = "dial_settings.lua", override=false },
    },
    alarming = {
        { filename = "alarm.lua", git = "alarm.lua", override=true },
        { filename = "settings.lua", git = "alarm_settings.lua", override=false },
    },
    auxiliary = {
        { filename = "auxiliary.lua", git = "auxiliary.lua", override=true },
        { filename = "settings.lua", git = "auxiliary_settings.lua", override=false },
    },
    reactor = {
        { filename = "reactor.lua", git = "reactor.lua", override=true, disk = "disk2" },
        { filename = "settings.lua", git = "reactor_settings.lua", override=false, disk = "disk2" },
    },
    server = {
        { filename = "server.lua", git = "sync/server.lua", override=true },
        { filename = "updater.lua", git = "sync/updater.lua", override=true },
    },
    shared = {
        { filename = "utils.lua", git = "utils.lua", override=true, disk = "disk2" },
        { filename = "address_utils.lua", git = "address_utils.lua", override=true, disk = "disk2" },
        { filename = "monitor_utils.lua", git = "monitor_utils.lua", override=true, disk = "disk2" },
        { filename = "peripheral_utils.lua", git = "peripheral_utils.lua", override=true, disk = "disk2" },
        { filename = "menu_utils.lua", git = "menu_utils.lua", override=true, disk = "disk2" },
        { filename = "dialing_utils.lua", git = "dialing_utils.lua", override=true, disk = "disk2" },
        { filename = "addresses.lua", git = "addresses.lua", override=true, disk = "disk2" },
        { filename = "client.lua", git = "sync/client.lua", override=true, disk = "disk2" },
        { filename = "client_config.lua", git = "sync/client_config.lua", override=false, disk = "disk2" },
    },
}
-- Outer table signifys the scope a PC is using, client should identifier which scope of files it requires
-- filename: Identifier and name it should have on the client
-- git: Relative location of the file in repo
-- override: If this file should override a local copy
-- disk: Optional disk directory (e.g. "disk2") for updater/server storage; defaults to "disk"
