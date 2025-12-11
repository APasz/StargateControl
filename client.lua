local PREFERRED_MODEM_SIDE = "back"
local PRIMARY_PROGRAM = "dial"
local REQUEST_PROTOCOL = "files_request"
local REPLY_PROTOCOL = "files_reply"
local SERVER_NAME = "SGServer"

local function is_wireless_modem(side)
    if not side or peripheral.getType(side) ~= "modem" then
        return false
    end

    local ok, res = pcall(peripheral.call, side, "isWireless")
    return ok and res == true
end

local function ensure_modem_open(preferred_side)
    if is_wireless_modem(preferred_side) then
        rednet.open(preferred_side)
        if rednet.isOpen(preferred_side) then
            return preferred_side
        end
    end

    local _, detected_side = peripheral.find("modem", function(_, obj)
        return obj.isWireless and obj.isWireless()
    end)
    if detected_side then
        rednet.open(detected_side)
        if rednet.isOpen(detected_side) then
            return detected_side
        end
    end

    error("No wireless/ender modem found; attach a wireless or ender modem", 0)
end

ensure_modem_open(PREFERRED_MODEM_SIDE)

local FILES = { PRIMARY_PROGRAM, "utils", "addresses", "client" }
-- files which are required to run the primary program, settings.lua should ideally only be fetched on initial setup
local REQUIRED_FILES = { PRIMARY_PROGRAM, "utils", "addresses", "client", "settings" }

local args = { ... }
local is_setup = args[1] == "setup"
local files_to_fetch = is_setup and REQUIRED_FILES or FILES

local function file_on_disk(name)
    return fs.exists(name) or fs.exists(("%s.lua"):format(name))
end

local function has_required_files()
    for _, name in ipairs(REQUIRED_FILES) do
        if not file_on_disk(name) then
            print("Missing file: " .. name)
            return false
        end
    end
    return true
end

local function find_server_with_retry(attempts, initial_delay)
    local max_attempts = attempts or 5
    local delay = initial_delay or 1
    for attempt = 1, max_attempts do
        local id = rednet.lookup(REQUEST_PROTOCOL, SERVER_NAME)
        if id then
            return id
        end
        if attempt < max_attempts then
            sleep(delay)
            delay = math.min(delay * 2, 8)
        end
    end
    return nil
end

local function fetch_file(name, server_id)
    rednet.send(server_id, name, REQUEST_PROTOCOL)
    while true do
        local id, payload = rednet.receive(REPLY_PROTOCOL, 5)
        if not id then
            error("No reply from SG server", 0)
        end
        if id == server_id then
            if type(payload) ~= "table" or not payload.dst or not payload.data then
                error(("Invalid file payload for %s"):format(name), 0)
            end
            return payload
        end
    end
end

local function write_file(file)
    if type(file.dst) ~= "string" or type(file.data) ~= "string" then
        error("Invalid file payload (missing dst or data)", 0)
    end

    local parent_dir = fs.getDir(file.dst)
    if parent_dir and parent_dir ~= "" then
        fs.makeDir(parent_dir)
    end

    local tmp_path = ("%s.tmp-%d"):format(file.dst, os.getComputerID())
    if fs.exists(tmp_path) then
        fs.delete(tmp_path)
    end

    local f = fs.open(tmp_path, "w")
    if not f then
        error(("Unable to open %s for writing"):format(tmp_path), 0)
    end
    f.write(file.data)
    f.close()

    if fs.exists(file.dst) then
        fs.delete(file.dst)
    end
    fs.move(tmp_path, file.dst)
end

local function run_primary()
    return shell.run(PRIMARY_PROGRAM)
end

local function fallback_or_error(message)
    local reason = tostring(message)
    if has_required_files() then
        print(reason)
        return run_primary()
    end
    error(reason, 0)
end

local server_id = find_server_with_retry()

if not server_id then
    return fallback_or_error("Unable to find SGServer on network")
end

local fetched_files = {}
for _, name in ipairs(files_to_fetch) do
    local ok, file_or_err = pcall(fetch_file, name, server_id)
    if not ok then
        return fallback_or_error(file_or_err)
    end
    fetched_files[#fetched_files + 1] = file_or_err
end

for _, file in ipairs(fetched_files) do
    write_file(file)
end

if is_setup then
    print("Done!")
else
    run_primary()
end
