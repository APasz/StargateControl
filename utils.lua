package.path = package.path .. ";disk/?.lua;disk/?/init.lua"

local address_utils = require("address_utils")
local dialing_utils = require("dialing_utils")
local menu_utils = require("menu_utils")
local monitor_utils = require("monitor_utils")
local peripheral_utils = require("peripheral_utils")

local U = {
    addr_input = nil,
}

local function merge(target, source)
    for key, value in pairs(source) do
        target[key] = value
    end
end

merge(U, monitor_utils)
merge(U, peripheral_utils)
merge(U, dialing_utils)

U.filtered_addresses = address_utils.filtered_addresses
U.addresses_match = address_utils.addresses_match
U.lookup_site = address_utils.lookup_site
U.find_gate_by_address = address_utils.find_gate_by_address
U.is_valid_address = address_utils.is_valid_address
U.format_address = address_utils.format_address
U.pad_to_width = address_utils.pad_to_width
U.trim_edge_hyphens = address_utils.trim_edge_hyphens

function U.address_to_string(addr)
    local interface = select(1, peripheral_utils.get_inf_gate())
    return address_utils.address_to_string(addr, interface)
end

function U.compute_menu_layout(addr_count)
    local width, height = monitor_utils.get_monitor_size(32, 15)
    return menu_utils.compute_menu_layout(addr_count, width, height)
end

function U.get_selection(ev, p2, p3, p4, addresses)
    local list = addresses or require("addresses")
    local width, height = monitor_utils.get_monitor_size(32, 15)
    local lookup = function(addr)
        return address_utils.lookup_site(addr, list)
    end
    return menu_utils.get_selection(ev, p2, p3, p4, list, width, height, address_utils.is_valid_address, lookup)
end

function U.wait_for_touch(addresses)
    local mon = monitor_utils.get_inf_mon()
    local count = #(addresses or require("addresses"))
    local selected = menu_utils.wait_for_touch(count, mon)
    U.addr_input = selected
    return selected
end

function U.wait_for_keyboard()
    local selected = menu_utils.wait_for_keyboard()
    U.addr_input = selected
    return selected
end

function U.wait_for_disconnect_request()
    return menu_utils.wait_for_disconnect_request()
end

return U
