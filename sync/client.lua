local CONFIG_PATH = "client_config.lua"
local DEFAULT_CONFIG_CONTENT = 'return { side = "back", primary_file = "dial" }\n'
local REQUEST_PROTOCOL = "files_request"
local REPLY_PROTOCOL = "files_reply"
local SERVER_NAME = "SGServer"
local FILE_LIST_NAME = "file_list.lua"
local SCOPE_ALIASES = { dial = "dialing", alarm = "alarming", server = "server" }

local function load_or_create_config()
    if fs.exists(CONFIG_PATH) then
        local ok, config = pcall(require, "client_config")
        if ok then
            return config
        end
        error(config, 0)
    end

    local handle = fs.open(CONFIG_PATH, "w")
    if not handle then
        error("Missing client_config.lua and unable to create it", 0)
    end

    handle.write(DEFAULT_CONFIG_CONTENT)
    handle.close()

    local ok, config = pcall(require, "client_config")
    if not ok then
        error(config, 0)
    end

    print("Created default client_config.lua; edit it to change modem side/primary file")
    return config
end

local CONFIG = load_or_create_config()

local function is_wireless_modem(side)
    if not side or peripheral.getType(side) ~= "modem" then
        return false
    end

    local ok, res = pcall(peripheral.call, side, "isWireless")
    return ok and res == true
end

local function ensure_modem_open(preferred_side)
    if not is_wireless_modem(preferred_side) then
        error(("No wireless/ender modem found on %s; update client_config.side"):format(preferred_side or "<unspecified>"), 0)
    end

    rednet.open(preferred_side)
    if rednet.isOpen(preferred_side) then
        return preferred_side
    end

    error(("Failed to open modem on %s"):format(preferred_side), 0)
end

ensure_modem_open(CONFIG.side)

local args = { ... }
local is_setup = args[1] == "setup"

local function parse_file_list(content)
    local loader, err = load(content, FILE_LIST_NAME, "t", {})
    if not loader then
        error(("Unable to parse %s: %s"):format(FILE_LIST_NAME, tostring(err)), 0)
    end

    local ok, result = pcall(loader)
    if not ok then
        error(("Failed to load %s: %s"):format(FILE_LIST_NAME, tostring(result)), 0)
    end
    if type(result) ~= "table" then
        error(("Invalid %s contents (expected table)"):format(FILE_LIST_NAME), 0)
    end

    return result
end

local function resolve_scope(file_list)
    local primary_key = CONFIG.primary_file
    local base_primary = primary_key:gsub("%.lua$", "")

    local scope = CONFIG.scope or SCOPE_ALIASES[primary_key] or SCOPE_ALIASES[base_primary] or base_primary
    if type(scope) ~= "string" or scope == "" then
        error("Unable to determine scope from client_config", 0)
    end

    if not file_list[scope] then
        error(("Scope '%s' missing from %s"):format(scope, FILE_LIST_NAME), 0)
    end

    return scope
end

local function build_fetch_plan(file_list, scope)
    local plan = {}
    local seen = {}

    local function add(scope_name)
        local files = file_list[scope_name]
        if not files then
            return
        end

        for _, file in ipairs(files) do
            local filename = file.filename
            local key = ("%s:%s"):format(scope_name, filename)
            if not seen[key] then
                plan[#plan + 1] = { scope = scope_name, filename = filename }
                seen[key] = true
            end
        end
    end

    add("shared")
    add(scope)

    return plan
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

local function fetch_file(request, server_id)
    rednet.send(server_id, request, REQUEST_PROTOCOL)
    while true do
        local id, payload = rednet.receive(REPLY_PROTOCOL, 5)
        if not id then
            error("No reply from SG server", 0)
        end
        if id == server_id then
            if type(payload) ~= "table" then
                error("Invalid file payload (expected table)", 0)
            end
            if payload.error then
                error(("Server error for %s/%s: %s"):format(request.scope, request.filename, tostring(payload.error)), 0)
            end
            if type(payload.dst) ~= "string" or type(payload.data) ~= "string" then
                error(("Invalid file payload for %s/%s"):format(request.scope, request.filename), 0)
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
    return shell.run(CONFIG.primary_file)
end

local server_id = find_server_with_retry()

if not server_id then
    print("Unable to find SGServer on network; running cached files")
    return run_primary()
end

local ok_manifest, manifest_file = pcall(fetch_file, { scope = "shared", filename = FILE_LIST_NAME }, server_id)
if not ok_manifest then
    print("Failed to fetch manifest; running cached files: " .. tostring(manifest_file))
    return run_primary()
end

local ok_list, file_list = pcall(parse_file_list, manifest_file.data)
if not ok_list then
    print("Failed to parse manifest; running cached files: " .. tostring(file_list))
    return run_primary()
end

local ok_scope, scope = pcall(resolve_scope, file_list)
if not ok_scope then
    print("Failed to resolve scope; running cached files: " .. tostring(scope))
    return run_primary()
end

local files_to_fetch = build_fetch_plan(file_list, scope)

local fetched_files = {}
for _, request in ipairs(files_to_fetch) do
    local ok, file_or_err = pcall(fetch_file, request, server_id)
    if not ok then
        print(("Failed to fetch %s/%s; running cached files: %s"):format(request.scope, request.filename, tostring(file_or_err)))
        return run_primary()
    end
    fetched_files[#fetched_files + 1] = file_or_err
end

for _, file in ipairs(fetched_files) do
    write_file(file)
end

if is_setup then
    print("Done! Update complete; edit settings as needed before running")
else
    run_primary()
end
