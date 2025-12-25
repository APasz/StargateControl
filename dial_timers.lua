local M = {}

function M.init(ctx)
    local STATE = ctx.state
    local SG_SETTINGS = ctx.settings
    local TIMER_SCHEDULE = ctx.timer_schedule
    local TICK_INTERVAL = ctx.tick_interval

    local function now_ms()
        if os.epoch then
            return os.epoch("utc")
        end
        return math.floor((os.clock and os.clock() or 0) * 1000)
    end

    local function get_countdown_failsafe_delay()
        local delay = SG_SETTINGS.countdown_failsafe_delay
        if delay == false then
            return 0
        end
        if type(delay) ~= "number" then
            return 3
        end
        return math.max(delay, 0)
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
        ctx.utils.update_line("Disconnect in " .. tostring(value), 2)
    end

    local function reset_timer()
        STATE.pending_timeout = nil
        STATE.timeout_remaining = nil
        STATE.countdown_deadline = nil
        STATE.countdown_pending = false
        STATE.countdown_pending_at = nil
        STATE.countdown_forced = false
        ctx.utils.update_line("", 2)
    end

    local function clear_incoming_counter()
        cancel_timer("incoming")
        STATE.incoming_seconds = 0
    end

    local function start_incoming_counter(initial_seconds)
        clear_incoming_counter()
        STATE.incoming_seconds = math.max(math.floor(initial_seconds or 0), 0)
        if ctx.update_incoming_counter_line then
            ctx.update_incoming_counter_line()
        end
        start_timer("incoming", 1)
    end

    local function start_countdown(remaining, force)
        clear_incoming_counter()
        reset_timer()
        local timeout = SG_SETTINGS.timeout
        if type(remaining) == "number" and remaining >= 0 then
            timeout = remaining
        end
        timeout = math.max(timeout or 0, 0)
        STATE.timeout_remaining = timeout
        STATE.countdown_deadline = now_ms() + (timeout * 1000)
        STATE.countdown_forced = force == true
        show_disconnect_line(STATE.timeout_remaining)
    end

    local function start_countdown_when_established(remaining)
        -- Defer the disconnect timer until the wormhole is fully connected.
        if STATE.countdown_deadline or STATE.countdown_pending then
            return
        end
        clear_incoming_counter()
        reset_timer()
        if type(remaining) == "number" and remaining >= 0 then
            STATE.pending_timeout = remaining
        else
            STATE.pending_timeout = nil
        end
        STATE.countdown_pending = true
        STATE.countdown_pending_at = now_ms()
        STATE.countdown_forced = false
        if ctx.is_wormhole_open and ctx.is_wormhole_open() then
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

    local function run_timer_task(name, now)
        if name == "energy" then
            if ctx.send_energy_update then
                ctx.send_energy_update()
            end
            start_timer("energy", 0.5)
            return
        end

        if name == "incoming" then
            if STATE.outbound == false then
                local seconds = ctx.get_open_seconds and ctx.get_open_seconds()
                if seconds then
                    seconds = math.max(seconds, 0)
                    if seconds ~= STATE.incoming_seconds then
                        STATE.incoming_seconds = seconds
                        if ctx.update_incoming_counter_line then
                            ctx.update_incoming_counter_line()
                        end
                    end
                else
                    STATE.incoming_seconds = (STATE.incoming_seconds or 0) + 1
                    if ctx.update_incoming_counter_line then
                        ctx.update_incoming_counter_line()
                    end
                end
                if ctx.send_alarm_update then
                    ctx.send_alarm_update(true, true)
                end
                if ctx.send_env_status_message then
                    ctx.send_env_status_message()
                end
                start_timer("incoming", 1)
            end
            return
        end

        if name == "screen" then
            clear_screen_timer()
            if ctx.screen then
                ctx.screen()
            end
            return
        end

        if name == "disconnect" then
            if STATE.waiting_disconnect then
                if ctx.show_disconnected_screen then
                    ctx.show_disconnected_screen()
                end
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
            STATE.countdown_pending = false
            STATE.countdown_pending_at = nil
            STATE.countdown_forced = false
            return
        end

        if STATE.outbound == true then
            local open = ctx.is_wormhole_open and ctx.is_wormhole_open()
            if not open and STATE.countdown_pending and not STATE.countdown_forced then
                local delay = get_countdown_failsafe_delay()
                if delay and delay > 0 then
                    local pending_at = STATE.countdown_pending_at
                    if pending_at and now - pending_at >= delay * 1000 then
                        STATE.countdown_forced = true
                    end
                end
            end
            if open or STATE.countdown_forced then
                if not STATE.countdown_deadline then
                    local timeout = STATE.pending_timeout
                    if timeout == nil then
                        timeout = SG_SETTINGS.timeout
                    end
                    timeout = math.max(timeout or 0, 0)
                    STATE.pending_timeout = nil
                    STATE.timeout_remaining = timeout
                    STATE.countdown_deadline = now + (timeout * 1000)
                    STATE.countdown_pending = false
                    STATE.countdown_pending_at = nil
                    show_disconnect_line(timeout)
                end

                if STATE.countdown_deadline then
                    local remaining_ms = STATE.countdown_deadline - now
                    if remaining_ms <= 0 then
                        if ctx.disconnect_now then
                            ctx.disconnect_now(false)
                        end
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
                if STATE.countdown_pending then
                    show_disconnect_line("X")
                end
            end
        elseif STATE.outbound == false then
            if ctx.is_wormhole_active and ctx.is_wormhole_active() then
                local open_seconds = ctx.get_open_seconds and ctx.get_open_seconds()
                if open_seconds then
                    open_seconds = math.max(open_seconds, 0)
                    if open_seconds ~= STATE.incoming_seconds then
                        STATE.incoming_seconds = open_seconds
                        if ctx.update_incoming_counter_line then
                            ctx.update_incoming_counter_line()
                        end
                    end
                end
            end
        end
    end

    local function schedule_tick(delay)
        ctx.tick_timer_id = os.startTimer(delay or TICK_INTERVAL)
    end

    local function process_tick()
        local now = now_ms()
        process_scheduled_timers(now)
        maintain_connection_timers(now)
        schedule_tick(TICK_INTERVAL)
    end

    ctx.cancel_timer = cancel_timer
    ctx.start_timer = start_timer
    ctx.has_timer = has_timer
    ctx.reset_timer = reset_timer
    ctx.clear_incoming_counter = clear_incoming_counter
    ctx.start_incoming_counter = start_incoming_counter
    ctx.start_countdown_when_established = start_countdown_when_established
    ctx.clear_screen_timer = clear_screen_timer
    ctx.start_disconnect_fallback = start_disconnect_fallback
    ctx.clear_disconnect_fallback = clear_disconnect_fallback
    ctx.show_disconnect_line = show_disconnect_line
    ctx.process_tick = process_tick
    ctx.schedule_tick = schedule_tick
end

return M
