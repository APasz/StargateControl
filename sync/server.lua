package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
rednet.open("left")
-- Since there should only be one server and it shouldn't be moved all that much, hardcoding is probably fine

local REQUEST_PROTOCOL = "files_request"
local REPLY_PROTOCOL = "files_reply"
local SERVER_NAME = "SGServer"
local DEFAULT_BASE_DIR = "disk"
local FILE_LIST = require("file_list")

rednet.host(REQUEST_PROTOCOL, SERVER_NAME)

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

local function build_file_map(list)
    local scoped_files = {}

    for scope, files in pairs(list) do
        local map = {}
        for _, file in ipairs(files) do
            local base_dir = file.disk or DEFAULT_BASE_DIR
            map[file.filename] = {
                src = fs.combine(base_dir, file.git),
                dst = file.filename,
                override = file.override ~= false,
            }
        end
        scoped_files[scope] = map
    end

    return scoped_files
end

local FILES = build_file_map(FILE_LIST)

for scope, files in pairs(FILES) do
    for name, file in pairs(files) do
        if not refresh_file(file) then
            print(("Failed to load %s (%s)"):format(file.src, name))
        end
    end
end

print("Stargate server online")

while true do
    local id, msg = rednet.receive(REQUEST_PROTOCOL)
    local scope = type(msg) == "table" and msg.scope
    local filename = type(msg) == "table" and msg.filename

    local scoped_files = scope and FILES[scope]
    local file = scoped_files and filename and scoped_files[filename]

    if not scope or not filename then
        rednet.send(id, { error = "Invalid file request" }, REPLY_PROTOCOL)
    elseif not file then
        rednet.send(id, { error = ("Unknown file requested (%s/%s)"):format(tostring(scope), tostring(filename)) }, REPLY_PROTOCOL)
    elseif not refresh_file(file) then
        print(("Skipping send of %s/%s; data missing"):format(scope, filename))
        rednet.send(id, { error = "File missing" }, REPLY_PROTOCOL)
    else
        rednet.send(id, { dst = file.dst, data = file.data, override = file.override }, REPLY_PROTOCOL)
    end
end
