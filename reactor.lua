package.path = package.path .. ";disk/?.lua;disk/?/init.lua"

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
    monitor_scale = 1,
    -- monitor text scale
    refresh_interval = 1,
    -- seconds between updates
    reactor_name = nil,
    -- optional peripheral name; nil auto-detects
    induction_name = nil,
    -- optional induction port name; nil auto-detects
}
]]

local function load_or_create_settings()
    if fs.exists(SETTINGS_PATH) then
        local ok, config = pcall(require, "settings")
        if ok then
            return config
        end
        error(config, 0)
    end

    local handle = fs.open(SETTINGS_PATH, "w")
    if not handle then
        error("Missing settings.lua and unable to create it", 0)
    end

    handle.write(DEFAULT_SETTINGS_CONTENT)
    handle.close()

    local ok, config = pcall(require, "settings")
    if not ok then
        error(config, 0)
    end

    print("Created default settings.lua")
    return config
end

local SETTINGS = load_or_create_settings()

local monitor_scale = tonumber(SETTINGS.monitor_scale) or 0.5
if monitor_scale <= 0 then
    monitor_scale = 0.5
end

local refresh_interval = tonumber(SETTINGS.refresh_interval) or 1
if refresh_interval <= 0 then
    refresh_interval = 1
end

local REACTOR_TYPES = {
    "BigReactors-Reactor",
}

local INDUCTION_TYPES = {
    "inductionPort",
}

local STATE = {
    reactor = nil,
    reactor_name = nil,
    induction = nil,
    induction_name = nil,
    display = nil,
    display_name = nil,
    display_is_monitor = false,
    display_width = nil,
    display_height = nil,
    display_colour = false,
    last_line_count = 0,
}

local function safe_call(target, method, ...)
    if not target or type(target[method]) ~= "function" then
        return nil
    end

    local ok, result = pcall(target[method], ...)
    if ok then
        return result
    end
    return nil
end

local function read_first(target, methods)
    for _, method in ipairs(methods) do
        local value = safe_call(target, method)
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function format_energy(value)
    local numeric = tonumber(value)
    if numeric == nil then
        return nil
    end

    value = numeric

    local suffixes = { "", "k", "M", "G", "T", "P" }
    local sign = value < 0 and "-" or ""
    local magnitude = math.abs(value)
    local idx = 1

    while magnitude >= 1000 and idx < #suffixes do
        magnitude = magnitude / 1000
        idx = idx + 1
    end

    local fmt
    if magnitude >= 100 or idx == 1 then
        fmt = "%.0f"
    elseif magnitude >= 10 then
        fmt = "%.1f"
    else
        fmt = "%.2f"
    end

    return string.format("%s" .. fmt .. "%s", sign, magnitude, suffixes[idx])
end

local function format_amount(value, max_value, unit)
    if value == nil then
        return "N/A"
    end

    local numeric_value = tonumber(value)
    local numeric_max = tonumber(max_value)

    local text = format_energy(numeric_value) or tostring(value)
    if max_value ~= nil then
        text = text .. "/" .. (format_energy(numeric_max) or tostring(max_value))
    end
    if unit then
        text = text .. " " .. unit
    end
    if numeric_value and numeric_max and numeric_max > 0 then
        local pct = math.floor((numeric_value / numeric_max) * 100 + 0.5)
        text = text .. string.format(" (%d%%)", pct)
    end
    return text
end

local function format_rate(value, unit)
    if value == nil then
        return "N/A"
    end

    local numeric = tonumber(value)
    local text
    if numeric and math.abs(numeric) < 10 then
        text = string.format("%.3f", numeric)
    else
        text = format_energy(numeric) or tostring(value)
    end

    if unit then
        text = text .. " " .. unit
    end
    return text
end

local function format_temp(value)
    if value == nil then
        return "N/A"
    end

    local numeric = tonumber(value)
    if numeric == nil then
        return tostring(value)
    end

    return string.format("%.0fC", numeric)
end

local function resolve_display()
    local mon = peripheral.find("monitor")
    if mon then
        return mon, true, peripheral.getName(mon)
    end

    return term, false, "term"
end

