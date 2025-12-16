package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
    modem_side = "back",
    -- side with wireless/ender modem; nil to auto-detect
    protocol = "sg_aux",
    -- optional rednet protocol filter; nil listens to any protocol
    monitor_scale = 1,
    -- monitor text scale
    receive_timeout = 5,
    -- seconds between listen heartbeats (used to refresh the modem status)
}
]]

local function load_or_create_settings()
    if fs.exists(SETTINGS_PATH) then
        local ok, config = pcall(require, "settings")
        if ok then
            return config
        end
        error(config, 0)
    end

    local handle = fs.open(SETTINGS_PATH, "w")
    if not handle then
        error("Missing settings.lua and unable to create it", 0)
    end

    handle.write(DEFAULT_SETTINGS_CONTENT)
    handle.close()

    local ok, config = pcall(require, "settings")
    if not ok then
        error(config, 0)
    end

    print("Created default settings.lua")
    return config
end
local SG_SETTINGS = load_or_create_settings()

local STATE = {
    modem_side = nil,
    status = nil,
}

local monitor_scale = tonumber(SG_SETTINGS.monitor_scale) or 0.5
if monitor_scale <= 0 then
    monitor_scale = 0.5
end
local listen_timeout = tonumber(SG_SETTINGS.receive_timeout) or 5
if listen_timeout < 0 then
    listen_timeout = 0
end
local protocol_filter = SG_SETTINGS.protocol

local warned_config_modem = false

local function serialise_value(value)
    if type(value) == "string" then
        return value
    end

    local serialise = textutils.serialise
    if serialise then
        local ok, result = pcall(serialise, value, { compact = true, allow_repetitions = true })
        if ok and type(result) == "string" then
            return result
        end

        ok, result = pcall(serialise, value)
        if ok and type(result) == "string" then
            return result
        end
    end

    return tostring(value)
end

local function format_energy(value)
    if type(value) ~= "number" then
        return nil
    end

    local suffixes = { "", "k", "M", "G", "T", "P" }
    local sign = value < 0 and "-" or ""
    local magnitude = math.abs(value)
    local idx = 1

    while magnitude >= 1000 and idx < #suffixes do
        magnitude = magnitude / 1000
        idx = idx + 1
    end

    local fmt
    if magnitude >= 100 or idx == 1 then
        fmt = "%.0f"
    elseif magnitude >= 10 then
        fmt = "%.1f"
    else
        fmt = "%.2f"
    end

    return string.format("%s" .. fmt .. "%s", sign, magnitude, suffixes[idx])
end

local function message_to_lines(value)
    local text = serialise_value(value or "")
    local lines = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then
        lines[1] = ""
    end
    return lines
end

local function open_modem()
    if STATE.modem_side and rednet.isOpen(STATE.modem_side) then
        return STATE.modem_side
    end

    local configured = SG_SETTINGS.modem_side
    if configured then
        if peripheral.getType(configured) == "modem" then
            local ok, err = pcall(rednet.open, configured)
            if not ok then
                print("Failed to open modem on " .. configured .. ": " .. tostring(err))
            end
            if rednet.isOpen(configured) then
                STATE.modem_side = configured
                return configured
            end
        elseif not warned_config_modem then
            print("Configured modem_side not found: " .. tostring(configured))
            warned_config_modem = true
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, err = pcall(rednet.open, name)
            if not ok then
                print("Failed to open modem on " .. tostring(name) .. ": " .. tostring(err))
            end
            if rednet.isOpen(name) then
                STATE.modem_side = name
                warned_config_modem = false
                return name
            end
        end
    end

    STATE.modem_side = nil
    return nil
end

local function render_no_modem()
    if STATE.status == "no_modem" then
        return
    end

    SG_UTILS.prepare_monitor(monitor_scale, true)
    SG_UTILS.reset_line_offset()
    SG_UTILS.update_line("No modem detected", 1)
    STATE.status = "no_modem"
end

local function render_waiting(modem_side)
    if STATE.status == "waiting" and STATE.modem_side == modem_side then
        return
    end

    SG_UTILS.prepare_monitor(monitor_scale, true)
    SG_UTILS.reset_line_offset()
    SG_UTILS.update_line("Waiting for rednet messages", 1)
    STATE.status = "waiting"
end

local function render_message(modem_side, sender, protocol, payload)
    SG_UTILS.prepare_monitor(monitor_scale, true)
    SG_UTILS.reset_line_offset()
    local energy = nil
    local capacity = nil
    local target = nil
    if type(payload) == "table" then
        energy = tonumber(payload.energy or 0)
        capacity = tonumber(payload.capacity or 0)
        target = tonumber(payload.target or 0)
    end

    if energy then
        SG_UTILS.update_line("Energy: " .. (format_energy(energy) or tostring(energy)), 1)
    end
    if capacity then
        SG_UTILS.update_line("Capacity: " .. (format_energy(capacity) or tostring(capacity)), 2)
    end
    if target then
        SG_UTILS.update_line("Target: " .. (format_energy(target) or tostring(target)), 3)
    end

    STATE.status = "message"
end

local function main()
    while true do
        local modem_side = open_modem()
        if not modem_side then
            render_no_modem()
            sleep(2)
        else
            if STATE.status ~= "message" then
                render_waiting(modem_side)
            end

            local id, payload, protocol = rednet.receive(protocol_filter, listen_timeout)
            if id then
                render_message(modem_side, id, protocol, payload)
            end
        end
    end
end

main()
