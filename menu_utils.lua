local MenuUtils = {}

function MenuUtils.compute_menu_layout(addr_count, mon_width, mon_height)
    local mon_width_value = mon_width or 32
    local mon_height_value = mon_height or 15
    local usable_width = math.max(mon_width_value - 1, 1)

    local min_col_width = 6
    local comfy_max_cols = math.max(1, math.min(math.floor(usable_width / min_col_width), addr_count))
    local hard_max_cols = math.max(1, math.min(usable_width, addr_count))

    local columns = 1
    local rows = math.ceil(addr_count / columns)

    while rows > mon_height_value and columns < comfy_max_cols do
        columns = columns + 1
        rows = math.ceil(addr_count / columns)
    end

    while rows > mon_height_value and columns < hard_max_cols do
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
        width = mon_width_value,
        height = mon_height_value,
        usable_width = usable_width,
    }
end

function MenuUtils.get_selection(ev, p2, p3, p4, addresses, mon_width, mon_height, is_valid_address, lookup_site)
    local list = addresses or {}
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
        if is_valid_address and is_valid_address(addr) then
            return { site = (lookup_site and lookup_site(addr, list)) or "Manual", address = addr }
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

        local layout = MenuUtils.compute_menu_layout(addr_count, mon_width, mon_height)
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

function MenuUtils.wait_for_touch(max_index, mon)
    if not mon then
        return
    end
    while true do
        local _, _, _, y = os.pullEvent("monitor_touch")
        if y >= 1 and (not max_index or y <= max_index) then
            return y
        end
    end
end

function MenuUtils.wait_for_keyboard()
    return tonumber(read())
end

function MenuUtils.wait_for_disconnect_request()
    while true do
        local event = { os.pullEvent() }
        local name = event[1]
        if name == "monitor_touch" or name == "key" or name == "char" then
            return
        end
    end
end

return MenuUtils
