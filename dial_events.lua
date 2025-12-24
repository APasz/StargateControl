local M = {}

function M.init(ctx)
    local SG_UTILS = ctx.utils
    local SG_SETTINGS = ctx.settings
    local STATE = ctx.state
    local LOCAL_SITE = ctx.local_site
    local FEEDBACK_BLACKLIST_TYPES = ctx.feedback_blacklist_types or {}
    local FEEDBACK_BLACKLIST_CODES = ctx.feedback_blacklist_codes or {}

    local FEEDBACK_CODE_MAP = {
        [0] = { type = "info", label = "none" },
        [-1] = { type = "error", label = "unknown" },
        [1] = { type = "info", label = "symbol_encoded" },
        [-2] = { type = "error", label = "symbol_in_address" },
        [-3] = { type = "error", label = "symbol_out_of_bounds" },
        [-4] = { type = "error", label = "encode_when_connected" },
        [2] = { type = "info", label = "connection_established.system_wide" },
        [3] = { type = "info", label = "connection_established.interstellar" },
        [4] = { type = "info", label = "connection_established.intergalactic" },
        [-5] = { type = "major_error", label = "incomplete_address" },
        [-6] = { type = "major_error", label = "invalid_address" },
        [-7] = { type = "major_error", label = "not_enough_power" },
        [-8] = { type = "major_error", label = "self_obstructed" },
        [-9] = { type = "skippable_error", label = "target_obstructed" },
        [-10] = { type = "major_error", label = "self_dial" },
        [-11] = { type = "major_error", label = "same_system_dial" },
        [-12] = { type = "major_error", label = "already_connected" },
        [-13] = { type = "major_error", label = "no_galaxy" },
        [-14] = { type = "major_error", label = "no_dimensions" },
        [-15] = { type = "major_error", label = "no_stargates" },
        [-16] = { type = "skippable_error", label = "target_restricted" },
        [-17] = { type = "major_error", label = "invalid_8_chevron_address" },
        [-18] = { type = "major_error", label = "invalid_system_wide_connection" },
        [-19] = { type = "major_error", label = "target_not_whitelisted" },
        [-20] = { type = "skippable_error", label = "not_whitelisted_by_target" },
        [-21] = { type = "major_error", label = "target_blacklisted" },
        [-22] = { type = "skippable_error", label = "blacklisted_by_target" },
        [7] = { type = "info", label = "connection_ended.disconnect" },
        [8] = { type = "info", label = "connection_ended.point_of_origin" },
        [9] = { type = "info", label = "connection_ended.stargate_network" },
        [10] = { type = "info", label = "connection_ended.autoclose" },
        [-23] = { type = "error", label = "exceeded_connection_time" },
        [-24] = { type = "error", label = "ran_out_of_power" },
        [-25] = { type = "error", label = "connection_rerouted" },
        [-26] = { type = "error", label = "wrong_disconnect_side" },
        [-27] = { type = "error", label = "connection_forming" },
        [-28] = { type = "error", label = "stargate_destroyed" },
        [-29] = { type = "major_error", label = "could_not_reach_target_stargate" },
        [-30] = { type = "error", label = "interrupted_by_incoming_connection" },
        [11] = { type = "info", label = "chevron_opened" },
        [12] = { type = "info", label = "rotating" },
        [-31] = { type = "info", label = "rotation_blocked" },
        [-32] = { type = "info", label = "not_rotating" },
        [13] = { type = "info", label = "rotation_stopped" },
        [-33] = { type = "error", label = "chevron_already_opened" },
        [-34] = { type = "error", label = "chevron_already_closed" },
        [-35] = { type = "error", label = "chevron_not_open" },
        [-36] = { type = "error", label = "cannot_encode_point_of_origin" },
        [-37] = { type = "error", label = "target_not_loaded" },
    }

    local function now_ms()
        return (os.epoch and os.epoch("utc")) or (os.clock and (os.clock() * 1000)) or 0
    end

    local function humanize_feedback_label(label)
        if type(label) ~= "string" then
            return nil
        end
        local normalized = label:gsub("[_%.]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if normalized == "" then
            return nil
        end
        return normalized
    end

    local function build_feedback_entry(code, desc)
        if type(code) ~= "number" then
            return nil
        end

        local mapped = FEEDBACK_CODE_MAP[code]
        local feedback_type = mapped and mapped.type or nil
        local label = (type(desc) == "string" and desc ~= "" and desc) or (mapped and mapped.label) or nil
        local display = humanize_feedback_label(label) or ("Feedback " .. tostring(code))
        local suppressed = (FEEDBACK_BLACKLIST_CODES and FEEDBACK_BLACKLIST_CODES[code] == true)
            or (feedback_type and FEEDBACK_BLACKLIST_TYPES and FEEDBACK_BLACKLIST_TYPES[feedback_type] == true)

        return {
            code = code,
            type = feedback_type,
            label = label,
            display = display,
            suppressed = suppressed,
        }
    end

    local function record_feedback(code, desc)
        local entry = build_feedback_entry(code, desc)
        STATE.last_feedback = entry
        STATE.last_feedback_at = now_ms()
        return entry
    end

    local function feedback_lines(title, code, desc)
        local entry = record_feedback(code, desc)
        if entry and not entry.suppressed and entry.display then
            return { title, "Reason: " .. entry.display }
        end
        return title
    end

    local function handle_timer_event(timer_id)
        if ctx.tick_timer_id and timer_id == ctx.tick_timer_id then
            ctx.tick_timer_id = nil
            if ctx.process_tick then
                ctx.process_tick()
            end
        end
    end

    local function handle_redstone_event()
        if STATE.connected or STATE.outbound == false then
            return
        end
        if ctx.has_timer and ctx.has_timer("screen") then
            if ctx.clear_screen_timer then
                ctx.clear_screen_timer()
            end
        end
        if ctx.screen then
            ctx.screen()
        end
    end

    local function handle_terminate()
        if ctx.show_status then
            ctx.show_status("! UNAVAILABLE !")
        end
        return true
    end

    local function handle_user_input(ev, p2, p3, p4)
        if STATE.waiting_disconnect then
            return
        end

        if ctx.has_timer and ctx.has_timer("screen") then
            if ctx.clear_screen_timer then
                ctx.clear_screen_timer()
            end
            if not STATE.connected and STATE.outbound ~= false then
                if ctx.screen then
                    ctx.screen()
                end
            end
            return
        end

        if STATE.connected or STATE.outbound == false then
            if STATE.outbound == true then
                if ctx.is_wormhole_open and ctx.is_wormhole_open() then
                    if ctx.disconnect_now then
                        ctx.disconnect_now(true)
                    end
                end
            elseif ev == "monitor_touch" then
                if ctx.send_incoming_message then
                    ctx.send_incoming_message()
                end
            end
            return
        end

        local sel = SG_UTILS.get_selection(ev, p2, p3, p4, ctx.addresses)
        if sel and ctx.handle_selection then
            ctx.handle_selection(sel)
        end
    end

    local function stargate_disconnected(p2, feedback_num, feedback_desc)
        if STATE.connected and ctx.reset_timer then
            ctx.reset_timer()
        end
        if ctx.send_alarm_update then
            ctx.send_alarm_update(false)
        end
        STATE.connected = false
        STATE.outbound = nil
        STATE.gate = nil
        STATE.gate_id = nil
        if ctx.show_disconnected_screen then
            ctx.show_disconnected_screen(feedback_lines("Stargate Disconnected", feedback_num, feedback_desc))
        end
    end

    local function stargate_message_received(p2, message)
        if type(message) ~= "string" then
            return
        end

        if message == "sg_disconnect" then
            if STATE.connected and STATE.outbound == true then
                SG_UTILS.update_line("Remote disconnect requested", 3)
                if ctx.disconnect_now then
                    ctx.disconnect_now(true)
                end
            end
            return
        end

        if ctx.show_remote_env_status and ctx.show_remote_env_status(message) then
            return
        end
    end

    local function iris_site_matches(payload)
        if not LOCAL_SITE then
            return true
        end
        local _, remote_site = SG_UTILS.normalise_name(payload.site)
        return remote_site and remote_site == LOCAL_SITE
    end

    local function apply_iris_command(command)
        local gate = SG_UTILS.get_inf_gate(false)
        if not gate then
            return
        end

        if type(gate.hasIris) == "function" and gate.hasIris() ~= true then
            return
        end

        if command == "open" then
            if type(gate.openIris) == "function" then
                pcall(gate.openIris)
            elseif type(gate.setIrisOpen) == "function" then
                pcall(gate.setIrisOpen, true)
            elseif type(gate.setIrisState) == "function" then
                pcall(gate.setIrisState, true)
            end
        elseif command == "close" then
            if type(gate.closeIris) == "function" then
                pcall(gate.closeIris)
            elseif type(gate.setIrisOpen) == "function" then
                pcall(gate.setIrisOpen, false)
            elseif type(gate.setIrisState) == "function" then
                pcall(gate.setIrisState, false)
            end
        elseif command == "toggle" then
            if type(gate.toggleIris) == "function" then
                pcall(gate.toggleIris)
            end
        end
    end

    local function handle_rednet_message(sender, payload, protocol)
        local iris_protocol = ctx.iris_protocol
        if iris_protocol == false or iris_protocol == "" then
            return
        end
        if iris_protocol and protocol ~= iris_protocol then
            return
        end
        if type(payload) ~= "table" or payload.type ~= "iris" then
            return
        end
        if not iris_site_matches(payload) then
            return
        end

        local command = payload.command
        if type(command) ~= "string" then
            return
        end
        command = string.lower(command)
        if command ~= "open" and command ~= "close" and command ~= "toggle" then
            return
        end
        apply_iris_command(command)
    end

    local function stargate_chevron_engaged(p2, count, engaged, incoming, symbol)
        if incoming then
            if STATE.outbound ~= true and ctx.send_alarm_update then
                ctx.send_alarm_update(true)
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
            if ctx.send_alarm_update then
                ctx.send_alarm_update(false)
            end
            return
        end
        if ctx.show_incoming_banner then
            ctx.show_incoming_banner()
        end
        STATE.outbound = false
        STATE.connected = true
        STATE.gate = nil
        STATE.gate_id = "Incoming"
        STATE.disconnected_early = false
        if ctx.send_alarm_update then
            ctx.send_alarm_update(true, true)
        end
        if ctx.start_incoming_counter then
            ctx.start_incoming_counter(ctx.get_open_seconds and ctx.get_open_seconds())
        end
        if ctx.send_env_status_message then
            ctx.send_env_status_message()
        end
    end

    local function stargate_outgoing_wormhole(p2, address)
        if ctx.send_alarm_update then
            ctx.send_alarm_update(true)
        end
        if ctx.clear_screen_timer then
            ctx.clear_screen_timer()
        end
        SG_UTILS.update_line("Wormhole Open", 3)
        SG_UTILS.update_line("", 4)
        STATE.outbound = true
        STATE.connected = true
        if not STATE.gate_id then
            STATE.gate_id = SG_UTILS.address_to_string(address)
        end
        if ctx.start_countdown_when_established then
            ctx.start_countdown_when_established()
        end
    end

    local function stargate_reset(p2, feedback_num, feedback_desc)
        if ctx.send_alarm_update then
            ctx.send_alarm_update(false)
        end
        local message = feedback_lines("Stargate Reset", feedback_num, feedback_desc)
        SG_UTILS.reset_outputs(SG_UTILS.get_inf_rs())
        if SG_SETTINGS.reset_on_gate_reset then
            if ctx.reset_timer then
                ctx.reset_timer()
            end
            STATE.connected = false
            STATE.outbound = nil
            STATE.gate = nil
            STATE.gate_id = nil
            STATE.disconnected_early = false
            if ctx.show_disconnected_screen then
                ctx.show_disconnected_screen(message)
            end
        end
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
        rednet_message = handle_rednet_message,
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

    local function dispatch_non_user_event(event)
        local name = event[1]

        local handler = event_handlers[name]
        if handler then
            if stargate_clear_screen_events[name] and ctx.clear_screen_timer then
                ctx.clear_screen_timer()
            end
            return handler(table.unpack(event, 2))
        end
    end

    local function dispatch_event(event)
        local name = event[1]
        local handler = user_event_handlers[name]
        if handler then
            return handler(table.unpack(event, 2))
        end

        return dispatch_non_user_event(event)
    end

    ctx.user_event_handlers = user_event_handlers
    ctx.event_handlers = event_handlers
    ctx.stargate_clear_screen_events = stargate_clear_screen_events
    ctx.dispatch_non_user_event = dispatch_non_user_event
    ctx.dispatch_event = dispatch_event
    ctx.handle_terminate = handle_terminate
end

return M
