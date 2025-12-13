package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_ADDRESSES = require("addresses")

local U = {}
local INF_GATE
local INF_GATE_IS_CRYSTAL = false
local INF_GATE_IS_ADVANCED = false
local INF_RS
local INF_MON
U.addr_input = nil
local LINE_OFFSET = 0
local MON_SIZE = nil
local WARNED_NO_SITE = false

local function is_cancelled(cancel_check)
    return cancel_check and cancel_check() == true
end

local function normalise_name(name)
    if type(name) ~= "string" then
        return nil, nil
    end
    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
    if not trimmed or trimmed == "" then
        return nil, nil
    end
    return trimmed, string.lower(trimmed)
end

local function after_last_underscore(str)
    if type(str) ~= "string" then
        return nil
    end
    return str:match(".*_(.*)$")
end

local function get_site(override)
    if not override then
        local label = os.getComputerLabel()
        override = after_last_underscore(label)
    end
    return normalise_name(override)
end

local function to_set(list)
    local t = {}
    for _, v in ipairs(list or {}) do
        local _, normalised = normalise_name(v)
        if normalised then
            t[normalised] = true
        end
    end
    return t
end

local function find_local_gate(all, site)
    if not site then
        return nil
    end
    for _, g in ipairs(all or {}) do
        local _, gate_site = normalise_name(g.site)
        if gate_site == site then
            return g
        end
    end
end

local function intergalaxial_allowed(local_gate, target_gate)
    if not local_gate or not target_gate then
        return false
    end

    local local_set = to_set(local_gate.intergalaxial)
    local target_set = to_set(target_gate.intergalaxial)
    if not next(local_set) or not next(target_set) then
        return false
    end

    local _, local_site = normalise_name(local_gate.site)
    local _, target_site = normalise_name(target_gate.site)

    local local_allows = local_set["*"] or (target_site and local_set[target_site])
    local target_allows = target_set["*"] or (local_site and target_set[local_site])

    return local_allows and target_allows
end

local function allowed_destinations(all, site)
    if not site then
        return nil
    end
    for _, g in ipairs(all or {}) do
        local _, gate_site = normalise_name(g.site)
        if gate_site == site then
            local allowed = to_set(g.only_to)
            if next(allowed) then
                return allowed
            end
            return nil
        end
    end
end

function U.filtered_addresses(all, site_override)
    local site_display, site_id = get_site(site_override)
    if not site_id and not WARNED_NO_SITE then
        WARNED_NO_SITE = true
        print("Warning: site is unknown; set PC's name or settings.site to enable filtering")
    end
    local display_text = site_display or site_id or "<unknown>"
    local local_gate = find_local_gate(all, site_id)
    local galaxy_display, galaxy_id = normalise_name(local_gate and local_gate.galaxy)
    local galaxy_text = galaxy_display or galaxy_id or "<any>"
    print("Site: " .. display_text .. " @ " .. galaxy_text)
    local allowed_to = allowed_destinations(all, site_id)
    local result = {}
    for _, g in ipairs(all or {}) do
        local hide_list = to_set(g.hide_on)
        local allowed_list = to_set(g.only_from)
        local _, gate_site = normalise_name(g.site)
        local _, gate_galaxy = normalise_name(g.galaxy)

        local hide = site_id and (hide_list[site_id] or gate_site == site_id)
        local allowed = (not g.only_from) or not site_id or allowed_list[site_id]
        local allowed_dest = (not allowed_to) or (gate_site and allowed_to[gate_site])
        local galaxy_ok = true
        if galaxy_id then
            if gate_galaxy and gate_galaxy ~= galaxy_id then
                galaxy_ok = intergalaxial_allowed(local_gate, g) or false
            end
        end

        if not hide and allowed and allowed_dest and galaxy_ok then
            table.insert(result, g)
        end
    end
    return result
end

function U.get_inf_gate(require_gate)
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
    local gate = U.get_inf_gate()
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
    local gate = U.get_inf_gate()
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
    if INF_RS and INF_RS ~= redstone then
        return INF_RS
    end

    local found = peripheral.find("redstone_relay")
    if found then
        INF_RS = found
        U.reset_outputs(INF_RS)
        return INF_RS
    end

    if not INF_RS then
        INF_RS = redstone
        U.reset_outputs(INF_RS)
    end
    return INF_RS
