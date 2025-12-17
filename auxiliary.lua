package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
    site = nil,
    -- optional site name to filter energy updates (falls back to computer label suffix)
    protocol = "sg_aux",
    -- optional rednet protocol filter; nil listens to any protocol
    monitor_scale = 1,
    -- monitor text scale
    receive_timeout = 5,
    -- seconds between listen heartbeats (used to refresh the modem status)
}
]]

local function get_client_config_side()
    local ok, cfg = pcall(require, "client_config")
    if not ok or type(cfg) ~= "table" then
        return nil
    end
    if type(cfg.side) == "string" then
        return cfg.side
    end
    return nil
end
local CLIENT_MODEM_SIDE = get_client_config_side()

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
local AUX_SETTINGS = load_or_create_settings()

local _, LOCAL_SITE = SG_UTILS.get_site(AUX_SETTINGS.site)

local STATE = {
    modem_side = nil,
    status = nil,
}

local monitor_scale = tonumber(AUX_SETTINGS.monitor_scale) or 0.5
if monitor_scale <= 0 then
    monitor_scale = 0.5
end
local listen_timeout = tonumber(AUX_SETTINGS.receive_timeout) or 5
if listen_timeout < 0 then
    listen_timeout = 0
end
local protocol_filter = AUX_SETTINGS.protocol

local warned_config_modem = false

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

local function open_modem()
    if STATE.modem_side and rednet.isOpen(STATE.modem_side) then
        return STATE.modem_side
    end

    if CLIENT_MODEM_SIDE then
        if peripheral.getType(CLIENT_MODEM_SIDE) == "modem" then
            local ok, err = pcall(rednet.open, CLIENT_MODEM_SIDE)
            if not ok then
                print("Failed to open modem on " .. CLIENT_MODEM_SIDE .. ": " .. tostring(err))
            end
            if rednet.isOpen(CLIENT_MODEM_SIDE) then
                STATE.modem_side = CLIENT_MODEM_SIDE
                return CLIENT_MODEM_SIDE
            end
        elseif not warned_config_modem then
            print("Configured modem side not found: " .. tostring(CLIENT_MODEM_SIDE))
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
    if type(payload) ~= "table" or payload.type ~= "energy" then
        return
    end

    if LOCAL_SITE then
        local _, remote_site = SG_UTILS.normalise_name(payload.site)
        if not remote_site or remote_site ~= LOCAL_SITE then
            return
        end
    end

    SG_UTILS.prepare_monitor(monitor_scale, true)
    SG_UTILS.reset_line_offset()
    local sg_energy = nil
    local inf_energy = nil
    local inf_capacity = nil
    local inf_target = nil
    sg_energy = tonumber(payload.sg_energy)
    inf_energy = tonumber(payload.inf_energy)
    inf_capacity = tonumber(payload.inf_capacity)
    inf_target = tonumber(payload.inf_target)

    if sg_energy ~= nil then
        SG_UTILS.update_line("Stargate Energy: " .. (format_energy(sg_energy) or tostring(sg_energy)), 1)
    end
    if inf_energy ~= nil then
        SG_UTILS.update_line("Interface Energy: " .. (format_energy(inf_energy) or tostring(inf_energy)), 2)
    end
    if inf_capacity ~= nil then
        SG_UTILS.update_line("Interface Capacity: " .. (format_energy(inf_capacity) or tostring(inf_capacity)), 3)
    end
    if inf_target ~= nil then
        SG_UTILS.update_line("Interface Target: " .. (format_energy(inf_target) or tostring(inf_target)), 4)
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
