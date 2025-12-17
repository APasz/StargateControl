package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
    site = nil,
    -- optional site override for address filtering
    rs_fast_dial = "left",
    -- side to detect redstone signal meaning to fast dial
    rs_income_alarm = nil,
    -- side to output redstone signal during incoming wormhole
    alarm_protocol = "sg_alarm",
    -- rednet protocol used when sending incoming wormhole alarms
    rs_safe_env = nil,
    -- side to detect redstone signal if the local environment is safe (set to true to force always-safe)
    timeout = 60,
    -- time until wormhole is autoclosed
    dialing_colour = "green",
    -- colour to use during dialing progress
    energy_modem_side = nil,
    -- side with modem to broadcast energy (nil auto-detects)
    energy_protocol = "sg_aux",
    -- rednet protocol used when sending energy updates
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
local SG_SETTINGS = load_or_create_settings()

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

local _, LOCAL_SITE = SG_UTILS.get_site(SG_SETTINGS.site)

local INF_GATE = SG_UTILS.get_inf_gate()

local INF_RS = SG_UTILS.get_inf_rs()
SG_UTILS.get_inf_mon()

local SG_ADDRESSES = SG_UTILS.filtered_addresses(require("addresses"), SG_SETTINGS.site)

local STATE = {
    connected = false,
    outbound = nil,
    timeout_remaining = nil,
    gate = nil,
    gate_id = nil,
    disconnected_early = false,
    waiting_disconnect = false,
    incoming_seconds = 0,
    pending_timeout = nil,
    countdown_deadline = nil,
    top_lines = 0,
}
local TICK_INTERVAL = 0.25 -- scheduler tick in seconds
local TIMER_SCHEDULE = {}
local TICK_TIMER_ID = nil
local ALARM_STATE = {
    modem_side = nil,
    warned_config = false,
    warned_missing = false,
    last_active = nil,
    last_sent_at = nil,
}
local ALARM_PROTOCOL = SG_SETTINGS.alarm_protocol or "sg_alarm"
local ENERGY_STATE = {
    modem_side = nil,
    warned_config = false,
    warned_missing = false,
}
local ENERGY_PROTOCOL = SG_SETTINGS.energy_protocol or "sg_aux"

local event_handlers
local stargate_clear_screen_events
local dispatch_event
local dispatch_non_user_event
local CANCEL_EVENT_BLACKLIST = {
    redstone = true,
    stargate_deconstructing_entity = true,
    stargate_reconstructing_entity = true,
    stargate_message = true,
    stargate_message_received = true,
}

local function send_incoming_message()
    local gate = SG_UTILS.get_inf_gate()
    if not gate or STATE.outbound ~= false then
        return
    end
    if type(gate.sendStargateMessage) ~= "function" then
        return
    end

    local ok, err = pcall(gate.sendStargateMessage, "sg_disconnect")
    if not ok then
        SG_UTILS.update_line("Send Stargate message Failed!", 1)
    end
end

local function get_env_status_message()
    local setting = SG_SETTINGS.rs_safe_env
    if setting == true then
        return "env_safe"
    end
    if setting == false then
        return "env_unsafe"
    end
    if setting == nil then
        return "env_unknown"
    end

    local safe_env = SG_UTILS.rs_input(setting)
    return safe_env and "env_safe" or "env_unsafe"
end

local function send_env_status_message()
    local gate = SG_UTILS.get_inf_gate()
    if not gate or STATE.outbound ~= false or type(gate.sendStargateMessage) ~= "function" then
        return
    end

    local ok, err = pcall(gate.sendStargateMessage, get_env_status_message())
    if not ok then
        print("Failed to send env status: " .. tostring(err))
    end
end

local function show_remote_env_status(message)
    if not (STATE.connected and STATE.outbound == true) then
        return false
    end

    local text
    local col
    if message == "env_safe" then
        text = "Environment: SAFE"
        col = colours.blue
    elseif message == "env_unsafe" then
        text = "Environment: UNSAFE"
        col = colours.red
    elseif message == "env_unknown" then
        text = "Environment: UNKNOWN"
        col = colours.yellow
    end

    if not text then
        return false
    end

    if col then
        SG_UTILS.set_text_colour(col)
    else
        SG_UTILS.reset_text_colour()
    end
    SG_UTILS.update_line(text, 4)
    if col then
        SG_UTILS.reset_text_colour()
    end
    return true
