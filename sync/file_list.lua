return {
    dialing = {
        { filename = "dial.lua", git = "dial.lua" },
        { filename = "settings.lua", git = "dial_settings.lua" },
    },
    alarming = {
        { filename = "alarm.lua", git = "alarm.lua" },
        { filename = "settings.lua", git = "alarm_settings.lua" },
    },
    server = {
        { filename = "server.lua", git = "sync/server.lua" },
        { filename = "updater.lua", git = "sync/updater.lua" },
    },
    shared = {
        { filename = "utils.lua", git = "utils.lua" },
        { filename = "addresses.lua", git = "addresses.lua" },
        { filename = "file_list.lua", git = "sync/file_list.lua" },
        { filename = "client.lua", git = "sync/client.lua" },
        { filename = "client_config.lua", git = "sync/client_config.lua" },
    },
}
-- Outer table signifys the scope a PC is using, client should identifier which scope of files it requires
-- filename: Identifier and name it should have on the client
-- git: Relative location of the file in repo
