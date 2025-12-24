package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local M = {}

function M.init(ctx)
    local SG_SETTINGS = ctx.settings
    local STATE = ctx.state
    local LOCAL_SITE = ctx.local_site
    local CLIENT_MODEM_SIDE = ctx.client_modem_side
    local ALARM_STATE = ctx.alarm_state
    local ENERGY_STATE = ctx.energy_state
    local ALARM_PROTOCOL = ctx.alarm_protocol
    local ENERGY_PROTOCOL = ctx.energy_protocol
    local INF_GATE = ctx.inf_gate

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
            outbound = STATE.outbound,
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

    ctx.send_incoming_message = send_incoming_message
    ctx.send_env_status_message = send_env_status_message
    ctx.show_remote_env_status = show_remote_env_status
    ctx.send_energy_update = send_energy_update
    ctx.send_alarm_update = send_alarm_update
end

return M
