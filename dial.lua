package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = 'return { site = nil, fast_dial_rs_side = "left", incom_alarm_rs_side = nil, timeout = 60 }\n'

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

local INF_GATE = SG_UTILS.get_inf_gate(false)

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
    top_lines = 0,
}
local TIMERS = {}
local TIMER_LOOKUP = {}

local function ensure_inf_gate(require_gate)
    INF_GATE = SG_UTILS.get_inf_gate(require_gate == nil and false or require_gate)
    return INF_GATE
end



local function send_incoming_message()
    local gate = ensure_inf_gate(false)
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

local function is_wormhole_active()
    local gate = ensure_inf_gate(false)
    if not gate then
        return false
    end

    local connected = type(gate.isStargateConnected) == "function" and gate.isStargateConnected() == true
    local open = type(gate.isWormholeOpen) == "function" and gate.isWormholeOpen() == true

    return connected or open
end

local function is_wormhole_open()
    local gate = ensure_inf_gate(false)
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

local function compute_menu_layout(addr_count)
    local mon_width, mon_height = SG_UTILS.get_monitor_size(32, 15)
    local usable_width = math.max(mon_width - 1, 1)

    local min_col_width = 6
    local comfy_max_cols = math.max(1, math.min(math.floor(usable_width / min_col_width), addr_count))
    local hard_max_cols = math.max(1, math.min(usable_width, addr_count))

    local columns = 1
    local rows = math.ceil(addr_count / columns)

    while rows > mon_height and columns < comfy_max_cols do
        columns = columns + 1
        rows = math.ceil(addr_count / columns)
    end

    while rows > mon_height and columns < hard_max_cols do
        columns = columns + 1
        rows = math.ceil(addr_count / columns)
    end

    local col_width = math.max(math.floor(usable_width / columns), 1)
    local entry_width = math.max(col_width - 1, 1)

    return {
        columns = columns,
        rows = rows,
        col_width = col_width,
        entry_width = entry_width,
        width = mon_width,
        height = mon_height,
        usable_width = usable_width,
    }
end

local function cancel_timer(name)
    local id = TIMERS[name]
    if id then
        os.cancelTimer(id)
        TIMER_LOOKUP[id] = nil
    end
    TIMERS[name] = nil
end

local function start_timer(name, delay)
    cancel_timer(name)
    local id = os.startTimer(delay)
    TIMERS[name] = id
    TIMER_LOOKUP[id] = name
    return id
end

local function timer_name(id)
    return TIMER_LOOKUP[id]
end

local function reset_timer()
    cancel_timer("countdown")
    STATE.timeout_remaining = nil
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
    STATE.timeout_remaining = timeout
    start_timer("countdown", 1)
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
    local rs = SG_UTILS.ensure_inf_rs()
    SG_UTILS.reset_outputs(rs)
    SG_UTILS.prepare_monitor(1, true)
    reset_top()
    local addr_count = #SG_ADDRESSES
    if addr_count == 0 then
        return
    end

    local layout = compute_menu_layout(addr_count)
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
        local fast = SG_UTILS.rs_input(SG_SETTINGS.fast_dial_rs_side)
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
    local gate = ensure_inf_gate(false)
    if gate and was_connected then
        SG_UTILS.update_line("Disconnecting...")
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
    local dial_result

    local function run_dial()
        local success, reason = SG_UTILS.dial(gate, fast, function()
            return cancel_requested
        end)
        dial_result = { success, reason }
    end

    local function wait_for_cancel()
        while not dial_result do
            SG_UTILS.wait_for_disconnect_request()
            if dial_result then
                break
            end
            cancel_requested = true
            while not dial_result do
                os.pullEvent()
            end
        end
    end

    parallel.waitForAny(run_dial, wait_for_cancel)
    if not dial_result then
        return false, "cancelled", cancel_requested
    end
    return dial_result[1], dial_result[2], cancel_requested
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

    local fast = SG_UTILS.rs_input(SG_SETTINGS.fast_dial_rs_side)
    local dialing_type = fast and "Fast Dialing: " or "Dialing: "
    show_status({ dialing_type .. gate.name, STATE.gate_id })

    local success, reason, cancelled = dial_with_cancel(gate, fast)
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
        show_top_message_lines({ "Dialed: " .. gate.name, STATE.gate_id })
        STATE.outbound, STATE.connected = true, true
        start_countdown()
        return
    end

    STATE.outbound = nil
    STATE.connected = false
    STATE.gate = nil
    STATE.gate_id = nil
    local message
    if reason == "no_gate" then
        message = "No gate interface found"
    elseif reason == "cancelled" or cancelled then
        message = "Dial cancelled"
    else
        message = "Dial failed"
    end
    show_status(message)
    clear_screen_timer()
    start_timer("screen", 2)
end

local function make_banner(width, phrase, pad)
    pad = pad or "!"

    local plen = #phrase
    if width < plen + 2 then
        return phrase
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
    SG_UTILS.set_text_color(colors.red)
    reset_top()
    local width = select(1, SG_UTILS.get_monitor_size())
    if not width or width < 1 then
        width = 1
    end

    local top_bottom = string.rep("!", width)

    local middle = make_banner(width, "Incoming Wormhole", "!")

    local lines_written = SG_UTILS.write_lines({ top_bottom, middle, top_bottom }, 1) or 3
    SG_UTILS.reset_text_color()
    STATE.top_lines = math.max(lines_written, 1)
    SG_UTILS.set_line_offset(math.max(STATE.top_lines - 1, 0))
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
    local gate = ensure_inf_gate(false)
    if not gate or type(gate.getOpenTime) ~= "function" then
        return nil
    end

    local ticks = gate.getOpenTime()
    if type(ticks) ~= "number" then
        return nil
    end

    return math.max(math.floor(ticks / 20), 0)
