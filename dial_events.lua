package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local M = {}

function M.init(ctx)
    local SG_SETTINGS = ctx.settings
    local STATE = ctx.state

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
            ctx.show_disconnected_screen()
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
                ctx.show_disconnected_screen()
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
