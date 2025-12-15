-- Downloads StargateControl files from GitHub into disk/*.lua

if not http then
    error("HTTP API is disabled")
end

local BASE_URL = "https://raw.githubusercontent.com/APasz/StargateControl/main/"
local TARGET_DIR = "disk"
local FILE_LIST_PATH = "sync/file_list.lua"
local UPDATER_PATH = "sync/updater.lua"

if not fs.exists(TARGET_DIR) or not fs.isDir(TARGET_DIR) then
    error("No '" .. TARGET_DIR .. "' directory")
end

local function download(url)
    local res, err = http.get(url)
    if not res then
        return nil, err
    end

    local content = res.readAll()
    res.close()
    return content, nil
end

local function load_file_list()
    local content, err = download(BASE_URL .. FILE_LIST_PATH)
    if not content then
        error("Failed to download file list: " .. tostring(err), 0)
    end

    local chunk, load_err = load(content, FILE_LIST_PATH, "t", {})
    if not chunk then
        error("Unable to parse file list: " .. tostring(load_err), 0)
    end

    local ok, result = pcall(chunk)
    if not ok then
        error("Failed to load file list: " .. tostring(result), 0)
    end

    if type(result) ~= "table" then
        error("Invalid file list contents", 0)
    end

    return result
end

local function download_file(path, destination)
    local url = BASE_URL .. path
    local content, err = download(url)
    if not content then
        print("Failed; " .. path .. ": " .. tostring(err))
        return false
    end

    local target_path = destination or fs.combine(TARGET_DIR, path)
    local dir = fs.getDir(target_path)
    if dir and dir ~= "" then
        fs.makeDir(dir)
    end

    local f = fs.open(target_path, "w")
    if not f then
        print("Failed to open " .. target_path .. " for writing.")
        return false
    end
    f.write(content)
    f.close()

    print("Saved: " .. target_path)
    return true
end

local function collect_paths(file_list)
    local paths = {}
    for _, files in pairs(file_list) do
        for _, file in ipairs(files) do
            paths[file.git] = true
        end
    end
    return paths
end

local file_list = load_file_list()
local paths = collect_paths(file_list)

local success = true

for path in pairs(paths) do
    success = download_file(path) and success
end

success = download_file(UPDATER_PATH, "updater.lua") and success

if success then
    print("Done!")
else
    print("Done (with errors; see above)")
end
