local peripheral_utils = require("peripheral_utils")
local monitor_utils = require("monitor_utils")

local DialingUtils = {}

local function is_cancelled(cancel_check)
    return cancel_check and cancel_check() == true
end

local function wait_for_fast_engage(interface, symbol, expected_chevron, cancel_check)
    local has_current = type(interface.isCurrentSymbol) == "function"
    local has_chevrons = type(interface.getChevronsEngaged) == "function"
    if not has_current and not has_chevrons then
        return true
    end

    for _ = 1, 60, 1 do
        if is_cancelled(cancel_check) then
            return false, "cancelled"
        end

        local current_ok = has_current and interface.isCurrentSymbol(symbol)
        local engaged_ok = false
        if has_chevrons and expected_chevron then
            local engaged = interface.getChevronsEngaged()
            engaged_ok = type(engaged) == "number" and engaged >= expected_chevron
        end

        if current_ok or engaged_ok then
            return true
        end

        sleep(0.05)
    end

    return false, "timeout"
end

function DialingUtils.dial_fast(gate, cancel_check, progress_cb)
    local interface = peripheral_utils.get_inf_gate()
    if not interface then
        return false, "no_gate"
    end

    local addr = gate.address
    local addr_len = #addr
    local start = 1
    if type(interface.getChevronsEngaged) == "function" then
        start = (interface.getChevronsEngaged() or 0) + 1
    end

    for chevron = start, addr_len, 1 do
        if is_cancelled(cancel_check) then
            peripheral_utils.reset_stargate()
            return false, "cancelled"
        end
        local symbol = addr[chevron]

        interface.engageSymbol(symbol)
        monitor_utils.update_line("Encoded: " .. symbol, 2)
        local engaged, engage_reason = wait_for_fast_engage(interface, symbol, chevron, cancel_check)
        if not engaged then
            peripheral_utils.reset_stargate()
            if engage_reason == "cancelled" or is_cancelled(cancel_check) then
                return false, "cancelled"
            end
            return false, "failed"
        end
        if is_cancelled(cancel_check) then
            peripheral_utils.reset_stargate()
            return false, "cancelled"
        end
        if progress_cb then
            progress_cb(chevron, symbol, addr_len)
        end
        sleep(0.7)
    end
    monitor_utils.update_line("", 2)
    return true
end

function DialingUtils.dial_slow(gate, cancel_check, progress_cb)
    local interface = peripheral_utils.get_inf_gate(false)
    if not interface then
        return false, "no_gate"
    end

    local is_milky = type(interface.openChevron) == "function"
    local addr = gate.address
    local addr_len = #addr
    local start = 1
    if type(interface.getChevronsEngaged) == "function" then
        start = (interface.getChevronsEngaged() or 0) + 1
    end

    for chevron = start, addr_len, 1 do
        if is_cancelled(cancel_check) then
            peripheral_utils.reset_stargate()
            return false, "cancelled"
        end
        local symbol = addr[chevron]
        monitor_utils.update_line("Encoding: " .. symbol, 2)

        if chevron % 2 == 0 then
            interface.rotateClockwise(symbol)
        else
            interface.rotateAntiClockwise(symbol)
        end

        while not interface.isCurrentSymbol(symbol) do
            if is_cancelled(cancel_check) then
                peripheral_utils.reset_stargate()
                return false, "cancelled"
            end
            sleep(0)
        end
        sleep(0.1)
        if is_milky then
            interface.openChevron()
            sleep(0.45)
            interface.closeChevron()
        else
            interface.encodeChevron()
            sleep(0.1)
        end
        monitor_utils.update_line("Encoded: " .. symbol, 2)
        if is_cancelled(cancel_check) then
            peripheral_utils.reset_stargate()
            return false, "cancelled"
        end
        if progress_cb then
            progress_cb(chevron, symbol, addr_len)
        end
        sleep(0.7)
    end
    monitor_utils.update_line("", 2)
    return true
end

function DialingUtils.dial(gate, fast, cancel_check, progress_cb)
    local interface = peripheral_utils.get_inf_gate(false)
    if not interface then
        print("No gate interface found")
        return false, "no_gate"
    end

    peripheral_utils.reset_if_chevrons_engaged(cancel_check)

    if type(interface.setChevronConfiguration) == "function" then
        local addr_len = #gate.address
        if addr_len == 9 then
            interface.setChevronConfiguration({ 1, 2, 3, 4, 5, 6, 7, 8 })
        else
            interface.setChevronConfiguration({ 1, 2, 3, 6, 7, 8, 4, 5 })
        end
    end

    if fast then
        if type(interface.engageSymbol) ~= "function" then
            print("Falling back to slow dial")
            return DialingUtils.dial_slow(gate, cancel_check, progress_cb)
        else
            return DialingUtils.dial_fast(gate, cancel_check, progress_cb)
        end
    else
        if type(interface.rotateClockwise) ~= "function" then
            print("Falling back to fast dial")
            return DialingUtils.dial_fast(gate, cancel_check, progress_cb)
        else
            return DialingUtils.dial_slow(gate, cancel_check, progress_cb)
        end
    end
end

return DialingUtils
