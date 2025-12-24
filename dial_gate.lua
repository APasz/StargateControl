package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local M = {}

function M.init(ctx)
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

    ctx.is_wormhole_active = is_wormhole_active
    ctx.is_wormhole_open = is_wormhole_open
    ctx.get_open_seconds = get_open_seconds
end

return M
