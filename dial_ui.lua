package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local M = {}

function M.init(ctx)
    local SG_SETTINGS = ctx.settings
    local STATE = ctx.state
    local SG_ADDRESSES = ctx.addresses

    local function reset_top()
        SG_UTILS.reset_line_offset()
        STATE.top_lines = 0
    end

    local function apply_top_offset()
        SG_UTILS.set_line_offset(math.max(STATE.top_lines - 1, 0))
    end

    local function show_top_message(text)
        SG_UTILS.clear_lines(STATE.top_lines)
        reset_top()
        STATE.top_lines = SG_UTILS.update_line(text) or 1
        apply_top_offset()
        return STATE.top_lines
    end

    local function show_top_message_lines(lines)
        SG_UTILS.clear_lines(STATE.top_lines)
        reset_top()

        STATE.top_lines = SG_UTILS.write_lines(lines, 1) or 0
        if STATE.top_lines < 1 then
            STATE.top_lines = 1
        end

        apply_top_offset()
        return STATE.top_lines
    end

    local function show_status(lines, scale)
        SG_UTILS.prepare_monitor(scale or 1, true)
        reset_top()
        if type(lines) == "table" then
            return show_top_message_lines(lines)
        else
            return show_top_message(lines)
        end
    end

    local function resolve_colour(value, default)
        if type(value) == "number" then
            return value
        end
        if type(value) == "string" then
            local function lookup(key)
                if colours[key] then
                    return colours[key]
                end
            end

            local exact = lookup(value)
            if exact then
                return exact
            end

            local lower = string.lower(value)
            if lower ~= value then
                local lower_res = lookup(lower)
                if lower_res then
                    return lower_res
                end
            end
        end
        return default
    end

    local function update_dial_progress(encoded_count)
        if not (STATE.gate and STATE.gate.address) then
            return
        end

        local addr = STATE.gate.address
        local total = #addr
        if total <= 0 then
            return
        end

        local coloured = math.max(math.min(encoded_count or 0, total), 0)
        local encoded_colour = resolve_colour(SG_SETTINGS.dialing_colour, colours.green)
        local remaining_colour = resolve_colour("lightGrey", colours.white)
        local segments = {}
        for idx, symbol in ipairs(addr) do
            local text = tostring(symbol)
            if idx < total then
                text = text .. "-"
            end
            segments[#segments + 1] = {
                text = text,
                colour = idx <= coloured and encoded_colour or remaining_colour,
            }
        end

        SG_UTILS.update_coloured_line(segments, 1, SG_UTILS.address_to_string(addr))
    end

    local function make_banner(width, phrase, pad)
        pad = pad or "!"
        phrase = phrase or ""
        width = math.max(width or 1, 1)

        if width <= 2 then
            return string.rep(pad, width)
        end

        local plen = #phrase
        if width < plen + 2 then
            phrase = string.sub(phrase, 1, width - 2)
            plen = #phrase
        end

        local n = math.floor(width / (plen + 2))
        if n < 1 then
            n = 1
        end

        local base_len = n * (plen + 2)
        local total_pad = width - base_len

        local segments = n + 1
        local base_pad = math.floor(total_pad / segments)
        local rem = total_pad % segments

        local pads = {}
        for i = 1, segments do
            local extra = (i <= rem) and 1 or 0
            pads[i] = string.rep(pad, base_pad + extra)
        end

        local parts = {}
        for i = 1, n do
            table.insert(parts, pads[i])
            table.insert(parts, " ")
            table.insert(parts, phrase)
            table.insert(parts, " ")
        end
        table.insert(parts, pads[segments])

        return table.concat(parts)
    end

    local function show_incoming_banner()
        SG_UTILS.prepare_monitor(1, true)
        SG_UTILS.set_text_colour(colours.red)
        reset_top()
        local width = select(1, SG_UTILS.get_monitor_size())
        if not width or width < 1 then
            width = 1
        end

        local top_bottom = string.rep("!", width)

        local middle = make_banner(width, "Incoming", "!")
        if #middle > width then
            middle = string.sub(middle, 1, width)
        end

        SG_UTILS.update_line(top_bottom, 1)
        SG_UTILS.update_line(middle, 2)
        SG_UTILS.update_line(top_bottom, 3)
        SG_UTILS.reset_text_colour()
        STATE.top_lines = 3
        SG_UTILS.set_line_offset(STATE.top_lines - 1)
    end

    local function update_incoming_counter_line()
        if not STATE.top_lines or STATE.top_lines <= 0 then
            return
        end
        SG_UTILS.set_line_offset(0)
        SG_UTILS.update_line("Open for " .. STATE.incoming_seconds .. "s", STATE.top_lines + 1)
        SG_UTILS.set_line_offset(math.max(STATE.top_lines - 1, 0))
    end

    local function screen()
        -- Menu of gate address options
        local rs = SG_UTILS.get_inf_rs()
        SG_UTILS.reset_outputs(rs)
        SG_UTILS.prepare_monitor(1, true)
        reset_top()
        local addr_count = #SG_ADDRESSES
        if addr_count == 0 then
            return
        end

        local layout = SG_UTILS.compute_menu_layout(addr_count)
        local columns = layout.columns
        local rows = layout.rows
        local col_width = layout.col_width
        local entry_width = layout.entry_width

        for row = 1, rows, 1 do
            local display_pieces = {}
            local log_pieces = {}
            for col = 1, columns, 1 do
                local idx = (col - 1) * rows + row
                local gate = SG_ADDRESSES[idx]

                local display_entry = gate and SG_UTILS.format_address(idx, gate, entry_width, false) or ""
                local log_entry = gate and SG_UTILS.format_address(idx, gate, nil, true) or ""

                if col < columns then
                    display_entry = SG_UTILS.pad_to_width(display_entry, col_width)
                    log_entry = SG_UTILS.pad_to_width(log_entry, col_width)
                end

                display_pieces[#display_pieces + 1] = display_entry
                log_pieces[#log_pieces + 1] = log_entry
            end
            SG_UTILS.update_line(table.concat(display_pieces), row, table.concat(log_pieces))
        end

        local mon = SG_UTILS.get_inf_mon()
        if mon then
            local fast = SG_UTILS.rs_input(SG_SETTINGS.rs_fast_dial)
            mon.setCursorPos(layout.width, layout.height)
            mon.write(fast and ">" or "#")
        end
    end

    ctx.reset_top = reset_top
    ctx.show_top_message = show_top_message
    ctx.show_top_message_lines = show_top_message_lines
    ctx.show_status = show_status
    ctx.update_dial_progress = update_dial_progress
    ctx.show_incoming_banner = show_incoming_banner
    ctx.update_incoming_counter_line = update_incoming_counter_line
    ctx.screen = screen
end

return M
