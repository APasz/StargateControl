package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")
local INF_RS = SG_UTILS.get_inf_rs()

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
    side_toggle = "front",
    side_input = nil,
    -- optional redstone input to trigger alarms (leave nil to rely on rednet only)
    phase_sides = { "left", "top", "right" },
    flash_delay = 0.28,
    status_flash_duration = 0.25,
    status_flash_interval = 0.75,
    debounce_reads = 1,
    alarm_protocol = "sg_alarm",
    -- rednet protocol used for incoming-wormhole alarms
    site = nil,
    -- optional site name to filter alarm broadcasts (falls back to computer label suffix)
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

    print("Created default settings.lua; edit it to change site, etc")
    return config
end
local AL_SETTINGS = load_or_create_settings()
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
local _, LOCAL_SITE = SG_UTILS.get_site(AL_SETTINGS.site)

local MODEM_STATE = {
    side = nil,
    warned_config = false,
    warned_missing = false,
}
local ALARM_PROTOCOL = AL_SETTINGS.alarm_protocol or "sg_alarm"
local remote_alarm_active = nil
local debounce_reads = tonumber(AL_SETTINGS.debounce_reads) or 1

local phase_timer = nil
local status_flash_timer = nil
local status_flash_visible = false
local phase_index = 1
local alarm_active = false
local manual_cancelled = false
local toggle_enabled = true
local button_regions = {}
local last_raw_input = nil
local stable_input = false
local input_stable_count = 0

local function set_toggle(active)
    local rs = SG_UTILS.get_inf_rs()
    if rs and AL_SETTINGS.side_toggle then
        rs.setOutput(AL_SETTINGS.side_toggle, active)
    end
end
local function open_alarm_modem()
    if MODEM_STATE.side and rednet.isOpen(MODEM_STATE.side) then
        return MODEM_STATE.side
    end

    if CLIENT_MODEM_SIDE then
        if peripheral.getType(CLIENT_MODEM_SIDE) == "modem" then
            local ok, err = pcall(rednet.open, CLIENT_MODEM_SIDE)
            if not ok then
                print("Alarm modem open failed on " .. tostring(CLIENT_MODEM_SIDE) .. ": " .. tostring(err))
            end
            if rednet.isOpen(CLIENT_MODEM_SIDE) then
                MODEM_STATE.side = CLIENT_MODEM_SIDE
                MODEM_STATE.warned_missing = false
                return CLIENT_MODEM_SIDE
            end
        elseif not MODEM_STATE.warned_config then
            print("Configured alarm modem side not found: " .. tostring(CLIENT_MODEM_SIDE))
            MODEM_STATE.warned_config = true
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, err = pcall(rednet.open, name)
            if not ok then
                print("Alarm modem open failed on " .. tostring(name) .. ": " .. tostring(err))
            end
            if rednet.isOpen(name) then
                MODEM_STATE.side = name
                MODEM_STATE.warned_config = false
                MODEM_STATE.warned_missing = false
                return name
            end
        end
    end

    if not MODEM_STATE.warned_missing then
        print("No modem available for alarm rednet")
        MODEM_STATE.warned_missing = true
    end
    MODEM_STATE.side = nil
    return nil
end

local function clear_phase_outputs()
    local rs = SG_UTILS.get_inf_rs()
    if not rs then
        return
    end
    for _, side in ipairs(AL_SETTINGS.phase_sides) do
        rs.setOutput(side, false)
    end
end

local function set_phase(target)
    local rs = SG_UTILS.get_inf_rs()
    if not rs then
        return
    end
    for _, side in ipairs(AL_SETTINGS.phase_sides) do
        rs.setOutput(side, side == target)
    end
end

local function update_toggle_output()
    set_toggle(alarm_active and toggle_enabled)
end