end

local function get_gate_energy()
    if not INF_GATE or type(INF_GATE.getEnergy) ~= "function" then
        return nil
    end
    return {
        sg_energy = INF_GATE.getStargateEnergy(),
        inf_energy = INF_GATE.getEnergy(),
        inf_capacity = INF_GATE.getEnergyCapacity(),
        inf_target = INF_GATE.getEnergyTarget(),
    }
end

local function open_alarm_modem()
    if ALARM_STATE.modem_side and rednet.isOpen(ALARM_STATE.modem_side) then
        return ALARM_STATE.modem_side
    end

    if CLIENT_MODEM_SIDE then
        if peripheral.getType(CLIENT_MODEM_SIDE) == "modem" then
            local ok, err = pcall(rednet.open, CLIENT_MODEM_SIDE)
            if not ok then
                print("Alarm modem open failed on " .. tostring(CLIENT_MODEM_SIDE) .. ": " .. tostring(err))
            end
            if rednet.isOpen(CLIENT_MODEM_SIDE) then
                ALARM_STATE.modem_side = CLIENT_MODEM_SIDE
                ALARM_STATE.warned_missing = false
                return CLIENT_MODEM_SIDE
            end
        elseif not ALARM_STATE.warned_config then
            print("Configured alarm modem side not found: " .. tostring(CLIENT_MODEM_SIDE))
            ALARM_STATE.warned_config = true
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, err = pcall(rednet.open, name)
            if not ok then
                print("Alarm modem open failed on " .. tostring(name) .. ": " .. tostring(err))
            end
            if rednet.isOpen(name) then
                ALARM_STATE.modem_side = name
                ALARM_STATE.warned_config = false
                ALARM_STATE.warned_missing = false
                return name
            end
        end
    end

    if not ALARM_STATE.warned_missing then
        print("No modem available for alarm broadcast")
        ALARM_STATE.warned_missing = true
    end
    ALARM_STATE.modem_side = nil
    return nil
end

local function open_energy_modem()
    if ENERGY_STATE.modem_side and rednet.isOpen(ENERGY_STATE.modem_side) then
        return ENERGY_STATE.modem_side
    end

    local configured = SG_SETTINGS.energy_modem_side
    if configured then
        if peripheral.getType(configured) == "modem" then
            local ok, err = pcall(rednet.open, configured)
            if not ok then
                print("Energy modem open failed on " .. tostring(configured) .. ": " .. tostring(err))
            end
            if rednet.isOpen(configured) then
                ENERGY_STATE.modem_side = configured
                ENERGY_STATE.warned_missing = false
                return configured
            end
        elseif not ENERGY_STATE.warned_config then
            print("Configured energy_modem_side not found: " .. tostring(configured))
            ENERGY_STATE.warned_config = true
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, err = pcall(rednet.open, name)
            if not ok then
                print("Energy modem open failed on " .. tostring(name) .. ": " .. tostring(err))
            end
            if rednet.isOpen(name) then
                ENERGY_STATE.modem_side = name
                ENERGY_STATE.warned_config = false
                ENERGY_STATE.warned_missing = false
                return name
            end
        end
    end

    if not ENERGY_STATE.warned_missing then
        print("No modem available for energy broadcast")
        ENERGY_STATE.warned_missing = true
    end
    ENERGY_STATE.modem_side = nil
    return nil
end

local function send_energy_update()
    local data = get_gate_energy()
    if not data then
        return
    end

    local modem = open_energy_modem()
    if not modem then
        return
    end

    data.type = "energy"
    data.site = LOCAL_SITE
    local ok, err = pcall(rednet.broadcast, data, ENERGY_PROTOCOL)
    if not ok then
        print("Failed to send energy: " .. tostring(err))
    end
end

