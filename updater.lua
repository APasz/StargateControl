-- Downloads StargateControl files from GitHub into disk/*.lua

if not http then
    error("HTTP API is disabled")
end

local base_url = "https://raw.githubusercontent.com/APasz/StargateControl/main/"
local target_dir = "disk"

local files = {
    "dial.lua",
    "alarm.lua",
    "utils.lua",
    "settings.lua",
    "server.lua",
    "client.lua",
    "updater.lua",
}

if not fs.exists(target_dir) or not fs.isDir(target_dir) then
    error("No '" .. target_dir .. "' directory")
end

local function download_file(name, destination)
    local url = base_url .. name
    print("Fetching " .. name .. "...")
    local res, err = http.get(url)
    if not res then
        print("  Failed: " .. tostring(err))
        return false
    end

    local content = res.readAll()
    res.close()

    local path = destination or fs.combine(target_dir, name)
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