local function update_display_state()
    local display, is_monitor, name = resolve_display()
    local changed = display ~= STATE.display or name ~= STATE.display_name or is_monitor ~= STATE.display_is_monitor

    STATE.display = display
    STATE.display_name = name
    STATE.display_is_monitor = is_monitor

    if changed then
        if is_monitor and display and type(display.setTextScale) == "function" then
            display.setTextScale(monitor_scale)
        end

        if display and type(display.clear) == "function" then
            display.clear()
        end
        if display and type(display.setCursorPos) == "function" then
            display.setCursorPos(1, 1)
        end
        STATE.last_line_count = 0
    end

    local width, height
    if display and type(display.getSize) == "function" then
        width, height = display.getSize()
    else
        width, height = term.getSize()
    end

    STATE.display_width = width or STATE.display_width or 32
    STATE.display_height = height or STATE.display_height or 15
    STATE.display_colour = display and ((display.isColour and display.isColour()) or (display.isColor and display.isColor())) or false

    return display
end

local function find_first_type(type_list)
    for _, type_name in ipairs(type_list) do
        local found = peripheral.find(type_name)
        if found then
            return found, peripheral.getName(found)
        end
    end
    return nil, nil
end

local function refresh_peripherals()
    if SETTINGS.reactor_name then
        if not (STATE.reactor and STATE.reactor_name == SETTINGS.reactor_name and peripheral.isPresent(SETTINGS.reactor_name)) then
            if peripheral.isPresent(SETTINGS.reactor_name) then
                STATE.reactor = peripheral.wrap(SETTINGS.reactor_name)
                STATE.reactor_name = SETTINGS.reactor_name
            else
                STATE.reactor = nil
                STATE.reactor_name = SETTINGS.reactor_name
            end
        end
    else
        if STATE.reactor_name and not peripheral.isPresent(STATE.reactor_name) then
            STATE.reactor = nil
            STATE.reactor_name = nil
        end
        if not STATE.reactor then
            STATE.reactor, STATE.reactor_name = find_first_type(REACTOR_TYPES)
        end
    end

    if SETTINGS.induction_name then
        if not (STATE.induction and STATE.induction_name == SETTINGS.induction_name and peripheral.isPresent(SETTINGS.induction_name)) then
            if peripheral.isPresent(SETTINGS.induction_name) then
                STATE.induction = peripheral.wrap(SETTINGS.induction_name)
                STATE.induction_name = SETTINGS.induction_name
            else
                STATE.induction = nil
                STATE.induction_name = SETTINGS.induction_name
            end
        end
    else
        if STATE.induction_name and not peripheral.isPresent(STATE.induction_name) then
            STATE.induction = nil
            STATE.induction_name = nil
        end
        if not STATE.induction then
            STATE.induction, STATE.induction_name = find_first_type(INDUCTION_TYPES)
        end
    end
end

local function read_reactor_stats(reactor)
    if not reactor then
        return nil
    end

    local stats = {
        active = safe_call(reactor, "getActive"),
        energy = read_first(reactor, { "getEnergyStored", "getEnergy" }),
        energy_capacity = read_first(reactor, { "getEnergyCapacity", "getEnergyStoredMax", "getMaxEnergyStored" }),
        output = read_first(reactor, { "getEnergyProducedLastTick" }),
        fuel = read_first(reactor, { "getFuelAmount" }),
        fuel_max = read_first(reactor, { "getFuelAmountMax" }),
        fuel_temp = read_first(reactor, { "getFuelTemperature" }),
        casing_temp = read_first(reactor, { "getCasingTemperature" }),
        fuel_used = read_first(reactor, { "getFuelConsumedLastTick" }),
        fuel_reactivity = read_first(reactor, { "getFuelReactivity" }),
    }

    if stats.active == nil then
        stats.active = safe_call(reactor, "getIsActive")
    end

    return stats
end

local function read_induction_stats(induction)
    if not induction then
        return nil
    end

    return {
        energy = read_first(induction, { "getEnergy", "getEnergyStored" }),
        energy_capacity = read_first(induction, { "getMaxEnergy", "getEnergyCapacity", "getMaxEnergyStored" }),
        input = read_first(induction, { "getLastInput", "getInput" }),
        output = read_first(induction, { "getLastOutput", "getOutput" }),
        transfer_cap = read_first(induction, { "getTransferCap", "getTransferCapacity" }),
    }
end

local function label_with_name(label, name)
    if name and name ~= "" then
        return label .. " (" .. name .. ")"
    end
    return label
end