local function draw_button(mon, label, y)
    if not mon then
        return nil
    end
    mon.setCursorPos(1, y)
    mon.write(label)
    return { x1 = 1, y1 = y, x2 = #label, y2 = y }
end

local function should_flash_status(input_active)
    local active_input = input_active
    if active_input == nil then
        active_input = stable_input
        if active_input == nil then
            active_input = SG_UTILS.rs_input(AL_SETTINGS.side_input)
        end
    end
    return alarm_active or (manual_cancelled and active_input)
end

local function update_status_flash_timer(force_flash_state)
    local should_flash = force_flash_state
    if should_flash == nil then
        should_flash = should_flash_status()
    end

    if should_flash then
        if not status_flash_timer then
            local delay = status_flash_visible and AL_SETTINGS.status_flash_duration or AL_SETTINGS.status_flash_interval
            status_flash_timer = os.startTimer(delay)
        end
    else
        if status_flash_timer then
            os.cancelTimer(status_flash_timer)
            status_flash_timer = nil
        end
        status_flash_visible = false
    end
end

local function draw_status(mon, status, should_flash)
    if not mon then
        return
    end

    local status_line = "Alarm: " .. status
    mon.setCursorPos(1, 1)

    local flashing = should_flash and status_flash_visible and mon.isColour()
    if flashing then
        SG_UTILS.set_text_colour(colours.red)
    end

    mon.write(status_line)
    if flashing then
        SG_UTILS.reset_text_colour()
    end
end

local function render_screen()
    local mon = SG_UTILS.get_inf_mon()
    if not mon then
        return
    end

    SG_UTILS.prepare_monitor(0.5, true)

    local input_active = SG_UTILS.rs_input(AL_SETTINGS.side_input)
    local status
    local status_should_flash
    if alarm_active then
        status = "ACTIVE"
        status_should_flash = true
    elseif manual_cancelled and input_active then
        status = "SILENCED"
        status_should_flash = true
    else
        status = "IDLE"
        status_should_flash = false
    end

    if status_should_flash then
        if not status_flash_timer and not status_flash_visible then
            status_flash_visible = true
        end
    else
        status_flash_visible = false
    end

    draw_status(mon, status, status_should_flash)
    update_status_flash_timer(status_should_flash)
    mon.setCursorPos(1, 2)
    mon.write("Siren: " .. (toggle_enabled and "ON" or "OFF"))

    button_regions.toggle = draw_button(mon, "[ TOGGLE SIREN ]", 4)
    button_regions.cancel = draw_button(mon, "[ CANCEL ALARM ]", 5)
end

local function start_alarm()
    if alarm_active then
        return
    end
    alarm_active = true
    phase_index = 1
    set_phase(AL_SETTINGS.phase_sides[phase_index])
    update_toggle_output()
    phase_timer = os.startTimer(AL_SETTINGS.flash_delay)
    render_screen()
end

local function stop_alarm()
    if phase_timer then
        os.cancelTimer(phase_timer)
    end
    phase_timer = nil
    alarm_active = false
    clear_phase_outputs()
    set_toggle(false)
    render_screen()
end

local function read_input_active(raw_override)
    if raw_override ~= nil then
        return raw_override
    end

    local redstone_active = SG_UTILS.rs_input(AL_SETTINGS.side_input)
    if remote_alarm_active == nil then
        return redstone_active
    end

    return remote_alarm_active or redstone_active
end

local function refresh_input_state(raw_override, skip_debounce)
    local input_active = read_input_active(raw_override)
    if skip_debounce then
        stable_input = input_active
        last_raw_input = input_active
        input_stable_count = debounce_reads
    else
        if input_active ~= last_raw_input then
            input_stable_count = 1
            last_raw_input = input_active
        else
            input_stable_count = input_stable_count + 1
        end
        if input_active ~= stable_input and input_stable_count >= debounce_reads then
            stable_input = input_active
        end
    end

    if stable_input and not manual_cancelled then
        start_alarm()
    else
        if not stable_input then
            manual_cancelled = false
            toggle_enabled = true
        end
        stop_alarm()
    end
end

local function advance_phase()
    if not alarm_active then
        return
    end
    phase_index = (phase_index % #AL_SETTINGS.phase_sides) + 1
    set_phase(AL_SETTINGS.phase_sides[phase_index])
end

local function ensure_alarm_modem_open()
    if MODEM_STATE.side and rednet.isOpen(MODEM_STATE.side) then
        return MODEM_STATE.side
    end
    return open_alarm_modem()
end

local function site_matches(message_site)
    if not (LOCAL_SITE and message_site) then
        return true
    end
    local _, incoming_site = SG_UTILS.normalise_name(message_site)
    return incoming_site == nil or incoming_site == LOCAL_SITE
end

local function handle_rednet_alarm(_, payload, protocol)
    if protocol ~= ALARM_PROTOCOL then
        return
    end
    if type(payload) ~= "table" or payload.type ~= "incoming_alarm" then
        return
    end
    if not site_matches(payload.site) then
        return
    end
    if payload.outbound == true then
        return
    end

    remote_alarm_active = payload.active == true
    refresh_input_state(nil, true)
end

local function handle_timer(id)
    if id == phase_timer then
        if not alarm_active then
            phase_timer = nil
            return
        end
        advance_phase()
        phase_timer = os.startTimer(AL_SETTINGS.flash_delay)
    elseif id == status_flash_timer then
        status_flash_timer = nil
        if not should_flash_status() then
            status_flash_visible = false
            render_screen()
            return
        end

        status_flash_visible = not status_flash_visible
        local delay = status_flash_visible and AL_SETTINGS.status_flash_duration or AL_SETTINGS.status_flash_interval
        status_flash_timer = os.startTimer(delay)
        render_screen()
    end
end

local function in_region(region, x, y)
    if not region then
        return false
    end
    return x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2
end

local function handle_monitor_touch(_, x, y)
    if in_region(button_regions.cancel, x, y) then
        manual_cancelled = true
        stop_alarm()
    elseif in_region(button_regions.toggle, x, y) then
        toggle_enabled = not toggle_enabled
        update_toggle_output()
        render_screen()
    end
end

local function event_loop()
    render_screen()
    ensure_alarm_modem_open()
    refresh_input_state()
    print("Ready!")
    while true do
        local ev, p2, p3, p4 = os.pullEvent()
        if ev == "timer" then
            handle_timer(p2)
        elseif ev == "monitor_touch" then
            handle_monitor_touch(p2, p3, p4)
        elseif ev == "redstone" then
            refresh_input_state()
        elseif ev == "rednet_message" then
            handle_rednet_alarm(p2, p3, p4)
        elseif ev == "terminate" then
            SG_UTILS.clear_all_lines()
            SG_UTILS.show_top_message("! UNAVAILABLE !")
            break
        end

        if ev ~= "redstone" and ev ~= "timer" then
            refresh_input_state()
        end

        if not MODEM_STATE.side or not rednet.isOpen(MODEM_STATE.side) then
            ensure_alarm_modem_open()
        end
    end
end

local ok, err = pcall(event_loop)
clear_phase_outputs()
set_toggle(false)
if not ok and err ~= "Terminated" then
    error(err)
end
