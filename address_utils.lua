local AddressUtils = {}

local WARNED_NO_SITE = false

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
AddressUtils.normalise_name = normalise_name

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
AddressUtils.get_site = get_site

local function to_set(list)
    local t = {}
    for _, v in ipairs(list or {}) do
        local _, norm = normalise_name(v)
        if norm then
            t[norm] = true
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
            if allowed["*"] then
                return nil
            end
            if next(allowed) then
                return allowed
            end
            return nil
        end
    end
end

function AddressUtils.filtered_addresses(all, site_override)
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
        local is_intergalactic = false
        if galaxy_id and gate_galaxy and gate_galaxy ~= galaxy_id then
            is_intergalactic = true
        end

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
            g.is_intergalactic = is_intergalactic
            table.insert(result, g)
        end
    end
    return result
end

function AddressUtils.addresses_match(a, b)
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

function AddressUtils.lookup_site(addr, all)
    for _, g in ipairs(all or require("addresses")) do
        if AddressUtils.addresses_match(addr, g.address) then
            return g.site
        end
    end
end

function AddressUtils.find_gate_by_address(addr, all)
    for _, gate in ipairs(all or require("addresses")) do
        if AddressUtils.addresses_match(addr, gate.address) then
            return gate
        end
    end
    return { site = "Manual", address = addr }
end

function AddressUtils.is_valid_address(addr)
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

function AddressUtils.trim_edge_hyphens(str)
    if type(str) ~= "string" then
        return str
    end

    local trimmed = str:gsub("^%s+", ""):gsub("%s+$", "")
    trimmed = trimmed:gsub("^%-+", ""):gsub("%-+$", "")
    if trimmed == "" then
        return str
    end
    return trimmed
end

function AddressUtils.address_to_string(addr, interface)
    if not addr then
        return "-"
    end

    if interface and type(interface.addressToString) == "function" then
        local converted = interface.addressToString(addr)
        converted = AddressUtils.trim_edge_hyphens(converted)
        if converted and converted ~= "-" and converted ~= "" then
            return converted
        end
    end

    local pieces = {}
    for i, v in ipairs(addr) do
        pieces[#pieces + 1] = tostring(v)
    end
    return AddressUtils.trim_edge_hyphens(table.concat(pieces, "-"))
end

function AddressUtils.format_address(idx, gate, max_width, with_number)
    if not gate then
        return ""
    end

    local base = gate.site or ""
    if gate.is_intergalactic then
        base = "[" .. base .. "]"
    end
    local text = with_number == false and base or (idx .. " = " .. base)
    if not max_width or #text <= max_width then
        return text
    end

    if max_width <= 3 then
        return string.sub(text, 1, max_width)
    end

    return string.sub(text, 1, max_width - 3) .. "..."
end

function AddressUtils.pad_to_width(text, width)
    text = text or ""
    if not width or #text >= width then
        return text .. " "
    end
    return text .. string.rep(" ", width - #text)
end

return AddressUtils
