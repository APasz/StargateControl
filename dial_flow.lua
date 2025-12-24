local M = {}

function M.init(ctx)
    local SG_UTILS = ctx.utils
    local SG_SETTINGS = ctx.settings
    local STATE = ctx.state
    local SG_ADDRESSES = ctx.addresses

    local function dial_failure_message(reason, cancel_reason)
        local feedback = STATE.last_feedback
        if reason ~= "cancelled" and not cancel_reason and feedback and not feedback.suppressed then
            local display = feedback.display
            if type(display) == "string" and display ~= "" then
                return { "Dial failed", "Reason: " .. display }
            end
        end

        if reason == "no_gate" then
            return "No gate interface found"
        end

        if reason == "cancelled" or cancel_reason then
            local labels = {
                user = "User input",
                incoming = "Incoming wormhole",
                stargate_incoming_wormhole = "Incoming wormhole",
                terminate = "Terminate requested",
            }
            local detail = labels[cancel_reason]
            if not detail and type(cancel_reason) == "string" and cancel_reason ~= "" then
                detail = cancel_reason
            end
            if detail then
                return { "Dial cancelled", "Reason: " .. detail }
            end
            return "Dial cancelled"
        end

        local labels = {
            timeout = "Encoding timeout",
            failed = "Encoding failed",
        }
        local detail = labels[reason]
        if not detail and type(reason) == "string" and reason ~= "" then
            detail = reason
        end
        if detail then
            return { "Dial failed", "Reason: " .. detail }
        end
        return "Dial failed"
    end

    local function show_disconnected_screen(lines)
        if ctx.clear_disconnect_fallback then
            ctx.clear_disconnect_fallback()
        end
        if ctx.clear_incoming_counter then
            ctx.clear_incoming_counter()
        end
        if ctx.show_status then
            ctx.show_status(lines or "Stargate Disconnected")
        end
        if ctx.clear_screen_timer then
            ctx.clear_screen_timer()
        end
        if ctx.start_timer then
            ctx.start_timer("screen", 3)
        end
    end

    local function disconnect_now(mark_early)
        local was_connected = STATE.connected
        if mark_early then
            STATE.disconnected_early = true
        end
        if ctx.reset_timer then
            ctx.reset_timer()
        end
        if ctx.clear_incoming_counter then
            ctx.clear_incoming_counter()
        end
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
            if ctx.start_disconnect_fallback then
                ctx.start_disconnect_fallback()
            end
        else
            if ctx.clear_disconnect_fallback then
                ctx.clear_disconnect_fallback()
            end
        end
        STATE.connected = false
        STATE.outbound = nil
        if not was_connected then
            if ctx.screen then
                ctx.screen()
            end
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
                if ctx.update_dial_progress then
                    ctx.update_dial_progress(encoded_idx)
                end
            end)
            dial_result = { success, reason }
        end

        local function wait_for_cancel()
            while not dial_result do
                local event = { os.pullEvent() }
                local name = event[1]

                local handler_result
                if
                    ctx.event_handlers
                    and ctx.event_handlers[name]
                    and not (ctx.cancel_event_blacklist and ctx.cancel_event_blacklist[name])
                    and ctx.dispatch_non_user_event
                then
                    handler_result = ctx.dispatch_non_user_event(event)
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
                elseif name == "stargate_chevron_engaged" and event[5] == true then
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
            if ctx.show_status then
                ctx.show_status("Invalid address (need 7-9 symbols)")
            end
            return
        end

        STATE.last_feedback = nil
        STATE.last_feedback_at = nil
        STATE.gate = gate
        STATE.gate_id = SG_UTILS.address_to_string(gate.address)
        STATE.disconnected_early = false

        local site = gate.site or gate.name or "<unknown>"
        local fast = SG_UTILS.rs_input(SG_SETTINGS.rs_fast_dial)
        local dialing_type = fast and "Fast Dialing: " or "Dialing: "
        if ctx.show_status then
            ctx.show_status({ dialing_type .. site, STATE.gate_id })
        end
        if ctx.update_dial_progress then
            ctx.update_dial_progress(0)
        end

        local success, reason, cancel_reason = dial_with_cancel(gate, fast)
        if success then
            if ctx.clear_screen_timer then
                ctx.clear_screen_timer()
            end
            local connected_now = ctx.is_wormhole_active and ctx.is_wormhole_active()
            if not connected_now then
                for _ = 1, 30, 1 do
                    sleep(0.1)
                    if ctx.is_wormhole_active and ctx.is_wormhole_active() then
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
                if ctx.show_status then
                    ctx.show_status("Unable to establish wormhole")
                end
                if ctx.clear_screen_timer then
                    ctx.clear_screen_timer()
                end
                if ctx.start_timer then
                    ctx.start_timer("screen", 3)
                end
                return
            end
            if ctx.show_top_message_lines then
                ctx.show_top_message_lines({ "Dialed: " .. gate.site, STATE.gate_id })
            end
            STATE.outbound, STATE.connected = true, true
            if ctx.start_countdown_when_established then
                ctx.start_countdown_when_established()
            end
            return
        end

        local message = dial_failure_message(reason, cancel_reason)
        if reason == "cancelled" or cancel_reason then
            local connection_active = STATE.outbound == false
                or STATE.gate_id == "Incoming"
                or STATE.connected
                or (ctx.is_wormhole_active and ctx.is_wormhole_active())
            if connection_active and (cancel_reason == "incoming" or cancel_reason == "stargate_incoming_wormhole") then
                return
            end
        end

        STATE.outbound = nil
        STATE.connected = false
        STATE.gate = nil
        STATE.gate_id = nil
        if ctx.show_status then
            ctx.show_status(message)
        end
        if ctx.clear_screen_timer then
            ctx.clear_screen_timer()
        end
        if ctx.start_timer then
            ctx.start_timer("screen", 2)
        end
    end

    local function resume_active_wormhole()
        local gate = SG_UTILS.get_inf_gate()
        if not gate or not (ctx.is_wormhole_active and ctx.is_wormhole_active()) then
            return false
        end

        if ctx.clear_screen_timer then
            ctx.clear_screen_timer()
        end
        if ctx.reset_top then
            ctx.reset_top()
        end

        local outgoing = type(gate.isStargateDialingOut) == "function" and gate.isStargateDialingOut() == true
        local open_seconds = ctx.get_open_seconds and ctx.get_open_seconds()
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
            local target_gate = SG_UTILS.find_gate_by_address(addr)
            if ctx.show_status then
                ctx.show_status({ "Active wormhole to: " .. target_gate.site, addr_str })
            end
            local remaining = SG_SETTINGS.timeout
            if open_seconds then
                remaining = math.max(remaining - open_seconds, 0)
            end
            if ctx.start_countdown_when_established then
                ctx.start_countdown_when_established(remaining)
            end
            if ctx.send_alarm_update then
                ctx.send_alarm_update(true)
            end
        else
            STATE.outbound = false
            STATE.gate_id = addr_str ~= "-" and addr_str or "Incoming"
            if ctx.show_incoming_banner then
                ctx.show_incoming_banner()
            end
            if ctx.start_incoming_counter then
                ctx.start_incoming_counter(open_seconds)
            end
            if ctx.send_alarm_update then
                ctx.send_alarm_update(true, true)
            end
            if ctx.send_env_status_message then
                ctx.send_env_status_message()
            end
        end

        return true
    end

    ctx.show_disconnected_screen = show_disconnected_screen
    ctx.disconnect_now = disconnect_now
    ctx.dial_with_cancel = dial_with_cancel
    ctx.handle_selection = handle_selection
    ctx.resume_active_wormhole = resume_active_wormhole
end

return M
