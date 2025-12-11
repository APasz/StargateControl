rednet.open("left")
rednet.host("files_request", "SGServer")

local FILES = {
    dial = { dst = "dial.lua", src = "disk/dial.lua", data = nil },
    alarm = { dst = "alarm.lua", src = "disk/alarm.lua", data = nil },
    utils = { dst = "utils.lua", src = "disk/utils.lua", data = nil },
    addresses = { dst = "addresses.lua", src = "disk/addresses.lua", data = nil },
    settings = { dst = "settings.lua", src = "disk/settings.lua", data = nil },
    client = { dst = "client.lua", src = "disk/client.lua", data = nil },
    client_config = { dst = "client_config.lua", src = "disk/client_config.lua", data = nil },
    server = { dst = "server.lua", src = "disk/server.lua", data = nil },
}

local function load_file(file)
    local handle = fs.open(file.src, "r")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function refresh_file(file)
    local data = load_file(file)
    file.data = data
    return data ~= nil
end

for name, file in pairs(FILES) do
    if not refresh_file(file) then
        print(("Failed to load %s"):format(file.src))
    end
end

print("Stargate server online")

while true do
    local id, msg, proto = rednet.receive("files_request")
    local file = FILES[msg]
    if file then
        if not refresh_file(file) then
            print(("Skipping send of %s; data missing"):format(msg))
        else
            rednet.send(id, file, "files_reply")
        end
    end
end
