package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local sg_settings = require("settings")

local U = {}
local inf_gate
local inf_gate_is_crystal = false
local inf_gate_is_advanced = false
local inf_rs
local inf_mon
U.addr_input = nil
local line_offset = 0
local mon_size = nil
local function is_cancelled(cancel_check)
    return cancel_check and cancel_check() == true
end

function U.get_inf_gate(require_gate)
    if require_gate == nil then
        require_gate = true
    end
    if inf_gate then
        return inf_gate, inf_gate_is_crystal, inf_gate_is_advanced
    end

    inf_gate = peripheral.find("advanced_crystal_interface")
    if inf_gate then
        inf_gate_is_crystal = true
        inf_gate_is_advanced = true
        print("Found: Adv Crystal Interface")
        return inf_gate, inf_gate_is_crystal, inf_gate_is_advanced
    end

    inf_gate = peripheral.find("crystal_interface")
    if inf_gate then
        inf_gate_is_crystal = false
        inf_gate_is_advanced = true
        print("Found: Crystal Interface")
        return inf_gate, inf_gate_is_crystal, inf_gate_is_advanced
    end

    inf_gate = peripheral.find("basic_interface")
    if inf_gate then
        inf_gate_is_crystal = false
        inf_gate_is_advanced = false
        print("Found: Basic Interface")
        return inf_gate, inf_gate_is_crystal, inf_gate_is_advanced
    end

    if require_gate then
        error("Gate Interface not found!")
    end

    return nil, false, false
end

function U.reset_outputs(inf_rs)
    local target = inf_rs or U.get_inf_rs()
    if not target then
        return
    end
    for _, value in pairs(redstone.getSides()) do
        target.setOutput(value, false)
    end
end

function U.reset_stargate()
    local gate = U.get_inf_gate(false)
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

function U.reset_if_chevrons_engaged(cancel_check)
    local gate = U.get_inf_gate(false)
    if not gate or type(gate.getChevronsEngaged) ~= "function" then
        return false, 0
    end

    local engaged = gate.getChevronsEngaged() or 0
    if engaged <= 0 then
        return false, engaged
    end

    U.reset_stargate()

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

function U.get_inf_rs()
    if inf_rs and inf_rs ~= redstone then
        return inf_rs
    end

    local found = peripheral.find("redstone_relay")
    if found then
        inf_rs = found
        U.reset_outputs(inf_rs)
        return inf_rs
    end

    if not inf_rs then
        inf_rs = redstone
        U.reset_outputs(inf_rs)
    end
    return inf_rs
end

function U.rs_input(side)
    local rs = U.get_inf_rs()
    if not rs or not side then
        return false
    end

    local normalized = string.lower(side)
    if normalized == "any" then
        for _, value in pairs(redstone.getSides()) do
            if rs.getInput(value) then
                return true
            end
        end
        return false
    end

    return rs.getInput(normalized)
end

local function init_monitor(scale, should_clear)
    if not inf_mon then
        return
    end
    inf_mon.setTextScale(scale or 1)
    inf_mon.setCursorPos(1, 1)
    if should_clear then
        inf_mon.clear()
    end
    mon_size = nil
end

local function update_mon_size()
    if not inf_mon or type(inf_mon.getSize) ~= "function" then
        mon_size = nil
        return
    end
    local w, h = inf_mon.getSize()
    if w and h then
        mon_size = { w = w, h = h }
    end
end

function U.get_inf_mon()
    if inf_mon then
        return inf_mon
    end

    inf_mon = peripheral.find("monitor")
    if inf_mon then
        init_monitor(1, true)
        update_mon_size()
    end
    return inf_mon
end

function U.prepare_monitor(scale, should_clear)
    local mon = U.get_inf_mon()
    if not mon then
        return
    end
    if scale then
        mon.setTextScale(scale)
    end
    mon.setCursorPos(1, 1)
    if should_clear then
        mon.clear()
    end
    mon_size = nil
    update_mon_size()
end

function U.set_text_color(color)
    local mon = U.get_inf_mon()
    if mon and mon.isColor and mon.isColor() and color then
        mon.setTextColor(color)
    end
end

function U.reset_text_color()
    local mon = U.get_inf_mon()
    if mon and mon.isColor and mon.isColor() then
        mon.setTextColor(colors.white)
    end
end

function U.get_monitor_size(default_width, default_height)
    U.get_inf_mon()
    if not mon_size then
        update_mon_size()
    end

    local width = (mon_size and mon_size.w) or default_width or 32
    local height = (mon_size and mon_size.h) or default_height or 15

    if not width or width < 1 then
        width = 1
    end
    if not height or height < 1 then
        height = 1
    end
    return width, height
end

function U.clear_lines(count, start_line)
    local mon = U.get_inf_mon()
    if not mon or not count or count <= 0 then
        return
    end
    local line = start_line or 1
    for i = 0, count - 1, 1 do
        mon.setCursorPos(1, line + i)
        mon.clearLine()
    end
end

