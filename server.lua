local modem_side = "left"
rednet.open(modem_side)
rednet.host("files_request", "SGServer")

local files = {
    dial = { dst = "dial.lua", src = "disk/dial.lua", data = nil },
    alarm = { dst = "alarm.lua", src = "disk/alarm.lua", data = nil },
    utils = { dst = "utils.lua", src = "disk/utils.lua", data = nil },
    addresses = { dst = "addresses.lua", src = "disk/addresses.lua", data = nil },
    settings = { dst = "settings.lua", src = "disk/settings.lua", data = nil },
    client = { dst = "client.lua", src = "disk/client.lua", data = nil },
    server = { dst = "server.lua", src = "disk/server.lua", data = nil },
}
for _, file in pairs(files) do
    local f = fs.open(file.src, "r")
    if f then
        file.data = f.readAll()
        f.close()
    else
        print(("Failed to load %s"):format(file.src))
    end
end

print("Stargate server online")

while true do
    local id, msg, proto = rednet.receive("files_request")
    local file = files[msg]
    if file and file.data then
        rednet.send(id, file, "files_reply")
    elseif file and not file.data then
        print(("Skipping send of %s; data missing"):format(msg))
    end
end
