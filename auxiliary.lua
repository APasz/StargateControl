package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local energy = peripheral.find("energyDetector")
local player = peripheral.find("playerDetector")

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
    current_limit = nil,
    manual_limit = nil,
    last_transfer_rate = nil,
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

local PLAYER_LIMIT = 70000
local MAX_LIMIT = 999999999
local MANUAL_STEP = 10000
local BUTTON_LINE = 6
local BUTTONS = {
    { key = "dec", label = "-10k" },
    { key = "inc", label = "+10k" },
    { key = "max", label = "max" },
    { key = "reset", label = "reset" },
}
local button_bounds = {}

local TRANSFER_LIMIT_INTERVAL = 15
local last_limit_update = nil

local function current_time_seconds()
    if os.epoch then
        return os.epoch("utc") / 1000
    end

    return os.clock()
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

local function render_limit_line()
    local parts = {}

    if STATE.last_transfer_rate then
        parts[#parts + 1] = "Transfer Rate: " .. (format_energy(STATE.last_transfer_rate) or tostring(STATE.last_transfer_rate))
    end
    if STATE.current_limit then
        parts[#parts + 1] = "Limit: " .. (format_energy(STATE.current_limit) or tostring(STATE.current_limit))
    end

    SG_UTILS.update_line(table.concat(parts, " | "), 5)
end

local function set_transfer_limit(limit, opts)
    local numeric_limit = tonumber(limit)
    if numeric_limit == nil or not energy or type(energy.setTransferRateLimit) ~= "function" then
        return
    end

    local ok, err = pcall(energy.setTransferRateLimit, numeric_limit)
    if not ok then
        print("Failed to set transfer rate limit: " .. tostring(err))
        return
    end

    STATE.current_limit = numeric_limit
    last_limit_update = current_time_seconds()

    if opts and opts.manual ~= nil then
        if opts.manual then
            STATE.manual_limit = numeric_limit
        else
            STATE.manual_limit = nil
        end
    end

    render_limit_line()
end

local function compute_auto_limit()
    local onlinePlayers = player.getOnlinePlayers() or {}

    if #onlinePlayers > 0 then
        return PLAYER_LIMIT
    end

    return MAX_LIMIT
end

local function apply_auto_limit(force)
    if STATE.manual_limit and not force then
        return
    end

    local now = current_time_seconds()
    if not force and last_limit_update and (now - last_limit_update) < TRANSFER_LIMIT_INTERVAL then
        return
    end

    set_transfer_limit(compute_auto_limit())
end

local function render_buttons()
    local labels = {}
    for _, btn in ipairs(BUTTONS) do
        labels[#labels + 1] = "[" .. btn.label .. "]"
    end

    local buttons_text = table.concat(labels, " ")
    local width = select(1, SG_UTILS.get_monitor_size())
    if width < #buttons_text then
        SG_UTILS.update_line("Controls unavailable", BUTTON_LINE)
        button_bounds = {}
        return
    end

    SG_UTILS.update_line(buttons_text, BUTTON_LINE)

    button_bounds = {}
    local cursor = 1
    for _, btn in ipairs(BUTTONS) do
        local label = "[" .. btn.label .. "]"
        local start_x = cursor
        local end_x = cursor + #label - 1
        button_bounds[btn.key] = { start_x = start_x, end_x = end_x }
        cursor = end_x + 2
    end
end

local function reset_limit()
    STATE.manual_limit = nil
    apply_auto_limit(true)
end

local function adjust_manual_limit(delta)
    local base = STATE.manual_limit or STATE.current_limit or compute_auto_limit()
    local new_limit = math.max(0, base + delta)
    set_transfer_limit(new_limit, { manual = true })
end

local function handle_button_press(action)
    if action == "dec" then
        adjust_manual_limit(-MANUAL_STEP)
    elseif action == "inc" then
        adjust_manual_limit(MANUAL_STEP)
    elseif action == "max" then
        set_transfer_limit(MAX_LIMIT, { manual = true })
    elseif action == "reset" then
        reset_limit()
    end
end

local function handle_monitor_touch(x, y)
    if not (x and y) or math.floor(y) ~= BUTTON_LINE then
        return
    end

    for action, bounds in pairs(button_bounds) do
        if x >= bounds.start_x and x <= bounds.end_x then
            handle_button_press(action)
            return
        end
    end
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
    render_limit_line()
    render_buttons()
    STATE.status = "no_modem"
end

local function render_waiting(modem_side)
    if STATE.status == "waiting" and STATE.modem_side == modem_side then
        return
    end

    SG_UTILS.prepare_monitor(monitor_scale, true)
    SG_UTILS.reset_line_offset()
    SG_UTILS.update_line("Waiting for rednet messages", 1)
    render_limit_line()
    render_buttons()
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
    local trans_rate = nil
    sg_energy = tonumber(payload.sg_energy)
    inf_energy = tonumber(payload.inf_energy)
    inf_capacity = tonumber(payload.inf_capacity)
    inf_target = tonumber(payload.inf_target)
    trans_rate = tonumber(energy.getTransferRate())
    STATE.last_transfer_rate = trans_rate

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
    render_limit_line()
    render_buttons()

    STATE.status = "message"
end

local function maybe_limit()
    apply_auto_limit()
end

local function rednet_loop()
    while true do
        maybe_limit()

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

local function touch_loop()
    while true do
        local ev, _, x, y = os.pullEvent()
        if ev == "monitor_touch" then
            handle_monitor_touch(x, y)
        end
    end
end

local function main()
    parallel.waitForAny(rednet_loop, touch_loop)
end

main()
