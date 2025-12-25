-- Downloads StargateControl files from GitHub into disk/*.lua (or disk2/..., per file_list)

if not http then
    error("HTTP API is disabled")
end

local BASE_URL = "https://raw.githubusercontent.com/APasz/StargateControl/main/"
local COMMITS_API_URL = "https://api.github.com/repos/APasz/StargateControl/commits/main"
local DEFAULT_TARGET_DIR = "disk"
local FILE_LIST_PATH = "sync/file_list.lua"
local UPDATER_PATH = "sync/updater.lua"

local args = { ... }
local self_only = args[1] == "self" or args[1] == "manifest"

local function download(url, headers)
    local res, err = http.get(url, headers)
    if not res then
        return nil, err
    end

    local content = res.readAll()
    res.close()
    return content, nil
end

local function fetch_latest_commit_name()
    local parse_json = textutils.unserialiseJSON
    if not parse_json then
        return nil, "JSON parser unavailable"
    end

    local headers = {
        ["User-Agent"] = "StargateControlUpdater",
        Accept = "application/vnd.github+json",
    }

    local content, err = download(COMMITS_API_URL, headers)
    if not content then
        return nil, err
    end

    local ok, data = pcall(parse_json, content)
    if not ok or type(data) ~= "table" then
        return nil, "Unexpected API response"
    end

    local message = data.commit and data.commit.message
    if type(message) ~= "string" then
        return nil, "Commit message unavailable"
    end

    local subject = message:match("([^\r\n]+)") or message
    return subject
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

local function add_expected_file(expected, base_dir, path)
    local base = base_dir or DEFAULT_TARGET_DIR
    local list = expected[base]
    if not list then
        list = {}
        expected[base] = list
    end
    list[path] = true
end

local function build_expected_files(file_list)
    local expected = {}

    add_expected_file(expected, DEFAULT_TARGET_DIR, FILE_LIST_PATH)
    for _, scope_files in pairs(file_list) do
        for _, file in ipairs(scope_files) do
            add_expected_file(expected, file.disk, file.git)
        end
    end

    return expected
end

local function collect_disk_files(base_dir)
    local files = {}

    local function scan(rel_path)
        local full_path = rel_path == "" and base_dir or fs.combine(base_dir, rel_path)
        for _, name in ipairs(fs.list(full_path)) do
            local child_rel = rel_path == "" and name or fs.combine(rel_path, name)
            local child_full = fs.combine(base_dir, child_rel)
            if fs.isDir(child_full) then
                scan(child_rel)
            else
                files[#files + 1] = child_rel
            end
        end
    end

    if fs.exists(base_dir) and fs.isDir(base_dir) then
        scan("")
    end

    return files
end

local function clean_disk(base_dir, expected)
    local removed = 0
    local files = collect_disk_files(base_dir)

    for _, rel_path in ipairs(files) do
        if not expected[rel_path] then
            local full_path = fs.combine(base_dir, rel_path)
            local ok, err = pcall(fs.delete, full_path)
            if ok then
                print("Removed: " .. full_path)
                removed = removed + 1
            else
                print(("Failed to remove %s: %s"):format(full_path, tostring(err)))
            end
        end
    end

    return removed
end

local function clean_disks(expected)
    local removed_total = 0
    for base_dir, allowed in pairs(expected) do
        removed_total = removed_total + clean_disk(base_dir, allowed)
    end
    if removed_total > 0 then
        print(("Cleanup removed %d file(s)."):format(removed_total))
    end
end

local function drive_label_for(path, fallback)
    local drive = fs.getDrive(path)
    if drive and drive ~= "" then
        return drive
    end
    return fallback or path
end

local function has_space_for_write(target_path, content_size, drive_label)
    local existing_size = 0
    if fs.exists(target_path) and not fs.isDir(target_path) then
        existing_size = fs.getSize(target_path)
    end

    local needed = content_size - existing_size
    if needed < 0 then
        needed = 0
    end

    local free_space = fs.getFreeSpace(target_path)
    if free_space and needed > free_space then
        print(("Failed; %s: disk '%s' is full (need %d, free %d)"):format(target_path, drive_label, needed, free_space))
        return false
    end

    return true
end

local function download_file(path, destination, target_dir)
    local url = BASE_URL .. path
    local content, err = download(url)
    if not content then
        print("Failed; " .. path .. ": " .. tostring(err))
        return false
    end

    local base_dir = target_dir or DEFAULT_TARGET_DIR
    local target_path = destination or fs.combine(base_dir, path)
    local drive_label = drive_label_for(target_path, base_dir)
    local dir = fs.getDir(target_path)
    if dir and dir ~= "" then
        local ok, mk_err = pcall(fs.makeDir, dir)
        if not ok then
            print(("Failed to create %s on disk '%s': %s"):format(dir, drive_label, tostring(mk_err)))
            return false
        end
    end

    if not has_space_for_write(target_path, #content, drive_label) then
        return false
    end

    local f, open_err = fs.open(target_path, "w")
    if not f then
        local suffix = open_err and (": " .. tostring(open_err)) or "."
        print(("Failed to open %s for writing (disk '%s')%s"):format(target_path, drive_label, suffix))
        return false
    end

    local ok, write_err = pcall(function()
        f.write(content)
    end)
    f.close()
    if not ok then
        local err_text = tostring(write_err)
        if err_text:lower():find("space", 1, true) then
            print(("Failed; %s: disk '%s' is full."):format(target_path, drive_label))
        else
            print(("Failed to write %s on disk '%s': %s"):format(target_path, drive_label, err_text))
        end
        return false
    end

    print("Saved: " .. target_path)
    return true
end

local function collect_files(file_list)
    local files = {}
    local seen = {}

    for _, scope_files in pairs(file_list) do
        for _, file in ipairs(scope_files) do
            local path = file.git
            if path ~= FILE_LIST_PATH then
                local disk = file.disk
                local key = ("%s:%s"):format(disk or "", path)
                if not seen[key] then
                    files[#files + 1] = { path = path, disk = disk }
                    seen[key] = true
                end
            end
        end
    end

    return files
end

local function validate_target_dirs(files)
    local missing = {}

    if not fs.exists(DEFAULT_TARGET_DIR) or not fs.isDir(DEFAULT_TARGET_DIR) then
        missing[DEFAULT_TARGET_DIR] = true
    end

    for _, file in ipairs(files) do
        local base_dir = file.disk or DEFAULT_TARGET_DIR
        if not fs.exists(base_dir) or not fs.isDir(base_dir) then
            missing[base_dir] = true
        end
    end

    if next(missing) then
        local dirs = {}
        for dir in pairs(missing) do
            dirs[#dirs + 1] = dir
        end
        error("Missing target disk directories: " .. table.concat(dirs, ", "), 0)
    end
end

local function resolve_disk_for_file(file)
    return file.disk or DEFAULT_TARGET_DIR
end

local function download_files(files)
    local ok = true
    for _, file in ipairs(files) do
        local disk = resolve_disk_for_file(file)
        ok = download_file(file.path, nil, disk) and ok
    end
    return ok
end

local commit_name, commit_err = fetch_latest_commit_name()

local success = true
if self_only then
    validate_target_dirs({})
    success = download_file(FILE_LIST_PATH, nil, DEFAULT_TARGET_DIR) and success
else
    local file_list = load_file_list()
    local files = collect_files(file_list)
    validate_target_dirs(files)
    clean_disks(build_expected_files(file_list))
    success = download_file(FILE_LIST_PATH, nil, DEFAULT_TARGET_DIR) and success
    success = download_files(files) and success
end

success = download_file(UPDATER_PATH, "updater.lua") and success

if success then
    print("Done!")
else
    print("Done (with errors; see above)")
end
if commit_name then
    print(commit_name)
elseif commit_err then
    print("Latest commit unavailable: " .. tostring(commit_err))
end