local function build_lines(reactor_stats, induction_stats)
    local lines = {}

    if not reactor_stats then
        lines[#lines + 1] = { text = label_with_name("Reactor: Missing", STATE.reactor_name), colour = colours.red }
    else
        local status = "UNKNOWN"
        local colour = colours.yellow
        if reactor_stats.active == true then
            status = "ACTIVE"
            colour = colours.green
        elseif reactor_stats.active == false then
            status = "INACTIVE"
            colour = colours.red
        end

        lines[#lines + 1] = { text = label_with_name("Reactor: " .. status, STATE.reactor_name), colour = colour }
        lines[#lines + 1] = { text = "Energy: " .. format_amount(reactor_stats.energy, reactor_stats.energy_capacity, "RF") }
        if reactor_stats.output ~= nil then
            lines[#lines + 1] = { text = "Output: " .. format_rate(reactor_stats.output, "RF/t") }
        else
            lines[#lines + 1] = { text = "Output: N/A" }
        end
        lines[#lines + 1] = { text = "Fuel: " .. format_amount(reactor_stats.fuel, reactor_stats.fuel_max, "mB") }

        local details = {}
        if reactor_stats.fuel_used ~= nil then
            details[#details + 1] = "Use " .. format_rate(reactor_stats.fuel_used, "mB/t")
        end
        if reactor_stats.fuel_reactivity ~= nil then
            local reactivity = tonumber(reactor_stats.fuel_reactivity)
            if reactivity then
                details[#details + 1] = string.format("React %.0f%%", reactivity)
            else
                details[#details + 1] = "React " .. tostring(reactor_stats.fuel_reactivity)
            end
        end
        if #details > 0 then
            lines[#lines + 1] = { text = table.concat(details, " ") }
        end

        local temps = {}
        if reactor_stats.fuel_temp ~= nil then
            temps[#temps + 1] = "Fuel " .. format_temp(reactor_stats.fuel_temp)
        end
        if reactor_stats.casing_temp ~= nil then
            temps[#temps + 1] = "Case " .. format_temp(reactor_stats.casing_temp)
        end
        if #temps > 0 then
            lines[#lines + 1] = { text = table.concat(temps, " ") }
        end
    end

    lines[#lines + 1] = { text = "" }

    if not induction_stats then
        lines[#lines + 1] = { text = label_with_name("Matrix: Missing", STATE.induction_name), colour = colours.red }
    else
        lines[#lines + 1] = { text = label_with_name("Matrix: OK", STATE.induction_name), colour = colours.green }
        lines[#lines + 1] = { text = "Energy: " .. format_amount(induction_stats.energy, induction_stats.energy_capacity, "RF") }

        local flow_parts = {}
        if induction_stats.input ~= nil then
            flow_parts[#flow_parts + 1] = "In " .. format_rate(induction_stats.input, "RF/t")
        end
        if induction_stats.output ~= nil then
            flow_parts[#flow_parts + 1] = "Out " .. format_rate(induction_stats.output, "RF/t")
        end
        if #flow_parts > 0 then
            lines[#lines + 1] = { text = table.concat(flow_parts, " ") }
        end

        if induction_stats.transfer_cap ~= nil then
            lines[#lines + 1] = { text = "Cap: " .. format_rate(induction_stats.transfer_cap, "RF/t") }
        end
    end

    return lines
end

local function render_lines(lines)
    local display = update_display_state()
    if not display then
        return
    end

    local width = STATE.display_width or 32
    local height = STATE.display_height or 15
    local max_lines = math.min(#lines, height)

    for i = 1, max_lines do
        local line = lines[i] or {}
        local text = line.text or ""
        if #text > width then
            text = string.sub(text, 1, width)
        end

        if display.setCursorPos then
            display.setCursorPos(1, i)
        end
        if display.clearLine then
            display.clearLine()
        end
        if STATE.display_colour and line.colour and display.setTextColour then
            display.setTextColour(line.colour)
        end
        if display.write then
            display.write(text)
        end
        if STATE.display_colour and line.colour and display.setTextColour then
            display.setTextColour(colours.white)
        end
    end

    local clear_to = math.min(STATE.last_line_count, height)
    for i = max_lines + 1, clear_to do
        if display.setCursorPos then
            display.setCursorPos(1, i)
        end
        if display.clearLine then
            display.clearLine()
        end
    end

    STATE.last_line_count = max_lines
end

while true do
    refresh_peripherals()
    local reactor_stats = read_reactor_stats(STATE.reactor)
    local induction_stats = read_induction_stats(STATE.induction)
    render_lines(build_lines(reactor_stats, induction_stats))
    sleep(refresh_interval)
end