function U.update_line(text, line, log_text)
    line = (line or 1) + line_offset
    text = text or ""
    log_text = log_text or text

    local mon = U.get_inf_mon()
    local width = select(1, U.get_monitor_size())

    -- Wrap text so it does not overflow the monitor width
    local segments = {}
    local idx = 1
    local len = #text
    if len == 0 then
        segments[1] = ""
    else
        while idx <= len do
            segments[#segments + 1] = string.sub(text, idx, idx + width - 1)
            idx = idx + width
        end
    end

    if mon then
        for i, segment in ipairs(segments) do
            local target_line = line + i - 1
            mon.setCursorPos(1, target_line)
            mon.clearLine()
            mon.write(segment)
        end
        print(log_text)
        return #segments
    else
        print(":" .. log_text)
        return #segments
    end
end

function U.show_top_message(text)
    U.reset_line_offset()
    return U.update_line(text or "", 1)
end

function U.write_lines(lines, start_line)
    local total = 0
    local base = start_line or 1

    for i, txt in ipairs(lines or {}) do
        local written = U.update_line(txt or "", base + total) or 1
        total = total + written
    end

    return total
end

function U.set_line_offset(offset)
    line_offset = math.max(0, offset or 0)
end

function U.reset_line_offset()
    U.set_line_offset(0)
    return line_offset
end

function U.wait_for_touch()
    local mon = U.get_inf_mon()
    if not mon then
        return
    end
    while true do
        local _, _, _, y = os.pullEvent("monitor_touch")
        if y >= 1 and y <= #sg_settings.addresses then
            U.addr_input = y
            return
        end
    end
end

function U.wait_for_keyboard()
    U.addr_input = tonumber(read())
end

function U.wait_for_disconnect_request()
    while true do
        local event = { os.pullEvent() }
        local name = event[1]
        if name == "monitor_touch" or name == "key" or name == "char" then
            return
        end
    end
end

function U.get_selection(ev, p2, p3, p4)
    if ev == "key" or ev == "char" then
        local raw = read()
        local numeric_sel = tonumber(raw)
        if numeric_sel then
            return numeric_sel
        end

        local addr = {}
        for token in raw:gmatch("%d+") do
            addr[#addr + 1] = tonumber(token)
        end

        -- Accept 6–9 symbols; if origin is missing (7), append 0
        if #addr == 6 then
            addr[7] = 0
        end
        if U.is_valid_address(addr) then
            return { name = "Manual", address = addr }
        end

        print("Invalid address. Enter 6-9 numbers separated by spaces/commas/dashes")
        return
    end

    if ev == "monitor_touch" and p4 and p4 >= 1 and p4 <= #sg_settings.addresses then
        return p4
    end
end

function U.is_valid_address(addr)
    if type(addr) ~= "table" then
        return false
    end
    local len = #addr
    if len < 7 or len > 9 then
        return false
    end
    for i = 1, len, 1 do
        if type(addr[i]) ~= "number" then
            return false
        end
    end
    return true
end

function U.address_to_string(addr)
    if not addr then
        return "-"
    end

    local interface = U.get_inf_gate(false)
    if interface and type(interface.addressToString) == "function" then
        local converted = interface.addressToString(addr)
        if converted and converted ~= "-" and converted ~= "" then
            return converted
        end
    end

    local pieces = {}
    for i, v in ipairs(addr) do
        pieces[#pieces + 1] = tostring(v)
    end
    return table.concat(pieces, "-")
end

function U.format_address(idx, gate, max_width, with_number)
    if not gate then
        return ""
    end

    local base = gate.name or ""
    local text = with_number == false and base or (idx .. " = " .. base)
    if not max_width or #text <= max_width then
        return text
    end

    if max_width <= 3 then
        return string.sub(text, 1, max_width)
    end

    return string.sub(text, 1, max_width - 3) .. "..."
end

function U.pad_to_width(text, width)
    text = text or ""
    if not width or #text >= width then
        return text .. " "
    end
    return text .. string.rep(" ", width - #text)
end

function U.dial_fast(gate, cancel_check)
    local interface = U.get_inf_gate(false)
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
            U.reset_stargate()
            return false, "cancelled"
        end
        local symbol = addr[chevron]

        interface.engageSymbol(symbol)
        U.update_line("Encoded: " .. symbol, 2)
        if is_cancelled(cancel_check) then
            U.reset_stargate()
            return false, "cancelled"
        end
        sleep(0.7)
    end
    U.update_line("", 2)
    return true
end

function U.dial_slow(gate, cancel_check)
    local interface = U.get_inf_gate(false)
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
            U.reset_stargate()
            return false, "cancelled"
        end
        local symbol = addr[chevron]
        U.update_line("Encoding: " .. symbol, 2)

        if chevron % 2 == 0 then
            interface.rotateClockwise(symbol)
        else
            interface.rotateAntiClockwise(symbol)
        end

        while not interface.isCurrentSymbol(symbol) do
            if is_cancelled(cancel_check) then
                U.reset_stargate()
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
        U.update_line("Encoded: " .. symbol, 2)
        if is_cancelled(cancel_check) then
            U.reset_stargate()
            return false, "cancelled"
        end
        sleep(0.7)
    end
    U.update_line("", 2)
    return true
end

function U.dial(gate, fast, cancel_check)
    local interface = U.get_inf_gate(false)
    if not interface then
        print("No gate interface found")
        return false, "no_gate"
    end

    U.reset_if_chevrons_engaged(cancel_check)

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
            return U.dial_slow(gate, cancel_check)
        else
            return U.dial_fast(gate, cancel_check)
        end
    else
        if type(interface.rotateClockwise) ~= "function" then
            print("Falling back to fast dial")
            return U.dial_fast(gate, cancel_check)
        else
            return U.dial_slow(gate, cancel_check)
        end
    end
end
return U
