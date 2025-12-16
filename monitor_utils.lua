local MonitorUtils = {}

local INF_MON
local MON_SIZE = nil
local LINE_OFFSET = 0

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

function MonitorUtils.get_inf_mon()
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

function MonitorUtils.prepare_monitor(scale, should_clear)
    local mon = MonitorUtils.get_inf_mon()
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

function MonitorUtils.set_text_colour(colour)
    local mon = MonitorUtils.get_inf_mon()
    if mon and mon.isColour() and colour then
        mon.setTextColour(colour)
    end
end

function MonitorUtils.reset_text_colour()
    local mon = MonitorUtils.get_inf_mon()
    if mon and mon.isColour() then
        mon.setTextColour(colours.white)
    end
end

function MonitorUtils.get_monitor_size(default_width, default_height)
    MonitorUtils.get_inf_mon()
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

function MonitorUtils.clear_lines(count, start_line)
    local mon = MonitorUtils.get_inf_mon()
    if not mon or not count or count <= 0 then
        return
    end
    local line = start_line or 1
    for i = 0, count - 1, 1 do
        mon.setCursorPos(1, line + i)
        mon.clearLine()
    end
end

function MonitorUtils.clear_all_lines()
    local _, h = MonitorUtils.get_monitor_size()
    MonitorUtils.clear_lines(h, 1)
    MonitorUtils.reset_line_offset()
end

function MonitorUtils.update_line(text, line, log_text)
    line = (line or 1) + LINE_OFFSET
    text = text or ""
    log_text = log_text or text

    local mon = MonitorUtils.get_inf_mon()
    local width = select(1, MonitorUtils.get_monitor_size())

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

local function resolve_line(line, ignore_offset)
    if ignore_offset then
        return math.max(line or 1, 1)
    end
    return (line or 1) + LINE_OFFSET
end

local function flatten_segments(segments)
    local parts = {}
    for _, seg in ipairs(segments or {}) do
        parts[#parts + 1] = seg.text or ""
    end
    return table.concat(parts)
end

function MonitorUtils.update_coloured_line(segments, line, log_text, ignore_offset)
    local mon = MonitorUtils.get_inf_mon()
    local target_line = resolve_line(line, ignore_offset)
    local full_text = flatten_segments(segments)

    local has_colour = mon and ((mon.isColour and mon.isColour()) or (mon.isColor and mon.isColor()))
    if not has_colour then
        return MonitorUtils.update_line(full_text, line, log_text)
    end

    local width = select(1, MonitorUtils.get_monitor_size())
    mon.setCursorPos(1, target_line)
    mon.clearLine()

    local remaining = width
    for _, seg in ipairs(segments or {}) do
        if remaining and remaining <= 0 then
            break
        end
        local text = seg.text or ""
        if remaining and #text > remaining then
            text = string.sub(text, 1, remaining)
        end
        local colour = seg.colour or colours.white
        mon.setTextColour(colour)
        mon.write(text)
        if remaining then
            remaining = remaining - #text
        end
    end

    local reset_colour = colours.white
    mon.setTextColour(reset_colour)
    print(log_text or full_text)
    return 1
end

function MonitorUtils.show_top_message(text)
    MonitorUtils.reset_line_offset()
    return MonitorUtils.update_line(text or "", 1)
end

function MonitorUtils.write_lines(lines, start_line)
    local total = 0
    local base = start_line or 1

    for i, txt in ipairs(lines or {}) do
        local written = MonitorUtils.update_line(txt or "", base + total) or 1
        total = total + written
    end

    return total
end

function MonitorUtils.set_line_offset(offset)
    LINE_OFFSET = math.max(0, offset or 0)
end

function MonitorUtils.reset_line_offset()
    MonitorUtils.set_line_offset(0)
    return LINE_OFFSET
end

return MonitorUtils