end

local function start_incoming_counter(initial_seconds)
    clear_incoming_counter()
    STATE.incoming_seconds = math.max(math.floor(initial_seconds or 0), 0)
    update_incoming_counter_line()
    start_timer("incoming", 1)
end

local function resume_active_wormhole()
    local gate = ensure_inf_gate(false)
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
        show_status({ "Active wormhole to: " .. gate.name, addr_str })
        local remaining = SG_SETTINGS.timeout
        if open_seconds then
            remaining = math.max(remaining - open_seconds, 0)
        end
        start_countdown(remaining)
    else
        STATE.outbound = false
        STATE.gate_id = addr_str ~= "-" and addr_str or "Incoming"
        show_incoming_banner()
        start_incoming_counter(open_seconds)
    end

    return true
end

local function handle_timer_event(timer_id)
    local name = timer_name(timer_id)
    if not name then
        return
    end

    TIMERS[name] = nil
    TIMER_LOOKUP[timer_id] = nil

    if name == "countdown" then
        if not STATE.connected then
            reset_timer()
            return
        end

        if STATE.timeout_remaining <= 0 then
            disconnect_now(false)
            return
        end

        SG_UTILS.update_line("Stargate Disconnect in " .. STATE.timeout_remaining, 2)
        STATE.timeout_remaining = STATE.timeout_remaining - 1
        start_timer("countdown", 1)
        return
    end

    if name == "disconnect" then
        if STATE.waiting_disconnect then
            show_disconnected_screen()
        else
            cancel_timer("disconnect")
        end
        return
    end

    if name == "incoming" then
        STATE.incoming_seconds = (STATE.incoming_seconds or 0) + 1
        update_incoming_counter_line()
        start_timer("incoming", 1)
        return
    end

    if name == "screen" then
        clear_screen_timer()
        screen()
    end
end

local function handle_redstone_event()
    if STATE.connected or STATE.outbound == false then
        return
    end
    if TIMERS.screen then
        clear_screen_timer()
    end
    screen()
end

local function handle_terminate()
    show_status("! UNAVAILABLE !")
    return true
end

local function handle_user_input(ev, p2, p3, p4)
    if TIMERS.screen then
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

    local sel = SG_UTILS.get_selection(ev, p2, p3, p4)
    if sel then
        handle_selection(sel)
    end
end

local function stargate_disconnected(p2, feedback_num, feedback_desc)
    if STATE.connected then
        reset_timer()
    end
    STATE.connected = false
    STATE.outbound = nil
    STATE.gate = nil
    STATE.gate_id = nil
    show_disconnected_screen()
end

local function stargate_message_received(p2, message)
    if message ~= "sg_disconnect" then
        return
    end
    if STATE.connected and STATE.outbound == true then
        SG_UTILS.update_line("Remote disconnect requested", 3)
        disconnect_now(true)
    end
end

local function stargate_chevron_engaged(p2, count, engaged, incoming, symbol)
    if incoming then
        local rs = SG_UTILS.ensure_inf_rs()
        if SG_SETTINGS.incom_alarm_rs_side and rs then
            rs.setOutput(SG_SETTINGS.incom_alarm_rs_side, true)
        end
        SG_UTILS.prepare_monitor(1)
        SG_UTILS.set_text_color(colors.red)
        SG_UTILS.update_line("!!! Incoming wormhole !!!")
        SG_UTILS.reset_text_color()
    end
end

local function stargate_incoming_wormhole(p2, address)
    show_incoming_banner()
    STATE.outbound = false
    STATE.gate = nil
    STATE.gate_id = "Incoming"
    STATE.disconnected_early = false
    start_incoming_counter(get_open_seconds())
end

local function stargate_outgoing_wormhole(p2, address)
    clear_screen_timer()
    SG_UTILS.update_line("Wormhole open", 3)
    STATE.outbound = true
    STATE.connected = true
    if not STATE.gate_id then
        STATE.gate_id = SG_UTILS.address_to_string(address)
    end
    start_countdown()
end

local function stargate_reset(p2, feedback_num, feedback_desc)
    SG_UTILS.reset_outputs(SG_UTILS.ensure_inf_rs())
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

local event_handlers = {
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

local stargate_clear_screen_events = {
    stargate_chevron_engaged = true,
    stargate_incoming_wormhole = true,
    stargate_wormhole_opened = true,
    stargate_outgoing_wormhole = true,
    stargate_disconnected = true,
}

local function dispatch_event(event)
    local name = event[1]
    local handler = user_event_handlers[name]
    if handler then
        return handler(table.unpack(event, 2))
    end

    handler = event_handlers[name]
    if handler then
        if stargate_clear_screen_events[name] then
            clear_screen_timer()
        end
        return handler(table.unpack(event, 2))
    end
end

if not resume_active_wormhole() then
    screen()
end
while true do
    local should_stop = dispatch_event({ os.pullEvent() })
    if should_stop then
        break
    end
end
