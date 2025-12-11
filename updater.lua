-- Downloads StargateControl files from GitHub into disk/*.lua

if not http then
    error("HTTP API is disabled")
end

local BASE_URL = "https://raw.githubusercontent.com/APasz/StargateControl/main/"
local TARGET_DIR = "disk"

local files = {
    "dial.lua",
    "alarm.lua",
    "utils.lua",
    "settings.lua",
    "addresses.lua",
    "server.lua",
    "client.lua",
    "client_config.lua",
    "updater.lua",
}

if not fs.exists(TARGET_DIR) or not fs.isDir(TARGET_DIR) then
    error("No '" .. TARGET_DIR .. "' directory")
end

local function download_file(name, destination)
    local url = BASE_URL .. name
    print("Fetching " .. name .. "...")
    local res, err = http.get(url)
    if not res then
        print("  Failed: " .. tostring(err))
        return false
    end

    local content = res.readAll()
    res.close()

    local path = destination or fs.combine(TARGET_DIR, name)
    local f = fs.open(path, "w")
    if not f then
        print("  Failed to open " .. path .. " for writing.")
        return false
    end
    f.write(content)
    f.close()

    print("  Saved to " .. path)
    return true
end

for _, name in ipairs(files) do
    download_file(name)
end

download_file("updater.lua", "updater.lua")

print("Done!")