local function send_alarm_update(active, force)
    local protocol = ALARM_PROTOCOL or "sg_alarm"
    if not protocol or protocol == "" then
        return
    end

    if active and STATE.outbound == true then
        return
    end

    local now = (os.epoch and os.epoch("utc")) or (os.clock and (os.clock() * 1000)) or nil
    if not force and ALARM_STATE.last_active == active then
        return
    end
    if force and ALARM_STATE.last_active == active and now and ALARM_STATE.last_sent_at and now - ALARM_STATE.last_sent_at < 4000 then
        return
    end

    local modem = open_alarm_modem()
    if not modem then
        return
    end

    local payload = {
        type = "incoming_alarm",
        active = active == true,
        site = LOCAL_SITE,
    }
    local ok, err = pcall(rednet.broadcast, payload, protocol)
    if not ok then
        print("Failed to send alarm signal: " .. tostring(err))
        return
    end
    ALARM_STATE.last_active = active
    ALARM_STATE.last_sent_at = now
end

local function is_wormhole_active()
    local gate = SG_UTILS.get_inf_gate()
    if not gate then
        return false
    end

    local connected = type(gate.isStargateConnected) == "function" and gate.isStargateConnected() == true
    local open = type(gate.isWormholeOpen) == "function" and gate.isWormholeOpen() == true

    return connected or open
end

local function is_wormhole_open()
    local gate = SG_UTILS.get_inf_gate()
    if not gate or type(gate.isWormholeOpen) ~= "function" then
        return false
    end
    return gate.isWormholeOpen() == true
end
local function reset_top()
    SG_UTILS.reset_line_offset()
    STATE.top_lines = 0
end

local function apply_top_offset()
    SG_UTILS.set_line_offset(math.max(STATE.top_lines - 1, 0))
end

local function show_top_message(text)
    SG_UTILS.clear_lines(STATE.top_lines)
    reset_top()
    STATE.top_lines = SG_UTILS.update_line(text) or 1
    apply_top_offset()
    return STATE.top_lines
end

local function show_top_message_lines(lines)
    SG_UTILS.clear_lines(STATE.top_lines)
    reset_top()

    STATE.top_lines = SG_UTILS.write_lines(lines, 1) or 0
    if STATE.top_lines < 1 then
        STATE.top_lines = 1
    end

    apply_top_offset()
    return STATE.top_lines
end

local function show_status(lines, scale)
    SG_UTILS.prepare_monitor(scale or 1, true)
    reset_top()
    if type(lines) == "table" then
        return show_top_message_lines(lines)
    else
        return show_top_message(lines)
    end
end

local function resolve_colour(value, default)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        local function lookup(key)
            if colours[key] then
                return colours[key]
            end
        end

        local exact = lookup(value)
        if exact then
            return exact
        end

        local lower = string.lower(value)
        if lower ~= value then
            local lower_res = lookup(lower)
            if lower_res then
                return lower_res
            end
        end
    end
    return default
end

local function update_dial_progress(encoded_count)
    if not (STATE.gate and STATE.gate.address) then
        return
    end

    local addr = STATE.gate.address
    local total = #addr
    if total <= 0 then
        return
    end

    local coloured = math.max(math.min(encoded_count or 0, total), 0)
    local encoded_colour = resolve_colour(SG_SETTINGS.dialing_colour, colours.green)
    local remaining_colour = resolve_colour("lightGrey", colours.white)
    local segments = {}
    for idx, symbol in ipairs(addr) do
        local text = tostring(symbol)
        if idx < total then
            text = text .. "-"
        end
        segments[#segments + 1] = {
            text = text,
            colour = idx <= coloured and encoded_colour or remaining_colour,
        }
    end

    SG_UTILS.update_coloured_line(segments, 1, SG_UTILS.address_to_string(addr))
end

local function now_ms()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor((os.clock and os.clock() or 0) * 1000)
end

local function cancel_timer(name)
    TIMER_SCHEDULE[name] = nil
end

local function start_timer(name, delay)
    cancel_timer(name)
    local when = now_ms() + math.max(delay or 0, 0) * 1000
    TIMER_SCHEDULE[name] = when
    return when
end

local function has_timer(name)
    return TIMER_SCHEDULE[name] ~= nil
end

local function show_disconnect_line(value)
    SG_UTILS.update_line("Disconnect in " .. tostring(value), 2)
end

local function reset_timer()
    STATE.pending_timeout = nil
    STATE.timeout_remaining = nil
    STATE.countdown_deadline = nil
    SG_UTILS.update_line("", 2)
end

local function clear_incoming_counter()
    cancel_timer("incoming")
    STATE.incoming_seconds = 0
end