end

function U.rs_input(side)
    local rs = U.get_inf_rs()
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

local function init_monitor(scale, should_clear)
    if not INF_MON then
        return
    end
    INF_MON.setTextScale(scale or 1)
    INF_MON.setCursorPos(1, 1)
    if should_clear then
        INF_MON.clear()
    end
    MON_SIZE = nil
end

local function update_mon_size()
    if not INF_MON or type(INF_MON.getSize) ~= "function" then
        MON_SIZE = nil
        return
    end
    local w, h = INF_MON.getSize()
    if w and h then
        MON_SIZE = { w = w, h = h }
    end
end

function U.get_inf_mon()
    if INF_MON then
        return INF_MON
    end

    INF_MON = peripheral.find("monitor")
    if INF_MON then
        init_monitor(1, true)
        update_mon_size()
    end
    return INF_MON
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
    MON_SIZE = nil
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
    if not MON_SIZE then
        update_mon_size()
    end

    local width = (MON_SIZE and MON_SIZE.w) or default_width or 32
    local height = (MON_SIZE and MON_SIZE.h) or default_height or 15

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

function U.clear_all_lines()
    local _, h = U.get_monitor_size()
    U.clear_lines(h, 1)
    U.reset_line_offset()
end

function U.update_line(text, line, log_text)
    line = (line or 1) + LINE_OFFSET
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
    LINE_OFFSET = math.max(0, offset or 0)
end

function U.reset_line_offset()
    U.set_line_offset(0)
    return LINE_OFFSET
end

function U.wait_for_touch()
    local mon = U.get_inf_mon()
    if not mon then
        return
    end
    while true do
        local _, _, _, y = os.pullEvent("monitor_touch")
        if y >= 1 and y <= #SG_ADDRESSES then
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

function U.addresses_match(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function U.lookup_site(addr)
    for _, g in ipairs(SG_ADDRESSES) do
        if U.addresses_match(addr, g.address) then
            return g.site
        end
    end
end

function U.find_gate_by_address(addr)
    for _, gate in ipairs(SG_ADDRESSES or {}) do
        if U.addresses_match(addr, gate.address) then
            return gate
        end
    end
    return { site = "Manual", address = addr }
end

function U.compute_menu_layout(addr_count)
    local mon_width, mon_height = U.get_monitor_size(32, 15)
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

function U.get_selection(ev, p2, p3, p4, addresses)
    local list = addresses or SG_ADDRESSES
    local addr_count = #(list or {})

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
            return { site = U.lookup_site(addr) or "Manual", address = addr }
        end

        print("Invalid address. Enter 6-9 numbers separated by spaces/commas/dashes")
        return
    end

    if ev == "monitor_touch" then
        if addr_count <= 0 then
            return
        end

        local x, y = p3, p4
        if not (x and y) then
            return
        end

        local layout = U.compute_menu_layout(addr_count)
        if not layout or y < 1 or y > layout.rows or x < 1 or x > layout.usable_width then
            return
        end

        local col = math.floor((x - 1) / layout.col_width) + 1
        if col < 1 or col > layout.columns then
            return
        end

        local idx = (col - 1) * layout.rows + y
        if idx >= 1 and idx <= addr_count then
            return idx
        end
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

    local interface = U.get_inf_gate()
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

    local base = gate.site or ""
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

local function wait_for_fast_engage(interface, symbol, expected_chevron, cancel_check)
    local has_current = type(interface.isCurrentSymbol) == "function"
    local has_chevrons = type(interface.getChevronsEngaged) == "function"
    if not has_current and not has_chevrons then
        return true
    end

    for _ = 1, 60, 1 do
        if is_cancelled(cancel_check) then
            return false
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

    return true
end

function U.dial_fast(gate, cancel_check)
    local interface = U.get_inf_gate()
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
        local engaged = wait_for_fast_engage(interface, symbol, chevron, cancel_check)
        if not engaged or is_cancelled(cancel_check) then
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
