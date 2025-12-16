local PeripheralUtils = {}

local INF_GATE
local INF_GATE_IS_CRYSTAL = false
local INF_GATE_IS_ADVANCED = false
local INF_RS

local function is_cancelled(cancel_check)
    return cancel_check and cancel_check() == true
end

function PeripheralUtils.get_inf_gate(require_gate)
    if require_gate == nil then
        require_gate = true
    end
    if INF_GATE then
        return INF_GATE, INF_GATE_IS_CRYSTAL, INF_GATE_IS_ADVANCED
    end

    INF_GATE = peripheral.find("advanced_crystal_interface")
    if INF_GATE then
        INF_GATE_IS_CRYSTAL = true
        INF_GATE_IS_ADVANCED = true
        print("Found: Adv Crystal Interface")
        return INF_GATE, INF_GATE_IS_CRYSTAL, INF_GATE_IS_ADVANCED
    end

    INF_GATE = peripheral.find("crystal_interface")
    if INF_GATE then
        INF_GATE_IS_CRYSTAL = false
        INF_GATE_IS_ADVANCED = true
        print("Found: Crystal Interface")
        return INF_GATE, INF_GATE_IS_CRYSTAL, INF_GATE_IS_ADVANCED
    end

    INF_GATE = peripheral.find("basic_interface")
    if INF_GATE then
        INF_GATE_IS_CRYSTAL = false
        INF_GATE_IS_ADVANCED = false
        print("Found: Basic Interface")
        return INF_GATE, INF_GATE_IS_CRYSTAL, INF_GATE_IS_ADVANCED
    end

    if require_gate then
        error("Gate Interface not found!")
    end

    return nil, false, false
end

function PeripheralUtils.reset_outputs(inf_rs)
    local target = inf_rs or PeripheralUtils.get_inf_rs()
    if not target then
        return
    end
    for _, value in pairs(redstone.getSides()) do
        target.setOutput(value, false)
    end
end

function PeripheralUtils.reset_stargate()
    local gate = PeripheralUtils.get_inf_gate()
    if not gate then
        return false
    end
    if type(gate.resetStargate) == "function" then
        gate.resetStargate()
        return true
    end
    if type(gate.disconnectStargate) == "function" then
        gate.disconnectStargate()
        return true
    end
    return false
end

function PeripheralUtils.reset_if_chevrons_engaged(cancel_check)
    local gate = PeripheralUtils.get_inf_gate()
    if not gate or type(gate.getChevronsEngaged) ~= "function" then
        return false, 0
    end

    local engaged = gate.getChevronsEngaged() or 0
    if engaged <= 0 then
        return false, engaged
    end

    PeripheralUtils.reset_stargate()

    for _ = 1, 30, 1 do
        if is_cancelled(cancel_check) then
            break
        end
        sleep(0.1)
        local remaining = gate.getChevronsEngaged() or 0
        if remaining <= 0 then
            break
        end
    end

    return true, engaged
end

function PeripheralUtils.get_inf_rs()
    if INF_RS and INF_RS ~= redstone then
        return INF_RS
    end

    local found = peripheral.find("redstone_relay")
    if found then
        INF_RS = found
        PeripheralUtils.reset_outputs(INF_RS)
        return INF_RS
    end

    if not INF_RS then
        INF_RS = redstone
        PeripheralUtils.reset_outputs(INF_RS)
    end
    return INF_RS
end

function PeripheralUtils.rs_input(side)
    local rs = PeripheralUtils.get_inf_rs()
    if not rs or not side then
        return false
    end

    local normalised = string.lower(side)
    if normalised == "any" then
        for _, value in pairs(redstone.getSides()) do
            if rs.getInput(value) then
                return true
            end
        end
        return false
    end

    return rs.getInput(normalised)
end

return PeripheralUtils