local function start_countdown(remaining)
    clear_incoming_counter()
    reset_timer()
    local timeout = SG_SETTINGS.timeout
    if type(remaining) == "number" and remaining >= 0 then
        timeout = remaining
    end
    timeout = math.max(timeout or 0, 0)
    STATE.timeout_remaining = timeout
    STATE.countdown_deadline = now_ms() + (timeout * 1000)
    show_disconnect_line(STATE.timeout_remaining)
end

local function start_countdown_when_established(remaining)
    -- Defer the disconnect timer until the wormhole is fully connected.
    if STATE.countdown_deadline or STATE.pending_timeout then
        return
    end
    clear_incoming_counter()
    reset_timer()
    if type(remaining) == "number" and remaining >= 0 then
        STATE.pending_timeout = remaining
    else
        STATE.pending_timeout = nil
    end
    if is_wormhole_open() then
        STATE.pending_timeout = nil
        start_countdown(remaining)
        return
    end

    show_disconnect_line("X")
end

local function clear_screen_timer()
    cancel_timer("screen")
end

local function start_disconnect_fallback()
    STATE.waiting_disconnect = true
    start_timer("disconnect", 3)
end

local function clear_disconnect_fallback()
    STATE.waiting_disconnect = false
    cancel_timer("disconnect")
end

local function show_disconnected_screen()
    clear_disconnect_fallback()
    clear_incoming_counter()
    show_status("Stargate Disconnected")
    clear_screen_timer()
    start_timer("screen", 3)
end

local function screen()
    -- Menu of gate address options
    local rs = SG_UTILS.get_inf_rs()
    SG_UTILS.reset_outputs(rs)
    SG_UTILS.prepare_monitor(1, true)
    reset_top()
    local addr_count = #SG_ADDRESSES
    if addr_count == 0 then
        return
    end

    local layout = SG_UTILS.compute_menu_layout(addr_count)
    local columns = layout.columns
    local rows = layout.rows
    local col_width = layout.col_width
    local entry_width = layout.entry_width

    for row = 1, rows, 1 do
        local display_pieces = {}
        local log_pieces = {}
        for col = 1, columns, 1 do
            local idx = (col - 1) * rows + row
            local gate = SG_ADDRESSES[idx]

            local display_entry = gate and SG_UTILS.format_address(idx, gate, entry_width, false) or ""
            local log_entry = gate and SG_UTILS.format_address(idx, gate, nil, true) or ""

            if col < columns then
                display_entry = SG_UTILS.pad_to_width(display_entry, col_width)
                log_entry = SG_UTILS.pad_to_width(log_entry, col_width)
            end

            display_pieces[#display_pieces + 1] = display_entry
            log_pieces[#log_pieces + 1] = log_entry
        end
        SG_UTILS.update_line(table.concat(display_pieces), row, table.concat(log_pieces))
    end

    local mon = SG_UTILS.get_inf_mon()
    if mon then
        local fast = SG_UTILS.rs_input(SG_SETTINGS.rs_fast_dial)
        mon.setCursorPos(layout.width, layout.height)
        mon.write(fast and ">" or "#")
    end
end

local function disconnect_now(mark_early)
    local was_connected = STATE.connected
    if mark_early then
        STATE.disconnected_early = true
    end
    reset_timer()
    clear_incoming_counter()
    local gate = SG_UTILS.get_inf_gate()
    if gate and was_connected then
        SG_UTILS.update_line("Disconnecting...", 2)
        SG_UTILS.update_line("", 3)
        SG_UTILS.update_line("", 4)
        SG_UTILS.update_line("", 5)
        if type(gate.disconnectStargate) == "function" then
            gate.disconnectStargate()
        else
            SG_UTILS.reset_stargate()
        end
        start_disconnect_fallback()
    else
        clear_disconnect_fallback()
    end
    STATE.connected = false
    STATE.outbound = nil
    if not was_connected then
        screen()
    end
end

local function dial_with_cancel(gate, fast)
    local cancel_requested = false
    local cancel_reason
    local dial_result

    local function run_dial()
        local success, reason = SG_UTILS.dial(gate, fast, function()
            return cancel_requested
        end, function(encoded_idx)
            update_dial_progress(encoded_idx)
        end)
        dial_result = { success, reason }
    end

    local function wait_for_cancel()
        while not dial_result do
            local event = { os.pullEvent() }
            local name = event[1]

            local handler_result
            if event_handlers and event_handlers[name] and not CANCEL_EVENT_BLACKLIST[name] and dispatch_non_user_event then
                handler_result = dispatch_non_user_event(event)
            end

            if handler_result == true then
                cancel_requested = true
                cancel_reason = cancel_reason or name
            elseif name == "monitor_touch" or name == "key" or name == "char" then
                cancel_requested = true
                cancel_reason = cancel_reason or "user"
            elseif name == "stargate_incoming_wormhole" then
                cancel_requested = true
                cancel_reason = cancel_reason or "incoming"
            elseif name == "stargate_chevron_engaged" and event[4] == true then
                cancel_requested = true
                cancel_reason = cancel_reason or "incoming"
            end
        end
    end

    parallel.waitForAny(run_dial, wait_for_cancel)
    if not dial_result then
        return false, "cancelled", cancel_reason or cancel_requested
    end
    return dial_result[1], dial_result[2], cancel_reason
end

local function handle_selection(sel)
    if not sel then
        return
    end

    local gate
    if type(sel) == "table" and sel.address then
        gate = sel
    elseif type(sel) == "number" then
        gate = SG_ADDRESSES[sel]
    else
        return
    end
    if not (gate and SG_UTILS.is_valid_address(gate.address)) then
        show_status("Invalid address (need 7-9 symbols)")
        return
    end

    STATE.gate = gate
    STATE.gate_id = SG_UTILS.address_to_string(gate.address)
    STATE.disconnected_early = false

    local site = gate.site or gate.name or "<unknown>"
    local fast = SG_UTILS.rs_input(SG_SETTINGS.rs_fast_dial)
    local dialing_type = fast and "Fast Dialing: " or "Dialing: "
    show_status({ dialing_type .. site, STATE.gate_id })
    update_dial_progress(0)

    local success, reason, cancel_reason = dial_with_cancel(gate, fast)
    if success then
        clear_screen_timer()
        local connected_now = is_wormhole_active()
        if not connected_now then
            for _ = 1, 30, 1 do
                sleep(0.1)
                if is_wormhole_active() then
                    connected_now = true
                    break
                end
            end
        end
        if not connected_now then
            STATE.outbound = nil
            STATE.connected = false
            STATE.gate = nil
            STATE.gate_id = nil
            show_status("Unable to establish wormhole")
            clear_screen_timer()
            start_timer("screen", 3)
            return
        end
        show_top_message_lines({ "Dialed: " .. gate.site, STATE.gate_id })
        STATE.outbound, STATE.connected = true, true
        start_countdown_when_established()
        return
    end

    local message
    if reason == "no_gate" then
        message = "No gate interface found"
    elseif reason == "cancelled" or cancel_reason then
        local connection_active = STATE.outbound == false or STATE.gate_id == "Incoming" or STATE.connected or is_wormhole_active()
        if connection_active and (cancel_reason == "incoming" or cancel_reason == "stargate_incoming_wormhole") then
            return
        end
        message = "Dial cancelled"
    else
        message = "Dial failed"
    end

    STATE.outbound = nil
    STATE.connected = false
    STATE.gate = nil
    STATE.gate_id = nil
    show_status(message)
    clear_screen_timer()
    start_timer("screen", 2)
end

local function make_banner(width, phrase, pad)
    pad = pad or "!"
    phrase = phrase or ""
    width = math.max(width or 1, 1)

    if width <= 2 then
        return string.rep(pad, width)
    end

    local plen = #phrase
    if width < plen + 2 then
        phrase = string.sub(phrase, 1, width - 2)
        plen = #phrase
    end

    local n = math.floor(width / (plen + 2))
    if n < 1 then
        n = 1
    end

    local base_len = n * (plen + 2)
    local total_pad = width - base_len

    local segments = n + 1
    local base_pad = math.floor(total_pad / segments)
    local rem = total_pad % segments

    local pads = {}
    for i = 1, segments do
        local extra = (i <= rem) and 1 or 0
        pads[i] = string.rep(pad, base_pad + extra)
    end

    local parts = {}
    for i = 1, n do
        table.insert(parts, pads[i])
        table.insert(parts, " ")
        table.insert(parts, phrase)
        table.insert(parts, " ")
    end
    table.insert(parts, pads[segments])

    return table.concat(parts)
end

local function show_incoming_banner()
    SG_UTILS.prepare_monitor(1, true)
    SG_UTILS.set_text_colour(colours.red)
    reset_top()
    local width = select(1, SG_UTILS.get_monitor_size())
    if not width or width < 1 then
        width = 1
    end

    local top_bottom = string.rep("!", width)

    local middle = make_banner(width, "Incoming", "!")
    if #middle > width then
        middle = string.sub(middle, 1, width)
    end

    SG_UTILS.update_line(top_bottom, 1)
    SG_UTILS.update_line(middle, 2)
    SG_UTILS.update_line(top_bottom, 3)
    SG_UTILS.reset_text_colour()
    STATE.top_lines = 3
    SG_UTILS.set_line_offset(STATE.top_lines - 1)
end

local function update_incoming_counter_line()
    if not STATE.top_lines or STATE.top_lines <= 0 then
        return
    end
    SG_UTILS.set_line_offset(0)
    SG_UTILS.update_line("Open for " .. STATE.incoming_seconds .. "s", STATE.top_lines + 1)
    SG_UTILS.set_line_offset(math.max(STATE.top_lines - 1, 0))
end

local function get_open_seconds()
    local gate = SG_UTILS.get_inf_gate()
    if not gate or type(gate.getOpenTime) ~= "function" then
        return nil
    end

    local ticks = gate.getOpenTime()
    if type(ticks) ~= "number" then
        return nil
    end

    return math.max(math.floor(ticks / 20), 0)
end

local function run_timer_task(name, now)
    if name == "energy" then
        send_energy_update()
        start_timer("energy", 1)
        return
    end

    if name == "incoming" then
        if STATE.outbound == false then
            local seconds = get_open_seconds()
            if seconds then
                seconds = math.max(seconds, 0)
                if seconds ~= STATE.incoming_seconds then
                    STATE.incoming_seconds = seconds
                    update_incoming_counter_line()
                end
            else
                STATE.incoming_seconds = (STATE.incoming_seconds or 0) + 1
                update_incoming_counter_line()
            end
            send_alarm_update(true, true)
            send_env_status_message()
            start_timer("incoming", 1)
        end
        return
    end

    if name == "screen" then
        clear_screen_timer()
        screen()
        return
    end

    if name == "disconnect" then
        if STATE.waiting_disconnect then
            show_disconnected_screen()
        else
            clear_disconnect_fallback()
        end
        return
    end
end

local function process_scheduled_timers(now)
    local due_list = {}
    for name, due in pairs(TIMER_SCHEDULE) do
        if due and due <= now then
            due_list[#due_list + 1] = name
        end
    end

    for _, name in ipairs(due_list) do
        TIMER_SCHEDULE[name] = nil
        run_timer_task(name, now)
    end
end

local function maintain_connection_timers(now)
    if not STATE.connected then
        STATE.countdown_deadline = nil
        STATE.pending_timeout = nil
        STATE.timeout_remaining = nil
        return
    end

    if STATE.outbound == true then
        local open = is_wormhole_open()
        if open then
            if not STATE.countdown_deadline then
                local timeout = STATE.pending_timeout
                if timeout == nil then
                    timeout = SG_SETTINGS.timeout
                end
                timeout = math.max(timeout or 0, 0)
                STATE.pending_timeout = nil
                STATE.timeout_remaining = timeout
                STATE.countdown_deadline = now + (timeout * 1000)
                show_disconnect_line(timeout)
            end

            if STATE.countdown_deadline then
                local remaining_ms = STATE.countdown_deadline - now
                if remaining_ms <= 0 then
                    disconnect_now(false)
                    return
                end
                local remaining = math.max(math.ceil(remaining_ms / 1000), 0)
                if remaining ~= STATE.timeout_remaining then
                    STATE.timeout_remaining = remaining
                    show_disconnect_line(remaining)
                end
            end
        else
            STATE.countdown_deadline = nil
            STATE.timeout_remaining = nil
            if STATE.pending_timeout ~= nil then
                show_disconnect_line("X")
            end
        end
    elseif STATE.outbound == false then
        if is_wormhole_active() then
            local open_seconds = get_open_seconds()
            if open_seconds then
                open_seconds = math.max(open_seconds, 0)
                if open_seconds ~= STATE.incoming_seconds then
                    STATE.incoming_seconds = open_seconds
                    update_incoming_counter_line()
                end
            end
        end
    end
end

local function schedule_tick(delay)
    TICK_TIMER_ID = os.startTimer(delay or TICK_INTERVAL)
end

local function process_tick()
    local now = now_ms()
    process_scheduled_timers(now)
    maintain_connection_timers(now)
    schedule_tick(TICK_INTERVAL)
end

local function start_incoming_counter(initial_seconds)
    clear_incoming_counter()
    STATE.incoming_seconds = math.max(math.floor(initial_seconds or 0), 0)
    update_incoming_counter_line()
    start_timer("incoming", 1)
end

local function resume_active_wormhole()
    local gate = SG_UTILS.get_inf_gate()
    if not gate or not is_wormhole_active() then
        return false
    end

    clear_screen_timer()
    reset_top()

    local outgoing = type(gate.isStargateDialingOut) == "function" and gate.isStargateDialingOut() == true
    local open_seconds = get_open_seconds()
    local addr
    if type(gate.getConnectedAddress) == "function" then
        addr = gate.getConnectedAddress()
    elseif outgoing and type(gate.getDialedAddress) == "function" then
        addr = gate.getDialedAddress()
    end
    local addr_str = SG_UTILS.address_to_string(addr)

    STATE.connected = true
    STATE.disconnected_early = false

    if outgoing then
        STATE.outbound = true
        STATE.gate_id = addr_str
        local gate = SG_UTILS.find_gate_by_address(addr)
        show_status({ "Active wormhole to: " .. gate.site, addr_str })
        local remaining = SG_SETTINGS.timeout
        if open_seconds then
            remaining = math.max(remaining - open_seconds, 0)
        end
        start_countdown_when_established(remaining)
        send_alarm_update(false)
    else
        STATE.outbound = false
        STATE.gate_id = addr_str ~= "-" and addr_str or "Incoming"
        show_incoming_banner()
        start_incoming_counter(open_seconds)
        send_alarm_update(true, true)
        send_env_status_message()
    end

    return true
end

local function handle_timer_event(timer_id)
    if TICK_TIMER_ID and timer_id == TICK_TIMER_ID then
        TICK_TIMER_ID = nil
        process_tick()
    end
end

local function handle_redstone_event()
    if STATE.connected or STATE.outbound == false then
        return
    end
    if has_timer("screen") then
        clear_screen_timer()
    end
    screen()
end

local function handle_terminate()
    show_status("! UNAVAILABLE !")
    return true
end

local function handle_user_input(ev, p2, p3, p4)
    if STATE.waiting_disconnect then
        return
    end

    if has_timer("screen") then
        clear_screen_timer()
        if not STATE.connected and STATE.outbound ~= false then
            screen()
        end
        return
    end

    if STATE.connected or STATE.outbound == false then
        if STATE.outbound == true then
            if is_wormhole_open() then
                disconnect_now(true)
            end
        elseif ev == "monitor_touch" then
            send_incoming_message()
        end
        return
    end

    local sel = SG_UTILS.get_selection(ev, p2, p3, p4, SG_ADDRESSES)
    if sel then
        handle_selection(sel)
    end
end

local function stargate_disconnected(p2, feedback_num, feedback_desc)
    if STATE.connected then
        reset_timer()
    end
    send_alarm_update(false)
    STATE.connected = false
    STATE.outbound = nil
    STATE.gate = nil
    STATE.gate_id = nil
    show_disconnected_screen()
end

local function stargate_message_received(p2, message)
    if type(message) ~= "string" then
        return
    end

    if message == "sg_disconnect" then
        if STATE.connected and STATE.outbound == true then
            SG_UTILS.update_line("Remote disconnect requested", 3)
            disconnect_now(true)
        end
        return
    end

    if show_remote_env_status(message) then
        return
    end
end

local function stargate_chevron_engaged(p2, count, engaged, incoming, symbol)
    if incoming then
        STATE.outbound = false
        if STATE.outbound ~= true then
            send_alarm_update(true)
        end
        local rs = SG_UTILS.get_inf_rs()
        if SG_SETTINGS.rs_income_alarm and rs then
            rs.setOutput(SG_SETTINGS.rs_income_alarm, true)
        end
        SG_UTILS.prepare_monitor(1)
        SG_UTILS.set_text_colour(colours.red)
        SG_UTILS.update_line("!!! Incoming wormhole !!!")
        SG_UTILS.reset_text_colour()
    end
end

local function stargate_incoming_wormhole(p2, address)
    if STATE.outbound == true then
        send_alarm_update(false)
        return
    end
    show_incoming_banner()
    STATE.outbound = false
    STATE.connected = true
    STATE.gate = nil
    STATE.gate_id = "Incoming"
    STATE.disconnected_early = false
    send_alarm_update(true, true)
    start_incoming_counter(get_open_seconds())
    send_env_status_message()
end

local function stargate_outgoing_wormhole(p2, address)
    send_alarm_update(false)
    clear_screen_timer()
    SG_UTILS.update_line("Wormhole Open", 3)
    SG_UTILS.update_line("", 4)
    STATE.outbound = true
    STATE.connected = true
    if not STATE.gate_id then
        STATE.gate_id = SG_UTILS.address_to_string(address)
    end
    start_countdown_when_established()
end

local function stargate_reset(p2, feedback_num, feedback_desc)
    send_alarm_update(false)
    SG_UTILS.reset_outputs(SG_UTILS.get_inf_rs())
end

local function stargate_deconstructing_entity(p2, enity_type, entity_name, uuid, went_wrong_way) end

local function stargate_reconstructing_entity(p2, enity_type, entity_name, uuid) end

local user_event_handlers = {
    monitor_touch = function(...)
        return handle_user_input("monitor_touch", ...)
    end,
    key = function(...)
        return handle_user_input("key", ...)
    end,
    char = function(...)
        return handle_user_input("char", ...)
    end,
}

event_handlers = {
    stargate_chevron_engaged = stargate_chevron_engaged,
    stargate_incoming_wormhole = stargate_incoming_wormhole,
    stargate_outgoing_wormhole = stargate_outgoing_wormhole,
    stargate_disconnected = stargate_disconnected,
    stargate_reset = stargate_reset,
    stargate_deconstructing_entity = stargate_deconstructing_entity,
    stargate_reconstructing_entity = stargate_reconstructing_entity,
    stargate_message = stargate_message_received,
    stargate_message_received = stargate_message_received,
    timer = handle_timer_event,
    redstone = handle_redstone_event,
    terminate = handle_terminate,
}

stargate_clear_screen_events = {
    stargate_chevron_engaged = true,
    stargate_incoming_wormhole = true,
    stargate_wormhole_opened = true,
    stargate_outgoing_wormhole = true,
    stargate_disconnected = true,
}

dispatch_non_user_event = function(event)
    local name = event[1]

    local handler = event_handlers[name]
    if handler then
        if stargate_clear_screen_events[name] then
            clear_screen_timer()
        end
        return handler(table.unpack(event, 2))
    end
end

function dispatch_event(event)
    local name = event[1]
    local handler = user_event_handlers[name]
    if handler then
        return handler(table.unpack(event, 2))
    end

    return dispatch_non_user_event(event)
end

local function show_error(err)
    local message = tostring(err or "unknown error")
    SG_UTILS.prepare_monitor(1, true)
    reset_top()
    SG_UTILS.set_text_colour(colours.red)
    SG_UTILS.update_line("! ERROR !", 1)
    SG_UTILS.reset_text_colour()
    SG_UTILS.update_line(message, 2)
    SG_UTILS.update_line("See terminal for traceback", 3)
end

local function main_loop()
    local resumed = resume_active_wormhole()
    if not resumed then
        send_alarm_update(false)
        screen()
    elseif STATE.outbound ~= false then
        send_alarm_update(false)
    end
    start_timer("energy", 1)
    schedule_tick(0)
    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            if handle_terminate() then
                break
            end
        else
            local should_stop = dispatch_event(event)
            if should_stop then
                break
            end
        end
    end
end

local function handle_error(err)
    show_error(err)
    return debug.traceback(err, 2)
end

local ok, err = xpcall(main_loop, handle_error)
if not ok then
    print(err)
end
